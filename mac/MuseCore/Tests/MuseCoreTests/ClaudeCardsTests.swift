import XCTest
@testable import MuseCore

// Claude panel cards (server/api/src/claude/cards.ts): the JSON the server sends decodes into the cards the panel draws,
// unknown cards are skipped (never an error), and the activity strip reads as the owner's reference.
final class ClaudeCardsTests: XCTestCase {
    private func card(_ json: String) throws -> ClaudeCard {
        try JSONDecoder().decode(ClaudeCardBox.self, from: Data(json.utf8)).card
    }

    func testPlanMediaChangesApproveDecode() throws {
        let plan = try card(#"{"kind":"plan","planId":"swap","title":"Plan: outfit swap","steps":[{"text":"Watch the clip","done":true},{"text":"Swap the outfit","done":false},{"text":"Render"}]}"#)
        XCTAssertEqual(plan.progress?.done, 1)
        XCTAssertEqual(plan.progress?.of, 3)

        let media = try card(#"{"kind":"media","title":"Clip analysis","summary":"Three moments","durationSec":15,"video":{"id":"tk_1","kind":"take","url":"/uploads/s/a.mp4"},"moments":[{"from":4,"to":10,"label":"Face toward camera"},{"from":11,"label":"Closing shot"}]}"#)
        guard case .media(_, let summary, let video, let dur, let moments) = media else { return XCTFail("media") }
        XCTAssertEqual(summary, "Three moments")
        XCTAssertEqual(video.url, "/uploads/s/a.mp4")
        XCTAssertEqual(dur, 15)
        XCTAssertEqual(moments.map(\.timecode), ["0:04–0:10", "0:11"])

        let changes = try card(#"{"kind":"changes","title":"What I changed","rows":[{"what":"Outfit","to":"Hoodie","undoable":true},{"what":"Background","to":"Describe it","undone":true}]}"#)
        guard case .changes(_, let rows) = changes else { return XCTFail("changes") }
        XCTAssertEqual(rows.map(\.undoable), [true, false])
        XCTAssertEqual(ClaudeCardText.change(rows[0]), "Outfit changed to Hoodie")

        let approve = try card(#"{"kind":"approve","title":"Generate · 15 s · $1.17","subtitle":"A new version","lines":[{"label":"Video, 15 s at $0.066/s","usd":0.99},{"label":"2 reference images past the 5 included","usd":0.18}],"totalUsd":1.17,"answer":{"assistId":"sa_1","pendingId":"sp_2"},"approveLabel":"Approve","declineLabel":"Decline"}"#)
        guard case .approve(let title, _, let lines, let total, let target, _, _) = approve else { return XCTFail("approve") }
        XCTAssertEqual(title, "Generate · 15 s · $1.17")
        XCTAssertEqual(ClaudeCardText.money(ClaudeCardText.total(lines, total)), "$1.17")
        XCTAssertEqual(ClaudeCardText.total(lines, nil), 1.17)
        XCTAssertEqual(target, .suite(assistId: "sa_1", pendingId: "sp_2"))
        let action = try card(#"{"kind":"approve","title":"Delete the take","answer":{"actionId":"ca_9"}}"#)
        guard case .approve(_, _, let none, _, .action("ca_9"), "Approve", "Decline") = action else { return XCTFail("action") }
        XCTAssertTrue(none.isEmpty)
    }

    func testUnknownOrBrokenCardsAreSkippedNotErrors() throws {
        XCTAssertEqual(try card(#"{"kind":"poll","options":[1,2]}"#), .unknown(kind: "poll"))
        XCTAssertEqual(try card(#"{"kind":"approve","title":"No answer"}"#), .unknown(kind: "approve"))
        // A tool line with a card still decodes as a whole, and keeps the raw JSON when encoded again.
        let ui = try JSONDecoder().decode(ClaudeUI.self, from: Data(#"{"card":{"kind":"plan","steps":[{"text":"A"}]},"approve":"ca_1"}"#.utf8))
        XCTAssertEqual(ui.card?.card.kind, "plan")
        XCTAssertEqual(ui.approve, "ca_1")
        let again = try JSONDecoder().decode(ClaudeUI.self, from: JSONEncoder().encode(ui))
        XCTAssertEqual(again, ui)
    }

    func testLiveCardEventAndUiCallStep() {
        let e = ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"card","threadId":"ct_1","messageId":"cm_2","card":{"kind":"plan","steps":[{"text":"A","done":true}]}}"#.utf8))
        guard case .card("ct_1", "cm_2", let box)? = e else { return XCTFail("card event") }
        XCTAssertEqual(box.card.progress?.done, 1)
        let c = ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"uiCall","call":{"id":"ui_1","kind":"act","args":{},"step":"Choosing Swap…"}}"#.utf8))
        guard case .uiCall(let call)? = c else { return XCTFail("uiCall") }
        XCTAssertEqual(call.step, "Choosing Swap…")
    }

    func testActivityStripReadsLikeTheReference() {
        var a = ClaudeActivity()
        XCTAssertFalse(a.isActive)
        a.began(UiCall(id: "1", kind: "act", step: "Opening Swap…"))
        a.began(UiCall(id: "2", kind: "act", step: "Setting outfit…"))
        XCTAssertEqual(a.line, "Opening Swap… setting outfit…")
        a.job(0.42)
        XCTAssertEqual(a.percent, "42%")
        a.ended("1"); a.ended("2")
        XCTAssertTrue(a.isActive) // the job still runs
        a.job(nil)
        XCTAssertFalse(a.isActive)
        XCTAssertEqual(a.line, "")
        a.began(UiCall(id: "3", kind: "snapshot"))
        XCTAssertEqual(a.line, "Working in the window…") // an older server: no step
        a.stop()
        XCTAssertFalse(a.isActive)
    }

    func testChipsFallbackFitsThePage() async throws {
        XCTAssertEqual(ClaudeChip.fallback(page: "suite", tool: "remix").map(\.label), ["Watch my clip", "Write the prompt", "Check the price"])
        XCTAssertEqual(ClaudeChip.fallback(page: "suite", tool: "shot").first?.label, "Write the prompt")
        XCTAssertEqual(ClaudeChip.fallback(page: nil, tool: nil).count, 3)
        XCTAssertEqual(ClaudeCardText.clock(3725), "1:02:05")
    }
}

final class ClaudeCardsTranscriptTests: XCTestCase {
    func testStoredCardLinesBecomeCardItemsInPlace() throws {
        func msg(_ id: String, _ json: String, at: Double) throws -> ClaudeMessage {
            try JSONDecoder().decode(ClaudeMessage.self, from: Data("""
            {"id":"\(id)","threadId":"ct","role":"tool","source":"api","text":"","tool":{"id":"ui_1","name":"card","ok":true,"summary":"Plan","ui":{"card":\(json)}},"createdAt":\(at)}
            """.utf8))
        }
        var tr = ClaudeTranscript(messages: [try msg("cm_1", #"{"kind":"plan","steps":[{"text":"A"},{"text":"B"}]}"#, at: 1)])
        guard case .card(_, "cm_1", let c)? = tr.items.first else { return XCTFail("card item") }
        XCTAssertEqual(c.progress?.done, 0)
        // The same line again (show_plan ticked a step): replaced in place, not added.
        tr.upsert(try msg("cm_1", #"{"kind":"plan","steps":[{"text":"A","done":true},{"text":"B"}]}"#, at: 1))
        XCTAssertEqual(tr.items.count, 1)
        guard case .card(_, _, let c2)? = tr.items.first else { return XCTFail("card item") }
        XCTAssertEqual(c2.progress?.done, 1)
        // An unknown card stays a plain tool chip.
        tr.upsert(try msg("cm_2", #"{"kind":"poll"}"#, at: 2).withToolId("ui_2"))
        guard case .tool? = tr.items.last else { return XCTFail("tool chip") }
    }
}

private extension ClaudeMessage {
    func withToolId(_ id: String) -> ClaudeMessage { var m = self; m.tool?.id = id; return m }
}

final class ClaudeOrbTests: XCTestCase {
    func testStatesFollowRealEventsWithErrorFirst() {
        var o = ClaudeOrb()
        XCTAssertEqual(o.state(at: 0), .idle)
        o.waiting(1)
        XCTAssertEqual(o.state(at: 0), .waiting)
        o.turnStarted()
        XCTAssertEqual(o.state(at: 1), .thinking)
        o.uiCallBegan("ui_1", at: 2)
        XCTAssertEqual(o.state(at: 2), .operating)
        o.uiCallEnded("ui_1", at: 3)
        XCTAssertEqual(o.state(at: 3), .thinking)
        o.turnEnded(ok: false, at: 4)
        XCTAssertEqual(o.state(at: 5), .error)
        XCTAssertEqual(o.state(at: 4 + ClaudeOrb.errorHold + 0.1), .waiting) // the error fades; the card still waits
        o.waiting(0)
        XCTAssertEqual(o.state(at: 20), .idle)
        o.turnEnded(ok: false, at: 21)
        o.turnStarted() // the person writes again: the error clears at once
        XCTAssertEqual(o.state(at: 22), .thinking)
        o.turnEnded(ok: true, at: 23)
        o.job(running: true, at: 23)
        XCTAssertEqual(o.state(at: 24), .thinking)
        o.job(running: false, failed: true, at: 25)
        XCTAssertEqual(o.state(at: 26), .error)
        o.uiCallBegan("ui_2", at: 27); o.stopped()
        XCTAssertEqual(o.state(at: 40), .idle)
    }

    func testPulsesFlashAndFadeEdgeFollowsOrb() {
        var o = ClaudeOrb()
        o.turnStarted()
        o.chunk(at: 10)
        XCTAssertEqual(o.pulses, 1)
        XCTAssertEqual(o.pulse(at: 10), 1)
        XCTAssertGreaterThan(o.pulse(at: 10.2), 0)
        XCTAssertEqual(o.pulse(at: 10 + ClaudeOrb.flashDecay), 0)
        XCTAssertGreaterThan(o.glow(at: 10), o.glow(at: 11))
        XCTAssertGreaterThan(o.edge(at: 10), o.edge(at: 11)) // the edge moves with the orb
        o.changeApplied(at: 12)
        XCTAssertEqual(o.pulses, 2)
    }

    func testReduceMotionTypingAndFrameRate() {
        var o = ClaudeOrb()
        o.turnStarted(); o.chunk(at: 1)
        let still = o.look(at: 1, reduceMotion: true)
        XCTAssertEqual(still.swirl, 0); XCTAssertEqual(still.breath, 0); XCTAssertFalse(still.flashes)
        XCTAssertEqual(o.pulse(at: 1, reduceMotion: true), 0)
        XCTAssertFalse(o.animates(at: 1, reduceMotion: true))
        XCTAssertEqual(o.frameRate(at: 1, reduceMotion: true), 0)
        XCTAssertEqual(o.frameRate(at: 1), 30)
        o.turnEnded(ok: true, at: 2)
        XCTAssertEqual(o.frameRate(at: 50), 12) // idle breathes slowly, at a low rate
        o.typing = true
        XCTAssertLessThanOrEqual(o.look(at: 50).edge, 0.15)
        XCTAssertTrue(ClaudeOrb.look(.error).danger)
        XCTAssertFalse(ClaudeOrb.look(.waiting).flashes)
        for s in ClaudeOrbState.allCases { XCTAssertLessThanOrEqual(ClaudeOrb.look(s).edge, 0.5) } // subtle, always
    }
}

final class ClaudeOrbShaderTests: XCTestCase {
    func testStatesBecomeTheShadersSmokeAndGlass() {
        func u(_ s: ClaudeOrbState, pulse: Double = 0, rm: Bool = false) -> ClaudeOrbUniforms {
            ClaudeOrbShader.uniforms(s, look: ClaudeOrb.look(s), time: 1, pulse: pulse, reduceMotion: rm)
        }
        XCTAssertLessThan(u(.idle).bright, u(.thinking).bright)
        XCTAssertGreaterThan(u(.operating).current, 0) // a current streams across
        XCTAssertEqual(u(.thinking).current, 0)
        XCTAssertEqual(u(.error).danger, 1)
        XCTAssertEqual(u(.thinking, pulse: 0.7).pulse, 0.7) // a chunk: a plume rises
        XCTAssertEqual(u(.idle, pulse: 0.7).pulse, 0) // idle never flashes
        XCTAssertGreaterThan(u(.thinking, pulse: 1).pop, u(.thinking).pop) // the glass pops per chunk
        XCTAssertGreaterThan(u(.thinking).wobble, u(.idle).wobble)
        for s in ClaudeOrbState.allCases { XCTAssertLessThanOrEqual(u(s).wobble, 0.05); XCTAssertLessThanOrEqual(abs(u(s, pulse: 1).pop), 0.06) } // subtle, never rubbery
        let still = u(.thinking, pulse: 1, rm: true)
        XCTAssertEqual(still.wobble, 0); XCTAssertEqual(still.pop, 0); XCTAssertEqual(still.pulse, 0) // Reduce Motion: the shape is still
        XCTAssertGreaterThan(ClaudeOrb.look(.thinking).swirl, ClaudeOrb.look(.idle).swirl)
        XCTAssertLessThan(ClaudeOrb.look(.error).swirl, ClaudeOrb.look(.idle).swirl) // error slows down
    }

    func testPhaseOnlyMovesForwardAndNeverJumps() {
        let look = ClaudeOrb.look(.thinking)
        XCTAssertEqual(ClaudeOrbShader.advance(5, by: 1, look: look), 5 + 0.25 * look.swirl, accuracy: 1e-9) // a stall
        XCTAssertEqual(ClaudeOrbShader.advance(5, by: -1, look: look), 5)
        XCTAssertEqual(ClaudeOrbShader.advance(5, by: 0.1, look: ClaudeOrb.look(.idle, reduceMotion: true)), 5) // Reduce Motion: still
    }
}

final class ClaudeContextTests: XCTestCase {
    func testTheStripReadsTheScreenClaudeGets() {
        // The same JSON the composer syncs (SuiteScreen.json): a New Swap with a clip, a product photo and a described background.
        let remix = ShotRequest.remix(clipId: "clip_1", draft: {
            var d = RemixDraft(); d.backgroundOn = true; d.backgroundMode = .describe; d.backgroundWords = "a beach at dusk"; return d
        }())
        var r = remix; r.modelId = "m_1"; r.outfitId = "of_1"; r.engineModel = "seedance-2"
        let screen = SuiteScreen.json(tool: "remix", request: r, inputs: [
            SuiteScreen.Input(slot: "remix.clip", kind: "video", label: "Walk.mp4", clipId: "clip_1", seconds: 12),
            SuiteScreen.Input(slot: "remix.outfit", kind: "image", label: "Hoodie photo", url: "/uploads/p.jpg"),
            SuiteScreen.Input(slot: "reference 1", kind: "image", label: "Look", role: "style", url: "/uploads/r.jpg"),
            SuiteScreen.Input(slot: "guide", kind: "video", label: "Blender guide", role: "blocking", key: "g.mp4"),
        ], settings: ["modelLabel": .string("Seedance 2.0 · Higgsfield")], at: nil)
        let items = ClaudeContext.items(screen: screen, lookups: .init(
            character: { $0 == "m_1" ? ("Ava", ImageRef(url: "/uploads/face.jpg")) : nil },
            outfit: { $0 == "of_1" ? ("Hoodie", nil) : nil },
            clipPoster: { $0 == "clip_1" ? ImageRef(url: "/uploads/poster.jpg") : nil },
            modelLabel: { _ in "not used: the screen names it" }))
        XCTAssertEqual(items.map(\.label), ["Clip", "Her", "Outfit", "Background", "Product", "Style", "Guide", "Model"])
        XCTAssertEqual(items[0].image?.url, "/uploads/poster.jpg")
        XCTAssertEqual(items[1].detail, "Ava")
        XCTAssertEqual(items[3].words, "a beach at dusk")
        XCTAssertEqual(items.last?.detail, "Seedance 2.0 · Higgsfield") // the server's label, never built in the app
        XCTAssertEqual(Set(items.map(\.id)).count, items.count) // stable, unique ids (the strip animates by id)
        XCTAssertTrue(ClaudeContext.items(screen: .null).isEmpty)
    }
}
