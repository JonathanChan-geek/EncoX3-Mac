import Foundation

/// Pure verification of a readback against the value it is supposed to hold.
///
/// These helpers exist so a caller can never claim a state it did not observe: every result is
/// computed from the payload of **this** query's correlated response. A missing response, a
/// non-zero status or an unparseable body is `unverified` — never "unchanged" and never a match.
public struct ScalarReadback: Equatable {
    /// Response command that was expected, e.g. `0x810C`.
    public let command: UInt16
    /// Payload of the response, or nil when the query produced no response at all.
    public let payload: [UInt8]?

    public init(command: UInt16, payload: [UInt8]?) {
        self.command = command
        self.payload = payload
    }
}

public enum ScalarVerification: Equatable {
    case matches(UInt32)
    case differs(expected: UInt32, got: UInt32)
    /// No usable evidence: no response, a failed status, or a body that does not parse.
    case unverified(String)

    public var isMatch: Bool {
        if case .matches = self { return true }
        return false
    }

    public var isVerified: Bool {
        switch self {
        case .matches, .differs: return true
        case .unverified: return false
        }
    }
}

public enum AudioVerification {
    public enum CurveResult: Equatable {
        case unchanged
        case changed([String])
        case unverified(String)

        public var isUnchanged: Bool {
            if case .unchanged = self { return true }
            return false
        }

        public var isVerified: Bool {
            if case .unverified = self { return false }
            return true
        }

        public var note: String {
            switch self {
            case .unchanged:
                return "EQ 列表频率/增益与恢复前一致（忽略选中态）"
            case .changed(let differences):
                return "EQ 列表与恢复前不一致（忽略选中态）：\(differences.joined(separator: "; "))"
            case .unverified(let reason):
                return "EQ 列表未能核验：\(reason)"
            }
        }
    }

    /// Noise-reduction bitmap readback, verified against the exact captured value.
    public static func noiseReduction(expected: UInt32, response: ScalarReadback) -> ScalarVerification {
        scalar(expected: expected, response: response, command: EncoCommand.noiseReductionResponse.rawValue, label: "降噪") { state in
            state.noiseReductionRawValue
        }
    }

    public static func equalizerPreset(expected: Int, response: ScalarReadback) -> ScalarVerification {
        scalar(expected: UInt32(expected), response: response, command: EncoCommand.equalizerResponse.rawValue, label: "EQ 预设") { state in
            state.equalizerPresetID.map { UInt32($0) }
        }
    }

    public static func spatialType(expected: Int, response: ScalarReadback) -> ScalarVerification {
        scalar(expected: UInt32(expected), response: response, command: EncoCommand.spatialResponse.rawValue, label: "空间音效") { state in
            state.spatialType.map { UInt32($0) }
        }
    }

    private static func scalar(
        expected: UInt32,
        response: ScalarReadback,
        command: UInt16,
        label: String,
        extract: (DeviceState) -> UInt32?
    ) -> ScalarVerification {
        guard let payload = response.payload, !payload.isEmpty else {
            return .unverified("未收到 \(label) 的 \(String(format: "0x%04X", command)) 响应")
        }
        guard response.command == command else {
            return .unverified("\(label) 响应命令不匹配（收到 0x\(String(format: "%04X", response.command))，期望 0x\(String(format: "%04X", command))）")
        }
        guard let status = payload.first, status == 0 else {
            return .unverified("\(label) 响应 status=\(payload.first.map(String.init) ?? "无")，不是成功读取")
        }
        let frame = Frame(cmd: command, sequence: 0, payload: payload, raw: [])
        var scratch = DeviceState()
        ResponseParser.apply(frame, to: &scratch)
        guard let value = extract(scratch) else {
            return .unverified("\(label) 响应结构无法解析：\(Hex.string(payload))")
        }
        return value == expected ? .matches(value) : .differs(expected: expected, got: value)
    }

    /// Curve check computed from the payload of this query's response only.
    public static func curve(original: [EqPreset], response: ScalarReadback) -> CurveResult {
        guard let payload = response.payload, !payload.isEmpty else {
            return .unverified("未收到 \(String(format: "0x%04X", EncoCommand.eqAllResponse.rawValue)) 响应")
        }
        guard response.command == EncoCommand.eqAllResponse.rawValue else {
            return .unverified("EQ 列表响应命令不匹配（收到 0x\(String(format: "%04X", response.command))）")
        }
        guard let status = payload.first, status == 0 else {
            return .unverified("EQ 列表响应 status=\(payload.first.map(String.init) ?? "无")，不是成功读取")
        }
        guard let parsed = EqPresetParser.parse(payload) else {
            return .unverified("EQ 列表响应结构无法解析：\(Hex.string(payload))")
        }
        guard !original.isEmpty else {
            return .unverified("没有可比的原始 EQ 列表")
        }
        let differences = EqPreset.curveDifferences(original, parsed.presets)
        return differences.isEmpty ? .unchanged : .changed(differences)
    }
}
