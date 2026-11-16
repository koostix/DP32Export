import Foundation

public struct WavComparison {
    public var headersIdentical = false
    public var framesA: UInt64 = 0
    public var framesB: UInt64 = 0
    public var differing: UInt64 = 0
    public var largest: Int = 0
    public var ignoredDiffering: UInt64 = 0
    public var firstDifferences: [UInt64] = []
    public var sameLength: Bool { framesA == framesB }
}

public enum Compare {
    /// Compares two mono PCM WAV files sample by sample. Differences in the first
    /// `ignoreHead` frames are counted separately.
    public static func wavs(_ pathA: String, _ pathB: String, ignoreHead: UInt64 = 0) throws -> WavComparison {
        let a = try ReadOnlyFile(path: pathA)
        let b = try ReadOnlyFile(path: pathB)
        let ia = try Wav.info(of: a)
        let ib = try Wav.info(of: b)
        guard ia.channels == 1, ib.channels == 1, ia.bitsPerSample == ib.bitsPerSample,
              ia.bitsPerSample == 16 || ia.bitsPerSample == 24,
              ia.blockAlign == ia.bitsPerSample / 8, ib.blockAlign == ib.bitsPerSample / 8 else {
            throw Refusal("\(a.name) and \(b.name) are not mono PCM files of the same bit depth")
        }
        var result = WavComparison()
        result.framesA = ia.frames
        result.framesB = ib.frames
        if ia.dataOffset == ib.dataOffset, ia.dataOffset <= 4096 {
            result.headersIdentical = try a.bytes(at: 0, count: Int(ia.dataOffset)) == b.bytes(at: 0, count: Int(ib.dataOffset))
        }
        let width = ia.blockAlign
        let common = min(ia.frames, ib.frames)
        let chunk = 1 << 16
        var position: UInt64 = 0
        func value(_ bytes: [UInt8], _ k: Int) -> Int {
            if width == 3 {
                return Int(bytes[3 * k]) | (Int(bytes[3 * k + 1]) << 8) | (Int(Int8(bitPattern: bytes[3 * k + 2])) << 16)
            }
            return Int(bytes[2 * k]) | (Int(Int8(bitPattern: bytes[2 * k + 1])) << 8)
        }
        while position < common {
            let count = Int(min(UInt64(chunk), common - position))
            let da = try a.bytes(at: ia.dataOffset + position * UInt64(width), count: count * width)
            let db = try b.bytes(at: ib.dataOffset + position * UInt64(width), count: count * width)
            if da != db {
                for k in 0..<count {
                    let delta = abs(value(da, k) - value(db, k))
                    if delta == 0 { continue }
                    let frame = position + UInt64(k)
                    if frame < ignoreHead { result.ignoredDiffering += 1; continue }
                    result.differing += 1
                    result.largest = max(result.largest, delta)
                    if result.firstDifferences.count < 8 { result.firstDifferences.append(frame) }
                }
            }
            position += UInt64(count)
        }
        return result
    }
}
