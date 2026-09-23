import Foundation
import EncoCore
import EncoDiagnostics

/// Checks for the equalizer / spatial audio work, built on the real captured `0x0122` payload
/// (`evidence/local/eq-probe-eqall.json`). The preset name in that payload is the device's own
/// custom-preset label and is kept only where it is structurally needed.
func audioChecks(_ c: Checker) {
    c.group("EQ 列表解析（0x0122，真实回包）")

    // status=0, count=1, one custom preset with 6 bands and signed gains.
    let realPayload: [UInt8] = [
        0x00, 0x01,
        0x01, 0xFA, 0x06, 0x04, 0x09,
        0xE8, 0x87, 0xAA, 0xE5, 0xAE, 0x9A, 0xE4, 0xB9, 0x89,
        0x06,
        0x3E, 0x00, 0xFD,
        0xFA, 0x00, 0x01,
        0xE8, 0x03, 0x01,
        0xA0, 0x0F, 0xFE,
        0x40, 0x1F, 0x02,
        0x80, 0x3E, 0x02,
    ]
    c.expectEqual(realPayload.count, 35, "真实 EQ 回包 35 字节")

    guard let parsed = EqPresetParser.parse(realPayload) else {
        c.expect(false, "真实 EQ 回包必须解析成功")
        return
    }
    c.expectEqual(parsed.count, 1, "count=1")
    c.expectEqual(parsed.presets.count, 1, "解析出 1 个预设")
    let preset = parsed.presets[0]
    c.expectEqual(preset.id, 4, "eqId=4")
    c.expect(preset.isSelected, "selected=true")
    c.expectEqual(preset.minGain, -6, "minGain 为有符号 -6（0xFA）")
    c.expectEqual(preset.maxGain, 6, "maxGain 6")
    c.expectEqual(preset.frequencies, [62, 250, 1000, 4000, 8000, 16000], "6 段频率（小端）")
    c.expectEqual(preset.gains, [-3, 1, 1, -2, 2, 2], "增益按有符号字节解析（0xFD=-3、0xFE=-2）")
    c.expectEqual(preset.name.utf8.count, 9, "名称 9 字节 UTF-8")

    state: do {
        var state = DeviceState()
        let frame = Frame(
            cmd: EncoCommand.eqAllResponse.rawValue,
            sequence: 0xF8,
            payload: realPayload,
            raw: try! FrameCodec.encode(cmd: EncoCommand.eqAllResponse.rawValue, payload: realPayload)
        )
        ResponseParser.apply(frame, to: &state, at: Date(timeIntervalSince1970: 1000))
        c.expectEqual(state.equalizerPresets.count, 1, "EQ 列表保存到 DeviceState")
        c.expectEqual(state.equalizerListUpdatedAt, Date(timeIntervalSince1970: 1000), "EQ 列表更新时间被记录")
        c.expectEqual(state.rawResponses[EncoCommand.eqAllResponse.rawValue]?.count, 35, "原始 payload 一并保留")
        c.expect(state.equalizerPresetID == nil, "列表不覆盖 0x810F 给出的当前预设")
    }

    c.group("EQ 列表边界（严格拒绝）")

    c.expect(EqPresetParser.parse([]) == nil, "空 payload 拒绝")
    c.expect(EqPresetParser.parse([0x01, 0x01]) == nil, "status != 0 拒绝")
    c.expect(EqPresetParser.parse([0x00, 0x00]) == nil, "count=0 拒绝")
    c.expect(EqPresetParser.parse(Array(realPayload.dropLast())) == nil, "截掉尾字节后拒绝（频率段不完整）")
    c.expect(EqPresetParser.parse(realPayload + [0x00]) == nil, "多出字节后拒绝（必须精确消费）")
    c.expect(EqPresetParser.parse(Array(realPayload.prefix(10))) == nil, "名称字节不足时拒绝")

    var badName = realPayload
    badName[7] = 0xFF
    c.expect(EqPresetParser.parse(badName) == nil, "名称非法 UTF-8 时拒绝")

    var badFreqCount = realPayload
    badFreqCount[16] = 0x10
    c.expect(EqPresetParser.parse(badFreqCount) == nil, "频率段数超过剩余字节时拒绝")

    var badIdByte = realPayload
    badIdByte[5] = 0x00
    if let parsed = EqPresetParser.parse(badIdByte) {
        c.expectEqual(parsed.presets.first?.id, 0, "eqId 为 0 时按 0 解析（id 0 是合法预设）")
    } else {
        c.expect(false, "eqId=0 不应导致整帧拒绝")
    }

    c.group("曲线比较（恢复复核）")

    let original = parsed.presets
    var selectedChanged = original
    selectedChanged[0] = EqPreset(
        isSelected: !original[0].isSelected,
        minGain: original[0].minGain,
        maxGain: original[0].maxGain,
        id: original[0].id,
        name: original[0].name,
        frequencies: original[0].frequencies,
        gains: original[0].gains,
        rawEntry: original[0].rawEntry
    )
    c.expect(EqPreset.sameCurves(original, selectedChanged), "选中态变化不算曲线变化")
    c.expect(EqPreset.curveDifferences(original, selectedChanged).isEmpty, "选中态变化不产生差异报告")

    var gainChanged = original
    gainChanged[0] = EqPreset(
        isSelected: original[0].isSelected,
        minGain: original[0].minGain,
        maxGain: original[0].maxGain,
        id: original[0].id,
        name: original[0].name,
        frequencies: original[0].frequencies,
        gains: [-3, 1, 1, -2, 2, 3],
        rawEntry: original[0].rawEntry
    )
    c.expect(!EqPreset.sameCurves(original, gainChanged), "增益变化算曲线变化")
    c.expectEqual(EqPreset.curveDifferences(original, gainChanged).count, 1, "增益差异被报告")
    c.expect(!EqPreset.sameCurves(original, []), "预设消失算曲线变化")

    c.group("EQ / 空间 / ANC 写命令（payload 与允许集合）")

    c.expectEqual(EncoPayload.eqAllQuery, [0x01, 0x05], "EQ 列表查询 payload 为 [01 05]")
    c.expectEqual(EncoPayload.equalizerSet(id: 4), [0x04], "EQ 设置 payload 为 [id]")
    c.expectEqual(EncoPayload.equalizerSet(id: 0), [0x00], "EQ id 0 可写（关闭/默认预设）")
    c.expectEqual(EncoPayload.spatialSet(type: 2), [0x02], "空间设置 payload 为 [type]")
    c.expectEqual(EncoCommand.allowedWriteCommands, [0x0404, 0x0406, 0x0422], "写入集合只有 ANC/EQ/空间三条")
    c.expect(!EncoCommand.allowedWriteCommands.contains(0x0429), "不允许 0x0429（多设备相关）")
    c.expect(!EncoCommand.allowedWriteCommands.contains(0x0413), "不允许 0x0413")
    c.expect(
        EncoCommand.allowedCommands.isSuperset(of: EncoCommand.allowedWriteCommands),
        "允许发送集合包含全部允许写入"
    )

    c.group("EQ 名称来源（设备优先，不伪造实测）")

    c.expectEqual(X3Profile.equalizerNameSource(4, devicePresets: parsed.presets), .device, "id 4 的名称来自设备回包")
    c.expectEqual(X3Profile.equalizerName(4, devicePresets: parsed.presets), parsed.presets[0].name, "设备名称优先")
    c.expectEqual(X3Profile.equalizerNameSource(0), .upstream, "内置 id 0 标记为上游配置")
    c.expectEqual(X3Profile.equalizerName(0), "至臻原音", "内置 id 0 名称")
    c.expectEqual(X3Profile.equalizerName(7), "丹拿特调", "内置 id 7 名称")
    c.expectEqual(X3Profile.equalizerNameSource(99), .unknown, "未知 id 不编造名称")
    c.expectEqual(X3Profile.equalizerName(99), "预设99（名称待核验）", "未知 id 显示待核验")
}

/// Verification and journal-guard rules: a check may only claim what a fresh response showed.
func audioVerificationChecks(_ c: Checker) {
    c.group("读回验证（只用本次响应，不用缓存）")

    let eqListPayload: [UInt8] = [
        0x00, 0x01,
        0x01, 0xFA, 0x06, 0x04, 0x09,
        0xE8, 0x87, 0xAA, 0xE5, 0xAE, 0x9A, 0xE4, 0xB9, 0x89,
        0x06,
        0x3E, 0x00, 0xFD, 0xFA, 0x00, 0x01, 0xE8, 0x03, 0x01,
        0xA0, 0x0F, 0xFE, 0x40, 0x1F, 0x02, 0x80, 0x3E, 0x02,
    ]
    guard let original = EqPresetParser.parse(eqListPayload)?.presets else {
        c.expect(false, "原始 EQ 列表 fixture 可解析")
        return
    }

    // Noise reduction readback.
    let ancOK = ScalarReadback(command: 0x810C, payload: [0x00, 0x01, 0x01, 0x08, 0x00])
    c.expect(AudioVerification.noiseReduction(expected: 8, response: ancOK).isMatch, "ANC 回读 8 与期望 8 匹配")
    c.expectEqual(
        AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x810C, payload: nil)),
        .unverified("未收到 降噪 的 0x810C 响应"),
        "查询无响应判为未验证，绝不当作匹配"
    )
    c.expect(!AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x810C, payload: nil)).isVerified, "无响应时 isVerified=false")
    c.expectEqual(
        AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x810C, payload: [0x03, 0x01, 0x01, 0x08, 0x00])),
        .unverified("降噪 响应 status=3，不是成功读取"),
        "status != 0 判为未验证"
    )
    c.expectEqual(
        AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x810C, payload: [0x00, 0x09])),
        .unverified("降噪 响应结构无法解析：00 09"),
        "结构无法解析判为未验证"
    )
    c.expectEqual(
        AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x810C, payload: [])),
        .unverified("未收到 降噪 的 0x810C 响应"),
        "空 payload 判为未验证"
    )
    c.expectEqual(
        AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x8106, payload: [0x00])),
        .unverified("降噪 响应命令不匹配（收到 0x8106，期望 0x810C）"),
        "响应命令不匹配判为未验证"
    )
    c.expectEqual(
        AudioVerification.noiseReduction(expected: 8, response: ScalarReadback(command: 0x810C, payload: [0x00, 0x01, 0x01, 0x80, 0x00])),
        .differs(expected: 8, got: 128),
        "回读到不同位图判为 differs（已验证但不匹配）"
    )

    // EQ preset and spatial readback.
    c.expect(AudioVerification.equalizerPreset(expected: 4, response: ScalarReadback(command: 0x810F, payload: [0x00, 0x04])).isMatch, "EQ 回读 4 匹配")
    c.expect(!AudioVerification.equalizerPreset(expected: 4, response: ScalarReadback(command: 0x810F, payload: nil)).isVerified, "EQ 无响应判为未验证")
    c.expect(AudioVerification.spatialType(expected: 0, response: ScalarReadback(command: 0x812A, payload: [0x00, 0x00])).isMatch, "空间回读 0 匹配")
    c.expectEqual(
        AudioVerification.spatialType(expected: 0, response: ScalarReadback(command: 0x812A, payload: [0x00, 0x02])),
        .differs(expected: 0, got: 2),
        "空间回读 2 与期望 0 不同"
    )

    // Curve check: only a fresh, parseable response may claim "unchanged".
    c.expectEqual(
        AudioVerification.curve(original: original, response: ScalarReadback(command: 0x8122, payload: eqListPayload)),
        .unchanged,
        "同一份响应判为曲线不变"
    )
    if case .unverified = AudioVerification.curve(original: original, response: ScalarReadback(command: 0x8122, payload: nil)) {
        c.expect(true, "曲线查询无响应判为未验证（不是不变）")
    } else {
        c.expect(false, "曲线查询无响应必须判为未验证")
    }
    if case .unverified = AudioVerification.curve(original: original, response: ScalarReadback(command: 0x8122, payload: [0x03, 0x01])) {
        c.expect(true, "曲线响应 status != 0 判为未验证")
    } else {
        c.expect(false, "曲线响应 status != 0 必须判为未验证")
    }
    if case .unverified = AudioVerification.curve(original: original, response: ScalarReadback(command: 0x8122, payload: Array(eqListPayload.dropLast()))) {
        c.expect(true, "曲线响应被截断时判为未验证")
    } else {
        c.expect(false, "曲线响应截断必须判为未验证")
    }
    var changedGain = eqListPayload
    changedGain[19] = 0x00 // 第一段增益 0xFD(-3) → 0x00(0)
    if case .changed(let differences) = AudioVerification.curve(original: original, response: ScalarReadback(command: 0x8122, payload: changedGain)) {
        c.expect(!differences.isEmpty, "增益变化被报告为 changed：\(differences.joined(separator: "; "))")
    } else {
        c.expect(false, "增益变化必须判为 changed")
    }
    if case .unverified = AudioVerification.curve(original: [], response: ScalarReadback(command: 0x8122, payload: eqListPayload)) {
        c.expect(true, "没有原始列表可比较时判为未验证")
    } else {
        c.expect(false, "缺少原始列表时必须判为未验证")
    }
    c.expectEqual(AudioVerification.curve(original: original, response: ScalarReadback(command: 0x8122, payload: nil)).note.contains("未能核验"), true, "未验证时文案明确说明未能核验")

    c.group("恢复日志覆盖保护")

    let sample = AudioJournal(
        createdAt: "2026-09-23T05:00:00Z",
        deviceName: "OPPO Enco X3",
        maskedAddress: "40:72:18:XX:XX:XX",
        productID: "067410",
        originalAncBitmap: 8,
        originalAncPayloadHex: "00 01 01 08 00",
        originalEqPresetID: 4,
        originalSpatialType: 0,
        originalEqListPayloadHex: "00 01",
        originalEqList: [],
        steps: [],
        restoreSteps: [],
        curveChecks: [],
        jointChecks: [],
        restoreVerified: nil,
        restoreDetail: nil,
        finishedAt: nil
    )
    c.expectEqual(AudioJournal.decideStart(existing: .none), .allowed, "没有旧记录时允许开始测试")
    c.expectEqual(AudioJournal.decideStart(existing: .completed(sample)), .allowed, "旧记录已恢复验证时允许覆盖")
    if case .blocked(let reason) = AudioJournal.decideStart(existing: .unfinished(sample)) {
        c.expect(reason.contains("未完成"), "未完成记录被拒绝覆盖：\(reason)")
    } else {
        c.expect(false, "未完成记录必须拒绝覆盖")
    }
    if case .blocked = AudioJournal.decideStart(existing: .unreadable) {
        c.expect(true, "无法解析的旧文件也拒绝覆盖")
    } else {
        c.expect(false, "无法解析的旧文件必须拒绝覆盖")
    }

    var restored = sample
    restored.restoreVerified = true
    c.expectEqual(AudioJournal.decideStart(existing: .completed(restored)), .allowed, "restoreVerified=true 视为已完成")

    // The joint check must state exactly what was verified.
    let joint = AudioJournal.JointCheck(
        checkedAt: "2026-09-23T05:01:00Z",
        round: 1,
        ancReadback: nil,
        ancMatches: false,
        ancNote: "未验证：未收到 降噪 的 0x810C 响应",
        eqReadback: 4,
        eqMatches: true,
        eqNote: "匹配 0x00000004",
        spatialReadback: 0,
        spatialMatches: true,
        spatialNote: "匹配 0x00000000",
        curveUnchanged: false,
        curveVerified: false,
        curveNote: "EQ 列表未能核验：未收到 0x8122 响应",
        allVerified: false
    )
    c.expect(!joint.allVerified, "任一未验证时联合检查不通过")
    c.expectEqual(joint.ancReadback, nil, "未验证项不记读数")
    c.expect(joint.ancNote.contains("未验证"), "未验证项明确标注")
}

/// Regression: duplicate preset ids must not reach the curve comparison.
func eqDuplicateIDChecks(_ c: Checker) {
    c.group("EQ 重复 id 拒绝（防止按 id 索引崩溃）")

    // Two entries with the same id: the frame is rejected as a whole.
    let entryA: [UInt8] = [
        0x01, 0xFA, 0x06, 0x04, 0x02, 0x41, 0x41,
        0x01, 0x3E, 0x00, 0xFD,
    ]
    let entryB: [UInt8] = [
        0x00, 0xFA, 0x06, 0x04, 0x02, 0x42, 0x42,
        0x01, 0x3E, 0x00, 0x01,
    ]
    let duplicate = [0x00, 0x02] + entryA + entryB
    c.expect(EqPresetParser.parse(duplicate) == nil, "同一 id 出现两次时整帧拒绝")

    // Distinct ids in the same shape still parse.
    var distinct = duplicate
    distinct[2 + entryA.count + 3] = 0x05
    if let parsed = EqPresetParser.parse(distinct) {
        c.expectEqual(parsed.presets.map(\.id), [4, 5], "不同 id 正常解析")
    } else {
        c.expect(false, "不同 id 应当解析成功")
    }

    // The comparison itself must not trap even if handed duplicates.
    let a = EqPreset(isSelected: false, minGain: -6, maxGain: 6, id: 4, name: "a", frequencies: [62], gains: [-3], rawEntry: [])
    let b = EqPreset(isSelected: true, minGain: -6, maxGain: 6, id: 4, name: "b", frequencies: [62], gains: [0], rawEntry: [])
    c.expect(!EqPreset.sameCurves([a], [a, b]), "重复 id 的比较不崩溃且判为不同")
    c.expect(!EqPreset.curveDifferences([a], [a, b]).isEmpty, "重复 id 的差异报告不崩溃")
}
