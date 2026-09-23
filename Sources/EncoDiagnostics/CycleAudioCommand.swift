import Foundation
import CoreAudio
import EncoCore
import EncoBluetooth

/// `cycle-audio`: walk the equalizer presets and the spatial audio modes with a serial
/// write-then-readback for each, then put every original value back.
///
/// Safety rules enforced here:
/// - nothing is written until the capability query, PID, current ANC, EQ, spatial and the full EQ
///   list have all been read successfully, and no unfinished restore record sits at the journal
///   path;
/// - the original values are on disk (one journal file) before the first SET;
/// - only these three commands are ever sent: `0x0404` (ANC bitmap), `0x0406` (EQ preset id),
///   `0x0422` (spatial type). Custom EQ curves are never written — only preset switching;
/// - a step counts as successful only with ACK status 0 **and** an exact readback match;
/// - any failure stops the walk and goes straight to the restore;
/// - after restoring, ANC, EQ preset, spatial type and the EQ curve are re-read independently and
///   compared with the originals — each result comes from that query's own response, never from
///   cached state. If that joint check fails, exactly one more restore round is attempted;
/// - SIGINT/SIGTERM only set a flag the main loop notices, so the restore still runs.
enum CycleAudioCommand {
    static let eqOrder = [0, 1, 2, 3, 7, 4]
    static let spatialOrder = [1, 2, 0]
    static let stepSpacing: TimeInterval = 1.0

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
        let listening = arguments.contains("--listen-spatial")
        let commandArguments = arguments.filter { $0 != "--listen-spatial" }
        let eqSequence = listening ? [] : eqOrder
        let spatialSequence = listening ? [1, 2] : spatialOrder
        let journalURL: URL
        do {
            journalURL = try parseArguments(commandArguments)
        } catch {
            print("FATAL: \(error)")
            print("usage: encoctl cycle-audio [--listen-spatial] [--journal /absolute/path.json]")
            return 2
        }

        // Do not play a listening stimulus to an unrelated output route, or silently change it.
        if listening, !ListeningOutput.isEncoDefaultOutput() {
            print("FATAL: 当前默认音频输出不是 Enco X3；请手动选择耳机后再测试。未连接控制通道、未改设置。")
            return 3
        }
        Diagnostics.printEnvironment()
        print("mode: cycle-audio（写测试：仅 0x0404 / 0x0406 / 0x0422，逐项 ACK + 回读）")
        print("journal: \(journalURL.path)")
        print("EQ 顺序: \(eqSequence)  空间顺序: \(spatialSequence)")
        print("")

        // Refuse to overwrite an unfinished record before touching the device at all: it holds
        // the only copy of the original values.
        if case .blocked(let reason) = AudioJournal.decideStart(existing: AudioJournal.Existing.inspect(journalURL)) {
            print("FATAL: \(reason)")
            print("未连接设备、未写入任何设置。")
            return 7
        }

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
            if listening, frame.cmd == EncoCommand.activeReport.rawValue {
                print("[\(Timestamp.now())] PASSIVE cmd=0204 payload=\(Hex.string(frame.payload))")
            }
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

        // ---- read-only prerequisites: nothing is written until all of these succeed ----
        print("--- 前置只读检查（未写任何设置） ---")
        let hello = transactions.query(cmd: EncoCommand.capability.rawValue)
        print("hello 0x0100（能力查询，仅激活协议）: outcome=\(hello.outcome)")
        guard hello.outcome == .ok else {
            print("FATAL: capability 查询未得到 status=0 响应，未写入任何设置")
            transport.close()
            return 3
        }

        _ = transactions.query(cmd: EncoCommand.queryProductID.rawValue)
        guard state.productID == X3Profile.productID else {
            print("FATAL: PID 校验失败（read=\(state.productID ?? "<none>")，要求 \(X3Profile.productID)），未写入任何设置")
            transport.close()
            return 3
        }
        print("PID: \(state.productID ?? "?") ✓")

        let ancRead = transactions.query(
            cmd: EncoCommand.queryNoiseReduction.rawValue,
            payload: EncoPayload.noiseReductionCurrent
        )
        guard ancRead.outcome == .ok, let originalAncBitmap = state.noiseReductionRawValue else {
            print("FATAL: 无法读取当前 ANC 原始值，未写入任何设置")
            transport.close()
            return 3
        }
        let originalAncPayload = state.noiseReductionRawPayload ?? []
        print(String(format: "ANC: 0x%08X payload=%@", originalAncBitmap, Hex.string(originalAncPayload)))

        guard transactions.query(cmd: EncoCommand.queryEqualizer.rawValue).outcome == .ok,
              let originalEqID = state.equalizerPresetID else {
            print("FATAL: 无法读取当前 EQ 预设，未写入任何设置")
            transport.close()
            return 3
        }
        print("EQ 当前预设: id=\(originalEqID) 名称=\(X3Profile.equalizerName(originalEqID, devicePresets: state.equalizerPresets)) 来源 \(X3Profile.equalizerNameSource(originalEqID, devicePresets: state.equalizerPresets).rawValue)")

        guard transactions.query(cmd: EncoCommand.querySpatial.rawValue).outcome == .ok,
              let originalSpatial = state.spatialType else {
            print("FATAL: 无法读取当前空间音效，未写入任何设置")
            transport.close()
            return 3
        }
        print("空间音效: \(X3Profile.spatialName(originalSpatial)) (type=\(originalSpatial))")

        let eqListRead = transactions.query(cmd: EncoCommand.queryEqAll.rawValue, payload: EncoPayload.eqAllQuery)
        guard eqListRead.outcome == .ok,
              let parsedList = EqPresetParser.parse(eqListRead.payload), !parsedList.presets.isEmpty else {
            print("FATAL: 无法读取/解析 EQ 列表（0x0122），未写入任何设置")
            transport.close()
            return 3
        }
        let originalEqList = parsedList.presets
        print("EQ 列表: \(originalEqList.count) 项 -> \(originalEqList.map { "\($0.id):\($0.name)" }.joined(separator: ", "))")
        print("")

        var journal = AudioJournal(
            createdAt: Timestamp.now(),
            deviceName: EncoDeviceLocator.targetName(for: target),
            maskedAddress: AddressMask.mask(target.addressString),
            productID: state.productID,
            originalAncBitmap: originalAncBitmap,
            originalAncPayloadHex: Hex.string(originalAncPayload),
            originalEqPresetID: originalEqID,
            originalSpatialType: originalSpatial,
            originalEqListPayloadHex: Hex.string(eqListRead.payload),
            originalEqList: originalEqList.map {
                AudioJournal.EqEntry(
                    id: $0.id, name: $0.name, isSelected: $0.isSelected,
                    minGain: Int($0.minGain), maxGain: Int($0.maxGain),
                    frequencies: $0.frequencies, gains: $0.gains.map { Int($0) }
                )
            },
            steps: [],
            restoreSteps: [],
            curveChecks: [],
            jointChecks: [],
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

        func step(_ label: String, _ result: TransactionResult) -> AudioJournal.Step {
            print(String(
                format: "    %@ reqSeq=0x%02X ackSeq=%@ ackStatus=%@ querySeq=%@ readback=%@ outcome=%@",
                label,
                result.requestSequence,
                result.ackSequence.map { String(format: "0x%02X", $0) } ?? "<none>",
                result.ackStatus.map { "\($0)" } ?? "<none>",
                result.querySequence.map { String(format: "0x%02X", $0) } ?? "<none>",
                result.readbackRaw.map { String(format: "0x%08X", $0) } ?? "<none>",
                "\(result.outcome)"
            ))
            print("      \(result.detail)")
            return AudioJournal.Step(
                label: label,
                requested: result.targetRaw,
                requestSequence: result.requestSequence,
                ackSequence: result.ackSequence,
                ackStatus: result.ackStatus,
                readback: result.readbackRaw,
                outcome: "\(result.outcome)",
                detail: result.detail,
                at: Timestamp.now()
            )
        }

        func failureReason(_ label: String, _ result: TransactionResult) -> String? {
            switch result.outcome {
            case .verified: return nil
            case .normalized: return "\(label) 回读被归一化"
            case .readbackMismatch: return "\(label) 回读与目标不一致"
            case .rejected(let status): return "\(label) ACK status=\(status)"
            case .malformedResponse(let reason): return "\(label) ACK 无 status：\(reason)"
            case .timedOut: return "\(label) 超时"
            case .notSent(let reason): return "\(label) 未发送：\(reason)"
            }
        }

        var stopReason: String?

        print("--- EQ 预设轮转 ---")
        for id in eqSequence {
            if interrupted.value {
                stopReason = "收到中断信号"
                print("!! 收到 SIGINT/SIGTERM，转入恢复流程")
                break
            }
            print(">>> EQ 预设 id=\(id)（\(X3Profile.equalizerName(id, devicePresets: state.equalizerPresets))，来源 \(X3Profile.equalizerNameSource(id, devicePresets: state.equalizerPresets).rawValue)）")
            let result = transactions.setEqualizer(id: id)
            journal.steps.append(step("EQ id=\(id)", result))
            try? journal.write(to: journalURL)
            if let reason = failureReason("EQ id=\(id)", result) {
                stopReason = reason
                print("!! 失败停止: \(reason)")
                break
            }
            print("      结果: 写入并回读一致 ✓（听感未验证）")
            RunLoopPump.pump(for: stepSpacing)
        }

        if stopReason == nil {
            print("")
            print("--- 空间音效轮转 ---")
            for type in spatialSequence {
                if interrupted.value {
                    stopReason = "收到中断信号"
                    print("!! 收到 SIGINT/SIGTERM，转入恢复流程")
                    break
                }
                print(">>> 空间音效 \(X3Profile.spatialName(type)) (type=\(type))")
                let result = transactions.setSpatial(type: type)
                journal.steps.append(step("空间 type=\(type)", result))
                try? journal.write(to: journalURL)
                if let reason = failureReason("空间 type=\(type)", result) {
                    stopReason = reason
                    print("!! 失败停止: \(reason)")
                    break
                }
                print("      结果: 写入并回读一致 ✓（听感未验证）")
                if listening {
                    guard ListeningOutput.isEncoDefaultOutput() else {
                        stopReason = "听感测试中输出设备改变，停止播放并恢复"
                        break
                    }
                    print("[\(Timestamp.now())] LISTEN stage=\(type) duration=20s")
                    fflush(stdout)
                    let speech = Process()
                    speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    let label = type == 1 ? "第一段，固定模式。" : "第二段，头部跟随模式。"
                    speech.arguments = ["-r", "150", label + "请先看向正前方。现在缓慢向左转头，再回到中间，然后向右转头。留意这段人声的位置。它是跟着你的头一起转，还是仍然停在你面前？请再慢慢重复一次。"]
                    do { try speech.run() }
                    catch { stopReason = "无法播放测试人声：\(error)"; break }
                    RunLoopPump.pump(until: Date().addingTimeInterval(20), shouldStop: {
                        interrupted.value || !ListeningOutput.isEncoDefaultOutput()
                    })
                    if speech.isRunning { speech.terminate(); speech.waitUntilExit() }
                    if interrupted.value || !ListeningOutput.isEncoDefaultOutput() {
                        stopReason = "测试被中断或输出改变，转入恢复"
                        break
                    }
                } else {
                    RunLoopPump.pump(for: stepSpacing)
                }
            }
        }
        if stopReason == nil { print("EQ 与空间音效轮转完成（声学结论须另记，不由 ACK 推断）") }
        print("")

        // ---- queries whose responses the verification is computed from ----
        func response(cmd: UInt16, payload: [UInt8], responseCommand: UInt16) -> ScalarReadback {
            let outcome = transactions.query(cmd: cmd, payload: payload)
            guard outcome.outcome == .ok else {
                return ScalarReadback(command: responseCommand, payload: nil)
            }
            return ScalarReadback(command: responseCommand, payload: outcome.payload)
        }

        func describe(_ verification: ScalarVerification) -> String {
            switch verification {
            case .matches(let value): return String(format: "匹配 0x%08X", value)
            case .differs(let expected, let got): return String(format: "不匹配：期望 0x%08X，实读 0x%08X", expected, got)
            case .unverified(let reason): return "未验证：\(reason)"
            }
        }

        func value(_ verification: ScalarVerification) -> UInt32? {
            switch verification {
            case .matches(let value): return value
            case .differs(_, let got): return got
            case .unverified: return nil
            }
        }

        // ---- restore ----
        func restoreRound(_ round: Int) -> Bool {
            var writesVerified = true
            print(">>> 恢复第 \(round) 轮写入")
            let eq = transactions.setEqualizer(id: originalEqID)
            journal.restoreSteps.append(step("恢复 EQ id=\(originalEqID)", eq))
            if eq.outcome != .verified { writesVerified = false }

            let spatial = transactions.setSpatial(type: originalSpatial)
            journal.restoreSteps.append(step("恢复 空间 type=\(originalSpatial)", spatial))
            if spatial.outcome != .verified { writesVerified = false }

            let anc = transactions.setNoiseReduction(bitmap: originalAncBitmap)
            journal.restoreSteps.append(step("恢复 ANC \(String(format: "0x%08X", originalAncBitmap))", anc))
            if anc.outcome != .verified { writesVerified = false }

            try? journal.write(to: journalURL)
            return writesVerified
        }

        /// Joint verification after all restore writes: every value is read again independently
        /// (a later write can disturb an earlier one) and compared with the exact original.
        func jointVerify(round: Int) -> Bool {
            let ancVerification = AudioVerification.noiseReduction(
                expected: originalAncBitmap,
                response: response(
                    cmd: EncoCommand.queryNoiseReduction.rawValue,
                    payload: EncoPayload.noiseReductionCurrent,
                    responseCommand: EncoCommand.noiseReductionResponse.rawValue
                )
            )
            let eqVerification = AudioVerification.equalizerPreset(
                expected: originalEqID,
                response: response(
                    cmd: EncoCommand.queryEqualizer.rawValue,
                    payload: EncoPayload.empty,
                    responseCommand: EncoCommand.equalizerResponse.rawValue
                )
            )
            let spatialVerification = AudioVerification.spatialType(
                expected: originalSpatial,
                response: response(
                    cmd: EncoCommand.querySpatial.rawValue,
                    payload: EncoPayload.empty,
                    responseCommand: EncoCommand.spatialResponse.rawValue
                )
            )
            let curveReadback = response(
                cmd: EncoCommand.queryEqAll.rawValue,
                payload: EncoPayload.eqAllQuery,
                responseCommand: EncoCommand.eqAllResponse.rawValue
            )
            let curve = AudioVerification.curve(original: originalEqList, response: curveReadback)

            let check = AudioJournal.JointCheck(
                checkedAt: Timestamp.now(),
                round: round,
                ancReadback: value(ancVerification),
                ancMatches: ancVerification.isMatch,
                ancNote: describe(ancVerification),
                eqReadback: value(eqVerification).map { Int($0) },
                eqMatches: eqVerification.isMatch,
                eqNote: describe(eqVerification),
                spatialReadback: value(spatialVerification).map { Int($0) },
                spatialMatches: spatialVerification.isMatch,
                spatialNote: describe(spatialVerification),
                curveUnchanged: curve.isUnchanged,
                curveVerified: curve.isVerified,
                curveNote: curve.note,
                allVerified: ancVerification.isMatch && eqVerification.isMatch && spatialVerification.isMatch && curve.isUnchanged
            )
            journal.jointChecks.append(check)
            journal.curveChecks.append(AudioJournal.CurveCheck(
                checkedAt: check.checkedAt,
                unchanged: curve.isUnchanged,
                verified: curve.isVerified,
                differences: { if case .changed(let differences) = curve { return differences } else { return [] } }(),
                note: curve.note,
                responsePayloadHex: Hex.string(curveReadback.payload ?? []),
                status: curveReadback.payload?.first
            ))
            print("联合验证（第 \(round) 轮）: ANC \(check.ancNote)；EQ \(check.eqNote)；空间 \(check.spatialNote)")
            print("  曲线: \(check.curveNote)")
            try? journal.write(to: journalURL)
            return check.allVerified
        }

        print("--- 恢复原始设置 ---")
        var writesVerified = restoreRound(1)
        var jointVerified = jointVerify(round: 1)
        if !(writesVerified && jointVerified) {
            // Exactly one extra round: enough for a preset-exclusivity side effect, never a loop.
            print("!! 联合恢复未通过，执行最后一轮恢复（仅一轮）")
            let roundTwoWrites = restoreRound(2)
            let roundTwoJoint = jointVerify(round: 2)
            if roundTwoWrites && roundTwoJoint {
                print("第二轮恢复写入与联合验证全部通过。")
                writesVerified = true
                jointVerified = true
            } else {
                print("!! 第二轮恢复仍未全部通过：如实报告，不再重试")
                writesVerified = writesVerified || roundTwoWrites
                jointVerified = false
            }
        }

        journal.restoreVerified = writesVerified && jointVerified
        journal.restoreDetail = journal.jointChecks.last.map { check in
            "联合恢复 round=\(check.round)；ANC \(check.ancNote)；EQ \(check.eqNote)；空间 \(check.spatialNote)；曲线 \(check.curveNote)"
        } ?? "未执行联合验证"
        journal.finishedAt = Timestamp.now()
        try? journal.write(to: journalURL)

        transport.close()

        print("")
        if journal.restoreVerified == true {
            print("恢复验证通过：ANC / EQ 预设 / 空间音效三项独立读回均与原始值一致，EQ 列表曲线亦一致。")
            print("journal: \(journalURL.path)（保留）")
        } else {
            print("!! 恢复未完全验证：\(journal.restoreDetail)")
            print("!! 原始值保存在 \(journalURL.path)，未删除；请人工核对耳机状态。")
        }
        if let stopReason { print("停止原因: \(stopReason)") }
        print("")

        if journal.restoreVerified != true { return 1 }
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
        return journal ?? AudioJournal.defaultURL()
    }

    private static func absoluteURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw ArgumentError.journalMustBeAbsolute(path) }
        return URL(fileURLWithPath: path)
    }
}

/// Read-only CoreAudio routing check for the user-assisted listening experiment.
private enum ListeningOutput {
    static func isEncoDefaultOutput() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return false }
        guard let name = name?.takeRetainedValue() else { return false }
        let normalized = (name as String).lowercased().replacingOccurrences(of: " ", with: "")
        return normalized.contains("encox3")
    }
}
