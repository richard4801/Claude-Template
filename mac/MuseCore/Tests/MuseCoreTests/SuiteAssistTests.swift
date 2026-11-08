import XCTest
@testable import MuseCore

/// Claude in the AI Suite: the shared draft's wire types (decoded leniently), the composer patch (the Draft checked against
/// the composer's own options, refusing unknown, hidden and merged values with a reason), the row-by-row merge after a
/// `409 stale`, the chat's context line, demo mode's stand-in reply and FakeMuseAPI's assist (revisions, paid asks that run
/// only on approve).
final class SuiteAssistTests: XCTestCase {
    private func api() async throws -> FakeMuseAPI {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        return a
    }

    private func options(_ a: FakeMuseAPI) async throws -> SuiteDraftOptions {
        let cat = try await a.suiteCatalog()
        let models = try await a.listModels()
        let outfits = try await a.listOutfits()
        return SuiteDraftOptions(catalog: cat, characters: Dictionary(models.map { ($0.id, $0.shortName) }, uniquingKeysWith: { x, _ in x }),
                                 outfits: Dictionary(outfits.map { ($0.id, $0.name) }, uniquingKeysWith: { x, _ in x }))
    }

    private func expectError(_ code: String, _ f: () async throws -> Void) async {
        do {
            try await f()
            XCTFail("expected \(code)")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Wire

    func testAssistDecodesLenientlyAndKeepsTheDraft() throws {
        let json = #"{"id":"sa_1","revision":3,"draft":{"tool":"shot","quality":"draft","rig":{"lens":"anamorphic"},"future":1},"pending":[{"id":"sp_1","kind":"suite_request_shot","label":"Generate · 5 s · $0.16","estimateUsd":0.16,"maxUsd":0.18,"status":"waiting","createdAt":1762600000000},{"id":"sp_0","status":"failed","error":"A spending cap stops this shot"}],"warnings":[],"updatedAt":1762600000000.0,"extra":true}"#
        let a = try JSONDecoder().decode(SuiteAssist.self, from: Data(json.utf8))
        XCTAssertEqual(a.id, "sa_1")
        XCTAssertEqual(a.revision, 3)
        XCTAssertEqual(a.draft?.rig?.lens, "anamorphic")
        XCTAssertEqual(a.draft?.extra["future"], .number(1))
        XCTAssertEqual(a.pending.count, 2)
        XCTAssertEqual(a.waiting?.id, "sp_1")
        XCTAssertEqual(a.waiting?.estimateUsd, 0.16)
        XCTAssertEqual(a.waiting?.maxUsd, 0.18, "the confirmation shows the price being approved")
        XCTAssertEqual(a.pending[1].kind, "suite_request_shot")
        XCTAssertEqual(a.pending[1].maxUsd, 0, "without maxUsd: the estimate")
        XCTAssertEqual(a.failed?.error, "A spending cap stops this shot")
        XCTAssertEqual(a.updatedAt, 1_762_600_000_000)
        XCTAssertNil(a.request)

        let bare = try JSONDecoder().decode(SuiteAssist.self, from: Data(#"{"id":"sa_2"}"#.utf8))
        XCTAssertEqual(bare.revision, 0)
        XCTAssertTrue(bare.pending.isEmpty)
    }

    func testTheLiveEventCarriesTheAssist() throws {
        let json = #"{"type":"suiteAssist","assist":{"id":"sa_9","revision":7,"draft":{"tool":"shot"}}}"#
        let e = try JSONDecoder().decode(ApiEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.assist?.id, "sa_9")
        XCTAssertEqual(e.assist?.revision, 7)
        let other = try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"job","assist":{"id":"x"}}"#.utf8))
        XCTAssertNil(other.assist, "only suiteAssist events are read")
    }

    func testASuiteBriefNamesTheDraft() throws {
        let b = try JSONDecoder().decode(ClaudeBrief.self, from: Data(#"{"prompt":"Fill in the composer.","tools":["suite_set_draft"],"assistId":"sa_4"}"#.utf8))
        XCTAssertEqual(b.assistId, "sa_4")
        XCTAssertEqual(b.systemPrompt, "Fill in the composer.\n\nThe Suite draft: sa_4.")
    }

    // MARK: The composer patch

    func testAValidDraftFillsTheComposerAndNamesTheRows() async throws {
        let o = try await options(try await api())
        let character = try XCTUnwrap(o.characters.first)
        var c = ComposerDraft()
        c.tokens = PromptTokens.text("old idea")
        var next = c
        next.tokens = PromptTokens([.mention(kind: "character", id: character.key, label: "Whoever", key: 4), .text(" walks into a café ")])
            .addMove(try XCTUnwrap(o.camera.move("dolly_in")), catalog: o.camera).0
        next.settings = ComposerSettings(body: "cinema_digital", lens: "anamorphic", focalMm: 35, aperture: "f2.8", height: "low", shotSize: "ms",
                                         genre: "drama", tempo: "steady", palette: "teal_orange", lighting: "window")
        next.aspect = "16:9"
        next.duration = 10
        let r = SuiteAssistDraft.apply(ComposerDrafts.draft(next), to: c, options: o)
        XCTAssertEqual(r.rejected, [])
        XCTAssertEqual(r.composer.settings.lens, "anamorphic")
        XCTAssertEqual(r.composer.settings.focalMm, 35)
        XCTAssertEqual(r.composer.aspect, "16:9")
        XCTAssertEqual(r.composer.duration, 10)
        XCTAssertEqual(r.composer.tokens.characterId, character.key)
        XCTAssertTrue(r.composer.tokens.display().hasPrefix("@\(character.value)"), "the studio's name, not the draft's label")
        XCTAssertEqual(r.changed, ["Character", "Prompt", "Moves", "Camera", "Light", "Look", "Style", "Shape", "Length"])
        XCTAssertEqual(SuiteAssistDraft.toast(["Camera", "Light"]), "Claude set Camera and Light")
        XCTAssertEqual(SuiteAssistDraft.toast(["Camera", "Light", "Prompt"]), "Claude set Camera, Light and Prompt")
        XCTAssertNil(SuiteAssistDraft.toast([]))
    }

    func testUnknownHiddenAndMergedValuesAreRefusedWithAReason() async throws {
        let o = try await options(try await api())
        var c = ComposerDraft()
        c.settings.lens = "clean"
        var d = ComposerDrafts.draft(c)
        d.rig = SuiteRig(body: "super35", lens: "cine_zoom", focalMm: 18, aperture: "f2", lighting: "laser_show", palette: "teal_orange", format: "unboxing")
        d.quality = "ultra"
        d.aspect = "2:1"
        d.duration = 99
        d.takes = 9
        let r = SuiteAssistDraft.apply(d, to: c, options: o)
        let fields = Dictionary(r.rejected.map { ($0.field, $0) }, uniquingKeysWith: { x, _ in x })
        XCTAssertTrue(fields["Camera"]?.reason.contains("Cinema camera") ?? false, "a merged body names its survivor")
        XCTAssertEqual(fields["Lens"]?.reason, "isn't offered in the composer")
        XCTAssertNotNil(fields["Focal length"])
        XCTAssertNotNil(fields["Aperture"])
        XCTAssertEqual(fields["Light"]?.reason, "isn't one of the composer's options")
        XCTAssertEqual(fields["Format"]?.reason, "isn't used by Shot")
        XCTAssertNotNil(fields["Quality"])
        XCTAssertNotNil(fields["Shape"])
        XCTAssertEqual(fields["Length"]?.reason, "is outside 2–15 s on Draft")
        XCTAssertNotNil(fields["Takes"])
        // Refused rows keep what they were; the valid one lands.
        XCTAssertEqual(r.composer.settings.lens, "clean")
        XCTAssertNil(r.composer.settings.body)
        XCTAssertNil(r.composer.settings.focalMm)
        XCTAssertEqual(r.composer.settings.palette, "teal_orange")
        XCTAssertEqual(r.composer.quality, c.quality)
        XCTAssertEqual(r.composer.duration, c.duration)
        XCTAssertEqual(r.changed, ["Look"])
        XCTAssertTrue(r.rejected[0].text.contains("“"))
    }

    func testRowsTheToolDoesNotUseAndAnotherToolAreRefused() async throws {
        let o = try await options(try await api())
        var swap = ComposerDraft(tool: .swap)
        var d = ComposerDrafts.draft(swap)
        d.rig = SuiteRig(body: "phone", palette: "teal_orange")
        let r = SuiteAssistDraft.apply(d, to: swap, options: o)
        XCTAssertEqual(r.rejected.map(\.field), ["Camera"])
        XCTAssertEqual(r.composer.settings.palette, "teal_orange", "Swap keeps its Look row")
        swap.settings.palette = "teal_orange"
        let other = SuiteAssistDraft.apply(ComposerDrafts.draft(ComposerDraft(tool: .shot)), to: swap, options: o)
        XCTAssertEqual(other.composer, swap)
        XCTAssertEqual(other.rejected.first?.field, "Tool")
        let noCatalog = SuiteAssistDraft.apply(d, to: swap, options: SuiteDraftOptions(catalog: nil))
        XCTAssertEqual(noCatalog.composer, swap)
        XCTAssertEqual(noCatalog.rejected.count, 1)
    }

    func testThePromptKeepsOnlyKnownMentionsAndMixableMoves() async throws {
        let o = try await options(try await api())
        let character = try XCTUnwrap(o.characters.first)
        var d = ComposerDrafts.draft(ComposerDraft())
        d.tokens = [
            .object(["t": .string("mention"), "kind": .string("character"), "id": .string("m_nobody"), "label": .string("Ghost"), "key": .number(1)]),
            .object(["t": .string("mention"), "kind": .string("character"), "id": .string(character.key), "label": .string("x"), "key": .number(2)]),
            .object(["t": .string("text"), "text": .string(" on a rooftop ")]),
            .object(["t": .string("move"), "id": .string("static"), "label": .string("Static"), "category": .string("static"), "intensity": .number(50), "key": .number(3)]),
            .object(["t": .string("move"), "id": .string("dolly_in"), "label": .string("Dolly in"), "category": .string("push"), "intensity": .number(140), "key": .number(4)]),
            .object(["t": .string("move"), "id": .string("warp_drive"), "label": .string("Warp"), "category": .string("x"), "intensity": .number(50), "key": .number(5)]),
        ]
        let r = SuiteAssistDraft.apply(d, to: ComposerDraft(), options: o)
        XCTAssertEqual(r.composer.tokens.characterId, character.key)
        XCTAssertEqual(r.composer.tokens.moves.compactMap(\.move).map(\.id), ["static"])
        XCTAssertEqual(Set(r.rejected.map(\.field)), ["Character", "Move"])
        XCTAssertTrue(r.rejected.contains { $0.reason == "can't be combined with Static" })
        XCTAssertTrue(r.rejected.contains { $0.reason == "isn't one of the composer's moves" })
        XCTAssertTrue(r.composer.tokens.promptText().contains("on a rooftop"))
    }

    func testTheOwnersEditsSurviveAStaleMerge() {
        var base = ComposerDraft()
        base.settings.lens = "clean"
        var mine = base
        mine.duration = 12 // the owner changed the length by hand
        var theirs = base
        theirs.settings.lens = "anamorphic" // Claude changed the lens meanwhile
        theirs.duration = 5
        let m = SuiteAssistDraft.merge(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(m.duration, 12)
        XCTAssertEqual(m.settings.lens, "anamorphic")
    }

    // MARK: The chat

    func testTheContextLineCarriesTheDraftAndIsHiddenInTheChat() async throws {
        let o = try await options(try await api())
        var c = ComposerDraft()
        c.settings.lens = "anamorphic"
        c.tokens = PromptTokens.text("A rooftop at night")
        let line = SuiteAssistClaude.context(assistId: "sa_1", revision: 4, composer: c, camera: o.camera,
                                             rejected: [SuiteDraftRejection(field: "Lens", value: "Cine zoom", reason: "isn't offered in the composer")])
        XCTAssertTrue(line.hasPrefix("[Suite · draft sa_1 rev 4 · Shot"))
        XCTAssertTrue(line.contains("Camera: Anamorphic"))
        XCTAssertTrue(line.contains("prompt: “A rooftop at night”"))
        XCTAssertTrue(line.contains("not applied: Lens “Cine zoom” isn't offered"))
        let sent = SuiteAssistClaude.message("Make it moodier", context: line)
        XCTAssertEqual(SuiteAssistClaude.stripContext(sent), "Make it moodier")
        XCTAssertEqual(SuiteAssistClaude.stripContext("plain"), "plain")
        XCTAssertEqual(SuiteAssistClaude.suggestions.map(\.label), ["Fill this in from my idea", "Make it more cinematic", "Explain the settings"])
    }

    func testTheDemoReplyFillsEveryRowWithValidOptionsAndGoAsksToGenerate() async throws {
        let o = try await options(try await api())
        let name = try XCTUnwrap(o.characters.values.sorted().first)
        let c = ComposerDraft()
        let reply = SuiteAssistClaude.demoReply(to: "\(name) orders coffee in a café, golden afternoon, close and calm", composer: c, options: o)
        let d = try XCTUnwrap(reply.draft)
        let r = SuiteAssistDraft.apply(d, to: c, options: o)
        XCTAssertEqual(r.rejected, [], "the stand-in only picks options the composer offers")
        let s = r.composer.settings
        for v in [s.body, s.lens, s.aperture, s.height, s.shotSize, s.lighting, s.palette, s.genre, s.tempo] { XCTAssertNotNil(v) }
        XCTAssertNotNil(s.focalMm)
        XCTAssertEqual(s.lighting, "window")
        XCTAssertEqual(s.shotSize, "cu")
        XCTAssertEqual(s.tempo, "calm")
        XCTAssertNotNil(r.composer.tokens.characterId)
        XCTAssertEqual(r.composer.tokens.moves.count, 1)
        XCTAssertFalse(reply.generate)
        XCTAssertFalse(reply.text.contains("!"))

        XCTAssertTrue(SuiteAssistClaude.demoReply(to: "Go", composer: r.composer, options: o).generate)
        let explain = SuiteAssistClaude.demoReply(to: SuiteAssistClaude.explainPrompt, composer: r.composer, options: o)
        XCTAssertNil(explain.draft)
        XCTAssertTrue(explain.text.contains("Light is Window light"))
        let cinematic = SuiteAssistClaude.demoReply(to: SuiteAssistClaude.cinematicPrompt, composer: r.composer, options: o)
        let rc = SuiteAssistDraft.apply(try XCTUnwrap(cinematic.draft), to: r.composer, options: o)
        XCTAssertEqual(rc.rejected, [])
        XCTAssertEqual(rc.composer.settings.lens, "anamorphic")
        XCTAssertEqual(rc.composer.tokens.characterId, r.composer.tokens.characterId, "the cinematic chip keeps the character")
    }

    // MARK: Demo mode's assist (FakeMuseAPI)

    func testTheFakeAssistKeepsRevisionsAndRefusesAStalePatch() async throws {
        let a = try await api()
        var c = ComposerDraft()
        c.tokens = PromptTokens.text("A rooftop at night")
        let made = try await a.createSuiteAssist(SuiteAssistCreate(draft: ComposerDrafts.draft(c)))
        XCTAssertTrue(made.id.hasPrefix("sa_"))
        XCTAssertEqual(made.revision, 1)
        XCTAssertEqual(made.request?.prompt, "A rooftop at night")
        c.duration = 10
        let patched = try await a.patchSuiteAssist(id: made.id, SuiteAssistPatch(draft: ComposerDrafts.draft(c), baseRevision: 1))
        XCTAssertEqual(patched.revision, 2)
        XCTAssertEqual(patched.request?.duration, 10)
        await expectError("stale") { _ = try await a.patchSuiteAssist(id: made.id, SuiteAssistPatch(draft: ComposerDrafts.draft(c), baseRevision: 1)) }
        let read = try await a.suiteAssist(id: made.id)
        XCTAssertEqual(read.revision, 2)
        await expectError("not_found") { _ = try await a.suiteAssist(id: "sa_none") }
    }

    func testAPaidAskRunsOnlyOnApprove() async throws {
        let a = try await api()
        var c = ComposerDraft()
        c.tokens = PromptTokens.text("A rooftop at night")
        let made = try await a.createSuiteAssist(SuiteAssistCreate(draft: ComposerDrafts.draft(c)))
        let jobsBefore = try await a.listJobs().count
        let asked = try await a.demoClaudeAssist(id: made.id, draft: nil, generate: true)
        let p = try XCTUnwrap(asked.waiting)
        XCTAssertGreaterThan(p.estimateUsd, -0.0001)
        let after = try await a.listJobs().count
        XCTAssertEqual(after, jobsBefore, "asking holds and runs nothing")

        let declined = try await a.answerSuitePending(assistId: made.id, pendingId: p.id, approve: false)
        XCTAssertEqual(declined.status, "declined")
        XCTAssertNil(declined.jobId)
        await expectError("not_found") { _ = try await a.answerSuitePending(assistId: made.id, pendingId: p.id, approve: true) }

        let again = try XCTUnwrap(try await a.demoClaudeAssist(id: made.id, draft: nil, generate: true).waiting)
        let done = try await a.answerSuitePending(assistId: made.id, pendingId: again.id, approve: true)
        XCTAssertEqual(done.status, "done")
        let jobId = try XCTUnwrap(done.jobId)
        let shot = try await a.suiteShot(id: jobId)
        XCTAssertEqual(shot.job.id, jobId)
    }

    // MARK: Attached images

    func testAttachmentsTakeUpToFourImagesOfTheAllowedTypes() {
        XCTAssertEqual(SuiteClaudeAttachments.mime(name: "a.JPG"), "image/jpeg")
        XCTAssertEqual(SuiteClaudeAttachments.mime(name: "a.heic"), "image/heic")
        XCTAssertEqual(SuiteClaudeAttachments.mime(name: "a.webp"), "image/webp")
        XCTAssertEqual(SuiteClaudeAttachments.mime(name: "x", mime: "image/jpg"), "image/jpeg")
        XCTAssertNil(SuiteClaudeAttachments.mime(name: "a.gif"))
        XCTAssertNil(SuiteClaudeAttachments.mime(name: "a.png", mime: "application/pdf"), "a known type wins over the name")
        XCTAssertNil(SuiteClaudeAttachments.mime(name: "clip.mov"))

        let ok = SuiteClaudeAttachments.check(existing: 0, picked: [("a.png", nil), ("b.jpeg", nil)])
        XCTAssertEqual(ok.take, [0, 1])
        XCTAssertNil(ok.refusal)
        let mixed = SuiteClaudeAttachments.check(existing: 1, picked: [("a.png", nil), ("doc.pdf", nil), ("b.heic", nil), ("c.webp", nil), ("d.png", nil)])
        XCTAssertEqual(mixed.take, [0, 2, 3], "the wrong type is left out, and only three more fit")
        XCTAssertEqual(mixed.refusal, "Up to 4 images (JPEG, PNG, WebP or HEIC)")
        XCTAssertEqual(SuiteClaudeAttachments.check(existing: 4, picked: [("a.png", nil)]).take, [])
    }

    func testASentMessageNamesItsImagesAndTheThreadReadsThemBack() {
        let part = SuiteClaudeAttachments.contextPart([(uploadId: "up_1", url: "https://x/uploads/a.png"), (uploadId: nil, url: "https://x/uploads/b.png")])
        XCTAssertEqual(part, "images: https://x/uploads/a.png (upload up_1), https://x/uploads/b.png")
        let msg = "[Suite · draft sa_1 rev 2 · Shot · prompt: “x” · \(part!)]\nUse these"
        XCTAssertEqual(SuiteClaudeAttachments.images(in: msg), ["https://x/uploads/a.png", "https://x/uploads/b.png"])
        XCTAssertEqual(SuiteAssistClaude.stripContext(msg), "Use these")
        XCTAssertEqual(SuiteClaudeAttachments.images(in: "no images here"), [])
        XCTAssertNil(SuiteClaudeAttachments.contextPart([]))
    }

    func testAUserMessageReadsItsAttachmentsLeniently() throws {
        let a = try JSONDecoder().decode(ClaudeMessage.self, from: Data(#"{"id":"m1","role":"user","text":"x","attachments":["up_1","up_2"]}"#.utf8))
        XCTAssertEqual(a.attachments, ["up_1", "up_2"])
        let b = try JSONDecoder().decode(ClaudeMessage.self, from: Data(#"{"id":"m2","role":"user","text":"x","uploadId":"up_3"}"#.utf8))
        XCTAssertEqual(b.attachments, ["up_3"])
        let c = try JSONDecoder().decode(ClaudeMessage.self, from: Data(#"{"id":"m3","role":"user","text":"x","attachments":7}"#.utf8))
        XCTAssertNil(c.attachments)
    }

    func testClaudesReferencesFillTheReferenceSlotsWhileThereIsRoom() {
        let pose = SuiteDraftReference(image: ImageRef(url: "https://x/p.png"), role: "pose", uploadId: "up_1")
        let place = SuiteDraftReference(image: ImageRef(url: "https://x/l.png"), role: "location")
        let odd = SuiteDraftReference(image: ImageRef(url: "https://x/o.png"), role: "logo")
        var d = SuiteDraft(tool: "shot")
        d.raw["references"] = .array([pose.json, place.json, odd.json, .object(["role": .string("style")]), .string("junk")])
        XCTAssertEqual(SuiteAssistDraft.references(SuiteAssistDraft.with([pose], in: SuiteDraft(tool: "shot"))), [pose])
        let refs = SuiteAssistDraft.references(d)
        XCTAssertEqual(refs, [pose, place, odd], "entries without an image are skipped")
        XCTAssertNil(d.problem, "references ride along as an extra key")

        let r = SuiteAssistDraft.place(refs, into: InputSlots(), capacity: 6)
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.slots[SlotId(.image, 0)]?.role, "person")
        XCTAssertEqual(r.slots[SlotId(.image, 0)]?.name, "Pose from Claude")
        XCTAssertEqual(r.slots[SlotId(.image, 1)]?.role, "location")
        XCTAssertEqual(r.rejected.map(\.reason), ["isn't a pose, style, location or outfit reference"])
        let again = SuiteAssistDraft.place(refs, into: r.slots, capacity: 6)
        XCTAssertEqual(again.added, 0, "an image already there isn't added twice")
        let tight = SuiteAssistDraft.place([pose, place], into: InputSlots(), capacity: 1)
        XCTAssertEqual(tight.added, 1)
        XCTAssertEqual(tight.rejected.first?.reason, "has no room: this quality takes 1")
        XCTAssertEqual(SuiteAssistDraft.place([pose], into: InputSlots(), capacity: 0).rejected.first?.reason, "isn't taken by this quality")
    }
}
