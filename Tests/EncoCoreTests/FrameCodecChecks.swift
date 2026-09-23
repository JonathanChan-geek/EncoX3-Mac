import Foundation
import EncoCore

func frameCodecChecks(_ c: Checker) {
    c.group("FrameCodec")

    c.expectEqual(
        try? FrameCodec.encode(cmd: 0x0100, payload: [], sequence: 0xF0),
        [0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0x00],
        "capability query encodes to the documented layout"
    )

    c.expectEqual(
        try? FrameCodec.encode(cmd: 0x010C, payload: [0x01, 0x01], sequence: 0x12),
        [0xAA, 0x09, 0x00, 0x00, 0x0C, 0x01, 0x12, 0x02, 0x00, 0x01, 0x01],
        "command and payload length are little endian"
    )

    let tooLong = [UInt8](repeating: 0x11, count: FrameCodec.maxPayloadLength + 1)
    c.expectThrows("payload beyond the one-byte length field is refused", {
        try FrameCodec.encode(cmd: 0x0100, payload: tooLong)
    }, matching: { ($0 as? FrameCodecError) == .payloadTooLong(FrameCodec.maxPayloadLength + 1) })

    if let largest = try? FrameCodec.encode(cmd: 0x0100, payload: [UInt8](repeating: 0x11, count: FrameCodec.maxPayloadLength)) {
        c.expectEqual(Int(largest[1]), 255, "largest legal payload fills the length field")
        c.expectEqual(largest.count, FrameCodec.maxFrameSize, "largest legal frame is maxFrameSize bytes")
    } else {
        c.expect(false, "largest legal payload encodes")
    }

    let roundTrips: [(cmd: UInt16, payload: [UInt8])] = [
        (0x8106, [0x00, 0x04, 0x64, 0x00, 0x63, 0x01, 0x50, 0x00]),
        (0x8103, [0x00, 0x10, 0x74, 0x06]),
    ]
    for expected in roundTrips {
        guard let bytes = try? FrameCodec.encode(cmd: expected.cmd, payload: expected.payload, sequence: 0x08),
              let frame = try? FrameCodec.decode(bytes)
        else {
            c.expect(false, "round trip for cmd 0x\(String(expected.cmd, radix: 16))")
            continue
        }
        c.expectEqual(frame.cmd, expected.cmd, "round trip keeps cmd 0x\(String(expected.cmd, radix: 16))")
        c.expectEqual(frame.payload, expected.payload, "round trip keeps payload")
        c.expectEqual(frame.sequence, 0x08, "round trip keeps sequence")
        c.expectEqual(frame.raw, bytes, "round trip keeps raw bytes")
    }

    c.expectThrows("bad header is refused", {
        try FrameCodec.decode([0xAB, 0x07, 0, 0, 0, 1, 0xF0, 0, 0])
    }, matching: { ($0 as? FrameCodecError) == .badHeader(0xAB) })

    c.expectThrows("length below the header size is refused", {
        try FrameCodec.decode([0xAA, 0x03, 0, 0, 0, 1, 0xF0, 0, 0, 0, 0])
    }, matching: { ($0 as? FrameCodecError) == .invalidLength(totalLength: 3) })

    var mismatched = (try? FrameCodec.encode(cmd: 0x0100, payload: [0x01])) ?? []
    mismatched[7] = 0x05
    c.expectThrows("declared payload longer than the body is refused", {
        try FrameCodec.decode(mismatched)
    }, matching: { ($0 as? FrameCodecError) == .payloadLengthMismatch(declared: 5, available: 1) })

    var shortDeclared = (try? FrameCodec.encode(cmd: 0x0100, payload: [0x01, 0x02])) ?? []
    shortDeclared[7] = 0x01
    c.expectThrows("declared payload shorter than the body is refused", {
        try FrameCodec.decode(shortDeclared)
    }, matching: { ($0 as? FrameCodecError) == .payloadLengthMismatch(declared: 1, available: 2) })

    var withExtra = (try? FrameCodec.encode(cmd: 0x0100, payload: [0x01])) ?? []
    withExtra.append(0x00)
    c.expectThrows("trailing byte after a complete frame is refused", {
        try FrameCodec.decode(withExtra)
    }, matching: { ($0 as? FrameCodecError) == .trailingBytes(extra: 1) })
}
