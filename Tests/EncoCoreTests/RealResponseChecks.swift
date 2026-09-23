import Foundation
import EncoCore

/// Checks built on the payloads actually captured from the device
/// (`evidence/local/probe-bundle.txt`, `probe-one-in-case.txt`).
///
/// Identifiers are anonymised: MAC bytes are replaced and names use same-length stand-ins, so
/// no personal device name or address ends up in the repository.
func realResponseChecks(_ c: Checker) {
    c.group("真实回包解析（payload 来自实机日志，标识已匿名化）")

    func response(_ cmd: UInt16, _ payload: [UInt8]) -> Frame {
        Frame(cmd: cmd, sequence: 0xF0, payload: payload, raw: (try? FrameCodec.encode(cmd: cmd, payload: payload)) ?? [])
    }

    // MARK: product id / capability / version / EQ / spatial

    var state = DeviceState()
    ResponseParser.apply(response(0x8103, [0x00, 0x10, 0x74, 0x06]), to: &state)
    c.expectEqual(state.productID, "067410", "PID 回包 00 10 74 06 → 067410（小端）")

    state = DeviceState()
    ResponseParser.apply(response(0x8100, [0x00, 0xFF, 0x77, 0x7A, 0xEE, 0xE6, 0x8F, 0x8E, 0x04]), to: &state)
    c.expectEqual(state.capabilityBitmap?.count, 8, "能力位图 8 字节已保存")
    c.expectEqual(state.capabilityBitString?.count, 64, "能力位图展开为 64 bit")

    state = DeviceState()
    ResponseParser.apply(
        response(0x8105, [0x00, 0x03] + Array("1,2,143,2,2,143,3,2,039".utf8)),
        to: &state
    )
    c.expectEqual(state.firmwareVersion, "1,2,143,2,2,143,3,2,039", "版本串按 UTF-8 解析")

    state = DeviceState()
    ResponseParser.apply(response(0x810F, [0x00, 0x04]), to: &state)
    c.expectEqual(state.equalizerPresetID, 4, "EQ 原始值 4")
    c.expectEqual(X3Profile.equalizerName(4), "预设4（名称待核验）", "EQ 名称标为待核验")

    state = DeviceState()
    ResponseParser.apply(response(0x812A, [0x00, 0x00]), to: &state)
    c.expectEqual(state.spatialType, 0, "空间音效类型 0")
    c.expectEqual(X3Profile.spatialName(0), "关闭", "空间音效 0 = 关闭")

    // MARK: battery list form

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x02, 0x01, 0x64, 0x02, 0x64]), to: &state)
    c.expectEqual(state.battery[.left], BatteryReading(level: 100, charging: false, reportedLevel: 100), "8106 左右耳各 100%")
    c.expectEqual(state.battery[.right], BatteryReading(level: 100, charging: false, reportedLevel: 100), "8106 右耳 100%")
    c.expect(state.battery[.chargingCase] == nil, "8106 未上报的充电盒保持未知（不是 0）")
    c.expect(state.batteryUpdatedAt != nil, "电量读数刷新电量时间")

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x03, 0x01, 0xE4, 0x02, 0x64, 0x03, 0xE4]), to: &state)
    c.expectEqual(state.battery[.left], BatteryReading(level: 100, charging: true, reportedLevel: 100), "0xE4 = 100 且充电（高 bit 充电）")
    c.expectEqual(state.battery[.right], BatteryReading(level: 100, charging: false, reportedLevel: 100), "未充电项不高位")
    c.expectEqual(state.battery[.chargingCase], BatteryReading(level: 100, charging: true, reportedLevel: 100), "充电盒入盒后上报")

    // A complete response replaces the set: the case drops out when the device stops reporting it.
    ResponseParser.apply(response(0x8106, [0x00, 0x02, 0x01, 0x64, 0x02, 0x64]), to: &state)
    c.expect(state.battery[.chargingCase] == nil, "完整响应未含充电盒时清空该槽（避免陈旧百分比）")
    c.expectEqual(state.battery[.left]?.level, 100, "清空的是未返回的槽，其它槽保留")

    // Notification form stays partial.
    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x03, 0x01, 0xE4, 0x02, 0x64, 0x03, 0xE4]), to: &state)
    ResponseParser.apply(response(0x0204, [0x01, 0x01, 0x01, 0x64]), to: &state)
    c.expectEqual(state.battery[.left]?.level, 100, "通知只更新列出的槽")
    c.expectEqual(state.battery[.chargingCase]?.level, 100, "通知未列出的槽保持上一次读数（部分更新）")

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x02, 0x01, 0x64]), to: &state)
    c.expect(state.battery.isEmpty, "count=2 但少于两对 id/raw 时整帧拒绝")

    // MARK: noise reduction

    state = DeviceState()
    ResponseParser.apply(response(0x810C, [0x00, 0x01, 0x01, 0x08, 0x00]), to: &state)
    c.expectEqual(state.noiseReductionRawValue, 0x08, "810C 原始位图 0x08 原样保存")
    let interpretation = X3Profile.interpretation(ofBitmap: 0x08)
    c.expectEqual(interpretation.matchedKey, "Off", "位图 8 按 X3 配置解释为关闭（实测 SET 8 → 回读 8）")
    c.expect(!interpretation.viaAlias, "位图 8 现在是关闭的发送主值，不再是别名")
    c.expectEqual(X3Profile.interpretation(ofBitmap: 0x01).matchedKey, "Off", "位图 1 是关闭的父值别名")
    c.expect(X3Profile.interpretation(ofBitmap: 0x01).viaAlias, "位图 1 标记为别名")

    // MARK: multi-connect list (structure identical to the capture, identifiers anonymised)

    let entry0: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x0C, 0x02, 0x00, 0x09] + Array("phone-001".utf8)
    let entry1: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x17, 0x02, 0x01, 0x14] + Array("MacBook Pro (tested)".utf8)
    let entry2: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]
    let multiBody = [0x00, 0x03] + entry0 + entry1 + entry2
    c.expectEqual(entry0.count, 19, "匿名化条目 0 与实机条目等长（19B）")
    c.expectEqual(entry1.count, 30, "匿名化条目 1 与实机条目等长（30B）")

    state = DeviceState()
    ResponseParser.apply(response(0x8112, multiBody), to: &state)
    c.expectEqual(state.connectedDevices.count, 3, "8112 固定偏移解析出 3 条")
    c.expectEqual(state.listedConnectedDevices.count, 2, "全零占位条目在展示时被过滤")
    c.expectEqual(state.connectedDevices.first?.address, "66:55:44:33:22:11", "MAC 按小端反转成显示顺序")
    c.expectEqual(state.connectedDevices.first?.name, "phone-001", "条目 0 名称")
    c.expectEqual(state.connectedDevices.first?.connectionState, 2, "条目 0 连接状态 2")
    c.expectEqual(state.connectedDevices[1].name, "MacBook Pro (tested)", "条目 1 名称（20 字节）")
    c.expectEqual(state.connectedDevices[1].flags, 0x01, "条目 1 flags=0x01（当前设备）")
    c.expect(state.connectedDevices[2].isPlaceholder, "第三条是全零占位")

    state = DeviceState()
    ResponseParser.apply(response(0x0204, [0x06] + multiBody), to: &state)
    c.expectEqual(state.listedConnectedDevices.count, 2, "0204 子类型 06 也解析多设备列表")

    // Fixed offsets: any structural deviation is rejected whole, never guessed.
    state = DeviceState()
    ResponseParser.apply(response(0x8112, multiBody + [0x00]), to: &state)
    c.expect(state.connectedDevices.isEmpty, "多出一字节时整帧不解析")
    c.expectEqual(state.unparsedPayloads[0x8112]?.count, multiBody.count + 1, "不解析的整帧原样保留")

    state = DeviceState()
    var badState = multiBody
    badState[2 + 6 + 1] = 0x09
    ResponseParser.apply(response(0x8112, badState), to: &state)
    c.expect(state.connectedDevices.isEmpty, "connectionState 越界（9）时整帧不解析")

    state = DeviceState()
    var badName = multiBody
    badName[2 + 19 + 10] = 0xFF
    ResponseParser.apply(response(0x8112, badName), to: &state)
    c.expect(state.connectedDevices.isEmpty, "名称不是合法 UTF-8 时整帧不解析")

    state = DeviceState()
    ResponseParser.apply(response(0x8112, [0x00, 0x00]), to: &state)
    c.expect(state.connectedDevices.isEmpty, "count=0 视为无效，不伪造设备")

    // MARK: unknown frames and failures

    state = DeviceState()
    let before = state.responseCount
    ResponseParser.apply(response(0x0500, []), to: &state)
    c.expectEqual(state.responseCount, before + 1, "未知命令帧计入响应数")
    c.expectEqual(state.rawResponses[0x0500]?.count, 0, "未知命令的空 payload 原样保存")
    c.expect(state.connectedDevices.isEmpty && state.battery.isEmpty, "未知命令不产生任何状态")

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x03, 0x02, 0x01, 0x64, 0x02, 0x64]), to: &state)
    c.expect(state.battery.isEmpty, "status != 0 的电量回包不产生读数")
    c.expectEqual(state.statusFailures[0x8106], 0x03, "失败状态记录下来")
    ResponseParser.apply(response(0x8106, [0x00, 0x02, 0x01, 0x64, 0x02, 0x64]), to: &state)
    c.expect(state.statusFailures[0x8106] == nil, "后续成功回包清除失败记录")

    // Freshness isolation: advanced replies must not refresh battery or noise reduction.
    state = DeviceState()
    let batteryAt = Date(timeIntervalSince1970: 700)
    ResponseParser.apply(response(0x8106, [0x00, 0x02, 0x01, 0x64, 0x02, 0x64]), to: &state, at: batteryAt)
    ResponseParser.apply(response(0x810F, [0x00, 0x04]), to: &state, at: Date(timeIntervalSince1970: 800))
    ResponseParser.apply(response(0x8112, multiBody), to: &state, at: Date(timeIntervalSince1970: 900))
    c.expectEqual(state.batteryUpdatedAt, batteryAt, "EQ/多设备回包不刷新电量新鲜度")
    c.expect(state.noiseReductionUpdatedAt == nil, "未收到降噪回包时降噪新鲜度为空")
}

func transactionRuleChecks(_ c: Checker) {
    c.group("事务与写命令规则")

    c.expectEqual(ResponseCorrelation.responseCommand(for: 0x010C), 0x810C, "响应命令 = 请求 | 0x8000")
    c.expectEqual(ResponseCorrelation.responseCommand(for: 0x0404), 0x8404, "写命令 0x0404 的响应为 0x8404")

    let frame = Frame(cmd: 0x810C, sequence: 0xF0, payload: [0x00, 0x01, 0x01, 0x08, 0x00], raw: [])
    c.expect(ResponseCorrelation.isResponse(frame, to: 0x010C, sequence: 0xF0), "同 seq 的响应被认领")
    c.expect(!ResponseCorrelation.isResponse(frame, to: 0x010C, sequence: 0xF1), "不同 seq 的响应不被认领")
    c.expect(!ResponseCorrelation.isResponse(frame, to: 0x0106, sequence: 0xF0), "不同命令的响应不被认领")

    c.expectEqual(ResponseCorrelation.classify(frame), .ok(0), "status=0 判为 ok")
    c.expectEqual(
        ResponseCorrelation.classify(Frame(cmd: 0x8404, sequence: 0xF0, payload: [], raw: [])),
        .missing,
        "空 ACK（无 status 字段）判为 missing，绝不是 ok"
    )
    c.expectEqual(
        ResponseCorrelation.classify(Frame(cmd: 0x8404, sequence: 0xF0, payload: [0x05], raw: [])),
        .rejected(5),
        "status=5 判为 rejected"
    )

    c.expectEqual(EncoPayload.noiseReductionSet(bitmap: 0x08), [0x01, 0x01, 0x08], "关闭按实测可用的 0x08 发送")
    c.expectEqual(EncoPayload.noiseReductionSet(bitmap: 0x01), [0x01, 0x01, 0x01], "别名 0x01 仍可原样发送（不会被替换）")
    c.expectEqual(EncoPayload.noiseReductionSet(bitmap: 0x100), [0x01, 0x01, 0x00, 0x01], "通透固定子模式 0x100 两字节小端")
    c.expectEqual(EncoPayload.noiseReductionSet(bitmap: 0x80), [0x01, 0x01, 0x80], "智能降噪 0x80 最短编码")
    c.expectEqual(EncoPayload.noiseReductionSet(bitmap: 0x200), [0x01, 0x01, 0x00, 0x02], "自适应通透 0x200 两字节小端")
    c.expect(EncoPayload.noiseReductionSet(bitmap: 0x08) != EncoPayload.noiseReductionSet(bitmap: 0x01), "关闭的发送值 0x08 不会被父值 0x01 替代")
    c.expect(X3Profile.cycleOrder.allSatisfy { bitmap in X3Profile.interpretation(ofBitmap: bitmap).matchedKey != nil }, "cycle 序列里每个值都能被解释")

    c.expectEqual(X3Profile.cycleOrder, [8, 256, 128, 16, 32, 64, 512], "cycle-anc 顺序：关闭8/通透256/智能128/深16/中32/轻64/自适应通透512")
    c.expectEqual(X3Profile.spec(bitmap: 128)?.key, "Smart", "128 = 智能降噪")
    c.expectEqual(X3Profile.spec(bitmap: 8)?.key, "Off", "8 = 关闭的发送主值（已实测）")
    c.expectEqual(X3Profile.spec(bitmap: 8)?.protocolIndex, 3, "关闭的发送值 protocolIndex=3")
    c.expectEqual(X3Profile.spec(bitmap: 8)?.aliases, [1], "关闭的别名是父值 1")
    c.expectEqual(X3Profile.spec(bitmap: 8)?.deviceMeasured, true, "关闭已被实机 cycle 验证")
    c.expectEqual(X3Profile.spec(bitmap: 256)?.key, "Transparency", "256 = 通透固定子模式（发送值）")
    c.expectEqual(X3Profile.spec(bitmap: 256)?.protocolIndex, 8, "通透的发送值 protocolIndex=8")
    c.expectEqual(X3Profile.spec(bitmap: 256)?.aliases, [4], "通透的别名是父值 4")
    c.expectEqual(X3Profile.spec(bitmap: 4)?.key, nil, "4 不再是任何模式的发送主值")
    c.expectEqual(X3Profile.candidate(forRawBitmap: 4)?.key, "Transparency", "回读 4 归为通透（别名）")
    c.expect(X3Profile.interpretation(ofBitmap: 4).viaAlias, "回读 4 标记为别名")
    c.expectEqual(X3Profile.interpretation(ofBitmap: 2).matchedKey, "NC", "0x02 = NC 父模式值")
    c.expect(X3Profile.interpretation(ofBitmap: 2).isParentValue, "0x02 标记为父模式")
    c.expectEqual(X3Profile.interpretation(ofBitmap: 512).matchedKey, "Adaptive", "回读 512 是自适应通透，不是通透")
    c.expect(X3Profile.interpretation(ofBitmap: 512).matchedBitmap != 256, "512 绝不等同通透固定子模式 256（首轮实测：parent 4 → 回读 512）")
    c.expectEqual(X3Profile.candidate(forRawBitmap: 512)?.key, "Adaptive", "512 只解析为自适应通透")
    c.expect(X3Profile.interpretation(ofBitmap: 0x1000).matchedKey == nil, "未知位图不做解释")
    c.expect(X3Profile.noiseModes.contains { $0.key == "Adaptive" && $0.bitmap == 0x200 && $0.aliases.isEmpty }, "自适应通透 0x200 独立、无别名")
    c.expect(!X3Profile.noiseModes.contains { $0.key == "Adaptive" && $0.bitmap == 0x1000000 }, "不套用 realme 的其它 0x1000000 值")
    c.expectEqual(X3Profile.offSpec?.key, "Off", "面板关闭按钮取自 profile")
    c.expectEqual(X3Profile.transparencySpec?.key, "Transparency", "面板通透按钮取自 profile")
    c.expectEqual(X3Profile.levelSpecs.map(\.key), ["Smart", "Deep", "Medium", "Light"], "面板档位取自 profile")
    c.expectEqual(X3Profile.selectedLevel(forRawBitmap: 512)?.key, "Smart", "当前不在降噪档位时，降噪按钮用默认档（智能）")
}
