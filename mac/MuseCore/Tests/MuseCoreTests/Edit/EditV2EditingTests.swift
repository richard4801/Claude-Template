import XCTest
@testable import MuseCore

/// The v2 editing API (immutable operations + undo/redo) and the render plan the AVFoundation engine follows.
final class EditV2EditingTests: XCTestCase {
    typealias E = EditV2

    private func fixtureProject(_ name: String) throws -> E.Project {
        let c = try XCTUnwrap(editorFixture("projects").array.first { $0["name"].string == name }, name)
        return try c["project"].decode(E.Project.self)
    }

    private func clip(_ id: String, _ a: Double, _ b: Double, speed: Double = 1, tr: E.Transition? = nil) -> E.Item {
        .video(E.VideoClip(id: id, asset: "src", inSec: a, outSec: b, speed: speed, transitionIn: tr))
    }

    // MARK: Editing

    func testSplitMainClip() throws {
        let p = try fixtureProject("single clip")
        let (q, nid) = try XCTUnwrap(p.splittingMainClip(at: 2))
        XCTAssertEqual(q.mainClips.map(\.id), ["c1", nid])
        XCTAssertEqual(q.mainClips[0].outSec, 2.5, accuracy: 1e-9)
        XCTAssertEqual(q.mainClips[1].inSec, 2.5, accuracy: 1e-9)
        XCTAssertEqual(E.durationSec(q), E.durationSec(p), accuracy: 1e-9)
        XCTAssertNil(E.problem(q))
        XCTAssertNil(p.splittingMainClip(at: 0.05), "too close to the start")
        XCTAssertNil(p.splittingMainClip(at: 9.27), "too close to the end")
    }

    func testSplitKeepsSpeedCaptionsAndKeyframes() throws {
        var p = try fixtureProject("captions through cuts")
        let words = E.captionWords(p).map(\.index)
        // c2 starts at 3.5 on the timeline and plays at 1.5×: 1 s in is 1.5 s of source.
        let (q, nid) = try XCTUnwrap(p.splittingMainClip(at: 4.5))
        let b = try XCTUnwrap(q.mainClips.first { $0.id == nid })
        XCTAssertEqual(b.inSec, 6, accuracy: 1e-9)
        XCTAssertEqual(b.speed, 1.5)
        XCTAssertEqual(E.captionWords(q).map(\.index), words, "captions follow the source")

        p = try fixtureProject("volume keyframes")
        let (r, rid) = try XCTUnwrap(p.splittingMainClip(at: 3))
        let a = r.mainClips[0], c = try XCTUnwrap(r.mainClips.first { $0.id == rid })
        XCTAssertEqual(E.keyframeValue(a.keyframes!.volume!, 3), 0.2, accuracy: 1e-9)
        XCTAssertEqual(E.keyframeValue(c.keyframes!.volume!, 0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(E.keyframeValue(c.keyframes!.volume!, 1), 1.5, accuracy: 1e-9)
        XCTAssertNotNil(r.mainClips.last?.transitionIn, "the next clip keeps its transition")
    }

    func testTransitions() throws {
        let p = try fixtureProject("cut and speeds")
        XCTAssertNil(p.settingTransition("c1", E.Transition(kind: .fade, durationSec: 0.5)), "not on the first clip")
        XCTAssertNil(p.settingTransition("c2", E.Transition(kind: .fade, durationSec: 1.5)), "more than half of c1")
        let q = try XCTUnwrap(p.settingTransition("c2", E.Transition(kind: .zoom, durationSec: 0.5)))
        XCTAssertEqual(E.durationSec(q), E.durationSec(p) - 0.5, accuracy: 1e-9)
        XCTAssertNil(E.problem(q))
        XCTAssertNil(q.settingTransition("c2", E.Transition(kind: .zoom, durationSec: 0.5)), "no change")
        XCTAssertNil(try XCTUnwrap(q.settingTransition("c2", nil)).mainClips[1].transitionIn)
        // Removing c1 makes c2 first: its transition goes.
        let r = try XCTUnwrap(q.removing("c1"))
        XCTAssertNil(r.mainClips[0].transitionIn)
        // Moving a clip re-checks transitions.
        let m = try XCTUnwrap(q.movingMainClip("c2", to: 0))
        XCTAssertEqual(m.mainClips.map(\.id), ["c2", "c1", "c3"])
        XCTAssertNil(m.mainClips[0].transitionIn)
    }

    func testAddRemoveMoveItems() throws {
        let p = try fixtureProject("pip text image look")
        let hook = E.hooks[2].item(id: "t3", startSec: 7)
        let q = try XCTUnwrap(p.adding(.text(hook), toTrack: "txt"))
        XCTAssertEqual(q.track("txt")?.items.map(\.id), ["t1", "t2", "t3"])
        XCTAssertNil(E.problem(q))
        XCTAssertNil(p.adding(.text(E.hooks[2].item(id: "t4", startSec: 2)), toTrack: "txt"), "overlaps t1")
        XCTAssertNil(p.adding(.text(E.hooks[2].item(id: "t1", startSec: 8)), toTrack: "txt"), "id in use")
        XCTAssertNil(p.adding(.text(hook), toTrack: "imgs"), "wrong track kind")
        // A new text track to stack on.
        let (r, tid) = try XCTUnwrap(p.addingTrack(.text))
        let s = try XCTUnwrap(r.adding(.text(E.hooks[0].item(id: "t9", startSec: 1)), toTrack: tid))
        XCTAssertNil(E.problem(s))
        XCTAssertNil(p.addingTrack(.main))
        // Move t2 later, and onto the new track.
        let m = try XCTUnwrap(p.moving("t2", toStartSec: 3.5))
        XCTAssertEqual(m.track("txt")?.item("t2")?.startSec, 3.5)
        XCTAssertNil(q.moving("t2", toStartSec: 1), "would overlap t1")
        let m2 = try XCTUnwrap(s.moving("t2", toStartSec: 5, track: tid))
        XCTAssertEqual(m2.track(tid)?.items.map(\.id), ["t9", "t2"])
        XCTAssertNil(p.removing("c1"), "the main track keeps a clip")
        XCTAssertEqual(try XCTUnwrap(p.removing("i1")).track("imgs")?.items.count, 0)
        // Main clips are added at an index.
        let a = try XCTUnwrap(p.adding(clip("c9", 0, 2), toTrack: "main", index: 0))
        XCTAssertEqual(a.mainClips.map(\.id), ["c9", "c1"])
    }

    func testHistory() throws {
        let p = try fixtureProject("cut and speeds")
        var h = E.History(p)
        XCTAssertFalse(h.apply { $0.removing("nope") })
        XCTAssertTrue(h.apply { $0.removing("c2") })
        XCTAssertTrue(h.apply { $0.splittingMainClip(at: 1)?.project })
        XCTAssertEqual(h.current.mainClips.count, 3)
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.current.mainClips.map(\.id), ["c1", "c3"])
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.current, p)
        XCTAssertFalse(h.undo())
        XCTAssertTrue(h.redo())
        XCTAssertEqual(h.current.mainClips.count, 2)
        h.begin()
        h.update(p)
        h.end()
        XCTAssertEqual(h.undoCount, 2)
        h.begin()
        h.end()
        XCTAssertEqual(h.undoCount, 2, "a drag that ended where it began leaves no step")
    }

    func testIdsAndRoundTripAfterEdits() throws {
        let p = try fixtureProject("music ducking")
        XCTAssertEqual(p.newId("c"), "c2")
        let (q, _) = try XCTUnwrap(p.splittingMainClip(at: 5))
        XCTAssertEqual(try E.Project.decode(q.encoded()), q)
    }

    // MARK: Render plan

    private let src = E.MediaInfo(durationSec: 10, hasVideo: true, hasAudio: true, width: 1080, height: 1920)

    func testPlanAlternatesMainLanesAndCoversTheTimeline() throws {
        let p = try fixtureProject("transitions")
        let plan = E.renderPlan(p, media: ["src": src])
        let main = plan.video.filter(\.isMain)
        XCTAssertEqual(main.map(\.lane), [0, 1, 0])
        XCTAssertEqual(main.map(\.timelineStart), [0, 3.5, 5.5])
        XCTAssertEqual(main.map(\.timelineEnd), [4, 6.5, 8.5])
        XCTAssertEqual(main[2].sourceStart, 7)
        XCTAssertEqual(main[2].sourceEnd, 10, accuracy: 1e-9)
        XCTAssertEqual(plan.durationSec, 8.5)
        XCTAssertEqual(plan.boundaries, [0, 3.5, 4, 5.5, 6.5, 8.5])
        XCTAssertEqual(plan.videoSegments(from: 3.5, to: 4).map(\.itemId), ["c1", "c2"])
        // Audio crossfades on the A/B lanes with the reference envelopes.
        XCTAssertEqual(plan.audio.map(\.lane), [0, 1, 0])
        XCTAssertEqual(plan.audio[2].envelope, E.audioEnvelope(p, trackId: "main", itemId: "c3"))

        // Mid fade: c1 under c2 at half opacity.
        let f = E.mainFrame(p, plan: plan, at: 3.75)
        XCTAssertEqual(f.layers.map(\.segment.itemId), ["c1", "c2"])
        XCTAssertEqual(f.layers[1].state.opacity, 0.5, accuracy: 1e-9)
        XCTAssertNil(f.dip)
        // Slide: c3 comes in from the right.
        let g = E.mainFrame(p, plan: plan, at: 6)
        XCTAssertEqual(g.layers.map(\.segment.itemId), ["c2", "c3"])
        XCTAssertEqual(g.layers[1].state.dx, 0.5, accuracy: 1e-9)
        XCTAssertEqual(E.mainFrame(p, plan: plan, at: 7).layers.map(\.segment.itemId), ["c3"])
    }

    func testPlanDipAndSpeeds() throws {
        let p = try fixtureProject("volume keyframes")
        let plan = E.renderPlan(p, media: ["src": src, "song": E.MediaInfo(durationSec: 30, hasVideo: false, hasAudio: true)])
        let f = E.mainFrame(p, plan: plan, at: 5.7)
        XCTAssertEqual(f.dip, "#000000")
        XCTAssertEqual(f.layers.count, 2)
        // c2 is muted: no audio segment; the sfx gets its own lane.
        XCTAssertEqual(plan.audio.map(\.itemId), ["c1", "s1"])
        XCTAssertEqual(plan.audio.map(\.lane), [0, 2])

        let s = try fixtureProject("cut and speeds")
        let sp = E.renderPlan(s, media: ["src": src])
        XCTAssertEqual(sp.video.map(\.timelineLength), [2, 4, 3])
        XCTAssertEqual(sp.video.map(\.sourceStart), [0, 2, 4])
        XCTAssertEqual(sp.video.map(\.sourceEnd), [2, 4, 10])
    }

    func testPlanOverlaysAudioTracksAndEnd() throws {
        let p = try fixtureProject("pip text image look")
        let pip = E.MediaInfo(durationSec: 6, hasVideo: true, hasAudio: true, width: 720, height: 1280)
        let plan = E.renderPlan(p, media: ["src": src, "pip": pip])
        let o = try XCTUnwrap(plan.video.first { !$0.isMain })
        XCTAssertEqual(o.lane, 2)
        XCTAssertEqual(o.layer, 1)
        XCTAssertEqual(o.timelineStart, 1)
        XCTAssertEqual(o.timelineEnd, 5.5)
        XCTAssertEqual(plan.audio.map(\.itemId), ["c1"], "the pip's volume is 0")
        XCTAssertEqual(E.renderPlan(p, media: ["src": src]).video.count, 1, "a source that couldn't be read is left out")
        var hidden = p
        hidden.tracks[1].hidden = true
        XCTAssertEqual(E.renderPlan(hidden, media: ["src": src, "pip": pip]).video.count, 1)

        let m = try fixtureProject("music ducking")
        let mp = E.renderPlan(m, media: ["src": src, "song": E.MediaInfo(durationSec: 30, hasVideo: false, hasAudio: true),
                                         "vo": E.MediaInfo(durationSec: 4, hasVideo: false, hasAudio: true)])
        XCTAssertEqual(mp.audio.map(\.itemId), ["c1", "m1", "v1"])
        XCTAssertEqual(mp.audio.map(\.lane), [0, 2, 3])
        XCTAssertEqual(mp.audio[1].sourceStart, 5)
        XCTAssertEqual(mp.audio[1].sourceEnd, 15)
        XCTAssertEqual(mp.audio[1].envelope, E.audioEnvelope(m, trackId: "mus", itemId: "m1"))

        // Music longer than the video is cut at the end.
        var long = m
        long.tracks[2].items[0] = .audio(E.AudioClip(id: "m1", asset: "song", startSec: 2, inSec: 0, outSec: 30))
        let lp = E.renderPlan(long, media: ["src": src, "song": E.MediaInfo(durationSec: 30, hasVideo: false, hasAudio: true)])
        let seg = try XCTUnwrap(lp.audio.first { $0.itemId == "m1" })
        XCTAssertEqual(seg.timelineEnd, 10)
        XCTAssertEqual(seg.sourceEnd, 8, accuracy: 1e-9)
    }

    func testPlacementAndFit() throws {
        let p = try fixtureProject("pip text image look")
        let pip = try XCTUnwrap(p.track("pipt")?.items[0].videoClip)
        XCTAssertEqual(E.placement(pip, local: 0).scale, 0.2, accuracy: 1e-9)
        XCTAssertEqual(E.placement(pip, local: 1).scale, 0.4, accuracy: 1e-9)
        XCTAssertEqual(E.placement(pip, local: 1).x, 0.75)
        let t1 = try XCTUnwrap(p.track("txt")?.items[0].textItem)
        XCTAssertEqual(E.placement(t1, local: 0).opacity, 0)
        XCTAssertEqual(E.placement(t1, local: 1).opacity, 1)
        let cover = E.fittedSize(width: 1920, height: 1080, crop: nil, fit: .cover, canvasWidth: 1080, canvasHeight: 1920)
        XCTAssertEqual(cover.1, 1920, accuracy: 1e-9)
        XCTAssertEqual(cover.0, 1920 * 1920 / 1080, accuracy: 1e-6)
        let contain = E.fittedSize(width: 1920, height: 1080, crop: nil, fit: .contain, canvasWidth: 1080, canvasHeight: 1920)
        XCTAssertEqual(contain.0, 1080, accuracy: 1e-9)
    }

    func testChromaKey() {
        let ck = E.Chroma(color: "#00FF00", similarity: 0.4, smoothness: 0.08, spill: 0.5)
        XCTAssertEqual(E.chromaKey(0, 1, 0, ck).alpha, 0)
        XCTAssertEqual(E.chromaKey(0.2, 0.7, 0.3, ck).alpha, 0, "a darker screen green")
        XCTAssertEqual(E.chromaKey(0.9, 0.7, 0.6, ck).alpha, 1, "skin")
        XCTAssertEqual(E.chromaKey(0.5, 0.5, 0.5, ck).alpha, 1, "grey")
        let cube = E.chromaCube(ck, size: 4)
        XCTAssertEqual(cube.count, 4 * 4 * 4 * 4)
        // Entry (r 0, g 1, b 0) is index 0 + 3*4 → keyed out, premultiplied to 0.
        XCTAssertEqual(Array(cube[(3 * 4) * 4 ..< (3 * 4) * 4 + 4]), [0, 0, 0, 0])
    }
}
