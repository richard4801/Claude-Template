import MuseCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The camera drums' soft click per stop (RigDrum.swift), off by default.
    @AppStorage("rigDrumClick") private var rigDrumClick = false

    var body: some View {
        @Bindable var store = store
        ScrollViewReader { proxy in
        ScreenPage {
            ScreenTitle("Settings")
            HStack(alignment: .top, spacing: Space.s6) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases.filter { !$0.ownerOnly || store.isOwner }, id: \.self) { s in
                        SettingsNavRow(title: s.title, on: store.settingsSection == s) { store.settingsSection = s }
                    }
                }
                .frame(width: 200)
                VStack(alignment: .leading, spacing: Space.s2) { section }
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
        // Review screenshots only (SnapshotRunner): scroll a section to an anchor.
        .onChange(of: SnapshotRunner.state.scrollTo) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        }
    }

    @ViewBuilder private var section: some View {
        @Bindable var store = store
        switch store.settingsSection {
        case .appearance:
            SectionTitle("Theme", top: 0)
            HStack(alignment: .top, spacing: Space.s5) {
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
            SectionTitle("Prompts")
            SettingRow("Pro mode", hint: "Show and edit the prompts behind every render") { RSwitch(label: "Pro mode", isOn: $store.pro) }
            SettingRow("Click on each camera stop", hint: "A soft tick as the camera drums turn") { RSwitch(label: "Click on each camera stop", isOn: $rigDrumClick) }
        case .defaults:
            SectionTitle("Render defaults", top: 0)
            SettingRow("Default render", hint: "Add-ons (Edit, Fast, in beta) are picked per video") {
                RSeg(VideoQuality.renders.map { ($0, $0.label) }, selection: $store.defaultQuality) { store.setQuality($0) }.frame(width: 300)
            }
            SettingRow("Export size", hint: "Export saves the render as it was made") { RowValue("9:16, as rendered") }
            SettingRow("Keep test renders for") { RowValue("30 days") }
            if store.isOwner {
                SectionTitle("House style")
                SettingRow("House style and never-add lists", hint: "The house style added to every photo prompt is under Prompts. Never-add lists are set per model.") {
                    RButton("Open Prompts", kind: .plain, small: true) { store.settingsSection = .prompts }
                }
            }
        case .costs:
            SectionTitle("Costs and limits", top: 0)
            HStack(alignment: .top, spacing: Space.s7) {
                fact("Balance", Pricing.money(store.creditUsd))
                fact("This month", Pricing.money(store.balance.month))
                fact("Draft video (10 s)", "About \(Pricing.money(Pricing.typicalVideo))")
                Spacer(minLength: 0)
            }
            .padding(.bottom, Space.s4)
            SettingRow("Spend cap per job", hint: store.isOwner ? "Change it under Studio" : "Set by the studio owner") { RowValue(Pricing.money(store.balance.perJobLimit)) }
            SettingRow(store.isMember ? "My cap per day" : "Spend cap per day") { RowValue(Pricing.money(store.balance.perDayLimit)) }
            SettingRow("Warn before a job goes over budget") { RSwitch(label: "Warn before a job goes over budget", isOn: $store.warnOverBudget) }
            RButton("Open credit", kind: .action) { store.go(.credits) }.padding(.top, Space.s4)
        case .studio:
            StudioSettingsSection()
        case .engines:
            EnginesSettingsSection()
            if store.isOwner { SuiteEnginesPanel(estimate: nil).frame(maxWidth: 560) } // AI suite (workstream 1): D9, the Video suite's engines
        case .prompts:
            PromptsSettingsSection()
        case .archived:
            ArchivedModelsSection()
        case .notif:
            SectionTitle("Notifications", top: 0)
            SettingRow("Alerts and sound", hint: "Follow your Mac's notification settings") {
                RButton("Open System Settings", small: true) { Notifier.openSystemSettings() }
            }
            SettingRow("Render finished") { RSwitch(label: "Render finished", isOn: $store.notifyDone) }
            SettingRow("Render failed") { RSwitch(label: "Render failed", isOn: $store.notifyFailed) }
            SettingRow("Balance below $5") { RSwitch(label: "Balance below $5", isOn: $store.notifyLowBalance) }
            SettingRow("Also notify my Android phone", hint: "Sent by the server to the MUSE Android app") { RSwitch(label: "Also notify my Android phone", isOn: $store.notifyPhone) }
            RButton("Send a test notification", small: true) {
                Notifier.shared.post(title: "MUSE test", body: "Notifications are working. Renders will tell you when they finish or fail.")
                store.showToast("Test notification sent. If nothing appears, allow MUSE in System Settings › Notifications.")
            }
            .padding(.top, Space.s3)
        case .developer:
            SectionTitle("Data source", top: 0)
            Text("MUSE talks to the MUSE server by default (\(defaultServerURL)). Demo mode runs everything inside the app with sample data and no account. You can also point MUSE at another server, such as a local server/api or server/mock. Each server keeps its own sign-in.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Space.s2)
            RSeg(DataSource.allCases.map { ($0, $0.label) }, selection: $store.dataSource) { _ in store.applyDataSource() }.frame(maxWidth: 460)
            RField("Server base URL", hint: "Remote servers need HTTPS. Plain HTTP works for this Mac and the local network only.") {
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
        case .connections:
            // A normal detail pane in the same column as the other sections (it used to be a sheet over Settings).
            ConnectionsView()
        case .about:
            SectionTitle("About", top: 0)
            SettingRow("Version") { RowValue("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))") }
            SettingRow("Fonts", hint: "Instrument Serif, Archivo, IBM Plex Mono, Barlow, JetBrains Mono, Outfit, DM Mono, Bricolage Grotesque, Figtree (SIL OFL); Permanent Marker (Apache 2.0)")
            SettingRow("Terms of Service") { RButton("Open", kind: .plain, small: true) { store.showToast("The Terms of Service open on the MUSE website") } }
            SettingRow("Acceptable Use Policy") { RButton("Open", kind: .plain, small: true) { store.showToast("The Acceptable Use Policy opens on the MUSE website") } }
            SettingRow("Account", hint: store.user?.email) { RButton("Sign out", kind: .danger, small: true) { store.signOut() } }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value).monospacedDigit().scaled(t.scale.title, t.roles.ink)
        }
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
