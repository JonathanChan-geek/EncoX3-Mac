import Foundation

/// One decoded protocol frame.
///
/// `raw` keeps the exact bytes as they arrived on the wire, so evidence and tests can
/// always fall back to what the device actually sent.
public struct Frame: Equatable {
    public let cmd: UInt16
    public let sequence: UInt8
    public let payload: [UInt8]
    public let raw: [UInt8]

    public init(cmd: UInt16, sequence: UInt8, payload: [UInt8], raw: [UInt8]) {
        self.cmd = cmd
        self.sequence = sequence
        self.payload = payload
        self.raw = raw
    }

    public var hex: String { Hex.string(raw) }
    public var payloadHex: String { Hex.string(payload) }
}

public enum FrameCodecError: Error, Equatable {
    /// The payload does not fit the one-byte length field.
    case payloadTooLong(Int)
    case invalidLength(totalLength: Int)
    case payloadLengthMismatch(declared: Int, available: Int)
    case notEnoughBytes(needed: Int, available: Int)
    case trailingBytes(extra: Int)
    case badHeader(UInt8)
}

/// Classic SPP/RFCOMM framing:
/// `AA len 00 00 cmdLo cmdHi seq payLenLo payLenHi payload`, where `len = 7 + payload.count`
/// and both the command word and the payload length are little endian.
public enum FrameCodec {
    public static let header: UInt8 = 0xAA
    /// Fixed header before the payload: AA + len + 00 00 + cmd + seq + payLen.
    public static let headerSize = 9
    /// `len` is a single byte, so the largest expressible payload is 255 - 7.
    public static let maxPayloadLength = 248
    /// Largest frame the one-byte length field can express: len 255 + header byte + len byte.
    public static let maxFrameSize = 257
    /// Transaction id used by the reference implementation for requests.
    public static let defaultSequence: UInt8 = 0xF0

    public static func encode(cmd: UInt16, payload: [UInt8] = [], sequence: UInt8 = defaultSequence) throws -> [UInt8] {
        guard payload.count <= maxPayloadLength else {
            throw FrameCodecError.payloadTooLong(payload.count)
        }
        let totalLength = 7 + payload.count
        var bytes: [UInt8] = [
            header,
            UInt8(totalLength),
            0x00,
            0x00,
            UInt8(cmd & 0xFF),
            UInt8((cmd >> 8) & 0xFF),
            sequence,
            UInt8(payload.count & 0xFF),
            UInt8((payload.count >> 8) & 0xFF),
        ]
        bytes.append(contentsOf: payload)
        return bytes
    }

    /// Strict single-frame decode: the buffer must hold exactly one well-formed frame.
    /// A length pair that disagrees with the frame length is rejected outright; padding or
    /// any other leniency would need real captured evidence first.
    public static func decode(_ bytes: [UInt8]) throws -> Frame {
        guard let first = bytes.first else {
            throw FrameCodecError.notEnoughBytes(needed: headerSize, available: 0)
        }
        guard first == header else { throw FrameCodecError.badHeader(first) }
        guard bytes.count >= 2 else {
            throw FrameCodecError.notEnoughBytes(needed: headerSize, available: bytes.count)
        }
        let totalLength = Int(bytes[1])
        guard totalLength >= 7, totalLength + 2 <= maxFrameSize else {
            throw FrameCodecError.invalidLength(totalLength: totalLength)
        }
        let frameLength = totalLength + 2
        guard bytes.count >= frameLength else {
            throw FrameCodecError.notEnoughBytes(needed: frameLength, available: bytes.count)
        }
        guard bytes.count == frameLength else {
            throw FrameCodecError.trailingBytes(extra: bytes.count - frameLength)
        }
        guard bytes.count >= headerSize else {
            throw FrameCodecError.notEnoughBytes(needed: headerSize, available: bytes.count)
        }
        let payloadLength = Int(bytes[7]) | Int(bytes[8]) << 8
        let available = frameLength - headerSize
        guard payloadLength == available else {
            throw FrameCodecError.payloadLengthMismatch(declared: payloadLength, available: available)
        }
        let raw = Array(bytes[0..<frameLength])
        let cmd = UInt16(raw[4]) | UInt16(raw[5]) << 8
        return Frame(
            cmd: cmd,
            sequence: raw[6],
            payload: Array(raw[headerSize..<headerSize + payloadLength]),
            raw: raw
        )
    }
}
