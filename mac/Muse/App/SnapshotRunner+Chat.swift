import AppKit
import MuseCore
import SwiftUI

// Claude chat review (plans/claude-chat-mac.md): every Mac surface that has the chat (Camera, Suite, Recreate, Edit) with
// the sample thread, in the four themes, plus the chat's fit check: the composer grows with the text up to 8 lines, then
// scrolls; it stays on screen down to 960 × 600; long messages wrap inside the panel. Lines go to fit-check.txt (CUT
// fails Mac CI). Demo mode only: nothing is sent, spent or deleted.
extension SnapshotRunner {
    static func chatShots(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        defer {
            let f = dir.appendingPathComponent("fit-check.txt")
            let before = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? (before + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: f, atomically: true, encoding: .utf8)
            state.chatSample = false
            state.chatStreaming = false
            state.chatComposerText = nil
            state.chatAttach = false
            state.overlay = nil
        }
        guard let w = mainWindow else {
            lines.append("CUT chat not drawn (no window)")
            return
        }
        let original = w.frame
        func size(_ width: Int, _ height: Int) {
            w.setFrame(NSRect(x: original.minX, y: original.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
        }
        func reset() {
            state.overlay = nil
            state.chatStreaming = false
            state.chatComposerText = nil
            state.chatAttach = false
            store.suite.claude.open = false
            store.recreate.closeClaude()
            store.closeRecreate()
            state.claudeTab = nil
        }

        // The editor's Claude panel needs a video take: editCheck's 15 s take (its MP4 stays in the temporary folder).
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        var take: Take?
        if FileManager.default.fileExists(atPath: long.path) {
            let raw: [String: Any] = ["id": "rx_chat", "kind": "take", "title": "Living room dance", "videoUrl": long.absoluteString,
                                      "durationSec": 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
            if let data = try? JSONSerialization.data(withJSONObject: raw) { take = try? JSONDecoder().decode(Take.self, from: data) }
        }
        if let take {
            store.takes.removeAll { $0.id == take.id }
            store.takes.insert(take, at: 0)
        }
        defer { store.takes.removeAll { $0.id == "rx_chat" } }

        state.chatSample = true
        for theme in [ThemeID.c, .a, .b, .d] {
            NSLog("[snapshot] chat %@", theme.rawValue)
            store.themeID = theme
            size(1280, 800)
            reset()
            store.openEdit(takeId: nil)

            NSLog("[snapshot] chat camera %@", theme.rawValue)
            // Camera: Direct with Claude, beside the stage (the chat panel as it sits in Camera).
            store.go(.home)
            state.overlay = "chat"
            try? await Task.sleep(for: .seconds(2.5))
            lines.append(drawnLine("claude_camera", theme, needsReply: true))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_camera.png"))
            // …mid-reply: a tool step running, bold text still arriving, Stop in place of Send.
            NSLog("[snapshot] chat camera streaming %@", theme.rawValue)
            state.chatStreaming = true
            try? await Task.sleep(for: .seconds(1.5))
            NSLog("[snapshot] chat camera streaming capture %@", theme.rawValue)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_camera_streaming.png"))
            // …a long message typed (the field at its 8-line height, then scrolling) and two images waiting to go.
            NSLog("[snapshot] chat camera composer %@", theme.rawValue)
            state.chatStreaming = false
            state.chatComposerText = longDraft
            state.chatAttach = true
            try? await Task.sleep(for: .seconds(1.5))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_camera_composer.png"))
            state.chatComposerText = nil
            state.chatAttach = false
            state.overlay = nil

            NSLog("[snapshot] chat recreate %@", theme.rawValue)
            // Recreate: Claude beside the Recipe (Recreate opens from the editor, as recreateShots does).
            store.openEdit(takeId: nil)
            store.openRecreate()
            try? await Task.sleep(for: .seconds(1))
            let refs = (try? await store.recreateAPI.listReferences()) ?? []
            if let ref = refs.first(where: { $0.id == "rx_demo" }) ?? refs.first(where: { $0.recipe != nil }) {
                await store.openRecreateReference(ref.id)
                store.toggleRecreateClaude()
                try? await Task.sleep(for: .seconds(2.5))
                lines.append(drawnLine("claude_recreate", theme, needsReply: true))
                capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_recreate.png"))
                store.recreate.closeClaude()
                store.leaveRecreateReference()
            } else {
                lines.append("CUT claude_recreate 1280x800 \(theme.rawValue) no demo reference")
            }
            store.closeRecreate()

            NSLog("[snapshot] chat edit %@", theme.rawValue)
            // Edit: the editor's Claude panel on its Chat tab.
            if let take {
                state.claudeTab = 0
                store.openEdit(takeId: take.id)
                try? await Task.sleep(for: .seconds(7))
                lines.append(drawnLine("claude_edit", theme, needsReply: true))
                capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_edit.png"))
                state.claudeTab = nil
                store.openEdit(takeId: nil)
                try? await Task.sleep(for: .seconds(1))
            } else {
                lines.append("CUT claude_edit 1280x800 \(theme.rawValue) no test video")
            }

            NSLog("[snapshot] chat suite %@", theme.rawValue)
            // The AI Suite: Claude's panel in the picture's place (demo mode: the stand-in chat, same rows and composer).
            store.openTool(.shot)
            fillDemoDraft(store)
            store.showSuiteClaudeForReview()
            try? await Task.sleep(for: .seconds(2.5))
            lines.append(drawnLine("claude_suite", theme, needsReply: true))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_suite.png"))
            // The demo reply finishes on its own (the first time slowly): wait for it, so it can't pull the next shots
            // back to the Suite.
            for _ in 0..<40 where store.suite.claude.demoBusy { try? await Task.sleep(for: .seconds(0.25)) }
            store.suite.claude.open = false
        }

        // Fit: the composer grows with the text, stops at 8 lines, and stays on screen with long messages above it.
        store.themeID = .c
        store.go(.home)
        state.overlay = "chat"
        let font = Fonts.nsFont(TypeScale.of(.c).textFamily, TypeScale.of(.c).body.size, .regular) ?? NSFont.systemFont(ofSize: 15)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        for (width, height) in [(1440, 900), (1280, 800), (1000, 700), (960, 600)] {
            size(width, height)
            var heights: [Int: CGFloat] = [:]
            for n in [1, 4, 12] {
                NSLog("[snapshot] chat composer %dx%d %d lines", width, height, n)
                state.chatComposerText = (1...n).map { "Line \($0) of the shot notes" }.joined(separator: "\n")
                try? await Task.sleep(for: .seconds(1.2))
                state.probeTick += 1
                try? await Task.sleep(for: .seconds(0.3))
                w.contentView?.layoutSubtreeIfNeeded()
                let content = w.contentView?.bounds.size ?? .zero
                let label = "chat_composer \(width)x\(height) c \(n) line\(n == 1 ? "" : "s")"
                guard let field = state.composerFrames["chat field"], let bar = state.composerFrames["chat composer"] else {
                    lines.append("CUT \(label) composer not drawn")
                    continue
                }
                heights[n] = field.height
                let inside = bar.minY >= 0 && bar.maxY <= content.height + 0.5 && bar.maxX <= content.width + 0.5
                lines.append("\(inside ? "FITS" : "CUT") \(label) field \(Int(field.height)) pt, bar \(Int(bar.minX)),\(Int(bar.minY)) \(Int(bar.width))x\(Int(bar.height)) in \(Int(content.width))x\(Int(content.height))")
                if n == 12 {
                    // Long messages: every bubble and reply sits inside the chat's width (they wrap, never run off).
                    let rows = state.composerFrames.filter { $0.key.hasPrefix("chat bubble") || $0.key.hasPrefix("chat reply") }
                    let wide = rows.filter { $0.value.maxX > bar.maxX + 0.5 || $0.value.minX < bar.minX - 0.5 }
                    lines.append("\(wide.isEmpty && !rows.isEmpty ? "FITS" : "CUT") chat_long \(width)x\(height) c \(rows.count) messages inside the panel\(wide.isEmpty ? "" : ": " + wide.keys.sorted().joined(separator: ", "))")
                }
                capture(dir.appendingPathComponent("mac_c_chat_composer_\(n)_\(width)x\(height).png"))
            }
            if let h1 = heights[1], let h4 = heights[4], let h12 = heights[12] {
                let grows = h4 >= h1 + line * 2.5
                // The field: 8 lines, the text view's insets (12) and the field's own padding (8).
                let cap = line * 8 + 20
                let capped = h12 <= cap + 2 && h12 >= h4
                lines.append("\(grows ? "FITS" : "CUT") chat_composer_grows \(width)x\(height) c 1 line \(Int(h1)) pt, 4 lines \(Int(h4)) pt (line \(String(format: "%.1f", line)) pt)")
                lines.append("\(capped ? "FITS" : "CUT") chat_composer_caps \(width)x\(height) c 12 lines \(Int(h12)) pt, at most 8 lines (\(Int(cap)) pt), then it scrolls")
            }
        }
        state.chatComposerText = nil
        state.overlay = nil
        size(Int(original.width), Int(original.height))
        w.setFrame(original, display: true)
        store.themeID = .a
    }

    /// The chat is up with its rows: a reply drawn (the sample's markdown), else CUT.
    private static func drawnLine(_ screen: String, _ theme: ThemeID, needsReply: Bool) -> String {
        mainWindow?.contentView?.layoutSubtreeIfNeeded()
        let replies = state.composerFrames.keys.filter { $0.hasPrefix("chat reply") }.count
        let bubbles = state.composerFrames.keys.filter { $0.hasPrefix("chat bubble") }.count
        let composer = state.composerFrames["chat composer"] != nil
        let ok = composer && (!needsReply || replies > 0)
        return "\(ok ? "FITS" : "CUT") \(screen) 1280x800 \(theme.rawValue) composer \(composer ? "drawn" : "not drawn"), \(replies) replies, \(bubbles) bubbles"
    }

    static let longDraft = (1...12).map { "Line \($0): the camera stays low, she crosses to the window and turns on the beat." }.joined(separator: "\n")
}
