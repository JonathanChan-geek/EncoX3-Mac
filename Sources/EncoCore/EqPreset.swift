import Foundation

/// One equalizer entry from the `0x0122` list response.
///
/// Layout per entry (upstream `OppoProtocol.ParseEqAll`, confirmed byte for byte by the captured
/// X3 response):
/// `[isSelected][minGainSigned][maxGainSigned][eqId][nameLen][nameUTF-8][freqCount][freqLE16 + gainSigned]×freqCount`
public struct EqPreset: Equatable {
    public let isSelected: Bool
    /// Signed limits the device reports for this preset's gains.
    public let minGain: Int8
    public let maxGain: Int8
    public let id: Int
    public let name: String
    /// Centre frequencies in Hz (unsigned 16-bit little endian).
    public let frequencies: [Int]
    /// Gains in dB (signed byte).
    public let gains: [Int8]
    public let rawEntry: [UInt8]

    public init(
        isSelected: Bool,
        minGain: Int8,
        maxGain: Int8,
        id: Int,
        name: String,
        frequencies: [Int],
        gains: [Int8],
        rawEntry: [UInt8]
    ) {
        self.isSelected = isSelected
        self.minGain = minGain
        self.maxGain = maxGain
        self.id = id
        self.name = name
        self.frequencies = frequencies
        self.gains = gains
        self.rawEntry = rawEntry
    }

    /// Compares the curve only: selection changes while switching presets, the curve must not.
    /// Ids are indexed defensively so a duplicated id can never abort the comparison.
    public static func sameCurves(_ lhs: [EqPreset], _ rhs: [EqPreset]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let left = lhs.sorted { $0.id < $1.id }
        let right = rhs.sorted { $0.id < $1.id }
        for (a, b) in zip(left, right) {
            guard a.id == b.id, a.frequencies == b.frequencies, a.gains == b.gains else { return false }
        }
        return true
    }

    /// Ids whose curve or presence differs, for reporting a failed restore.
    public static func curveDifferences(_ original: [EqPreset], _ current: [EqPreset]) -> [String] {
        var notes: [String] = []
        var originalById: [Int: EqPreset] = [:]
        for preset in original { originalById[preset.id] = preset }
        var currentById: [Int: EqPreset] = [:]
        for preset in current { currentById[preset.id] = preset }
        for id in Set(originalById.keys).union(currentById.keys).sorted() {
            switch (originalById[id], currentById[id]) {
            case (let a?, let b?):
                if a.frequencies != b.frequencies { notes.append("id \(id) 频率变化 \(a.frequencies) → \(b.frequencies)") }
                if a.gains != b.gains { notes.append("id \(id) 增益变化 \(a.gains) → \(b.gains)") }
            case (let a?, nil):
                notes.append("id \(id) 恢复后消失（原 \(a.frequencies)/\(a.gains)）")
            case (nil, let b?):
                notes.append("id \(id) 恢复后新增（现 \(b.frequencies)/\(b.gains)）")
            case (nil, nil):
                break
            }
        }
        return notes
    }
}

/// Parser for the `0x0122` (`getAllEqInfo`) response.
///
/// Strict by design: a status byte is required, every entry must be complete, each frequency row
/// needs its three bytes, and the entries must consume the payload exactly. Anything else is
/// rejected whole and left raw — a partially applied curve would be worse than no data.
public enum EqPresetParser {
    public struct Result: Equatable {
        public let presets: [EqPreset]
        public let count: Int
    }

    public static func parse(_ payload: [UInt8]) -> Result? {
        guard let status = payload.first, status == 0 else { return nil }
        guard payload.count >= 2 else { return nil }
        let count = Int(payload[1])
        guard count > 0, count <= 32 else { return nil }

        var position = 2
        var presets: [EqPreset] = []
        var seenIDs = Set<Int>()
        for _ in 0..<count {
            let entryStart = position
            // isSelected, min, max, eqId, nameLen
            guard position + 5 <= payload.count else { return nil }
            let isSelected = payload[position] != 0
            let minGain = Int8(bitPattern: payload[position + 1])
            let maxGain = Int8(bitPattern: payload[position + 2])
            let id = Int(payload[position + 3])
            let nameLength = Int(payload[position + 4])
            position += 5

            guard position + nameLength <= payload.count else { return nil }
            let nameBytes = Array(payload[position..<position + nameLength])
            position += nameLength
            guard let name = decodeName(nameBytes) else { return nil }

            guard position + 1 <= payload.count else { return nil }
            let frequencyCount = Int(payload[position])
            position += 1
            guard frequencyCount > 0, frequencyCount <= 32 else { return nil }
            guard position + frequencyCount * 3 <= payload.count else { return nil }

            var frequencies: [Int] = []
            var gains: [Int8] = []
            for _ in 0..<frequencyCount {
                let value = Int(payload[position]) | Int(payload[position + 1]) << 8
                frequencies.append(value)
                gains.append(Int8(bitPattern: payload[position + 2]))
                position += 3
            }

            // Duplicate ids would make curves ambiguous (and index-by-id unsafe), so the whole
            // frame is rejected instead of picking one.
            guard seenIDs.insert(id).inserted else { return nil }

            presets.append(EqPreset(
                isSelected: isSelected,
                minGain: minGain,
                maxGain: maxGain,
                id: id,
                name: name,
                frequencies: frequencies,
                gains: gains,
                rawEntry: Array(payload[entryStart..<position])
            ))
        }

        guard position == payload.count else { return nil }
        return Result(presets: presets, count: count)
    }

    /// Only clean UTF-8 is accepted, so a wrong offset cannot masquerade as a name.
    private static func decodeName(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return "" }
        let text = String(decoding: bytes, as: UTF8.self)
        guard !text.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else { return nil }
        return text
    }
}
