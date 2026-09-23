import Foundation

let checker = Checker()
print("EncoCoreChecks — offline checks (no XCTest framework on this machine)")
print("timestamp: \(ISO8601DateFormatter().string(from: Date()))")
print("")

frameCodecChecks(checker)
print("")
frameStreamParserChecks(checker)
print("")
responseParserChecks(checker)
print("")
realResponseChecks(checker)
print("")
transactionRuleChecks(checker)
print("")
audioChecks(checker)
print("")
audioVerificationChecks(checker)
print("")
eqDuplicateIDChecks(checker)
connectionNoticeChecks(checker)

Task { @MainActor in
    await asyncTransactionChecks(checker)
    exit(checker.summary())
}
RunLoop.main.run()
