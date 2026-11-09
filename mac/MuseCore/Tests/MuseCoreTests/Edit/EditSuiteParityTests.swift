import XCTest
@testable import MuseCore

/// Parity rows Android built app-side (WS8 22a950d, f90b4f3), the Mac port of each: same rules, one undo step, valid.
final class EditSuiteParityTests: XCTestCase {
    typealias E = EditV2

    private func fresh(_ d: Double = 10) -> EditSuiteState {
        EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: d), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
    }
    private func valid(_ s: EditSuiteState, file: StaticString = #filePath, line: UInt = #line) {
        let p = E.problem(s.project)
        XCTAssertNil(p, p?.description ?? "", file: file, line: line)
    }
    private let take2 = E.Asset(id: "t2", kind: .video, take: "tk2", durationSec: 6, width: 1080, height: 1920, hasAudio: true)
    private let song = E.Asset(id: "a1", kind: .audio, upload: "u1", durationSec: 3, hasAudio: true)

    func testSlipKeepsTheLength() {
        var s = fresh()
        let id = s.project.mainClips[0].id
        s.beginGesture(); s.updateGesture(s.trimming(id, .end, to: 5)); s.endGesture()
        XCTAssertTrue(s.slip(to: 4))
        XCTAssertEqual(s.project.mainClips[0].inSec, 4, accuracy: 1e-6)
        XCTAssertEqual(s.project.mainClips[0].outSec - s.project.mainClips[0].inSec, 5, accuracy: 1e-6)
        XCTAssertTrue(s.slip(to: 9))
        XCTAssertEqual(s.project.mainClips[0].inSec, 5, accuracy: 1e-6, "clamped to the source's end")
        valid(s)
    }

    func testSetLengthChangesSpeed() {
        var s = fresh()
        XCTAssertTrue(s.setClipLength(5))
        XCTAssertEqual(s.duration, 5, accuracy: 1e-6)
        XCTAssertEqual(s.selectedVideo?.speed, 2)
    }

    func testReplaceClipKeepsEdits() {
        var s = fresh()
        XCTAssertTrue(s.setSpeed(2))
        XCTAssertTrue(s.changeVisual { $0.adjust = E.Adjust(exposure: 0.3) })
        XCTAssertTrue(s.replaceClip(with: take2))
        let c = s.project.mainClips[0]
        XCTAssertEqual(c.asset, "t2")
        XCTAssertEqual(c.outSec, 6, accuracy: 1e-6, "the take is shorter than the clip's 10 s of source")
        XCTAssertEqual(c.speed, 2)
        XCTAssertEqual(c.adjust?.exposure, 0.3)
        valid(s)
    }

    func testBeatsTakeSoundAndLoop() throws {
        var s = fresh()
        XCTAssertTrue(s.addAudio(song, kind: .music))
        s.playhead = 1.5
        XCTAssertTrue(s.markBeat())
        s.playhead = 2.5
        XCTAssertTrue(s.markBeat())
        XCTAssertEqual(s.musicHere?.clip.beats, [1.5, 2.5])
        XCTAssertEqual(s.beats.map(\.t), [1.5, 2.5])
        XCTAssertTrue(s.clearBeats())
        XCTAssertNil(s.musicHere?.clip.beats)
        // Loop the 3 s song to the 10 s end: 4 pieces (3 + 3 + 3 + 1).
        s.selection = s.project.tracks.first { $0.kind == .music }?.items.first?.id
        XCTAssertTrue(s.loopToEnd())
        let music = try XCTUnwrap(s.project.tracks.first { $0.kind == .music })
        XCTAssertEqual(music.items.count, 4)
        XCTAssertEqual(music.items.last?.audioClip?.outSec ?? 0, 1, accuracy: 1e-6)
        valid(s)
        s.playhead = 2
        XCTAssertTrue(s.addTakeSound(take2))
        XCTAssertEqual(s.project.tracks.first { $0.kind == .sfx }?.items.first?.startSec, 2)
        valid(s)
    }

    func testLookEffects() {
        var s = fresh()
        for e in EditSuite.LookEffect.allCases {
            XCTAssertTrue(s.setLookEffect(e, e == .vignette ? -0.4 : 0.5), e.label)
            XCTAssertEqual(s.lookEffect(e), e == .vignette ? -0.4 : 0.5, accuracy: 1e-6)
        }
        valid(s)
        for e in EditSuite.LookEffect.allCases { XCTAssertTrue(s.setLookEffect(e, 0)) }
        XCTAssertNil(s.selectedVideo?.look, "all effects off: no look left")
    }

    func testSplitScreenSideBySide() throws {
        var s = fresh()
        s.playhead = 1
        XCTAssertTrue(s.addVideo(take2, overlay: true))
        XCTAssertEqual(s.clipsHere.count, 2)
        XCTAssertTrue(s.splitScreen(.sideBySide))
        let main = s.project.mainClips[0]
        XCTAssertEqual(main.fit, .contain)
        XCTAssertEqual(main.transform?.x, 0.25)
        let ov = try XCTUnwrap(s.project.tracks.first { $0.kind == .video }?.items.first?.videoClip)
        XCTAssertEqual(ov.transform?.x, 0.75)
        XCTAssertNotNil(main.crop, "a 9:16 picture cropped to a 9:32 cell")
        valid(s)
        var one = fresh()
        XCTAssertFalse(one.splitScreen(.grid))
        XCTAssertNotNil(one.lastRefusal)
    }

    func testCutToBeats() {
        var s = fresh()
        s.playhead = 4
        XCTAssertTrue(s.split())
        XCTAssertTrue(s.addAudio(E.Asset(id: "m", kind: .audio, upload: "u", durationSec: 30, hasAudio: true), kind: .music))
        let m = s.project.tracks.first { $0.kind == .music }!.items[0].id
        XCTAssertTrue(s.setBeats(m, beats: [1, 2, 3, 4.5, 6, 7.5, 9], strong: []))
        s.beatMarks = .every
        XCTAssertEqual(s.cutToBeats(), 2)
        XCTAssertEqual(E.timeline(s.project)[0].endSec, 4.5, accuracy: 1e-6)
        valid(s)
    }

    func testEvenVolume() throws {
        var s = fresh()
        s.playhead = 4
        XCTAssertTrue(s.split())
        s.playhead = 7
        XCTAssertTrue(s.split())
        let ids = s.project.mainClips.map(\.id)
        let n = s.evenVolume(levels: [ids[0]: (0.1, 0.3), ids[1]: (0.2, 0.5), ids[2]: (0.4, 0.95)])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(s.project.mainClips[0].volume, 2)
        XCTAssertNil(s.project.mainClips[1].volume, "the median stays")
        XCTAssertEqual(s.project.mainClips[2].volume, 0.5)
        valid(s)
    }
}
