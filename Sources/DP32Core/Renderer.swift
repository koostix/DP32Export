import Foundation

public struct Cancelled: Error {}

public enum Renderer {
    /// Frames handled per pass. A stem is never held in memory as a whole.
    static let chunkFrames = 1 << 16

    /// Writes one stem as a mono WAV. `totalFrames` is `stem.frames`, or more to pad with silence.
    public static func render(stem: StemPlan, song: SongPlan, to path: String, totalFrames: UInt64,
                              progress: (UInt64) -> Void = { _ in },
                              isCancelled: () -> Bool = { false }) throws {
        precondition(totalFrames >= stem.frames)
        let bytesPerFrame = song.bitsPerSample / 8
        let dataBytes = totalFrames * UInt64(bytesPerFrame)
        guard dataBytes <= UInt64(UInt32.max) - 36 else {
            throw Refusal("the stem would be larger than a WAV file can be (4 GB)")
        }
        let n = song.fadeLength
        let fadeFrames = UInt64(n)
        let fade = EdgeFade(length: n)
        let regions = stem.regions

        var open = [Int: ReadOnlyFile]()
        var raw = [UInt8](repeating: 0, count: chunkFrames * bytesPerFrame)

        /// Decodes `count` frames of a clip, starting at `first`, as 24-bit values.
        func load(_ clip: Int, _ first: UInt64, _ count: Int, _ out: UnsafeMutablePointer<Int32>) throws {
            let file: ReadOnlyFile
            if let f = open[clip] { file = f } else {
                file = try ReadOnlyFile(path: song.clips[clip].path)
                open[clip] = file
            }
            let info = song.clips[clip].info
            guard first + UInt64(count) <= info.frames else {
                throw Refusal("\(song.clips[clip].name) is shorter than the edit list says it should be")
            }
            try raw.withUnsafeMutableBytes { buffer in
                let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<(count * bytesPerFrame)])
                try file.read(at: info.dataOffset + first * UInt64(bytesPerFrame), into: slice)
                let p = slice.bindMemory(to: UInt8.self)
                if bytesPerFrame == 3 {
                    for k in 0..<count {
                        let v = Int32(p[3 * k]) | (Int32(p[3 * k + 1]) << 8) | (Int32(Int8(bitPattern: p[3 * k + 2])) << 16)
                        out[k] = v
                    }
                } else {
                    for k in 0..<count {
                        let v = Int32(p[2 * k]) | (Int32(Int8(bitPattern: p[2 * k + 1])) << 8)
                        out[k] = v << 8
                    }
                }
            }
        }

        // The audio stored after each clip's end: what fades out past the clip.
        var tails = [[Int32]?](repeating: nil, count: regions.count)
        for (j, r) in regions.enumerated() {
            guard let clip = r.clip else { continue }
            var tail = [Int32](repeating: 0, count: n)
            try tail.withUnsafeMutableBufferPointer { try load(clip, r.sourceStart + r.length, n, $0.baseAddress!) }
            tails[j] = tail
        }

        let output = try NewFile(path: path)
        try output.append(Wav.header(sampleRate: song.sampleRate, bits: song.bitsPerSample, channels: 1,
                                     dataBytes: UInt32(dataBytes)))

        var samples = [Int32](repeating: 0, count: chunkFrames)
        var encoded = [UInt8](repeating: 0, count: chunkFrames * bytesPerFrame)
        var position: UInt64 = 0
        while position < totalFrames {
            if isCancelled() { throw Cancelled() }
            let count = Int(min(UInt64(chunkFrames), totalFrames - position))
            let end = position + UInt64(count)

            try samples.withUnsafeMutableBufferPointer { buffer in
                let s = buffer.baseAddress!
                for k in 0..<count { s[k] = 0 }
                for (j, r) in regions.enumerated() {
                    guard let clip = r.clip else { continue }
                    let start = r.start
                    let stop = r.end
                    if start >= end { break }
                    if stop + fadeFrames <= position { continue }

                    // The clip itself.
                    let from = max(start, position)
                    let to = min(stop, end)
                    if from < to {
                        try load(clip, r.sourceStart + (from - start), Int(to - from), s + Int(from - position))
                    }
                    // Its first 10 ms: faded in, plus the fade-out of a clip that stopped exactly here.
                    let headEnd = min(start + fadeFrames, end)
                    if from < headEnd {
                        let before: [Int32]? = j > 0 ? tails[j - 1] : nil
                        var x = from
                        while x < headEnd {
                            let i = Int(x - start)
                            let k = Int(x - position)
                            s[k] = fade.mix(outgoing: before?[i] ?? 0, incoming: s[k], at: i)
                            x += 1
                        }
                    }
                    // The 10 ms after its end, when silence follows.
                    if j + 1 < regions.count, regions[j + 1].clip == nil, let tail = tails[j] {
                        var x = max(stop, position)
                        let tailEnd = min(stop + fadeFrames, end)
                        while x < tailEnd {
                            s[Int(x - position)] = fade.mix(outgoing: tail[Int(x - stop)], incoming: 0, at: Int(x - stop))
                            x += 1
                        }
                    }
                }

                encoded.withUnsafeMutableBufferPointer { bytes in
                    let e = bytes.baseAddress!
                    if bytesPerFrame == 3 {
                        for k in 0..<count {
                            let v = UInt32(bitPattern: s[k])
                            e[3 * k] = UInt8(v & 0xFF)
                            e[3 * k + 1] = UInt8((v >> 8) & 0xFF)
                            e[3 * k + 2] = UInt8((v >> 16) & 0xFF)
                        }
                    } else {
                        for k in 0..<count {
                            let v = UInt32(bitPattern: s[k] >> 8)
                            e[2 * k] = UInt8(v & 0xFF)
                            e[2 * k + 1] = UInt8((v >> 8) & 0xFF)
                        }
                    }
                }
            }
            try encoded.withUnsafeBytes { bytes in
                try output.append(UnsafeRawBufferPointer(rebasing: bytes[0..<(count * bytesPerFrame)]))
            }
            position = end
            progress(UInt64(count))
        }
        try output.finish()
    }
}
