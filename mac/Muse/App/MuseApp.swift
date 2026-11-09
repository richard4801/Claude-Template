import AppKit
import Combine
import MuseCore
import Network
import SwiftUI

@main
struct MuseApp: App {
    @State private var store = AppStore()

    init() {
        StartupMetrics.launched()
        Fonts.registerBundled()
    }

    private static var firstSize: CGSize {
        let vis = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(1440, max(960, vis.width)), height: min(900, max(600, vis.height)))
    }

    var body: some Scene {
        Window("MUSE Studio", id: "main") {
            RootView()
                .environment(store)
                .environment(\.theme, store.theme)
                .frame(minWidth: 960, minHeight: 600) // 960: the owner works in a window about 1000 pt wide (coordination item 8); 600: fits a 13" MacBook with the Dock showing (owner fix A2)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .onAppear {
                    store.bootstrap()
                    SnapshotRunner.runIfRequested(store) // review screenshots, only with MUSE_SNAPSHOT_DIR set
                    KeyMonitor.shared.install(store)
                    NetworkWatcher.shared.start { store.resumeLive(force: true) }
                }
                // Back in front, or awake after sleep: restart the live stream and refetch what changed meanwhile.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.resumeLive() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in store.resumeLive(force: true) }
        }
        .windowStyle(.hiddenTitleBar)
        // First launch: 1440 × 900, or the screen's visible area when that is smaller, so nothing starts below the Dock.
        .defaultSize(width: Self.firstSize.width, height: Self.firstSize.height)
        .commands { MuseCommands(store: store) }
    }
}

/// Calls back on the main actor when the network comes back or changes (Wi-Fi to Ethernet, a VPN), so the live stream reconnects at once.
final class NetworkWatcher: @unchecked Sendable {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private var last: NWPath.Status?
    private var started = false

    func start(_ onChange: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let was = self.last
            self.last = path.status
            guard was != nil, path.status == .satisfied else { return }
            Task { @MainActor in onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "muse.network"))
    }
}

/// The menu bar: ⌘1–6 screens, ⌘N new video, ⌘↵ generate, ⌘, settings, ⌘K palette.
@MainActor
struct MuseCommands: Commands {
    let store: AppStore

    private var signedIn: Bool { store.user != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Shot") { store.openTool(.shot) }.keyboardShortcut("n").disabled(!signedIn)
            Button("New Model") { store.go(.create) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!signedIn)
            Button("New Outfit Set…") { store.openOutfitSheet(for: nil) }.disabled(!signedIn)
            Divider()
            Button("Choose Clip…") {
                store.openTool(.swap)
                store.pickClip()
            }
            .keyboardShortcut("o")
            .disabled(!signedIn)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { store.go(.settings) }.keyboardShortcut(",").disabled(!signedIn)
        }
        CommandMenu("Go") {
            ForEach(NavItem.main) { item in
                Button(item.title) { store.go(item.screen) }.keyboardShortcut(KeyEquivalent(item.key)).disabled(!signedIn)
            }
            Button("Templates") { store.openTemplates() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!signedIn)
            Button("Members") { store.openSettings(.members) }.keyboardShortcut("8").disabled(!signedIn || !store.isOwner)
            Divider()
            Button("Credit") { store.go(.credits) }.disabled(!signedIn)
            Divider()
            Button("Command Palette…") { store.openPalette() }.keyboardShortcut("k").disabled(!signedIn)
        }
        CommandMenu("Render") {
            // Generate (⌘↩) lives on the AI Suite composer's own button; the classic studio's menu item is gone (owner 2026-11-08).
            Button("Run Queue") { store.runQueue() }.disabled(!signedIn || !store.jobs.contains(where: \.isQueued))
        }
        CommandMenu("Theme") {
            ForEach(ThemeID.allCases) { id in
                Button((store.themeID == id ? "✓ " : "") + id.name) { store.setTheme(id) }
            }
            Divider()
            Toggle("Pro Mode (Show Prompts)", isOn: Binding(get: { store.pro }, set: { store.pro = $0 }))
        }
    }
}
