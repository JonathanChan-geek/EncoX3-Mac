import Foundation
import IOBluetooth
import EncoCore
import EncoBluetooth

/// Bounded read-only probe: opens the vendor RFCOMM channel, listens, sends the capability
/// query once plus one round of the documented read-only queries, then leaves the rest of
/// the window for replies. Nothing else is written to the device.
enum ProbeCommand {
    static let defaultSeconds: TimeInterval = 20
    static let minimumSeconds: TimeInterval = 3
    static let maximumSeconds: TimeInterval = 120
    static let passiveWindow: TimeInterval = 2
    static let sendInterval: TimeInterval = 0.5

    enum ArgumentError: Error, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case invalidSeconds(String)

        var description: String {
            switch self {
            case .unknown(let value): return "unknown argument '\(value)'"
            case .missingValue(let flag): return "'\(flag)' needs a value"
            case .invalidSeconds(let value):
                return "'\(value)' is not a number of seconds between \(Int(minimumSeconds)) and \(Int(maximumSeconds))"
            }
        }
    }

    static func run(arguments: [String]) -> Int32 {
        let seconds: TimeInterval
        do {
            seconds = try parseSeconds(arguments)
        } catch {
            print("FATAL: \(error)")
            print("usage: encoctl probe [--seconds N]   (N between \(Int(minimumSeconds)) and \(Int(maximumSeconds)), default \(Int(defaultSeconds)))")
            return 2
        }

        Diagnostics.printEnvironment()
        print("mode: read-only probe")
        print("seconds: \(Int(seconds))  passive window: \(Int(passiveWindow))s  query interval: \(sendInterval)s")
        print("")

        let paired = EncoDeviceLocator.pairedDevices()
        print("paired device count: \(paired.count)")
        for device in EncoDeviceLocator.connectedDevices() {
            print("connected: \(EncoDeviceLocator.targetName(for: device))  [\(AddressMask.mask(device.addressString))]")
        }
        print("")

        guard let target = EncoDeviceLocator.target() else {
            print("FATAL: no connected paired device named '\(EncoDeviceLocator.targetName)'")
            if paired.isEmpty {
                Diagnostics.reportMissingDevices()
            } else {
                print("connected paired names: \(EncoDeviceLocator.connectedDevices().map { EncoDeviceLocator.targetName(for: $0) }.joined(separator: ", "))")
                print("this tool never connects or pages a device; connect the headset in Bluetooth settings first")
            }
            return 3
        }

        let transport = RFCOMMTransport(device: target)
        var frames: [Frame] = []
        var state = DeviceState()
        var txCount = 0

        transport.onLog = { print("[\(Timestamp.now())] \($0)") }
        transport.onState = { print("[\(Timestamp.now())] LINK state=\($0)") }
        transport.onRawReceive = { chunk in
            print("[\(Timestamp.now())] RX chunk \(chunk.count)B \(Hex.string(chunk))")
        }
        transport.onFrame = { frame in
            frames.append(frame)
            ResponseParser.apply(frame, to: &state)
            print("[\(Timestamp.now())] FRAME cmd=0x\(String(format: "%04X", frame.cmd)) seq=0x\(String(format: "%02X", frame.sequence)) payloadLen=\(frame.payload.count) payload=\(frame.payloadHex)")
        }

        print("--- open ---")
        do {
            try transport.open(sdpTimeout: 10, openTimeout: 12)
        } catch {
            print("FATAL: vendor control channel unavailable: \(error)")
            print("device connection state: \(target.isConnected())")
            return 4
        }
        print("channel open: channelID=\(transport.channelID.map(String.init) ?? "?") device=\(transport.maskedAddress)")
        print("")

        let start = Date()
        let deadline = start.addingTimeInterval(seconds)

        func send(_ query: ReadOnlyQuery) {
            do {
                let sent = try transport.send(cmd: query.cmd, payload: query.payload)
                txCount += 1
                print("[\(Timestamp.now())] TX \(query.label) cmd=0x\(String(format: "%04X", sent.cmd)) seq=0x\(String(format: "%02X", sent.sequence)) payload=\(Hex.string(query.payload)) raw=\(Hex.string(sent.raw))")
            } catch {
                print("[\(Timestamp.now())] TX FAILED \(query.label): \(error)")
            }
        }

        print("--- passive listen \(Int(passiveWindow))s ---")
        RunLoopPump.pump(until: min(start.addingTimeInterval(passiveWindow), deadline))
        print("frames so far: \(frames.count)")
        print("")

        print("--- one round of read-only queries (capability query first) ---")
        var nextSendAt = Date()
        for query in [ReadOnlyQueries.hello] + ReadOnlyQueries.rotation {
            guard Date() < deadline else {
                print("deadline reached before \(query.label); stopping the round")
                break
            }
            RunLoopPump.pump(until: min(nextSendAt, deadline))
            send(query)
            nextSendAt = Date().addingTimeInterval(sendInterval)
        }

        print("")
        print("--- receive window until deadline ---")
        RunLoopPump.pump(until: deadline)
        print("frames after receive window: \(frames.count)")

        transport.close()
        let elapsed = Date().timeIntervalSince(start)

        print("")
        print("=== probe summary ===")
        print("elapsed: \(String(format: "%.1f", elapsed))s")
        print("tx frames: \(txCount)")
        print("rx chunks: \(transport.receiveChunkCount)  rx bytes: \(transport.receivedByteCount)")
        print("rx frames: \(frames.count)  parser rejected: \(transport.parser.rejectedFrameCount)  parser garbage bytes: \(transport.parser.discardedByteCount)")
        print("write failures: \(transport.writeFailureCount)  pending writes at exit: \(transport.pendingWriteCount)")
        print("channel state after close: \(transport.state)  closed unexpectedly: \(transport.didCloseUnexpectedly)")
        print("")

        print("--- response commands seen ---")
        if state.rawResponses.isEmpty {
            print("<none>")
        } else {
            for cmd in state.rawResponses.keys.sorted() {
                let count = frames.filter { $0.cmd == cmd }.count
                print("0x\(String(format: "%04X", cmd)): \(count) frame(s)  last payload=\(Hex.string(state.rawResponses[cmd] ?? []))")
            }
        }
        print("")

        print("--- parsed state (per-field freshness) ---")
        print("productID: \(state.productID ?? "<unknown>")  updated: \(timestamp(state.productIDUpdatedAt))")
        print("firmwareVersion: \(state.firmwareVersion ?? "<unknown>")  updated: \(timestamp(state.firmwareVersionUpdatedAt))")
        print("battery: \(state.describeBattery())  updated: \(timestamp(state.batteryUpdatedAt))")
        if let value = state.noiseReductionRawValue {
            print("noiseReductionRawValue: 0x\(String(format: "%08X", value)) (raw bitmap, no mode naming applied) source=\(state.noiseReductionSource ?? "?") updated: \(timestamp(state.noiseReductionUpdatedAt))")
        } else {
            print("noiseReductionRawValue: <unknown>  updated: <never>")
        }
        print("capabilityBitmap: \(state.capabilityBitString ?? "<unknown>")  updated: \(timestamp(state.capabilityUpdatedAt))")
        print("last response at: \(timestamp(state.lastResponseAt))  responses: \(state.responseCount)")
        if !state.statusFailures.isEmpty {
            print("status failures (recorded, not applied):")
            for cmd in state.statusFailures.keys.sorted() {
                print("  0x\(String(format: "%04X", cmd)): status=\(state.statusFailures[cmd] ?? 0)")
            }
        }
        if !state.unparsedPayloads.isEmpty {
            print("payloads kept raw (layout not recognised):")
            for cmd in state.unparsedPayloads.keys.sorted() {
                print("  0x\(String(format: "%04X", cmd)): \(Hex.string(state.unparsedPayloads[cmd] ?? []))")
            }
        }
        print("")

        if frames.isEmpty {
            print("RESULT: no frames received")
            if transport.receivedByteCount == 0 {
                print("diagnosis: the channel opened but the device sent nothing; it may be idle, or the")
                print("control service may only speak after the companion app's handshake.")
            } else {
                print("diagnosis: bytes arrived but no valid frame was parsed; see the RX chunks above.")
            }
            return 5
        }
        print("RESULT: \(frames.count) frame(s) received")
        return 0
    }

    private static func timestamp(_ date: Date?) -> String {
        date.map { Timestamp.formatted($0) } ?? "<never>"
    }

    static func parseSeconds(_ arguments: [String]) throws -> TimeInterval {
        var value: TimeInterval?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--seconds" {
                guard index + 1 < arguments.count else { throw ArgumentError.missingValue("--seconds") }
                value = try seconds(from: arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--seconds=") {
                value = try seconds(from: String(argument.dropFirst("--seconds=".count)))
                index += 1
                continue
            }
            throw ArgumentError.unknown(argument)
        }
        return value ?? defaultSeconds
    }

    private static func seconds(from text: String) throws -> TimeInterval {
        guard let parsed = TimeInterval(text), parsed.isFinite else {
            throw ArgumentError.invalidSeconds(text)
        }
        guard parsed >= minimumSeconds, parsed <= maximumSeconds else {
            throw ArgumentError.invalidSeconds(text)
        }
        return parsed
    }
}
