import Foundation

/// Events produced while draining the receive buffer.
public enum FrameStreamEvent: Equatable {
    case frame(Frame)
    /// Bytes before the next `0xAA` were dropped.
    case discardedGarbage(count: Int)
    /// A frame start was rejected and the parser resynchronised one byte later.
    case rejectedFrame(reason: FrameCodecError, raw: [UInt8])
}

/// Incremental parser for the RFCOMM byte stream.
///
/// RFCOMM hands over arbitrary chunks: one callback may carry half a frame, two frames,
/// or a frame split across three callbacks. The parser buffers until a full frame is
/// present and resynchronises by one byte when a length field cannot be trusted, so a
/// single corrupt header cannot wedge the stream.
///
/// Both length fields are required to agree exactly (`len == 7 + payloadLen`); a frame
/// whose fields disagree is rejected rather than accepted with a shortened payload.
public struct FrameStreamParser {
    public private(set) var buffer: [UInt8] = []
    public private(set) var discardedByteCount = 0
    public private(set) var rejectedFrameCount = 0
    public private(set) var frameCount = 0

    public init() {}

    public mutating func append(_ data: [UInt8]) {
        guard !data.isEmpty else { return }
        buffer.append(contentsOf: data)
    }

    public mutating func reset() {
        buffer.removeAll()
    }

    /// Returns the next event, or nil when the buffer holds an incomplete frame.
    public mutating func next() -> FrameStreamEvent? {
        while true {
            guard let start = buffer.firstIndex(of: FrameCodec.header) else {
                guard !buffer.isEmpty else { return nil }
                let dropped = buffer.count
                buffer.removeAll()
                discardedByteCount += dropped
                return .discardedGarbage(count: dropped)
            }
            if start > 0 {
                buffer.removeFirst(start)
                discardedByteCount += start
                return .discardedGarbage(count: start)
            }
            guard buffer.count >= 2 else { return nil }

            let totalLength = Int(buffer[1])
            guard totalLength >= 7, totalLength + 2 <= FrameCodec.maxFrameSize else {
                let head = Array(buffer.prefix(min(2, buffer.count)))
                buffer.removeFirst(1)
                rejectedFrameCount += 1
                return .rejectedFrame(reason: .invalidLength(totalLength: totalLength), raw: head)
            }

            let frameLength = totalLength + 2

            // With the full 9-byte header in hand the two length fields must agree. Checking
            // here means a bad large length cannot stall a good frame behind up to 257 bytes
            // of never-arriving body.
            if buffer.count >= FrameCodec.headerSize {
                let header = Array(buffer.prefix(FrameCodec.headerSize))
                let payloadLength = Int(header[7]) | Int(header[8]) << 8
                let available = frameLength - FrameCodec.headerSize
                guard payloadLength == available else {
                    buffer.removeFirst(1)
                    rejectedFrameCount += 1
                    return .rejectedFrame(
                        reason: .payloadLengthMismatch(declared: payloadLength, available: available),
                        raw: header
                    )
                }
            }

            guard buffer.count >= frameLength else { return nil }

            let raw = Array(buffer.prefix(frameLength))
            let payloadLength = Int(raw[7]) | Int(raw[8]) << 8
            let available = frameLength - FrameCodec.headerSize
            guard payloadLength == available else {
                buffer.removeFirst(1)
                rejectedFrameCount += 1
                return .rejectedFrame(
                    reason: .payloadLengthMismatch(declared: payloadLength, available: available),
                    raw: raw
                )
            }

            buffer.removeFirst(frameLength)
            let cmd = UInt16(raw[4]) | UInt16(raw[5]) << 8
            frameCount += 1
            return .frame(Frame(
                cmd: cmd,
                sequence: raw[6],
                payload: Array(raw[FrameCodec.headerSize..<FrameCodec.headerSize + payloadLength]),
                raw: raw
            ))
        }
    }

    /// Drains every complete frame; rejected or garbage bytes are swallowed into the counters.
    public mutating func drain() -> [Frame] {
        drainEvents().compactMap { event in
            if case .frame(let frame) = event { return frame }
            return nil
        }
    }

    public mutating func drainEvents() -> [FrameStreamEvent] {
        var events: [FrameStreamEvent] = []
        while let event = next() { events.append(event) }
        return events
    }
}
