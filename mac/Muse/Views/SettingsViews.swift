import MuseCore
import SwiftUI

/// Settings (owner-approved redesign 2026-11-09, plans/settings-redesign.md): six sections and a hidden Advanced, each
/// opening with one plain line. Members see Account, Studio and AI & spending; owner-only parts are hidden from them.
/// Every control that existed before is here: caps, AI editing helpers, models, providers, Claude tokens, Blender,
/// notifications, the server and the test tools.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// Advanced shows in the list only while this is on (Account → "Show advanced settings").
    @AppStorage("showAdvancedSettings") private var showAdvanced = false

    private var sections: [SettingsSection] {
        SettingsSection.allCases.filter { s in
            if s == .advanced { return store.isOwner && showAdvanced }
            return !s.ownerOnly || store.isOwner
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScreenPage {
            ScreenTitle("Settings").id("settings.top")
            HStack(alignment: .top, spacing: Space.s6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections.filter { $0 != .advanced }, id: \.self) { s in
                        SettingsNavRow(title: s.title, on: store.settingsSection == s) { store.openSettings(s) }
                    }
                    if sections.contains(.advanced) {
                        SettingsNavRow(title: SettingsSection.advanced.title, on: store.settingsSection == .advanced) { store.openSettings(.advanced) }
                            .padding(.top, Space.s5)
                    }
                }
                .frame(width: 200)
                VStack(alignment: .leading, spacing: 0) {
                    if !(store.settingsSection == .studio && store.settingsPrompts) {
                        Text(current.intro).scaled(t.scale.body, t.roles.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, Space.s5)
                    }
                    section
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        // Review screenshots only (SnapshotRunner): scroll a section to an anchor.
        .onChange(of: SnapshotRunner.state.scrollTo) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        // Each section (and the Prompts subpage) opens at the top, not where the last one was scrolled to.
        .onChange(of: store.settingsSection) { _, _ in proxy.scrollTo("settings.top", anchor: .top) }
        .onChange(of: store.settingsPrompts) { _, _ in proxy.scrollTo("settings.top", anchor: .top) }
        }
        // A member (or Advanced switched off) never stays on a section they can't see.
        .onAppear { if !sections.contains(store.settingsSection) { store.settingsSection = .account } }
        .onChange(of: showAdvanced) { _, on in if !on && store.settingsSection == .advanced { store.settingsSection = .account } }
    }

    private var current: SettingsSection { sections.contains(store.settingsSection) ? store.settingsSection : .account }

    @ViewBuilder private var section: some View {
        switch current {
        case .account: AccountSettings(showAdvanced: $showAdvanced)
        case .studio: StudioPreferences()
        case .members: MembersView()
        case .spending: SpendingSettings()
        case .providers: ProvidersSettings()
        case .apps: ConnectionsView()
        case .advanced: AdvancedSettings()
        }
    }
}

// MARK: Account

private struct AccountSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var showAdvanced: Bool
    @State private var fontsOpen = false

    var body: some View {
        Group { who; appearance }
        Group { notifications }
        Group { ClaudeFileSettingsSection() }
        Group { about }
    }

    @ViewBuilder private var who: some View {
        let u = store.user
        SettingRow(store.isOwner ? (u?.studioName ?? "Your studio") : (u?.email ?? "You"),
                   hint: store.isOwner ? "\(u?.email ?? ""), owner" : "Member of \(u?.studioName ?? "the studio")") {
            RButton("Sign out", kind: .danger, small: true) { store.signOut() }
        }
    }

    @ViewBuilder private var appearance: some View {
        SectionTitle("Appearance")
        HStack(alignment: .top, spacing: Space.s4) {
            ForEach(ThemeID.allCases) { id in
                let on = id == store.themeID
                let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                Button { store.setTheme(id) } label: {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ThemePreview(theme: Theme.get(id)).aspectRatio(16 / 10, contentMode: .fit)
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: 1))
                            .overlay(shape.strokeBorder(t.roles.selection, lineWidth: on ? 2 : 0).padding(-4))
                        Text(id.name).scaled(t.scale.label, on ? t.roles.ink : t.roles.ink2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Theme: \(id.name)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        @Bindable var store = store
        SectionTitle("Notifications")
        SettingRow("Render finished") { RSwitch(label: "Render finished", isOn: $store.notifyDone) }
        SettingRow("Render failed") { RSwitch(label: "Render failed", isOn: $store.notifyFailed) }
        SettingRow("Balance below $5") { RSwitch(label: "Balance below $5", isOn: $store.notifyLowBalance) }
        SettingRow("Also notify my Android phone", hint: "Sent by the server to the MUSE Android app") {
            RSwitch(label: "Also notify my Android phone", isOn: $store.notifyPhone)
        }
        HStack(spacing: Space.s3) {
            RButton("Send a test notification", small: true) {
                Notifier.shared.post(title: "MUSE test", body: "Notifications are working. Renders will tell you when they finish or fail.")
                store.showToast("Test notification sent. If nothing appears, allow MUSE in System Settings › Notifications.")
            }
            RButton("Sound and banners in System Settings", kind: .plain, small: true) { Notifier.openSystemSettings() }
        }
        .padding(.top, Space.s2)
    }

    @ViewBuilder private var about: some View {
        SectionTitle("About")
        SettingRow("Version") { RowValue("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))") }
        SettingRow("Terms and policies") {
            HStack(spacing: Space.s3) {
                RButton("Terms of Service", kind: .plain, small: true) { store.showToast("The Terms of Service open on the MUSE website") }
                RButton("Acceptable Use", kind: .plain, small: true) { store.showToast("The Acceptable Use Policy opens on the MUSE website") }
            }
        }
        DisclosureRow(title: "Font licences", summary: "SIL OFL and Apache 2.0", open: $fontsOpen)
        if fontsOpen {
            Text("Instrument Serif, Archivo, IBM Plex Mono, Barlow, JetBrains Mono, Outfit, DM Mono, Bricolage Grotesque, Figtree (SIL OFL); Permanent Marker (Apache 2.0)")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true).padding(.leading, Space.s5)
        }
        // The edit content library (WS8 84df583): stickers, sound effects and fonts under their own licences.
        SectionTitle("Licences")
        SettingsContentLicences()
        if store.isOwner {
            SettingRow("Show advanced settings", hint: "Server, testing and performance tools") {
                RSwitch(label: "Show advanced settings", isOn: $showAdvanced)
            }
            .padding(.top, Space.s4)
        }
    }
}

// MARK: Studio

private struct StudioPreferences: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The camera drums' soft click per stop (RigDrum.swift), off by default.
    @AppStorage("rigDrumClick") private var rigDrumClick = false
    @State private var archivedOpen = false

    var body: some View {
        @Bindable var store = store
        if store.settingsPrompts && store.isOwner {
            Crumb(parent: "Studio", title: "Prompts") { store.settingsPrompts = false }
            PromptsSettingsSection()
        } else {
            SectionTitle("New videos and photos", top: 0)
            SettingRow("Start at", hint: "The quality new videos use. Change it per shot in the AI Suite.") {
                RSeg(VideoQuality.renders.map { ($0, $0.label) }, selection: $store.defaultQuality) { store.setQuality($0) }.frame(width: 300)
            }
            SettingRow("Show the prompt behind each render", hint: "Read and edit what the AI is asked to make") {
                RSwitch(label: "Show the prompt behind each render", isOn: $store.pro)
            }
            SettingRow("Click on each camera stop", hint: "A soft tick as the camera wheels turn") {
                RSwitch(label: "Click on each camera stop", isOn: $rigDrumClick)
            }
            SettingRow("Test renders are kept for") { RowValue("30 days") }
            if store.isOwner {
                SectionTitle("Prompts and house style")
                SettingRow("Prompt library", hint: "The house style added to every photo, and each prompt MUSE writes") {
                    RButton("Open prompts", small: true) {
                        store.settingsPrompts = true
                        Task { await store.loadPrompts() }
                    }
                }
                SectionTitle("Archived models")
                SettingRow(ScreenCopy.count(store.archivedModels.count, "archived model"), hint: "Hidden from every list. Their photos, renders and posts are kept.") {
                    RButton(archivedOpen ? "Hide" : "Show", small: true, off: store.archivedModels.isEmpty) { archivedOpen.toggle() }
                }
                if archivedOpen { ArchivedModelsSection() }
            }
        }
    }
}

// MARK: AI & spending

private struct SpendingSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var enginesOpen = false

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .top, spacing: Space.s7) {
            fact("Balance", Pricing.money(store.creditUsd))
            fact("This month", Pricing.money(store.balance.month))
            fact("A 10 s Draft video", "About \(Pricing.money(Pricing.typicalVideo))")
            Spacer(minLength: 0)
            RButton(store.isOwner ? "Add credit" : "Open credit", kind: .action) { store.go(.credits) }
        }
        if store.isOwner {
            // Spend caps (editable) and AI editing helpers, as before.
            StudioSettingsSection().padding(.top, Space.s5)
        } else {
            SectionTitle("Spend caps")
            SettingRow("Per job", hint: "Set by the studio owner") { RowValue(Pricing.money(store.balance.perJobLimit)) }
            SettingRow("My cap per day", hint: "Set by the studio owner") { RowValue(Pricing.money(store.balance.perDayLimit)) }
        }
        SettingRow("Warn me before a job goes over budget") { RSwitch(label: "Warn me before a job goes over budget", isOn: $store.warnOverBudget) }
            .padding(.top, Space.s2)
        if store.isOwner {
            DefaultModelsSettings()
                .task { await store.loadEngines() }
            // 4c: model choice for everyone: the provider-name switch and "Hide from members" per model.
            MemberModelsSettings()
                .padding(.top, Space.s4)
            DisclosureRow(title: "Models and our own GPUs", summary: "Status, GPU limits, the photo service and price corrections", open: $enginesOpen)
                .padding(.top, Space.s4)
            if enginesOpen {
                EnginesSettingsSection()
                SuiteEnginesPanel(estimate: nil).frame(maxWidth: 560)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value).monospacedDigit().scaled(t.scale.title, t.roles.ink)
        }
    }
}

// MARK: Advanced

private struct AdvancedSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        SectionTitle("Server", top: 0)
        Text("MUSE talks to the MUSE server by default (\(defaultServerURL)). Demo mode runs everything inside the app with sample data and no account. You can also point MUSE at another server, such as a local server/api or server/mock. Each server keeps its own sign-in.")
            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Space.s2)
        RSeg(DataSource.allCases.map { ($0, $0.label) }, selection: $store.dataSource) { _ in store.applyDataSource() }.frame(maxWidth: 460)
        RField("Server address", hint: "Remote servers need HTTPS. Plain HTTP works for this Mac and the local network only.") {
            HStack(spacing: Space.s2) {
                RTextField(placeholder: defaultServerURL, text: $store.baseURL) { store.applyDataSource() }
                RButton("Reconnect") { store.applyDataSource() }
                RButton("Test connection") { store.testConnection() }
                if store.baseURL != defaultServerURL {
                    RButton("Use the MUSE server", kind: .plain) {
                        store.baseURL = defaultServerURL
                        store.applyDataSource()
                    }
                }
            }
        }
        .padding(.top, Space.s3)
        .opacity(store.dataSource == .http ? 1 : 0.5)
        if let msg = store.offlineMessage {
            InlineNotice("\(msg) Check the address, then Test connection.", tone: .caution).padding(.top, Space.s2)
        }
        SectionTitle("Testing")
        SettingRow("Fail the next render", hint: "It stops partway and the cost is refunded, to test failure handling and notifications. Demo mode, server/mock and dev servers only.") {
            RButton("Fail next render", small: true) { store.setFailNext() }
        }
        SettingRow("Reload everything", hint: "Fetches models, outfits, jobs, takes and balance again.") {
            RButton("Reload", small: true) { Task { await store.forceReload() } }
        }
        SectionTitle("Performance")
        PerfReadout()
    }
}

/// A row that opens and closes a group of rarely used settings (progressive disclosure): a chevron, the title and a
/// one-line summary of what's inside.
struct DisclosureRow: View {
    @Environment(\.theme) private var t
    var title: String
    var summary: String
    @Binding var open: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
            HStack(spacing: Space.s2) {
                Ph(open ? "chevron.down" : "chevron.right", 12).foregroundStyle(t.roles.ink2).frame(width: 14)
                Text(title).scaled(t.scale.body, t.roles.ink)
                Text(summary).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(open ? "hide" : "show")")
    }
}

/// A Settings section in the list on the left: text only, the selected one on the `field` tone with the accent mark.
/// Also used by Settings → Connections (SuiteConnectionsRow), so every item in the list looks the same.
struct SettingsNavRow: View {
    @Environment(\.theme) private var t
    var title: String
    var on: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        Button(action: action) {
            Text(title).font(t.scale.label.font).lineLimit(1)
                .foregroundStyle(on || hover ? t.roles.ink : t.roles.ink2)
                .padding(.horizontal, Space.s3)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(on ? t.roles.field : hover ? t.roles.field.opacity(0.6) : .clear))
                .overlay(shape.strokeBorder(t.roles.selection, lineWidth: on && t.isD ? 2 : 0))
                .overlay(alignment: .leading) { if on && !t.isD { Capsule().fill(t.roles.accent).frame(width: 3, height: 16) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A tiny drawing of the app in a theme, for the Appearance picker.
struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        let t = theme
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                t.bg
                Rectangle().fill(t.isD ? t.blue : t.chrome).frame(width: w * 0.22)
                    .overlay(alignment: .trailing) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(width: 1) }
                VStack(alignment: .leading, spacing: h * 0.03) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: t.isA ? 0 : 2).fill(i == 0 ? (t.isD ? t.yellow : t.accent) : (t.isD ? Color.white.opacity(0.6) : t.muted.opacity(0.4)))
                            .frame(width: w * 0.14, height: h * 0.04)
                    }
                }
                .padding(.leading, w * 0.04).padding(.top, h * 0.2)
                VStack(alignment: .leading, spacing: h * 0.05) {
                    RoundedRectangle(cornerRadius: 1).fill(t.ink).frame(width: w * 0.3, height: h * 0.07)
                    HStack(spacing: w * 0.025) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: t.isA ? 0 : t.rLg * 0.2)
                                .fill(t.isD ? [t.yellow, t.pink, t.mint][i] : t.isA ? .clear : t.surface)
                                .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : t.rLg * 0.2).strokeBorder(t.isC ? .clear : t.strongLine, lineWidth: t.isD ? 1.5 : 0.5))
                                .background(RoundedRectangle(cornerRadius: t.isA ? 0 : t.rLg * 0.2).fill(t.isD ? Color(hex: 0x111111) : .clear).offset(x: 2, y: 2))
                                .shadow(color: t.isC ? .black.opacity(0.12) : .clear, radius: 3, x: 2, y: 2)
                                .frame(height: h * 0.28)
                        }
                    }
                    RoundedRectangle(cornerRadius: t.isC ? h * 0.05 : t.isA ? 0 : 2).fill(t.cta).frame(width: w * 0.22, height: h * 0.1)
                }
                .padding(.leading, w * 0.28).padding(.trailing, w * 0.05).padding(.top, h * 0.14)
            }
        }
    }
}
