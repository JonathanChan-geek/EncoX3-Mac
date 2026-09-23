import Foundation
import Dispatch
import EncoCore
import EncoBluetooth

/// `cycle-anc`: walk the X3 noise-reduction candidates with a serial write-then-readback
/// transaction for each, and always put the captured value back.
///
/// Safety rules enforced here:
/// - nothing is written until the PID is verified as `067410` and a fresh ANC bitmap was read;
/// - the original bitmap is on disk (journal) before the first write;
/// - a write counts as successful only when the ACK has status 0 *and* the readback matches;
///   a readback the device normalised to a parent/child value is reported, never as success;
/// - any failure stops the walk and goes straight to the restore step;
/// - SIGINT/SIGTERM only set a flag that the main loop notices, so the restore still runs.
enum CycleAncCommand {
    enum ArgumentError: Error, CustomStringConvertible {
        case journalMustBeAbsolute(String)
        case unknown(String)
        case missingValue(String)

        var description: String {
            switch self {
            case .journalMustBeAbsolute(let path): return "--journal 需要绝对路径，收到 '\(path)'"
            case .unknown(let value): return "未知参数 '\(value)'"
            case .missingValue(let flag): return "'\(flag)' 需要一个值"
            }
        }
    }

    static func run(arguments: [String]) -> Int32 {
        let journalURL: URL
        do {
            journalURL = try parseArguments(arguments)
        } catch {
            print("FATAL: \(error)")
            print("usage: encoctl cycle-anc [--journal /absolute/path.json]")
            return 2
        }

        Diagnostics.printEnvironment()
        print("mode: cycle-anc（写测试：仅 0x0404 降噪位图设置 + 逐项回读）")
        print("journal: \(journalURL.path)")
        print("cycle order: \(X3Profile.cycleOrder.map { String(format: "0x%02X", $0) }.joined(separator: ", "))")
        print("")

        guard let target = EncoDeviceLocator.target() else {
            print("FATAL: 没有已连接的 '\(EncoDeviceLocator.targetName)'")
            if EncoDeviceLocator.pairedDevices().isEmpty {
                Diagnostics.reportMissingDevices()
            }
            return 3
        }

        let transport = RFCOMMTransport(device: target)
        let transactions = TransactionController(transport: transport, defaultTimeout: 4)
        var state = DeviceState()
        let interrupted = InterruptFlag.install()

        transport.onLog = { print("[\(Timestamp.now())] \($0)") }
        transport.onState = { print("[\(Timestamp.now())] LINK state=\($0)") }
        transport.onFrame = { frame in
            ResponseParser.apply(frame, to: &state)
            transactions.accept(frame)
        }
        transactions.onLog = { print("[\(Timestamp.now())] \($0)") }

        print("--- open ---")
        do {
            try transport.open(sdpTimeout: 10, openTimeout: 12)
        } catch {
            print("FATAL: vendor control channel 不可用：\(error)")
            return 4
        }
        print("channel open: channelID=\(transport.channelID.map(String.init) ?? "?") device=\(transport.maskedAddress)")
        print("")

        print("--- 前置只读检查（未写任何设置） ---")
        // The protocol needs the capability query first: every working session in the captured
        // evidence begins with 0x0100, which is what brings the notifications up. This is a
        // read-only query, not an authentication frame.
        let hello = transactions.query(cmd: EncoCommand.capability.rawValue)
        print("hello 0x0100（能力查询，仅激活协议）: outcome=\(hello.outcome)")
        guard hello.outcome == .ok else {
            print("FATAL: capability 查询未得到 status=0 响应，未写入任何设置")
            transport.close()
            return 3
        }

        let pid = transactions.query(cmd: EncoCommand.queryProductID.rawValue)
        guard pid.outcome == .ok, state.productID == X3Profile.productID else {
            print("FATAL: PID 校验失败（read=\(state.productID ?? "<none>")，要求 \(X3Profile.productID)），未写入任何设置")
            transport.close()
            return 3
        }
        print("PID: \(state.productID ?? "?") ✓")

        let anc = transactions.query(
            cmd: EncoCommand.queryNoiseReduction.rawValue,
            payload: EncoPayload.noiseReductionCurrent
        )
        guard anc.outcome == .ok, let originalBitmap = state.noiseReductionRawValue else {
            print("FATAL: 无法读取当前 ANC 原始值（outcome=\(anc.outcome)），未写入任何设置")
            transport.close()
            return 3
        }
        let originalPayload = state.noiseReductionRawPayload ?? []
        print("ANC 原始位图: \(String(format: "0x%08X", originalBitmap))  payload=\(Hex.string(originalPayload))")
        print("  型号配置解释: \(X3Profile.interpretation(ofBitmap: originalBitmap).text)")

        _ = transactions.query(cmd: EncoCommand.queryBattery.rawValue)
        print("电量: \(state.describeBattery())")
        print("")

        // Journal before any write.
        var journal = AncJournal(
            createdAt: Timestamp.now(),
            deviceName: EncoDeviceLocator.targetName(for: target),
            maskedAddress: AddressMask.mask(target.addressString),
            productID: state.productID,
            originalBitmap: originalBitmap,
            originalPayloadHex: Hex.string(originalPayload),
            originalSource: state.noiseReductionSource ?? "0x810C",
            batteryAtStart: state.describeBattery(),
            steps: [],
            restoredAt: nil,
            restoreVerified: nil,
            restoreDetail: nil,
            finishedAt: nil
        )
        do {
            try journal.write(to: journalURL)
            print("恢复日志已落盘（写之前）: \(journalURL.path)")
        } catch {
            print("FATAL: 无法写入恢复日志 \(journalURL.path)：\(error)，未写入任何设置")
            transport.close()
            return 3
        }
        print("")

        var stopReason: String?
        print("--- 写测试循环（每项 ACK + readback） ---")
        for target in X3Profile.cycleOrder {
            if interrupted.value {
                stopReason = "收到中断信号"
                print("!! 收到 SIGINT/SIGTERM，转入恢复流程（不提前退出）")
                break
            }
            guard state.noiseReductionIsFresh() else {
                stopReason = "ANC 读数已过期（>\(Int(DeviceState.freshnessWindow))s），停止写测试"
                print("!! \(stopReason ?? "")")
                break
            }
            let spec = X3Profile.spec(bitmap: target)
            print(String(format: ">>> 目标 %@ 0x%02X payload=%@", spec?.label ?? "?", target, Hex.string(EncoPayload.noiseReductionSet(bitmap: target))))

            let result = transactions.setNoiseReduction(bitmap: target)
            var step = AncJournal.Step(
                requestedBitmap: target,
                requestSequence: result.requestSequence,
                ackSequence: result.ackSequence,
                ackStatus: result.ackStatus,
                readbackBitmap: result.readbackRaw,
                outcome: "\(result.outcome)",
                detail: result.detail,
                at: Timestamp.now()
            )
            print(String(
                format: "    reqSeq=0x%02X ackSeq=%@ ackStatus=%@ querySeq=%@ readback=%@ outcome=%@",
                result.requestSequence,
                result.ackSequence.map { String(format: "0x%02X", $0) } ?? "<none>",
                result.ackStatus.map { "\($0)" } ?? "<none>",
                result.querySequence.map { String(format: "0x%02X", $0) } ?? "<none>",
                result.readbackRaw.map { String(format: "0x%08X", $0) } ?? "<none>",
                "\(result.outcome)"
            ))
            print("    \(result.detail)")

            switch result.outcome {
            case .verified:
                print("    结果: 写入并回读一致 ✓（听感未验证）")
            case .normalized:
                print("    结果: 设备归一化/子项别名，未当成功（继续下一项）")
                step.outcome = "normalized"
            case .readbackMismatch:
                stopReason = "回读与目标无关：\(result.detail)"
            case .rejected(let status):
                stopReason = "ACK status=\(status)"
            case .malformedResponse(let reason):
                stopReason = "ACK 无 status 字段：\(reason)"
            case .timedOut:
                stopReason = "ACK 或回读超时"
            case .notSent(let reason):
                stopReason = "发送失败：\(reason)"
            }
            journal.steps.append(step)
            try? journal.write(to: journalURL)

            if let stopReason {
                print("!! 失败停止: \(stopReason)")
                break
            }
            // Keep consecutive mode switches apart so the headset is not driven faster than a
            // human could; bounded, and skipped when the loop is about to end anyway.
            if target != X3Profile.cycleOrder.last {
                RunLoopPump.pump(for: 1.0)
            }
        }
        if stopReason == nil { print("所有候选项均已走完（含归一化项）") }
        print("")

        print("--- 恢复原始位图 \(String(format: "0x%08X", originalBitmap))（payload=\(Hex.string(EncoPayload.noiseReductionSet(bitmap: originalBitmap)))） ---")
        let restore = transactions.setNoiseReduction(bitmap: originalBitmap)
        print(String(
            format: "    reqSeq=0x%02X ackSeq=%@ ackStatus=%@ querySeq=%@ readback=%@ outcome=%@",
            restore.requestSequence,
            restore.ackSequence.map { String(format: "0x%02X", $0) } ?? "<none>",
            restore.ackStatus.map { "\($0)" } ?? "<none>",
            restore.querySequence.map { String(format: "0x%02X", $0) } ?? "<none>",
            restore.readbackRaw.map { String(format: "0x%08X", $0) } ?? "<none>",
            "\(restore.outcome)"
        ))
        print("    \(restore.detail)")

        journal.restoredAt = Timestamp.now()
        journal.restoreVerified = (restore.outcome == .verified)
        journal.restoreDetail = restore.detail
        journal.finishedAt = Timestamp.now()
        try? journal.write(to: journalURL)

        transport.close()

        if restore.outcome == .verified {
            print("恢复验证通过：回读 \(String(format: "0x%08X", restore.readbackRaw ?? 0)) 与原始值一致。")
            print("journal: \(journalURL.path)（保留，含本次全部步骤）")
        } else {
            print("!! 恢复未验证：\(restore.detail)")
            print("!! 原始值保存在 \(journalURL.path)，未删除；请人工核对耳机状态。")
        }
        if let stopReason { print("停止原因: \(stopReason)") }
        print("")

        if restore.outcome != .verified { return 1 }
        if stopReason != nil { return 6 }
        return 0
    }

    private static func parseArguments(_ arguments: [String]) throws -> URL {
        var journal: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--journal" {
                guard index + 1 < arguments.count else { throw ArgumentError.missingValue("--journal") }
                journal = try absoluteURL(arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix("--journal=") {
                journal = try absoluteURL(String(argument.dropFirst("--journal=".count)))
                index += 1
                continue
            }
            throw ArgumentError.unknown(argument)
        }
        return journal ?? AncJournal.defaultURL()
    }

    private static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw ArgumentError.journalMustBeAbsolute(path) }
        return URL(fileURLWithPath: path)
    }
}

/// Set from a dispatch source, read by the main loop.
final class InterruptFlag {
    private(set) var value = false

    func set() {
        value = true
    }

    /// Installs SIGINT/SIGTERM handlers that only flip this flag, so the current step can
    /// finish and the restore still runs. `exit()` is never called from the handler.
    static func install() -> InterruptFlag {
        let flag = InterruptFlag()
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { flag.set() }
            source.resume()
            sources.append(source)
        }
        return flag
    }

    private static var sources: [DispatchSourceSignal] = []
}
