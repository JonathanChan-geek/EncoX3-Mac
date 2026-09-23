import Foundation

/// Turns response frames into `DeviceState`.
///
/// Rules kept deliberately conservative:
/// - the raw payload is always stored before anything else is attempted;
/// - a non-zero status byte is recorded as a failure and never becomes a value;
/// - a failure is cleared again only by a later successful response for that command;
/// - a payload whose layout does not match a known format is kept verbatim and left alone;
/// - only the field a response actually describes gets its timestamp refreshed.
///
/// Formats are taken from the captured X3 responses in `evidence/local/probe-bundle.txt`,
/// `probe-one-in-case.txt` and `docs/evidence/2026-09-23-readonly.md`; upstream reference
/// code is only used where the capture agrees with it.
public enum ResponseParser {
    /// Commands whose payload layout is implemented in this stage.
    public static let parsedCommands: Set<UInt16> = [
        EncoCommand.capabilityResponse.rawValue,
        EncoCommand.productIDResponse.rawValue,
        EncoCommand.versionResponse.rawValue,
        EncoCommand.batteryResponse.rawValue,
        EncoCommand.noiseReductionResponse.rawValue,
        EncoCommand.equalizerResponse.rawValue,
        EncoCommand.spatialResponse.rawValue,
        EncoCommand.eqAllResponse.rawValue,
        EncoCommand.multiConnectResponse.rawValue,
        EncoCommand.activeReport.rawValue,
    ]

    public static func reading(reportedLevel: Int, charging: Bool) -> BatteryReading {
        let level: Int? = (reportedLevel <= 0 || reportedLevel > 100) ? nil : reportedLevel
        return BatteryReading(level: level, charging: charging, reportedLevel: reportedLevel)
    }

    @discardableResult
    public static func apply(_ frame: Frame, to state: inout DeviceState, at date: Date = Date()) -> DeviceState {
        state.rawResponses[frame.cmd] = frame.payload
        state.responseCount += 1
        state.lastResponseAt = date

        switch frame.cmd {
        case EncoCommand.capabilityResponse.rawValue:
            applyCapability(frame.payload, to: &state, at: date)
        case EncoCommand.productIDResponse.rawValue:
            applyProductID(frame.payload, to: &state, at: date)
        case EncoCommand.versionResponse.rawValue:
            applyVersion(frame.payload, to: &state, at: date)
        case EncoCommand.batteryResponse.rawValue:
            applyBatteryResponse(frame.payload, to: &state, at: date)
        case EncoCommand.noiseReductionResponse.rawValue:
            applyNoiseReductionResponse(frame.payload, to: &state, at: date)
        case EncoCommand.equalizerResponse.rawValue:
            applyEqualizer(frame.payload, to: &state, at: date)
        case EncoCommand.spatialResponse.rawValue:
            applySpatial(frame.payload, to: &state, at: date)
        case EncoCommand.multiConnectResponse.rawValue:
            applyMultiConnect(frame.payload, to: &state, at: date)
        case EncoCommand.eqAllResponse.rawValue:
            applyEqAll(frame.payload, to: &state, at: date)
        case EncoCommand.activeReport.rawValue:
            applyActiveReport(frame.payload, to: &state, at: date)
        default:
            break
        }
        return state
    }

    // MARK: - Helpers

    private static func markUnparsed(_ payload: [UInt8], cmd: UInt16, in state: inout DeviceState) {
        guard !payload.isEmpty else { return }
        state.unparsedPayloads[cmd] = payload
    }

    private static func recordFailure(_ status: UInt8, cmd: UInt16, in state: inout DeviceState) {
        state.statusFailures[cmd] = status
    }

    private static func clearFailure(_ cmd: UInt16, in state: inout DeviceState) {
        state.statusFailures.removeValue(forKey: cmd)
    }

    /// Shared `[count, (id, raw)…]` battery list used by `0x8106` and by the `0x0204`
    /// battery notification.
    ///
    /// `replacingAll` is true for the response form: the headset reports the complete set, so
    /// a slot it does not mention (for example the case while it is asleep) is cleared to
    /// unknown instead of keeping a stale percentage. Notifications are partial by design.
    private static func applyBatteryList(
        body: [UInt8],
        replacingAll: Bool,
        payload: [UInt8],
        cmd: UInt16,
        to state: inout DeviceState,
        at date: Date
    ) {
        guard let count = body.first, count > 0 else {
            markUnparsed(payload, cmd: cmd, in: &state)
            return
        }
        guard body.count >= 1 + Int(count) * 2 else {
            markUnparsed(payload, cmd: cmd, in: &state)
            return
        }
        var readings: [BatterySlot: BatteryReading] = [:]
        for index in 0..<Int(count) {
            let offset = 1 + index * 2
            let slot: BatterySlot?
            switch body[offset] {
            case 1: slot = .left
            case 2: slot = .right
            case 3: slot = .chargingCase
            default: slot = nil
            }
            guard let slot else { continue }
            let raw = Int(body[offset + 1])
            readings[slot] = reading(reportedLevel: raw & 0x7F, charging: raw & 0x80 != 0)
        }
        guard !readings.isEmpty else {
            markUnparsed(payload, cmd: cmd, in: &state)
            return
        }
        if replacingAll {
            for slot in BatterySlot.allCases where readings[slot] == nil {
                state.battery.removeValue(forKey: slot)
            }
        }
        for (slot, reading) in readings {
            state.battery[slot] = reading
        }
        state.batteryUpdatedAt = date
    }

    // MARK: - Per-command parsing

    private static func applyCapability(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        guard let status = payload.first else { return }
        guard status == 0 else {
            recordFailure(status, cmd: EncoCommand.capabilityResponse.rawValue, in: &state)
            return
        }
        guard payload.count > 1 else {
            markUnparsed(payload, cmd: EncoCommand.capabilityResponse.rawValue, in: &state)
            return
        }
        let bitmap = Array(payload[1...])
        state.capabilityBitmap = bitmap
        state.capabilityBitString = bitmap.map { byte in
            (0..<8).map { bit in (byte >> UInt8(bit)) & 1 == 1 ? "1" : "0" }.joined()
        }.joined()
        state.capabilityUpdatedAt = date
        clearFailure(EncoCommand.capabilityResponse.rawValue, in: &state)
    }

    private static func applyProductID(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        guard payload.count == 4 else {
            markUnparsed(payload, cmd: EncoCommand.productIDResponse.rawValue, in: &state)
            return
        }
        guard payload[0] == 0 else {
            recordFailure(payload[0], cmd: EncoCommand.productIDResponse.rawValue, in: &state)
            return
        }
        // [status][id0][id1][id2] little endian -> six hex digits.
        let value = UInt32(payload[1]) | UInt32(payload[2]) << 8 | UInt32(payload[3]) << 16
        state.productID = String(format: "%06X", value)
        state.productIDUpdatedAt = date
        clearFailure(EncoCommand.productIDResponse.rawValue, in: &state)
    }

    private static func applyVersion(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        guard payload.count >= 3 else {
            markUnparsed(payload, cmd: EncoCommand.versionResponse.rawValue, in: &state)
            return
        }
        guard payload[0] == 0 else {
            recordFailure(payload[0], cmd: EncoCommand.versionResponse.rawValue, in: &state)
            return
        }
        let bytes = payload[2...].prefix { $0 != 0x00 }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            markUnparsed(payload, cmd: EncoCommand.versionResponse.rawValue, in: &state)
            return
        }
        state.firmwareVersion = text
        state.firmwareVersionUpdatedAt = date
        clearFailure(EncoCommand.versionResponse.rawValue, in: &state)
    }

    private static func applyBatteryResponse(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        // Captured: [status, count, id, raw, …] e.g. `00 02 01 64 02 64`.
        guard let status = payload.first else { return }
        guard status == 0 else {
            recordFailure(status, cmd: EncoCommand.batteryResponse.rawValue, in: &state)
            return
        }
        guard payload.count >= 3 else {
            markUnparsed(payload, cmd: EncoCommand.batteryResponse.rawValue, in: &state)
            return
        }
        let cmd = EncoCommand.batteryResponse.rawValue
        applyBatteryList(body: Array(payload.dropFirst()), replacingAll: true, payload: payload, cmd: cmd, to: &state, at: date)
        clearFailure(cmd, in: &state)
    }

    private static func applyNoiseReductionResponse(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        // [status, 01, 01, bitmap little endian...]
        guard payload.count >= 4, payload[1] == 0x01, payload[2] == 0x01 else {
            markUnparsed(payload, cmd: EncoCommand.noiseReductionResponse.rawValue, in: &state)
            return
        }
        guard payload[0] == 0 else {
            recordFailure(payload[0], cmd: EncoCommand.noiseReductionResponse.rawValue, in: &state)
            return
        }
        state.noiseReductionRawValue = littleEndianValue(Array(payload[3...]))
        state.noiseReductionRawPayload = payload
        state.noiseReductionSource = String(format: "0x%04X", EncoCommand.noiseReductionResponse.rawValue)
        state.noiseReductionUpdatedAt = date
        clearFailure(EncoCommand.noiseReductionResponse.rawValue, in: &state)
    }

    private static func applyEqualizer(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        // Captured: `00 04` — status then the raw preset id. Names are not verified.
        guard payload.count >= 2 else {
            markUnparsed(payload, cmd: EncoCommand.equalizerResponse.rawValue, in: &state)
            return
        }
        guard payload[0] == 0 else {
            recordFailure(payload[0], cmd: EncoCommand.equalizerResponse.rawValue, in: &state)
            return
        }
        state.equalizerPresetID = Int(payload[1])
        state.equalizerUpdatedAt = date
        clearFailure(EncoCommand.equalizerResponse.rawValue, in: &state)
    }

    private static func applySpatial(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        // Captured: `00 00` — status then the spatial type (0 off, 1 fixed, 2 track).
        guard payload.count >= 2 else {
            markUnparsed(payload, cmd: EncoCommand.spatialResponse.rawValue, in: &state)
            return
        }
        guard payload[0] == 0 else {
            recordFailure(payload[0], cmd: EncoCommand.spatialResponse.rawValue, in: &state)
            return
        }
        state.spatialType = Int(payload[1])
        state.spatialUpdatedAt = date
        clearFailure(EncoCommand.spatialResponse.rawValue, in: &state)
    }

    private static func applyMultiConnect(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        guard payload.count >= 3 else {
            markUnparsed(payload, cmd: EncoCommand.multiConnectResponse.rawValue, in: &state)
            return
        }
        guard payload[0] == 0 else {
            recordFailure(payload[0], cmd: EncoCommand.multiConnectResponse.rawValue, in: &state)
            return
        }
        let count = Int(payload[1])
        guard let devices = MultiConnectParser.parse(Array(payload.dropFirst(2)), count: count) else {
            markUnparsed(payload, cmd: EncoCommand.multiConnectResponse.rawValue, in: &state)
            return
        }
        state.connectedDevices = devices
        state.multiConnectUpdatedAt = date
        clearFailure(EncoCommand.multiConnectResponse.rawValue, in: &state)
    }

    private static func applyEqAll(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        let cmd = EncoCommand.eqAllResponse.rawValue
        if let status = payload.first, status != 0 {
            recordFailure(status, cmd: cmd, in: &state)
            return
        }
        guard let result = EqPresetParser.parse(payload) else {
            markUnparsed(payload, cmd: cmd, in: &state)
            return
        }
        state.equalizerPresets = result.presets
        state.equalizerListUpdatedAt = date
        clearFailure(cmd, in: &state)
    }

    private static func applyActiveReport(_ payload: [UInt8], to state: inout DeviceState, at date: Date) {
        guard let subType = payload.first else { return }
        let body = Array(payload.dropFirst())
        switch ActiveReportSubType(rawValue: subType) {
        case .battery:
            applyBatteryList(
                body: body,
                replacingAll: false,
                payload: payload,
                cmd: EncoCommand.activeReport.rawValue,
                to: &state,
                at: date
            )
        case .noiseMode:
            // [03, 01, 01, bitmap little endian...]
            guard body.count >= 3, body[0] == 0x01, body[1] == 0x01 else {
                markUnparsed(payload, cmd: EncoCommand.activeReport.rawValue, in: &state)
                return
            }
            state.noiseReductionRawValue = littleEndianValue(Array(body[2...]))
            state.noiseReductionRawPayload = payload
            state.noiseReductionSource = "0x0204"
            state.noiseReductionUpdatedAt = date
        case .multiConnect:
            guard body.count >= 2, body[0] == 0 else {
                markUnparsed(payload, cmd: EncoCommand.activeReport.rawValue, in: &state)
                return
            }
            let count = Int(body[1])
            guard let devices = MultiConnectParser.parse(Array(body.dropFirst(2)), count: count) else {
                markUnparsed(payload, cmd: EncoCommand.activeReport.rawValue, in: &state)
                return
            }
            state.connectedDevices = devices
            state.multiConnectUpdatedAt = date
        case .earbudsStatus:
            guard let readings = WearingReading.parse(payload, at: date) else {
                markUnparsed(payload, cmd: EncoCommand.activeReport.rawValue, in: &state)
                return
            }
            state.wearing.merge(readings) { _, new in new }
        case .none:
            break
        }
    }

    private static func littleEndianValue(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << UInt32(index * 8)
        }
        return value
    }
}
