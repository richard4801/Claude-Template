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
        /// The words drawn on Generate ("Generate · $0.14", or its short form), for the fit check's price line.
        var generateLabel: String?
        /// The composer bar's pills ("pill quality", …) and its pricing link ("pricing"), window space (ComposerBarFrame).
        var composerFrames: [String: CGRect] = [:]
        /// Bumped by the fit check after each screen change: Generate's probe reports its frame again.
        var probeTick = 0
        /// The rig panel's view is on screen (its onAppear / onDisappear), for the same-tick diagnosis.
        var rigPanelOnScreen = false
        /// The Edit suite hides its media panel and inspector (the `_collapsed` layout shots).
        var editCollapsed = false
        /// Recreate's cost line and its primary (window space), for the fit check (SnapshotFrame).
        var recreateFrames: [String: CGRect] = [:]
        /// The Edit suite opens with its Claude panel up on this tab (2 = Playbook), for the learning editor's shot.
        var claudeTab: Int?
    }

    /// Review mode: labels report truncation (`fitProbe`). Read once; a normal launch never probes.
    nonisolated static let probing: Bool = !(ProcessInfo.processInfo.environment["MUSE_SNAPSHOT_DIR"] ?? "").isEmpty
    /// The labels on screen that carry a fit probe: name, width drawn, width the text needs.
    static var fitProbes: [UUID: (name: String, drawn: CGFloat, ideal: CGFloat)] = [:]
    static func fitNote(_ id: UUID, _ name: String, drawn: CGFloat? = nil, ideal: CGFloat? = nil) {
        var e = fitProbes[id] ?? (name, -1, -1)
        e.name = name
        if let drawn { e.drawn = drawn }
        if let ideal { e.ideal = ideal }
        fitProbes[id] = e
    }
    /// Probed labels drawn narrower than their text (truncated), as "name (drawn of ideal pt)".
    static func truncatedLabels() -> [String] {
        fitProbes.values.filter { $0.drawn >= 0 && $0.ideal >= 0 && $0.ideal > $0.drawn + 0.75 }
            .map { "\($0.name) (\(Int($0.drawn.rounded())) of \(Int($0.ideal.rounded())) pt)" }
            .sorted()
    }

    /// The last Suite body that reported (noteSuiteBody): did it see the picker open (not observed: a plain static).
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
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so the CI log keeps the last lines if the app stops (Edit check)
        installCrashLogging()
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
            await editOpsCheck(store, dir: dir)   // Mac Edit audit 2026-11-08: every operation changes the project, the preview and the export
            await editLayoutShots(store, dir: dir)   // Edit layout audit (owner 2026-11-08): three window sizes, four themes
            await recreateShots(store, dir: dir)   // Recreate this edit: Recipe and Compare in four themes, the swatches
            await learnShots(store, dir: dir)   // The learning editor: Playbook, its rule editor, Recipes, the Claude panel tab
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
                        store.suite.feedOpen = false
                        store.suite.compareIds = []
                        store.suite.viewerTakeId = nil
                        store.suite.feedTool = nil
                        store.suite.feedModel = nil
                        store.suite.claude.open = false
                        state.generateFrame = nil
                        state.generateLabel = nil
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
                        // The window really is this wide (the app's minimum width once clamped 1000 to 1100).
                        if abs(content.width - CGFloat(width)) > 1 {
                            lines.append("CUT \(label) window drawn \(Int(content.width)) wide, not \(width)")
                        }
                        lines.append(contentsOf: composerBarLines(label, content: content))
                        if name == "composer_feed_viewer" {
                            let f = state.composerFrames["viewer"]
                            lines.append("\(f != nil ? "FITS" : "CUT") \(label) large viewer \(f.map { "\(Int($0.width))x\(Int($0.height))" } ?? "not drawn")")
                        }
                        if name == "composer_queue" {
                            let f = state.composerFrames["queued"]
                            lines.append("\(f != nil ? "FITS" : "CUT") \(label) queued group \(store.suite.queued.count) shots, \(store.suite.queued.first?.buttonLabel ?? "none")")
                        }
                        if name.hasPrefix("composer_claude") {
                            // Claude in the Suite: the panel beside the rail, the composer filled by demo mode's stand-in
                            // reply through the shared draft's checks; with the ask, its row waits (no confirmation opens
                            // in review mode, so nothing here can spend).
                            let c = store.suite.claude
                            let s = store.suite.composer.settings
                            let filled = s.body != nil && s.lighting != nil && s.palette != nil && s.genre != nil
                            let drawn = state.composerFrames["claude panel"] != nil
                            lines.append("\(drawn && filled ? "FITS" : "CUT") \(label) Claude panel \(drawn ? "drawn" : "not drawn"), composer \(filled ? "filled" : "not filled"), \(c.demoLines.count) lines, \(c.rejected.count) refused, revision \(c.revision)")
                            if name == "composer_claude_ask" {
                                lines.append("INFO \(label) reference chips: \(c.references.map(\.title).joined(separator: ", ")) \(state.composerFrames["claude references"] != nil ? "drawn" : "not drawn")")
                                lines.append("\(c.ask != nil && !c.confirmOpen ? "FITS" : "CUT") \(label) Claude's ask waits for the owner (\(c.ask.map { Pricing.money($0.estimateUsd) } ?? "none"), confirmation \(c.confirmOpen ? "open" : "closed"))")
                            }
                            if name == "composer_claude_attach" {
                                lines.append("\(c.attachments.count == 2 && state.composerFrames["claude attachments"] != nil ? "FITS" : "CUT") \(label) \(c.attachments.count) images attached before sending")
                            }
                        }
                        if name == "composer_swap" {
                            lines.append("\(state.composerFrames["decided"] != nil ? "FITS" : "CUT") \(label) rows set by the clip shown greyed with the reason")
                        }
                        if name.contains("rig") {
                            lines.append("PANEL \(label) picker=\(store.suite.picker?.rawValue ?? "nil") bodySawPicker=\(suiteBodySawPicker) bodies=\(suiteBodyCount) appeared=\(state.rigPanelOnScreen)")
                        }
                        capture(dir.appendingPathComponent("mac_\(theme.rawValue)_\(name)_\(width)x\(height).png"))
                    }
                }
            }
        }
        // 1000 × 700 and 960 × 640: the owner's window was about 1000 pt wide (coordination item 8).
        await run([.c, .b], [(1440, 900), (1280, 800), (1100, 620), (1000, 700), (960, 640)], screens)
        // The results feed beside the composer and two takes compared (plans/ai-suite-design.md, Release 1), with the
        // Setup rail's Rigs row, in the four themes.
        let feedScreens: [(String, @MainActor () -> Void)] = [
            ("composer_feed", { store.openTool(.shot); fillDemoDraft(store); store.suite.feedOpen = true }),
            // A card clicked: the take large over the feed (← → move through the takes).
            ("composer_feed_viewer", { store.openTool(.shot); fillDemoDraft(store); store.suite.feedOpen = true
                store.suite.viewerTakeId = (store.suite.feed.compactMap { store.feedTake($0) }.first ?? store.suiteTakes(photo: false).first)?.id }),
            // Swap: Camera, Light and Style are set by the clip, shown greyed with that reason.
            ("composer_swap", { store.openTool(.swap) }),
            // Build step 3: a shot added to the queue (priced, nothing held) shows in the feed's "Queued" group.
            ("composer_queue", { store.openTool(.shot); fillDemoDraft(store)
                if store.suite.queued.isEmpty { store.addShotToQueue() }
                store.suite.feedOpen = true }),
            // Claude in the Suite (owner): the panel in the picture's place, the composer filled from the typed idea.
            ("composer_claude", { store.openTool(.shot); fillDemoDraft(store); store.showSuiteClaudeForReview() }),
            // …two reference images attached, waiting to be sent (removable thumbnails).
            ("composer_claude_attach", { store.openTool(.shot); fillDemoDraft(store); store.showSuiteClaudeForReview(attach: true) }),
            // …and after "go": Claude's ask waits in the panel for the owner's confirmation (never approved here).
            ("composer_claude_ask", { store.openTool(.shot); fillDemoDraft(store); store.showSuiteClaudeForReview(ask: true) }),
            ("composer_compare", { store.openTool(.shot); fillDemoDraft(store); store.suite.feedOpen = true
                let two = Array(store.suiteTakes(photo: false).prefix(2)) + Array(store.takes.filter(\.isVideo).prefix(2))
                store.suite.compareIds = Array(two.map(\.id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(2)) }),
        ]
        await run([.c, .a, .b, .d], [(1280, 800), (1000, 700)], feedScreens)
        // The last screen was the comparison: two takes were on screen (the demo has video takes).
        let compared = store.suiteComparing.count
        lines.append("\(compared == 2 ? "FITS" : "CUT") composer_compare \(compared) takes side by side, \(store.suite.feed.count) feed cards")
        // Library's collection filter: the demo's "Client picks" shows its two takes only.
        store.suite.compareIds = []
        store.suite.feedOpen = false
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1280, height: 800), display: true)
            store.go(.gallery)
            store.setGalleryCollection("col_demo_picks")
            // The screen change animates (the sidebar cross-fades): wait it out before the shot.
            try? await Task.sleep(for: .seconds(3))
            w.contentView?.layoutSubtreeIfNeeded()
            let n = store.galleryList.count
            lines.append("\(n == 2 ? "FITS" : "CUT") library_collection 1280x800 \(theme.rawValue) \(n) takes in Client picks, \(store.library.collections.count) collections")
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_library_collection_1280x800.png"))
            store.setGalleryCollection(nil)
        }
        store.suite.compareIds = []
        store.suite.feedOpen = false
        // Claude's ask from the review shots is declined (it was never approved), and the panel closed.
        if store.suite.claude.ask != nil { store.answerSuiteAsk(approve: false) }
        store.suite.claude.attachments = []
        store.suite.claude.open = false
        w.setFrame(full, display: true)
        try? await Task.sleep(for: .seconds(1))
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("fit-check.txt"), atomically: true, encoding: .utf8)
    }

    /// The composer bar at this size (coordination item 8: "Standar/d", "Speak/ing", "Engine · A…", "GENERATE…"): every
    /// pill drawn whole (no wrapped or cut label, not under the pricing link or Generate, inside the window), and Generate
    /// drawn whole with its price. One FITS line, or a CUT line per problem.
    private static func composerBarLines(_ label: String, content: CGSize) -> [String] {
        var out: [String] = []
        let frames = state.composerFrames
        let pills = frames.filter { $0.key.hasPrefix("pill ") }.sorted { $0.value.minX < $1.value.minX }
        if pills.isEmpty { out.append("CUT \(label) bar no pills drawn") }
        let limit = frames["pricing"]?.minX ?? state.generateFrame?.minX ?? content.width
        for (key, f) in pills where f.minX < -0.5 || f.maxX > limit + 0.5 || f.maxY > content.height + 0.5 {
            out.append("CUT \(label) bar \(key) at \(Int(f.minX))-\(Int(f.maxX)), past \(Int(limit))")
        }
        for cut in truncatedLabels() where cut.hasPrefix("composer ") {
            out.append("CUT \(label) bar \(cut.dropFirst("composer ".count))")
        }
        let g = state.generateLabel ?? ""
        // The price is the last part: "Generate · $0.14", "Generate · Free", "Generate · —" while there is none yet.
        if !g.contains(" · ") { out.append("CUT \(label) bar generate shows no price (\"\(g)\")") }
        if out.isEmpty {
            let names = pills.map { String($0.key.dropFirst(5)) }.joined(separator: ", ")
            out.append("FITS \(label) bar \(pills.count) pills whole (\(names)), \"\(g)\"")
        }
        // The feed's filter (composer_feed): inside the feed's header row; its labels are probed whole above (12 pt
        // padding each side by construction; under that width it becomes one "All ▾").
        if let f = frames["feed filter"], let h = frames["feed header"] {
            let inside = f.minX >= h.minX - 0.5 && f.maxX <= h.maxX + 0.5 && f.height <= 36
            let form = f.width > 120 ? "segments" : "menu"
            out.append("\(inside ? "FITS" : "CUT") \(label) feed filter (\(form)) \(Int(f.width))x\(Int(f.height)) in the header \(Int(h.width)) wide")
        }
        return out
    }

    // MARK: Edit layout audit

    /// The Edit suite on a real-shaped take (editCheck's 15 s take with sound), at the sizes the owner uses: 1280 × 800,
    /// 1440 × 900 and a 13" MacBook Air's window (1470 × 882: its default 1470 × 956 screen less the menu bar and Dock),
    /// with the side panels shown and collapsed (`_collapsed`). Soft Tactile first. Rendered from the window's own drawing
    /// (`mac_editaudit_<theme>_<w>x<h>[_collapsed].png`), so a window larger than the runner's screen still comes out whole.
    /// Also the Edit part of the fit check: every probed label (`fitProbe`) must be drawn in full, else a CUT line in
    /// fit-check.txt (Mac CI fails on it).
    private static func editLayoutShots(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        defer {
            let f = dir.appendingPathComponent("fit-check.txt")
            let before = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? (before + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: f, atomically: true, encoding: .utf8)
        }
        // editCheck removes its rx_* takes when it ends; its MP4s stay in the temporary folder. Use its 15 s stereo take.
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        guard FileManager.default.fileExists(atPath: long.path), let w = mainWindow else {
            lines.append("CUT edit not drawn (no test video or window)")
            return
        }
        let raw: [String: Any] = ["id": "rx_layout", "kind": "take", "title": "Living room dance", "videoUrl": long.absoluteString,
                                  "durationSec": 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
        guard let data = try? JSONSerialization.data(withJSONObject: raw), let take = try? JSONDecoder().decode(Take.self, from: data) else { return }
        store.takes.removeAll { $0.id == take.id }
        store.takes.insert(take, at: 0)
        defer { store.takes.removeAll { $0.id == take.id } }
        let original = w.frame
        let sizes: [(Int, Int)] = [(1280, 800), (1440, 900), (1470, 882)]
        func shot(_ name: String, _ label: String) {
            capture(dir.appendingPathComponent("mac_editaudit_\(name).png"))
            let cut = truncatedLabels()
            if cut.isEmpty {
                lines.append("FITS edit \(label) (\(fitProbes.count) labels)")
            } else {
                lines.append(contentsOf: cut.map { "CUT edit \(label) \($0)" })
            }
        }
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            state.editCollapsed = false
            store.openEdit(takeId: take.id)
            try? await Task.sleep(for: .seconds(8))
            for (width, height) in sizes {
                NSLog("[snapshot] editaudit %dx%d %@", width, height, theme.rawValue)
                w.setFrame(NSRect(x: original.minX, y: original.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
                try? await Task.sleep(for: .seconds(1.5))
                shot("\(theme.rawValue)_\(width)x\(height)", "\(width)x\(height) \(theme.rawValue)")
                state.editCollapsed = true
                try? await Task.sleep(for: .seconds(1))
                shot("\(theme.rawValue)_\(width)x\(height)_collapsed", "\(width)x\(height) \(theme.rawValue) collapsed")
                state.editCollapsed = false
                try? await Task.sleep(for: .seconds(0.5))
            }
            // The app now opens down to 960 pt (coordination item 8): Edit at 1000 × 700 for the record. INFO lines, not
            // CUT: the Edit layout plan's sizes are the three above.
            if theme == .c {
                w.setFrame(NSRect(x: original.minX, y: original.maxY - 700, width: 1000, height: 700), display: true)
                try? await Task.sleep(for: .seconds(1.5))
                capture(dir.appendingPathComponent("mac_editaudit_c_1000x700.png"))
                let cut = truncatedLabels()
                lines.append(cut.isEmpty ? "INFO edit 1000x700 c (\(fitProbes.count) labels whole)" : cut.map { "INFO edit 1000x700 c \($0)" }.joined(separator: "\n"))
            }
            w.setFrame(original, display: true)
            store.openEdit(takeId: nil)
            try? await Task.sleep(for: .seconds(1))
        }
        store.themeID = .a
    }

    // MARK: Recreate this edit

    /// Recipe (shot 2 selected), Build's confirmation with the estimates, the Recipe while the new shots generate, and
    /// Compare (after they are ready and the edit is built) on demo mode's reference, at 1280 × 800 in the four themes
    /// (`mac_<theme>_recreate_recipe.png`, `…_recreate_confirm.png`, `…_recreate_generating.png`, `…_recreate_compare.png`),
    /// and the Look swatches as analysed and as shown
    /// (`mac_recreate_swatches.png`). Fit check lines: every probed label drawn in full, and the total and Build both on
    /// screen, side by side (owner note 2); the shown swatches 3–5, calm and ordered by tone (owner note 1).
    private static func recreateShots(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        defer {
            let f = dir.appendingPathComponent("fit-check.txt")
            let before = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? (before + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: f, atomically: true, encoding: .utf8)
        }
        guard let w = mainWindow else {
            lines.append("CUT recreate not drawn (no window)")
            return
        }
        let original = w.frame
        func check(_ screen: String, _ theme: ThemeID, beside: Bool, primary: String = "build") {
            w.contentView?.layoutSubtreeIfNeeded()
            let content = w.contentView?.bounds.size ?? .zero
            let label = "recreate_\(screen) 1280x800 \(theme.rawValue)"
            let keys = beside ? ["cost", primary] : [primary]
            for k in keys {
                guard let f = state.recreateFrames[k], f.width > 0 else {
                    lines.append("CUT \(label) \(k) not drawn")
                    continue
                }
                let inside = f.minX >= 0 && f.minY >= 0 && f.maxX <= content.width + 0.5 && f.maxY <= content.height + 0.5
                lines.append("\(inside ? "FITS" : "CUT") \(label) \(k) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) in \(Int(content.width))x\(Int(content.height))")
            }
            if beside, let c = state.recreateFrames["cost"], let b = state.recreateFrames["build"] {
                let gap = b.minX - c.maxX
                let sameRow = c.maxY > b.minY && c.minY < b.maxY
                lines.append("\(gap >= 0 && gap <= 24 && sameRow ? "FITS" : "CUT") \(label) cost beside build (gap \(Int(gap)) pt)")
            }
            let cut = truncatedLabels()
            if cut.isEmpty {
                lines.append("FITS \(label) (\(fitProbes.count) labels)")
            } else {
                lines.append(contentsOf: cut.map { "CUT \(label) \($0)" })
            }
        }
        /// A frame (window space) drawn fully inside the window: FITS, else CUT.
        func onScreen(_ key: String, _ label: String) {
            w.contentView?.layoutSubtreeIfNeeded()
            let content = w.contentView?.bounds.size ?? .zero
            guard let f = state.recreateFrames[key], f.width > 0 else { lines.append("CUT \(label) \(key) not drawn"); return }
            let inside = f.minX >= 0 && f.minY >= 0 && f.maxX <= content.width + 0.5 && f.maxY <= content.height + 0.5
            lines.append("\(inside ? "FITS" : "CUT") \(label) \(key) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) in \(Int(content.width))x\(Int(content.height))")
        }
        // Compare's "Your edit" plays the built edit: demo mode builds it on a video take, editCheck's 15 s take (its MP4
        // stays in the temporary folder), added for these shots only.
        // A patterned take (stripes and a moving square, colours changing over time), so the built edit's frame shows the
        // camera moves, cuts and Look on real picture detail; editCheck's flat test video if it can't be written.
        var long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        let pattern = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-recreate-pattern.mp4")
        if (try? await writePatternVideo(pattern, seconds: 6, fps: 30, width: 432, height: 768)) != nil { long = pattern }
        let demoTakeId = "rx_recreate"
        if FileManager.default.fileExists(atPath: long.path) {
            let raw: [String: Any] = ["id": demoTakeId, "kind": "take", "title": "Living room dance", "videoUrl": long.absoluteString,
                                      "durationSec": long == pattern ? 6 : 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
            if let data = try? JSONSerialization.data(withJSONObject: raw), let take = try? JSONDecoder().decode(Take.self, from: data) {
                store.takes.removeAll { $0.id == take.id }
                store.takes.insert(take, at: 0)
            }
        } else {
            lines.append("CUT recreate_compare no demo take to build on (editCheck's video is missing)")
        }
        defer { store.takes.removeAll { $0.id == demoTakeId } }
        for theme in [ThemeID.c, .a, .b, .d] {
            NSLog("[snapshot] recreate %@", theme.rawValue)
            store.themeID = theme
            w.setFrame(NSRect(x: original.minX, y: original.maxY - 800, width: 1280, height: 800), display: true)
            store.openEdit(takeId: nil)
            store.recreate.fake.forgetMade()
            store.recreate.buildWhenReady = []
            store.openRecreate()
            try? await Task.sleep(for: .seconds(1))
            if theme == .c {
                // A link being fetched on this Mac (faked: review mode never runs the download): the progress line and Stop.
                store.recreate.fetchingLink = true
                store.recreate.linkStatus = RecreateDeviceFetch.statusLine(fetched: 0.42)
                store.recreate.linkProgress = 0.42
                try? await Task.sleep(for: .seconds(0.6))
                onScreen("linkFetching", "recreate_fetching 1280x800 c")
                check("fetching", theme, beside: false, primary: "linkFetching")
                capture(dir.appendingPathComponent("mac_c_recreate_fetching.png"))
                store.recreate.fetchingLink = false
                store.recreate.linkStatus = nil
                store.recreate.linkProgress = nil
                try? await Task.sleep(for: .seconds(0.3))
                // Paste a link (Release 1 gap 3): demo mode's private link is refused, with the file offered right there.
                // Pasted into the empty field: fetched at once.
                store.recreate.linkText = "https://www.tiktok.com/@muse.demo/video/7400000000000000002-private"
                try? await Task.sleep(for: .seconds(1.2))
                if store.recreate.linkProblem == nil { await store.createRecreateReference(link: store.recreate.linkText) }
                try? await Task.sleep(for: .seconds(0.5))
                let p = store.recreate.linkProblem
                lines.append("\(p?.code == "link_private" && p?.offersFile == true ? "FITS" : "CUT") recreate_link 1280x800 c refusal \(p?.code ?? "none"), file offered \(p?.offersFile == true)")
                onScreen("linkProblem", "recreate_link 1280x800 c")
                check("link", theme, beside: false, primary: "linkProblem")
                capture(dir.appendingPathComponent("mac_c_recreate_link.png"))
                // The demo link reads at once (source: link), and the same link again is the cached reference.
                await store.createRecreateReference(link: FakeRecreateAPI.demoLink)
                let first = store.recreate.reference
                store.leaveRecreateReference()
                await store.createRecreateReference(link: FakeRecreateAPI.demoLink)
                let again = store.recreate.reference
                let ok = first?.isLink == true && first?.isReady == true && again?.id == first?.id && again?.cached == true
                lines.append("\(ok ? "FITS" : "CUT") recreate_link 1280x800 c the demo link reads at once (\(first?.id ?? "none")), again cached \(again?.cached == true)")
                store.leaveRecreateReference()
                store.toast = nil   // the "read this video before" toast would sit over the next shots
                try? await Task.sleep(for: .seconds(0.5))
            }
            let refs = (try? await store.recreateAPI.listReferences()) ?? []
            guard let ref = refs.first(where: { $0.id == "rx_demo" }) ?? refs.first(where: { $0.recipe != nil }) else {
                lines.append("CUT recreate no demo reference")
                break
            }
            await store.openRecreateReference(ref.id)
            store.selectRecreateSlot(1)
            try? await Task.sleep(for: .seconds(2))
            check("recipe", theme, beside: true)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_recreate_recipe.png"))
            if theme == .c {
                // A toast on Recreate never covers the cost line or Build: it sits under the top bar.
                store.showToast("Shot 2 replaced. Undo it in the editor’s history.")
                try? await Task.sleep(for: .seconds(0.6))
                if let toast = state.recreateFrames["toast"], let c = state.recreateFrames["cost"], let b = state.recreateFrames["build"] {
                    let clear = !toast.intersects(c) && !toast.intersects(b)
                    lines.append("\(clear ? "FITS" : "CUT") recreate_toast 1280x800 c toast \(Int(toast.minX)),\(Int(toast.minY)) \(Int(toast.width))x\(Int(toast.height)) clear of the cost line and Build")
                } else {
                    lines.append("CUT recreate_toast 1280x800 c toast, cost or build not drawn")
                }
                capture(dir.appendingPathComponent("mac_c_recreate_toast.png"))
                store.toast = nil
                try? await Task.sleep(for: .seconds(0.4))
                // The Cast step (Release 1 item E): the lead, and the studio's cast open under it.
                let lead = store.recreateLead
                lines.append("\(lead != nil && store.recreateModelId == lead?.id ? "FITS" : "CUT") recreate_cast 1280x800 c lead \(lead?.name ?? "none") prices the shots")
                store.recreate.castOpen = true
                try? await Task.sleep(for: .seconds(0.8))
                onScreen("castDone", "recreate_cast 1280x800 c")
                check("cast", theme, beside: true)
                capture(dir.appendingPathComponent("mac_c_recreate_cast.png"))
                store.recreate.castOpen = false
                // Claude beside the Recipe (Release 1 item C): the chat with Recreate's context (demo mode has no Claude
                // connection, so it says so); Build and the total stay on screen beside each other.
                store.toggleRecreateClaude()
                try? await Task.sleep(for: .seconds(1.2))
                onScreen("claude", "recreate_claude 1280x800 c")
                check("claude", theme, beside: true)
                capture(dir.appendingPathComponent("mac_c_recreate_claude.png"))
                store.recreate.closeClaude()
                try? await Task.sleep(for: .seconds(0.5))
                // Write the shot briefs (G8): shot 1 has none, so its price shows; the confirmation, closed with Cancel
                // (nothing is written or charged in review mode).
                store.selectRecreateSlot(0)
                try? await Task.sleep(for: .seconds(1))
                let b = store.recreate.briefs
                lines.append("\(b?.available == true && (b?.label.contains("$") ?? false) ? "FITS" : "CUT") recreate_briefs 1280x800 c \(b?.label ?? "no estimate") for \(b?.slots ?? 0) shots")
                onScreen("briefs", "recreate_briefs 1280x800 c")
                check("briefs", theme, beside: true)
                capture(dir.appendingPathComponent("mac_c_recreate_briefs.png"))
                store.requestRecreateBriefs()
                try? await Task.sleep(for: .seconds(1.2))
                captureWithSheet(dir.appendingPathComponent("mac_c_recreate_briefs_confirm.png"), lines: &lines, label: "recreate_briefs_confirm c")
                store.recreate.askBriefs = false
                try? await Task.sleep(for: .seconds(0.8))
                store.selectRecreateSlot(1)
                // Use your own setting: the studio's locations and "Make one from the brief · +$0.06" (priced again).
                if let s2 = store.recreate.slots.dropFirst().first?.id {
                    store.setRecreateKeepSetting(s2, false)
                    try? await Task.sleep(for: .seconds(1))
                    state.scrollTo = "recreate.fill"
                    try? await Task.sleep(for: .seconds(0.8))
                    let info = store.recreate.estimateInfo[s2]
                    let ok = info?.background?.source == "generated" && (info?.backgroundUsd ?? 0) > 0 && !store.suite.locations.isEmpty
                    lines.append("\(ok ? "FITS" : "CUT") recreate_own_setting 1280x800 c \(store.suite.locations.count) locations, plate +\(RecreateText.money(info?.backgroundUsd ?? 0)), \(info?.estimate.buttonLabel ?? "not priced")")
                    onScreen("plate", "recreate_own_setting 1280x800 c")
                    check("own_setting", theme, beside: true)
                    capture(dir.appendingPathComponent("mac_c_recreate_own_setting.png"))
                    if let loc = store.suite.locations.first {
                        store.setRecreateLocation(s2, loc.id)
                        try? await Task.sleep(for: .seconds(0.8))
                        let bg = store.recreate.estimateInfo[s2]?.background
                        lines.append("\(bg?.source == "location" && bg?.usd == 0 ? "FITS" : "CUT") recreate_own_setting 1280x800 c on \(bg?.name ?? "no location"), free")
                    }
                    // Back to the reference's setting for the shots after this one.
                    store.setRecreateLocation(s2, nil)
                    store.setRecreateKeepSetting(s2, true)
                    state.scrollTo = nil
                    try? await Task.sleep(for: .seconds(0.8))
                }
            }
            // The panel scrolled to the Look (owner note 1: the swatches as the Recipe shows them).
            state.scrollTo = "recreate.look"
            try? await Task.sleep(for: .seconds(1))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_recreate_recipe_look.png"))
            state.scrollTo = nil
            // Build: the confirmation with the estimates (the demo prices each new shot at $0.64), closed with Cancel.
            await store.requestRecreateBuild()
            try? await Task.sleep(for: .seconds(1.5))
            check("confirm", theme, beside: false, primary: "confirm")
            captureWithSheet(dir.appendingPathComponent("mac_\(theme.rawValue)_recreate_confirm.png"), lines: &lines, label: "recreate_confirm \(theme.rawValue)")
            store.recreate.askBuild = false
            try? await Task.sleep(for: .seconds(1))
            // The yes, in demo mode only (the fake makes nothing and charges nothing): the new shots generating on the
            // Recipe, then ready, then the edit is built and Compare opens.
            guard store.isDemo, store.recreateAPI is FakeRecreateAPI else {
                lines.append("CUT recreate_generating not in demo mode (nothing is spent in review mode)")
                break
            }
            store.confirmRecreateBuild()
            store.selectRecreateSlot(1)
            // The fake's shots are ready on the second fill after they start (the watch reads it 3 s later): shoot before.
            try? await Task.sleep(for: .seconds(1.2))
            let making = store.recreate.generatingSlots.count
            lines.append("\(making > 0 ? "FITS" : "CUT") recreate_generating 1280x800 \(theme.rawValue) \(making) shots generating")
            check("generating", theme, beside: true)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_recreate_generating.png"))
            for _ in 0..<40 where store.recreate.mode != .compare { try? await Task.sleep(for: .seconds(0.5)) }
            lines.append("\(store.recreate.mode == .compare ? "FITS" : "CUT") recreate_built 1280x800 \(theme.rawValue) after the new shots were ready")
            store.selectRecreateSlot(1)
            // "Your edit" is the built edit itself, from the editor's engine (gap 1).
            for _ in 0..<24 where store.recreate.built?.phase != .ready { try? await Task.sleep(for: .seconds(0.5)) }
            try? await Task.sleep(for: .seconds(1))
            let built = store.recreate.built
            lines.append("\(built?.phase == .ready ? "FITS" : "CUT") recreate_compare 1280x800 \(theme.rawValue) your edit is the built edit (\(built.map { "\($0.clipCount) clips, \(String(format: "%.1f", $0.duration)) s" } ?? "not built"))")
            check("compare", theme, beside: false, primary: "export")
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_recreate_compare.png"))
            if theme == .c, let built {
                // Playing on the shared playhead: both players run, and the built edit's own clock moves with Recreate's.
                store.recreate.time = 0
                try? await Task.sleep(for: .seconds(0.3))
                store.toggleRecreatePlay()
                try? await Task.sleep(for: .seconds(1.6))
                let at = built.player.currentTime().seconds
                let clock = store.recreate.time
                lines.append("\(at > 0.3 && abs(at - clock) < 1.0 ? "FITS" : "CUT") recreate_compare_playing 1280x800 c your edit at \(String(format: "%.2f", at)) s, playhead \(String(format: "%.2f", clock)) s")
                onScreen("yours", "recreate_compare_playing 1280x800 c")
                capture(dir.appendingPathComponent("mac_c_recreate_compare_playing.png"))
                if store.recreate.playing { store.toggleRecreatePlay() }
                // The exact frame the player shows (screen grabs leave video layers out): the built composition at 3.5 s,
                // where the reference's caption is on screen.
                if let img = await built.frame(at: 3.6) {
                    let rep = NSBitmapImageRep(cgImage: img)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mac_c_recreate_compare_frame.png"))
                    lines.append("FITS recreate_compare_frame c the built edit renders (\(img.width)x\(img.height))")
                    // The demo take's picture is in it (not a flat fill), and whether this Mac has the reference's Look.
                    let detail = frameDetail(img)
                    let look = built.project?.mainClips.first?.look?.lut ?? "none (this Mac doesn't have the reference's Look)"
                    lines.append("\(detail > 12 ? "FITS" : "CUT") recreate_compare_frame c picture detail \(String(format: "%.0f", detail)) (a flat fill is ~0), Look \(look)")
                } else {
                    lines.append("CUT recreate_compare_frame c the built edit didn't render a frame")
                }
                // Fix shot N: the sheet (your takes, or regenerate after its price), then a take swapped in for real (demo:
                // the fake's replace; nothing is spent) and "Your edit" rebuilt with it.
                if let w = store.recreate.weakestSlot {
                    store.openRecreateFix(w)
                    try? await Task.sleep(for: .seconds(1.2))
                    let slot = store.recreate.fixSlot
                    lines.append("\(slot != nil ? "FITS" : "CUT") recreate_fix 1280x800 c sheet for \(slot ?? "none"), \(store.recreateTakeChoices.count) takes to choose")
                    captureWithSheet(dir.appendingPathComponent("mac_c_recreate_fix.png"), lines: &lines, label: "recreate_fix c")
                    check("fix", theme, beside: false, primary: "export")
                    if let slot {
                        let code = await store.replaceRecreateSlot(slot, take: demoTakeId)
                        for _ in 0..<20 where store.recreate.built?.phase != .ready { try? await Task.sleep(for: .seconds(0.5)) }
                        lines.append("\(code == nil && store.recreate.demoSwaps[slot] == demoTakeId && store.recreate.built?.phase == .ready ? "FITS" : "CUT") recreate_fix_replace 1280x800 c \(slot) now plays \(demoTakeId) (\(code ?? "ok"))")
                    }
                    store.closeRecreateFix()
                    store.toast = nil
                    try? await Task.sleep(for: .seconds(0.8))
                } else {
                    lines.append("CUT recreate_fix 1280x800 c no weakest shot after Build")
                }
                // Export (gap 2): the sheet, closed with Cancel (nothing is saved in review mode).
                store.openRecreateExport()
                try? await Task.sleep(for: .seconds(1.2))
                let reminder = RecreateExport.reminder(store.recreate.reference)
                lines.append("\(store.recreate.exportOpen && !reminder.isEmpty ? "FITS" : "CUT") recreate_export 1280x800 c sound \(store.recreate.exportSound.rawValue), reminder shown")
                captureWithSheet(dir.appendingPathComponent("mac_c_recreate_export.png"), lines: &lines, label: "recreate_export c")
                check("export", theme, beside: false, primary: "export")
                store.recreate.exportOpen = false
                try? await Task.sleep(for: .seconds(0.8))
            }
            store.closeRecreate()
            try? await Task.sleep(for: .seconds(0.5))
        }
        // The swatches (owner note 1): the analysis's palette, then the strip the Recipe shows.
        if let ref = try? await FakeRecreateAPI().listReferences().first, let raw = ref.recipe?.grade?.swatches {
            let soft = RecreateSwatches.soften(raw)
            let maxSat = soft.map(RecreateSwatches.saturation).max() ?? 1
            let lum = soft.map(RecreateSwatches.luminance)
            let ok = (RecreateSwatches.minCount...RecreateSwatches.maxCount).contains(soft.count) && maxSat <= RecreateSwatches.maxSaturation && lum == lum.sorted()
            lines.append("\(ok ? "FITS" : "CUT") recreate_swatches \(soft.count) swatches, max saturation \(String(format: "%.2f", maxSat)), dark to light: \(soft.joined(separator: " "))")
            let r = ImageRenderer(content: RecreateSwatchSheet(raw: raw, soft: soft))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mac_recreate_swatches.png"))
            }
        } else {
            lines.append("CUT recreate_swatches no fixture")
        }
        w.setFrame(original, display: true)
        store.themeID = .a
        store.closeRecreate()
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: Learning editor

    /// The Playbook (Rules), its rule editor on the long learned rule (counter, evidence, Delete rule), Suggestions,
    /// Recipes, a recipe's detail panel and the editor's Claude panel on its Playbook tab, in demo mode at 1280 × 800 in
    /// the four themes (`mac_<theme>_learn_<screen>.png`). Fit check lines: every probed label drawn in full (CUT fails CI),
    /// plus that each screen has its content. Nothing is changed or deleted.
    private static func learnShots(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        defer {
            let f = dir.appendingPathComponent("fit-check.txt")
            let before = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? (before + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: f, atomically: true, encoding: .utf8)
        }
        guard let w = mainWindow else {
            lines.append("CUT learn not drawn (no window)")
            return
        }
        let original = w.frame
        func check(_ screen: String, _ theme: ThemeID, only: ((String) -> Bool)? = nil) {
            w.contentView?.layoutSubtreeIfNeeded()
            let label = "learn_\(screen) 1280x800 \(theme.rawValue)"
            let cut = truncatedLabels().filter { only?($0) ?? true }
            if cut.isEmpty {
                lines.append("FITS \(label) (\(fitProbes.count) labels)")
            } else {
                lines.append(contentsOf: cut.map { "CUT \(label) \($0)" })
            }
        }
        func has(_ ok: Bool, _ screen: String, _ theme: ThemeID, _ what: String) {
            lines.append("\(ok ? "FITS" : "CUT") learn_\(screen) 1280x800 \(theme.rawValue) \(what)")
        }
        // The editor's Claude panel needs a video take: editCheck's 15 s take (its MP4 stays in the temporary folder).
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        var take: Take?
        if FileManager.default.fileExists(atPath: long.path) {
            let raw: [String: Any] = ["id": "rx_learn", "kind": "take", "title": "Living room dance", "videoUrl": long.absoluteString,
                                      "durationSec": 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
            if let data = try? JSONSerialization.data(withJSONObject: raw) { take = try? JSONDecoder().decode(Take.self, from: data) }
        }
        if let take {
            store.takes.removeAll { $0.id == take.id }
            store.takes.insert(take, at: 0)
        }
        defer { store.takes.removeAll { $0.id == "rx_learn" } }
        for theme in [ThemeID.c, .a, .b, .d] {
            NSLog("[snapshot] learn %@", theme.rawValue)
            store.themeID = theme
            w.setFrame(NSRect(x: original.minX, y: original.maxY - 800, width: 1280, height: 800), display: true)
            store.openEdit(takeId: nil)
            store.closeRecreate()
            store.learn.reset()
            store.openLearn(.playbook)
            try? await Task.sleep(for: .seconds(2))
            let rules = store.learn.rules ?? []
            has(!rules.isEmpty, "playbook", theme, "\(rules.count) rules in \(LearnFilter.grouped(rules).count) areas")
            check("playbook", theme)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_learn_playbook.png"))
            // The rule editor on the long learned rule: its counter ("271 / 300"), evidence and "Delete rule". Closed with Cancel.
            if let r = rules.first(where: { $0.text.count >= Learn.counterFrom }) ?? rules.first { store.startEditing(r) }
            try? await Task.sleep(for: .seconds(1.5))
            has(store.learn.draft != nil, "playbook_editor", theme, "editor open")
            check("playbook_editor", theme)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_learn_playbook_editor.png"))
            store.cancelRule()
            store.learn.tab = .suggestions
            try? await Task.sleep(for: .seconds(1))
            has(!(store.learn.lessons ?? []).isEmpty, "suggestions", theme, "\(store.learn.lessons?.count ?? 0) suggestions")
            check("suggestions", theme)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_learn_suggestions.png"))
            store.learn.tab = .rules
            store.openLearn(.recipes)
            try? await Task.sleep(for: .seconds(2))
            let recipes = store.learn.recipes ?? []
            has(!recipes.isEmpty, "recipes", theme, "\(recipes.count) recipes, \(store.learn.gaps.count) gaps")
            check("recipes", theme)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_learn_recipes.png"))
            if let r = recipes.first(where: { $0.performance != nil }) ?? recipes.first { await store.selectRecipe(r.id) }
            try? await Task.sleep(for: .seconds(1.5))
            has(store.learn.detail?.recipe != nil, "recipe_detail", theme, "\(store.learn.detail?.name ?? "nothing") with \(store.learn.nearest.count) closest")
            check("recipe_detail", theme)
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_learn_recipe_detail.png"))
            store.closeLearn()
            // The editor with the Claude panel on its Playbook tab (pinned rules, "Open playbook").
            if let take {
                state.claudeTab = 2
                store.openEdit(takeId: take.id)
                try? await Task.sleep(for: .seconds(7))
                has(!store.learn.pinned.isEmpty, "claude_tab", theme, "\(store.learn.pinned.count) pinned rules")
                // Only this tab's own labels: the editor beside the panel is checked by editLayoutShots.
                check("claude_tab", theme) { $0.hasPrefix("Open playbook") || $0.hasPrefix("segment Chat") || $0.hasPrefix("segment History") || $0.hasPrefix("segment Playbook") }
                capture(dir.appendingPathComponent("mac_\(theme.rawValue)_learn_claude_tab.png"))
                state.claudeTab = nil
                store.openEdit(takeId: nil)
                try? await Task.sleep(for: .seconds(1))
            } else {
                lines.append("CUT learn_claude_tab 1280x800 \(theme.rawValue) no test video")
            }
        }
        w.setFrame(original, display: true)
        store.themeID = .a
        store.closeLearn()
        store.openEdit(takeId: nil)
        try? await Task.sleep(for: .seconds(1))
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
        // The learning editor's two pages (Edit → Playbook, Edit → Recipes).
        await check("learn_playbook") { store.openEdit(takeId: nil); store.openLearn(.playbook) }
        await check("learn_recipes") { store.openEdit(takeId: nil); store.openLearn(.recipes) }
        store.closeLearn()
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

    /// The window with its sheet drawn where it sits (a sheet is its own window; the screen can be smaller than the
    /// window on CI, so the two are drawn from their views rather than from a screen grab).
    static func captureWithSheet(_ url: URL, lines: inout [String], label: String) {
        guard let window = mainWindow, let view = window.contentView,
              let sheet = window.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent === window }), let sv = sheet.contentView else {
            lines.append("CUT \(label) sheet not shown")
            capture(url)
            return
        }
        view.layoutSubtreeIfNeeded()
        sv.layoutSubtreeIfNeeded()
        guard let base = view.bitmapImageRepForCachingDisplay(in: view.bounds), let top = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: base)
        sv.cacheDisplay(in: sv.bounds, to: top)
        let size = view.bounds.size
        // The sheet's frame in the content view, bottom-left origin (as the bitmap is drawn).
        let inWindow = window.convertFromScreen(sheet.frame)
        var r = view.convert(inWindow, from: nil)
        if view.isFlipped { r.origin.y = size.height - r.maxY }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        base.draw(in: NSRect(origin: .zero, size: size))
        let shape = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        shape.addClip()
        top.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
        let inside = r.minX >= 0 && r.minY >= 0 && r.maxX <= size.width + 0.5 && r.maxY <= size.height + 0.5
        lines.append("\(inside ? "FITS" : "CUT") \(label) sheet \(Int(r.width))x\(Int(r.height)) in \(Int(size.width))x\(Int(size.height))")
    }

    /// Review mode only: an uncaught Objective-C exception or a fatal signal writes its stack to the log before the app
    /// dies, so CI shows where (the macOS crash report isn't always written on the runner).
    nonisolated static func installCrashLogging() {
        NSSetUncaughtExceptionHandler { e in
            print("CRASH uncaught exception \(e.name.rawValue): \(e.reason ?? "")")
            for s in e.callStackSymbols.prefix(60) { print("CRASH   \(s)") }
            fflush(stdout)
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig) { n in
                print("CRASH signal \(n)")
                for s in Thread.callStackSymbols.prefix(60) { print("CRASH   \(s)") }
                fflush(stdout)
                signal(n, SIG_DFL)
                raise(n)
            }
        }
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

/// Review mode: the Look swatches as the analysis reports them and as the Recipe shows them (mac_recreate_swatches.png).
struct RecreateSwatchSheet: View {
    var raw: [String]
    var soft: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row("As analysed", raw)
            row("As shown in the Recipe", soft)
        }
        .padding(24)
        .frame(width: 640)
        .background(Color(hex: 0xF3F0EA))
    }

    private func row(_ title: String, _ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0x23262A))
            HStack(spacing: 0) { ForEach(list.indices, id: \.self) { i in Color(swatch: list[i]) } }
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 0) {
                ForEach(list.indices, id: \.self) { i in
                    Text(list[i]).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(hex: 0x5E5C57)).frame(maxWidth: .infinity)
                }
            }
        }
    }
}
