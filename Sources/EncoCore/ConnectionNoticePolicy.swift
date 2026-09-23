import Foundation

/// A verified connection may announce once. Repeated query replies and short link flaps
/// must not repeatedly interrupt the user. This does not infer a lid-open event.
public struct ConnectionNoticePolicy {
    private var sessionConsumed = false
    private var lastPresentedAt: Date?
    public init() {}
    public mutating func beginSession() { sessionConsumed = false }

    public mutating func shouldPresent(ready: Bool, enabled: Bool, now: Date = Date()) -> Bool {
        guard ready, !sessionConsumed else { return false }
        sessionConsumed = true
        guard enabled else { return false }
        guard lastPresentedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return false }
        lastPresentedAt = now
        return true
    }
}
