import Foundation
import EncoCore

/// Restore journal for the audio write test.
///
/// Everything needed to put the headset back — the noise-reduction bitmap, the equalizer preset,
/// the spatial type and the full equalizer list — is written to one file **before** the first
/// SET. A journal that was not verified as restored is kept on purpose.
public struct AudioJournal: Codable, Equatable {
    public struct Step: Codable, Equatable {
        public var label: String
        public var requested: UInt32
        public var requestSequence: UInt8
        public var ackSequence: UInt8?
        public var ackStatus: UInt8?
        public var readback: UInt32?
        public var outcome: String
        public var detail: String
        public var at: String

        public init(label: String, requested: UInt32, requestSequence: UInt8, ackSequence: UInt8?, ackStatus: UInt8?, readback: UInt32?, outcome: String, detail: String, at: String) {
            self.label = label
            self.requested = requested
            self.requestSequence = requestSequence
            self.ackSequence = ackSequence
            self.ackStatus = ackStatus
            self.readback = readback
            self.outcome = outcome
            self.detail = detail
            self.at = at
        }
    }

    public struct EqEntry: Codable, Equatable {
        public var id: Int
        public var name: String
        public var isSelected: Bool
        public var minGain: Int
        public var maxGain: Int
        public var frequencies: [Int]
        public var gains: [Int]

        public init(id: Int, name: String, isSelected: Bool, minGain: Int, maxGain: Int, frequencies: [Int], gains: [Int]) {
            self.id = id
            self.name = name
            self.isSelected = isSelected
            self.minGain = minGain
            self.maxGain = maxGain
            self.frequencies = frequencies
            self.gains = gains
        }
    }

    public struct CurveCheck: Codable, Equatable {
        public var checkedAt: String
        /// True only when this check parsed a fresh response and found the curve identical.
        public var unchanged: Bool
        /// False when there was no usable response: the curve was NOT verified.
        public var verified: Bool
        public var differences: [String]
        public var note: String
        public var responsePayloadHex: String
        public var status: UInt8?

        public init(checkedAt: String, unchanged: Bool, verified: Bool, differences: [String], note: String, responsePayloadHex: String, status: UInt8?) {
            self.checkedAt = checkedAt
            self.unchanged = unchanged
            self.verified = verified
            self.differences = differences
            self.note = note
            self.responsePayloadHex = responsePayloadHex
            self.status = status
        }
    }

    /// One joint verification pass: after restoring, all three values are re-read independently
    /// and compared with the originals.
    public struct JointCheck: Codable, Equatable {
        public var checkedAt: String
        public var round: Int
        public var ancReadback: UInt32?
        public var ancMatches: Bool
        public var ancNote: String
        public var eqReadback: Int?
        public var eqMatches: Bool
        public var eqNote: String
        public var spatialReadback: Int?
        public var spatialMatches: Bool
        public var spatialNote: String
        public var curveUnchanged: Bool
        public var curveVerified: Bool
        public var curveNote: String
        /// True only when all four checks came back verified and equal to the originals.
        public var allVerified: Bool

        public init(
            checkedAt: String,
            round: Int,
            ancReadback: UInt32?,
            ancMatches: Bool,
            ancNote: String,
            eqReadback: Int?,
            eqMatches: Bool,
            eqNote: String,
            spatialReadback: Int?,
            spatialMatches: Bool,
            spatialNote: String,
            curveUnchanged: Bool,
            curveVerified: Bool,
            curveNote: String,
            allVerified: Bool
        ) {
            self.checkedAt = checkedAt
            self.round = round
            self.ancReadback = ancReadback
            self.ancMatches = ancMatches
            self.ancNote = ancNote
            self.eqReadback = eqReadback
            self.eqMatches = eqMatches
            self.eqNote = eqNote
            self.spatialReadback = spatialReadback
            self.spatialMatches = spatialMatches
            self.spatialNote = spatialNote
            self.curveUnchanged = curveUnchanged
            self.curveVerified = curveVerified
            self.curveNote = curveNote
            self.allVerified = allVerified
        }
    }

    public var createdAt: String
    public var deviceName: String
    public var maskedAddress: String
    public var productID: String?
    public var originalAncBitmap: UInt32
    public var originalAncPayloadHex: String
    public var originalEqPresetID: Int
    public var originalSpatialType: Int
    public var originalEqListPayloadHex: String
    public var originalEqList: [EqEntry]
    public var steps: [Step]
    public var restoreSteps: [Step]
    public var curveChecks: [CurveCheck]
    public var jointChecks: [JointCheck]
    public var restoreVerified: Bool?
    public var restoreDetail: String?
    public var finishedAt: String?

    public init(
        createdAt: String,
        deviceName: String,
        maskedAddress: String,
        productID: String?,
        originalAncBitmap: UInt32,
        originalAncPayloadHex: String,
        originalEqPresetID: Int,
        originalSpatialType: Int,
        originalEqListPayloadHex: String,
        originalEqList: [EqEntry],
        steps: [Step],
        restoreSteps: [Step],
        curveChecks: [CurveCheck],
        jointChecks: [JointCheck],
        restoreVerified: Bool?,
        restoreDetail: String?,
        finishedAt: String?
    ) {
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.maskedAddress = maskedAddress
        self.productID = productID
        self.originalAncBitmap = originalAncBitmap
        self.originalAncPayloadHex = originalAncPayloadHex
        self.originalEqPresetID = originalEqPresetID
        self.originalSpatialType = originalSpatialType
        self.originalEqListPayloadHex = originalEqListPayloadHex
        self.originalEqList = originalEqList
        self.steps = steps
        self.restoreSteps = restoreSteps
        self.curveChecks = curveChecks
        self.jointChecks = jointChecks
        self.restoreVerified = restoreVerified
        self.restoreDetail = restoreDetail
        self.finishedAt = finishedAt
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EncoX3", isDirectory: true).appendingPathComponent("audio-restore.json")
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> AudioJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AudioJournal.self, from: data)
    }

    public enum Existing {
        case none
        case completed(AudioJournal)
        case unfinished(AudioJournal)
        /// The file exists but could not be decoded — treated as unfinished on purpose.
        case unreadable

        public static func inspect(_ url: URL) -> Existing {
            guard FileManager.default.fileExists(atPath: url.path) else { return .none }
            guard let journal = AudioJournal.read(from: url) else { return .unreadable }
            return journal.restoreVerified == true ? .completed(journal) : .unfinished(journal)
        }
    }

    public enum GuardDecision: Equatable {
        case allowed
        case blocked(reason: String)
    }

    /// A new write test may only start when there is no unfinished record at this path:
    /// overwriting one would destroy the only copy of the original values.
    public static func decideStart(existing: Existing) -> GuardDecision {
        switch existing {
        case .none, .completed:
            return .allowed
        case .unfinished(let journal):
            return .blocked(reason: "该路径已有未完成的恢复记录（restoreVerified=\(journal.restoreVerified.map(String.init) ?? "nil")，createdAt=\(journal.createdAt)，原始 ANC 0x\(String(format: "%08X", journal.originalAncBitmap))）。拒绝覆盖，请换用新的 --journal 路径或先人工处理该文件。")
        case .unreadable:
            return .blocked(reason: "该路径已存在文件但无法解析为恢复记录；拒绝覆盖，请换用新的 --journal 路径或先人工处理该文件。")
        }
    }
}
