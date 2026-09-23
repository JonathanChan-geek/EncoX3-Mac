import Foundation

/// Model-specific interpretation of the OPPO Enco X3.
///
/// Every value here comes from the upstream model profile for PID `067410`
/// (`OppoPodsManager` `Data/DeviceModels.json`, `whiteList[114].function.noiseReductionMode`)
/// combined with `DeviceProfileLoader.ModeKey`. The mode **names** are configuration readings:
/// they describe how the model table labels each bitmap.
///
/// Write/readback status (verified 2026-09-23 on the device, see
/// `docs/evidence/2026-09-23-anc-verified.md`): all seven noise-reduction values
/// (`0x08`, `0x100`, `0x80`, `0x10`, `0x20`, `0x40`, `0x200`) were accepted with an exact
/// acknowledgement and an exact readback, then the original `0x08` was restored. The two parent
/// values were measured earlier: writing `0x01` reads back `0x08`, writing `0x04` reads back
/// `0x200`. What is still unmeasured is how each mode *sounds* — no acoustic or listening test
/// has been done, so the names carry no listening claim.
///
/// The realme/OPPO legacy swap (`LegacyAncSwap`) is deliberately NOT applied — it belongs to
/// older models whose NC and transparency values are exchanged.
public enum X3Profile {
    public static let productID = "067410"
    public static let displayName = "OPPO Enco X3"

    /// Bitmap candidates for the X3, from `whiteList[114].noiseReductionMode`:
    ///   - `modeType 5` (NC) parent at protocolIndex 1, children Smart(7) / Deep(4) / Medium(5) / Light(6)
    ///   - `modeType 1` (Off) parent at protocolIndex 0, single child Off(3)
    ///   - `modeType 2` (Transparency) parent at protocolIndex 2, children Transparency(8) / Adaptive(9)
    ///
    /// `bitmap` is the value this app **sends**; `aliases` are the other bitmaps the device may
    /// report or answer with for the same mode. The first device cycle (2026-09-23) showed the
    /// headset answering to the parent values (`1` -> reads back `8`, `4` -> reads back `512`),
    /// so the child values are used for sending and the parents are kept as aliases.
    public static let noiseModes: [NoiseModeSpec] = [
        NoiseModeSpec(
            key: "Off", label: "关闭", bitmap: 1 << 3, protocolIndex: 3, aliases: [1 << 0],
            isParentOnly: false, panelRole: .off, deviceMeasured: true,
            source: "whiteList[114] modeType=1 child protocolIndex=3（发送值）；父值 protocolIndex=0 作别名。实测 SET 1 → 回读 8"
        ),
        NoiseModeSpec(
            key: "Transparency", label: "通透", bitmap: 1 << 8, protocolIndex: 8, aliases: [1 << 2],
            isParentOnly: false, panelRole: .transparency, deviceMeasured: true,
            source: "whiteList[114] modeType=2 child protocolIndex=8=通透固定子模式（发送值）；父值 protocolIndex=2 作别名。parent 4 实测回读 512"
        ),
        NoiseModeSpec(
            key: "Smart", label: "智能降噪", bitmap: 1 << 7, protocolIndex: 7, aliases: [],
            isParentOnly: false, panelRole: .level, deviceMeasured: true,
            source: "whiteList[114] modeType=7 protocolIndex=7 (child of NC)"
        ),
        NoiseModeSpec(
            key: "Deep", label: "深度降噪", bitmap: 1 << 4, protocolIndex: 4, aliases: [],
            isParentOnly: false, panelRole: .level, deviceMeasured: true,
            source: "whiteList[114] modeType=4 protocolIndex=4 (child of NC)"
        ),
        NoiseModeSpec(
            key: "Medium", label: "中度降噪", bitmap: 1 << 5, protocolIndex: 5, aliases: [],
            isParentOnly: false, panelRole: .level, deviceMeasured: true,
            source: "whiteList[114] modeType=8 protocolIndex=5 (child of NC)"
        ),
        NoiseModeSpec(
            key: "Light", label: "轻度降噪", bitmap: 1 << 6, protocolIndex: 6, aliases: [],
            isParentOnly: false, panelRole: .level, deviceMeasured: true,
            source: "whiteList[114] modeType=3 protocolIndex=6 (child of NC)"
        ),
        NoiseModeSpec(
            key: "Adaptive", label: "自适应通透", bitmap: 1 << 9, protocolIndex: 9, aliases: [],
            isParentOnly: false, panelRole: .adaptive, deviceMeasured: true,
            source: "whiteList[114] modeType=6 protocolIndex=9 (child of Transparency)；独立档位，不与通透固定子模式混同。2026-09-23 实测 SET 0x200 → 回读 0x200"
        ),
        NoiseModeSpec(
            key: "NC", label: "降噪（父模式）", bitmap: 1 << 1, protocolIndex: 1, aliases: [],
            isParentOnly: true, panelRole: .other, deviceMeasured: false,
            source: "whiteList[114] modeType=5 protocolIndex=1 (parent of Smart/Deep/Medium/Light)"
        ),
    ]

    /// The order `cycle-anc` walks the candidates in.
    public static let cycleOrder: [UInt32] = [8, 256, 128, 16, 32, 64, 512]

    public static func spec(bitmap: UInt32) -> NoiseModeSpec? {
        noiseModes.first { $0.bitmap == bitmap }
    }

    /// Looks a raw bitmap up as a main value or as one of its aliases, so a captured value
    /// (the X3 reports `0x08` right now) resolves to its mode without being rewritten.
    public static func candidate(forRawBitmap raw: UInt32) -> NoiseModeSpec? {
        if let exact = spec(bitmap: raw) { return exact }
        return noiseModes.first { $0.aliases.contains(raw) }
    }

    /// Panel grouping, so the UI derives its buttons from the profile instead of hardcoding values.
    public static var offSpec: NoiseModeSpec? { noiseModes.first { $0.panelRole == .off } }
    public static var transparencySpec: NoiseModeSpec? { noiseModes.first { $0.panelRole == .transparency } }
    public static var levelSpecs: [NoiseModeSpec] { noiseModes.filter { $0.panelRole == .level } }
    public static var adaptiveSpec: NoiseModeSpec? { noiseModes.first { $0.panelRole == .adaptive } }
    /// Everything the panel offers as a selectable value: the four NC levels plus adaptive
    /// transparency, which the device accepted as a separate, writable mode.
    public static var selectableSpecs: [NoiseModeSpec] { levelSpecs + [adaptiveSpec].compactMap { $0 } }
    public static var defaultLevelSpec: NoiseModeSpec? { levelSpecs.first }

    /// The level to send when the 降噪 button is pressed: the level the device currently
    /// reports, otherwise the profile's default level.
    public static func selectedLevel(forRawBitmap raw: UInt32?) -> NoiseModeSpec? {
        if let raw, let spec = candidate(forRawBitmap: raw), spec.panelRole == .level { return spec }
        return defaultLevelSpec
    }

    /// Explains a raw bitmap without pretending the device confirmed anything.
    public static func interpretation(ofBitmap raw: UInt32) -> AncInterpretation {
        var matched: NoiseModeSpec?
        var viaAlias = false
        var matchedValue = raw
        for spec in noiseModes where spec.bitmap == raw {
            matched = spec
        }
        if matched == nil {
            for spec in noiseModes where spec.aliases.contains(raw) {
                matched = spec
                viaAlias = true
                matchedValue = spec.bitmap
            }
        }
        let otherBits = (0..<32)
            .filter { bit in (raw >> UInt32(bit)) & 1 == 1 && (UInt32(1) << UInt32(bit)) != raw }
            .map(UInt8.init)
        return AncInterpretation(
            raw: raw,
            matchedKey: matched?.key,
            matchedLabel: matched?.label,
            matchedBitmap: matched == nil ? nil : matchedValue,
            viaAlias: viaAlias,
            isParentValue: matched?.isParentOnly ?? false,
            otherSetBits: otherBits
        )
    }
    /// Spatial audio type from `0x812A`. This is the earbuds' own spatial mode, not any
    /// macOS or Apple head-tracking integration.
    public static func spatialName(_ type: Int) -> String {
        switch type {
        case 0: return "关闭"
        case 1: return "固定"
        case 2: return "跟随"
        default: return "未知(\(type))"
        }
    }

    /// Equalizer presets verified end to end on the device: each was written with `0x0406` and
    /// read back exactly, and the original custom preset (id 4) was restored with the curve
    /// unchanged (see `docs/evidence/2026-09-23-anc-verified.md`).
    public static let measuredEqualizerPresetIDs: [Int] = [0, 1, 2, 3, 7, 4]

    /// Spatial audio modes verified the same way: 1 (fixed) and 2 (track) were written and read
    /// back exactly, and 0 (off) was the original value at both ends of the run.
    public static let measuredSpatialTypes: [Int] = [0, 1, 2]

    /// Built-in equalizer names for the X3 from the upstream model profile
    /// (`whiteList[114]` EQ list). These are **upstream configuration**, not measured names:
    /// the device currently reports only its custom preset (id 4, "自定义").
    public static let builtInEqualizerNames: [Int: String] = [
        0: "至臻原音",
        1: "高清解析",
        2: "纯享人声",
        3: "澎湃低音",
        7: "丹拿特调",
    ]

    public enum NameSource: String {
        /// Name came back from the device in the `0x0122` list.
        case device = "设备回包"
        /// Name is from the upstream X3 model configuration, never verified on hardware.
        case upstream = "X3 上游配置（未实测）"
        case unknown = "未知"
    }

    /// Display name for an equalizer preset: the device's own name wins, an upstream built-in
    /// name is used only as a labelled fallback, and an unknown id stays unknown.
    public static func equalizerName(_ presetID: Int, devicePresets: [EqPreset] = []) -> String {
        if let preset = devicePresets.first(where: { $0.id == presetID }), !preset.name.isEmpty {
            return preset.name
        }
        return builtInEqualizerNames[presetID] ?? "预设\(presetID)（名称待核验）"
    }

    /// Where a preset's displayed name came from, so the UI can label it honestly.
    public static func equalizerNameSource(_ presetID: Int, devicePresets: [EqPreset] = []) -> NameSource {
        if let preset = devicePresets.first(where: { $0.id == presetID }), !preset.name.isEmpty {
            return .device
        }
        return builtInEqualizerNames[presetID] != nil ? .upstream : .unknown
    }

    public static func connectionStateName(_ state: UInt8) -> String {
        switch state {
        case 0: return "已断开"
        case 1: return "连接中"
        case 2: return "已连接"
        default: return "未知(\(state))"
        }
    }

    /// `flag` bits per upstream `ConnectedDeviceInfo`.
    public static func flagDescription(_ flag: UInt8) -> String {
        var parts: [String] = []
        if flag & 0x01 != 0 { parts.append("当前设备") }
        if flag & 0x02 != 0 { parts.append("主音频") }
        if flag & 0x04 != 0 { parts.append("音频活动") }
        if parts.isEmpty { parts.append("无标记") }
        return "\(parts.joined(separator: "/")) (0x\(String(format: "%02X", flag)))"
    }
}

public struct NoiseModeSpec: Equatable {
    public enum PanelRole: String, Equatable {
        case off
        case transparency
        case level
        /// Adaptive transparency: a separate writable mode, shown next to the NC levels.
        case adaptive
        /// Known to the profile but not a daily-use button (the NC parent value).
        case other
    }

    public let key: String
    public let label: String
    /// The bitmap this app sends for this mode.
    public let bitmap: UInt32
    public let protocolIndex: UInt8
    /// Other bitmaps the device may report or answer with for the same mode.
    public let aliases: [UInt32]
    public let isParentOnly: Bool
    public let panelRole: PanelRole
    /// True once a real device cycle confirmed this value end to end.
    public let deviceMeasured: Bool
    public let source: String

    public init(
        key: String,
        label: String,
        bitmap: UInt32,
        protocolIndex: UInt8,
        aliases: [UInt32],
        isParentOnly: Bool,
        panelRole: PanelRole,
        deviceMeasured: Bool,
        source: String
    ) {
        self.key = key
        self.label = label
        self.bitmap = bitmap
        self.protocolIndex = protocolIndex
        self.aliases = aliases
        self.isParentOnly = isParentOnly
        self.panelRole = panelRole
        self.deviceMeasured = deviceMeasured
        self.source = source
    }
}

public struct AncInterpretation: Equatable {
    public let raw: UInt32
    public let matchedKey: String?
    public let matchedLabel: String?
    public let matchedBitmap: UInt32?
    public let viaAlias: Bool
    public let isParentValue: Bool
    public let otherSetBits: [UInt8]

    public var hex: String { String(format: "0x%08X", raw) }

    /// Chinese description that keeps configuration reading and measurement apart.
    public var text: String {
        guard let matchedLabel, let matchedBitmap else {
            return "原始位图 \(hex)（型号配置中无匹配候选，未解释）"
        }
        if viaAlias {
            return "原始位图 \(hex) = \(matchedLabel) 的子项别名（该模式主值为 \(String(format: "0x%08X", matchedBitmap))）"
        }
        if isParentValue {
            return "原始位图 \(hex) = \(matchedLabel)（父模式值，档位由子项上报）"
        }
        return "原始位图 \(hex) = \(matchedLabel)"
    }
}
