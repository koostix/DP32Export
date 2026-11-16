import XCTest
@testable import DP32Core

final class ExportTests: XCTestCase {
    /// Clip A: 5,000 samples used + 480 tail. Clip B: 3,000 used + 480 tail.
    let clipA = testSamples(count: 5_480, seed: 1)
    let clipB = testSamples(count: 3_480, seed: 2)

    /// Track 1: clip A from 0.
    /// Track 2: 1,000 of silence, clip B, then A[3000..<4500] starting exactly where B ends (a punch-out).
    /// Track 3: clip B, a 2,000-sample gap, clip A.
    private func makeSong(_ scratch: Scratch, name: String = "SONG", bits: Int = 24,
                          configure: (inout SyntheticEDL) -> Void = { _ in }) throws -> URL {
        let folder = try scratch.folder(name)
        var edl = SyntheticEDL()
        if bits == 16 { edl.bits = 16; edl.sampleRate = 44_100 }
        edl.files = [(0, "ZZ0000_1.wav"), (1, "ZZ0001_1.wav")]
        edl.versions[0] = [[.init(file: 0, length: 5_000)]]
        edl.versions[8] = [[.init(file: nil, length: 1_000), .init(file: 1, length: 3_000),
                            .init(file: 0, length: 1_500, source: 3_000, fadeOut: 0)]]
        edl.versions[16] = [[.init(file: 1, length: 3_000), .init(file: nil, length: 2_000), .init(file: 0, length: 5_000)]]
        configure(&edl)
        try scratch.write(edl.build(), to: folder.appendingPathComponent("edltable.sys"))
        try scratch.write([UInt8](repeating: 0, count: 2_996), to: folder.appendingPathComponent("song.sys"))
        let rate = bits == 16 ? 44_100 : 48_000
        try scratch.write(wavBytes(clipA, sampleRate: rate, bits: bits), to: folder.appendingPathComponent("ZZ0000_1.wav"))
        try scratch.write(wavBytes(clipB, sampleRate: rate, bits: bits), to: folder.appendingPathComponent("ZZ0001_1.wav"))
        return folder
    }

    private func plan(_ folder: URL) throws -> SongPlan {
        switch Song.inspect(folder) {
        case .ready(let plan): return plan
        case .refused(let reason): throw Refusal(reason)
        }
    }

    private func refusal(_ folder: URL) -> String {
        if case .refused(let reason) = Song.inspect(folder) { return reason }
        XCTFail("expected the song to be refused")
        return ""
    }

    func testEndToEndRender() throws {
        let scratch = try Scratch()
        let song = try plan(try makeSong(scratch))
        XCTAssertEqual(song.stems.map { $0.suffix }, ["_TRK01", "_TRK02", "_TRK03"])
        XCTAssertEqual(song.stems.map { $0.frames }, [5_480, 5_980, 10_480])
        XCTAssertEqual(song.frames, 10_480)

        let out = scratch.url.appendingPathComponent("exports")
        let result = try Exporter.export(song, to: out)
        XCTAssertEqual(result.folder.lastPathComponent, "SONG")
        XCTAssertEqual(result.stemFiles, ["SONG_TRK01.WAV", "SONG_TRK02.WAV", "SONG_TRK03.WAV"])
        let fade = EdgeFade(length: 480)

        // Track 1: fade-in, untouched body, fade-out past the end.
        let one = try readStem(result.folder.appendingPathComponent("SONG_TRK01.WAV").path)
        XCTAssertEqual(one.count, 5_480)
        for i in 0..<480 { XCTAssertEqual(one[i], fade.mix(outgoing: 0, incoming: clipA[i], at: i)) }
        XCTAssertEqual(Array(one[480..<5_000]), Array(clipA[480..<5_000]))
        for i in 0..<480 { XCTAssertEqual(one[5_000 + i], fade.mix(outgoing: clipA[5_000 + i], incoming: 0, at: i)) }

        // The header is the 44 bytes the unit writes.
        let header = try ReadOnlyFile(path: result.folder.appendingPathComponent("SONG_TRK01.WAV").path).bytes(at: 0, count: 44)
        XCTAssertEqual(header, Wav.header(sampleRate: 48_000, bits: 24, channels: 1, dataBytes: 5_480 * 3))

        // Track 2: leading silence, then the punch-out crossfade where B stops and A resumes.
        let two = try readStem(result.folder.appendingPathComponent("SONG_TRK02.WAV").path)
        XCTAssertEqual(two.count, 5_980)
        XCTAssertEqual(Array(two[0..<1_000]), [Int32](repeating: 0, count: 1_000))
        for i in 0..<480 { XCTAssertEqual(two[1_000 + i], fade.mix(outgoing: 0, incoming: clipB[i], at: i)) }
        XCTAssertEqual(Array(two[1_480..<4_000]), Array(clipB[480..<3_000]))
        for i in 0..<480 { XCTAssertEqual(two[4_000 + i], fade.mix(outgoing: clipB[3_000 + i], incoming: clipA[3_000 + i], at: i)) }
        XCTAssertEqual(Array(two[4_480..<5_500]), Array(clipA[3_480..<4_500]))
        for i in 0..<480 { XCTAssertEqual(two[5_500 + i], fade.mix(outgoing: clipA[4_500 + i], incoming: 0, at: i)) }

        // Track 3: a gap. B fades out into it, the rest of the gap is silent, A fades in.
        let three = try readStem(result.folder.appendingPathComponent("SONG_TRK03.WAV").path)
        XCTAssertEqual(three.count, 10_480)
        for i in 0..<480 { XCTAssertEqual(three[3_000 + i], fade.mix(outgoing: clipB[3_000 + i], incoming: 0, at: i)) }
        XCTAssertEqual(Array(three[3_480..<5_000]), [Int32](repeating: 0, count: 1_520))
        for i in 0..<480 { XCTAssertEqual(three[5_000 + i], fade.mix(outgoing: 0, incoming: clipA[i], at: i)) }
        XCTAssertEqual(Array(three[5_480..<10_000]), Array(clipA[480..<5_000]))

        // The report is there and names every stem and the gap.
        let report = try String(contentsOf: result.folder.appendingPathComponent(Exporter.reportName), encoding: .utf8)
        XCTAssertTrue(report.contains("SONG_TRK03.WAV"))
        XCTAssertTrue(report.contains("gap"))
        XCTAssertTrue(song.notes.contains { $0.contains("gap") })
    }

    func testChunkBoundariesDoNotChangeTheResult() throws {
        // A stem longer than one render pass, with a clip that starts just before a pass boundary.
        let scratch = try Scratch()
        let long = testSamples(count: 70_000 + 480, seed: 3)
        let folder = try makeSong(scratch) { edl in
            edl.files.append((2, "ZZ0002_1.wav"))
            edl.versions[24] = [[.init(file: nil, length: 65_300), .init(file: 2, length: 70_000)]]
        }
        try scratch.write(wavBytes(long), to: folder.appendingPathComponent("ZZ0002_1.wav"))
        let song = try plan(folder)
        let result = try Exporter.export(song, to: scratch.url.appendingPathComponent("exports"))
        let four = try readStem(result.folder.appendingPathComponent("SONG_TRK04.WAV").path)
        let fade = EdgeFade(length: 480)
        XCTAssertEqual(four.count, 65_300 + 70_000 + 480)
        XCTAssertEqual(Array(four[0..<65_300]), [Int32](repeating: 0, count: 65_300))
        for i in 0..<480 { XCTAssertEqual(four[65_300 + i], fade.mix(outgoing: 0, incoming: long[i], at: i)) }
        XCTAssertEqual(Array(four[65_780..<135_300]), Array(long[480..<70_000]))
        for i in 0..<480 { XCTAssertEqual(four[135_300 + i], fade.mix(outgoing: long[70_000 + i], incoming: 0, at: i)) }
    }

    func testPadMakesEveryStemTheSongLength() throws {
        let scratch = try Scratch()
        let song = try plan(try makeSong(scratch))
        let result = try Exporter.export(song, to: scratch.url.appendingPathComponent("exports"),
                                         options: ExportOptions(padToSongLength: true))
        let one = try readStem(result.folder.appendingPathComponent("SONG_TRK01.WAV").path)
        XCTAssertEqual(one.count, 10_480)
        XCTAssertEqual(Array(one[5_480..<10_480]), [Int32](repeating: 0, count: 5_000))
        XCTAssertEqual(Array(one[480..<5_000]), Array(clipA[480..<5_000]))
    }

    func testVirtualTracksGetSuffixOnlyWhenThereIsMoreThanOne() throws {
        let scratch = try Scratch()
        let folder = try makeSong(scratch) { edl in
            edl.versions[1] = [[.init(file: 1, length: 3_000)]]     // track 1, virtual track 2
            edl.versions[18] = [[.init(file: 1, length: 3_000)]]    // track 3, virtual track 3 as well as 1
        }
        let song = try plan(folder)
        XCTAssertEqual(song.stems.map { $0.suffix }, ["_TRK01_V1", "_TRK01_V2", "_TRK02", "_TRK03_V1", "_TRK03_V3"])
        XCTAssertTrue(song.notes.contains { $0.contains("virtual") })
    }

    func testNeverWritesIntoAnExistingFolder() throws {
        let scratch = try Scratch()
        let song = try plan(try makeSong(scratch))
        let out = scratch.url.appendingPathComponent("exports")
        XCTAssertEqual(try Exporter.export(song, to: out).folder.lastPathComponent, "SONG")
        XCTAssertEqual(try Exporter.export(song, to: out).folder.lastPathComponent, "SONG 2")
        XCTAssertEqual(try Exporter.export(song, to: out).folder.lastPathComponent, "SONG 3")
    }

    func testMastersAreFoundEvenWhenTheFolderWasRenamed() throws {
        let scratch = try Scratch()
        let folder = try makeSong(scratch, name: "Renamed On The Mac")
        let stereo = wavBytes(testSamples(count: 2_000, seed: 9), channels: 2)
        try scratch.write(stereo, to: folder.appendingPathComponent("20251102_0002.WAV"))
        try scratch.write(stereo, to: folder.appendingPathComponent("20251102_0002_z.WAV"))
        let song = try plan(folder)
        XCTAssertEqual(song.masters.map { $0.exportName }, ["Renamed On The Mac.WAV", "Renamed On The Mac_z.WAV"])
        let result = try Exporter.export(song, to: scratch.url.appendingPathComponent("exports"))
        XCTAssertEqual(result.masterFiles.count, 2)
        let copied = try Data(contentsOf: result.folder.appendingPathComponent("Renamed On The Mac.WAV"))
        XCTAssertEqual([UInt8](copied), stereo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent("Renamed On The Mac_TRK01.WAV").path))
    }

    func testRefusesDestinationsInsideTheSongAroundItOrOnACard() throws {
        let scratch = try Scratch()
        let folder = try makeSong(scratch)
        let song = try plan(folder)
        XCTAssertThrowsError(try Exporter.export(song, to: folder.appendingPathComponent("out")))
        XCTAssertThrowsError(try Exporter.export(song, to: folder))
        XCTAssertThrowsError(try Exporter.export(song, to: scratch.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("out").path))

        let card = try scratch.folder("CARD")
        try scratch.write([0], to: card.appendingPathComponent("dp-24.sys"))
        _ = try scratch.folder("CARD/MUSIC")
        XCTAssertTrue(Card.isCardRoot(card))
        XCTAssertThrowsError(try Exporter.export(song, to: card.appendingPathComponent("AudioDepot/exports")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: card.appendingPathComponent("AudioDepot").path))
    }

    func testRefusesMissingShortOrWrongClipFiles() throws {
        let scratch = try Scratch()
        var folder = try makeSong(scratch, name: "MISSING")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("ZZ0001_1.wav"))
        XCTAssertTrue(refusal(folder).contains("ZZ0001_1.wav"))

        folder = try makeSong(scratch, name: "SHORT")
        try scratch.write(wavBytes(Array(clipA[0..<5_479])), to: folder.appendingPathComponent("ZZ0000_1.wav"))
        XCTAssertTrue(refusal(folder).contains("shorter"))

        folder = try makeSong(scratch, name: "STEREO")
        try scratch.write(wavBytes(clipA, channels: 2), to: folder.appendingPathComponent("ZZ0000_1.wav"))
        XCTAssertTrue(refusal(folder).contains("mono"))

        folder = try makeSong(scratch, name: "LINK")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("ZZ0000_1.wav"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("ZZ0000_1.wav"),
                                                   withDestinationURL: scratch.url.appendingPathComponent("SHORT/ZZ0001_1.wav"))
        XCTAssertTrue(refusal(folder).contains("ZZ0000_1.wav"))

        folder = try scratch.folder("EMPTY")
        XCTAssertTrue(refusal(folder).contains("edltable.sys"))
    }

    func testRefusesEdgeCasesTheHardwareWasNeverSeenDoing() throws {
        let scratch = try Scratch()
        var folder = try makeSong(scratch, name: "TINYGAP") { edl in
            edl.versions[24] = [[.init(file: 1, length: 3_000), .init(file: nil, length: 479), .init(file: 0, length: 5_000)]]
        }
        XCTAssertTrue(refusal(folder).contains("gap"))
        folder = try makeSong(scratch, name: "TINYCLIP") { edl in
            edl.versions[24] = [[.init(file: 1, length: 479)]]
        }
        XCTAssertTrue(refusal(folder).contains("shorter"))
        folder = try makeSong(scratch, name: "NOAUDIO") { edl in
            edl.versions[0] = [[]]; edl.versions[8] = [[]]; edl.versions[16] = [[]]
        }
        XCTAssertTrue(refusal(folder).contains("nothing"))
    }

    func testSixteenBitSongRendersAndIsFlaggedUnverified() throws {
        let scratch = try Scratch()
        let song = try plan(try makeSong(scratch, bits: 16))
        XCTAssertEqual(song.fadeLength, 441)
        XCTAssertTrue(song.notes.contains { $0.contains("16-bit") })
        let result = try Exporter.export(song, to: scratch.url.appendingPathComponent("exports"))
        let one = try readStem(result.folder.appendingPathComponent("SONG_TRK01.WAV").path)
        let fade = EdgeFade(length: 441)
        let a16 = clipA.map { ($0 >> 8) << 8 }     // what a 16-bit file holds, as 24-bit values
        XCTAssertEqual(one.count, 5_441)
        for i in 0..<441 { XCTAssertEqual(one[i], (fade.mix(outgoing: 0, incoming: a16[i], at: i) >> 8) << 8) }
        XCTAssertEqual(Array(one[441..<5_000]), Array(a16[441..<5_000]))
    }

    func testCancelRemovesTheNewFolder() throws {
        let scratch = try Scratch()
        let song = try plan(try makeSong(scratch))
        let out = scratch.url.appendingPathComponent("exports")
        XCTAssertThrowsError(try Exporter.export(song, to: out, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("SONG").path))
    }

    func testSongFoldersAreFoundOnCardsAndInPlainFolders() throws {
        let scratch = try Scratch()
        let card = try scratch.folder("CARD")
        try scratch.write([0], to: card.appendingPathComponent("dp-24.sys"))
        let music = try scratch.folder("CARD/MUSIC")
        _ = try scratch.folder("CARD/AudioDepot")
        for name in ["B_SONG", "A_SONG"] {
            let song = try scratch.folder("CARD/MUSIC/" + name)
            try scratch.write([0], to: song.appendingPathComponent("edltable.sys"))
        }
        _ = try scratch.folder("CARD/MUSIC/not a song")
        XCTAssertEqual(Card.songFolders(in: card).map { $0.lastPathComponent }, ["A_SONG", "B_SONG"])
        XCTAssertEqual(Card.songFolders(in: music).map { $0.lastPathComponent }, ["A_SONG", "B_SONG"])
        XCTAssertEqual(Card.songFolders(in: music.appendingPathComponent("A_SONG")).count, 1)
        XCTAssertNotNil(Card.cardRoot(containing: music.appendingPathComponent("A_SONG/later/not/there")))
        XCTAssertNil(Card.cardRoot(containing: scratch.url))
    }
}
