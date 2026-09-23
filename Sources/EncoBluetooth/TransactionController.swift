import Foundation
import EncoCore

/// Serial request/response transactions on the vendor channel.
///
/// One transaction in flight at a time. A request carries a unique `sequence`; the matching
/// response is the request command with bit 15 set, echoing that sequence — the same rule the
/// device already demonstrated for read-only queries. GUI operations suspend with continuations
/// and bounded timers; only the synchronous CLI operations pump the calling run loop.
///
/// The controller never assumes success: a write is only reported as verified after an
/// acknowledgement with status 0 **and** a follow-up query whose readback matches the target.
public final class TransactionController {
    public enum Outcome: Equatable {
        /// Response arrived with an explicit status byte of 0.
        case ok
        case rejected(status: UInt8)
        /// A response arrived but carries no status byte: never treated as success.
        case malformedResponse(String)
        case timedOut
        case notSent(String)
    }

    public struct QueryOutcome: Equatable {
        public let requestCmd: UInt16
        public let requestSequence: UInt8
        public let responseSequence: UInt8?
        public let status: UInt8?
        public let payload: [UInt8]
        public let outcome: Outcome
    }

    public private(set) var isBusy = false
    public private(set) var lastOutcome: TransactionResult?

    public var defaultTimeout: TimeInterval
    public var onLog: ((String) -> Void)?

    private let sendRequest: (UInt16, [UInt8]) throws -> UInt8
    private var asyncResponse: ((Frame) -> Void)?
    private var asyncCancel: (() -> Void)?
    private var cancelled = false
    private var pendingRequest: (cmd: UInt16, sequence: UInt8)?
    private var receivedResponse: Frame?

    public init(transport: RFCOMMTransport, defaultTimeout: TimeInterval = 4) {
        self.sendRequest = { try transport.send(cmd: $0, payload: $1).sequence }
        self.defaultTimeout = defaultTimeout
    }

    /// Injectable sender for deterministic offline timeout/cancellation/correlation checks.
    public init(defaultTimeout: TimeInterval = 4, sendRequest: @escaping (UInt16, [UInt8]) throws -> UInt8) {
        self.defaultTimeout = defaultTimeout
        self.sendRequest = sendRequest
    }

    /// Ends a discarded GUI session; pending async work resumes exactly once.
    public func cancel() {
        cancelled = true
        asyncCancel?()
    }

    @MainActor
    public func queryAsync(cmd: UInt16, payload: [UInt8] = [], timeout: TimeInterval? = nil) async -> QueryOutcome {
        guard !cancelled, !Task.isCancelled, !isBusy else {
            return QueryOutcome(requestCmd: cmd, requestSequence: 0, responseSequence: nil, status: nil, payload: [], outcome: .notSent("session closed or busy"))
        }
        isBusy = true
        defer { isBusy = false }
        let sequence: UInt8
        do { sequence = try sendRequest(cmd, payload) }
        catch {
            return QueryOutcome(requestCmd: cmd, requestSequence: 0, responseSequence: nil, status: nil, payload: [], outcome: .notSent(String(describing: error)))
        }
        pendingRequest = (cmd, sequence)
        receivedResponse = nil
        return await withCheckedContinuation { continuation in
            var finished = false
            var timer: Timer?
            let finish: (QueryOutcome) -> Void = { [weak self] result in
                guard !finished else { return }
                finished = true
                timer?.invalidate()
                self?.asyncResponse = nil
                self?.asyncCancel = nil
                self?.pendingRequest = nil
                self?.receivedResponse = nil
                continuation.resume(returning: result)
            }
            asyncResponse = { frame in
                let outcome: Outcome
                let status: UInt8?
                switch ResponseCorrelation.classify(frame) {
                case .missing: status = nil; outcome = .malformedResponse("响应无 status 字段")
                case .rejected(let value): status = value; outcome = .rejected(status: value)
                case .ok(let value): status = value; outcome = .ok
                }
                finish(QueryOutcome(requestCmd: cmd, requestSequence: sequence, responseSequence: frame.sequence, status: status, payload: frame.payload, outcome: outcome))
            }
            asyncCancel = {
                finish(QueryOutcome(requestCmd: cmd, requestSequence: sequence, responseSequence: nil, status: nil, payload: [], outcome: .notSent("session closed")))
            }
            timer = Timer(timeInterval: timeout ?? defaultTimeout, repeats: false) { _ in
                finish(QueryOutcome(requestCmd: cmd, requestSequence: sequence, responseSequence: nil, status: nil, payload: [], outcome: .timedOut))
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    /// Feed every received frame here (from `transport.onFrame`). Returns true when the frame
    /// was consumed as the response of the in-flight transaction.
    @discardableResult
    public func accept(_ frame: Frame) -> Bool {
        guard let pendingRequest else { return false }
        guard ResponseCorrelation.isResponse(frame, to: pendingRequest.cmd, sequence: pendingRequest.sequence) else {
            return false
        }
        guard receivedResponse == nil else { return false }
        receivedResponse = frame
        asyncResponse?(frame)
        return true
    }

    /// Read-only query: send, then wait for the correlated response.
    public func query(cmd: UInt16, payload: [UInt8] = [], timeout: TimeInterval? = nil) -> QueryOutcome {
        let limit = timeout ?? defaultTimeout
        guard !isBusy else {
            return QueryOutcome(requestCmd: cmd, requestSequence: 0, responseSequence: nil, status: nil, payload: [], outcome: .notSent("another transaction is in flight"))
        }
        isBusy = true
        defer { isBusy = false }

        let sentSequence: UInt8
        do {
            sentSequence = try sendRequest(cmd, payload)
        } catch {
            log(String(format: "TX 0x%04X failed: %@", cmd, String(describing: error)))
            return QueryOutcome(requestCmd: cmd, requestSequence: 0, responseSequence: nil, status: nil, payload: [], outcome: .notSent(String(describing: error)))
        }
        log(String(format: "TX 0x%04X seq=0x%02X payload=%@", cmd, sentSequence, Hex.string(payload)))

        let deadline = Date().addingTimeInterval(limit)
        pendingRequest = (cmd: cmd, sequence: sentSequence)
        receivedResponse = nil
        RunLoopPump.pump(until: deadline, shouldStop: { self.receivedResponse != nil })
        let response = receivedResponse
        pendingRequest = nil
        receivedResponse = nil

        guard let response else {
            log(String(format: "RX 0x%04X seq=0x%02X timeout after %.1fs", cmd, sentSequence, limit))
            return QueryOutcome(requestCmd: cmd, requestSequence: sentSequence, responseSequence: nil, status: nil, payload: [], outcome: .timedOut)
        }
        // A response without a status byte is not an acknowledgement; it must never read as ok.
        switch ResponseCorrelation.classify(response) {
        case .missing:
            return QueryOutcome(requestCmd: cmd, requestSequence: sentSequence, responseSequence: response.sequence, status: nil, payload: response.payload, outcome: .malformedResponse("响应 payload 为空，无 status 字段"))
        case .rejected(let status):
            return QueryOutcome(requestCmd: cmd, requestSequence: sentSequence, responseSequence: response.sequence, status: status, payload: response.payload, outcome: .rejected(status: status))
        case .ok(let status):
            return QueryOutcome(requestCmd: cmd, requestSequence: sentSequence, responseSequence: response.sequence, status: status, payload: response.payload, outcome: .ok)
        }
    }

    /// A scalar write: one value goes out, the same value is read back through a query.
    public struct ScalarWrite {
        public enum Kind {
            case noiseReduction
            case equalizer
            case spatial
        }

        public let kind: Kind
        public let writeCommand: UInt16
        public let writePayload: [UInt8]
        public let verifyCommand: UInt16
        public let verifyPayload: [UInt8]
        public let target: UInt32
        public let label: String

        public init(
            kind: Kind,
            writeCommand: UInt16,
            writePayload: [UInt8],
            verifyCommand: UInt16,
            verifyPayload: [UInt8],
            target: UInt32,
            label: String
        ) {
            self.kind = kind
            self.writeCommand = writeCommand
            self.writePayload = writePayload
            self.verifyCommand = verifyCommand
            self.verifyPayload = verifyPayload
            self.target = target
            self.label = label
        }
    }

    /// Writes one value and verifies it by reading the same value back.
    ///
    /// Shared by every setter so the rules live in one place: the command must be in the allowed
    /// write set, exactly one transaction may be in flight, every wait is bounded, and success
    /// requires an ACK with status 0 **and** a readback equal to the target. A value the device
    /// normalises to a known alias of the target is reported as `normalized`, never as success.
    public func setScalar(
        _ write: ScalarWrite,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        onReadback: ((Frame) -> Void)? = nil
    ) -> TransactionResult {
        let limit = timeout ?? defaultTimeout

        guard EncoCommand.allowedWriteCommands.contains(write.writeCommand) else {
            let result = failure(write, sequence: 0, outcome: .notSent(reason: "命令 0x\(String(format: "%04X", write.writeCommand)) 不在允许的写入集合内"), detail: "命令不在允许的写入集合内，未发送")
            lastOutcome = result
            return result
        }

        let ack = query(cmd: write.writeCommand, payload: write.writePayload, timeout: limit)
        switch ack.outcome {
        case .notSent(let reason):
            let result = failure(write, sequence: ack.requestSequence, outcome: .notSent(reason: reason), detail: reason)
            lastOutcome = result
            return result
        case .timedOut:
            let result = failure(
                write,
                sequence: ack.requestSequence,
                outcome: .timedOut,
                detail: String(format: "0x%04X 未在 %.1fs 内返回 ACK（未确认设备是否接受该写入）", write.writeCommand, limit)
            )
            lastOutcome = result
            return result
        case .rejected(let status):
            let result = TransactionResult(
                requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
                requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: status,
                querySequence: nil, readbackRaw: nil, targetRaw: write.target,
                outcome: .rejected(status: status),
                detail: String(format: "ACK status=%u，设备拒绝该写入（未做 readback）", status)
            )
            lastOutcome = result
            return result
        case .malformedResponse(let reason):
            let result = TransactionResult(
                requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
                requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: nil,
                querySequence: nil, readbackRaw: nil, targetRaw: write.target,
                outcome: .malformedResponse(reason),
                detail: "ACK 无 status 字段（\(reason)），不视为成功"
            )
            lastOutcome = result
            return result
        case .ok:
            break
        }

        // The device needs a moment before it reports the new value.
        RunLoopPump.pump(for: settle)

        let deadline = Date().addingTimeInterval(readbackBudget)
        var readback: UInt32?
        var lastQuerySequence: UInt8?
        var lastFailure: String?
        var attempts = 0
        while true {
            attempts += 1
            let verify = query(cmd: write.verifyCommand, payload: write.verifyPayload, timeout: limit)
            lastQuerySequence = verify.requestSequence
            switch verify.outcome {
            case .ok:
                let frame = Frame(
                    cmd: ResponseCorrelation.responseCommand(for: write.verifyCommand),
                    sequence: verify.responseSequence ?? 0,
                    payload: verify.payload,
                    raw: []
                )
                onReadback?(frame)
                if let value = extract(write, from: frame) {
                    readback = value
                    lastFailure = nil
                } else {
                    lastFailure = "读取回包无法解析为\(write.label)值：\(Hex.string(verify.payload))"
                }
            case .timedOut:
                lastFailure = "读取\(write.label)的查询超时"
            case .rejected(let status):
                lastFailure = "读取\(write.label)返回 status=\(status)"
            case .malformedResponse(let reason):
                lastFailure = "读取\(write.label)的响应无 status 字段（\(reason)）"
            case .notSent(let reason):
                lastFailure = "读取查询未发出：\(reason)"
            }

            if readback == write.target { break }
            guard Date() < deadline else { break }
            RunLoopPump.pump(for: 0.5)
        }

        guard let readback else {
            let result = TransactionResult(
                requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
                requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: ack.status,
                querySequence: lastQuerySequence, readbackRaw: nil, targetRaw: write.target,
                outcome: .readbackMismatch,
                detail: "写入 ACK 成功，但 \(attempts) 次读取都未得到\(write.label)值：\(lastFailure ?? "无响应")"
            )
            lastOutcome = result
            return result
        }

        let outcome: TransactionResult.Outcome
        let detail: String
        if readback == write.target {
            outcome = .verified
            detail = String(format: "ACK status=0，回读 0x%08X 与目标一致（%d 次读取）", readback, attempts)
        } else if let alias = aliasOfTarget(write, raw: readback) {
            outcome = .normalized
            detail = String(
                format: "ACK status=0，但回读为 0x%08X（%@，与目标 0x%08X 不等价）——设备可能归一化父/子值，未当成功（%d 次读取）",
                readback, alias, write.target, attempts
            )
        } else {
            outcome = .readbackMismatch
            detail = String(format: "ACK status=0，但回读为 0x%08X，与目标 0x%08X 无关——未当成功（%d 次读取）", readback, write.target, attempts)
        }
        let result = TransactionResult(
            requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
            requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: ack.status,
            querySequence: lastQuerySequence, readbackRaw: readback, targetRaw: write.target,
            outcome: outcome, detail: detail
        )
        lastOutcome = result
        return result
    }

    @MainActor
    public func setScalarAsync(
        _ write: ScalarWrite,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        onReadback: ((Frame) -> Void)? = nil
    ) async -> TransactionResult {
        let limit = timeout ?? defaultTimeout

        guard EncoCommand.allowedWriteCommands.contains(write.writeCommand) else {
            let result = failure(write, sequence: 0, outcome: .notSent(reason: "命令 0x\(String(format: "%04X", write.writeCommand)) 不在允许的写入集合内"), detail: "命令不在允许的写入集合内，未发送")
            lastOutcome = result
            return result
        }

        let ack = await queryAsync(cmd: write.writeCommand, payload: write.writePayload, timeout: limit)
        switch ack.outcome {
        case .notSent(let reason):
            let result = failure(write, sequence: ack.requestSequence, outcome: .notSent(reason: reason), detail: reason)
            lastOutcome = result
            return result
        case .timedOut:
            let result = failure(
                write,
                sequence: ack.requestSequence,
                outcome: .timedOut,
                detail: String(format: "0x%04X 未在 %.1fs 内返回 ACK（未确认设备是否接受该写入）", write.writeCommand, limit)
            )
            lastOutcome = result
            return result
        case .rejected(let status):
            let result = TransactionResult(
                requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
                requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: status,
                querySequence: nil, readbackRaw: nil, targetRaw: write.target,
                outcome: .rejected(status: status),
                detail: String(format: "ACK status=%u，设备拒绝该写入（未做 readback）", status)
            )
            lastOutcome = result
            return result
        case .malformedResponse(let reason):
            let result = TransactionResult(
                requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
                requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: nil,
                querySequence: nil, readbackRaw: nil, targetRaw: write.target,
                outcome: .malformedResponse(reason),
                detail: "ACK 无 status 字段（\(reason)），不视为成功"
            )
            lastOutcome = result
            return result
        case .ok:
            break
        }

        // The device needs a moment before it reports the new value.
        try? await Task.sleep(nanoseconds: UInt64(max(0, settle) * 1_000_000_000))

        let deadline = Date().addingTimeInterval(readbackBudget)
        var readback: UInt32?
        var lastQuerySequence: UInt8?
        var lastFailure: String?
        var attempts = 0
        while true {
            attempts += 1
            let verify = await queryAsync(cmd: write.verifyCommand, payload: write.verifyPayload, timeout: limit)
            lastQuerySequence = verify.requestSequence
            switch verify.outcome {
            case .ok:
                let frame = Frame(
                    cmd: ResponseCorrelation.responseCommand(for: write.verifyCommand),
                    sequence: verify.responseSequence ?? 0,
                    payload: verify.payload,
                    raw: []
                )
                onReadback?(frame)
                if let value = extract(write, from: frame) {
                    readback = value
                    lastFailure = nil
                } else {
                    lastFailure = "读取回包无法解析为\(write.label)值：\(Hex.string(verify.payload))"
                }
            case .timedOut:
                lastFailure = "读取\(write.label)的查询超时"
            case .rejected(let status):
                lastFailure = "读取\(write.label)返回 status=\(status)"
            case .malformedResponse(let reason):
                lastFailure = "读取\(write.label)的响应无 status 字段（\(reason)）"
            case .notSent(let reason):
                lastFailure = "读取查询未发出：\(reason)"
            }

            if readback == write.target { break }
            guard !cancelled, !Task.isCancelled, Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        guard let readback else {
            let result = TransactionResult(
                requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
                requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: ack.status,
                querySequence: lastQuerySequence, readbackRaw: nil, targetRaw: write.target,
                outcome: .readbackMismatch,
                detail: "写入 ACK 成功，但 \(attempts) 次读取都未得到\(write.label)值：\(lastFailure ?? "无响应")"
            )
            lastOutcome = result
            return result
        }

        let outcome: TransactionResult.Outcome
        let detail: String
        if readback == write.target {
            outcome = .verified
            detail = String(format: "ACK status=0，回读 0x%08X 与目标一致（%d 次读取）", readback, attempts)
        } else if let alias = aliasOfTarget(write, raw: readback) {
            outcome = .normalized
            detail = String(
                format: "ACK status=0，但回读为 0x%08X（%@，与目标 0x%08X 不等价）——设备可能归一化父/子值，未当成功（%d 次读取）",
                readback, alias, write.target, attempts
            )
        } else {
            outcome = .readbackMismatch
            detail = String(format: "ACK status=0，但回读为 0x%08X，与目标 0x%08X 无关——未当成功（%d 次读取）", readback, write.target, attempts)
        }
        let result = TransactionResult(
            requestCommand: write.writeCommand, requestSequence: ack.requestSequence,
            requestPayload: write.writePayload, ackSequence: ack.responseSequence, ackStatus: ack.status,
            querySequence: lastQuerySequence, readbackRaw: readback, targetRaw: write.target,
            outcome: outcome, detail: detail
        )
        lastOutcome = result
        return result
    }

    private func failure(_ write: ScalarWrite, sequence: UInt8, outcome: TransactionResult.Outcome, detail: String) -> TransactionResult {
        TransactionResult(
            requestCommand: write.writeCommand, requestSequence: sequence, requestPayload: write.writePayload,
            ackSequence: nil, ackStatus: nil, querySequence: nil, readbackRaw: nil, targetRaw: write.target,
            outcome: outcome, detail: detail
        )
    }

    /// Reads the scalar the write is about, reusing the same parsers as the read path.
    private func extract(_ write: ScalarWrite, from frame: Frame) -> UInt32? {
        var scratch = DeviceState()
        ResponseParser.apply(frame, to: &scratch)
        switch write.kind {
        case .noiseReduction:
            return scratch.noiseReductionRawValue
        case .equalizer:
            return scratch.equalizerPresetID.map { UInt32($0) }
        case .spatial:
            return scratch.spatialType.map { UInt32($0) }
        }
    }

    /// A readback that is a known alias of the target, so it can be reported as normalised
    /// rather than unexplained. Only the noise-reduction profile has aliases today.
    private func aliasOfTarget(_ write: ScalarWrite, raw: UInt32) -> String? {
        guard write.kind == .noiseReduction else { return nil }
        let interpretation = X3Profile.interpretation(ofBitmap: raw)
        guard interpretation.matchedBitmap == write.target else { return nil }
        return interpretation.text
    }

    /// Set the noise-reduction bitmap, then read it back. Restoring a captured value such as
    /// `0x08` sends `08`; the parent value is never substituted.
    public func setNoiseReduction(
        bitmap: UInt32,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        readback: ((Frame) -> Void)? = nil
    ) -> TransactionResult {
        setScalar(
            ScalarWrite(
                kind: .noiseReduction,
                writeCommand: EncoCommand.setNoiseReduction.rawValue,
                writePayload: EncoPayload.noiseReductionSet(bitmap: bitmap),
                verifyCommand: EncoCommand.queryNoiseReduction.rawValue,
                verifyPayload: EncoPayload.noiseReductionCurrent,
                target: bitmap,
                label: "降噪"
            ),
            timeout: timeout,
            readbackBudget: readbackBudget,
            settle: settle,
            onReadback: readback
        )
    }

    /// Switch equalizer preset, then read the current preset back.
    public func setEqualizer(
        id: Int,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        readback: ((Frame) -> Void)? = nil
    ) -> TransactionResult {
        setScalar(
            ScalarWrite(
                kind: .equalizer,
                writeCommand: EncoCommand.setEqualizer.rawValue,
                writePayload: EncoPayload.equalizerSet(id: id),
                verifyCommand: EncoCommand.queryEqualizer.rawValue,
                verifyPayload: EncoPayload.empty,
                target: UInt32(id),
                label: "EQ 预设"
            ),
            timeout: timeout,
            readbackBudget: readbackBudget,
            settle: settle,
            onReadback: readback
        )
    }

    /// Set the earbud-side spatial audio type, then read it back.
    public func setSpatial(
        type: Int,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        readback: ((Frame) -> Void)? = nil
    ) -> TransactionResult {
        setScalar(
            ScalarWrite(
                kind: .spatial,
                writeCommand: EncoCommand.setSpatialAudio.rawValue,
                writePayload: EncoPayload.spatialSet(type: type),
                verifyCommand: EncoCommand.querySpatial.rawValue,
                verifyPayload: EncoPayload.spatialCurrent,
                target: UInt32(type),
                label: "空间音效"
            ),
            timeout: timeout,
            readbackBudget: readbackBudget,
            settle: settle,
            onReadback: readback
        )
    }

    @MainActor
    public func setNoiseReductionAsync(
        bitmap: UInt32,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        readback: ((Frame) -> Void)? = nil
    ) async -> TransactionResult {
        await setScalarAsync(
            ScalarWrite(
                kind: .noiseReduction,
                writeCommand: EncoCommand.setNoiseReduction.rawValue,
                writePayload: EncoPayload.noiseReductionSet(bitmap: bitmap),
                verifyCommand: EncoCommand.queryNoiseReduction.rawValue,
                verifyPayload: EncoPayload.noiseReductionCurrent,
                target: bitmap,
                label: "降噪"
            ),
            timeout: timeout,
            readbackBudget: readbackBudget,
            settle: settle,
            onReadback: readback
        )
    }

    /// Switch equalizer preset, then read the current preset back.
    @MainActor
    public func setEqualizerAsync(
        id: Int,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        readback: ((Frame) -> Void)? = nil
    ) async -> TransactionResult {
        await setScalarAsync(
            ScalarWrite(
                kind: .equalizer,
                writeCommand: EncoCommand.setEqualizer.rawValue,
                writePayload: EncoPayload.equalizerSet(id: id),
                verifyCommand: EncoCommand.queryEqualizer.rawValue,
                verifyPayload: EncoPayload.empty,
                target: UInt32(id),
                label: "EQ 预设"
            ),
            timeout: timeout,
            readbackBudget: readbackBudget,
            settle: settle,
            onReadback: readback
        )
    }

    /// Set the earbud-side spatial audio type, then read it back.
    @MainActor
    public func setSpatialAsync(
        type: Int,
        timeout: TimeInterval? = nil,
        readbackBudget: TimeInterval = 4,
        settle: TimeInterval = 0.2,
        readback: ((Frame) -> Void)? = nil
    ) async -> TransactionResult {
        await setScalarAsync(
            ScalarWrite(
                kind: .spatial,
                writeCommand: EncoCommand.setSpatialAudio.rawValue,
                writePayload: EncoPayload.spatialSet(type: type),
                verifyCommand: EncoCommand.querySpatial.rawValue,
                verifyPayload: EncoPayload.spatialCurrent,
                target: UInt32(type),
                label: "空间音效"
            ),
            timeout: timeout,
            readbackBudget: readbackBudget,
            settle: settle,
            onReadback: readback
        )
    }

    private func log(_ text: String) {
        onLog?(text)
    }
}
