import Foundation
import IOBluetooth
import EncoCore

/// Vendor RFCOMM control channel.
///
/// Resolves the channel through SDP (never a hardcoded number), opens exactly one
/// channel to an already connected device, and only ever
/// closes that channel — no pairing calls, no baseband connect/disconnect.
///
/// All delegate callbacks and state live on the calling run loop; `open(timeout:)`
/// pumps that run loop in bounded steps so the CLI cannot block forever. A channel that
/// completes its open after the caller gave up is closed and never adopted.
public final class RFCOMMTransport: NSObject, IOBluetoothRFCOMMChannelDelegate {
    public enum State: Equatable {
        case idle
        case resolving
        case opening
        case open
        case closed
        case failed(String)
    }

    public struct SentFrame: Equatable {
        public let cmd: UInt16
        public let sequence: UInt8
        public let raw: [UInt8]
    }

    private struct PendingWrite {
        /// Retained until the write completes; `writeAsync` does not copy the buffer.
        let data: NSMutableData
        let cmd: UInt16
        let sequence: UInt8
        let sentAt: Date
    }

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onState?(state)
        }
    }
    public private(set) var channelID: BluetoothRFCOMMChannelID?
    public private(set) var receiveChunkCount = 0
    public private(set) var receivedByteCount = 0
    public private(set) var parser = FrameStreamParser()
    public private(set) var lastWriteError: IOReturn?
    public private(set) var writeFailureCount = 0
    public private(set) var didCloseUnexpectedly = false

    public var onFrame: ((Frame) -> Void)?
    public var onRawReceive: (([UInt8]) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Fires on every state change, including a channel the system dropped, so a UI can
    /// show a lost link instead of silently stale numbers.
    public var onState: ((State) -> Void)?

    public let device: IOBluetoothDevice
    public var maskedAddress: String { AddressMask.mask(device.addressString) }
    public var pendingWriteCount: Int { pendingWrites.count }

    private var channel: IOBluetoothRFCOMMChannel?
    private var pendingChannel: IOBluetoothRFCOMMChannel?
    private var openStatus: IOReturn?
    private var didFinishOpening = false
    /// Set once the caller stopped waiting or closed; late callbacks must not revive the link.
    private var isAbandoned = false
    private var isClosing = false
    private var nextSequence: UInt8 = FrameCodec.defaultSequence
    /// SDP query targets are kept alive for at least as long as a callback may reference them.
    private var sdpWaiters: [SDPQueryWaiter] = []
    private var pendingWrites: [UInt: PendingWrite] = [:]
    private var nextWriteRefcon: UInt = 1
    private var asyncOpenCompletion: ((Result<Void, Error>) -> Void)?
    private var asyncOpenTimer: Timer?
    private var openGeneration = 0

    public init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    /// GUI path: return to AppKit between every phase. Never pump a nested run loop.
    /// Cached SDP is authoritative until opening it fails; a retry can force fresh discovery.
    @MainActor
    public func openAsync(refreshServices: Bool = false, sdpTimeout: TimeInterval = 6, openTimeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openGeneration += 1
            let generation = openGeneration
            isAbandoned = false
            parser.reset()
            asyncOpenCompletion = { continuation.resume(with: $0) }
            state = .resolving
            if !refreshServices, device.getServiceRecord(for: EncoDeviceLocator.controlServiceUUID) != nil {
                log("using cached vendor SDP record")
                beginAsyncChannelOpen(timeout: openTimeout)
                return
            }
            let waiter = SDPQueryWaiter()
            sdpWaiters.append(waiter)
            waiter.onComplete = { [weak self, weak waiter] status in
                waiter?.onComplete = nil
                guard let self, self.openGeneration == generation, self.asyncOpenCompletion != nil else { return }
                self.asyncOpenTimer?.invalidate()
                self.sdpWaiters.removeAll { $0.finished }
                guard status == kIOReturnSuccess else {
                    self.finishAsyncOpen(.failure(EncoBluetoothError.sdpQueryFailed(status)))
                    return
                }
                self.beginAsyncChannelOpen(timeout: openTimeout)
            }
            // Arm before dispatch so an inline completion cannot replace the channel timer
            // with a stale discovery timer.
            armOpenTimer(seconds: sdpTimeout) { [weak self] in
                self?.finishAsyncOpen(.failure(EncoBluetoothError.sdpQueryFailed(kIOReturnTimeout)))
            }
            let result = device.performSDPQuery(waiter)
            guard result == kIOReturnSuccess else {
                finishAsyncOpen(.failure(EncoBluetoothError.sdpQueryFailed(result)))
                return
            }
        }
    }

    private func beginAsyncChannelOpen(timeout: TimeInterval) {
        guard let record = device.getServiceRecord(for: EncoDeviceLocator.controlServiceUUID) else {
            finishAsyncOpen(.failure(EncoBluetoothError.serviceRecordNotFound)); return
        }
        var id: BluetoothRFCOMMChannelID = 0
        let result = record.getRFCOMMChannelID(&id)
        guard result == kIOReturnSuccess, id != 0 else {
            finishAsyncOpen(.failure(EncoBluetoothError.rfcommChannelUnavailable(result))); return
        }
        channelID = id
        state = .opening
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        guard status == kIOReturnSuccess else {
            finishAsyncOpen(.failure(EncoBluetoothError.channelOpenFailed(status))); return
        }
        // Do not overwrite an already completed callback, even if a driver replies inline.
        if asyncOpenCompletion != nil {
            pendingChannel = opened
            armOpenTimer(seconds: timeout) { [weak self] in
                self?.finishAsyncOpen(.failure(EncoBluetoothError.channelOpenTimeout(timeout)))
            }
        }
    }

    private func armOpenTimer(seconds: TimeInterval, action: @escaping () -> Void) {
        asyncOpenTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in action() }
        asyncOpenTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishAsyncOpen(_ result: Result<Void, Error>) {
        guard let completion = asyncOpenCompletion else { return }
        asyncOpenCompletion = nil
        asyncOpenTimer?.invalidate()
        asyncOpenTimer = nil
        for waiter in sdpWaiters { waiter.onComplete = nil }
        if case .failure(let error) = result {
            abandonPendingChannel(String(describing: error))
            state = .failed(String(describing: error))
        }
        completion(result)
    }

    /// Resolves the vendor service, then opens the channel and waits (bounded) for completion.
    public func open(sdpTimeout: TimeInterval = 10, openTimeout: TimeInterval = 12) throws {
        didFinishOpening = false
        openStatus = nil
        isAbandoned = false
        parser.reset()
        receiveChunkCount = 0
        receivedByteCount = 0
        didCloseUnexpectedly = false
        state = .resolving

        let waiter = SDPQueryWaiter()
        sdpWaiters.append(waiter)
        let queryResult = device.performSDPQuery(waiter)
        if queryResult == kIOReturnSuccess {
            let deadline = Date().addingTimeInterval(sdpTimeout)
            RunLoopPump.pump(until: deadline, shouldStop: { waiter.finished })
            if !waiter.finished {
                log("SDP query did not complete within \(Int(sdpTimeout))s; falling back to cached records")
            } else if waiter.status != kIOReturnSuccess {
                log("SDP query finished with \(describe(waiter.status ?? kIOReturnError))")
            }
        } else {
            log("performSDPQuery could not start: \(describe(queryResult))")
        }
        // Completed waiters are unreferenced by the framework; unfinished ones stay retained.
        sdpWaiters.removeAll { $0.finished }

        guard let record = device.getServiceRecord(for: EncoDeviceLocator.controlServiceUUID) else {
            state = .failed("service record not found")
            throw EncoBluetoothError.serviceRecordNotFound
        }
        var resolvedChannel: BluetoothRFCOMMChannelID = 0
        let channelStatus = record.getRFCOMMChannelID(&resolvedChannel)
        guard channelStatus == kIOReturnSuccess else {
            state = .failed("no RFCOMM channel id")
            throw EncoBluetoothError.rfcommChannelUnavailable(channelStatus)
        }
        channelID = resolvedChannel
        log("resolved vendor service '\(record.getServiceName() ?? "<unnamed>")' to RFCOMM channel \(resolvedChannel)")

        state = .opening
        var opened: IOBluetoothRFCOMMChannel?
        let openResult = device.openRFCOMMChannelAsync(&opened, withChannelID: resolvedChannel, delegate: self)
        guard openResult == kIOReturnSuccess else {
            state = .failed("openRFCOMMChannelAsync \(describe(openResult))")
            throw EncoBluetoothError.channelOpenFailed(openResult)
        }
        pendingChannel = opened

        let deadline = Date().addingTimeInterval(openTimeout)
        RunLoopPump.pump(until: deadline, shouldStop: { self.didFinishOpening })
        guard didFinishOpening else {
            abandonPendingChannel("open timeout after \(Int(openTimeout))s")
            state = .failed("open timeout")
            throw EncoBluetoothError.channelOpenTimeout(openTimeout)
        }
        let status = openStatus ?? kIOReturnError
        guard status == kIOReturnSuccess, let openedChannel = channel else {
            abandonPendingChannel("open failed with \(describe(status))")
            state = .failed("open failed")
            throw EncoBluetoothError.channelOpenFailed(status)
        }
        log("channel open on RFCOMM channel \(openedChannel.getID())")
    }

    /// Drops a channel we are no longer waiting for: delegate cleared first, then closed.
    private func abandonPendingChannel(_ reason: String) {
        isAbandoned = true
        didFinishOpening = true
        let target = pendingChannel ?? channel
        pendingChannel = nil
        channel = nil
        if let target {
            _ = target.setDelegate(nil)
            _ = target.close()
        }
        log("abandoned pending channel: \(reason)")
    }

    /// Sends one frame. The sequence number increments per call and is returned for
    /// matching a response against its request.
    @discardableResult
    public func send(cmd: UInt16, payload: [UInt8] = []) throws -> SentFrame {
        guard let channel, state == .open else {
            throw EncoBluetoothError.sendFailed(kIOReturnNotOpen)
        }
        let sequence = nextSequence
        let bytes = try FrameCodec.encode(cmd: cmd, payload: payload, sequence: sequence)
        nextSequence = nextSequence == UInt8.max ? 0 : nextSequence + 1

        // The buffer must stay alive until writeComplete: writeAsync keeps the pointer.
        let buffer = NSMutableData(bytes: bytes, length: bytes.count)
        let refcon = nextWriteRefcon
        nextWriteRefcon += 1
        // Registered before the call: a synchronous completion callback would otherwise arrive
        // before there is anything to release.
        pendingWrites[refcon] = PendingWrite(data: buffer, cmd: cmd, sequence: sequence, sentAt: Date())
        let result = channel.writeAsync(
            buffer.mutableBytes,
            length: UInt16(bytes.count),
            refcon: UnsafeMutableRawPointer(bitPattern: refcon)
        )
        guard result == kIOReturnSuccess else {
            pendingWrites.removeValue(forKey: refcon)
            lastWriteError = result
            writeFailureCount += 1
            throw EncoBluetoothError.sendFailed(result)
        }
        return SentFrame(cmd: cmd, sequence: sequence, raw: bytes)
    }

    /// Closes the control channel only; the device stays connected to the system.
    /// Idempotent, and re-entrancy safe: the delegate is cleared before the close so
    /// `rfcommChannelClosed` cannot call back into a half-closed transport.
    public func close() {
        guard !isClosing else { return }
        isClosing = true
        openGeneration += 1
        finishAsyncOpen(.failure(CancellationError()))
        defer { isClosing = false }

        isAbandoned = true
        let target = channel ?? pendingChannel
        channel = nil
        pendingChannel = nil
        if let target {
            _ = target.setDelegate(nil)
            _ = target.close()
        }
        pendingWrites.removeAll()
        parser.reset()
        state = .closed
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    public func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        openStatus = error
        didFinishOpening = true

        guard !isAbandoned else {
            // The caller already gave up on this open: close it and stay disengaged.
            log("late open callback ignored (status \(describe(error)))")
            _ = channel?.setDelegate(nil)
            _ = channel?.close()
            pendingChannel = nil
            return
        }
        guard error == kIOReturnSuccess else {
            pendingChannel = nil
            self.channel = nil
            state = .failed("open complete \(describe(error))")
            finishAsyncOpen(.failure(EncoBluetoothError.channelOpenFailed(error)))
            return
        }
        self.channel = channel
        pendingChannel = nil
        state = .open
        finishAsyncOpen(.success(()))
    }

    public func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self),
            count: dataLength
        ))
        receiveChunkCount += 1
        receivedByteCount += chunk.count
        onRawReceive?(chunk)
        parser.append(chunk)
        for frame in parser.drain() {
            onFrame?(frame)
        }
    }

    public func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        finishAsyncOpen(.failure(EncoBluetoothError.channelOpenFailed(kIOReturnNotOpen)))
        self.channel = nil
        self.pendingChannel = nil
        if !isClosing {
            didCloseUnexpectedly = true
            log("channel closed by the system")
        }
        state = .closed
    }

    public func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        handleWriteComplete(refcon: refcon, status: error)
    }

    public func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn, bytesWritten length: Int) {
        handleWriteComplete(refcon: refcon, status: error)
    }

    private func handleWriteComplete(refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard let refcon else { return }
        let key = UInt(bitPattern: refcon)
        guard let pending = pendingWrites.removeValue(forKey: key) else { return }
        if error != kIOReturnSuccess {
            lastWriteError = error
            writeFailureCount += 1
            log(String(
                format: "async write failed cmd=0x%04X seq=0x%02X status=%@",
                pending.cmd, pending.sequence, describe(error)
            ))
        }
    }
}
