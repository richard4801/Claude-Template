import AppKit
import MuseCore

// The Video suite redesign (owner-approved 2026-11-14, plans/design/suite-redesign/): the approved frames' screens at the
// frames' own size (1152 × 720), Editorial (light) and Camera Body (dark), for the side-by-side with the PNGs:
//   mac_<a|b>_design_home_1152x720.png         frame 5 "Suite home"
//   mac_<a|b>_design_shot_1152x720.png         frame 4 "Shot composer" (a finished take on the stage)
//   mac_<a|b>_design_swap_empty_1152x720.png   frame 2 "New Swap, empty"
//   mac_<a|b>_design_swap_filled_1152x720.png  frames 1 and 3 "New Swap, filled" light and dark
// and suite-design-check.txt, which Mac CI reads (FAIL fails the run):
//   home_no_generate   Home draws no Generate (owner decision 1: its button only opens the composer)
//   home_opens_shot    "Open in composer" opens Shot with the prompt carried over and starts no job
//   price_on_generate  on Shot and the filled Swap, Generate shows its price ("· $x" or "· Free")
// and the Photo tab (owner-approved 2026-11-14, plans/design/photo/): mac_<a|b>_photo_<empty|filled|results>_<w>x<h>.png at
// 1000 × 700, 1152 × 720 and 1440 × 900, with photo_fits, photo_price, photo_empty_stage, photo_carousel and photo_presets.
extension SnapshotRunner {
    static func suiteDesignShots(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        var lines: [String] = ["START suite design check"]
        let file = dir.appendingPathComponent("suite-design-check.txt")
        func write() { try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8) }
        func line(_ ok: Bool, _ name: String, _ detail: String) {
            lines.append("\(ok ? "PASS" : "FAIL") \(name) · \(detail)")
            NSLog("[snapshot] suite design %@ %@", ok ? "PASS" : "FAIL", name)
            write()
        }
        write()

        let screens: [(String, @MainActor () -> Void)] = [
            ("home", { store.suite.composer.tokens = PromptTokens(); store.openSuite(.hub) }),
            ("shot", { store.openTool(.shot); fillDemoDraft(store); store.suite.composer.aspect = "9:16"
                if let j = store.suiteTakes(photo: false).compactMap(\.jobId).first { store.rememberStage(j, tool: .shot) } }),
            ("swap_empty", { store.openTool(.swap); store.setSwapVariant(.remix); store.clip = nil; store.clipVideo = nil }),
            ("swap_filled", { store.openTool(.swap); store.setSwapVariant(.remix)
                store.suite.remix.backgroundOn = true; store.suite.remix.backgroundMode = .describe
                store.suite.remix.backgroundWords = "A rooftop at golden hour, city lights behind her"
                store.suite.remix.outfitOn = true
                store.suite.remix.outfitId = store.outfits(for: store.character(SampleData.demo)).first?.id // the frame's "Hoodie": one of her outfits
                store.suite.remix.lookOn = false
                Task { await store.useSampleClip(bad: false, quiet: true) } }),
        ]
        for theme in [ThemeID.a, .b] {
            store.themeID = theme
            w.setFrame(NSRect(x: full.minX, y: full.maxY - 720, width: 1152, height: 720), display: true)
            for (name, show) in screens {
                NSLog("[snapshot] design %@ %@", name, theme.rawValue)
                store.suite.picker = nil
                store.suite.browserOpen = false
                store.suite.feedOpen = false
                store.suite.compareIds = []
                store.suite.viewerTakeId = nil
                store.suite.claude.open = false
                state.generateFrame = nil
                state.generateLabel = nil
                show()
                try? await Task.sleep(for: .seconds(2))
                // Only a Generate on screen now answers the probe tick (run 635: a frame left by the screen before read as drawn).
                state.generateFrame = nil
                state.generateLabel = nil
                state.probeTick += 1
                try? await Task.sleep(for: .seconds(0.3))
                w.contentView?.layoutSubtreeIfNeeded()
                let g = state.generateLabel ?? ""
                switch name {
                case "home":
                    line(state.generateFrame == nil, "home_no_generate", "\(theme.rawValue) Generate \(state.generateFrame == nil ? "not drawn" : "drawn (\"\(g)\")")")
                case "shot", "swap_filled":
                    let priced = g.contains(" · $") || g.hasSuffix(" · Free")
                    line(priced, "price_on_generate", "\(name) \(theme.rawValue) \"\(g)\"")
                default:
                    break
                }
                capture(dir.appendingPathComponent("mac_\(theme.rawValue)_design_\(name)_1152x720.png"))
            }
        }

        // Owner decision 1: Home's button opens Shot with the prompt and spends nothing.
        store.themeID = .a
        store.openSuite(.hub)
        store.suite.composer.tokens = PromptTokens.text("dances on a rooftop at golden hour")
        try? await Task.sleep(for: .seconds(1))
        let jobsBefore = store.jobs.count
        let generatingBefore = store.suite.generating
        store.openTool(.shot) // what "Open in composer" does (SuiteQuickBar)
        try? await Task.sleep(for: .seconds(1.5))
        let words = store.suite.composer.tokens.parts.compactMap(\.text).joined()
        let ok = store.suite.mode == .shot && store.suite.composer.tool == .shot && words.contains("rooftop at golden hour")
            && store.jobs.count == jobsBefore && !generatingBefore && !store.suite.generating
        line(ok, "home_opens_shot", "mode \(store.suite.mode.rawValue), prompt \"\(words.trimmingCharacters(in: .whitespaces))\", jobs \(jobsBefore) → \(store.jobs.count)")

        // The Photo tab (owner-approved 2026-11-14, plans/design/photo/): empty, filled and 4 photos, A and B, at 1000 × 700,
        // 1152 × 720 and 1440 × 900 (mac_<a|b>_photo_<state>_<w>x<h>.png), checked:
        //   photo_fits         Generate whole inside the window (the page never runs below it)
        //   photo_price        filled and results: Generate shows the estimate's price ("Generate · 4 photos · $x")
        //   photo_empty_stage  empty and filled: no old result on the stage before this session's run
        //   photo_carousel     results: the run's 4 photos on the stage, with the strip under the photo
        //   photo_presets      no "Start from a preset" row: the Preset chip is in the bar
        func until(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if ok() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return ok()
        }
        func photoState(_ filled: Bool) {
            store.openTool(.photo)
            store.suite.photo.presetId = nil
            store.suite.photo.references = []
            store.suite.photo.count = 4
            if filled {
                store.suite.composer.tokens = PromptTokens.text(" on a rooftop at golden hour, laughing, one hand in her hair, city soft behind. ")
                store.setComposerCharacter(store.character(SampleData.demo))
                store.suite.photo.aspect = "4:5"
            } else {
                store.setComposerCharacter(nil)
                store.suite.composer.tokens = PromptTokens()
                store.suite.photo.aspect = nil
            }
        }
        // One demo run (FakeMuseAPI: nothing is spent) for the results frames.
        store.themeID = .a
        store.suite.photoSessionJobs = []
        photoState(true)
        await store.estimatePhoto()
        let jobsBefore4 = Set(store.jobs.map(\.id))
        store.generatePhoto()
        _ = await until(15) { store.jobs.contains { !jobsBefore4.contains($0.id) && $0.isPhoto && $0.isDone } }
        let photoRun = store.jobs.first { !jobsBefore4.contains($0.id) && $0.isPhoto }?.id
        for theme in [ThemeID.a, .b] {
            store.themeID = theme
            for (width, height) in [(1000, 700), (1152, 720), (1440, 900)] {
                w.setFrame(NSRect(x: full.minX, y: full.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
                for name in ["empty", "filled", "results"] {
                    store.suite.picker = nil
                    store.suite.browserOpen = false
                    store.suite.feedOpen = false
                    store.suite.compareIds = []
                    store.suite.claude.open = false
                    store.suite.photoSessionJobs = name == "results" ? Set([photoRun].compactMap { $0 }) : []
                    photoState(name != "empty")
                    state.generateFrame = nil
                    state.generateLabel = nil
                    try? await Task.sleep(for: .seconds(2))
                    state.generateFrame = nil
                    state.generateLabel = nil
                    state.probeTick += 1
                    try? await Task.sleep(for: .seconds(0.3))
                    w.contentView?.layoutSubtreeIfNeeded()
                    let content = w.contentView?.bounds.size ?? .zero
                    let label = "\(name) \(theme.rawValue) \(width)x\(height)"
                    let g = state.generateLabel ?? ""
                    if let f = state.generateFrame {
                        let inside = f.minX >= 0 && f.minY >= 0 && f.maxX <= content.width + 0.5 && f.maxY <= content.height + 0.5
                        line(inside, "photo_fits", "\(label) Generate at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) in \(Int(content.width))x\(Int(content.height))")
                    } else {
                        line(false, "photo_fits", "\(label) Generate not drawn")
                    }
                    let frames = state.composerFrames
                    if name != "empty" {
                        line(g.contains(" · $") || g.hasSuffix(" · Free"), "photo_price", "\(label) \"\(g)\"")
                    } else {
                        line(g.hasPrefix("Generate · ") && !g.contains("—"), "photo_price", "\(label) empty reads \"\(g)\", blocker \(frames["photo blocker"] != nil ? "drawn" : "not drawn")")
                    }
                    if name == "results" {
                        let four = frames.keys.contains { $0.hasPrefix("stage carousel ") && $0.hasSuffix("/4") }
                        line(four && frames["stage photo strip"] != nil, "photo_carousel", "\(label) carousel \(four), strip \(frames["stage photo strip"] != nil)")
                    } else {
                        line(frames["stage ready"] == nil, "photo_empty_stage", "\(label) stage \(frames["stage ready"] == nil ? "empty" : "shows an old result")")
                    }
                    line(frames["pill preset"] != nil, "photo_presets", "\(label) Preset chip \(frames["pill preset"] != nil ? "in the bar" : "missing")")
                    if let r = frames["photo rail end"] {
                        lines.append("INFO photo_rail \(label) last row ends at \(Int(r.maxY)) of \(Int(content.height))")
                    }
                    capture(dir.appendingPathComponent("mac_\(theme.rawValue)_photo_\(name)_\(width)x\(height).png"))
                }
            }
        }
        store.suite.photoSessionJobs = []
        store.themeID = .a

        store.setSwapVariant(.classic)
        w.setFrame(full, display: true)
        try? await Task.sleep(for: .seconds(1))
        lines.append("ALL DONE")
        write()
    }
}
