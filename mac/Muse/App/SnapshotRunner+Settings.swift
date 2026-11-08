import AppKit
import MuseCore
import SwiftUI

// Settings redesign (owner request 2026-11-08, plans/settings-redesign.md): today's Settings, one shot per section
// (`mac_settingsbefore_<section>.png`, Soft Tactile), and the proposed structure's mock in the four themes at 1280 × 800
// (`mac_settingsmock_<theme>_<shot>.png`), for the owner's approval before it is built.
extension SnapshotRunner {
    static func settingsMockShots(_ store: AppStore, dir: URL) async {
        guard let w = mainWindow else { return }
        let full = w.frame
        w.setFrame(NSRect(x: full.minX, y: full.maxY - 800, width: 1280, height: 800), display: true)
        defer {
            state.settingsMock = nil
            w.setFrame(full, display: true)
        }
        // Settle first: a theme change and a screen change in the same tick, right after the resize, left the previous
        // screen (the Suite) drawn under a highlighted Settings (run 42523890409).
        state.overlay = nil
        store.go(.home)
        try? await Task.sleep(for: .seconds(2))
        store.themeID = .c
        try? await Task.sleep(for: .seconds(1))
        store.openSettings(.appearance)
        try? await Task.sleep(for: .seconds(3))
        for section in SettingsSection.allCases {
            state.settingsMock = nil
            store.openSettings(section)
            try? await Task.sleep(for: .seconds(1.5))
            capture(dir.appendingPathComponent("mac_settingsbefore_\(section.rawValue).png"))
        }
        let shots: [(String, SettingsMockState)] = [
            ("account", SettingsMockState(section: .account)),
            ("studio", SettingsMockState(section: .studio)),
            ("members", SettingsMockState(section: .members)),
            ("spending", SettingsMockState(section: .spending)),
            ("spending_models", SettingsMockState(section: .spending, modelsOnly: true)),
            ("providers_empty", SettingsMockState(section: .providers, providers: "empty")),
            ("providers_add", SettingsMockState(section: .providers, providers: "add")),
            ("providers_nokeys", SettingsMockState(section: .providers, providers: "nokeys")),
            ("providers", SettingsMockState(section: .providers, providers: "models")),
            ("apps", SettingsMockState(section: .apps)),
            ("advanced", SettingsMockState(section: .advanced)),
            ("member_account", SettingsMockState(section: .account, member: true)),
            ("member_spending", SettingsMockState(section: .spending, member: true)),
        ]
        for theme in [ThemeID.c, .a, .b, .d] {
            store.themeID = theme
            try? await Task.sleep(for: .seconds(1))
            for (name, mock) in shots {
                NSLog("[snapshot] settings mock %@ %@", name, theme.rawValue)
                state.settingsMock = mock
                try? await Task.sleep(for: .seconds(1.2))
                capture(dir.appendingPathComponent("mac_settingsmock_\(theme.rawValue)_\(name).png"))
            }
        }
        store.themeID = .a
    }
}
