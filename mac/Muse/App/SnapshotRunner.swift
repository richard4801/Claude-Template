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
        /// Settings scrolls to this anchor (a view `.id`), for the scrolled shots.
        var scrollTo: String?
        /// Generate's frame in the window (SwiftUI global space, top-left origin), for the composer fit check.
        var generateFrame: CGRect?
        /// The cinematic Suite shows its empty state (the demo studio already has takes).
        var cinemaEmpty = false
        /// Bumped by the fit check after each screen change: Generate's probe reports its frame again.
        var probeTick = 0
        /// The rig panel's view is on screen (its onAppear / onDisappear), for the same-tick diagnosis.
        var rigPanelOnScreen = false
    }

    /// The last CinemaSuiteView body: did it see the picker open, and when (not observed: a plain static).
    static var suiteBodySawPicker = false
    static var suiteBodyCount = 0
    static func noteSuiteBody(pickerOpen: Bool) {
        guard dir != nil else { return }
        suiteBodySawPicker = pickerOpen
        suiteBodyCount += 1
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
                ("settings_connections", { store.openSettings(.connections) }),
                // Before (prod fffebeb): Connections as the sheet it used to be, over Settings.
                ("settings_connections_before", { store.openSettings(.appearance); state.overlay = "connections_before" }),
                ("settings_connections_scrolled", { store.openSettings(.connections); Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1)); state.scrollTo = "connections.blender" } }),
                ("credits", { store.go(.credits) }),
                ("members", { store.go(.members) }),
                ("chat", { store.go(.home); state.overlay = "chat" }),
                // The composer as the approved render (Shot with a filled demo draft), the Photo tool, and Camera → Setup.
                ("composer", { store.openTool(.shot); fillDemoDraft(store) }),
                ("composer_photo", { store.openPhoto(model: SampleData.demo) }),
                ("camera_setup", { store.openTool(.shot); fillDemoDraft(store); store.openPicker(.camera, step: "setup") }),
                // Owner decision 2026-11-08: the title's mode menu (after) and the big browser it replaced (before); a preset
                // picked, then the prompt backspaced to empty (the preset lets go, the composer is the normal one again).
                ("composer_menu", { store.openTool(.shot); fillDemoDraft(store); store.suite.browserOpen = true }),
                ("composer_tools_before", { store.openTool(.shot); fillDemoDraft(store); state.overlay = "tools_before" }),
                ("composer_preset", { store.openTool(.shot); fillDemoDraft(store)
                    if let p = store.suite.camera.presets.first { store.applyPreset(p) } }),
                ("composer_preset_cleared", { store.openTool(.shot); fillDemoDraft(store)
                    if let p = store.suite.camera.presets.first { store.applyPreset(p) }
                    store.suite.composer.tokens = PromptTokens(); store.unselectPresetOnEmptyPrompt() }),
                ("composer_photo_preset", { store.openPhoto(model: SampleData.demo)
                    if let tpl = store.templates.first { store.choosePhotoPreset(tpl) } }),
                ("composer_photo_preset_cleared", { store.openPhoto(model: SampleData.demo)
                    if let tpl = store.templates.first { store.choosePhotoPreset(tpl) }
                    store.suite.composer.tokens = PromptTokens(); store.unselectPresetOnEmptyPrompt() }),
            ]
            /// Also shot at 1000 × 800.
            let narrow: Set<String> = ["composer", "composer_photo", "camera_setup"]
            for theme in ThemeID.allCases {
                store.themeID = theme
                for (name, show) in shots {
                    state.overlay = nil
                    state.scrollTo = nil
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
            store.themeID = .a
            await fitCheck(store, dir: dir)
            await editCheck(store, dir: dir)   // owner blocker 2026-11-07: opening Edit with real takes (SnapshotRunner+Edit.swift)
            await scrollCheck(store, dir: dir)
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

    // MARK: Fit check (CI): Generate is fully on screen at the common Mac window sizes (owner fix A2)

    /// Writes `fit-check.txt` and `mac_<theme>_<screen>_<w>x<h>.png`: one line per tool and size, `FITS` when Generate
    /// lies inside the window's content, else `CUT`. Mac CI fails on any CUT line. Sizes larger than the runner's
    /// screen are fine: the window is drawn off screen and captured from its own content view.
    private static func fitCheck(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        var lines: [String] = []
        let screens: [(String, @MainActor () -> Void)] = [
            ("composer", { store.openTool(.shot); fillDemoDraft(store) }),
            // Empty draft: the presets strip opens by default (worst case for height). Switching tools re-evaluates it.
            ("composer_empty", { store.openTool(.photo); Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                store.openTool(.shot); store.suite.composer.tokens = PromptTokens(); store.suite.composer.collapsed = nil } }),
            ("composer_photo", { store.openPhoto(model: SampleData.demo) }),
            // Regression (the old composer): Photo drawn, then Shot and the Style picker in one tick (PANEL line).
            ("composer_rig_sametick", { store.openTool(.shot); fillDemoDraft(store); store.openPicker(.style) }),
        ]
        func run(_ themes: [ThemeID], _ sizes: [(Int, Int)], _ screens: [(String, @MainActor () -> Void)]) async {
            for theme in themes {
                store.themeID = theme
                for (width, height) in sizes {
                    w.setFrame(NSRect(x: full.minX, y: full.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
                    for (name, show) in screens {
                        NSLog("[snapshot] fit %@ %dx%d %@", name, width, height, theme.rawValue)
                        store.suite.picker = nil
                        store.suite.browserOpen = false
                        state.generateFrame = nil
                        show()
                        try? await Task.sleep(for: .seconds(1.5))
                        state.probeTick += 1
                        try? await Task.sleep(for: .seconds(0.3))
                        w.contentView?.layoutSubtreeIfNeeded()
                        let content = w.contentView?.bounds.size ?? .zero
                        let label = "\(name) \(width)x\(height) \(theme.rawValue)"
                        if let g = state.generateFrame {
                            let inside = g.minX >= 0 && g.minY >= 0 && g.maxX <= content.width + 0.5 && g.maxY <= content.height + 0.5
                            lines.append("\(inside ? "FITS" : "CUT") \(label) generate \(Int(g.minX)),\(Int(g.minY)) \(Int(g.width))x\(Int(g.height)) in \(Int(content.width))x\(Int(content.height))")
                        } else {
                            lines.append("CUT \(label) generate not drawn")
                        }
                        if name.contains("rig") {
                            lines.append("PANEL \(label) picker=\(store.suite.picker?.rawValue ?? "nil") bodySawPicker=\(suiteBodySawPicker) bodies=\(suiteBodyCount) appeared=\(state.rigPanelOnScreen)")
                        }
                        capture(dir.appendingPathComponent("mac_\(theme.rawValue)_\(name)_\(width)x\(height).png"))
                    }
                }
            }
        }
        await run([.c, .b], [(1440, 900), (1280, 800), (1100, 620)], screens)
        // The cinematic Suite (owner switch "Try the new Suite"): Shot, its empty state and Photo in all four themes.
        let cinema: [(String, @MainActor () -> Void)] = [
            ("cinema_shot", { store.newSuite = true; state.cinemaEmpty = false; store.openTool(.shot); fillDemoDraft(store) }),
            ("cinema_empty", { store.newSuite = true; state.cinemaEmpty = true; store.openTool(.shot); store.suite.composer.tokens = PromptTokens() }),
            ("cinema_photo", { store.newSuite = true; state.cinemaEmpty = false; store.openPhoto(model: SampleData.demo) }),
            // Build step 3: the rig panel on Style (arc carousel, era ruler, tempo) and on Camera (the drums).
            // The picker opens a moment after the tool switch, as a person would (switching from Photo and opening the
            // panel in the same tick sometimes drew the room without it).
            ("cinema_rig_style", { store.newSuite = true; state.cinemaEmpty = false; store.openTool(.shot); fillDemoDraft(store)
                Task { @MainActor in try? await Task.sleep(for: .seconds(0.6)); store.openPicker(.style) } }),
            ("cinema_rig_camera", { store.newSuite = true; state.cinemaEmpty = false; store.openTool(.shot); fillDemoDraft(store)
                Task { @MainActor in try? await Task.sleep(for: .seconds(0.6)); store.openPicker(.camera, step: "setup") } }),
            // Diagnosis (coordinator): Photo, then Shot and the panel in the same tick. The fit check logs whether the
            // body saw the picker and whether the panel's view appeared (PANEL lines).
            // The original failure: the Photo screen fully drawn, then Shot and the panel in one tick.
            ("cinema_photo_again", { store.newSuite = true; state.cinemaEmpty = false; store.openPhoto(model: SampleData.demo) }),
            ("cinema_rig_sametick", { store.newSuite = true; state.cinemaEmpty = false; store.openTool(.shot); fillDemoDraft(store); store.openPicker(.style) }),
        ]
        // The runner's screen clamps the window's height (the 1440 × 900 and 1280 × 800 shots are about 684 pt tall).
        await run(ThemeID.allCases, [(1440, 900), (1280, 800)], cinema)
        store.newSuite = false
        state.cinemaEmpty = false
        w.setFrame(full, display: true)
        try? await Task.sleep(for: .seconds(1))
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("fit-check.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Scroll check (CI): every main page and Settings pane must scroll with a real scroll event

    /// Writes `scroll-check.txt`: one line per page, `MOVED`, `FITS` (nothing to scroll) or `STUCK` (scrollable but a
    /// synthetic scroll didn't move it). Mac CI fails on any STUCK line when at least one page MOVED (the events work).
    private static func scrollCheck(_ store: AppStore, dir: URL) async {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        var lines: [String] = []
        func check(_ name: String, _ show: @MainActor () -> Void) async {
            store.suite.picker = nil
            state.scrollTo = nil
            show()
            try? await Task.sleep(for: .seconds(1.5))
            lines.append(await scrollOnce(name))
        }
        let pages: [(String, Screen)] = [("home", .home), ("library", .gallery), ("models", .models), ("queue", .queue), ("credits", .credits),
                                          ("members", .members), ("posts", .posts), ("templates", .templates), ("lora", .lora),
                                          ("suite", .suite), ("edit", .edit)]
        for (name, screen) in pages { await check(name) { store.go(screen) } }
        await check("cast") { store.openProfile(SampleData.demo) }
        for section in SettingsSection.allCases { await check("settings_\(section.rawValue)") { store.openSettings(section) } }
        // The drum's scroll monitor must not outlive the picker: hover a drum, close the picker under the pointer, scroll Home.
        store.openTool(.shot)
        store.openPicker(.camera, step: "setup")
        try? await Task.sleep(for: .seconds(2))
        if let w = mainWindow, let content = w.contentView { postMouseMove(at: content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil), in: w) }
        try? await Task.sleep(for: .seconds(0.5))
        store.suite.picker = nil
        await check("home_after_picker") { store.go(.home) }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("scroll-check.txt"), atomically: true, encoding: .utf8)
    }

    /// The largest scroll view in the window whose content is taller than its viewport, or the largest one at all.
    private static func mainScrollView(in view: NSView) -> NSScrollView? {
        var all: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !s.isHiddenOrHasHiddenAncestor, s.bounds.width > 200, s.bounds.height > 200 { all.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        func area(_ s: NSScrollView) -> CGFloat { s.bounds.width * s.bounds.height }
        let scrollable = all.filter { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 4 }
        return (scrollable.max { area($0) < area($1) }) ?? all.max { area($0) < area($1) }
    }

    private static func scrollOnce(_ name: String) async -> String {
        guard let w = mainWindow, let content = w.contentView else { return "UNTESTED \(name) no window" }
        guard let sv = mainScrollView(in: content) else { return "FITS \(name) no scroll view" }
        let doc = sv.documentView?.frame.height ?? 0, viewport = sv.contentView.bounds.height
        guard doc > viewport + 4 else { return "FITS \(name) content \(Int(doc)) <= viewport \(Int(viewport))" }
        let mid = sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
        func offset() -> CGFloat { sv.contentView.bounds.origin.y }
        // 1. Through the app, as a real event: NSApp.sendEvent runs local event monitors (a monitor that swallows
        //    scrolls makes this fail).
        let start = offset()
        if let ev = scrollEvent(at: mid, in: w, dy: -240) { NSApp.sendEvent(ev) }
        try? await Task.sleep(for: .seconds(0.6))
        if abs(offset() - start) > 1 { return "MOVED \(name) (app) \(Int(start)) -> \(Int(offset()))" }
        // 2. To the view under the pointer: fails when the content isn't in a scroll view or something covers it.
        let hitPoint = content.superview.map { $0.convert(mid, from: nil) } ?? mid
        guard let hit = content.hitTest(hitPoint) else { return "STUCK \(name) nothing under the pointer" }
        guard hit === sv || hit.isDescendant(of: sv) else {
            return "STUCK \(name) covered by \(type(of: hit)), content \(Int(doc)) > viewport \(Int(viewport))"
        }
        let start2 = offset()
        if let ev = scrollEvent(at: mid, in: w, dy: -240) { hit.scrollWheel(with: ev) }
        try? await Task.sleep(for: .seconds(0.6))
        if abs(offset() - start2) > 1 { return "MOVED \(name) (view) \(Int(start2)) -> \(Int(offset()))" }
        return "STUCK \(name) offset \(Int(start2)), content \(Int(doc)) > viewport \(Int(viewport)), hit \(type(of: hit))"
    }

    /// A continuous (trackpad-like) scroll event at a point in the window, addressed to that window.
    private static func scrollEvent(at p: NSPoint, in w: NSWindow, dy: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
        cg.location = globalPoint(p, in: w)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.windowNumber))
        return NSEvent(cgEvent: cg)
    }

    /// A point in window coordinates → Quartz global coordinates (top-left of the main display).
    private static func globalPoint(_ p: NSPoint, in w: NSWindow) -> CGPoint {
        let s = w.convertPoint(toScreen: p)
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: s.x, y: h - s.y)
    }

    private static func postMouseMove(at p: NSPoint, in w: NSWindow) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: globalPoint(p, in: w), mouseButton: .left) else { return }
        e.postToPid(getpid())
    }


    static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.canBecomeMain } }

    /// Draws the window's content into a PNG. Also asks `screencapture` for the same window (`…_sc.png`), which
    /// includes layer-only content (video, some images) if the runner allows screen capture.
    static func capture(_ url: URL) {
        guard let window = mainWindow, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        let sc = url.deletingPathExtension().appendingPathExtension("sc.png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // A sheet is its own window: shots with one ("…_before") take the whole screen.
        let whole = url.lastPathComponent.contains("_before")
        p.arguments = whole ? ["-x", sc.path] : ["-x", "-o", "-l", String(window.windowNumber), sc.path]
        try? p.run()
        p.waitUntilExit()
    }
}

/// The Claude chat panel as it sits beside a camera session, for the review screenshots only.
struct SnapshotOverlay: View {
    @Environment(\.theme) private var t

    var body: some View {
        // "Before" for the owner's Connections report: the old sheet exactly as it was presented (SuiteConnectionsRow).
        Color.clear.allowsHitTesting(false)
            .sheet(isPresented: Binding(get: { SnapshotRunner.state.overlay == "connections_before" }, set: { if !$0 { SnapshotRunner.state.overlay = nil } })) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { SnapshotRunner.state.overlay = nil }.padding(12)
                    }
                    ConnectionsView()
                }
                .frame(minWidth: 720, minHeight: 520)
            }
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
