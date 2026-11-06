import AppKit
import MuseCore
import Observation
import SwiftUI

/// Review screenshots for the owner (Mac CI). Off unless the app is launched with `MUSE_SNAPSHOT_DIR=<folder>`: it then
/// switches to demo mode, signs in as the demo owner, shows each key screen in each theme, writes the window to
/// `<folder>/mac_<theme>_<screen>.png`, and quits. Nothing here runs in a normal launch.
@MainActor
enum SnapshotRunner {
    @Observable @MainActor final class State {
        /// Shown over the current screen: "chat" puts the Claude chat panel up.
        var overlay: String?
    }

    static let state = State()
    static var dir: URL? {
        ProcessInfo.processInfo.environment["MUSE_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runIfRequested(_ store: AppStore) {
        guard let dir else { return }
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let w = mainWindow { w.setContentSize(NSSize(width: 1440, height: 900)); w.center() }
            store.dataSource = .fake
            store.applyDataSource()
            try? await Task.sleep(for: .seconds(1))
            store.authEmail = "you@studio.com"
            store.signIn()
            try? await Task.sleep(for: .seconds(4))
            let shots: [(String, @MainActor () -> Void)] = [
                ("home", { store.go(.home) }),
                ("library", { store.go(.gallery) }),
                ("queue", { store.go(.queue) }),
                ("models", { store.go(.models) }),
                ("cast", { store.openProfile(SampleData.demo) }),
                ("lora", { store.go(.lora) }),
                ("settings", { store.openSettings(.appearance) }),
                ("settings_prompts", { store.openSettings(.prompts) }),
                ("chat", { store.go(.home); state.overlay = "chat" }),
            ]
            for theme in ThemeID.allCases {
                store.themeID = theme
                for (name, show) in shots {
                    state.overlay = nil
                    show()
                    try? await Task.sleep(for: .seconds(2))
                    capture(dir.appendingPathComponent("mac_\(theme.rawValue)_\(name).png"))
                }
            }
            state.overlay = nil
            store.signOut()
            try? await Task.sleep(for: .seconds(1))
            capture(dir.appendingPathComponent("mac_a_signin.png"))
            NSApp.terminate(nil)
        }
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.canBecomeMain } }

    /// Draws the window's content into a PNG. Also asks `screencapture` for the same window (`…_sc.png`), which
    /// includes layer-only content (video, some images) if the runner allows screen capture.
    private static func capture(_ url: URL) {
        guard let window = mainWindow, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        let sc = url.deletingPathExtension().appendingPathExtension("sc.png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), sc.path]
        try? p.run()
        p.waitUntilExit()
    }
}

/// The Claude chat panel as it sits beside a camera session, for the review screenshots only.
struct SnapshotOverlay: View {
    @Environment(\.theme) private var t

    var body: some View {
        if SnapshotRunner.state.overlay == "chat" {
            HStack(spacing: 0) {
                Spacer()
                ClaudeChatView(contextKind: "camera", contextId: "cs_snapshot", title: "Direct with Claude")
                    .frame(width: 420)
                    .background(t.roles.raised)
                    .museFloat(t)
            }
            .padding(.top, 52)
        }
    }
}
