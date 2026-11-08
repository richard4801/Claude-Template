import XCTest
@testable import MuseCore

/// Editor v2 against the shared fixtures (Fixtures/editor, written by server/api/scripts/editor-fixtures.ts from the
/// TypeScript reference): every expected answer to 1e-6, the validation cases' first problem, and a JSON round trip of
/// every project.
final class EditV2FixtureTests: XCTestCase {
    typealias E = EditV2

    private func projects() throws -> [(name: String, raw: JV, project: E.Project, expect: JV)] {
        try editorFixture("projects").array.map { c in
            (c["name"].string ?? "?", c["project"], try c["project"].decode(E.Project.self), c["expect"])
        }
    }

    func testProjectsHaveTheReferenceAnswers() throws {
        let all = try projects()
        XCTAssertEqual(all.count, 11, "ten projects + wave 1")
        for (name, _, p, ex) in all {
            XCTAssertEqual(E.durationSec(p), try XCTUnwrap(ex["durationSec"].double), accuracy: 1e-6, name)
            assertJSON(E.timeline(p), ex["timeline"], "\(name) timeline")
            assertJSON(E.captionWords(p), ex["captionWords"], "\(name) captionWords")
            let pages = E.captionPages(p).map { pg in JV.obj(["startSec": .num(pg.startSec), "endSec": .num(pg.endSec), "words": .arr(pg.words.map { .num(Double($0.index)) })]) }
            assertJSON(pages, ex["captionPages"], "\(name) captionPages")
            let samples = ex["captionAt"].array
            XCTAssertFalse(samples.isEmpty, name)
            for s in samples {
                let t = try XCTUnwrap(s["t"].double)
                assertJSON(E.captionAt(p, t), s["at"], "\(name) captionAt \(t)")
            }
            let envs = ex["envelopes"].object
            XCTAssertFalse(envs.isEmpty, name)
            for (key, want) in envs {
                let parts = key.split(separator: "/").map(String.init)
                assertJSON(E.audioEnvelope(p, trackId: parts[0], itemId: parts[1]), want, "\(name) envelope \(key)")
            }
            for (id, want) in ex["colorMatrices"].object {
                let item = try XCTUnwrap(p.tracks.lazy.compactMap { $0.item(id) }.first, "\(name) \(id)")
                let m: [Double]
                switch item {
                case .video(let c): m = E.colorMatrix(c.adjust, c.filter, presets: E.filters)
                case .image(let c): m = E.colorMatrix(c.adjust, c.filter, presets: E.filters)
                default: XCTFail("\(name) \(id) has no look"); continue
                }
                assertJSON(m, want, "\(name) colorMatrix \(id)")
            }
            assertJSON(E.toV1(p), ex["toV1"], "\(name) toV1")
            // Edit suite: speed-curve pieces and the .srt.
            var pieces: [String: [E.Piece]] = [:]
            for c in p.mainClips where c.speedCurve != nil { pieces[c.id] = E.speedPieces(c) }
            assertJSON(pieces, ex["pieces"], "\(name) pieces")
            XCTAssertEqual(E.toSrt(p), ex["srt"].string, "\(name) srt")
        }
    }

    func testProjectsRoundTripThroughJSON() throws {
        for (name, raw, p, _) in try projects() {
            let again = try JV.of(p)
            let d = jsonStrictDiff(again, raw)
            XCTAssert(d.isEmpty, "\(name): " + d.prefix(5).joined(separator: "; "))
            XCTAssertEqual(try E.Project.decode(p.encoded()), p, name)
        }
    }

    func testValidationCases() throws {
        let cases = try editorFixture("validation").array
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let name = c["name"].string ?? "?"
            // A wrong type (an unknown blend mode, a flip that isn't a boolean) already fails decoding here (EditV2Validate.swift).
            guard let p = try? c["project"].decode(E.Project.self) else {
                XCTAssertNotEqual(c["ok"], .bool(true), "\(name): a valid project didn't decode")
                continue
            }
            let problem = E.problem(p, presets: E.filters)
            if c["ok"] == .bool(true) {
                XCTAssertNil(problem, "\(name): \(problem?.description ?? "")")
            } else {
                XCTAssertEqual(problem?.field, c["field"].string, "\(name): \(problem?.description ?? "no problem")")
            }
        }
    }

    func testKeyframes() throws {
        let f = try editorFixture("functions")
        for c in f["keyframes"].array {
            let keys = try c["keys"].decode([E.Keyframe].self)
            for s in c["samples"].array {
                let t = try XCTUnwrap(s["t"].double)
                XCTAssertEqual(E.keyframeValue(keys, t), try XCTUnwrap(s["v"].double), accuracy: 1e-6, "t=\(t)")
            }
        }
    }

    func testTransitions() throws {
        let cases = try editorFixture("functions")["transitions"].array
        XCTAssertEqual(cases.count, 11 * 7)
        for c in cases {
            let kind = try c["kind"].decode(E.TransitionKind.self), p = try XCTUnwrap(c["p"].double)
            assertJSON(E.transitionState(kind, p), c["state"], "\(kind) \(p)")
        }
    }

    func testAnims() throws {
        struct AnimItem: Decodable { var durationSec: Double; var text: String?; var animIn: E.Anim?; var animOut: E.Anim? }
        for c in try editorFixture("functions")["anims"].array {
            let it = try c["item"].decode(AnimItem.self)
            for s in c["samples"].array {
                let t = try XCTUnwrap(s["t"].double)
                assertJSON(E.animState(durationSec: it.durationSec, animIn: it.animIn, animOut: it.animOut, text: it.text, t), s["state"], "anim t=\(t)")
            }
        }
    }

    func testColors() throws {
        let cases = try editorFixture("functions")["colors"].array
        XCTAssertEqual(cases.count, 4 + E.filters.count)
        for c in cases {
            let adjust = try c["adjust"].decode(E.Adjust.self)
            let filter = c["filter"].isNull ? nil : try c["filter"].decode(E.FilterRef.self)
            assertJSON(E.colorMatrix(adjust, filter, presets: E.filters), c["matrix"], "color \(c["adjust"]) \(c["filter"])")
        }
    }

    func testChromaKey() throws {
        let cases = try editorFixture("functions")["chroma"].array
        XCTAssertEqual(cases.count, 30)
        for (i, c) in cases.enumerated() {
            let key = try c["key"].decode(E.Chroma.self)
            let rgb = c["rgb"].array.compactMap { $0.double }
            let want = c["out"].array.compactMap { $0.double }
            let got = E.chromaKey(rgb[0], rgb[1], rgb[2], key)
            for (j, v) in [got.r, got.g, got.b, got.alpha].enumerated() { XCTAssertEqual(v, want[j], accuracy: 1e-6, "chroma \(i)[\(j)]") }
        }
    }

    func testApplyCuts() throws {
        for (i, c) in try editorFixture("functions")["cuts"].array.enumerated() {
            let p = try c["project"].decode(E.Project.self)
            let cuts = try c["cuts"].decode([E.SecRange].self)
            let out = E.applyCuts(p, assetId: try XCTUnwrap(c["asset"].string), cuts: cuts)
            let d = jsonStrictDiff(try JV.of(out), c["result"], tol: 1e-6)
            XCTAssert(d.isEmpty, "cuts \(i): " + d.prefix(5).joined(separator: "; "))
        }
    }

    func testV1() throws {
        for (i, c) in try editorFixture("functions")["v1"].array.enumerated() {
            let v1 = try c["v1"].decode(E.EditListV1.self)
            let info = try c["info"].decode(E.SourceFacts.self)
            let p = E.fromV1(v1, info)
            let d = jsonStrictDiff(try JV.of(p), c["project"], tol: 1e-9)
            XCTAssert(d.isEmpty, "v1 \(i): " + d.prefix(5).joined(separator: "; "))
            assertJSON(E.toV1(p), c["back"], "v1 \(i) back")
            // From the editor's own v1 type too.
            XCTAssertEqual(E.fromV1(v1.editList, info), p, "v1 \(i) from EditList")
            XCTAssertEqual(E.toV1EditList(p), v1.editList, "v1 \(i) to EditList")
        }
    }

    func testSuggestCuts() throws {
        for (i, c) in try editorFixture("functions")["suggestCuts"].array.enumerated() {
            let words = try c["words"].decode([E.Word].self)
            let o = try c["options"].decode(E.CutOptions.self)
            let r = E.suggestCuts(words, durationSec: try XCTUnwrap(c["durationSec"].double), options: o)
            let d = jsonStrictDiff(try JV.of(r), c["result"], tol: 1e-6)
            XCTAssert(d.isEmpty, "suggestCuts \(i): " + d.prefix(5).joined(separator: "; "))
        }
    }

    func testPresetsEqualTheReferenceTables() throws {
        let f = try editorFixture("presets")
        for (key, mine, want) in [("filters", try JV.of(E.filters), f["filters"]), ("hooks", try JV.of(E.hooks), f["hooks"])] {
            let d = jsonStrictDiff(mine, want)
            XCTAssert(d.isEmpty, "\(key): " + d.prefix(5).joined(separator: "; "))
        }
        let styles = Dictionary(uniqueKeysWithValues: E.captionStyles.map { ($0.key.rawValue, $0.value) })
        let d = jsonStrictDiff(try JV.of(styles), f["captionStyles"])
        XCTAssert(d.isEmpty, "captionStyles: " + d.prefix(5).joined(separator: "; "))
        XCTAssertEqual(E.captionStyles.count, E.CaptionPreset.allCases.count)
        let labels = E.captionStyleLabels.map { JV.arr([.str($0.0.rawValue), .str($0.1)]) }
        XCTAssert(jsonStrictDiff(.arr(labels), f["captionStyleLabels"]).isEmpty, "captionStyleLabels")
        let tl = E.transitionLabels.map { JV.arr([.str($0.0), .str($0.1)]) }
        XCTAssert(jsonStrictDiff(.arr(tl), f["transitionLabels"]).isEmpty, "transitionLabels")
        for (k, _) in E.transitionLabels where k != "cut" { XCTAssertNotNil(E.TransitionKind(rawValue: k), k) }
    }

    // MARK: Edit suite additions

    func testMasks() throws {
        let cases = try editorFixture("functions")["masks"].array
        XCTAssertEqual(cases.count, 12)
        for c in cases {
            let m = try c["mask"].decode(E.Mask.self)
            for s in c["samples"].array {
                let v = s.array.compactMap(\.double)
                XCTAssertEqual(E.maskAlpha(m, v[0], v[1]), v[2], accuracy: 1e-6, "\(m.shape) \(v)")
            }
        }
    }

    func testTone() throws {
        for c in try editorFixture("functions")["tone"].array {
            let sh = try XCTUnwrap(c["shadows"].double), hi = try XCTUnwrap(c["highlights"].double)
            for s in c["samples"].array {
                let v = s.array.compactMap(\.double)
                XCTAssertEqual(E.toneAdjust(v[0], shadows: sh, highlights: hi), v[1], accuracy: 1e-6, "tone \(sh) \(hi) \(v[0])")
            }
        }
    }

    func testSpeedCurves() throws {
        let f = try editorFixture("functions")
        let cases = f["speedCurves"].array
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            var raw = c["clip"].object; raw["id"] = .str("c"); raw["asset"] = .str("a")
            let clip = try JV.obj(raw).decode(E.VideoClip.self)
            let curve = try XCTUnwrap(clip.speedCurve)
            XCTAssertEqual(E.clipLength(clip), try XCTUnwrap(c["length"].double), accuracy: 1e-6)
            for s in c["curve"].array {
                let v = s.array.compactMap(\.double)
                XCTAssertEqual(E.curveSpeed(curve, v[0]), v[1], accuracy: 1e-5, "curve x=\(v[0])")
            }
            for s in c["timeAt"].array {
                let v = s.array.compactMap(\.double)
                XCTAssertEqual(E.clipTimeAt(clip, v[0]), v[1], accuracy: 1e-6, "timeAt \(v[0])")
                XCTAssertEqual(E.clipSourceAt(clip, E.clipTimeAt(clip, v[0])), v[0], accuracy: 1e-6, "sourceAt inverse \(v[0])")
            }
            assertJSON(E.subCurve(curve, 0.25, 0.8), c["sub"], "subCurve")
        }
        let presets = f["speedPresets"].object
        XCTAssertEqual(presets.count, E.speedPresets.count)
        for (k, want) in presets {
            assertJSON(try XCTUnwrap(E.speedPresets[E.SpeedPreset(rawValue: k)]), want, "preset \(k)")
        }
    }

    func testVoiceChains() throws {
        let cases = try editorFixture("functions")["voice"].array
        XCTAssertEqual(cases.count, 20)
        for c in cases {
            let effect = try c["voiceEffect"].decode(E.VoiceEffect.self)
            let enhance = c["enhance"] == .bool(true)
            let sr = try XCTUnwrap(c["sampleRate"].double)
            let chain = E.voiceChain(effect: effect, enhance: enhance, sampleRate: sr)
            assertJSON(chain, c["chain"], "chain \(effect) \(enhance) \(sr)")
            let impulse = (0..<24).map { $0 == 0 ? 1.0 : 0 }
            let out = E.runChain(chain, impulse)
            let want = c["impulse"].array.compactMap(\.double)
            XCTAssertEqual(out.count, want.count)
            for (a, b) in zip(out, want) { XCTAssertEqual(a, b, accuracy: 1e-8, "impulse \(effect) \(enhance) \(sr)") }
        }
    }

    func testDuckTimes() throws {
        for c in try editorFixture("functions")["duckTimes"].array {
            let d = try c["duck"].decode(E.Duck.self)
            let want = c["times"].array.compactMap(\.double)
            let got = E.duckTimes(d)
            XCTAssertEqual(got.attack, want[0], accuracy: 1e-9)
            XCTAssertEqual(got.release, want[1], accuracy: 1e-9)
        }
    }

}
