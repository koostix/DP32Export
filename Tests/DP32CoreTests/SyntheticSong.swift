import Foundation
@testable import DP32Core

/// Builds an edltable.sys from a description, laid out like the ones the unit writes.
struct SyntheticEDL {
    struct Region {
        var file: UInt32?          // nil = silence
        var length: UInt64
        var source: UInt64 = 0
        var fadeIn: UInt32? = nil  // nil = what the unit would store
        var fadeOut: UInt32? = nil
    }

    static let timeline: UInt64 = 0xF800_0000

    var sampleRate: UInt32 = 48_000
    var bits: UInt16 = 24
    /// (file id, name). Use id 0xFFFB for a file the song no longer uses.
    var files: [(UInt16, String)] = []
    /// key -> versions, oldest first. Each version lists its regions; trailing silence is added.
    var versions: [Int: [[Region]]] = [:]
    /// key -> index of the current version (default: the last one).
    var currentVersion: [Int: Int] = [:]
    /// key -> key whose regions it shares (a clone).
    var cloneOf: [Int: Int] = [:]

    /// Node ids of the regions of each key's current version, filled by build().
    private(set) var regionNodes: [Int: [Int]] = [:]
    private(set) var playlistNode: [Int: Int] = [:]
    private(set) var trackNode: [Int: Int] = [:]

    static func nodeOffset(_ id: Int) -> Int { 0x5238 + 192 * id }

    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for k in 0..<4 { b[o + k] = UInt8((v >> UInt32(8 * k)) & 0xFF) }
    }

    static func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
        put32(&b, o, UInt32(v & 0xFFFF_FFFF))
        put32(&b, o + 4, UInt32(v >> 32))
    }

    mutating func build() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: EditList.fileSize)
        let put32 = SyntheticEDL.put32
        let put64 = SyntheticEDL.put64
        func text(_ o: Int, _ s: String) { for (k, c) in Array(s.utf8).enumerated() { b[o + k] = c } }
        text(0x00, "TEAC"); text(0x08, "DP-32"); text(0x18, "DP-32_EDL")
        put32(&b, 0x38, 1); put32(&b, 0x3C, 0x51F8)
        put32(&b, 0x40, sampleRate)
        b[0x44] = UInt8(bits & 0xFF); b[0x45] = UInt8(bits >> 8)
        put32(&b, 0x4C, sampleRate / 100)
        put32(&b, 0x58, 192); put32(&b, 0x5C, 60_000); put32(&b, 0x60, 11_520_000)

        let fade = sampleRate / 100
        var next = 600
        func allocate() -> Int { next += 1; return next - 1 }
        let end: UInt32 = 0xFFFF_FFFE
        let begin: UInt32 = 0xFFFF_FFFF

        for key in 0...256 {
            let all = versions[key] ?? [[]]
            var trackIDs = [Int]()
            for (v, described) in all.enumerated() {
                var regions = described
                let used = regions.reduce(UInt64(0)) { $0 + $1.length }
                regions.append(Region(file: nil, length: SyntheticEDL.timeline - used))
                let track = allocate()
                let playlist = allocate()
                let ids = regions.map { _ in allocate() }
                let regionKey = UInt32(cloneOf[key] ?? key)
                var position: UInt64 = 0
                for (j, r) in regions.enumerated() {
                    let o = SyntheticEDL.nodeOffset(ids[j])
                    put32(&b, o, j + 1 < ids.count ? UInt32(ids[j + 1]) : end)
                    put32(&b, o + 4, j > 0 ? UInt32(ids[j - 1]) : begin)
                    put32(&b, o + 8, 3)
                    put32(&b, o + 0xC, regionKey)
                    put32(&b, o + 0x50, r.file ?? 0xFFFF_FFFF)
                    put64(&b, o + 0x58, position)
                    put64(&b, o + 0x60, r.length)
                    let source = r.file == nil ? position : r.source
                    put64(&b, o + 0x68, source)
                    put64(&b, o + 0x70, source + r.length - 1)
                    if r.file != nil {
                        put32(&b, o + 0x78, r.fadeIn ?? (r.source == 0 ? fade : 0))
                        put32(&b, o + 0x7C, r.fadeOut ?? fade)
                    }
                    position += r.length
                }
                let p = SyntheticEDL.nodeOffset(playlist)
                put32(&b, p, end); put32(&b, p + 4, begin)
                put32(&b, p + 8, 2); put32(&b, p + 0xC, regionKey)
                put32(&b, p + 0x30, UInt32(ids[0])); put32(&b, p + 0x34, UInt32(ids[ids.count - 1]))
                put32(&b, p + 0x38, UInt32(ids.count))
                put64(&b, p + 0x58, SyntheticEDL.timeline)
                let t = SyntheticEDL.nodeOffset(track)
                put32(&b, t + 8, 1); put32(&b, t + 0xC, UInt32(key))
                put32(&b, t + 0x30, UInt32(playlist)); put32(&b, t + 0x34, UInt32(playlist)); put32(&b, t + 0x38, 1)
                trackIDs.append(track)
                if v == (currentVersion[key] ?? all.count - 1) {
                    regionNodes[key] = ids
                    playlistNode[key] = playlist
                    trackNode[key] = track
                }
            }
            for (v, id) in trackIDs.enumerated() {
                let t = SyntheticEDL.nodeOffset(id)
                put32(&b, t, v + 1 < trackIDs.count ? UInt32(trackIDs[v + 1]) : end)
                put32(&b, t + 4, v > 0 ? UInt32(trackIDs[v - 1]) : begin)
            }
            let current = currentVersion[key] ?? trackIDs.count - 1
            let h = SyntheticEDL.nodeOffset(key)
            put32(&b, h + 8, 4)
            put32(&b, h + 0x28, UInt32(trackIDs[current])); put32(&b, h + 0x2C, UInt32(current))
            put32(&b, h + 0x30, UInt32(trackIDs[0])); put32(&b, h + 0x34, UInt32(trackIDs[trackIDs.count - 1]))
            put32(&b, h + 0x38, UInt32(trackIDs.count))
        }

        let list = 0xB02586
        text(list, "File List")
        put32(&b, list + 0x10, UInt32(files.count))
        for slot in 0..<998 {
            let o = list + 0x20 + 20 * slot
            if slot < files.count {
                let (id, name) = files[slot]
                b[o] = UInt8(id & 0xFF); b[o + 1] = UInt8(id >> 8)
                b[o + 2] = b[o]; b[o + 3] = b[o + 1]
                text(o + 4, name)
            } else {
                b[o] = 0xFE; b[o + 1] = 0xFF; b[o + 2] = 0xFE; b[o + 3] = 0xFF
            }
        }
        return b
    }
}

/// Deterministic 24-bit test audio.
func testSamples(count: Int, seed: UInt32) -> [Int32] {
    var state = seed &* 2_654_435_761 &+ 12_345
    var out = [Int32]()
    out.reserveCapacity(count)
    for _ in 0..<count {
        state = state &* 1_664_525 &+ 1_013_904_223
        out.append(Int32(bitPattern: state) >> 10)      // about ±2 million, fits 24 bits
    }
    return out
}

func wavBytes(_ samples: [Int32], sampleRate: Int = 48_000, bits: Int = 24, channels: Int = 1) -> [UInt8] {
    var data = [UInt8]()
    for s in samples {
        let v = UInt32(bitPattern: bits == 24 ? s : s >> 8)
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
        if bits == 24 { data.append(UInt8((v >> 16) & 0xFF)) }
    }
    return Wav.header(sampleRate: sampleRate, bits: bits, channels: channels, dataBytes: UInt32(data.count)) + data
}

func readStem(_ path: String) throws -> [Int32] {
    let file = try ReadOnlyFile(path: path)
    let info = try Wav.info(of: file)
    let raw = try file.bytes(at: info.dataOffset, count: Int(info.dataBytes))
    let width = info.blockAlign
    var out = [Int32]()
    out.reserveCapacity(raw.count / width)
    var k = 0
    while k + width <= raw.count {
        if width == 3 {
            out.append(Int32(raw[k]) | (Int32(raw[k + 1]) << 8) | (Int32(Int8(bitPattern: raw[k + 2])) << 16))
        } else {
            out.append((Int32(raw[k]) | (Int32(Int8(bitPattern: raw[k + 1])) << 8)) << 8)
        }
        k += width
    }
    return out
}

/// A scratch folder that is removed when the test ends.
final class Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("dp32export-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func folder(_ name: String) throws -> URL {
        let f = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    func write(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url)
    }
}
