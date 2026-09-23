import Foundation

public enum BatterySlot: String, CaseIterable {
    case left
    case right
    case chargingCase

    public var label: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        case .chargingCase: return "C"
        }
    }
}

/// One battery slot as reported by the device.
///
/// `level` is nil when the device reported 0 or an impossible level: an unreadable or
/// sleeping slot is unknown, not empty.
public struct BatteryReading: Equatable {
    public var level: Int?
    public var charging: Bool
    /// Exactly what the device sent, kept so unknowns stay auditable.
    public var reportedLevel: Int

    public init(level: Int?, charging: Bool, reportedLevel: Int) {
        self.level = level
        self.charging = charging
        self.reportedLevel = reportedLevel
    }
}

/// Decoded device state. Raw responses are stored before any interpretation, and any
/// response whose status byte is non-zero is recorded as a failure instead of a value.
///
/// Freshness is tracked per field: a response that says nothing about the battery must not
/// make a stale battery reading look current, and an EQ reply or a failed response must not
/// refresh anything at all.
public struct DeviceState {
    public var battery: [BatterySlot: BatteryReading] = [:]
    public var batteryUpdatedAt: Date?
    /// Raw noise-reduction bitmap as sent (little endian), no mode naming applied yet.
    public var noiseReductionRawValue: UInt32?
    public var noiseReductionRawPayload: [UInt8]?
    public var noiseReductionSource: String?
    public var noiseReductionUpdatedAt: Date?
    public var productID: String?
    public var productIDUpdatedAt: Date?
    public var firmwareVersion: String?
    public var firmwareVersionUpdatedAt: Date?
    public var capabilityBitmap: [UInt8]?
    public var capabilityBitString: String?
    public var capabilityUpdatedAt: Date?
    /// `0x810F` raw preset id (names are not confirmed for the X3).
    public var equalizerPresetID: Int?
    public var equalizerUpdatedAt: Date?
    /// `0x8122` preset list as reported by the device (custom curves included).
    public var equalizerPresets: [EqPreset] = []
    public var equalizerListUpdatedAt: Date?
    /// `0x812A` spatial audio type: 0 off, 1 fixed, 2 track (earbud-side mode only).
    public var spatialType: Int?
    public var spatialUpdatedAt: Date?
    public var connectedDevices: [ConnectedDevice] = []
    public var multiConnectUpdatedAt: Date?
    /// Last raw payload per response command, verbatim.
    public var rawResponses: [UInt16: [UInt8]] = [:]
    /// Payloads whose structure did not match a known layout, kept verbatim.
    public var unparsedPayloads: [UInt16: [UInt8]] = [:]
    /// Response command -> non-zero status byte; cleared again by a later success.
    public var statusFailures: [UInt16: UInt8] = [:]
    public var responseCount = 0
    /// When any response last arrived, whatever it said. Not a freshness source per field.
    public var lastResponseAt: Date?

    public init() {}

    /// Data older than this is shown as stale rather than as live.
    public static let freshnessWindow: TimeInterval = 30

    public func isFresh(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= Self.freshnessWindow
    }

    public func batteryIsFresh(now: Date = Date()) -> Bool {
        isFresh(batteryUpdatedAt, now: now)
    }

    public func noiseReductionIsFresh(now: Date = Date()) -> Bool {
        isFresh(noiseReductionUpdatedAt, now: now)
    }

    /// Devices worth listing: the all-zero placeholder entry the headset reports is dropped.
    public var listedConnectedDevices: [ConnectedDevice] {
        connectedDevices.filter { !$0.isPlaceholder }
    }

    public var batteryUnknownSlots: [BatterySlot] {
        BatterySlot.allCases.filter { battery[$0]?.level == nil }
    }

    public func describeBattery() -> String {
        BatterySlot.allCases.map { slot in
            guard let reading = battery[slot] else { return "\(slot.label)=<not reported>" }
            let level = reading.level.map { "\($0)%" } ?? "<unknown>"
            return "\(slot.label)=\(level)\(reading.charging ? " charging" : "") (reported \(reading.reportedLevel))"
        }.joined(separator: "  ")
    }
}

/// One entry of the `0x8112` multi-connect list.
public struct ConnectedDevice: Equatable {
    /// Display-order address (the wire sends the MAC reversed); empty when all zero.
    public let address: String
    public let name: String
    public let elementByte: UInt8
    public let connectionState: UInt8
    public let flags: UInt8
    public let rawEntry: [UInt8]

    public init(address: String, name: String, elementByte: UInt8, connectionState: UInt8, flags: UInt8, rawEntry: [UInt8]) {
        self.address = address
        self.name = name
        self.elementByte = elementByte
        self.connectionState = connectionState
        self.flags = flags
        self.rawEntry = rawEntry
    }

    /// The headset reports an all-zero placeholder entry; it is never a real device.
    public var isPlaceholder: Bool {
        address.isEmpty || address == "00:00:00:00:00:00"
    }

    public var maskedAddress: String {
        let parts = address.split(separator: ":")
        guard parts.count == 6 else { return address.isEmpty ? "<none>" : "<unparsable>" }
        return parts[0...2].joined(separator: ":") + ":XX:XX:XX"
    }

    public var flagsText: String {
        X3Profile.flagDescription(flags)
    }
}
