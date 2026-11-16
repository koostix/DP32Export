import Foundation

/// One entry of a track's timeline. `fileID == nil` is silence.
public struct EDLRegion: Equatable {
    public var fileID: UInt32?
    public var start: UInt64
    public var length: UInt64
    public var sourceStart: UInt64
    /// The fade length when the region starts where its recording starts, else 0.
    public var fadeInFlag: UInt32
    /// The fade length when the region ends where its recording ends, else 0.
    public var fadeOutFlag: UInt32
}

/// The state of one virtual track that the unit currently shows.
public struct EDLTrack: Equatable {
    public var key: Int
    public var track: Int { key / 8 + 1 }       // 1...32
    public var virtual: Int { key % 8 }         // 0...7
    public var regions: [EDLRegion]
    /// Edits that were undone and could still be redone on the unit.
    public var undoneEdits: Int
    /// The key whose playlist this track shares, when it is a clone.
    public var cloneOfKey: Int?
    public var hasAudio: Bool { regions.contains { $0.fileID != nil } }
}

/// A decoded edltable.sys. Decoding either succeeds completely or throws a Refusal.
public struct EditList: Equatable {
    public var sampleRate: Int
    public var bitsPerSample: Int
    public var fadeLength: Int
    /// File id -> clip file name, for the files the current state may use.
    public var files: [UInt32: String]
    /// All 256 keys, in key order.
    public var tracks: [EDLTrack]

    public static let fileSize = 11_563_954
    static let pool = 0x5238
    static let nodeSize = 192
    static let nodeCount = 60_000
    static let fileList = 0xB02586
    static let fileSlots = 998
    static let listEnd: UInt32 = 0xFFFF_FFFE
    static let listBegin: UInt32 = 0xFFFF_FFFF
    static let silence: UInt32 = 0xFFFF_FFFF

    public static func parse(_ b: [UInt8]) throws -> EditList {
        guard b.count == fileSize else {
            throw Refusal("edltable.sys is \(b.count) bytes; a DP-32SD edit list is always \(fileSize)")
        }
        guard Array(b[0..<5]) == Array("TEAC".utf8) + [0],
              Array(b[8..<14]) == Array("DP-32".utf8) + [0],
              Array(b[0x18..<0x22]) == Array("DP-32_EDL".utf8) + [0] else {
            throw Refusal("edltable.sys does not carry the DP-32 signature")
        }
        guard le32(b, 0x38) == 1, le32(b, 0x3C) == 0x51F8, le32(b, 0x58) == UInt32(nodeSize),
              le32(b, 0x5C) == UInt32(nodeCount), le32(b, 0x60) == UInt32(nodeSize * nodeCount) else {
            throw Refusal("the edit list header is laid out differently from every DP-32SD song seen so far")
        }
        let rate = Int(le32(b, 0x40))
        let bits = Int(le16(b, 0x44))
        let fade = Int(le32(b, 0x4C))
        guard rate == 44_100 || rate == 48_000, bits == 16 || bits == 24 else {
            throw Refusal("the song format (\(rate) Hz, \(bits)-bit) is not one the DP-32SD records")
        }
        guard fade * 100 == rate else {
            throw Refusal("the edit list gives an edge fade of \(fade) samples, which does not fit \(rate) Hz")
        }
        guard Array(b[fileList..<fileList + 10]) == Array("File List".utf8) + [0],
              le32(b, fileList + 0x10) <= UInt32(fileSlots) else {
            throw Refusal("the clip file list in the edit list could not be found")
        }

        var files = [UInt32: String]()
        for slot in 0..<fileSlots {
            let o = fileList + 0x20 + 20 * slot
            let id = UInt32(le16(b, o))
            var nameBytes = [UInt8]()
            for k in 0..<16 {
                let c = b[o + 4 + k]
                if c == 0 { break }
                nameBytes.append(c)
            }
            if nameBytes.isEmpty || id >= 0xFFF0 { continue }
            guard let name = String(bytes: nameBytes, encoding: .ascii), isPlainClipName(name) else {
                throw Refusal("the edit list holds a clip file name that is not a plain ZZ file name")
            }
            guard files[id] == nil else { throw Refusal("the edit list lists clip file id \(id) twice") }
            files[id] = name
        }

        func node(_ id: UInt32, _ what: String) throws -> Int {
            guard id < UInt32(nodeCount) else { throw Refusal("\(what) points outside the edit list") }
            return pool + nodeSize * Int(id)
        }

        var tracks = [EDLTrack]()
        tracks.reserveCapacity(256)
        for key in 0..<256 {
            let label = "track \(key / 8 + 1)" + (key % 8 == 0 ? "" : " (virtual track \(key % 8 + 1))")
            let broken = Refusal("the edit history of \(label) could not be followed")
            let head = try node(UInt32(key), label)
            guard le32(b, head + 8) == 4 else { throw broken }
            let current = le32(b, head + 0x28)
            let index = le32(b, head + 0x2C)
            let first = le32(b, head + 0x30)
            let last = le32(b, head + 0x34)
            let count = le32(b, head + 0x38)
            guard count >= 1, count <= UInt32(nodeCount), index < count else { throw broken }

            // Versions of this key, oldest first. The head says which one is current.
            var id = first
            var previous = listBegin
            var walked: UInt32 = 0
            var lastSeen = listBegin
            var foundCurrent = false
            while id != listEnd {
                guard walked < count else { throw broken }
                let o = try node(id, label)
                guard le32(b, o + 8) == 1, le32(b, o + 0xC) == UInt32(key), le32(b, o + 4) == previous else { throw broken }
                if walked == index { foundCurrent = (id == current) }
                lastSeen = id
                previous = id
                id = le32(b, o)
                walked += 1
            }
            guard walked == count, lastSeen == last, foundCurrent else { throw broken }

            let t = try node(current, label)
            let playlistID = le32(b, t + 0x30)
            guard le32(b, t + 0x38) == 1, le32(b, t + 0x34) == playlistID else {
                throw Refusal("\(label) does not have exactly one playlist")
            }
            let p = try node(playlistID, label)
            let playlistKey = le32(b, p + 0xC)
            guard le32(b, p + 8) == 2, playlistKey < 256 else {
                throw Refusal("the playlist of \(label) is not a playlist")
            }
            let firstRegion = le32(b, p + 0x30)
            let lastRegion = le32(b, p + 0x34)
            let regionCount = le32(b, p + 0x38)
            let timeline = le64(b, p + 0x58)

            let untiled = Refusal("the clips of \(label) do not cover its timeline exactly")
            var regions = [EDLRegion]()
            var position: UInt64 = 0
            id = firstRegion
            previous = listBegin
            lastSeen = listBegin
            while id != listEnd {
                guard UInt32(regions.count) < regionCount else { throw untiled }
                let o = try node(id, label)
                guard le32(b, o + 8) == 3, le32(b, o + 0xC) == playlistKey, le32(b, o + 4) == previous else { throw untiled }
                let fileID = le32(b, o + 0x50)
                let start = le64(b, o + 0x58)
                let length = le64(b, o + 0x60)
                let source = le64(b, o + 0x68)
                let sourceEnd = le64(b, o + 0x70)
                guard start == position, length > 0, length <= timeline - position else { throw untiled }
                let (sum, overflow) = source.addingReportingOverflow(length - 1)
                guard !overflow, sourceEnd == sum else {
                    throw Refusal("a clip of \(label) has a source range that does not add up")
                }
                if fileID == silence {
                    regions.append(EDLRegion(fileID: nil, start: start, length: length, sourceStart: 0, fadeInFlag: 0, fadeOutFlag: 0))
                } else {
                    guard files[fileID] != nil else {
                        throw Refusal("\(label) uses clip file id \(fileID), which the song's file list does not hold")
                    }
                    let fadeIn = le32(b, o + 0x78)
                    let fadeOut = le32(b, o + 0x7C)
                    guard fadeIn == 0 || fadeIn == UInt32(fade), fadeOut == 0 || fadeOut == UInt32(fade) else {
                        throw Refusal("a clip of \(label) has an edge fade length that was never seen before")
                    }
                    regions.append(EDLRegion(fileID: fileID, start: start, length: length, sourceStart: source,
                                             fadeInFlag: fadeIn, fadeOutFlag: fadeOut))
                }
                position += length
                lastSeen = id
                previous = id
                id = le32(b, o)
            }
            guard UInt32(regions.count) == regionCount, lastSeen == lastRegion, position == timeline else { throw untiled }

            tracks.append(EDLTrack(key: key, regions: regions, undoneEdits: Int(count - 1 - index),
                                   cloneOfKey: playlistKey == UInt32(key) ? nil : Int(playlistKey)))
        }
        return EditList(sampleRate: rate, bitsPerSample: bits, fadeLength: fade, files: files, tracks: tracks)
    }

    /// Clip names come from the card. Only names that cannot leave the song folder are accepted.
    static func isPlainClipName(_ name: String) -> Bool {
        guard name.count >= 5, name.count <= 16, name != ".", name != ".." else { return false }
        for scalar in name.unicodeScalars {
            let ok = (scalar.value >= 0x30 && scalar.value <= 0x39)        // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)          // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)          // a-z
                || scalar == "_" || scalar == "."
            if !ok { return false }
        }
        return name.lowercased().hasPrefix("zz") && name.lowercased().hasSuffix(".wav")
    }
}
