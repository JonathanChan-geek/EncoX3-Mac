import Foundation

enum Timestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func now() -> String { formatter.string(from: Date()) }

    static func formatted(_ date: Date) -> String { formatter.string(from: date) }
}

enum Diagnostics {
    static func printEnvironment() {
        print("timestamp: \(Timestamp.now())")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("command: \(CommandLine.arguments.joined(separator: " "))")
    }

    /// Reports what the system sees, and flags a likely Bluetooth permission problem.
    /// Nothing here changes system state; system_profiler is only read.
    static func reportMissingDevices() {
        print("paired devices visible to this process: 0")
        print("checking what the system reports ...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            print("could not run system_profiler; Bluetooth permission state unknown")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        let connectedBlock = text.contains("Connected:") || text.contains("device_connected")
        if connectedBlock {
            print("system_profiler reports connected Bluetooth devices, but IOBluetooth returned none.")
            print("This is the signature of a missing Bluetooth permission for the running process.")
            print("Open System Settings > Privacy & Security > Bluetooth and enable the terminal app")
            print("that launched encoctl (or encoctl itself when run from Finder), then run again.")
            print("No TCC setting was modified by this tool.")
        } else {
            print("system_profiler reports no connected Bluetooth device either.")
        }
    }
}
