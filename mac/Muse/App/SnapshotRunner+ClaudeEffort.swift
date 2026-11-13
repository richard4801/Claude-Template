import AppKit
import MuseCore

// Effort beside the model in the Claude panel (owner, 2026-11-13: "add effort levels for Claude in the app"). Demo mode
// (FakeClaudeAPI and the scripted Claude Code; nothing is spent). Lines go into claude-chat-check.txt (CI fails on FAIL):
//   effort beside the model   drawn right of the model chip on the same row; the header fits the panel at 1000 × 700
//   effort reaches Claude Code  choosing High is sent on the chat's next turn (`--effort high`)
//   effort hidden without support  a model that takes no effort setting shows no effort picker
// Shot: mac_a_claude_effort.png (1000 × 700, panel open).
extension SnapshotRunner {
    static func claudeEffortCheck(_ store: AppStore, fakeChat: FakeClaudeAPI, dir: URL,
                                  until: (Double, () -> Bool) async -> Bool, line: (Bool, String, String) -> Void) async {
        let svc = ClaudeCodeService.shared
        await store.loadClaudeModels()
        guard let thread = try? await fakeChat.newThread(contextKind: "chat", contextId: "ct_effort_check") else {
            line(false, "effort beside the model", "couldn't make a demo chat")
            return
        }
        let savedChats = store.oneClaude.chats, savedChat = store.oneClaude.chatId
        store.oneClaude.chats.insert(ClaudeChatSummary(id: thread.id, title: "Effort check"), at: 0)
        store.pickOneClaudeChat(thread.id)

        // 1. Drawn beside the model, fitting the panel, at 1000 × 700.
        let win = mainWindow
        let original = win?.frame
        if let w = win, let o = original { w.setFrame(NSRect(x: o.minX, y: o.maxY - 700, width: 1000, height: 700), display: true) }
        store.oneClaude.open = true
        _ = await until(8) { SnapshotRunner.state.composerFrames["claude effort line"] != nil && SnapshotRunner.state.composerFrames["claude model line"] != nil }
        try? await Task.sleep(for: .seconds(1))
        let f = SnapshotRunner.state.composerFrames
        if let ml = f["claude model line"], let el = f["claude effort line"], let h = f["claude header"] {
            let panelWidth = f["one claude panel"]?.width ?? CGFloat(FloatingClaudePanel.defaultWidth)
            let beside = el.minX >= ml.maxX - 1 && abs(el.midY - ml.midY) <= 6
            // The header's three buttons (New chat, History, Hide: about 90 pt) still fit right of the effort chip.
            let roomForButtons = el.maxX <= h.maxX - 80
            line(beside && roomForButtons && h.width <= panelWidth + 1 && el.height <= 40, "effort beside the model",
                 "model \(Int(ml.minX))–\(Int(ml.maxX)), effort \(Int(el.minX))–\(Int(el.maxX)) on the same row \(beside), buttons fit \(roomForButtons); header \(Int(h.width)) in a panel \(Int(panelWidth)) wide; showing \(store.oneClaudeEffort.current.map(ClaudeEffort.name) ?? "none")")
        } else {
            line(false, "effort beside the model", "not drawn (model \(f["claude model line"] != nil), effort \(f["claude effort line"] != nil), levels \(store.oneClaudeEffort.levels))")
        }
        capture(dir.appendingPathComponent("mac_a_claude_effort.png"))

        // 2. High is sent on the next turn.
        await store.setOneClaudeEffort("high")
        let before = ClaudeScriptedLauncher.recent.arguments.count
        svc.send(threadId: thread.id, text: "Effort check: say ok.")
        func ours(_ a: [String]) -> Bool { a.contains { $0.contains("/\(thread.id)/") } }
        let launched = await until(15) { ClaudeScriptedLauncher.recent.arguments.dropFirst(before).contains(where: ours) }
        let args = ClaudeScriptedLauncher.recent.arguments.dropFirst(before).last(where: ours) ?? []
        let sent = args.firstIndex(of: "--effort").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        line(launched && sent == "high" && store.oneClaudeEffort.current == "high", "effort reaches Claude Code",
             "turn launched \(launched), --effort \(sent ?? "missing"), the picker shows \(store.oneClaudeEffort.current ?? "none")")
        _ = await until(15) { svc.relayState.running[thread.id] == nil && (svc.relayState.queued[thread.id] ?? 0) == 0 }

        // 3. A model without effort support hides the picker.
        let none = ClaudeModelInfo(id: "claude-no-effort-check", name: "Claude No Effort", speed: "Fast", cost: "Low", good: "Check", efforts: nil, defaultEffort: nil)
        store.oneClaude.models?.models.append(none)
        if let i = store.oneClaude.chats.firstIndex(where: { $0.id == thread.id }) { store.oneClaude.chats[i].model = none.id }
        let hidden = await until(5) { SnapshotRunner.state.composerFrames["claude effort line"] == nil }
        line(hidden && store.oneClaudeEffort.levels.isEmpty && store.oneClaudeEffort.current == nil, "effort hidden without support",
             "picker drawn \(!hidden), levels \(store.oneClaudeEffort.levels)")

        // Leave the panel as it was.
        store.oneClaude.models?.models.removeAll { $0.id == none.id }
        store.oneClaude.open = false
        store.oneClaude.chats = savedChats
        if let c = savedChat { store.pickOneClaudeChat(c) } else { store.oneClaude.chatId = nil }
        if let w = win, let o = original { w.setFrame(o, display: true) }
    }
}
