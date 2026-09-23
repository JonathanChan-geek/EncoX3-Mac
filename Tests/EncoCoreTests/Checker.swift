import Foundation

/// Minimal check harness.
///
/// This machine has no XCTest framework (Command Line Tools only, no Xcode), so the offline
/// checks run as a plain executable: each check records a failure, the entry point prints a
/// summary and exits non-zero if anything failed.
final class Checker {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentGroup = "?"

    func group(_ name: String) {
        currentGroup = name
        print("== \(name)")
    }

    func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("  ok   \(message)")
        } else {
            failures.append("\(currentGroup): \(message)")
            print("  FAIL \(message)")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        expect(actual == expected, "\(message) (expected \(expected), got \(actual))")
    }

    func expectThrows<T>(_ message: String, _ body: () throws -> T, matching: (Error) -> Bool) {
        do {
            _ = try body()
            failures.append("\(currentGroup): \(message) (no error thrown)")
            print("  FAIL \(message) (no error thrown)")
        } catch {
            expect(matching(error), "\(message) (got \(error))")
        }
    }

    func summary() -> Int32 {
        print("")
        print("checks passed: \(passed)")
        print("checks failed: \(failures.count)")
        for failure in failures {
            print("  - \(failure)")
        }
        return failures.isEmpty ? 0 : 1
    }
}
