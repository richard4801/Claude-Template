import XCTest
@testable import MuseCore

/// Reuse settings: the composer's draft round-trips through `SuiteDraft` (and its JSON) exactly.
final class ComposerDraftsTests: XCTestCase {
    private func sampleTokens() -> PromptTokens {
        PromptTokens([.mention(kind: "character", id: "m_demo", label: "Demo", key: 1), .text(" walks out of the café "),
                      .move(id: "dolly_in", label: "Dolly in", category: "push", intensity: 70, key: 2)])
    }

    func testTokensRoundTripWithTheirKeys() {
        let t = sampleTokens()
        XCTAssertEqual(ComposerDrafts.decode(ComposerDrafts.encode(t)), t)
    }

    func testShotDraftRestoresTheComposer() throws {
        var d = ComposerDraft()
        d.tool = .shot
        d.tokens = sampleTokens()
        d.aspect = "16:9"
        d.duration = 10
        d.takes = 2
        d.sound = false
        d.speaking = .off
        d.settings.body = "film35"
        d.settings.lighting = "window"
        let draft = ComposerDrafts.draft(d)
        // Through JSON, as the server stores it.
        let back = try JSONDecoder().decode(SuiteDraft.self, from: JSONEncoder().encode(draft))
        let r = ComposerDrafts.restore(back, into: ComposerDraft())
        XCTAssertEqual(r.tool, .shot)
        XCTAssertEqual(r.tokens, d.tokens)
        XCTAssertEqual(r.aspect, "16:9")
        XCTAssertEqual(r.duration, 10)
        XCTAssertEqual(r.takes, 2)
        XCTAssertFalse(r.sound)
        XCTAssertEqual(r.speaking, .off)
        XCTAssertEqual(r.settings.body, "film35")
        XCTAssertEqual(r.settings.lighting, "window")
        XCTAssertNil(back.problem)
    }

    func testPhotoDraftKeepsCountAndPreset() {
        var d = ComposerDraft()
        d.tool = .photo
        var p = PhotoDraft()
        p.count = 3
        p.presetId = "tpl_window"
        let draft = ComposerDrafts.draft(d, photo: p)
        XCTAssertEqual(draft.tool, "photo")
        XCTAssertEqual(draft.count, 3)
        XCTAssertEqual(draft.extra["presetId"], .string("tpl_window"))
    }
}
