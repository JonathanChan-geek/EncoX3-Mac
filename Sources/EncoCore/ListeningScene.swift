import Foundation

public struct ListeningScene: Codable, Equatable {
    public var noise: UInt32
    public var equalizer: Int
    public var spatial: Int
    public init(noise: UInt32, equalizer: Int, spatial: Int) {
        self.noise = noise; self.equalizer = equalizer; self.spatial = spatial
    }
    public var isAllowed: Bool {
        X3Profile.noiseModes.contains { $0.bitmap == noise }
            && X3Profile.measuredEqualizerPresetIDs.contains(equalizer) && (0...2).contains(spatial)
    }
    public enum Field: CaseIterable { case noise, equalizer, spatial }
    public func value(_ field: Field) -> UInt32 {
        switch field {
        case .noise: return noise
        case .equalizer: return UInt32(clamping: equalizer)
        case .spatial: return UInt32(clamping: spatial)
        }
    }
}

public struct SceneJournal: Codable {
    public let deviceID: String
    public let original: ListeningScene
    public let target: ListeningScene
    public let createdAt: Date
    public var completed: Bool = false
    public var restoreVerified: Bool = false
    public init(deviceID: String, original: ListeningScene, target: ListeningScene) {
        self.deviceID = deviceID; self.original = original; self.target = target; createdAt = Date()
    }
}

/// All state comes from independent correlated queries. The caller owns the single-operation
/// lock and binds both closures to one connection generation. Persist-before-write is mandatory.
@MainActor
public enum SceneRunner {
    public enum Outcome: Equatable { case applied, restored, needsRecovery, refused }
    public static func apply(target: ListeningScene, deviceID: String,
                             read: () async -> ListeningScene?,
                             write: (ListeningScene.Field, UInt32) async -> Bool,
                             persist: (SceneJournal) throws -> Void) async -> Outcome {
        guard target.isAllowed, !deviceID.isEmpty, let original = await read(), original.isAllowed else { return .refused }
        var journal = SceneJournal(deviceID: deviceID, original: original, target: target)
        do { try persist(journal) } catch { return .refused }
        var success = true
        for field in ListeningScene.Field.allCases where target.value(field) != original.value(field) {
            if !(await write(field, target.value(field))) { success = false; break }
        }
        if success, await read() == target {
            journal.completed = true
            do { try persist(journal); return .applied } catch { return .needsRecovery }
        }
        for field in ListeningScene.Field.allCases { _ = await write(field, original.value(field)) }
        journal.restoreVerified = await read() == original
        journal.completed = journal.restoreVerified
        do { try persist(journal) } catch { return .needsRecovery }
        return journal.restoreVerified ? .restored : .needsRecovery
    }
}
