import AppKit
import MuseCore
import SwiftUI

/// "Allow always" check (Mac CI, owner 2026-11-12: "When I give it access to a folder or bash once, it shouldn't ask again.
/// The options should be Allow now or Allow always."). In review mode, through the real one-Claude panel and Settings:
/// a file card offers "Allow always" (the project folder); a command offers "Allow always: shell commands" (the KIND,
/// ci_c64e3cab2c7f); a dangerous one (`…; rm -rf ~`) offers only Allow once and Deny with its one-line why; answering
/// Allow always saves the kind for every chat, and after a relaunch 5 more commands of that kind in a NEW chat (plus reads,
/// uploads and a MUSE tool always allowed once) show 0 cards; "Ask before anything" pauses the list;
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
        check("file_card_covers", f?.alwaysCovers(home: home) == "Allow always covers ~/Movies/MUSE review shoot (reading, writing and uploading) in every chat", f?.alwaysCovers(home: home) ?? "none")
        check("safe_command_card", s?.alwaysLabel == "Allow always: shell commands" && s?.alwaysAsksBecause == nil, "label \(s?.alwaysLabel ?? "none")")
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
        check("rule_saved", st.shellScope == .folders, "shell \(st.shellScope?.rawValue ?? "off")")
        // The command reached the shoot folder (outside the allowed ones): its Always saved that folder too.
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
        let del = service.reviewShowAsk(ask("perm_review_rm", "Bash", ["command": .string("rm -rf '\(shoot.path)/old'")]), threadId: tid)
        if case .ask(let c) = del { check("delete_asks", c.alwaysLabel == nil) } else { check("delete_asks", false, "\(del)") }
        // Another program is the same kind now (the old per-program rules asked again here).
        let probe = service.reviewShowAsk(ask("perm_review_probe", "Bash", ["command": .string("ffprobe '\(out)'")]), threadId: tid)
        check("same_kind_runs", probe == .allow, "\(probe)")
        let again = service.reviewShowAsk(ask("perm_review_again", "Bash", ["command": .string(badCmd)]), threadId: tid)
        if case .ask(let c) = again { check("dangerous_asks_again", c.alwaysLabel == nil) } else { check("dangerous_asks_again", false, "\(again)") }
        let write = service.reviewShowAsk(ask("perm_review_write", "Write", ["file_path": .string(home + "/Documents/MUSE review.txt")]), threadId: tid)
        if case .ask = write { check("write_outside_asks", true) } else { check("write_outside_asks", false, "\(write)") }

        note("START kinds_across_chats")
        // A MUSE tool Claude Code asked about: Allow always by name.
        let toolAsk = ask("perm_review_tool", "mcp__muse__suite_add_reference", ["uploadId": .string("up_review")])
        _ = service.reviewShowAsk(toolAsk, threadId: tid)
        check("tool_card", card(toolAsk.id)?.alwaysLabel == "Allow always: suite_add_reference", card(toolAsk.id)?.alwaysLabel ?? "none")
        service.answerFile(toolAsk.id, .always)
        check("tool_saved", service.fileSettings.tools == ["mcp__muse__suite_add_reference"], "\(service.fileSettings.tools)")
        // A relaunch: the list goes through JSON and back (as stored in the app's defaults), then a NEW chat.
        if let d = try? JSONEncoder().encode(service.fileSettings), let back = try? JSONDecoder().decode(ClaudeFileSettings.self, from: d) {
            check("survives_relaunch", back == service.fileSettings)
            service.reviewSetFileSettings(back)
        } else { check("survives_relaunch", false, "couldn't encode the list") }
        let newChat = "review_new_chat_\(UUID().uuidString.prefix(6))"
        let tmp = "/tmp/muse_review_\(newChat)"
        let more: [ClaudePermissionAsk] = [
            ask("perm_review_m1", "Bash", ["command": .string("mkdir -p \(tmp) && ffmpeg -y -i '\(clip)' -t 1 \(tmp)/a.mp4 2>&1 | tail -n 5")]),
            ask("perm_review_m2", "Bash", ["command": .string("cd '\(shoot.path)' && for f in *.mp4; do ffprobe -v error \"$f\"; done")]),
            ask("perm_review_m3", "Bash", ["command": .string("python3 -c \"print(open('\(tmp)/a.mp4','rb').read(4))\"")]),
            ask("perm_review_m4", "Bash", ["command": .string("sips -g pixelWidth '\(shoot.path)/still.png' > \(tmp)/w.txt")]),
            ask("perm_review_m5", "Bash", ["command": .string("ls -la \(tmp) '\(shoot.path)' | wc -l")]),
            ask("perm_review_m6", "Read", ["file_path": .string("\(shoot.path)/sub/still.png")]),
            ask("perm_review_m7", "Read", ["file_path": .string("\(tmp)/w.txt")]),
            ask("perm_review_m8", "Upload", ["file_path": .string("\(shoot.path)/still.png"), "purpose": .string("reference")]),
            ask("perm_review_m9", "mcp__muse__suite_add_reference", ["uploadId": .string("up_review_2")]),
        ]
        var prompts: [String] = []
        for a in more {
            let v = service.reviewShowAsk(a, threadId: newChat)
            if v != .allow { prompts.append("\(a.id): \(v)") }
        }
        check("five_more_across_a_new_chat_ask_nothing", prompts.isEmpty, "\(prompts.count) prompts: \(prompts)")
        for a in service.fileAsks(threadId: newChat) { service.answerFile(a.id, .deny) }

        note("START ask_before_anything")
        service.setAskEverything(true)
        let paused = service.reviewShowAsk(ask("perm_review_paused", "Bash", ["command": .string("ffmpeg -i '\(clip)' '\(out)'")]), threadId: tid)
        if case .ask(let c) = paused { check("ask_all_asks", c.alwaysLabel == nil && c.alwaysAsksBecause == "You chose Ask before anything (Settings → Claude)") }
        else { check("ask_all_asks", false, "\(paused)") }
        check("ask_all_keeps_the_list", service.fileSettings.shellScope == .folders && !service.fileSettings.tools.isEmpty)
        service.setAskEverything(false)
        for a in service.fileAsks(threadId: tid) { service.answerFile(a.id, .deny) }

        note("START settings")
        store.oneClaude.open = false
        store.openSettings(.account)
        try? await Task.sleep(for: .seconds(1.0))
        // The Claude section sits below Appearance and Notifications: bring it on screen before reading the texts.
        SnapshotRunner.state.scrollTo = "settings.claude"
        try? await Task.sleep(for: .seconds(1.0))
        check("settings_lists", service.fileSettings.allowedFolders == [shoot.path] && service.fileSettings.shellScope == .folders
              && service.fileSettings.tools == ["mcp__muse__suite_add_reference"],
              "folders \(service.fileSettings.allowedFolders), shell \(service.fileSettings.shellScope?.rawValue ?? "off"), tools \(service.fileSettings.tools)")
        // SwiftUI exposes only the pickers' values to accessibility here (run 629: 9 texts), so the rows report where they
        // were drawn (review-only frame probes) and each must sit inside the window.
        SnapshotRunner.state.probeTick += 1
        try? await Task.sleep(for: .seconds(0.5))
        let frames = SnapshotRunner.state.composerFrames
        let height = mainWindow?.contentView?.bounds.height ?? 0
        func shown(_ key: String) -> (Bool, String) {
            guard let f = frames[key] else { return (false, "not drawn") }
            return (f.height > 0 && f.minY >= 0 && f.maxY <= height, "at y \(Int(f.minY))–\(Int(f.maxY)) in a window \(Int(height)) high")
        }
        let heading = shown("settings always allowed"), rule = shown("settings shell commands"), toggle = shown("settings ask before anything")
        let toolRow = shown("settings tool suite_add_reference")
        check("settings_shows_always_allowed", heading.0, "the Always allowed heading \(heading.1)")
        check("settings_shows_rule", rule.0, "the Shell commands row \(rule.1); rows drawn \(frames.keys.filter { $0.hasPrefix("settings ") }.sorted())")
        check("settings_shows_tool", toolRow.0, "the suite_add_reference row \(toolRow.1)")
        check("settings_shows_switch", toggle.0, "the Ask before anything row \(toggle.1)")
        capture(dir.appendingPathComponent("mac_a_claude_allow_settings.png"))
        SnapshotRunner.state.scrollTo = nil
        service.removeShellCommands()
        service.removeAlwaysTool("mcp__muse__suite_add_reference")
        service.removeAllowedFolder(shoot.path)
        check("settings_remove", service.fileSettings.shellScope == nil && service.fileSettings.tools.isEmpty && service.fileSettings.allowedFolders.isEmpty)
        // Removed: the same command asks again.
        let after = service.reviewShowAsk(ask("perm_review_after", "Bash", ["command": .string("ffmpeg -i '\(clip)' '\(out)'")]), threadId: tid)
        if case .ask = after { check("asks_again_after_remove", true) } else { check("asks_again_after_remove", false, "\(after)") }
        for a in service.fileAsks(threadId: tid) { service.answerFile(a.id, .deny) }

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
            guard depth < 160, count < 40_000 else { return }
            for v in [o.accessibilityLabel(), o.accessibilityTitle(), o.accessibilityValue() as? String] { if let v, !v.isEmpty { out.append(v) } }
            if let a = o.accessibilityValue() as? NSAttributedString, !a.string.isEmpty { out.append(a.string) }
            for c in o.accessibilityChildren() ?? [] { if let a = c as? NSAccessibilityProtocol { walk(a, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        return out
    }
}
