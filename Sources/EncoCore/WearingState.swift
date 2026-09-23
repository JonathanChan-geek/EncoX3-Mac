import Foundation

/// Only 05/07 are labelled: these exact values correlated with left/right removal and insertion
/// on this X3. Other upstream states are retained raw rather than guessed as case/disconnection.
public struct WearingReading: Equatable {
    public let raw: UInt8
    public let updatedAt: Date
    public var label: String? { raw == 5 ? "已摘下" : raw == 7 ? "佩戴中" : nil }
    public static func parse(_ payload: [UInt8], at date: Date) -> [BatterySlot: WearingReading]? {
        guard payload.count >= 2, payload[0] == 2, payload.count == 2 + Int(payload[1]) * 2 else { return nil }
        var result: [BatterySlot: WearingReading] = [:]
        var ids = Set<UInt8>()
        for i in 0..<Int(payload[1]) {
            let id = payload[2 + i * 2], raw = payload[3 + i * 2]
            guard (1...3).contains(id), ids.insert(id).inserted else { return nil }
            if id != 3 { result[id == 1 ? .left : .right] = WearingReading(raw: raw, updatedAt: date) }
        }
        return result
    }
}
