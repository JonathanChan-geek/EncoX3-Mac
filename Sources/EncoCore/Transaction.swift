import Foundation

/// Request/response correlation for the vendor protocol.
///
/// A response carries the request command with bit 15 set (`0x010C` -> `0x810C`) and echoes
/// the request's transaction id in `sequence` — confirmed on the device: a request sent with
/// seq 0xF0 came back with seq 0xF0 (see `evidence/local/probe-bundle.txt`).
public enum ResponseCorrelation {
    public static func responseCommand(for request: UInt16) -> UInt16 {
        request | 0x8000
    }

    public static func isResponse(_ frame: Frame, to requestCommand: UInt16, sequence: UInt8) -> Bool {
        frame.cmd == responseCommand(for: requestCommand) && frame.sequence == sequence
    }

    /// Status byte of a response payload, when the layout has one.
    public static func status(_ frame: Frame) -> UInt8? {
        frame.payload.first
    }

    /// Classifies a response by its status byte. A response with no status byte at all is
    /// `missing` — never a success, whatever else the payload contains.
    public static func classify(_ frame: Frame) -> ResponseStatus {
        guard let status = frame.payload.first else { return .missing }
        return status == 0 ? .ok(status) : .rejected(status)
    }
}

public enum ResponseStatus: Equatable {
    /// Status byte present and zero.
    case ok(UInt8)
    case rejected(UInt8)
    /// No status byte in the payload: not an acknowledgement.
    case missing
}

/// Outcome of a serialized write-then-verify transaction.
public struct TransactionResult: Equatable {
    public enum Outcome: Equatable {
        /// The device acknowledged the write with status 0 and the readback matched the target.
        case verified
        /// Status 0, but the readback is a different (interpretable) value — the device may
        /// have normalised the mode. Never reported as success.
        case normalized
        /// The device accepted the write but the readback matched nothing we can explain.
        case readbackMismatch
        case rejected(status: UInt8)
        /// A response arrived without a usable status byte: not an acknowledgement.
        case malformedResponse(String)
        case timedOut
        case notSent(reason: String)
    }

    public let requestCommand: UInt16
    public let requestSequence: UInt8
    public let requestPayload: [UInt8]
    public let ackSequence: UInt8?
    public let ackStatus: UInt8?
    public let querySequence: UInt8?
    public let readbackRaw: UInt32?
    public let targetRaw: UInt32
    public let outcome: Outcome
    public let detail: String

    public init(
        requestCommand: UInt16,
        requestSequence: UInt8,
        requestPayload: [UInt8],
        ackSequence: UInt8?,
        ackStatus: UInt8?,
        querySequence: UInt8?,
        readbackRaw: UInt32?,
        targetRaw: UInt32,
        outcome: Outcome,
        detail: String
    ) {
        self.requestCommand = requestCommand
        self.requestSequence = requestSequence
        self.requestPayload = requestPayload
        self.ackSequence = ackSequence
        self.ackStatus = ackStatus
        self.querySequence = querySequence
        self.readbackRaw = readbackRaw
        self.targetRaw = targetRaw
        self.outcome = outcome
        self.detail = detail
    }
}

public enum TransactionError: Error, CustomStringConvertible {
    case busy
    case notOpen

    public var description: String {
        switch self {
        case .busy: return "another transaction is in flight"
        case .notOpen: return "control channel is not open"
        }
    }
}
