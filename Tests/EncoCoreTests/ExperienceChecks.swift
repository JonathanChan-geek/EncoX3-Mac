import Foundation
import EncoCore

func batteryAlertChecks(_ c: Checker) {
    c.group("Battery alert suppression")
    func reading(_ value: Int?, _ charging: Bool = false) -> [BatterySlot: BatteryReading] {
        [.left: BatteryReading(level: value, charging: charging, reportedLevel: value ?? 0)]
    }
    var policy = BatteryAlertPolicy()
    c.expect(policy.update(reading(10), fresh: false, lowEnabled: true, chargingEnabled: true).isEmpty, "stale low reading cannot alert")
    c.expect(policy.update(reading(nil), fresh: true, lowEnabled: true, chargingEnabled: true).isEmpty, "unknown is not empty")
    c.expectEqual(policy.update(reading(20), fresh: true, lowEnabled: true, chargingEnabled: true), ["左耳电量 20%"], "first threshold")
    policy.beginSession()
    c.expect(policy.update(reading(19), fresh: true, lowEnabled: true, chargingEnabled: true).isEmpty, "reconnection does not repeat low alert")
    policy = BatteryAlertPolicy(notifiedTiers: policy.notifiedTiers)
    c.expect(policy.update(reading(19), fresh: true, lowEnabled: true, chargingEnabled: true).isEmpty, "restart preserves suppression")
    c.expectEqual(policy.update(reading(10), fresh: true, lowEnabled: true, chargingEnabled: true), ["左耳电量 10%"], "lower threshold escalates once")
    c.expect(policy.update(reading(18), fresh: true, lowEnabled: true, chargingEnabled: true).isEmpty, "small battery bounce cannot rearm")
    c.expectEqual(policy.update(reading(18, true), fresh: true, lowEnabled: true, chargingEnabled: true), ["左耳开始充电"], "real charging edge")
    c.expectEqual(policy.update(reading(18), fresh: true, lowEnabled: true, chargingEnabled: false), ["左耳电量 18%"], "charge rearms low warning without unwanted charging notification")
    c.expect(policy.update(reading(9), fresh: true, lowEnabled: false, chargingEnabled: false).isEmpty, "disabled alerts stay quiet")
}

@MainActor
func sceneRunnerChecks(_ c: Checker) async {
    c.group("Scene verification and recovery")
    let original = ListeningScene(noise: 8, equalizer: 4, spatial: 0)
    let target = ListeningScene(noise: 128, equalizer: 0, spatial: 2)
    var state = original
    var writes: [ListeningScene.Field] = []
    var records: [SceneJournal] = []
    func assign(_ field: ListeningScene.Field, _ value: UInt32) {
        switch field {
        case .noise: state.noise = value
        case .equalizer: state.equalizer = Int(value)
        case .spatial: state.spatial = Int(value)
        }
    }
    let applied = await SceneRunner.apply(target: target, deviceID: "test-device", read: { state }, write: { field, value in
        c.expect(!records.isEmpty && records[0].original == original, "original durably captured before SET")
        writes.append(field); assign(field, value); return true
    }, persist: { records.append($0) })
    c.expectEqual(applied, .applied, "all verified writes and final independent read apply scene")
    c.expectEqual(state, target, "target state reached")
    c.expect(records.last?.completed == true, "successful journal completed")

    state = original; writes = []; records = []
    let rollback = await SceneRunner.apply(target: target, deviceID: "test-device", read: { state }, write: { field, value in
        writes.append(field); assign(field, value)
        return writes.count != 2 // Simulates an applied write whose ACK is lost.
    }, persist: { records.append($0) })
    c.expectEqual(rollback, .restored, "unconfirmed partially applied write is rolled back")
    c.expectEqual(writes.count, 5, "stop forward writes and restore all three original values")
    c.expectEqual(state, original, "exact original values recovered")
    c.expect(records.last?.restoreVerified == true, "rollback independently confirmed")

    state = original; writes = []; records = []
    var readCount = 0
    let lostLink = await SceneRunner.apply(target: target, deviceID: "test-device", read: {
        readCount += 1; return readCount == 1 ? original : nil
    }, write: { field, _ in writes.append(field); return false }, persist: { records.append($0) })
    c.expectEqual(lostLink, .needsRecovery, "missing recovery readback cannot claim restoration")
    c.expect(records.last?.completed == false, "unfinished restore journal retained")

    enum DiskFailure: Error { case full }
    writes = []
    let diskFailure = await SceneRunner.apply(target: target, deviceID: "test-device", read: { original }, write: { field, _ in writes.append(field); return true }, persist: { _ in throw DiskFailure.full })
    c.expectEqual(diskFailure, .refused, "failure to save original blocks all writes")
    c.expect(writes.isEmpty, "no writes before durable journal")
    let invalid = await SceneRunner.apply(target: ListeningScene(noise: 999, equalizer: 0, spatial: 0), deviceID: "test-device", read: { original }, write: { field, _ in writes.append(field); return true }, persist: { _ in })
    c.expectEqual(invalid, .refused, "unknown scene values rejected")
    c.expect(writes.isEmpty, "invalid target cannot reach transport")
}

func wearingChecks(_ c: Checker) {
    c.group("Measured X3 wearing notifications")
    let now = Date()
    let removed = WearingReading.parse([2,3,1,5,2,7,3,4], at: now)
    c.expectEqual(removed?[.left]?.label, "已摘下", "left removal captured as 05")
    c.expectEqual(removed?[.right]?.label, "佩戴中", "right remains worn as 07")
    c.expect(removed?[.chargingCase] == nil, "case status not interpreted without evidence")
    c.expect(WearingReading.parse([2,2,1,5,1,7], at: now) == nil, "duplicate slots rejected")
    c.expect(WearingReading.parse([2,2,1,5], at: now) == nil, "truncated notification rejected")
    c.expect(WearingReading.parse([2,1,1,0], at: now)?[.left]?.label == nil, "upstream unmeasured state remains unknown")
    c.expectEqual(WearingReading.parse([2,1,2,5], at: now)?[.right]?.label, "已摘下", "partial right notification parsed")
}
