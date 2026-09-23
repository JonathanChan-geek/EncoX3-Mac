import Foundation
import IOBluetooth
import EncoCore
import EncoBluetooth

/// Read-only enumeration of paired/connected devices and the target's cached SDP records.
/// It performs no channel open and no device write of any kind.
enum InspectCommand {
    static func run(arguments: [String]) -> Int32 {
        Diagnostics.printEnvironment()
        print("source: local SDP cache only (no RFCOMM channel is opened)")
        print("")

        let paired = EncoDeviceLocator.pairedDevices()
        print("paired device count: \(paired.count)")
        print("")

        print("--- connected devices (addresses masked) ---")
        let connected = EncoDeviceLocator.connectedDevices()
        if connected.isEmpty {
            print("- <none>")
        } else {
            for device in connected {
                print("- \(EncoDeviceLocator.targetName(for: device))  [\(AddressMask.mask(device.addressString))]")
            }
        }
        print("")

        if paired.isEmpty {
            Diagnostics.reportMissingDevices()
            return 3
        }

        print("--- target ---")
        guard let target = EncoDeviceLocator.target() else {
            print("no connected paired device named '\(EncoDeviceLocator.targetName)'")
            print("connected paired names: \(connected.map { EncoDeviceLocator.targetName(for: $0) }.joined(separator: ", "))")
            return 3
        }
        print("name: \(EncoDeviceLocator.targetName(for: target))")
        print("masked address: \(AddressMask.mask(target.addressString))")
        print("connected: \(target.isConnected())")
        print("")

        let records = (target.services as? [IOBluetoothSDPServiceRecord]) ?? []
        print("cached service record count: \(records.count)")
        print("")
        print("--- service records ---")
        for (index, record) in records.enumerated() {
            print("[\(index + 1)/\(records.count)]")
            print("  serviceName: \(record.getServiceName() ?? "<none>")")
            var channel: BluetoothRFCOMMChannelID = 0
            let channelStatus = record.getRFCOMMChannelID(&channel)
            if channelStatus == kIOReturnSuccess {
                print("  getRFCOMMChannelID: \(describe(channelStatus)), channelID=\(channel)")
            } else {
                print("  getRFCOMMChannelID: \(describe(channelStatus)) (not an RFCOMM service)")
            }
            print("")
        }

        print("--- vendor UUID lookup ---")
        print("target UUID: 0000079A-D102-11E1-9B23-00025B00A5A5")
        if let record = target.getServiceRecord(for: EncoDeviceLocator.controlServiceUUID) {
            var channel: BluetoothRFCOMMChannelID = 0
            let status = record.getRFCOMMChannelID(&channel)
            print("present: YES")
            print("serviceName: \(record.getServiceName() ?? "<none>")")
            if status == kIOReturnSuccess {
                print("rfcommChannelID: \(channel)")
            } else {
                print("rfcommChannelID: <none> (\(describe(status)))")
            }
        } else {
            print("present: NO")
        }
        return 0
    }
}
