import XCTest
@testable import MuseCore

/// Edit → Uploads as a media bin (owner, 2026-11-12): the kind from the file, the tiles, the chips, and placing an upload.
final class EditUploadBinTests: XCTestCase {
    typealias E = EditV2
    typealias Bin = EditSuite.UploadBin

    private func fixture(_ name: String) throws -> E.Project {
        let c = try XCTUnwrap(editorFixture("projects").array.first { $0["name"].string == name }, name)
        return try c["project"].decode(E.Project.self)
    }

    private func assertValid(_ s: EditSuiteState, file: StaticString = #filePath, line: UInt = #line) {
        let p = E.problem(s.project)
        XCTAssertNil(p, p?.description ?? "", file: file, line: line)
    }

    private let video = E.Asset(id: "up_v", kind: .video, upload: "u1", durationSec: 4, width: 720, height: 1280, hasAudio: true)
    private let picture = E.Asset(id: "up_p", kind: .image, upload: "u2", width: 800, height: 800)
    private let song = E.Asset(id: "up_s", kind: .audio, upload: "u3", durationSec: 168, hasAudio: true)
    private let blip = E.Asset(id: "up_b", kind: .audio, upload: "u4", durationSec: 1.5, hasAudio: true)

    func testKindComesFromTheFile() {
        XCTAssertEqual(Bin.kind(ofExtension: "MOV"), .video)
        XCTAssertEqual(Bin.kind(ofExtension: "mp4"), .video)
        XCTAssertEqual(Bin.kind(ofExtension: "heic"), .picture)
        XCTAssertEqual(Bin.kind(ofExtension: "png"), .picture)
        XCTAssertEqual(Bin.kind(ofExtension: "m4a"), .audio)
        XCTAssertEqual(Bin.kind(ofExtension: "wav"), .audio)
        XCTAssertNil(Bin.kind(ofExtension: "pdf"))
        XCTAssertNil(Bin.kind(ofExtension: "cube"))
    }

    func testItemsAreTheEditsOwnUploadsNewestFirst() throws {
        var p = try fixture("single clip")
        let takeAssets = p.assets.count
        p = p.addingAsset(video).addingAsset(picture).addingAsset(song)
        p = p.addingAsset(E.Asset(id: "lib", kind: .image, library: "content:emoji/1f600"))
        var reversed = E.Asset(id: "rev", kind: .video, upload: "u9", durationSec: 4)
        reversed.reverseOf = "up_v"
        p = p.addingAsset(reversed)
        let items = Bin.items(p, names: ["up_v": "Living room dance", "up_s": "  "])
        XCTAssertEqual(items.map(\.id), ["up_s", "up_p", "up_v"], "uploads only (no takes \(takeAssets), no library, no helper copies), newest first")
        XCTAssertEqual(items.map(\.name), ["Sound", "Picture", "Living room dance"])
        XCTAssertNil(items[1].durationSec, "a picture has no length")
    }

    func testChipsOnlyWhenKindsAreMixed() {
        let v = EditSuite.Upload(id: "a", kind: .video, name: "A", durationSec: 3)
        let v2 = EditSuite.Upload(id: "b", kind: .video, name: "B", durationSec: 5)
        let s = EditSuite.Upload(id: "c", kind: .audio, name: "C", durationSec: 9)
        XCTAssertEqual(Bin.filters([]), [])
        XCTAssertEqual(Bin.filters([v, v2]), [])
        XCTAssertEqual(Bin.filters([v, s]), [.all, .video, .audio])
        XCTAssertEqual(Bin.filtered([v, v2, s], by: .audio).map(\.id), ["c"])
        XCTAssertEqual(Bin.filtered([v, v2], by: .audio).map(\.id), ["a", "b"], "a chip that no longer applies shows everything")
        XCTAssertEqual(EditSuite.UploadFilter.allCases.map(\.label), ["All", "Video", "Images", "Audio"])
    }

    func testLengthLabel() {
        XCTAssertEqual(Bin.length(23.4), "0:23")
        XCTAssertEqual(Bin.length(168), "2:48")
        XCTAssertEqual(Bin.length(0.3), "0:01", "never 0:00 for a real clip")
        XCTAssertEqual(Bin.length(3725), "1:02:05")
        XCTAssertNil(Bin.length(nil))
        XCTAssertNil(Bin.length(.infinity))
        XCTAssertNil(Bin.length(0))
    }

    func testAddToBinIsUndoableAndValid() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let before = s.project
        XCTAssertTrue(s.addToBin(video))
        XCTAssertFalse(s.addToBin(video), "already in the bin")
        XCTAssertEqual(s.project.tracks, before.tracks, "nothing placed")
        assertValid(s)
        XCTAssertTrue(s.undo())
        XCTAssertNil(s.project.asset("up_v"))
    }

    func testPlusPutsAVideoIntoTheSequenceAtThePlayhead() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let first = try XCTUnwrap(s.project.mainClips.first?.id)
        XCTAssertTrue(s.addToBin(video))
        // Playhead in the first half of the only clip: the new clip goes before it.
        s.playhead = 0.2
        XCTAssertTrue(s.placeUpload("up_v"))
        XCTAssertEqual(s.project.mainClips.map(\.asset).first, "up_v")
        XCTAssertEqual(s.project.mainClips.last?.id, first)
        assertValid(s)
        // At the end: after everything.
        XCTAssertTrue(s.placeUpload("up_v", at: s.duration))
        XCTAssertEqual(s.project.mainClips.last?.asset, "up_v")
        XCTAssertEqual(s.project.mainClips.count, 3)
        assertValid(s)
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.project.mainClips.count, 2, "one placement, one undo step")
    }

    func testDroppedOnAnOverlayRowItBecomesAnOverlayAtThatTime() throws {
        var s = EditSuiteState(try fixture("single clip"))
        XCTAssertTrue(s.addToBin(video))
        let main = s.project.mainClips.count
        XCTAssertTrue(s.placeUpload("up_v", at: 1, lane: .video))
        XCTAssertEqual(s.project.mainClips.count, main)
        let overlay = try XCTUnwrap(s.project.tracks.first { $0.kind == .video }?.items.first?.videoClip)
        XCTAssertEqual(overlay.startSec ?? -1, 1, accuracy: 1e-6)
        assertValid(s)
    }

    func testSoundsGoOnTheRowTheyWereDroppedOnElseByLength() throws {
        var s = EditSuiteState(try fixture("single clip"))
        XCTAssertTrue(s.addToBin(song))
        XCTAssertTrue(s.addToBin(blip))
        XCTAssertTrue(s.placeUpload("up_s", at: 0))
        XCTAssertNotNil(s.project.tracks.first { $0.kind == .music }, "a long file is a song")
        XCTAssertTrue(s.placeUpload("up_b", at: 1))
        XCTAssertEqual(s.project.tracks.first { $0.kind == .sfx }?.items.first?.startSec ?? -1, 1, accuracy: 1e-6, "a short one a sound effect, at the drop")
        XCTAssertTrue(s.placeUpload("up_b", at: 0.5, lane: .voice))
        XCTAssertNotNil(s.project.tracks.first { $0.kind == .voice }, "dropped on the voice row")
        XCTAssertTrue(s.placeUpload("up_s", audioKind: .voice))
        XCTAssertEqual(s.project.tracks.filter { $0.kind == .voice }.flatMap(\.items).count, 2, "the + menu's choice wins (an overlap takes a second voice row)")
        assertValid(s)
        XCTAssertEqual(Bin.audioKind(lane: .main, durationSec: 5), .sfx)
        XCTAssertEqual(Bin.audioKind(lane: nil, durationSec: 30), .music)
    }

    func testAPictureGoesOnTheStickersRowAtTheDrop() throws {
        var s = EditSuiteState(try fixture("single clip"))
        XCTAssertTrue(s.addToBin(picture))
        XCTAssertTrue(s.placeUpload("up_p", at: 0.5, lane: .music))
        let item = try XCTUnwrap(s.project.tracks.first { $0.kind == .image }?.items.first)
        XCTAssertEqual(item.startSec, 0.5, accuracy: 1e-6)
        assertValid(s)
        XCTAssertFalse(s.placeUpload("nope"))
    }

    func testATakeIsPlacedLikeAnUpload() throws {
        var s = EditSuiteState(try fixture("single clip"))
        let take = E.Asset(id: "t9", kind: .video, take: "tk_9", durationSec: 3, width: 720, height: 1280, hasAudio: true)
        XCTAssertTrue(s.place(take, at: 0))
        XCTAssertEqual(s.project.mainClips.first?.asset, "t9")
        XCTAssertNotNil(s.project.asset("t9"))
        XCTAssertTrue(Bin.items(s.project, names: [:]).isEmpty, "a take is not an upload")
        assertValid(s)
    }
}
