import XCTest
@testable import MuseCore

/// Live suggestion chips (owner 2026-11-12): what the Mac tells the server about the open edit, the steady order, and the
/// demo copy of the server's Edit rules (server/api/src/claude/suggest.ts is the real one).
final class ClaudeSuggestTests: XCTestCase {
    typealias E = EditV2

    private func project(captions: Bool = false, music: Bool = false, beats: Bool = false, textAt: (Double, Double)? = nil) -> E.Project {
        let a = E.Asset(id: "src", kind: .video, take: "t1", durationSec: 8, width: 1080, height: 1920, hasAudio: true)
        var tracks = [E.Track(id: "main", kind: .main, items: [.video(E.VideoClip(id: "c1", asset: "src", inSec: 0, outSec: 8))])]
        if music { tracks.append(E.Track(id: "mu", kind: .music, items: [.audio(E.AudioClip(id: "mus_1", asset: "src", startSec: 0, inSec: 0, outSec: 8, strongBeats: beats ? [1, 2] : nil))])) }
        if let at = textAt {
            tracks.append(E.Track(id: "tx", kind: .text, items: [.text(E.TextItem(id: "txt_1", startSec: 0, durationSec: 2, text: "Hi",
                style: E.TextStyle(font: .sans, weight: 700, sizePct: 0.06, color: "#FFFFFF", align: .center), transform: E.Transform(x: at.0, y: at.1)))]))
        }
        if captions, let style = E.captionStyles[.plain] {
            tracks.append(E.Track(id: "cap", kind: .caption, items: [], caption: E.CaptionTrack(asset: "src", words: [E.CaptionWord(text: "hi", startSec: 0, endSec: 0.4)], style: style)))
        }
        return E.Project(sourceTakeId: "t1", canvas: E.Canvas(width: 1080, height: 1920, fps: 30), assets: [a], tracks: tracks)
    }

    private func facts(_ p: E.Project, selection: String? = nil, safe: EditPreview? = nil, unsaved: Bool = false) -> ClaudeSuggestQuery {
        var q = ClaudeSuggestQuery(page: ClaudePage(name: "edit", ids: ["sessionId": "es_1", "takeId": "t1"]), chatId: "ct_1")
        q.edit(project: p, selection: selection, preview: safe, unsaved: unsaved)
        return q
    }

    func testEditFactsAndQueryString() {
        let q = facts(project(music: true), selection: "c1", safe: EditPreview(view: .tiktok, safeArea: true), unsaved: true)
        XCTAssertEqual(q.clips, 1)
        XCTAssertEqual(q.captions, false)
        XCTAssertEqual(q.musicId, "mus_1")
        XCTAssertEqual(q.beats, false)
        XCTAssertEqual(q.selKind, "video")
        XCTAssertEqual(q.queryString,
                       "beats=0&blank=0&captions=0&chatId=ct_1&clips=1&musicId=mus_1&page=edit&selId=c1&selKind=video&sessionId=es_1&takeId=t1&unsaved=1&view=tiktok")
        XCTAssertEqual(facts(project(captions: true)).captions, true)
        XCTAssertEqual(facts(project(music: true), selection: "mus_1").selKind, "audio")
        XCTAssertNil(facts(project(), selection: "nope").selKind)
    }

    func testTextOutsideTheSafeArea() {
        XCTAssertEqual(facts(project(textAt: (0.5, 0.95)), safe: EditPreview(view: .tiktok, safeArea: true)).offSafe, ["txt_1"])
        XCTAssertEqual(facts(project(textAt: (0.5, 0.5)), safe: EditPreview(view: .tiktok, safeArea: true)).offSafe, [])
        XCTAssertEqual(facts(project(textAt: (0.5, 0.95)), safe: nil).offSafe, [])   // no platform view, nothing to fix
    }

    func testOnAnotherPageKeepsTheEditFacts() {
        let q = facts(project(captions: true)).on(ClaudePage(name: "edit", ids: ["sessionId": "es_2"]), chatId: nil)
        XCTAssertEqual(q.ids, ["sessionId": "es_2"])
        XCTAssertNil(q.chatId)
        XCTAssertEqual(q.captions, true)
    }

    func testSteadyKeepsChipsInTheirPlaces() {
        let c = { (l: String) in ClaudeChip(label: l, prompt: l, icon: "x") }
        let old = [c("A"), c("B"), c("C")]
        XCTAssertEqual(ClaudeChip.steady(old: old, new: [c("B"), c("D"), c("C")]).map(\.label), ["D", "B", "C"])
        XCTAssertEqual(ClaudeChip.steady(old: old, new: [c("C"), c("B"), c("A")]).map(\.label), ["A", "B", "C"])
        XCTAssertEqual(ClaudeChip.steady(old: [], new: [c("X"), c("Y")]).map(\.label), ["X", "Y"])
        XCTAssertEqual(ClaudeChip.steady(old: old, new: [c("Z")]).map(\.label), ["Z"])
    }

    func testDemoChipsDifferWithCaptions() {
        let without = ClaudeChip.demoSuggestions(facts(project(music: true))).map(\.label)
        let with = ClaudeChip.demoSuggestions(facts(project(captions: true, music: true, beats: true))).map(\.label)
        XCTAssertEqual(without, ["Add captions", "Cut to the beat", "Watch my edit"])
        XCTAssertEqual(with, ["Cut to the drop", "Restyle the captions", "Watch my edit"])
        XCTAssertNotEqual(without, with)
        // No music, no captions: the free silence cut instead of beats; captions on: no "Add captions", no beats.
        XCTAssertEqual(ClaudeChip.demoSuggestions(facts(project())).map(\.label), ["Add captions", "Cut the silences", "Watch my edit"])
        XCTAssertEqual(ClaudeChip.demoSuggestions(facts(project(captions: true))).map(\.label), ["Restyle the captions", "Watch my edit", "What can you do"])
        for l in without + with { XCTAssertLessThanOrEqual(l.split(separator: " ").count, 4, l) }
    }
}
