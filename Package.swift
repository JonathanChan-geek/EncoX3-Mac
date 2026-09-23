// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EncoX3",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EncoCore", targets: ["EncoCore"]),
        .library(name: "EncoBluetooth", targets: ["EncoBluetooth"]),
        .library(name: "EncoDiagnostics", targets: ["EncoDiagnostics"]),
        .executable(name: "encoctl", targets: ["encoctl"]),
        .executable(name: "EncoMenu", targets: ["EncoMenu"]),
    ],
    targets: [
        .target(name: "EncoCore"),
        .target(name: "EncoBluetooth", dependencies: ["EncoCore"]),
        // Diagnostic logic shared by the CLI and the menu bar app, so `probe` and `cycle-anc`
        // behave identically however they are launched.
        .target(name: "EncoDiagnostics", dependencies: ["EncoCore", "EncoBluetooth"]),
        .executableTarget(name: "encoctl", dependencies: ["EncoDiagnostics"]),
        .executableTarget(name: "EncoMenu", dependencies: ["EncoCore", "EncoBluetooth", "EncoDiagnostics"]),
        // Offline checks for EncoCore. This machine has no XCTest framework (Command Line
        // Tools only, no Xcode), so the checks are a dependency-free executable rather than
        // a test target: `swift run EncoCoreChecks` is the offline verification command.
        // Also depends on EncoDiagnostics so the journal guard (an unfinished restore record
        // must not be overwritten) is covered offline.
        .executableTarget(name: "EncoCoreChecks", dependencies: ["EncoCore", "EncoDiagnostics"], path: "Tests/EncoCoreTests"),
    ]
)
