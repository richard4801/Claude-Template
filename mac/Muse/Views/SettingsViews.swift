import MuseCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        Page {
            PageHeader(eyebrow: "Preferences", title: "Settings")
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.allCases.filter { !$0.ownerOnly || store.isOwner }, id: \.self) { s in
                        SettingsNavRow(icon: icon(s), title: s.title, on: store.settingsSection == s) { store.settingsSection = s }
                    }
                    if store.isOwner { SuiteConnectionsRow() } // AI suite (workstream 1): Connections (owner) → ConnectionsView
                }
                .frame(width: 220)
                VStack(alignment: .leading, spacing: 16) { section }
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
    }

    private func icon(_ s: SettingsSection) -> String {
        switch s {
        case .appearance: return "paintpalette"
        case .defaults: return "slider.horizontal.3"
        case .costs: return "dollarsign.circle"
        case .studio: return "building.2"
        case .engines: return "server.rack"
        case .prompts: return "text.quote"
        case .archived: return "archivebox"
        case .notif: return "bell"
        case .developer: return "hammer"
        case .about: return "info.circle"
        }
    }

    @ViewBuilder private var section: some View {
        @Bindable var store = store
        switch store.settingsSection {
        case .appearance:
            H2("Theme")
            HStack(spacing: 16) {
                ForEach(ThemeID.allCases) { id in
                    let on = id == store.themeID
                    Button { store.setTheme(id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ThemePreview(theme: Theme.get(id)).aspectRatio(16 / 10, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: t.cardRadius * 0.6))
                                .overlay(RoundedRectangle(cornerRadius: t.cardRadius * 0.6).strokeBorder(.black.opacity(0.12), lineWidth: 1))
                            HStack {
                                Text(id.name).font(t.body(14, .semibold))
                                Spacer()
                                if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                        }
                        .padding(8)
                        .surface()
                        .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(on ? t.accent : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ListBox {
                ListRow(icon: "sparkles", title: "Pro mode", hint: "Show and edit the prompts behind every render", last: true) { MToggle(isOn: $store.pro) }
            }
        case .defaults:
            H2("Render defaults")
            ListBox {
                ListRow(title: "Default render", hint: "Add-ons (Edit, Fast · beta) are picked per video") {
                    Seg(VideoQuality.renders.map { ($0, $0.label) }, selection: $store.defaultQuality) { store.setQuality($0) }.frame(width: 300)
                }
                ListRow(title: "Export size", hint: "Export saves the render as it was made") { MonoValue("9:16 · as rendered") }
                ListRow(title: "Keep test renders for", last: true) { MonoValue("30 days") }
            }
            if store.isOwner {
                H2("House style")
                HStack {
                    Muted("The house style added to every photo prompt is in Settings → Prompts, with every other prompt. Never-add lists are set per model.")
                    Spacer()
                    LinkText("Open Prompts") { store.settingsSection = .prompts }
                }
            }
        case .costs:
            H2("Costs & limits")
            HStack(spacing: 14) {
                KPI(label: "Balance", value: Pricing.money(store.creditUsd), index: 0)
                KPI(label: "This month", value: Pricing.money(store.balance.month), index: 1)
                KPI(label: "Draft video (10 s)", value: "~\(Pricing.money(Pricing.typicalVideo))", index: 2)
            }
            ListBox {
                ListRow(icon: "checkmark.shield", title: "Spend cap per job", hint: store.isOwner ? "Change it in Settings → Studio" : "Set by the studio owner") { MonoValue(Pricing.money(store.balance.perJobLimit)) }
                ListRow(icon: "checkmark.shield", title: store.isMember ? "My cap per day" : "Spend cap per day") { MonoValue(Pricing.money(store.balance.perDayLimit)) }
                ListRow(icon: "bell", title: "Warn before a job goes over budget", last: true) { MToggle(isOn: $store.warnOverBudget) }
            }
            MButton("Credit", icon: "dollarsign.circle", kind: .primary) { store.go(.credits) }
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
            H2("Notifications")
            ListBox {
                ListRow(icon: "bell", title: "Notifications", hint: "Sound and alerts follow your Mac's notification settings") {
                    MButton("Open System Settings", size: .small) { Notifier.openSystemSettings() }
                }
                ListRow(title: "Render finished") { MToggle(isOn: $store.notifyDone) }
                ListRow(title: "Render failed") { MToggle(isOn: $store.notifyFailed) }
                ListRow(title: "Balance below $5") { MToggle(isOn: $store.notifyLowBalance) }
                ListRow(title: "Also notify my Android phone", hint: "Sent by the server to the MUSE Android app", last: true) { MToggle(isOn: $store.notifyPhone) }
            }
            HStack {
                MButton("Send a test notification", icon: "bell", size: .small) {
                    Notifier.shared.post(title: "MUSE test", body: "Notifications are working. Renders will tell you when they finish or fail.")
                    store.showToast("Test notification sent. If nothing appears, allow MUSE in System Settings → Notifications.")
                }
            }
        case .developer:
            H2("Data source")
            Muted("MUSE talks to the MUSE server by default (\(defaultServerURL)). Demo mode runs everything inside the app with sample data and no account. You can also point MUSE at another server, such as a local server/api or server/mock. Each server keeps its own sign-in.")
            Seg(DataSource.allCases.map { ($0, $0.label) }, selection: $store.dataSource) { _ in store.applyDataSource() }.frame(maxWidth: 460)
            Field("Server base URL", trailing: store.baseURL == defaultServerURL ? nil : "Use the MUSE server", trailingAction: {
                store.baseURL = defaultServerURL
                store.applyDataSource()
            }) {
                HStack(spacing: 10) {
                    TextField(defaultServerURL, text: $store.baseURL).fieldChrome().font(t.mono(13))
                        .onSubmit { store.applyDataSource() }
                    MButton("Reconnect", size: .regular) { store.applyDataSource() }
                    MButton("Test", size: .regular) { store.testConnection() }
                }
            }
            .opacity(store.dataSource == .http ? 1 : 0.5)
            Muted("Remote servers need HTTPS. Plain HTTP works for this Mac and the local network only.")
            if let msg = store.offlineMessage { Note(icon: "wifi.exclamationmark", warn: true, msg) }
            H2("Testing")
            ListBox {
                ListRow(title: "Fail the next render", hint: "It stops partway and the cost is refunded, to test failure handling and notifications. Demo mode, server/mock, and dev servers only.") {
                    MButton("Fail next", size: .small) { store.setFailNext() }
                }
                ListRow(title: "Reload everything", hint: "Fetches models, outfits, jobs, takes and balance again.", last: true) {
                    MButton("Reload", size: .small) { Task { await store.forceReload() } }
                }
            }
            H2("Performance")
            PerfReadout()
        case .about:
            H2("About")
            ListBox {
                ListRow(title: "Version") { MonoValue("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))") }
                ListRow(title: "Fonts", hint: "Instrument Serif, Archivo, IBM Plex Mono, Barlow, JetBrains Mono, Outfit, DM Mono, Bricolage Grotesque, Figtree (SIL OFL) · Permanent Marker (Apache 2.0)") { EmptyView() }
                RowButton(title: "Terms of Service") { store.showToast("The Terms of Service open on the MUSE website") }
                RowButton(title: "Acceptable Use Policy") { store.showToast("The Acceptable Use Policy opens on the MUSE website") }
                RowButton(title: "Sign out", last: true) { store.signOut() }
            }
        }
    }
}

/// A Settings section in the list on the left. Like the sidebar's NavRow, but drawn for the page background: the sidebar's
/// Creator Pop colours (white on blue) were white on cream here.
private struct SettingsNavRow: View {
    @Environment(\.theme) private var t
    var icon: String
    var title: String
    var on: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.isA ? 0 : t.isC ? 14 : t.isD ? 12 : t.r, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: on ? .semibold : .regular)).frame(width: 20)
                Text(t.navUppercase ? title.uppercased() : title).font(t.navFont).tracking(t.isA ? 1 : t.isB ? 1.2 : 0).lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(on ? (t.isA || t.isB ? t.accent : t.ink) : hover ? t.ink : t.muted)
            .padding(.horizontal, 10)
            .frame(height: t.isA ? 38 : 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(on ? (t.isA ? Color.clear : t.isD ? t.yellow : t.isB ? t.surface2 : t.surface) : hover && !t.isA ? t.surface2 : Color.clear))
            .overlay(shape.strokeBorder(on && t.isD ? Color(hex: 0x111111) : Color.clear, lineWidth: 2.5))
            .overlay(alignment: .leading) {
                if on && t.isA { Rectangle().fill(t.accent).frame(width: 2).padding(.vertical, 10) }
                if on && t.isB { Rectangle().fill(t.accent).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct RowButton: View {
    var title: String
    var last = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ListRow(title: title, last: last) { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
