import Foundation

public struct WavInfo: Equatable {
    public var fmtChunkSize: UInt32
    public var formatTag: UInt16
    public var channels: Int
    public var sampleRate: Int
    public var bitsPerSample: Int
    public var blockAlign: Int
    public var dataOffset: UInt64
    public var dataBytes: UInt64

    public var frames: UInt64 { blockAlign > 0 ? dataBytes / UInt64(blockAlign) : 0 }
    /// PCM with the 16-byte fmt chunk the DP-32SD writes.
    public var isClassicPCM: Bool { fmtChunkSize == 16 && formatTag == 1 }
}

public enum Wav {
    /// Reads the fmt and data chunk headers. Throws when the file is not a complete WAV.
    public static func info(of file: ReadOnlyFile) throws -> WavInfo {
        let bad = Refusal("\(file.name) is not a readable WAV file")
        guard file.size >= 12 else { throw bad }
        let riff = try file.bytes(at: 0, count: 12)
        guard Array(riff[0..<4]) == Array("RIFF".utf8), Array(riff[8..<12]) == Array("WAVE".utf8) else { throw bad }
        var offset: UInt64 = 12
        var fmt: [UInt8]? = nil
        var fmtSize: UInt32 = 0
        for _ in 0..<64 {
            guard offset + 8 <= file.size else { break }
            let head = try file.bytes(at: offset, count: 8)
            let id = Array(head[0..<4])
            let size = UInt64(le32(head, 4))
            if id == Array("fmt ".utf8) {
                guard size >= 16, offset + 8 + 16 <= file.size else { throw bad }
                fmt = try file.bytes(at: offset + 8, count: 16)
                fmtSize = UInt32(size)
            } else if id == Array("data".utf8) {
                guard let f = fmt, offset + 8 + size <= file.size else { throw bad }
                return WavInfo(
                    fmtChunkSize: fmtSize,
                    formatTag: le16(f, 0),
                    channels: Int(le16(f, 2)),
                    sampleRate: Int(le32(f, 4)),
                    bitsPerSample: Int(le16(f, 14)),
                    blockAlign: Int(le16(f, 12)),
                    dataOffset: offset + 8,
                    dataBytes: size)
            }
            offset += 8 + size + (size & 1)
        }
        throw bad
    }

    /// The 44-byte header the DP-32SD writes in front of PCM data.
    public static func header(sampleRate: Int, bits: Int, channels: Int, dataBytes: UInt32) -> [UInt8] {
        var h = [UInt8]()
        func put32(_ v: UInt32) { for s in [0, 8, 16, 24] { h.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        func put16(_ v: UInt16) { h.append(UInt8(v & 0xFF)); h.append(UInt8(v >> 8)) }
        let align = channels * bits / 8
        h += Array("RIFF".utf8); put32(36 + dataBytes)
        h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); put32(16)
        put16(1); put16(UInt16(channels))
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * align))
        put16(UInt16(align)); put16(UInt16(bits))
        h += Array("data".utf8); put32(dataBytes)
        return h
    }
}
