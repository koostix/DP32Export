import XCTest
@testable import DP32Core

final class EditListTests: XCTestCase {
    private func simple() -> SyntheticEDL {
        var edl = SyntheticEDL()
        edl.files = [(0, "ZZ0000_1.wav"), (1, "ZZ0001_1.wav"), (0xFFFB, "ZZ0002_1.wav")]
        edl.versions[0] = [[.init(file: 0, length: 5_000)]]
        // Track 2: silence, a clip, then a second clip that starts exactly where the first ends.
        edl.versions[8] = [[.init(file: nil, length: 1_000), .init(file: 1, length: 3_000),
                            .init(file: 0, length: 1_500, source: 3_000)]]
        return edl
    }

    private func refusal(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try EditList.parse(bytes)
            XCTFail("expected a refusal", file: file, line: line)
            return ""
        } catch let r as Refusal {
            return r.reason
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
            return ""
        }
    }

    func testParsesTracksRegionsAndFiles() throws {
        var synth = simple()
        let edl = try EditList.parse(synth.build())
        XCTAssertEqual(edl.sampleRate, 48_000)
        XCTAssertEqual(edl.bitsPerSample, 24)
        XCTAssertEqual(edl.fadeLength, 480)
        XCTAssertEqual(edl.files, [0: "ZZ0000_1.wav", 1: "ZZ0001_1.wav"])
        XCTAssertEqual(edl.tracks.count, 256)
        XCTAssertEqual(edl.tracks.filter { $0.hasAudio }.map { $0.key }, [0, 8])

        let one = edl.tracks[0]
        XCTAssertEqual(one.track, 1)
        XCTAssertEqual(one.virtual, 0)
        XCTAssertEqual(one.regions.count, 2)
        XCTAssertEqual(one.regions[0], EDLRegion(fileID: 0, start: 0, length: 5_000, sourceStart: 0, fadeInFlag: 480, fadeOutFlag: 480))
        XCTAssertNil(one.regions[1].fileID)
        XCTAssertEqual(one.regions[1].start + one.regions[1].length, SyntheticEDL.timeline)

        let two = edl.tracks[8]
        XCTAssertEqual(two.track, 2)
        XCTAssertEqual(two.regions.map { $0.start }, [0, 1_000, 4_000, 5_500])
        XCTAssertEqual(two.regions[2].sourceStart, 3_000)
        XCTAssertEqual(two.regions[2].fadeInFlag, 0)
    }

    func testVirtualTrackKeys() throws {
        var synth = simple()
        synth.versions[9] = [[.init(file: 1, length: 2_000)]]       // track 2, virtual track 2
        synth.versions[255] = [[.init(file: 0, length: 2_000)]]     // track 32, virtual track 8
        let edl = try EditList.parse(synth.build())
        XCTAssertEqual(edl.tracks[9].track, 2)
        XCTAssertEqual(edl.tracks[9].virtual, 1)
        XCTAssertEqual(edl.tracks[255].track, 32)
        XCTAssertEqual(edl.tracks[255].virtual, 7)
    }

    func test16BitHeader() throws {
        var synth = simple()
        synth.sampleRate = 44_100
        synth.bits = 16
        let edl = try EditList.parse(synth.build())
        XCTAssertEqual(edl.sampleRate, 44_100)
        XCTAssertEqual(edl.bitsPerSample, 16)
        XCTAssertEqual(edl.fadeLength, 441)
    }

    func testCurrentVersionComesFromTheHeadNotTheEndOfTheChain() throws {
        var synth = simple()
        // Three versions of track 3; the unit's undo left the middle one current.
        synth.versions[16] = [[], [.init(file: 0, length: 4_000)], [.init(file: 1, length: 2_000)]]
        synth.currentVersion[16] = 1
        let edl = try EditList.parse(synth.build())
        XCTAssertEqual(edl.tracks[16].regions[0].fileID, 0)
        XCTAssertEqual(edl.tracks[16].regions[0].length, 4_000)
        XCTAssertEqual(edl.tracks[16].undoneEdits, 1)
        XCTAssertEqual(edl.tracks[0].undoneEdits, 0)
    }

    func testCloneIsReported() throws {
        var synth = simple()
        synth.versions[56] = [[.init(file: 0, length: 5_000)]]
        synth.cloneOf[56] = 0
        let edl = try EditList.parse(synth.build())
        XCTAssertEqual(edl.tracks[56].cloneOfKey, 0)
        XCTAssertNil(edl.tracks[0].cloneOfKey)
        XCTAssertTrue(edl.tracks[56].hasAudio)
    }

    func testRefusesWrongSize() {
        var synth = simple()
        var bytes = synth.build()
        bytes.removeLast()
        XCTAssertTrue(refusal(bytes).contains("bytes"))
    }

    func testRefusesBadSignature() {
        var synth = simple()
        var bytes = synth.build()
        bytes[0x18] = UInt8(ascii: "X")
        XCTAssertTrue(refusal(bytes).contains("signature"))
    }

    func testRefusesUnknownHeaderConstantsAndFormats() {
        var synth = simple()
        let good = synth.build()
        var bytes = good
        SyntheticEDL.put32(&bytes, 0x58, 200)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, 0x40, 96_000)
        XCTAssertTrue(refusal(bytes).contains("96000"))
        bytes = good
        SyntheticEDL.put32(&bytes, 0x4C, 441)
        XCTAssertTrue(refusal(bytes).contains("fade"))
        bytes = good
        bytes[0xB02586] = 0
        XCTAssertTrue(refusal(bytes).contains("file list"))
    }

    func testRefusesGapInTiling() {
        var synth = simple()
        var bytes = synth.build()
        let region = SyntheticEDL.nodeOffset(synth.regionNodes[8]![1])
        SyntheticEDL.put64(&bytes, region + 0x58, 1_001)
        XCTAssertTrue(refusal(bytes).contains("track 2"))
    }

    func testRefusesTimelineThatDoesNotEndWhereThePlaylistSays() {
        var synth = simple()
        var bytes = synth.build()
        SyntheticEDL.put64(&bytes, SyntheticEDL.nodeOffset(synth.playlistNode[0]!) + 0x58, SyntheticEDL.timeline + 1)
        XCTAssertTrue(refusal(bytes).contains("track 1"))
    }

    func testRefusesWrongNodeTypeAndKey() {
        var synth = simple()
        let good = synth.build()
        var bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[0]![0]) + 8, 2)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[0]![0]) + 0xC, 8)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.trackNode[0]!) + 0xC, 8)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.playlistNode[0]!) + 8, 3)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(0) + 8, 1)
        XCTAssertFalse(refusal(bytes).isEmpty)
    }

    func testRefusesSourceRangeThatDoesNotAddUp() {
        var synth = simple()
        var bytes = synth.build()
        SyntheticEDL.put64(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[0]![0]) + 0x70, 5_000)
        XCTAssertTrue(refusal(bytes).contains("source range"))
    }

    func testRefusesFileIDThatIsNotListedOrNoLongerUsed() {
        var synth = simple()
        let good = synth.build()
        var bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[0]![0]) + 0x50, 77)
        XCTAssertTrue(refusal(bytes).contains("77"))
        // Slot 2 holds ZZ0002_1.wav with id 0xFFFB; a region may not use it under any id.
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[0]![0]) + 0x50, 0xFFFB)
        XCTAssertFalse(refusal(bytes).isEmpty)
    }

    func testRefusesUnknownFadeLengthAndBrokenLinks() {
        var synth = simple()
        let good = synth.build()
        var bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[0]![0]) + 0x7C, 100)
        XCTAssertTrue(refusal(bytes).contains("fade"))
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.regionNodes[8]![1]) + 4, 5)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(synth.playlistNode[8]!) + 0x38, 9)
        XCTAssertFalse(refusal(bytes).isEmpty)
        bytes = good
        SyntheticEDL.put32(&bytes, SyntheticEDL.nodeOffset(8) + 0x2C, 3)
        XCTAssertFalse(refusal(bytes).isEmpty)
    }

    func testRefusesDuplicateFileIDAndOddClipNames() {
        var synth = simple()
        synth.files.append((1, "ZZ0009_1.wav"))
        XCTAssertTrue(refusal(synth.build()).contains("twice"))
        var other = simple()
        other.files.append((5, "../evil.wav"))
        XCTAssertFalse(refusal(other.build()).isEmpty)
    }
}
