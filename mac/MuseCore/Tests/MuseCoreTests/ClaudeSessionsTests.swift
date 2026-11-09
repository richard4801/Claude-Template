import XCTest
@testable import MuseCore

/// WS18, the owner's Claude chat bug report: a message typed once shows once; each place keeps its own list of chats
/// (new, switch, rename, delete), stored on the server so they come back; and a draft Claude sets (rig, prompt, reference)
/// in any Suite mode reaches the composer.
final class ClaudeSessionsTests: XCTestCase {
    private let ctx = "[Suite · draft sa_1abcd rev 3 · Photo · Draft, 9:16, 5 s, 1 take · prompt: empty]"
    private let words = "Great place it, and also add the image as reference."

    private func users(_ t: ClaudeTranscript) -> [String] {
        t.items.compactMap { if case .user(_, let text, _) = $0 { return ClaudeSessions.typedText(text) }; return nil }
    }

    // MARK: 1. Every message sent twice

    func testAMessageTypedOnceShowsOnceThroughEchoAndStoredCopy() {
        // The owner's report: the bubble the app shows at once, the runner's echo (with the context line) and the stored
        // message (with the context line too) are one message.
        let wrapped = "\(ctx)\n\(words)"
        var t = ClaudeTranscript()
        t.begin(userText: wrapped, source: "mac")
        XCTAssertEqual(users(t), [words])
        t.apply(.user(text: wrapped, attachments: []))
        XCTAssertEqual(users(t), [words], "the runner's echo is the bubble already shown")
        t.upsert(ClaudeMessage(id: "cm_1", threadId: "ct_1", role: "user", source: "mac", text: wrapped, createdAt: 10))
        XCTAssertEqual(users(t), [words], "the stored copy replaces the live bubble")
        t.apply(.text(delta: "On it."))
        t.apply(.done(ok: true, error: nil, model: nil))
        t.load([ClaudeMessage(id: "cm_1", threadId: "ct_1", role: "user", source: "mac", text: wrapped, createdAt: 10)])
        XCTAssertEqual(users(t), [words])
    }

    func testABubbleBegunWithoutTheContextLineStillMatchesItsWrappedCopies() {
        // Older call sites began the bubble with the bare words; the echo and the server carry the context line.
        var t = ClaudeTranscript()
        t.begin(userText: words, source: "mac")
        t.apply(.user(text: "\(ctx)\n\(words)", attachments: []))
        XCTAssertEqual(users(t), [words])
        t.upsert(ClaudeMessage(id: "cm_1", threadId: "ct_1", role: "user", source: "mac", text: "\(ctx)\n\(words)", createdAt: 10))
        XCTAssertEqual(users(t).count, 1)
        // A second press before the first went anywhere (Return and the button) is the same bubble.
        var u = ClaudeTranscript()
        u.begin(userText: words, source: "mac")
        u.begin(userText: words, source: "mac")
        XCTAssertEqual(users(u).count, 1)
    }

    func testTheStoredEchoArrivingFirstAddsNoBubble() {
        var t = ClaudeTranscript()
        t.upsert(ClaudeMessage(id: "cm_1", threadId: "ct_1", role: "user", source: "mac", text: "\(ctx)\n\(words)", createdAt: 10))
        t.apply(.user(text: "\(ctx)\n\(words)", attachments: []))
        XCTAssertEqual(users(t), [words])
    }

    func testTypedTextKeepsTheOwnersOwnBrackets() {
        XCTAssertEqual(ClaudeSessions.typedText("\(ctx)\nhello"), "hello")
        XCTAssertEqual(ClaudeSessions.typedText("[note]"), "[note]", "a one-line message in brackets is the owner's")
        XCTAssertEqual(ClaudeSessions.typedText("  plain  "), "plain")
    }

    // MARK: 2. Sessions

    func testKeysTitlesAndLastUsed() {
        XCTAssertEqual(ClaudeSessions.suiteKey("photo"), "suite:photo")
        XCTAssertEqual(ClaudeSessions.suiteKey("../x"), "suite:shot")
        XCTAssertEqual(ClaudeSessions.contextKey(kind: "recreate", id: "rx_1"), "recreate:rx_1")
        XCTAssertEqual(ClaudeSessions.autoTitle("\(ctx)\n\(words)"), words)
        XCTAssertEqual(ClaudeSessions.autoTitle("[Recreate rx_1]\nMatch shot 4 to /Users/me/x.png please"), "Match shot 4 to please")
        XCTAssertNil(ClaudeSessions.autoTitle("\(ctx)\n  "))
        let long = ClaudeSessions.autoTitle("She walks out of the café into golden light, turns to the camera and smiles while the wind lifts her hair")!
        XCTAssertLessThanOrEqual(long.count, 61)
        XCTAssertTrue(long.hasSuffix("…"))
        let t = ClaudeThread(id: "ct_1", contextKind: "suite", contextId: "sa_1", createdAt: 0, updatedAt: 0)
        XCTAssertEqual(ClaudeSessions.displayTitle(t), "New chat")
        XCTAssertTrue(ClaudeSessions.isEmpty(t))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = 1_794_200_000_000.0 // 2026-11-09 06:13 UTC
        XCTAssertEqual(ClaudeSessions.lastUsed(now - 20_000, now: now, calendar: cal), "Just now")
        XCTAssertEqual(ClaudeSessions.lastUsed(now - 5 * 60_000, now: now, calendar: cal), "5 min ago")
        XCTAssertEqual(ClaudeSessions.lastUsed(now - 3 * 3_600_000, now: now, calendar: cal), "3 h ago")
        XCTAssertEqual(ClaudeSessions.lastUsed(now - 24 * 3_600_000, now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(ClaudeSessions.lastUsed(now - 4 * 86_400_000, now: now, calendar: cal), "4 days ago")
        XCTAssertEqual(ClaudeSessions.lastUsed(now - 30 * 86_400_000, now: now, calendar: cal), "10 Oct")
    }

    func testPickAfterDeleteAndUpsertKeepTheNewestFirst() {
        func th(_ id: String, _ at: Double) -> ClaudeThread { ClaudeThread(id: id, contextKind: "suite", contextId: "sa_\(id)", createdAt: at, updatedAt: at) }
        var list = [th("a", 3), th("b", 1)]
        XCTAssertEqual(ClaudeSessions.pick(list, preferred: nil)?.id, "a")
        XCTAssertEqual(ClaudeSessions.pick(list, preferred: "b")?.id, "b")
        XCTAssertEqual(ClaudeSessions.pick(list, preferred: "gone")?.id, "a")
        XCTAssertEqual(ClaudeSessions.after(deleting: "a", in: list)?.id, "b")
        XCTAssertNil(ClaudeSessions.after(deleting: "b", in: [th("b", 1)]))
        var b = th("b", 9)
        b.title = "Café look"
        ClaudeSessions.upsert(b, into: &list)
        XCTAssertEqual(list.map(\.id), ["b", "a"])
        XCTAssertEqual(list[0].title, "Café look")
        ClaudeSessions.upsert(th("c", 5), into: &list)
        XCTAssertEqual(list.map(\.id), ["b", "c", "a"])
    }

    func testThreadListsAndTheDeletedEventDecode() throws {
        let json = #"{"key":"suite:photo","threads":[{"id":"ct_2","contextKind":"suite","contextId":"sa_2","contextKey":"suite:photo","title":"Café look","messageCount":4,"createdAt":1,"updatedAt":5},{"id":"ct_1","contextKind":"suite","contextId":"sa_1"}]}"#
        let l = try JSONDecoder().decode(ClaudeThreadList.self, from: Data(json.utf8))
        XCTAssertEqual(l.threads.map(\.id), ["ct_2", "ct_1"])
        XCTAssertEqual(l.threads[0].title, "Café look")
        XCTAssertEqual(l.threads[0].messageCount, 4)
        XCTAssertEqual(l.threads[0].contextKey, "suite:photo")
        XCTAssertNil(l.threads[1].title)
        XCTAssertEqual(ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"threadDeleted","threadId":"ct_9","contextKey":"suite:photo"}"#.utf8)), .threadDeleted(threadId: "ct_9"))
    }

    func testTheFakeKeepsAListPerPlaceWithTitlesRenameAndDelete() async throws {
        let api = FakeClaudeAPI()
        api.suiteToolOf = { $0 == "sa_photo1" || $0 == "sa_photo2" ? "photo" : "shot" }
        let shot = try await api.thread(contextKind: "suite", contextId: "sa_shot1")
        let p1 = try await api.thread(contextKind: "suite", contextId: "sa_photo1")
        XCTAssertEqual(shot.contextKey, "suite:shot")
        XCTAssertEqual(p1.contextKey, "suite:photo")
        let again = try await api.thread(contextKind: "suite", contextId: "sa_photo1")
        XCTAssertEqual(again.id, p1.id, "the same draft is the same chat")
        try await api.postEvents(threadId: p1.id, ClaudeEventBatch(turnId: nil, events: [.user(text: "\(ctx)\n\(words)", attachments: [])]))
        let p2 = try await api.thread(contextKind: "suite", contextId: "sa_photo2")
        try await api.postEvents(threadId: p2.id, ClaudeEventBatch(turnId: nil, events: [.user(text: "Second idea", attachments: [])]))
        var list = try await api.threads(key: "suite:photo")
        XCTAssertEqual(list.map(\.id), [p2.id, p1.id])
        XCTAssertEqual(list[1].title, words)
        XCTAssertEqual(list[1].messageCount, 1)
        let shots = try await api.threads(key: "suite:shot")
        XCTAssertEqual(shots.map(\.id), [shot.id])
        let named = try await api.renameThread(p1.id, title: " Café look ")
        XCTAssertEqual(named.title, "Café look")
        let unnamed = try await api.renameThread(p1.id, title: "")
        XCTAssertEqual(unnamed.title, words)
        try await api.deleteThread(p2.id)
        list = try await api.threads(key: "suite:photo")
        XCTAssertEqual(list.map(\.id), [p1.id])
        do {
            _ = try await api.threadDetail(p2.id)
            XCTFail("a deleted chat is gone")
        } catch let e as ApiError { XCTAssertEqual(e.code, "not_found") }
        // A new chat about the same edit session; the plain open is the newest.
        let e1 = try await api.thread(contextKind: "edit", contextId: "es_1")
        let e2 = try await api.newThread(contextKind: "edit", contextId: "es_1")
        XCTAssertNotEqual(e1.id, e2.id)
        let edits = try await api.threads(key: "edit:es_1")
        XCTAssertEqual(edits.count, 2)
        // The messages stay with their chat: read again, they are all there.
        let d = try await api.threadDetail(p1.id)
        XCTAssertEqual(d.messages.filter { $0.role == "user" }.count, 1)
    }

    // MARK: 4. Claude's changes reach the composer in every mode

    private func options() async throws -> SuiteDraftOptions {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        let cat = try await a.suiteCatalog()
        let models = try await a.listModels()
        return SuiteDraftOptions(catalog: cat, characters: Dictionary(models.map { ($0.id, $0.shortName) }, uniquingKeysWith: { x, _ in x }))
    }

    func testClaudeSetsTheRigThePromptAndAReferenceAndThePhotoComposerShowsAllThree() async throws {
        let o = try await options()
        var composer = ComposerDraft(tool: .photo)
        composer.tokens = PromptTokens.text("old idea")
        // Claude's draft as the server keeps it now: the composer's own tool (Photo), a rig, a prompt and a reference.
        var claude = composer
        claude.settings = ComposerSettings(lens: "anamorphic", palette: "teal_orange", lighting: "window")
        claude.tokens = PromptTokens.text("At the café window, soft morning light")
        let ref = SuiteDraftReference(uploadId: "up_1", url: "/uploads/u/loc.png", use: "location")
        let draft = SuiteAssistDraft.with([ref], in: ComposerDrafts.draft(claude))
        XCTAssertEqual(draft.tool, "photo")
        let r = SuiteAssistDraft.apply(draft, to: composer, options: o)
        XCTAssertEqual(r.rejected, [])
        XCTAssertEqual(r.composer.settings.lens, "anamorphic", "the rig")
        XCTAssertEqual(r.composer.settings.lighting, "window")
        XCTAssertEqual(r.composer.tokens.promptText(), "At the café window, soft morning light", "the prompt")
        XCTAssertEqual(SuiteAssistDraft.references(draft), [ref], "the reference")
        XCTAssertTrue(r.changed.contains("Camera"))
        XCTAssertTrue(r.changed.contains("Prompt"))

        // The bug: the server used to set every draft to Shot, and the Photo composer refused all of it.
        var forced = draft
        forced.tool = "shot"
        let refused = SuiteAssistDraft.apply(forced, to: composer, options: o)
        XCTAssertEqual(refused.composer, composer)
        XCTAssertEqual(refused.rejected.first?.field, "Tool")
    }

    func testEveryModeTakesItsOwnDraft() async throws {
        let o = try await options()
        for tool in ComposerTool.allCases where tool != .extend {
            let composer = ComposerDraft(tool: tool)
            var claude = composer
            claude.tokens = PromptTokens.text("A new idea for \(tool.title)")
            let r = SuiteAssistDraft.apply(ComposerDrafts.draft(claude), to: composer, options: o)
            XCTAssertFalse(r.rejected.contains { $0.field == "Tool" }, "\(tool.title) refused its own draft")
        }
    }
}
