import AppKit
import MuseCore
import SwiftUI

/// "Allow always" check (Mac CI, owner 2026-11-12: "When I give it access to a folder or bash once, it shouldn't ask again.
/// The options should be Allow now or Allow always."). In review mode, through the real one-Claude panel and Settings:
/// a file card offers "Allow always"; a safe command offers "Allow always: ffmpeg commands"; a dangerous one
/// (`…; rm -rf ~`) offers only Allow once and Deny with its one-line why; answering Allow always saves the folder or the
/// rule for every chat, and the next matching command runs without a card; "Ask before anything" pauses the list;
/// Settings shows the list; old per-chat folders move to it. Shots `mac_a_claude_allow_*.png`. Writes
/// `claude-allow-check.txt`; CI fails on any FAIL line or a missing ALL DONE. Nothing here runs: the questions are made up
/// and their answers go nowhere.
extension SnapshotRunner {
    static func claudeAllowCheck(_ store: AppStore, dir: URL) async {
        let log = dir.appendingPathComponent("claude-allow-check.txt")
        try? Data().write(to: log)
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("claude-allow-check: \(s)")
        }
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            note(ok ? "DONE \(name)" : "FAIL \(name)\(detail().isEmpty ? "" : ": \(detail())")")
        }
        func wait(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
            return ok()
        }
        let service = ClaudeCodeService.shared
        _ = await wait(15) { service.configured }
        let saved = service.fileSettings
        defer { service.reviewSetFileSettings(saved) }
        service.reviewSetFileSettings(ClaudeFileSettings())

        // Real files, so folder arguments and the script are read from the disk like on the owner's Mac.
        let home = NSHomeDirectory()
        let shoot = URL(fileURLWithPath: home).appendingPathComponent("Movies/MUSE review shoot", isDirectory: true)
        try? FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let clip = shoot.appendingPathComponent("a.mp4").path
        let out = shoot.appendingPathComponent("b.mp4").path
        try? Data("x".utf8).write(to: URL(fileURLWithPath: clip))

        // A clean start (bundle-10 run 617: Recreate and the One Claude panel left open by earlier walks made the page
        // "recreate" and showOneClaude a no-op).
        store.closeRecreate()
        store.oneClaude.open = false
        state.overlay = nil
        store.themeID = .a
        store.go(.home)
        store.showOneClaude()
        if !(await wait(10) { store.oneClaude.chatId != nil }) { await store.startOneClaude() }
        guard let chat = store.oneClaude.chatId, let tid = (try? await service.openThread(contextKind: "chat", contextId: chat))?.thread.id else {
            note("FAIL setup: the one-Claude chat didn't open"); note("ALL DONE"); return
        }
        func ask(_ id: String, _ tool: String, _ input: [String: JSONValue]) -> ClaudePermissionAsk {
            ClaudePermissionAsk(id: id, toolName: tool, input: .object(input), toolUseId: "toolu_review_\(id)")
        }
        func card(_ id: String) -> ClaudeFileCard? { service.fileAsks(threadId: tid).first { $0.id == id }?.card }

        note("START cards")
        let fileAsk = ask("perm_review_file", "Read", ["file_path": .string(clip)])
        let safeCmd = "ffmpeg -i '\(clip)' -c:v libx264 -vf scale=1080:-2 '\(out)'"
        let safeAsk = ask("perm_review_safe", "Bash", ["command": .string(safeCmd)])
        let badCmd = "ffmpeg -i a.mp4 out.mp4; rm -rf ~"
        let badAsk = ask("perm_review_bad", "Bash", ["command": .string(badCmd)])
        for a in [fileAsk, safeAsk, badAsk] { _ = service.reviewShowAsk(a, threadId: tid) }

        let f = card(fileAsk.id), s = card(safeAsk.id), b = card(badAsk.id)
        check("file_card", f?.alwaysLabel == "Allow always" && f?.folder == shoot.path, "label \(f?.alwaysLabel ?? "none"), folder \(f?.folder ?? "none")")
        check("file_card_covers", f?.alwaysCovers(home: home) == "Allow always covers ~/Movies/MUSE review shoot in every chat", f?.alwaysCovers(home: home) ?? "none")
        check("safe_command_card", s?.alwaysLabel == "Allow always: ffmpeg commands" && s?.alwaysAsksBecause == nil, "label \(s?.alwaysLabel ?? "none")")
        check("dangerous_command_card", b != nil && b?.alwaysLabel == nil && b?.alwaysAsksBecause == "Always asks: it deletes files",
              "label \(b?.alwaysLabel ?? "none"), why \(b?.alwaysAsksBecause ?? "none")")
        check("cards_in_the_chat", service.fileAsks(threadId: tid).count == 3, "\(service.fileAsks(threadId: tid).count) cards")
        try? await Task.sleep(for: .seconds(1))
        capture(dir.appendingPathComponent("mac_a_claude_allow_cards.png"))
        // Each card alone, at the panel's narrowest width.
        for (name, c) in [("file", f), ("safe", s), ("dangerous", b)] {
            guard let c else { continue }
            let r = ImageRenderer(content: ClaudeFileCardView(card: c, id: "shot", answer: { _ in })
                .frame(width: 300).padding(8).background(Color(nsColor: .windowBackgroundColor)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("mac_a_claude_allow_card_\(name).png"))
            } else { note("FAIL card_shot_\(name): couldn't draw the card") }
        }

        note("START allow_always")
        service.answerFile(safeAsk.id, .always)
        let st = service.fileSettings
        check("rule_saved", st.rules.contains(ClaudeCommandRule(program: "ffmpeg")), "rules \(st.rules.map(\.id))")
        check("folder_saved_with_rule", st.allowedFolders.contains(shoot.path), "folders \(st.allowedFolders)")
        // The file card in that folder is now covered: it went through by itself.
        check("covered_card_went_through", card(fileAsk.id) == nil, "the file card is still open")
        check("dangerous_card_still_open", card(badAsk.id) != nil && card(badAsk.id)?.alwaysLabel == nil)
        // The next ffmpeg command in that folder runs without a card; another kind still asks.
        let next = service.reviewShowAsk(ask("perm_review_next", "Bash", ["command": .string("ffmpeg -y -i '\(out)' -t 2 '\(shoot.path)/c.mp4'")]), threadId: tid)
        check("next_ffmpeg_runs", next == .allow, "\(next)")
        // Claude Code's usual shape: cd into the folder, then a pipe into tail.
        let piped = service.reviewShowAsk(ask("perm_review_piped", "Bash", ["command": .string("cd '\(shoot.path)' && ffmpeg -y -i b.mp4 -t 1 d.mp4 2>&1 | tail -n 40")]), threadId: tid)
        check("cd_and_tail_runs", piped == .allow, "\(piped)")
        let toShell = service.reviewShowAsk(ask("perm_review_sh", "Bash", ["command": .string("ffmpeg -i '\(out)' -f wav - | sh")]), threadId: tid)
        if case .ask(let c) = toShell { check("pipe_to_shell_asks", c.alwaysLabel == nil) } else { check("pipe_to_shell_asks", false, "\(toShell)") }
        let probe = service.reviewShowAsk(ask("perm_review_probe", "Bash", ["command": .string("ffprobe '\(out)'")]), threadId: tid)
        if case .ask(let c) = probe { check("other_kind_asks", c.alwaysLabel == "Allow always: ffprobe commands", c.alwaysLabel ?? "none") }
        else { check("other_kind_asks", false, "\(probe)") }
        let again = service.reviewShowAsk(ask("perm_review_again", "Bash", ["command": .string(badCmd)]), threadId: tid)
        if case .ask(let c) = again { check("dangerous_asks_again", c.alwaysLabel == nil) } else { check("dangerous_asks_again", false, "\(again)") }
        let write = service.reviewShowAsk(ask("perm_review_write", "Write", ["file_path": .string(home + "/Documents/MUSE review.txt")]), threadId: tid)
        if case .ask = write { check("write_outside_asks", true) } else { check("write_outside_asks", false, "\(write)") }

        note("START ask_before_anything")
        service.setAskEverything(true)
        let paused = service.reviewShowAsk(ask("perm_review_paused", "Bash", ["command": .string("ffmpeg -i '\(clip)' '\(out)'")]), threadId: tid)
        if case .ask(let c) = paused { check("ask_all_asks", c.alwaysLabel == nil && c.alwaysAsksBecause == "You chose Ask before anything (Settings → Claude)") }
        else { check("ask_all_asks", false, "\(paused)") }
        check("ask_all_keeps_the_list", service.fileSettings.rules.contains(ClaudeCommandRule(program: "ffmpeg")))
        service.setAskEverything(false)
        for a in service.fileAsks(threadId: tid) { service.answerFile(a.id, .deny) }

        note("START settings")
        store.oneClaude.open = false
        store.openSettings(.account)
        try? await Task.sleep(for: .seconds(1.0))
        // The Claude section sits below Appearance and Notifications: bring it on screen before reading the texts.
        SnapshotRunner.state.scrollTo = "settings.claude"
        try? await Task.sleep(for: .seconds(1.0))
        check("settings_lists", service.fileSettings.allowedFolders == [shoot.path] && service.fileSettings.rules.map(\.id) == ["ffmpeg"],
              "folders \(service.fileSettings.allowedFolders), rules \(service.fileSettings.rules.map(\.id))")
        let win = mainWindow?.contentView
        let texts = win.map(Self.accessibilityTexts) ?? []
        check("settings_shows_always_allowed", texts.contains { $0.contains("Always allowed") }, "no Always allowed heading on screen")
        check("settings_shows_rule", texts.contains("ffmpeg commands"), "rows \(texts.filter { $0.contains("ommands") })")
        check("settings_shows_switch", texts.contains("Ask before anything"))
        capture(dir.appendingPathComponent("mac_a_claude_allow_settings.png"))
        SnapshotRunner.state.scrollTo = nil
        service.removeCommandRule("ffmpeg")
        service.removeAllowedFolder(shoot.path)
        check("settings_remove", service.fileSettings.rules.isEmpty && service.fileSettings.allowedFolders.isEmpty)

        note("START migrate")
        let old = ClaudeFileSettings(mode: .ask, folders: [ClaudeAllowedFolder(folder: shoot.path, chatId: "ct_a", chatTitle: "A"),
                                                            ClaudeAllowedFolder(folder: shoot.path, chatId: "ct_b"),
                                                            ClaudeAllowedFolder(folder: home, chatId: "ct_c")])
        let m = old.migrated(home: home)
        check("migrate", m.allowedFolders == [shoot.path] && m.folders.isEmpty, "folders \(m.allowedFolders)")

        store.go(.home)
        try? FileManager.default.removeItem(at: shoot)
        try? await Task.sleep(for: .seconds(0.5))
        note("ALL DONE")
    }

    /// Every label, title and text value the window shows to accessibility, for checking what's on screen.
    static func accessibilityTexts(_ root: NSView) -> [String] {
        var out: [String] = []
        var count = 0
        func walk(_ o: NSAccessibilityProtocol, depth: Int) {
            count += 1
            guard depth < 60, count < 20_000 else { return }
            for v in [o.accessibilityLabel(), o.accessibilityTitle(), o.accessibilityValue() as? String] { if let v, !v.isEmpty { out.append(v) } }
            if let a = o.accessibilityValue() as? NSAttributedString, !a.string.isEmpty { out.append(a.string) }
            for c in o.accessibilityChildren() ?? [] { if let a = c as? NSAccessibilityProtocol { walk(a, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        return out
    }
}
