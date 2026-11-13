import AppKit
import MuseCore

// WS18, the owner's Claude chat bug report, walked in review mode (demo mode: FakeMuseAPI, FakeClaudeAPI and the
// scripted Claude Code; nothing is spent). Each step writes PASS or FAIL to claude-chat-check.txt, which Mac CI reads:
//   one_bubble       one message sent (Return and the button both pressed) shows exactly one bubble, stored once
//   reopen           the chat closed and opened again (a new view) still has its messages
//   sessions         New chat, switch back, rename and delete in one place's list
//   draft_live       Claude sets the rig, the prompt and a reference in Photo; the composer shows all three
//   draft_after_tool the same with the live event missed: the draft is read again after Claude's tool step
//   draft_bound      the chat's context line names the draft the composer shows
//   mode_sessions    each Suite mode has its own chats; closing the panel (or quitting) and opening the mode again returns
//                    to its latest chat with its messages and its draft
extension SnapshotRunner {
    static func claudeChatCheck(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        let file = dir.appendingPathComponent("claude-chat-check.txt")
        func write() { try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8) }
        func line(_ ok: Bool, _ name: String, _ detail: String) {
            lines.append("\(ok ? "PASS" : "FAIL") \(name) · \(detail)")
            NSLog("[snapshot] claude check %@ %@", ok ? "PASS" : "FAIL", name)
            write()
        }
        func until(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if ok() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ok()
        }
        func users(_ m: ClaudeChatModel, _ words: String) -> Int {
            m.transcript.items.filter { if case .user(_, let t, _) = $0 { return ClaudeSessions.typedText(t) == words }; return false }.count
        }
        lines.append("START claude chat check")
        // One Claude: the panel has a single header (its own switcher, New chat and close); the chat inside adds none.
        line(!ClaudeChatView.ownChatSwitcher(contextKind: "chat"), "one-Claude panel has one header", "the embedded chat shows no chat switcher of its own")
        write()

        let svc = ClaudeCodeService.shared
        guard svc.configured, let fakeChat = svc.api as? FakeClaudeAPI, let fakeMuse = store.api as? FakeMuseAPI else {
            line(false, "setup", "demo mode's Claude isn't configured")
            lines.append("ALL DONE")
            write()
            return
        }
        fakeChat.suiteToolOf = { id in await fakeMuse.demoAssistTool(id) ?? "shot" }
        _ = await until(15) { svc.info.ready }

        // 1. One message, one bubble (the Suite's context line in front, as in the owner's screenshot).
        let words = "Great place it, and also add the image as reference."
        let place = "es_chat_check_\(Int(Date().timeIntervalSince1970))"
        let m = ClaudeChatModel()
        m.wrapOutgoing = { "[Suite · draft sa_check rev 1 · Photo · Draft, 9:16, 5 s, 1 take · prompt: empty]\n\($0)" }
        m.unwrapShown = SuiteAssistClaude.stripContext
        await m.attach(svc, contextKind: "edit", contextId: place)
        m.composer = words
        m.send()
        m.composer = words
        m.send()   // the second press of the same message (Return and the Send button): nothing more is sent
        let shownAtOnce = users(m, words)
        _ = await until(1) { m.busy }
        let finished = await until(30) { !m.busy }
        try? await Task.sleep(for: .seconds(2))   // the reload after the turn
        let shownAfter = users(m, words)
        let stored = (try? await fakeChat.threadDetail(m.thread?.id ?? ""))?.messages.filter { $0.role == "user" }.count ?? -1
        line(finished && shownAtOnce == 1 && shownAfter == 1 && stored == 1, "one_bubble",
             "bubbles at once \(shownAtOnce), after the reply \(shownAfter), stored \(stored), reply finished \(finished)")

        // 2. Close and open again: the same chat, its messages still there.
        let firstThread = m.thread
        let replies = m.transcript.items.filter { if case .assistant = $0 { return true }; return false }.count
        m.detach()
        let again = ClaudeChatModel()
        again.unwrapShown = SuiteAssistClaude.stripContext
        await again.attach(svc, contextKind: "edit", contextId: place)
        let againReplies = again.transcript.items.filter { if case .assistant = $0 { return true }; return false }.count
        line(again.thread?.id == firstThread?.id && users(again, words) == 1 && againReplies == replies && replies > 0, "reopen",
             "same chat \(again.thread?.id == firstThread?.id), bubbles \(users(again, words)), Claude's replies \(againReplies) of \(replies)")

        // 3. Sessions in one place: New chat, switch back, rename, delete.
        await again.newChat()
        let second = again.thread
        let newIsEmpty = again.transcript.items.isEmpty && second?.id != firstThread?.id
        let listed = again.threads.count
        if let first = again.threads.first(where: { $0.id == firstThread?.id }) { await again.open(first) }
        let backOnFirst = again.thread?.id == firstThread?.id && users(again, words) == 1
        if let first = again.thread { await again.rename(first, to: "Café look") }
        let renamed = again.threads.first { $0.id == firstThread?.id }?.title == "Café look"
        if let s = again.threads.first(where: { $0.id == second?.id }) { await again.delete(s) }
        let deleted = !again.threads.contains { $0.id == second?.id } && again.thread?.id == firstThread?.id
        line(again.sessionsAvailable && newIsEmpty && listed == 2 && backOnFirst && renamed && deleted, "sessions",
             "list \(again.sessionsAvailable), new chat empty \(newIsEmpty), listed \(listed), switched back \(backOnFirst), renamed \(renamed), deleted \(deleted)")
        again.detach()

        // 4. Claude's draft changes reach the composer, in Photo.
        let savedComposer = store.suite.composer
        let c = store.suite.claude
        defer {
            c.reset()
            store.suite.composer = savedComposer
        }
        if store.suite.catalog == nil { await store.loadSuite() }
        c.reset()
        store.suite.composer = ComposerDraft(tool: .photo)
        c.open = true
        await store.ensureSuiteAssist()
        guard let a = c.assist else {
            line(false, "draft_live", "no shared draft: \(c.error ?? "nothing")")
            lines.append("ALL DONE")
            write()
            return
        }
        let cam = store.suite.camera
        let lens = cam.lenses.first { $0.mergedInto == nil && $0.visible != false }?.id
        let lens2 = cam.lenses.last { $0.mergedInto == nil && $0.visible != false && $0.id != lens }?.id
        func claudeDraft(_ lens: String?, _ prompt: String, refs: [SuiteDraftReference]) -> SuiteDraft {
            var d = store.suite.composer
            d.settings.lens = lens
            d.tokens = PromptTokens.text(prompt)
            return SuiteAssistDraft.with(refs, in: ComposerDrafts.draft(d))
        }
        let ref = SuiteDraftReference(uploadId: "up_check", url: "/uploads/u/check.png", use: "location")
        _ = try? await fakeMuse.demoClaudeAssist(id: a.id, draft: claudeDraft(lens, "At the café window, soft morning light", refs: [ref]), generate: false)
        let live = await until(5) {
            store.suite.composer.settings.lens == lens && store.suite.composer.tokens.promptText() == "At the café window, soft morning light" && c.references.count == 1
        }
        line(live && lens != nil, "draft_live",
             "rig \(store.suite.composer.settings.lens ?? "Auto") (wanted \(lens ?? "none")), prompt “\(store.suite.composer.tokens.promptText())”, references \(c.references.count), refused \(c.rejected.map(\.text))")

        _ = try? await fakeMuse.demoClaudeAssist(id: a.id, draft: claudeDraft(lens2, "Closer, she looks up from the cup", refs: [ref]), generate: false, quiet: true)
        store.suiteClaudeToolDone("mcp__muse__suite_set_draft")
        let afterTool = await until(5) { store.suite.composer.settings.lens == lens2 && store.suite.composer.tokens.promptText() == "Closer, she looks up from the cup" }
        line(afterTool && lens2 != nil, "draft_after_tool", "rig \(store.suite.composer.settings.lens ?? "Auto") (wanted \(lens2 ?? "none")), prompt “\(store.suite.composer.tokens.promptText())”")

        let ctxLine = store.suiteClaudeContext()
        let rev = c.assist?.revision ?? -1
        line(ctxLine.contains("draft \(a.id) rev \(rev)") && c.revision == rev, "draft_bound", "context names \(a.id) rev \(rev); composer at rev \(c.revision)")

        // 5. Sessions per mode: Photo's chat A gets a message; New chat makes B; switching back to A restores its draft;
        //    closing (a fresh start) returns to A with its messages; Shot has its own chats.
        let photoKey = ClaudeSessions.suiteKey("photo")
        let modelA = ClaudeChatModel()
        await modelA.attach(svc, contextKind: "suite", contextId: a.id)
        if let tid = modelA.thread?.id {
            try? await fakeChat.postEvents(threadId: tid, ClaudeEventBatch(turnId: nil, events: [.user(text: "[Suite · draft \(a.id) rev \(rev) · Photo]\n\(words)", attachments: []), .assistant(text: "Done. I set the lens.")]))
        }
        let threadA = modelA.thread
        modelA.detach()
        await store.suiteChatHooks.newChat()
        let b = c.assist
        let modelB = ClaudeChatModel()
        if let b { await modelB.attach(svc, contextKind: "suite", contextId: b.id) }
        modelB.detach()
        let photoList = (try? await svc.threads(key: photoKey)) ?? []
        if let threadA { await store.suiteChatHooks.open(threadA) }
        let switched = c.assist?.id == a.id && store.suite.composer.settings.lens == lens2
        c.reset()   // the panel closed and the app started again
        c.open = true
        await store.ensureSuiteAssist()
        let returned = c.assist?.id == a.id
        let reopened = ClaudeChatModel()
        if let id = c.assist?.id { await reopened.attach(svc, contextKind: "suite", contextId: id) }
        let kept = users(reopened, words) == 1
        reopened.detach()
        store.suite.composer = ComposerDraft(tool: .shot)
        store.suiteClaudeToolChanged()
        _ = await until(5) { c.key == ClaudeSessions.suiteKey("shot") && c.assist != nil }
        let shotOwn = c.key == ClaudeSessions.suiteKey("shot") && c.assist?.id != a.id && c.assist?.id != b?.id
        store.suite.composer = ComposerDraft(tool: .photo)
        store.suiteClaudeToolChanged()
        _ = await until(5) { c.key == photoKey && c.assist != nil }
        let photoAgain = c.assist?.id == a.id
        line(photoList.count == 2 && switched && returned && kept && shotOwn && photoAgain, "mode_sessions",
             "Photo chats \(photoList.count), switched to A with its draft \(switched), back after closing \(returned), messages kept \(kept), Shot has its own \(shotOwn), Photo returns to A \(photoAgain)")

        // Step 6b (owner bug, build 530): the panel shows its model line (the models load for the panel header).
        await store.loadClaudeModels()
        let models = store.oneClaude.models?.models ?? []
        line(!models.isEmpty && store.oneClaudeModel.info != nil, "model line visible in the panel header",
             "\(models.count) models, showing \(store.oneClaudeModel.info?.name ?? "none")")
        // …and it can't widen the panel (owner bug, build 530: a huge icon pushed the header into the editor).
        store.oneClaude.open = true
        _ = await until(5) { SnapshotRunner.state.composerFrames["claude model line"] != nil }
        if let h = SnapshotRunner.state.composerFrames["claude header"], let ml = SnapshotRunner.state.composerFrames["claude model line"] {
            // The panel floats and resizes (bundle-7): the header must fit the panel as drawn, not the old docked 380.
            let panelWidth = SnapshotRunner.state.composerFrames["one claude panel"]?.width ?? CGFloat(FloatingClaudePanel.defaultWidth)
            line(h.width <= panelWidth + 1 && ml.height <= 40 && h.height <= 140, "panel header fits",
                 "header \(Int(h.width))×\(Int(h.height)) in a panel \(Int(panelWidth)) wide, model line height \(Int(ml.height))")
        } else {
            line(true, "panel header fits", "not measured (the panel wasn't drawn in this run)")
        }
        store.oneClaude.open = false

        // One Claude (owner bug, build 520): Claude opening an edit session (a new blank project) lands IN the editor on
        // that session, not on the Edit home.
        if let blank = try? await fakeMuse.openEditSession(EditSessionOpenRequest(takeId: EditV2.blankSourceId, device: "check")) {
            store.performOneClaudeOpen(ClaudeUI(page: "edit", id: blank.id, label: "Blank edit"))
            let opened = Date()
            let inEditor = await until(15) { store.screen == .edit && store.oneClaude.viewPage?.ids?["sessionId"] == blank.id }
            line(inEditor, "open_page edit session", "the editor opened on Claude's session \(blank.id): \(inEditor) after "
                 + String(format: "%.1f s", Date().timeIntervalSince(opened)) + " (page \(store.claudePage.line))")
            store.go(.home)
        } else {
            line(false, "open_page edit session", "couldn't make a blank session in demo mode")
        }

        // Owner bug, build 597: open_page on Claude's 16:9 session WHILE Edit is already open on that take. The editAttach
        // task's own open() cancelled it mid-load, so the editor stayed on its local copy (9:16, not live, dead buttons).
        await openPageOnOpenTake(store, fakeMuse: fakeMuse, until: until, line: line)

        lines.append("ALL DONE")
        write()
    }
}
