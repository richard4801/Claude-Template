import AppKit
import ApplicationServices
import MuseCore
import SwiftUI

// Click-through for the screens added in round 2 (owner 2026-11-08): every control on them is pressed once through the
// Accessibility API, like the Edit suite's walk (SnapshotRunner+Edit.swift). Anything that spends, opens a blocking file
// panel or a menu is skipped and logged as SKIP. The lines go to edit-check.txt; a FAIL line fails Mac CI.
extension SnapshotRunner {
    /// A new outfit with its four angles made, as the outfit sheet shows them once generated (demo stills).
    static func demoOutfitDraft() -> OutfitDraft {
        var d = OutfitDraft(modelId: SampleData.demo)
        d.description = "sheer crystal mini dress, silver strappy heels"
        d.state = .done
        d.angles = ["dressa_front", "dressa_tq", "dressa_side", "dressa_back"].map { ImageRef.asset($0) }
        return d
    }

    /// The outfit sheet with its angles, and the angle open full size, at 1280 × 800 in the four themes
    /// (`mac_<theme>_outfit_sheet.png`, `mac_<theme>_outfit_lightbox.png`).
    static func outfitShots(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1280, height: 800), display: true)
        defer { w.setFrame(full, display: true) }
        store.go(.models)
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            store.outfitSheet = demoOutfitDraft()
            try? await Task.sleep(for: .seconds(1.2))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_outfit_sheet.png"))
            store.outfitSheet?.viewing = 1
            try? await Task.sleep(for: .seconds(1.2))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_outfit_lightbox.png"))
        }
        store.outfitSheet = nil
        store.themeID = .a
    }

    /// Runs every round-2 screen's walk; called from editCheck before its ALL DONE.
    static func screensWalk(_ store: AppStore, note: (String) -> Void) async {
        let ax = AXWalker()
        store.outfitSheet = nil
        // Outfits: the angle tiles open the full view; its next, previous, zoom, fit and close all work.
        await walkScreen("outfit_lightbox", ax: ax, minimum: 6,
                         // Spending, the file panel (the drop zone's label ends "Choose files"), and the sheet's own controls that
                         // would close it or clear the angles (Close, the mode switch): the walk is about the full view.
                         deny: ["Make 4 angles", "Retake", "Choose files", "Use my images", "Save outfit", "Drop "],
                         denyExact: ["Close", "Describe it", "From a photo", "My own set"],
                         // The viewer's own Close goes last, after its arrows and zoom (the top bar comes first in tree order).
                         last: ["Close (Esc)"],
                         required: ["View front full size", "Next (→)", "Previous (←)", "Zoom in (=)", "Close (Esc)"],
                         base: { store.go(.models) },
                         open: { store.outfitSheet = demoOutfitDraft() },
                         isOpen: { store.outfitSheet != nil },
                         note: note)
        store.outfitSheet = nil
        // The owner's model picker: Auto and every model's resolutions pin without spending (Generate isn't in the list).
        await walkScreen("model_picker", ax: ax, minimum: 8, deny: ["Generate"],
                         only: { $0.hasPrefix("Use ") },
                         required: ["Use Auto", "Use Veo 3.1 Lite at 720p"],
                         base: { store.openTool(.shot); fillDemoDraft(store) },
                         open: { state.overlay = "model_picker" },
                         isOpen: { state.overlay == "model_picker" && store.screen == .suite },
                         note: note)
        let pinned = store.suite.composer.engineModel
        note(pinned == nil || ComposerModelPicker.engines(store.suite.catalog, store.suite.settings).contains { $0.model == pinned }
             ? "DONE model_picker pin \(pinned ?? "Auto"), \(store.suite.composer.duration) s, \(store.suite.composer.aspect)"
             : "FAIL model_picker: pinned an unknown model \(pinned ?? "")")
        state.overlay = nil
        store.pinComposerModel(nil)
        // Import a video from a link (demo mode imports at once, nothing is downloaded or spent). "Choose a file instead"
        // opens a modal file panel, so it's skipped.
        await walkScreen("link_import", ax: ax, minimum: 3, deny: ["Choose a file instead"],
                         required: ["Import", "Cancel"],
                         base: { store.openTool(.swap) },
                         open: { store.openLinkImport(.swap); store.linkImport.text = demoImportLink },
                         isOpen: { store.linkImport.open },
                         note: note)
        note(store.clip != nil ? "DONE link_import swap source \(store.clip?.name ?? "")" : "FAIL link_import: no swap source after importing")
        store.closeLinkImport()
    }

    static let demoImportLink = "https://www.tiktok.com/@muse.demo/video/7300000000000000000"

    /// The import sheet over Swap, over the Library with a link that strict rules refuse, and Edit's media bin entry, at
    /// 1280 × 800 in the four themes (`mac_<theme>_link_import.png`, `…_link_import_problem.png`).
    static func linkImportShots(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1280, height: 800), display: true)
        defer { w.setFrame(full, display: true) }
        store.go(.home)
        try? await Task.sleep(for: .seconds(2))
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            try? await Task.sleep(for: .seconds(1))
            store.openTool(.swap)
            try? await Task.sleep(for: .seconds(2))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_swap_source.png"))
            store.openLinkImport(.swap)
            store.linkImport.text = demoImportLink
            try? await Task.sleep(for: .seconds(1.2))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_link_import.png"))
            store.closeLinkImport()
            store.go(.gallery)
            try? await Task.sleep(for: .seconds(2.5))
            store.openLinkImport(.library)
            store.linkImport.text = "https://vimeo.com/123456"
            store.startLinkImport()
            try? await Task.sleep(for: .seconds(1.2))
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_link_import_problem.png"))
            store.closeLinkImport()
        }
        store.themeID = .a
    }

    /// Shows `base`, takes every control on it as chrome (not walked), then opens the screen under test and presses each
    /// of its controls once (sliders nudged), reopening it when a control leaves it. `only` limits it to its own controls. `deny` are label parts never
    /// pressed (spending, file panels); `required` labels must have been pressed.
    static func walkScreen(_ name: String, ax: AXWalker, minimum: Int, deny: [String], denyExact: Set<String> = [], only: ((String) -> Bool)? = nil, last: Set<String> = [], required: [String] = [],
                           base: @MainActor () -> Void, open: @MainActor () -> Void, isOpen: @MainActor () -> Bool,
                           note: (String) -> Void) async {
        note("START walk_\(name)")
        base()
        try? await Task.sleep(for: .seconds(1.5))
        let before = await ax.controls().controls
        let chrome = Set(before.map(\.key))
        open()
        try? await Task.sleep(for: .seconds(1.5))
        var used = Set<String>(), skipped = Set<String>(), pressedLabels = Set<String>()
        var presses = 0
        for _ in 0..<300 {
            let scan = await ax.controls().controls
            var pick: AXWalker.Control?
            var deferred: AXWalker.Control?
            for c in scan where !used.contains(c.key) && !skipped.contains(c.key) && !chrome.contains(c.key) && (only?(c.label) ?? true) {
                if c.isMenu || denyExact.contains(c.label) || deny.contains(where: { c.label.hasPrefix($0) || c.label.contains($0) }) {
                    skipped.insert(c.key)
                    note("SKIP \(c.role) \(c.label)")
                    continue
                }
                if last.contains(c.label) {
                    if deferred == nil { deferred = c }
                    continue
                }
                pick = c
                break
            }
            guard let c = pick ?? deferred else { break }
            used.insert(c.key)
            pressedLabels.insert(c.label)
            note("\(c.isSlider ? "NUDGE" : "PRESS") \(c.role) \(c.label)")
            if c.isSlider { await ax.increment(c) } else { await ax.press(c) }
            presses += 1
            try? await Task.sleep(for: .seconds(0.4))
            if !isOpen() {
                note("LEFT \(name) via \(c.label); reopening")
                base()
                open()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if let w = mainWindow, let sh = w.attachedSheet { w.endSheet(sh) }
        let missing = required.filter { !pressedLabels.contains($0) }
        if !missing.isEmpty { note("FAIL walk_\(name): never pressed \(missing.joined(separator: ", "))") }
        if presses < minimum { note("FAIL walk_\(name): only \(presses) controls found (expected \(minimum) or more)") }
        note("DONE walk_\(name) (\(presses) pressed, \(skipped.count) skipped)")
    }
}
