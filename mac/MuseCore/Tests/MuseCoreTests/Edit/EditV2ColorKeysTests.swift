import XCTest
@testable import MuseCore

/// Colour keyframes (contract, WS8 c10e398): adjustAt and the colour matrix at item-local t give the reference's answers
/// (functions.json → colorKeys).
final class EditV2ColorKeysTests: XCTestCase {
    typealias E = EditV2

    func testAdjustAtAndMatrix() throws {
        let cases = try editorFixture("functions")["colorKeys"].array
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let item = c["item"]
            let adjust = item["adjust"].isNull ? nil : try item["adjust"].decode(E.Adjust.self)
            let filter = item["filter"].isNull ? nil : try item["filter"].decode(E.FilterRef.self)
            let keys = try item["keyframes"].decode(E.Keyframes.self)
            XCTAssertTrue(E.hasColorKeys(keys))
            for s in c["samples"].array {
                let t = s["t"].double!
                let got = E.adjustAt(adjust, keys, t)
                if s["adjust"].isNull {
                    XCTAssertNil(got, "t \(t)")
                } else {
                    let want = try s["adjust"].decode(E.Adjust.self)
                    XCTAssertEqual(got, want, "t \(t)")
                }
                let m = E.colorMatrix(got, filter)
                let wm = s["matrix"].array.compactMap(\.double)
                XCTAssertEqual(m.count, wm.count)
                for (g, e) in zip(m, wm) { XCTAssertEqual(g, e, accuracy: 1e-5, "matrix at t \(t)") }
            }
        }
    }

    /// Mask and look keyframes (WS8 bfa44a6, 9cf11a4): maskAt and lookAt at item-local t (functions.json → motionKeys).
    func testMaskAndLookKeys() throws {
        let cases = try editorFixture("functions")["motionKeys"].array
        XCTAssertEqual(cases.count, 4)
        for (i, c) in cases.enumerated() {
            let item = c["item"]
            let mask = item["mask"].isNull ? nil : try item["mask"].decode(E.Mask.self)
            let look = item["look"].isNull ? nil : try item["look"].decode(E.Look.self)
            let keys = try item["keyframes"].decode(E.Keyframes.self)
            for s in c["samples"].array {
                let t = s["t"].double!
                let gm = try JV.of(E.maskAt(mask, keys, t)), gl = try JV.of(E.lookAt(look, keys, t))
                let dm = jsonDiff(gm, s["mask"]), dl = jsonDiff(gl, s["look"])
                XCTAssert(dm.isEmpty, "item \(i) maskAt \(t): " + dm.prefix(4).joined(separator: "; "))
                XCTAssert(dl.isEmpty, "item \(i) lookAt \(t): " + dl.prefix(4).joined(separator: "; "))
            }
        }
    }

    /// Loop animations (WS8 57fe40c): loopState at item-local t (functions.json → loops).
    func testLoopStates() throws {
        let cases = try editorFixture("functions")["loops"].array
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let loop = try c["loop"].decode(E.AnimLoop.self)
            for s in c["samples"].array {
                let t = s["t"].double!, got = E.loopState(loop, t), w = s["state"]
                XCTAssertEqual(got.scale, w["scale"].double!, accuracy: 1e-6, "\(loop.kind) \(t)")
                XCTAssertEqual(got.rotation, w["rotation"].double!, accuracy: 1e-6, "\(loop.kind) \(t)")
                XCTAssertEqual(got.dy, w["dy"].double!, accuracy: 1e-6, "\(loop.kind) \(t)")
                XCTAssertEqual(got.opacity, w["opacity"].double!, accuracy: 1e-6, "\(loop.kind) \(t)")
            }
        }
    }

    func testLoopOnOverlaysOnly() {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        s.selection = s.project.mainClips[0].id
        XCTAssertFalse(s.setLoop(E.AnimLoop(kind: .pulse, periodSec: 1)), "not on a main clip")
        let take2 = E.Asset(id: "t2", kind: .video, take: "tk2", durationSec: 4, width: 1080, height: 1920, hasAudio: true)
        s.playhead = 1
        XCTAssertTrue(s.addVideo(take2, overlay: true))
        XCTAssertTrue(s.setLoop(E.AnimLoop(kind: .float, periodSec: 9, amount: 0.5)))
        XCTAssertEqual(s.selectedLoop, E.AnimLoop(kind: .float, periodSec: 5), "period clamped, default amount left out")
        XCTAssertNil(E.problem(s.project))
        let p0 = E.placement(s.selectedVideo!, local: 1.25)
        var still = s.selectedVideo!; still.animLoop = nil
        XCTAssertEqual(p0.y - E.placement(still, local: 1.25).y, -0.03 * 0.5 * sin(2 * Double.pi * 1.25 / 5), accuracy: 1e-6, "float moves it up")
        XCTAssertTrue(s.moveToMain())
        XCTAssertNil(s.project.mainClips.first { $0.asset == "t2" }?.animLoop, "the main track drops the loop")
        XCTAssertNil(E.problem(s.project))
    }

    /// Audio speed (WS8 dacb556): length, beats on the timeline and source times (functions.json → audioSpeed).
    func testAudioSpeedFixtures() throws {
        let cases = try editorFixture("functions")["audioSpeed"].array
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let clip = try c["clip"].decode(E.AudioClip.self)
            XCTAssertEqual(E.clipLength(clip), c["length"].double!, accuracy: 1e-6)
            let beats = (clip.beats ?? []).map { E.r6(clip.startSec + ($0 - clip.inSec) / (clip.speed ?? 1)) }
            let want = c["beatsOnTimeline"].array.compactMap(\.double)
            XCTAssertEqual(beats.count, want.count)
            for (g, w) in zip(beats, want) { XCTAssertEqual(g, w, accuracy: 1e-6) }
            for s in c["sourceAt"].array {
                XCTAssertEqual(clip.inSec + s["t"].double! * (clip.speed ?? 1), s["src"].double!, accuracy: 1e-6, "t \(s["t"])")
            }
        }
    }

    func testAudioSpeedOnASound() {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        let song = E.Asset(id: "a1", kind: .audio, upload: "u1", durationSec: 6, hasAudio: true)
        XCTAssertTrue(s.addAudio(song, kind: .music))
        XCTAssertTrue(s.setAudioSpeed(1.5))
        let c = s.project.tracks.first { $0.kind == .music }!.items[0].audioClip!
        XCTAssertEqual(c.speed, 1.5)
        XCTAssertEqual(E.clipLength(c), (c.outSec - c.inSec) / 1.5, accuracy: 1e-9)
        XCTAssertNil(E.problem(s.project))
        XCTAssertTrue(s.setAudioSpeed(9))
        XCTAssertEqual(s.selectedAudioSpeed, 2, "clamped to 2×")
        XCTAssertTrue(s.setAudioSpeed(1))
        XCTAssertNil(s.project.tracks.first { $0.kind == .music }!.items[0].audioClip!.speed)
    }

    /// Adjustment layers (WS8 3e20288): adjustLayerMatrix at 8 timeline times (functions.json → adjustLayers).
    func testAdjustLayerMatrix() throws {
        let f = try editorFixture("functions")["adjustLayers"]
        let p = try f["project"].decode(E.Project.self)
        XCTAssertNil(E.problem(p))
        let samples = f["samples"].array
        XCTAssertEqual(samples.count, 8)
        for s in samples {
            let t = s["t"].double!
            let got = E.adjustLayerMatrix(p, t)
            if s["matrix"].isNull { XCTAssertNil(got, "t \(t)"); continue }
            let want = s["matrix"].array.compactMap(\.double)
            let g = try XCTUnwrap(got, "t \(t)")
            for (a, b) in zip(g, want) { XCTAssertEqual(a, b, accuracy: 1e-6, "t \(t)") }
        }
    }

    func testAddAndEditAnAdjustmentLayer() throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        s.playhead = 2
        XCTAssertTrue(s.addAdjustLayer())
        let a = try XCTUnwrap(s.selectedAdjust)
        XCTAssertEqual(a.startSec, 2); XCTAssertEqual(a.durationSec, 3)
        XCTAssertNil(E.adjustLayerMatrix(s.project, 3), "an empty layer changes nothing")
        XCTAssertTrue(s.setVisualValue(.exposure, 0.5))
        XCTAssertTrue(s.setVisualValue(.opacity, 0.5))
        XCTAssertTrue(s.setLayerFilter(E.filters[0].id, amount: 0.8))
        XCTAssertNotNil(E.adjustLayerMatrix(s.project, 3))
        XCTAssertNil(E.adjustLayerMatrix(s.project, 6), "outside its span")
        s.playhead = 2.5
        XCTAssertTrue(s.addKeyframe(.opacity, value: 0))
        XCTAssertNil(E.problem(s.project))
        // Another at the same time goes on a second adjustment track.
        s.playhead = 3
        XCTAssertTrue(s.addAdjustLayer())
        XCTAssertEqual(s.project.tracks.filter { $0.kind == .adjust }.count, 2)
        XCTAssertNil(E.problem(s.project))
    }

    /// Own fonts: the name table (full name, else family + style; Windows over Mac), and refusing what isn't sfnt.
    func testFontName() {
        func sfnt(_ names: [(platform: Int, id: Int, text: String)]) -> Data {
            var strings = [UInt8](), records = [UInt8]()
            func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            for n in names {
                let bytes: [UInt8] = n.platform == 3 ? n.text.utf16.flatMap { be16(Int($0)) } : Array(n.text.utf8)
                records += be16(n.platform) + be16(n.platform == 3 ? 1 : 0) + be16(n.platform == 3 ? 0x409 : 0) + be16(n.id) + be16(bytes.count) + be16(strings.count)
                strings += bytes
            }
            let table = be16(0) + be16(names.count) + be16(6 + records.count) + records + strings
            let header = be32(0x0001_0000) + be16(1) + be16(16) + be16(0) + be16(0)
            let dir = Array("name".utf8) + be32(0) + be32(12 + 16) + be32(table.count)
            return Data(header + dir + table)
        }
        XCTAssertEqual(E.fontName(sfnt([(3, 1, "Figtree"), (3, 2, "Bold")])), "Figtree Bold")
        XCTAssertEqual(E.fontName(sfnt([(1, 4, "Mac Full"), (3, 4, "Win Full")])), "Win Full")
        XCTAssertEqual(E.fontName(sfnt([])), "Font")
        XCTAssertNil(E.fontName(Data("wOFF0000000000000".utf8)), "WOFF is refused")
        XCTAssertNil(E.fontName(Data([0, 1])))
    }

    func testOwnFontOnText() throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        XCTAssertTrue(s.addText("Hello"))
        let font = E.Asset(id: "fnt1", kind: .font, upload: "up1", name: "Figtree Bold")
        XCTAssertTrue(s.setTextFont(font))
        XCTAssertEqual(s.selectedItem?.textItem?.style.fontAsset, "fnt1")
        XCTAssertEqual(s.ownFonts.map(\.id), ["fnt1"])
        XCTAssertNil(E.problem(s.project))
        XCTAssertTrue(s.setTextFont(nil))
        XCTAssertNil(s.selectedItem?.textItem?.style.fontAsset)
    }

    func testHslSetter() {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.setHsl("blue", "sat", 0.4))
        XCTAssertTrue(s.setHsl("red", "hue", -2))
        XCTAssertEqual(s.hslValue("red", "hue"), -1, "clamped")
        XCTAssertNil(E.problem(s.project))
        XCTAssertFalse(s.setHsl("cyan", "sat", 0.2), "not a band")
        XCTAssertTrue(s.setHsl("blue", "sat", 0))
        XCTAssertNil(s.project.mainClips[0].look?.hsl?["blue"])
        XCTAssertTrue(s.resetHsl())
        XCTAssertNil(s.project.mainClips[0].look)
    }

    /// Reverse (WS8 cb5413e): reverseClip and back is the identity; a freeze has nothing to reverse (functions.json → reverse).
    func testReverseFixtures() throws {
        let cases = try editorFixture("functions")["reverse"].array
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let clip = try c["clip"].decode(E.VideoClip.self), d = c["durationSec"].double!
            if c["reversed"].isNull { XCTAssertNil(E.reverseClip(clip, reversed: "x", durationSec: d), clip.id); continue }
            let want = try c["reversed"].decode(E.VideoClip.self)
            let got = try XCTUnwrap(E.reverseClip(clip, reversed: want.asset, durationSec: d))
            let d1 = jsonDiff(try JV.of(got), c["reversed"]); XCTAssert(d1.isEmpty, "\(clip.id): " + d1.prefix(4).joined(separator: "; "))
            let back = try XCTUnwrap(E.reverseClip(got, reversed: clip.asset, durationSec: d))
            let d2 = jsonDiff(try JV.of(back), c["back"]); XCTAssert(d2.isEmpty, "\(clip.id) back: " + d2.prefix(4).joined(separator: "; "))
        }
    }

    func testReverseTheSelectedClip() throws {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        let id = s.project.mainClips[0].id
        s.selection = id
        s.beginGesture(); s.updateGesture(s.trimming(id, .end, to: 4)); s.endGesture()
        let orig = s.project.mainClips[0].asset
        var rev = E.Asset(id: "src_rev", kind: .video, upload: "u_rev", durationSec: 10, width: 1080, height: 1920, hasAudio: true)
        rev.reverseOf = orig
        XCTAssertEqual(s.reverseSelected(to: rev), [])
        XCTAssertEqual(s.project.mainClips[0].asset, "src_rev")
        XCTAssertEqual(s.project.mainClips[0].inSec, 6, accuracy: 1e-9)
        XCTAssertEqual(s.reversedFrom, orig)
        XCTAssertNil(E.problem(s.project))
        let back = try XCTUnwrap(s.project.asset(orig))
        XCTAssertEqual(s.reverseSelected(to: back), [])
        XCTAssertEqual(s.project.mainClips[0].asset, orig)
        XCTAssertEqual(s.project.mainClips[0].inSec, 0, accuracy: 1e-9)
        XCTAssertNotNil(s.reversedCopy(of: orig), "the copy stays for next time")
    }

    /// Auto adjust: the reference's numbers on its four synthetic frames (functions.json → autoAdjust, WS8 03928ae).
    func testAutoAdjustFixtures() throws {
        let cases = try editorFixture("functions")["autoAdjust"].array
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let base = c["base"].isNull ? nil : try c["base"].decode(E.Adjust.self)
            let got = E.autoAdjust(c["rgb"].array.compactMap(\.double), base: base)
            XCTAssertEqual(got, try c["out"].decode(E.Adjust.self), c["name"].string ?? "")
        }
    }

    func testColorKeysOnTheSelectedClip() {
        var s = EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.setVisualValue(.exposure, 0.4))
        XCTAssertEqual(s.project.mainClips[0].adjust?.exposure, 0.4, "unkeyed: the static value")
        s.playhead = 1; XCTAssertTrue(s.addKeyframe(.exposure, value: -0.5))
        s.playhead = 3; XCTAssertTrue(s.addKeyframe(.exposure, value: 0.5))
        s.playhead = 2
        XCTAssertEqual(s.visualValue(.exposure) ?? 9, 0, accuracy: 1e-6, "half-way between the keys")
        XCTAssertTrue(s.setVisualValue(.exposure, 0.2), "keyed: sets a key at the playhead")
        XCTAssertEqual(s.project.mainClips[0].keyframes?.exposure?.count, 3)
        XCTAssertNil(E.problem(s.project))
        XCTAssertFalse(s.setVisualValue(.volume, 1))
    }
}

/// The owner's model pick on Edit helpers (WS13 engineModel): the purpose each helper runs, and the field on the wire.
final class EditorHelperModelTests: XCTestCase {
    func testPurposesAndEncoding() throws {
        XCTAssertEqual(EditorJobKind.captions.enginePurpose(nil), .captions)
        XCTAssertEqual(EditorJobKind.cuts.enginePurpose(nil), .captions)
        XCTAssertEqual(EditorJobKind.matte.enginePurpose(nil), .matte)
        XCTAssertEqual(EditorJobKind.matte.enginePurpose(EditorJobOptions(points: [])), .track)
        XCTAssertEqual(EditorJobKind.denoise.enginePurpose(nil), .denoise)
        XCTAssertNil(EditorJobKind.beats.enginePurpose(nil))
        let src = EditorSource(takeId: "tk", durationSec: 3)
        let plain = String(decoding: try JSONEncoder().encode(EditorJobRequest(kind: .denoise, source: src)), as: UTF8.self)
        XCTAssertFalse(plain.contains("engineModel"), "no pick: the studio's default, field left out")
        let picked = String(decoding: try JSONEncoder().encode(EditorJobRequest(kind: .denoise, source: src, engineModel: "m1")), as: UTF8.self)
        XCTAssertTrue(picked.contains("\"engineModel\":\"m1\""))
    }
}
