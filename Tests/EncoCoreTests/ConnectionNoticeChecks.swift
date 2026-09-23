import Foundation
import EncoCore

func connectionNoticeChecks(_ c: Checker) {
    c.group("Connection notices")
    let now = Date(timeIntervalSince1970: 1_000)
    var policy = ConnectionNoticePolicy()
    c.expect(!policy.shouldPresent(ready: false, enabled: true, now: now), "unverified connection cannot announce")
    c.expect(policy.shouldPresent(ready: true, enabled: true, now: now), "first verified battery can announce")
    c.expect(!policy.shouldPresent(ready: true, enabled: true, now: now.addingTimeInterval(120)), "polls never repeat the same session")
    policy.beginSession()
    c.expect(!policy.shouldPresent(ready: true, enabled: true, now: now.addingTimeInterval(20)), "short reconnect is quiet")
    c.expect(!policy.shouldPresent(ready: true, enabled: true, now: now.addingTimeInterval(80)), "suppressed session does not announce later")
    policy.beginSession()
    c.expect(policy.shouldPresent(ready: true, enabled: true, now: now.addingTimeInterval(80)), "later reconnect can announce")
    policy.beginSession()
    c.expect(!policy.shouldPresent(ready: true, enabled: false, now: now.addingTimeInterval(180)), "disabled preference suppresses announcement")
    c.expect(!policy.shouldPresent(ready: true, enabled: true, now: now.addingTimeInterval(181)), "enabling preference does not replay the current connection")
    policy.beginSession()
    c.expect(policy.shouldPresent(ready: true, enabled: true, now: now.addingTimeInterval(182)), "disabled session did not spend the cooldown")
}
