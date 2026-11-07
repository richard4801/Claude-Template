import XCTest
@testable import MuseCore

/// Owner blocker 2026-11-07: the Edit suite crashed on open with real takes. Every path the editor draws or plays must
/// survive degenerate media: a 0 / NaN / infinite / missing duration, a zero-size video, inverted or zero-length trims,
/// zero speed. A Swift trap (Int(inf), a reversed range, an out-of-range index) would crash this test process.
final class EditSuiteRobustnessTests: XCTestCase {
    typealias E = EditV2
    static let durations: [Double?] = [nil, 0, -1, .nan, .infinity, 1e-9, 0.04, 15]
    static let trims: [(Double, Double)] = [(0, 8), (0, 0), (5, 2), (0, .nan), (.nan, .nan), (0, .infinity), (-3, 4), (14, 15)]
    static let speeds: [Double] = [1, 0, -1, .nan, 100]

    func project(dur: Double?, trim: (Double, Double), speed: Double, w: Int, h: Int) -> E.Project {
        let a = E.Asset(id: "src", kind: .video, take: "t1", durationSec: dur, width: w, height: h, hasAudio: true)
        let c = E.VideoClip(id: "c1", asset: "src", inSec: trim.0, outSec: trim.1, speed: speed)
        return E.Project(sourceTakeId: "t1", canvas: E.Canvas(width: w, height: h, fps: 30), assets: [a], tracks: [E.Track(id: "main", kind: .main, items: [.video(c)])])
    }

    func exercise(_ p: E.Project, media: Double) {
        var s = EditSuiteState(p)
        _ = s.duration
        _ = EditSuite.clock(s.duration); _ = EditSuite.clockTenths(s.duration)
        _ = EditSuite.clock(s.playhead); _ = EditSuite.clockTenths(.nan)
        for r in s.rows { _ = s.blocks(r.trackId) }
        _ = s.beats; _ = s.bpm; _ = s.transcript(); _ = s.silenceCuts(); _ = s.fillerCuts
        _ = s.snapped(.nan); _ = s.snapped(.infinity); _ = s.snapped(3)
        _ = EditList.clock(.infinity); _ = EditList.clock(.nan); _ = EditList.clock(s.duration)
        s.select(at: 1)
        _ = s.trimming("c1", .start, to: 2); _ = s.trimming("c1", .end, to: .nan)
        _ = s.moving("c1", to: 1)
        _ = s.export.summary(durationSec: s.duration); _ = s.export.sizeLabel(durationSec: s.duration)
        _ = s.export.sizeLabel(durationSec: .infinity)
        _ = E.timeline(p)
        let plan = E.renderPlan(p, media: ["src": E.MediaInfo(durationSec: media, hasVideo: true, hasAudio: true, width: p.canvas.width, height: p.canvas.height)])
        for t in [0, 0.5, 1, 7.9, plan.durationSec, .nan] { _ = E.mainFrame(p, plan: plan, at: t) }
        _ = E.problem(p)
        _ = s.split(); _ = s.addText(); _ = s.setSpeed(2); _ = s.undo()
        for i in 0..<5 { _ = EditSuite.frameIndex(source: Double(i) * 3, durationSec: p.assets.first?.durationSec, fallbackSec: p.mainClips.first?.outSec ?? 0, count: 12) }
    }

    func testEditorSurvivesDegenerateMedia() {
        for d in Self.durations {
            for tr in Self.trims {
                for sp in Self.speeds {
                    for (w, h) in [(1080, 1920), (0, 0)] {
                        exercise(project(dur: d, trim: tr, speed: sp, w: w, h: h), media: d ?? 0)
                    }
                }
            }
        }
    }

    func testFromV1WithMissingFacts() {
        for d in [0.0, .nan, 15] {
            let p = E.fromV1(EditList(sourceTakeId: "t1", sourceDurationSec: d), E.SourceFacts(width: 0, height: 0, fps: 0, hasAudio: nil))
            exercise(p, media: d)
        }
    }

    func testFrameIndexIsAlwaysInRange() {
        let bad: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for src in bad + [0.5, 3, 100] {
            for dur in bad.map(Optional.some) + [nil, 0.1, 15] {
                for n in [0, 1, 12] {
                    let i = EditSuite.frameIndex(source: src, durationSec: dur, fallbackSec: .nan, count: n)
                    XCTAssert(n == 0 ? i == nil : (i! >= 0 && i! < n), "src \(src) dur \(String(describing: dur)) n \(n) → \(String(describing: i))")
                }
            }
        }
        XCTAssertEqual(EditSuite.frameIndex(source: 7.5, durationSec: 15, fallbackSec: 8, count: 10), 5)
        XCTAssertEqual(EditSuite.tileCount(width: .nan, tileWidth: 16), 1)
        XCTAssertEqual(EditSuite.tileCount(width: .infinity, tileWidth: 16), 1)
        XCTAssertEqual(EditSuite.tileCount(width: 1e12, tileWidth: 16), EditSuite.maxTiles)
        XCTAssertEqual(EditSuite.tileCount(width: 100, tileWidth: 16), 7)
    }
}

/// Every bundled look (the 32 pack looks and the palette LUTs the suite grades takes with) parses and renders, so a take
/// that opens with its suite look on the main clip can't trap in the look pipeline.
final class EditSuiteBundledLooksTests: XCTestCase {
    func testEveryBundledCubeParsesAndRenders() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dirs = ["server/api/assets/lookpack/looks", "server/api/assets/lookpack/palettes"].map { repo.appendingPathComponent($0) }
        var n = 0
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "cube" {
                let lut = try EditV2.parseCube(String(decoding: try Data(contentsOf: f), as: UTF8.self))
                XCTAssertEqual(lut.data.count, lut.size * lut.size * lut.size * 3, f.lastPathComponent)
                let img = EditV2.LookImage(width: 4, height: 3, data: [Float](repeating: 0.5, count: 36))
                for v in [0.0, 0.5, 1.0, -1, 2, .nan] { _ = EditV2.lutSample(lut, v, v, v) }
                _ = EditV2.renderLook(img, EditV2.Look(lut: "x", strength: 1, grain: .init(amount: 0.3)), matrix: nil, lut: lut, frame: 3, fps: 30)
                n += 1
            }
        }
        XCTAssertGreaterThan(n, 32)
    }
}

/// The waveform's down-mix and slicing (owner crash 2026-11-07: the reader now decodes at the file's own rate and channels).
final class EditSuitePeaksTests: XCTestCase {
    func testStereoAndMonoAtAnyRate() {
        // 1 s of 48 kHz stereo: silent left, a loud right channel in the second half.
        var st = [Int16](repeating: 0, count: 48_000 * 2)
        for f in 24_000..<48_000 { st[f * 2 + 1] = 16_000 }
        var p = EditSuite.Peaks()
        p.add(interleaved: st, channels: 2)
        let s = p.slices(10)
        XCTAssertEqual(s.count, 10)
        XCTAssertEqual(Array(s[0..<5]), [0, 0, 0, 0, 0])
        XCTAssertEqual(Array(s[5...]), [1, 1, 1, 1, 1])
        // 44.1 kHz mono, fed in odd-sized chunks.
        var m = EditSuite.Peaks()
        let mono = (0..<44_100).map { Int16(clamping: $0 % 2 == 0 ? $0 / 4 : -$0 / 4) }
        var i = 0
        while i < mono.count { let j = min(mono.count, i + 1_003); m.add(interleaved: Array(mono[i..<j]), channels: 1); i = j }
        let ms = m.slices(400)
        XCTAssertEqual(ms.count, 400)
        XCTAssertEqual(ms.last, 1)
        XCTAssertLessThan(ms.first!, 0.05)
    }

    func testEdges() {
        XCTAssertEqual(EditSuite.Peaks().slices(400), [])
        var p = EditSuite.Peaks()
        p.add(interleaved: [5, 6, 7], channels: 2)   // a partial frame is ignored
        XCTAssertEqual(p.slices(0), [])
        XCTAssertEqual(p.slices(400).count, 1)        // never more slices than blocks
        p.add(interleaved: [Int16.min, 0], channels: 0)
        XCTAssertEqual(p.slices(3).count, 1)
        var q = EditSuite.Peaks(block: 1)
        q.add(interleaved: [Int16](repeating: 100, count: 10), channels: 1)
        XCTAssertEqual(q.slices(4).count, 4)
        XCTAssertLessThan(q.slices(4)[0], 1)          // quiet stays quiet (0.05 floor)
    }
}
