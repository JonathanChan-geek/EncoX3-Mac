import Foundation

/// Parser for the `0x8112` multi-connect list (also carried by `0x0204` sub type `0x06`).
///
/// Fixed layout, matching the upstream reference and the captured X3 payload byte for byte:
///
/// ```
/// [status][count] then count × ( MAC(6, little endian) | elementByte | connectionState | flag | nameLen | name(UTF-8) )
/// ```
///
/// The parse is all-or-nothing: every entry must stay inside the payload, every `nameLen` must
/// have its bytes, `connectionState` must be 0…2, and the entries must consume the payload
/// exactly. Anything else is treated as unknown and left raw — no per-entry guessing.
public enum MultiConnectParser {
    public static func parse(_ body: [UInt8], count: Int) -> [ConnectedDevice]? {
        guard count > 0, count <= 8 else { return nil }
        var position = 0
        var devices: [ConnectedDevice] = []

        for _ in 0..<count {
            let entryStart = position
            guard position + 10 <= body.count else { return nil }

            let macBytes = Array(body[position..<position + 6])
            position += 6
            let elementByte = body[position]
            let connectionState = body[position + 1]
            let flags = body[position + 2]
            let nameLength = Int(body[position + 3])
            position += 4

            guard connectionState <= 2 else { return nil }
            guard position + nameLength <= body.count else { return nil }
            let nameBytes = Array(body[position..<position + nameLength])
            position += nameLength
            guard let name = decodeName(nameBytes) else { return nil }

            devices.append(ConnectedDevice(
                address: macBytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":"),
                name: name,
                elementByte: elementByte,
                connectionState: connectionState,
                flags: flags,
                rawEntry: Array(body[entryStart..<position])
            ))
        }

        guard position == body.count else { return nil }
        return devices
    }

    /// Accepts only UTF-8 that decodes cleanly, so a wrong offset cannot masquerade as a name.
    private static func decodeName(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return "" }
        let text = String(decoding: bytes, as: UTF8.self)
        guard !text.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else { return nil }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
