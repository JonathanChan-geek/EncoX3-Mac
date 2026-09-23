import Foundation
import EncoCore

/// Restore journal for the noise-reduction writes.
///
/// The original bitmap is written to disk **before** any write is attempted, so a crash or a
/// power loss in the middle of a test still leaves the value needed to put the headset back.
/// A journal that has not been marked restored is kept on purpose.
public struct AncJournal: Codable, Equatable {
    public struct Step: Codable, Equatable {
        public var requestedBitmap: UInt32
        public var requestSequence: UInt8
        public var ackSequence: UInt8?
        public var ackStatus: UInt8?
        public var readbackBitmap: UInt32?
        public var outcome: String
        public var detail: String
        public var at: String
    }

    public var createdAt: String
    public var deviceName: String
    public var maskedAddress: String
    public var productID: String?
    public var originalBitmap: UInt32
    public var originalPayloadHex: String
    public var originalSource: String
    public var batteryAtStart: String
    public var steps: [Step]
    public var restoredAt: String?
    public var restoreVerified: Bool?
    public var restoreDetail: String?
    public var finishedAt: String?

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("EncoX3", isDirectory: true).appendingPathComponent("anc-restore.json")
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> AncJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AncJournal.self, from: data)
    }
}
