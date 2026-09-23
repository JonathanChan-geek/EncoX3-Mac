import Foundation
import IOBluetooth
import EncoCore

/// Address masking for anything that leaves this process (logs, evidence).
public enum AddressMask {
    /// Keeps the OUI and hides the device-unique part: `40:72:18:XX:XX:XX`.
    public static func mask(_ address: String?) -> String {
        guard let address, !address.isEmpty else { return "<unavailable>" }
        let parts = address.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return "<unparsable>" }
        return parts[0...2].joined(separator: ":") + ":XX:XX:XX"
    }
}

public enum EncoBluetoothError: Error, CustomStringConvertible {
    case targetNotFound(String)
    case sdpQueryFailed(IOReturn)
    case serviceRecordNotFound
    case rfcommChannelUnavailable(IOReturn)
    case channelOpenFailed(IOReturn)
    case channelOpenTimeout(TimeInterval)
    case sendFailed(IOReturn)

    public var description: String {
        switch self {
        case .targetNotFound(let name):
            return "no connected paired device named '\(name)'"
        case .sdpQueryFailed(let status):
            return "SDP query failed with \(describe(status))"
        case .serviceRecordNotFound:
            return "vendor control service record not found in the device's SDP records"
        case .rfcommChannelUnavailable(let status):
            return "vendor service has no RFCOMM channel id (\(describe(status)))"
        case .channelOpenFailed(let status):
            return "RFCOMM channel open failed with \(describe(status))"
        case .channelOpenTimeout(let seconds):
            return "RFCOMM channel open did not complete within \(Int(seconds))s"
        case .sendFailed(let status):
            return "writeAsync failed with \(describe(status))"
        }
    }
}

public func describe(_ status: IOReturn) -> String {
    let name: String
    switch status {
    case kIOReturnSuccess: name = "kIOReturnSuccess"
    case kIOReturnError: name = "kIOReturnError"
    case kIOReturnNoDevice: name = "kIOReturnNoDevice"
    case kIOReturnNotPermitted: name = "kIOReturnNotPermitted"
    case kIOReturnNotFound: name = "kIOReturnNotFound"
    case kIOReturnBadArgument: name = "kIOReturnBadArgument"
    case kIOReturnNotOpen: name = "kIOReturnNotOpen"
    case kIOReturnNotAttached: name = "kIOReturnNotAttached"
    case kIOReturnBusy: name = "kIOReturnBusy"
    case kIOReturnTimeout: name = "kIOReturnTimeout"
    case kIOReturnUnsupported: name = "kIOReturnUnsupported"
    case kIOReturnExclusiveAccess: name = "kIOReturnExclusiveAccess"
    default: name = "unknown"
    }
    return String(format: "%@ (0x%08X)", name, UInt32(bitPattern: status))
}

/// Locates the headset. Only paired devices that are already connected are considered —
/// this app never opens a baseband connection of its own.
public enum EncoDeviceLocator {
    public static let targetName = "OPPO Enco X3"

    /// OPPO/realme `oppointeraction` control service.
    public static let controlServiceUUIDBytes: [UInt8] = [
        0x00, 0x00, 0x07, 0x9A, 0xD1, 0x02, 0x11, 0xE1,
        0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5,
    ]

    public static var controlServiceUUID: IOBluetoothSDPUUID {
        IOBluetoothSDPUUID(bytes: controlServiceUUIDBytes, length: controlServiceUUIDBytes.count)
    }

    public static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    public static func connectedDevices() -> [IOBluetoothDevice] {
        pairedDevices().filter { $0.isConnected() }
    }

    /// The paired device named `targetName` that the system currently reports as connected.
    ///
    /// Only paired devices whose name matches exactly are considered, and `isConnected()` is the
    /// primary source. On this machine that flag can read `false` for a headset that
    /// `system_profiler` still lists under `device_connected` (observed 2026-09-23), so a `false`
    /// result falls back to the read-only report below. The fallback never matches on name: the
    /// paired device's full address must equal an address the report puts under
    /// `device_connected`, so a different device cannot be picked. Nothing here opens a baseband
    /// connection — the fallback only reads what the system already believes.
    public static func target() -> IOBluetoothDevice? {
        let candidates = pairedDevices().filter { ($0.name ?? "") == targetName }
        guard !candidates.isEmpty else { return nil }
        for device in candidates where device.isConnected() {
            return device
        }
        let reported = SystemProfilerBluetooth.connectedAddresses()
        guard !reported.isEmpty else { return nil }
        for device in candidates {
            guard let address = normalizedAddress(device.addressString ?? "") else { continue }
            if reported.contains(address) { return device }
        }
        return nil
    }

    public static func targetName(for device: IOBluetoothDevice) -> String {
        device.name ?? "<unnamed>"
    }

    /// Canonical form of a 48-bit address: six uppercase hex bytes joined by colons.
    ///
    /// Only the `AA:BB:CC:DD:EE:FF` / `AA-BB-…` shapes are accepted, so a name, a numeric id or
    /// a partial address can never be compared as if it were an address.
    static func normalizedAddress(_ text: String) -> String? {
        let digits = text
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard digits.count == 12, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        let upper = digits.uppercased()
        var parts: [String] = []
        var index = upper.startIndex
        while index < upper.endIndex {
            let next = upper.index(index, offsetBy: 2)
            parts.append(String(upper[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }
}

/// What the system reports as connected, read once per cache window to cross-check
/// `IOBluetoothDevice.isConnected()`.
///
/// The query is bounded to 3s and its result is cached for 5s. Standard output goes to a private
/// 0600 temporary file instead of a pipe: a pipe nobody drains can fill up while the caller
/// waits, which is exactly the deadlock this avoids. The file is deleted on every exit path, and
/// no address or device name is ever logged. A query that times out returns an empty set *and*
/// drops the cache, so a stale read can never keep a device looking online.
///
/// Single-threaded use only, like the rest of this target: the cache is plain static state.
enum SystemProfilerBluetooth {
    static let timeout: TimeInterval = 3
    static let cacheLifetime: TimeInterval = 5

    private static var cached: (at: Date, addresses: Set<String>)?

    /// Pure extraction: every `device_address` found beneath a `device_connected` entry.
    ///
    /// Subtrees under `device_not_connected` are never entered, so a device the system lists as
    /// disconnected cannot be reported as connected. Unparsable input yields an empty set.
    static func connectedAddresses(inProfilerJSON data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else { return [] }
        var found: Set<String> = []
        collectConnected(in: root, into: &found)
        return found
    }

    static func connectedAddresses() -> Set<String> {
        if let cached, Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.addresses
        }
        guard let data = profilerJSON() else {
            cached = nil
            return []
        }
        let addresses = connectedAddresses(inProfilerJSON: data)
        cached = (Date(), addresses)
        return addresses
    }

    private static func collectConnected(in value: Any, into found: inout Set<String>) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                if key == "device_connected" {
                    collectAddresses(in: child, into: &found)
                } else if key != "device_not_connected" {
                    collectConnected(in: child, into: &found)
                }
            }
        case let array as [Any]:
            for child in array { collectConnected(in: child, into: &found) }
        default:
            break
        }
    }

    private static func collectAddresses(in value: Any, into found: inout Set<String>) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                if key == "device_address", let text = child as? String,
                   let address = EncoDeviceLocator.normalizedAddress(text) {
                    found.insert(address)
                } else {
                    collectAddresses(in: child, into: &found)
                }
            }
        case let array as [Any]:
            for child in array { collectAddresses(in: child, into: &found) }
        default:
            break
        }
    }

    /// Runs the profiler with its output on a private file, waiting at most `timeout`.
    /// Returns nil on timeout, launch failure, or a non-zero exit.
    private static func profilerJSON() -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enco-spbt-\(UUID().uuidString).json")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = handle
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// Drives the run loop so IOBluetooth delegate callbacks (which are delivered on this
/// thread's run loop) can fire while a synchronous caller waits.
public enum RunLoopPump {
    public static func pump(until deadline: Date, interval: TimeInterval = 0.02, shouldStop: () -> Bool = { false }) {
        while !shouldStop() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
        }
    }

    public static func pump(for seconds: TimeInterval, interval: TimeInterval = 0.02) {
        pump(until: Date().addingTimeInterval(seconds), interval: interval)
    }
}

/// Async SDP query completion target.
public final class SDPQueryWaiter: NSObject, IOBluetoothDeviceAsyncCallbacks {
    public var onComplete: ((IOReturn) -> Void)?
    public private(set) var status: IOReturn?
    public private(set) var finished = false

    public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        self.status = status
        finished = true
        onComplete?(status)
    }

    public func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    public func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
}
