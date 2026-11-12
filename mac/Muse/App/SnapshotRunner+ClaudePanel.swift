import AppKit
import Foundation
import MuseCore
import SwiftUI

// The floating Claude panel with its orb and context strip (coordinator, bundle-8 review: none of the walk's shots showed
// it). On New Swap with a clip and the background/look switched on (so the strip has things to show), the panel open:
//   mac_<theme>_claude_panel_idle.png      the orb at rest, the context strip filled
//   mac_<theme>_claude_panel_thinking.png  the orb as a turn runs (a demo turn start, nothing sent)
// The orb is drawn by Metal (colorEffect), so its pixels are in the screencapture copy (…_sc.png); the view's own
// bitmap shows the panel and strip. Lines go to claude-panel-shots.txt (INFO only: the shots are for people to judge).
extension SnapshotRunner {
    static func claudePanelShots(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        let service = ClaudeCodeService.shared
        var lines: [String] = []
        let wasOpen = store.oneClaude.open
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1280, height: 800), display: true)
            store.suite.feedOpen = false
            store.suite.viewerTakeId = nil
            store.openTool(.swap)
            store.setSwapVariant(.remix)
            store.suite.remix.backgroundOn = true
            store.suite.remix.backgroundMode = .describe
            store.suite.remix.backgroundWords = "A rooftop at golden hour, city lights behind her"
            store.suite.remix.lookOn = true
            store.suite.remix.lookWords = "Warmer, soft window light"
            await store.useSampleClip(bad: false, quiet: true)
            store.oneClaude.open = true
            try? await Task.sleep(for: .seconds(2.5))
            w.contentView?.layoutSubtreeIfNeeded()
            let items = store.claudeContextItems
            let header = state.composerFrames["claude header"].map { "\(Int($0.width))×\(Int($0.height))" } ?? "not drawn"
            lines.append("INFO claude_panel_idle 1280x800 \(theme.rawValue) header \(header), context strip \(items.count) items (\(items.map(\.label).joined(separator: ", "))), orb \(service.orb.state(at: ClaudeCodeService.now).rawValue)")
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_panel_idle.png"))
            // A turn runs: the orb's thinking state (no message is sent; the turn ends right after the shot).
            service.orbTurnStarted()
            service.orbEvent(.text(delta: "…"))
            try? await Task.sleep(for: .seconds(1.2))
            lines.append("INFO claude_panel_thinking 1280x800 \(theme.rawValue) orb \(service.orb.state(at: ClaudeCodeService.now).rawValue)")
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_claude_panel_thinking.png"))
            service.orbEvent(.done(ok: true, error: nil, model: nil))
            try? await Task.sleep(for: .seconds(0.5))
        }
        store.oneClaude.open = wasOpen
        store.setSwapVariant(.classic)
        w.setFrame(full, display: true)
        try? await Task.sleep(for: .seconds(1))
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("claude-panel-shots.txt"), atomically: true, encoding: .utf8)
    }
}
