import Foundation

/// Keep low-battery suppression across reconnects and app launches. Only a reported charge
/// or a rise above 30% re-arms a slot; missing/stale values cannot manufacture transitions.
public struct BatteryAlertPolicy {
    public private(set) var notifiedTiers: [String: Int]
    private var charging: [BatterySlot: Bool] = [:]
    public init(notifiedTiers: [String: Int] = [:]) { self.notifiedTiers = notifiedTiers }
    public mutating func beginSession() { charging = [:] }
    public mutating func update(_ readings: [BatterySlot: BatteryReading], fresh: Bool,
                                lowEnabled: Bool, chargingEnabled: Bool) -> [String] {
        guard fresh else { return [] }
        var messages: [String] = []
        for slot in BatterySlot.allCases {
            guard let r = readings[slot], let level = r.level else { continue }
            let name = slot == .left ? "左耳" : slot == .right ? "右耳" : "充电盒"
            if let previous = charging[slot], previous != r.charging, chargingEnabled {
                messages.append("\(name)\(r.charging ? "开始充电" : "已停止充电")")
            }
            charging[slot] = r.charging
            if r.charging || level > 30 { notifiedTiers[slot.rawValue] = nil; continue }
            let tier = level <= 10 ? 10 : level <= 20 ? 20 : nil
            if let tier, tier < (notifiedTiers[slot.rawValue] ?? 100) {
                notifiedTiers[slot.rawValue] = tier
                if lowEnabled { messages.append("\(name)电量 \(level)%") }
            }
        }
        return messages
    }
}
