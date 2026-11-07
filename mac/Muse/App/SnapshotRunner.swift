import AppKit
import MuseCore
import Observation
import SwiftUI

/// Review screenshots for the owner (Mac CI). Off unless the app is launched with `MUSE_SNAPSHOT_DIR=<folder>`: it then
/// switches to demo mode, signs in as the demo owner, shows each key screen in each theme, writes the window to
/// `<folder>/mac_<theme>_<screen>.png`, and quits. The composer screens are also shot in a 1000 × 800 window
/// (`mac_<theme>_<screen>_1000.png`), the narrow layout of plans/design-direction/composer-mac-1000-b.png. Nothing here
/// runs in a normal launch.
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
            if let w = mainWindow {
                // 1440 × 900, or the screen's visible area when it is smaller (CI runners have small screens).
                let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                w.setFrame(NSRect(x: vis.minX, y: vis.maxY - min(900, vis.height), width: min(1440, vis.width), height: min(900, vis.height)), display: true)
            }
            store.dataSource = .fake
            store.applyDataSource()
            try? await Task.sleep(for: .seconds(1))
            store.authEmail = "you@studio.com"
            store.signIn()
            try? await Task.sleep(for: .seconds(4))
            // The composer screens need the suite's catalog (the demo draft picks its camera, light and look from it).
            await store.loadSuite()
            let shots: [(String, @MainActor () -> Void)] = [
                ("home", { store.go(.home) }),
                ("library", { store.go(.gallery) }),
                ("queue", { store.go(.queue) }),
                ("models", { store.go(.models) }),
                ("cast", { store.openProfile(SampleData.demo) }),
                ("lora", { store.go(.lora) }),
                ("settings", { store.openSettings(.appearance) }),
                ("settings_prompts", { store.openSettings(.prompts) }),
                ("settings_studio", { store.openSettings(.studio) }),
                ("credits", { store.go(.credits) }),
                ("members", { store.go(.members) }),
                ("chat", { store.go(.home); state.overlay = "chat" }),
                // The composer as the approved render (Shot with a filled demo draft), the Photo tool, and Camera → Setup.
                ("composer", { store.openTool(.shot); fillDemoDraft(store) }),
                ("composer_photo", { store.openPhoto(model: SampleData.demo) }),
                ("camera_setup", { store.openTool(.shot); fillDemoDraft(store); store.openPicker(.camera, step: "setup") }),
            ]
            /// Also shot at 1000 × 800.
            let narrow: Set<String> = ["composer", "composer_photo", "camera_setup"]
            for theme in ThemeID.allCases {
                store.themeID = theme
                for (name, show) in shots {
                    state.overlay = nil
                    store.suite.picker = nil
                    store.suite.browserOpen = false
                    show()
                    try? await Task.sleep(for: .seconds(2))
                    capture(dir.appendingPathComponent("mac_\(theme.rawValue)_\(name).png"))
                    if narrow.contains(name), let w = mainWindow {
                        let full = w.frame
                        // Keep the top-left corner where it is; AppKit's frame origin is the bottom-left.
                        w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1000, height: 800), display: true)
                        try? await Task.sleep(for: .seconds(1.5))
                        capture(dir.appendingPathComponent("mac_\(theme.rawValue)_\(name)_1000.png"))
                        w.setFrame(full, display: true)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
            store.suite.picker = nil
            state.overlay = nil
            store.signOut()
            try? await Task.sleep(for: .seconds(1))
            capture(dir.appendingPathComponent("mac_a_signin.png"))
            NSApp.terminate(nil)
        }
    }

    /// The render's draft (design/direction/render.py `composer_mac`): @Demo in a café, 16:9, 8 s, 35 mm film with an
    /// anamorphic lens, window light, Golden warmth, UGC · Calm, and a #Dolly in. Options the catalog doesn't have stay Auto.
    private static func fillDemoDraft(_ store: AppStore) {
        let cam = store.suite.camera
        func pick(_ list: [SuiteOption], _ words: [String]) -> String? {
            list.first { o in words.allSatisfy { o.label.localizedCaseInsensitiveContains($0) } }?.id
        }
        var d = store.suite.composer
        d.collapsed = nil
        d.directed = nil
        d.aspect = "16:9"
        d.duration = 8
        d.settings.body = pick(cam.bodies, ["35", "film"])
        d.settings.lens = pick(cam.lenses, ["anamorphic"])
        d.settings.lighting = pick(cam.lighting, ["window"])
        d.settings.palette = pick(cam.palettes, ["golden"])
        d.settings.genre = pick(cam.genres, ["ugc"])
        d.settings.tempo = pick(cam.tempos, ["calm"])
        var tokens = PromptTokens.text(" walks into a quiet café at golden hour, orders at the counter, then turns to camera with a soft smile. ")
        if let move = cam.move("dolly_in") { tokens = tokens.addMove(move, catalog: cam).0 }
        d.tokens = tokens
        store.suite.composer = d
        // The character goes in front of the text, with her first outfit.
        store.setComposerCharacter(store.character(SampleData.demo))
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
