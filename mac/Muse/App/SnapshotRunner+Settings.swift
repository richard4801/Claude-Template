import AppKit
import MuseCore
import SwiftUI

// Settings (owner-approved redesign 2026-11-09, plans/settings-redesign.md): every section at 1280 × 800 in the four
// themes (`mac_settings_<theme>_<section>.png`), Providers' add-a-key form and a connected provider with its models,
// Studio's Prompts page and AI & spending's Default models, plus a click-through of each section (SnapshotRunner+Walk).
extension SnapshotRunner {
    static func settingsShots(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1280, height: 800), display: true)
        defer {
            UserDefaults.standard.set(false, forKey: "showAdvancedSettings")
            w.setFrame(full, display: true)
        }
        // Settle first: a theme change and a screen change in the same tick, right after a resize, can leave the
        // previous screen drawn (run 42523890409).
        state.overlay = nil
        store.go(.home)
        try? await Task.sleep(for: .seconds(2))
        UserDefaults.standard.set(true, forKey: "showAdvancedSettings")
        // A connected demo provider with one model on, for the Providers shots.
        if let api = store.providersAPI, (try? await api.providers().providers.isEmpty) ?? false,
           let p = try? await api.addProvider(kind: "fal", apiKey: "fal_demo_key_0000_4f2a", label: nil),
           let first = try? await api.providerModels(p.id, query: "", kind: nil, cursor: nil).models.first,
           let c = try? await api.addProviderModel(p.id, ref: first.ref, displayName: nil) {
            _ = try? await api.updateCustomModel(c.id, enabled: true, displayName: nil)
        }
        let shots: [(String, @MainActor () -> Void)] = [
            ("account", { store.openSettings(.account) }),
            ("studio", { store.openSettings(.studio) }),
            ("studio_prompts", { store.openSettings(.studio); store.settingsPrompts = true }),
            ("members", { store.openSettings(.members) }),
            ("spending", { store.openSettings(.spending) }),
            ("spending_models", { store.openSettings(.spending); state.scrollTo = "settings.models" }),
            ("providers", { store.openSettings(.providers) }),
            ("providers_add", { store.openSettings(.providers); store.openProviderForm() }),
            ("apps", { store.openSettings(.apps) }),
            ("advanced", { store.openSettings(.advanced) }),
        ]
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            try? await Task.sleep(for: .seconds(1))
            store.openSettings(.account)
            try? await Task.sleep(for: .seconds(2))
            for (name, show) in shots {
                NSLog("[snapshot] settings %@ %@", name, theme.rawValue)
                state.scrollTo = nil
                store.closeProviderForm()
                store.settingsPrompts = false
                show()
                try? await Task.sleep(for: .seconds(1.2))
                capture(dir.appendingPathComponent("mac_settings_\(theme.rawValue)_\(name).png"))
            }
        }
        store.closeProviderForm()
        store.settingsPrompts = false
        state.scrollTo = nil
        store.themeID = .a
    }
}
