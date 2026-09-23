import Foundation
import EncoCore

func frameStreamParserChecks(_ c: Checker) {
    c.group("FrameStreamParser")

    func frameBytes(cmd: UInt16, payload: [UInt8] = []) -> [UInt8] {
        (try? FrameCodec.encode(cmd: cmd, payload: payload)) ?? []
    }

    // Sticky frames in one chunk.
    var parser = FrameStreamParser()
    parser.append(frameBytes(cmd: 0x8106, payload: [0x00, 0x04]) + frameBytes(cmd: 0x8103, payload: [0x00, 0x10, 0x74, 0x06]))
    var frames = parser.drain()
    c.expectEqual(frames.map(\.cmd), [0x8106, 0x8103], "two frames in one chunk are both decoded")
    c.expectEqual(frames.count > 1 ? frames[1].payload : [], [0x00, 0x10, 0x74, 0x06], "second sticky frame keeps its payload")
    c.expect(parser.buffer.isEmpty, "sticky frames leave no residue")

    // One frame split across three chunks.
    let split = frameBytes(cmd: 0x810C, payload: [0x00, 0x01, 0x01, 0x02])
    parser = FrameStreamParser()
    parser.append(Array(split[0..<3]))
    c.expectEqual(parser.drain().count, 0, "partial frame is not emitted early")
    parser.append(Array(split[3..<6]))
    c.expectEqual(parser.drain().count, 0, "still partial after two chunks")
    parser.append(Array(split[6...]))
    frames = parser.drain()
    c.expectEqual(frames.count, 1, "split frame completes after the last chunk")
    if let frame = frames.first {
        c.expectEqual(frame.cmd, 0x810C, "split frame keeps its cmd")
        c.expectEqual(frame.payload, [0x00, 0x01, 0x01, 0x02], "split frame keeps its payload")
        c.expectEqual(frame.raw, split, "split frame keeps its raw bytes")
    }

    // Garbage before a frame.
    parser = FrameStreamParser()
    parser.append([0x00, 0x13, 0x37] + frameBytes(cmd: 0x8100, payload: [0x00]))
    c.expectEqual(parser.drainEvents(), [
        .discardedGarbage(count: 3),
        .frame(Frame(cmd: 0x8100, sequence: FrameCodec.defaultSequence, payload: [0x00], raw: frameBytes(cmd: 0x8100, payload: [0x00]))),
    ], "bytes before the header are discarded and the frame survives")
    c.expectEqual(parser.discardedByteCount, 3, "discarded byte count is reported")

    parser = FrameStreamParser()
    parser.append([0x01, 0x02, 0x03, 0x04])
    c.expectEqual(parser.drainEvents(), [.discardedGarbage(count: 4)], "a chunk with no header is dropped")
    c.expect(parser.buffer.isEmpty, "no header leaves an empty buffer")

    // Invalid length resynchronises and keeps the following frame.
    let good = frameBytes(cmd: 0x8103, payload: [0x00, 0x10, 0x74, 0x06])
    parser = FrameStreamParser()
    parser.append([0xAA, 0x02, 0x00, 0x00] + good)
    c.expectEqual(parser.drainEvents(), [
        .rejectedFrame(reason: .invalidLength(totalLength: 2), raw: [0xAA, 0x02]),
        .discardedGarbage(count: 3),
        .frame(Frame(cmd: 0x8103, sequence: FrameCodec.defaultSequence, payload: [0x00, 0x10, 0x74, 0x06], raw: good)),
    ], "impossible length resynchronises one byte later and keeps the good frame")
    c.expectEqual(parser.rejectedFrameCount, 1, "rejected frame count is reported")

    // Length-field disagreement with only the header present: reject without waiting.
    var mismatched = frameBytes(cmd: 0x8106, payload: [0x00, 0x04])
    mismatched[7] = 0x09
    parser = FrameStreamParser()
    parser.append(mismatched)
    let headerOnly = parser.drainEvents()
    c.expectEqual(headerOnly, [
        .rejectedFrame(
            reason: .payloadLengthMismatch(declared: 9, available: 2),
            raw: Array(mismatched.prefix(FrameCodec.headerSize))
        ),
        .discardedGarbage(count: 10),
    ], "length mismatch is decided at the header, without waiting for the missing body")

    parser = FrameStreamParser()
    parser.append(mismatched + good)
    let mismatchThenGood = parser.drainEvents()
    c.expectEqual(mismatchThenGood.count, 3, "bad length then garbage then the good frame")
    if mismatchThenGood.count == 3 {
        c.expectEqual(mismatchThenGood[2], .frame(Frame(
            cmd: 0x8103,
            sequence: FrameCodec.defaultSequence,
            payload: [0x00, 0x10, 0x74, 0x06],
            raw: good
        )), "a bad length pair does not block the following frame")
    }

    // The one-byte length field caps a frame at maxFrameSize; a declared max must simply wait.
    parser = FrameStreamParser()
    parser.append([0xAA, 0xFF, 0x00, 0x00])
    c.expectEqual(parser.drainEvents().count, 0, "declared max length waits for its body")
    c.expectEqual(parser.buffer.count, 4, "waiting for a body keeps only the received bytes")
    let full = frameBytes(cmd: 0x0100, payload: [UInt8](repeating: 0x5A, count: FrameCodec.maxPayloadLength))
    parser.append(Array(full.dropFirst(4)))
    frames = parser.drain()
    c.expectEqual(frames.count, 1, "max-length frame completes")
    if let frame = frames.first {
        c.expectEqual(frame.payload.count, FrameCodec.maxPayloadLength, "max-length frame keeps its payload length")
        c.expectEqual(frame.raw, full, "max-length frame keeps its raw bytes")
    }

    // Incomplete header.
    parser = FrameStreamParser()
    parser.append([0xAA])
    c.expectEqual(parser.drainEvents().count, 0, "a lone header byte waits")
    c.expectEqual(parser.buffer.count, 1, "a lone header byte is buffered")

    // Reset clears a partial frame.
    parser = FrameStreamParser()
    parser.append([0xAA, 0x09, 0x00])
    parser.reset()
    c.expect(parser.buffer.isEmpty, "reset clears a partial frame")
    parser.append(frameBytes(cmd: 0x8100, payload: [0x00]))
    c.expectEqual(parser.drain().map(\.cmd), [0x8100], "parser keeps working after reset")
}
