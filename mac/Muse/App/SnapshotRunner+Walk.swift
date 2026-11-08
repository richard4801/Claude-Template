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
        store.go(.home)
        try? await Task.sleep(for: .seconds(1.5))
        let home = await ax.controls().controls
        let chrome = Set(home.map(\.key))
        // Outfits: the angle tiles open the full view; its next, previous, zoom, fit and close all work.
        await walkScreen("outfit_lightbox", ax: ax, chrome: chrome, minimum: 6,
                         deny: ["Make 4 angles", "Retake", "Choose files", "Use my images", "Save outfit"],
                         required: ["View front full size", "Next (→)", "Previous (←)", "Zoom in (=)", "Close (Esc)"],
                         open: { store.go(.models); store.outfitSheet = demoOutfitDraft() },
                         isOpen: { store.outfitSheet != nil },
                         note: note)
        store.outfitSheet = nil
    }

    /// Opens a screen and presses each of its controls once (sliders nudged), reopening it when a control leaves it.
    /// `deny` are label prefixes never pressed (spending, file panels); `required` labels must have been pressed.
    static func walkScreen(_ name: String, ax: AXWalker, chrome: Set<String>, minimum: Int, deny: [String], required: [String] = [],
                           open: @MainActor () -> Void, isOpen: @MainActor () -> Bool, note: (String) -> Void) async {
        note("START walk_\(name)")
        open()
        try? await Task.sleep(for: .seconds(1.5))
        var used = Set<String>(), skipped = Set<String>(), pressedLabels = Set<String>()
        var presses = 0
        for _ in 0..<300 {
            let scan = await ax.controls().controls
            var pick: AXWalker.Control?
            for c in scan where !used.contains(c.key) && !skipped.contains(c.key) && !chrome.contains(c.key) {
                if c.isMenu || deny.contains(where: { c.label.hasPrefix($0) }) {
                    skipped.insert(c.key)
                    note("SKIP \(c.role) \(c.label)")
                    continue
                }
                pick = c
                break
            }
            guard let c = pick else { break }
            used.insert(c.key)
            pressedLabels.insert(c.label)
            note("\(c.isSlider ? "NUDGE" : "PRESS") \(c.role) \(c.label)")
            if c.isSlider { await ax.increment(c) } else { await ax.press(c) }
            presses += 1
            try? await Task.sleep(for: .seconds(0.4))
            if !isOpen() {
                note("LEFT \(name) via \(c.label); reopening")
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
