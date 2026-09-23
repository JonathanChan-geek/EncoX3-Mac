import Foundation

/// Command words used by this stage. Request commands are 0x01xx, responses 0x81xx,
/// unsolicited notifications arrive on 0x0204.
public enum EncoCommand: UInt16 {
    case capability = 0x0100
    case queryProductID = 0x0103
    case queryVersion = 0x0105
    case queryBattery = 0x0106
    case queryNoiseReduction = 0x010C
    case queryEqualizer = 0x010F
    case queryMultiConnect = 0x0112
    case querySpatial = 0x012A
    case queryEqAll = 0x0122

    // Writes. This stage may send exactly these three and nothing else.
    case setNoiseReduction = 0x0404
    case setEqualizer = 0x0406
    case setSpatialAudio = 0x0422

    case capabilityResponse = 0x8100
    case productIDResponse = 0x8103
    case versionResponse = 0x8105
    case batteryResponse = 0x8106
    case noiseReductionResponse = 0x810C
    case equalizerResponse = 0x810F
    case multiConnectResponse = 0x8112
    case spatialResponse = 0x812A
    case eqAllResponse = 0x8122

    case activeReport = 0x0204

    /// Every command this stage is allowed to write. Anything else is refused before it is
    /// built, let alone sent.
    public static let allowedWriteCommands: Set<UInt16> = [
        EncoCommand.setNoiseReduction.rawValue,
        EncoCommand.setEqualizer.rawValue,
        EncoCommand.setSpatialAudio.rawValue,
    ]

    /// Every command this stage is allowed to send at all.
    public static let allowedCommands: Set<UInt16> = Set([
        EncoCommand.capability.rawValue,
        EncoCommand.queryProductID.rawValue,
        EncoCommand.queryVersion.rawValue,
        EncoCommand.queryBattery.rawValue,
        EncoCommand.queryNoiseReduction.rawValue,
        EncoCommand.queryEqualizer.rawValue,
        EncoCommand.queryMultiConnect.rawValue,
        EncoCommand.querySpatial.rawValue,
        EncoCommand.queryEqAll.rawValue,
    ]).union(allowedWriteCommands)
}

/// Sub types carried by the 0x0204 active report. Values are from the upstream event table
/// and match the captured notifications (`06 …` multi-connect, seen on the X3).
public enum ActiveReportSubType: UInt8 {
    case battery = 0x01
    case earbudsStatus = 0x02
    case noiseMode = 0x03
    case multiConnect = 0x06
}

public enum EncoPayload {
    public static let empty: [UInt8] = []
    /// Current noise-reduction mode query: feature id 1, action 1.
    public static let noiseReductionCurrent: [UInt8] = [0x01, 0x01]
    /// `getAllEqInfo`: one feature, type id 5 (equalizer).
    public static let eqAllQuery: [UInt8] = [0x01, 0x05]
    /// Spatial audio type query carries no payload.
    public static let spatialCurrent: [UInt8] = []

    /// `0x0406` payload: the preset id alone.
    public static func equalizerSet(id: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: id)]
    }

    /// `0x0422` payload: the spatial type alone (0 off, 1 fixed, 2 track).
    public static func spatialSet(type: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: type)]
    }

    /// `0x0404` payload: `[01, 01]` plus the shortest little-endian bitmap.
    ///
    /// The bitmap is written exactly as captured when restoring — a child alias such as
    /// `0x08` is sent as `08`, never replaced by the parent value.
    public static func noiseReductionSet(bitmap: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x01, 0x01]
        var value = bitmap
        repeat {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        } while value != 0
        return bytes
    }
}

public struct ReadOnlyQuery {
    public let label: String
    public let cmd: UInt16
    public let payload: [UInt8]

    public init(label: String, cmd: UInt16, payload: [UInt8] = []) {
        self.label = label
        self.cmd = cmd
        self.payload = payload
    }
}

/// The complete set of commands this stage may send.
///
/// Every entry is a read-only query. The realme/OPPO "hello" on the wire is `00 01`, which
/// is little-endian `0x0100` — the capability query — so this probe sends that capability
/// query and nothing else; it makes no attempt at any authentication frame.
public enum ReadOnlyQueries {
    public static let hello = ReadOnlyQuery(label: "capability", cmd: EncoCommand.capability.rawValue)

    public static let rotation: [ReadOnlyQuery] = [
        ReadOnlyQuery(label: "productID", cmd: EncoCommand.queryProductID.rawValue),
        ReadOnlyQuery(label: "battery", cmd: EncoCommand.queryBattery.rawValue),
        ReadOnlyQuery(label: "noiseReduction", cmd: EncoCommand.queryNoiseReduction.rawValue, payload: EncoPayload.noiseReductionCurrent),
        ReadOnlyQuery(label: "version", cmd: EncoCommand.queryVersion.rawValue),
        ReadOnlyQuery(label: "equalizer", cmd: EncoCommand.queryEqualizer.rawValue),
        ReadOnlyQuery(label: "spatial", cmd: EncoCommand.querySpatial.rawValue),
        ReadOnlyQuery(label: "multiConnect", cmd: EncoCommand.queryMultiConnect.rawValue),
    ]
}
