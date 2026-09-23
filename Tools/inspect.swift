import Foundation
import IOBluetooth

// Read-only probe: enumerates paired devices, prints cached SDP records of the
// target headset and reports RFCOMM channel IDs. It never opens an RFCOMM
// channel, never writes to the device and never pairs/unpairs anything.
// Default source of service records is the local cache; pass --sdp to force a
// live (still read-only) SDP query when the cache is empty.

let targetName = "OPPO Enco X3"
let targetUUIDBytes: [UInt8] = [
    0x00, 0x00, 0x07, 0x9A, 0xD1, 0x02, 0x11, 0xE1,
    0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5,
]
let bluetoothBaseUUID: [UInt8] = [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB,
]

let arguments = CommandLine.arguments
let forceSDPQuery = arguments.contains("--sdp")
let sdpQueryTimeout: TimeInterval = 10

func maskAddress(_ address: String?) -> String {
    guard let address = address, !address.isEmpty else { return "<unavailable>" }
    let parts = address.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { return "<unparsable>" }
    return parts[0...2].joined(separator: ":") + ":XX:XX:XX"
}

func hex(_ code: IOReturn) -> String {
    String(format: "0x%08X", UInt32(bitPattern: code))
}

func sanitize(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{0}", with: "").replacingOccurrences(of: "\n", with: " ")
}

func describeIOReturn(_ code: IOReturn) -> String {
    let status = ioReturnName(code) ?? (code == kIOReturnSuccess ? "kIOReturnSuccess" : "unknown")
    return "\(status) (\(hex(code)))"
}

func ioReturnName(_ code: IOReturn) -> String? {
    switch code {
    case kIOReturnSuccess: return "kIOReturnSuccess"
    case kIOReturnError: return "kIOReturnError"
    case kIOReturnNoDevice: return "kIOReturnNoDevice"
    case kIOReturnNotPermitted: return "kIOReturnNotPermitted"
    case kIOReturnNotFound: return "kIOReturnNotFound"
    case kIOReturnBadArgument: return "kIOReturnBadArgument"
    case kIOReturnNotOpen: return "kIOReturnNotOpen"
    case kIOReturnNotAttached: return "kIOReturnNotAttached"
    case kIOReturnBusy: return "kIOReturnBusy"
    case kIOReturnTimeout: return "kIOReturnTimeout"
    case kIOReturnUnsupported: return "kIOReturnUnsupported"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess"
    default: return nil
    }
}

func uuidBytes(_ uuid: IOBluetoothSDPUUID) -> [UInt8] {
    let length = Int(uuid.length)
    guard length > 0 else { return [] }
    var bytes = [UInt8](repeating: 0, count: length)
    bytes.withUnsafeMutableBytes { uuid.getBytes($0.baseAddress!, length: length) }
    return bytes
}

func expandToFullUUID(_ bytes: [UInt8]) -> [UInt8] {
    switch bytes.count {
    case 2, 4:
        return bytes + Array(bluetoothBaseUUID[bytes.count...])
    default:
        return bytes
    }
}

func formatUUID(_ bytes: [UInt8]) -> String {
    func group(_ range: Range<Int>) -> String {
        range.map { String(format: "%02X", bytes[$0]) }.joined()
    }
    switch bytes.count {
    case 2, 4:
        return "0x" + group(0..<bytes.count)
    case 16:
        return "\(group(0..<4))-\(group(4..<6))-\(group(6..<8))-\(group(8..<10))-\(group(10..<16))"
    default:
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}

func renderElement(_ element: IOBluetoothSDPDataElement) -> String {
    if let value = element.getUUIDValue() { return formatUUID(uuidBytes(value)) }
    if let items = element.getArrayValue() as? [IOBluetoothSDPDataElement] {
        return "{ " + items.map { renderElement($0) }.joined(separator: ", ") + " }"
    }
    if let number = element.getNumberValue() {
        if element.getTypeDescriptor() == kBluetoothSDPDataElementTypeBoolean {
            return number.boolValue ? "true" : "false"
        }
        return String(describing: number)
    }
    if element.getTypeDescriptor() == kBluetoothSDPDataElementTypeString,
       let string = element.getStringValue(), !string.isEmpty {
        return string
    }
    return String(describing: element)
}

func uuidValues(of element: IOBluetoothSDPDataElement) -> [IOBluetoothSDPUUID] {
    if let direct = element.getUUIDValue() { return [direct] }
    if let array = element.getArrayValue() as? [IOBluetoothSDPDataElement] {
        return array.flatMap { uuidValues(of: $0) }
    }
    return []
}

func serviceClassUUIDs(of record: IOBluetoothSDPServiceRecord) -> [IOBluetoothSDPUUID] {
    guard let element = record.attributes?[NSNumber(value: 0x0001)] as? IOBluetoothSDPDataElement else { return [] }
    return uuidValues(of: element)
}

final class SDPQueryWaiter: NSObject, IOBluetoothDeviceAsyncCallbacks {
    private(set) var status: IOReturn?
    private(set) var finished = false

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        self.status = status
        self.finished = true
    }

    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
}

func runSDPQuery(_ device: IOBluetoothDevice, timeout: TimeInterval) -> IOReturn {
    let waiter = SDPQueryWaiter()
    let started = device.performSDPQuery(waiter)
    guard started == kIOReturnSuccess else { return started }
    let deadline = Date().addingTimeInterval(timeout)
    while !waiter.finished && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return waiter.status ?? kIOReturnTimeout
}

func stringAttribute(_ record: IOBluetoothSDPServiceRecord, _ id: Int) -> String? {
    guard let element = record.attributes?[NSNumber(value: id)] as? IOBluetoothSDPDataElement else { return nil }
    return renderElement(element)
}

print("=== Enco X3 read-only Bluetooth probe ===")
print("timestamp: \(ISO8601DateFormatter().string(from: Date())) (local \(Date()))")
print("command: xcrun swift Tools/inspect.swift\(forceSDPQuery ? " --sdp" : "")")
print("service record source: \(forceSDPQuery ? "live SDP query (cache preferred, forced by --sdp)" : "local SDP cache only")")
print("")

let pairedDevices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
print("paired device count: \(pairedDevices.count)")
print("")

print("--- connected devices (names only, addresses masked) ---")
var connectedCount = 0
for device in pairedDevices where device.isConnected() {
    connectedCount += 1
    let name = device.name ?? "<unnamed>"
    print("- \(name)  [address \(maskAddress(device.addressString))]")
}
if connectedCount == 0 {
    print("- <none>")
}
print("")

print("--- target device ---")
guard let target = pairedDevices.first(where: { ($0.name ?? "") == targetName }) else {
    print("target '\(targetName)' not found among paired devices")
    exit(2)
}
print("matched name: \(target.name ?? "<unnamed>")")
print("masked address: \(maskAddress(target.addressString))")
print("connected: \(target.isConnected())")
print("")

var records = (target.services as? [IOBluetoothSDPServiceRecord]) ?? []
print("cached service record count: \(records.count)")

if forceSDPQuery {
    print("running read-only SDP query (timeout \(Int(sdpQueryTimeout))s)")
    let status = runSDPQuery(target, timeout: sdpQueryTimeout)
    print("sdpQueryComplete status: \(describeIOReturn(status))")
    records = (target.services as? [IOBluetoothSDPServiceRecord]) ?? []
    print("service record count after SDP query: \(records.count)")
} else if records.isEmpty {
    print("cache empty; rerun with --sdp to perform a read-only SDP query")
}
print("")

let targetFullUUID = expandToFullUUID(targetUUIDBytes)
print("--- service records ---")
for (index, record) in records.enumerated() {
    print("[\(index + 1)/\(records.count)]")
    print("  serviceName: \(sanitize(record.getServiceName() ?? "<none>"))")
    print("  serviceDescription: \(stringAttribute(record, 0x0005) ?? "<none>")")
    print("  recordDescription: \(sanitize(String(describing: record)))")

    var channel: BluetoothRFCOMMChannelID = 0
    let channelStatus = record.getRFCOMMChannelID(&channel)
    if channelStatus == kIOReturnSuccess {
        print("  getRFCOMMChannelID: \(describeIOReturn(channelStatus)), channelID=\(channel)")
    } else {
        print("  getRFCOMMChannelID: \(describeIOReturn(channelStatus)) (not an RFCOMM service)")
    }

    let uuids = serviceClassUUIDs(of: record)
    if uuids.isEmpty {
        print("  serviceClassIDList: <none>")
    } else {
        print("  serviceClassIDList:")
        for uuid in uuids {
            let bytes = uuidBytes(uuid)
            print("    - \(formatUUID(bytes)) (length \(bytes.count))")
        }
    }

    if let attributes = record.attributes {
        let sortedKeys = attributes.keys.sorted { lhs, rhs in
            (lhs as? NSNumber)?.intValue ?? 0 < (rhs as? NSNumber)?.intValue ?? 0
        }
        print("  attributes (\(sortedKeys.count)):")
        for key in sortedKeys {
            let keyID = (key as? NSNumber)?.intValue ?? 0
            let value = attributes[key]
            let text = (value as? IOBluetoothSDPDataElement).map { renderElement($0) }
                ?? String(describing: value)
            print("    0x\(String(format: "%04X", keyID)): \(sanitize(text))")
        }
    } else {
        print("  attributes: <none>")
    }
    print("")
}

print("--- vendor UUID lookup ---")
print("target UUID: \(formatUUID(targetUUIDBytes))")
var matchingRecords: [(index: Int, name: String, channel: BluetoothRFCOMMChannelID?)] = []
for (index, record) in records.enumerated() {
    let matched = serviceClassUUIDs(of: record).contains { expandToFullUUID(uuidBytes($0)) == targetFullUUID }
    if matched {
        var channel: BluetoothRFCOMMChannelID = 0
        let status = record.getRFCOMMChannelID(&channel)
        matchingRecords.append((index + 1, record.getServiceName() ?? "<none>", status == kIOReturnSuccess ? channel : nil))
    }
}
if matchingRecords.isEmpty {
    print("present: NO")
    print("no service record exposes the vendor UUID in the enumerated records")
} else {
    print("present: YES (\(matchingRecords.count) record(s))")
    for match in matchingRecords {
        let channelText = match.channel.map { String($0) } ?? "<no RFCOMM channel id>"
        print("  record \(match.index) serviceName=\(match.name) rfcommChannelID=\(channelText)")
    }
}
print("")
print("=== probe finished (read-only, no RFCOMM channel opened) ===")
