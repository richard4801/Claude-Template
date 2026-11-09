import XCTest
@testable import MuseCore

/// Helper copies (WS8 2df521a): sourceOf / derivedOps / derivedLabel on a chain, deriveClip both ways, and applySlowmo
/// (functions.json → derived, slowmo). Validation cases are in validation.json.
final class EditV2DerivedTests: XCTestCase {
    typealias E = EditV2

    func testChains() throws {
        let d = try editorFixture("functions")["derived"]
        let p = E.Project(sourceTakeId: "tk_1", canvas: E.Canvas(width: 1080, height: 1920, fps: 30),
                          assets: try d["assets"].decode([E.Asset].self), tracks: [])
        let chains = d["chains"].array
        XCTAssertGreaterThanOrEqual(chains.count, 5)
        for c in chains {
            let id = try XCTUnwrap(c["asset"].string)
            XCTAssertEqual(E.sourceOf(p, id), c["source"].string, id)
            XCTAssertEqual(E.derivedOps(p, id), c["ops"].array.compactMap(\.string), id)
            XCTAssertEqual(E.derivedLabel(p, id), c["label"].string, id)
        }
    }

    func testDeriveClip() throws {
        let d = try editorFixture("functions")["derived"]
        let clip = try d["clip"].decode(E.VideoClip.self)
        for s in d["swaps"].array {
            let op = s["op"].string.flatMap(E.DerivedOp.init(rawValue:))
            let got = E.deriveClip(clip, copy: try XCTUnwrap(s["copy"].string), op: op)
            let diff = jsonDiff(try JV.of(got), s["clip"]); XCTAssert(diff.isEmpty, "\(String(describing: op)): " + diff.prefix(4).joined(separator: "; "))
        }
    }

    func testApplySlowmo() throws {
        let cases = try editorFixture("functions")["slowmo"].array
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let name = c["name"].string ?? "?"
            let p = try c["project"].decode(E.Project.self)
            // As editor-fixtures.ts: clip "c1", copy "src_sm".
            let got = E.applySlowmo(p, clipId: "c1", slowId: "src_sm")
            if c["result"].isNull { XCTAssertNil(got, name); continue }
            let r = try XCTUnwrap(got, name)
            XCTAssertEqual(r.id, c["result"]["id"].string, name)
            let diff = jsonDiff(try JV.of(r.project), c["result"]["project"]); XCTAssert(diff.isEmpty, "\(name): " + diff.prefix(5).joined(separator: "; "))
            XCTAssertNil(E.problem(r.project), name)
        }
    }

    /// Stabilise on the selected clip, then Reverse on top: only the last step switches off.
    func testStabiliseThenReverse() throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        let id = s.project.mainClips[0].id
        s.selection = id
        let orig = s.project.mainClips[0].asset
        var st = E.Asset(id: "src_st", kind: .video, upload: "u_st", durationSec: 10, width: 1080, height: 1920, hasAudio: true)
        st.derivedFrom = E.DerivedFrom(asset: orig, op: .stabilize)
        XCTAssertEqual(s.stabilizeSelected(to: st), [])
        XCTAssertEqual(s.project.mainClips[0].asset, "src_st")
        XCTAssertEqual(s.steadiedFrom, orig)
        XCTAssertEqual(s.selectedSteps, ["stabilize"])
        XCTAssertNil(E.problem(s.project))
        var rev = E.Asset(id: "src_st_rev", kind: .video, upload: "u_rev", durationSec: 10, width: 1080, height: 1920, hasAudio: true)
        rev.reverseOf = "src_st"
        XCTAssertNotNil(s.reverseSelected(to: rev))
        XCTAssertEqual(s.selectedSteps, ["stabilize", "reverse"])
        XCTAssertEqual(s.blockingStep(for: "stabilize"), "reverse")
        XCTAssertNil(s.blockingStep(for: "reverse"))
        XCTAssertEqual(E.derivedLabel(s.project, s.project.mainClips[0].asset), "Steadied, reversed")
        XCTAssertNil(E.problem(s.project))
        // Reverse off, then Stabilise off: back to the original, the copies kept for next time.
        XCTAssertNotNil(s.reverseSelected(to: try XCTUnwrap(s.project.asset("src_st"))))
        XCTAssertNotNil(s.stabilizeSelected(to: try XCTUnwrap(s.project.asset(orig))))
        XCTAssertEqual(s.project.mainClips[0].asset, orig)
        XCTAssertEqual(s.selectedSteps, [])
        XCTAssertNotNil(s.steadiedCopy(of: orig))
    }
}

extension EditV2DerivedTests {
    func testSlowmoOnTheSelectedClip() throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        let c = s.project.mainClips[0]
        s.selection = c.id
        s.playhead = 9   // near the end: the range moves back inside the clip
        let r = try XCTUnwrap(s.slowmoRange(lengthSec: 2))
        XCTAssertEqual(r.startSec, 8, accuracy: 1e-9)
        XCTAssertEqual(r.endSec, 10, accuracy: 1e-9)
        s.playhead = 3
        let r2 = try XCTUnwrap(s.slowmoRange(lengthSec: 2))
        XCTAssertEqual(r2.startSec, 3, accuracy: 1e-9)
        var copy = E.Asset(id: "src_sm", kind: .video, upload: "u_sm", durationSec: 8, width: 1080, height: 1920, hasAudio: false)
        copy.derivedFrom = E.DerivedFrom(asset: c.asset, op: .slowmo, startSec: r2.startSec, endSec: r2.endSec, factor: 4)
        XCTAssertTrue(s.applySlowmoSelected(copy))
        XCTAssertEqual(s.project.mainClips.count, 3)
        XCTAssertEqual(s.selectedVideo?.asset, "src_sm")
        XCTAssertEqual(s.selectedVideo?.muted, true)
        XCTAssertEqual(E.durationSec(s.project), 10 - 2 + 8, accuracy: 1e-6)
        XCTAssertEqual(E.derivedLabel(s.project, "src_sm"), "Smooth 4×")
        XCTAssertNotNil(s.slowmoCopy(of: c.asset, startSec: 3, endSec: 5, factor: 4))
        XCTAssertNil(E.problem(s.project))
        s.undo()
        XCTAssertEqual(s.project.mainClips.count, 1)
    }
}

extension EditV2DerivedTests {
    /// Translated captions (functions.json → captionTranslate, WS8 cac2bb0).
    func testCaptionTranslate() throws {
        let f = try editorFixture("functions")["captionTranslate"]
        func ct(_ k: String) throws -> E.CaptionTrack { try f[k].decode(E.CaptionTrack.self) }
        func same(_ got: E.CaptionTrack, _ k: String) throws {
            let d = jsonDiff(try JV.of(got), f[k]); XCTAssert(d.isEmpty, "\(k): " + d.prefix(4).joined(separator: "; "))
        }
        let base = try ct("base"), es = try ct("es"), fr = try ct("fr")
        try same(E.translateCaptions(base, language: "es", words: es.words, sourceLanguage: "en"), "es")
        try same(E.translateCaptions(es, language: "fr", words: fr.words, sourceLanguage: "en"), "fr")
        try same(E.swapCaptionOriginal(fr), "frOriginal")
        try same(E.swapCaptionOriginal(E.swapCaptionOriginal(fr)), "frBack")
        try same(E.swapCaptionOriginal(base), "baseSwap")
        try same(E.translateCaptions(base, language: "de", words: try ct("noSource").words), "noSource")
    }
}

extension EditV2DerivedTests {
    func testTranslateTheCaptions() async throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        let asset = s.project.mainClips[0].asset
        XCTAssertTrue(s.setCaptions(words: [E.Word(text: "Hello", startSec: 0, endSec: 0.5), E.Word(text: "big", startSec: 0.5, endSec: 1),
                                            E.Word(text: "world", startSec: 1, endSec: 1.5), E.Word(text: "again", startSec: 1.5, endSec: 2)], assetId: asset))
        let lines = s.captionLinesToTranslate
        XCTAssertEqual(lines.map(\.id), lines.indices.map { String($0) })
        XCTAssertEqual(lines.map(\.text).joined(separator: " "), "Hello big world again")
        // The demo job: the lines come back tagged and timed.
        let api = FakeMuseAPI(genDelay: 0.01)
        var o = EditorJobOptions(); o.targetLanguage = "es"; o.sourceLanguage = "en"; o.lines = lines
        var job = try await api.startEditorJob(EditorJobRequest(kind: .translate, source: EditorSource(takeId: nil, uploadId: "u", durationSec: 6), options: o))
        for _ in 0..<100 where job.isRunning { try await Task.sleep(nanoseconds: 20_000_000); job = try await api.editorJob(id: job.id) }
        let r = try XCTUnwrap(job.result)
        XCTAssertEqual(r.lines?.first?.translated?.hasPrefix("[es]"), true)
        XCTAssertTrue(s.setCaptionTranslation(language: "es", words: try XCTUnwrap(r.words), sourceLanguage: r.sourceLanguage))
        XCTAssertEqual(s.captionLanguage, "es")
        XCTAssertEqual(s.captionOriginalLanguage, "en")
        XCTAssertEqual(s.project.captionTrack?.original?.words.first?.text, "Hello")
        XCTAssertNil(E.problem(s.project))
        // Translating again works from the original (the lines are the English ones).
        XCTAssertEqual(s.captionLinesToTranslate.first?.text.hasPrefix("Hello"), true)
        XCTAssertTrue(s.swapCaptionOriginal())
        XCTAssertEqual(s.captionLanguage, "en")
        XCTAssertEqual(s.project.captionTrack?.words.first?.text, "Hello")
        XCTAssertTrue(s.swapCaptionOriginal())
        XCTAssertEqual(s.captionLanguage, "es")
    }
}

extension EditV2DerivedTests {
    /// Captions in other scripts (functions.json → captionScripts, WS8 d0c1a6e): joiner, right to left, text, a Japanese .srt.
    func testCaptionScripts() throws {
        let f = try editorFixture("functions")["captionScripts"]
        let words = ["今日は", "いい", "天気"]
        for c in f["languages"].array {
            let l = c["language"].string
            XCTAssertEqual(E.captionJoiner(l), c["joiner"].string, l ?? "nil")
            XCTAssertEqual(E.isRtlLanguage(l), c["rtl"] == .bool(true), l ?? "nil")
            XCTAssertEqual(E.captionText(words, l), c["text"].string, l ?? "nil")
        }
        let p = try f["srtJa"]["project"].decode(E.Project.self)
        XCTAssertEqual(E.toSrt(p), f["srtJa"]["srt"].string)
    }
}

extension EditV2DerivedTests {
    /// Lyric captions (functions.json → lyricCaptions, WS8 54f4b17): the song's words mapped through its music clips.
    func testLyricCaptions() throws {
        let f = try editorFixture("functions")["lyricCaptions"]
        let p = try f["project"].decode(E.Project.self)
        let d1 = jsonDiff(try JV.of(E.captionWords(p)), f["words"]); XCTAssert(d1.isEmpty, "words: " + d1.prefix(4).joined(separator: "; "))
        let d2 = jsonDiff(try JV.of(E.captionPages(p)), f["pages"]); XCTAssert(d2.isEmpty, "pages: " + d2.prefix(4).joined(separator: "; "))
    }
}

extension EditV2DerivedTests {
    /// Overlay cross-dissolves (functions.json → overlayFades, WS8 3d62419): every item's alpha at each sample time.
    func testOverlayFades() throws {
        let f = try editorFixture("functions")["overlayFades"]
        let p = try f["project"].decode(E.Project.self)
        XCTAssertNil(E.problem(p))
        for s in f["samples"].array {
            let t = try XCTUnwrap(s["t"].double)
            for tr in p.tracks where tr.kind == .video || tr.kind == .image {
                for it in tr.items {
                    XCTAssertEqual(E.overlayFade(p, tr, it, t), try XCTUnwrap(s["alpha"][it.id].double), accuracy: 1e-6, "\(it.id) at \(t)")
                }
            }
        }
    }

    /// Split voice and music (functions.json → separation, WS8 b5cb9248).
    func testSeparation() throws {
        let f = try editorFixture("functions")["separation"]
        let p = try f["project"].decode(E.Project.self)
        for c in f["cases"].array {
            let keep = try XCTUnwrap(c["keep"].string.flatMap(E.SeparationKeep.init(rawValue:)))
            let got = E.applySeparation(p, clipId: try XCTUnwrap(c["clip"].string), vocals: "voc", instrumental: "ins", keep: keep)
            let name = "\(c["clip"].string ?? "") \(keep)"
            if c["result"].isNull { XCTAssertNil(got, name); continue }
            let r = try XCTUnwrap(got, name)
            XCTAssertEqual(r.ids, c["result"]["ids"].array.compactMap(\.string), name)
            let d = jsonDiff(try JV.of(r.project), c["result"]["project"]); XCTAssert(d.isEmpty, "\(name): " + d.prefix(4).joined(separator: "; "))
        }
    }

    /// Cut out a picture (functions.json → cutouts, WS8 b5cb9248).
    func testCutouts() throws {
        for c in try editorFixture("functions")["cutouts"].array {
            let name = c["name"].string ?? "?"
            let p = try c["project"].decode(E.Project.self)
            let box = try c["box"].decode(E.CutoutBox.self)
            let got = E.applyCutout(p, itemId: "i1", assetId: "cut", box: box, sourceWidth: c["sourceWidth"].double!, sourceHeight: c["sourceHeight"].double!)
            if c["result"].isNull { XCTAssertNil(got, name); continue }
            let d = jsonDiff(try JV.of(try XCTUnwrap(got, name)), c["result"]); XCTAssert(d.isEmpty, "\(name): " + d.prefix(4).joined(separator: "; "))
        }
    }
}

extension EditV2DerivedTests {
    /// The effects library's reference maths (functions.json → effects, WS8 f7226f2): every sample pixel.
    func testEffectsReference() throws {
        let f = try editorFixture("functions")["effects"]
        XCTAssertEqual(f["perm"].array.compactMap(\.double).map(Int.init), E.effectPerm)
        // The pattern is sampled bilinearly between pixel centres; each case tells the effect its own frame size.
        let pat = f["pattern"]
        let PW = Int(try XCTUnwrap(pat["width"].double)), PH = Int(try XCTUnwrap(pat["height"].double))
        let px = pat["pixels"].array.map { E.RGB($0[0].double!, $0[1].double!, $0[2].double!) }
        XCTAssertEqual(px.count, PW * PH)
        let sample = E.imageSampler(width: PW, height: PH, px)
        let cases = f["cases"].array
        XCTAssertEqual(Set(cases.map { "\($0["width"].double ?? 0)x\($0["height"].double ?? 0)" }).count, 2, "both frame shapes")
        XCTAssertEqual(cases.count % E.effectIds.count, 0)
        for c in cases {
            let e = try c["effect"].decode(E.Effect.self), t = try XCTUnwrap(c["t"].double)
            let W = try XCTUnwrap(c["width"].double), H = try XCTUnwrap(c["height"].double)
            for s in c["samples"].array {
                let got = E.effectPixel(e, t: t, width: W, height: H, u: s["u"].double!, v: s["v"].double!, sample: sample)
                let want = s["rgb"].array.compactMap(\.double)
                for k in 0..<3 { XCTAssertEqual(got[k], want[k], accuracy: 2e-6, "\(e.id) \(W)x\(H) a=\(e.amount) t=\(t) at \(s["u"].double!),\(s["v"].double!)") }
            }
        }
    }
}

extension EditV2DerivedTests {
    func testDissolveAndEffectOnTheSelection() throws {
        let f = try editorFixture("functions")["overlayFades"]
        var p = try f["project"].decode(E.Project.self)
        // Undo the fixture's dissolves so the second item just touches the first.
        guard let ti = p.tracks.firstIndex(where: { $0.kind == .image }) else { return XCTFail("image track") }
        if case .image(var im) = p.tracks[ti].items[1] {
            let prevEnd = E.itemSpan(p, p.tracks[ti], p.tracks[ti].items[0]).endSec
            im.transitionIn = nil; im.startSec = prevEnd; p.tracks[ti].items[1] = .image(im)
        }
        var s = EditSuiteState(p)
        s.selection = p.tracks[ti].items[1].id
        XCTAssertTrue(s.canDissolve)
        XCTAssertTrue(s.setOverlayDissolve(0.5))
        XCTAssertEqual(s.selectedDissolve?.kind, .fade)
        XCTAssertNil(E.problem(s.project))
        XCTAssertTrue(s.setOverlayDissolve(nil))
        XCTAssertNil(s.selectedDissolve)
        XCTAssertNil(E.problem(s.project))
        XCTAssertTrue(s.setEffect(E.Effect(id: "duotone", amount: 0.6, colors: ["#000000", "#FFFFFF"])))
        XCTAssertEqual(s.selectedEffect?.id, "duotone")
        XCTAssertNil(E.problem(s.project))
        XCTAssertTrue(s.setEffect(nil))
        XCTAssertNil(s.selectedEffect)
    }
}
