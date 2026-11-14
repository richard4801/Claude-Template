import AppKit
import MuseCore

// Auto-compact (owner, 2026-11-14: a long Edit chat about a song's captions died with "Prompt is too long · automatic
// compaction failed: API Error: Output blocked by content filtering policy", and every retry failed). Demo mode: FakeClaudeAPI
// and the scripted Claude Code, which answers a message carrying ClaudeDemoScript.chatFullMarker with that very failure
// unless the message opens a fresh session with MUSE's handoff. Lines go into claude-chat-check.txt (CI fails on FAIL):
//   chat full carries on   the turn recovers by itself: one quiet line, Claude's reply, no error, no "Prompt is too long",
//                          and the chat's Claude Code session is now the fresh one (the next message resumes it)
extension SnapshotRunner {
    static func claudeAutoCompactCheck(_ store: AppStore, fakeChat: FakeClaudeAPI,
                                       until: (Double, () -> Bool) async -> Bool, line: (Bool, String, String) -> Void) async {
        let svc = ClaudeCodeService.shared
        let place = "es_compact_check_\(Int(Date().timeIntervalSince1970))"
        let m = ClaudeChatModel()
        await m.attach(svc, contextKind: "edit", contextId: place)
        guard let tid = m.thread?.id else {
            line(false, "chat full carries on", "couldn't open a demo chat")
            return
        }
        _ = try? await fakeChat.setClaudeSession(threadId: tid, claudeSessionId: "demo-session-1")
        _ = try? await svc.loadThread(tid) // the relay learns the (full) session to resume
        m.composer = "Make the chorus captions pink \(ClaudeDemoScript.chatFullMarker)"
        m.send()
        _ = await until(2) { m.busy }
        let finished = await until(30) { !m.busy }
        try? await Task.sleep(for: .seconds(2)) // the reload after the turn
        let items = m.transcript.items
        let notes = items.filter { if case .tool(let id, _, let s, _) = $0 { return id.hasPrefix(ClaudeAutoCompact.freshSpacePrefix) && s == ClaudeAutoCompact.freshSpaceLine }; return false }.count
        let rows = ChatRow.build(items, audience: .owner, unwrap: nil, images: { _ in [] })
        let noteRows = rows.filter { if case .note = $0.kind { return true }; return false }.count
        let replied = items.contains { if case .assistant(_, let t, _) = $0 { return t.contains("Done:") }; return false }
        let leaked = items.contains { if case .assistant(_, let t, _) = $0 { return t.contains("Prompt is too long") }; return false }
        let session = (try? await fakeChat.threadDetail(tid))?.thread.claudeSessionId
        line(finished && notes == 1 && noteRows == 1 && replied && !leaked && m.turnError == nil && session == ClaudeDemoScript.freshSessionId,
             "chat full carries on",
             "finished \(finished), quiet line \(notes) (row \(noteRows)), Claude replied \(replied), raw error shown \(leaked), "
             + "error \(m.turnError ?? "none"), session now \(session ?? "none")")
        m.detach()
    }
}
