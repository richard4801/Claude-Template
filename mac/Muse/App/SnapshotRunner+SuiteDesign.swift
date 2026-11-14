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

        store.setSwapVariant(.classic)
        w.setFrame(full, display: true)
        try? await Task.sleep(for: .seconds(1))
        lines.append("ALL DONE")
        write()
    }
}
