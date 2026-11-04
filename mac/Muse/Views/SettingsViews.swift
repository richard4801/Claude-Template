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
                    ForEach(SettingsSection.allCases, id: \.self) { s in
                        NavRow(icon: icon(s), title: s.title, on: store.settingsSection == s, compact: false, trailing: .none) { store.settingsSection = s }
                    }
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
                ListRow(icon: "speaker.wave.2", title: "Sound effects", hint: "Each theme has its own sounds") { MToggle(isOn: $store.sound) }
                ListRow(icon: "sparkles", title: "Pro mode", hint: "Show and edit the prompts behind every render", last: true) { MToggle(isOn: $store.pro) }
            }
        case .defaults:
            H2("Render defaults")
            ListBox {
                ListRow(title: "Default steps", hint: "10 looked the same as 15 and 20 in testing") {
                    NumStepper(value: store.defaultSteps, dec: {
                        store.defaultSteps = Pricing.clampSteps(store.defaultSteps - 1)
                        store.steps = store.defaultSteps
                    }, inc: {
                        store.defaultSteps = Pricing.clampSteps(store.defaultSteps + 1)
                        store.steps = store.defaultSteps
                    })
                }
                ListRow(title: "Default engine") {
                    Seg([(Engine.h3, "Standard"), (Engine.viggle, "Fast · beta")], selection: $store.defaultEngine) { store.engine = $0 }.frame(width: 260)
                }
                ListRow(title: "Export size") { MonoValue("1080×1920 · 9:16") }
                ListRow(title: "Keep test renders for", last: true) { MonoValue("30 days") }
            }
            H2("House style")
            TextBox(placeholder: PromptEngine.houseStyle, text: $store.houseStyle, lines: 3)
            HStack {
                Muted("Added to every photo prompt. Never-add lists are set per model.")
                Spacer()
                if store.houseStyle != PromptEngine.houseStyle { LinkText("Reset") { store.houseStyle = PromptEngine.houseStyle } }
            }
        case .costs:
            H2("Costs & limits")
            HStack(spacing: 14) {
                KPI(label: "Balance", value: Pricing.money(store.balance.balance), index: 0)
                KPI(label: "This month", value: Pricing.money(store.balance.month), index: 1)
                KPI(label: "Per video", value: "~\(Pricing.money(Pricing.typicalVideo))", index: 2)
            }
            ListBox {
                ListRow(icon: "checkmark.shield", title: "Spend cap per job") { MonoValue(Pricing.money(store.balance.perJobLimit)) }
                ListRow(icon: "checkmark.shield", title: "Spend cap per day") { MonoValue(Pricing.money(store.balance.perDayLimit)) }
                ListRow(icon: "bell", title: "Warn before a job goes over budget") { MToggle(isOn: $store.warnOverBudget) }
                ListRow(icon: "slider.horizontal.3", title: "Shut down idle GPU after", last: true) { MonoValue("5 min") }
            }
            MButton("Credits & top up", icon: "creditcard", kind: .primary) { store.go(.credits) }
        case .notif:
            H2("Notifications")
            ListBox {
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
            Muted("The app runs against an in-process fake backend by default. Switch to the HTTP mock server (server/mock) to test the real API contract. No GPU or RunPod calls are made either way.")
            Seg(DataSource.allCases.map { ($0, $0.label) }, selection: $store.dataSource) { _ in store.applyDataSource() }.frame(maxWidth: 460)
            Field("Server base URL") {
                HStack(spacing: 10) {
                    TextField("http://localhost:8787", text: $store.baseURL).fieldChrome().font(t.mono(13))
                        .onSubmit { store.applyDataSource() }
                    MButton("Reconnect", size: .regular) { store.applyDataSource() }
                    MButton("Test", size: .regular) { store.testConnection() }
                }
            }
            .opacity(store.dataSource == .http ? 1 : 0.5)
            if let msg = store.offlineMessage { Note(icon: "wifi.exclamationmark", warn: true, msg) }
            H2("Testing")
            ListBox {
                ListRow(title: "Fail the next render", hint: "It stops at step 3 and the cost is refunded, to test failure handling and notifications.") {
                    MButton("Fail next", size: .small) { store.setFailNext() }
                }
                ListRow(title: "Reload everything", hint: "Fetches models, outfits, jobs, takes and balance again.", last: true) {
                    MButton("Reload", size: .small) { Task { await store.reload() } }
                }
            }
        case .about:
            H2("About")
            ListBox {
                ListRow(title: "Version") { MonoValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1") }
                ListRow(title: "Video model") { Text("MiniMax H3").font(t.body(13)) }
                ListRow(title: "Lip sync") { Text("LatentSync").font(t.body(13)) }
                ListRow(title: "Fonts", hint: "Instrument Serif, Archivo, IBM Plex Mono, Barlow, JetBrains Mono, Outfit, DM Mono, Bricolage Grotesque, Figtree (SIL OFL) · Permanent Marker (Apache 2.0)") { EmptyView() }
                RowButton(title: "Terms of Service") { store.showToast("The Terms of Service open on the MUSE website") }
                RowButton(title: "Acceptable Use Policy") { store.showToast("The Acceptable Use Policy opens on the MUSE website") }
                RowButton(title: "Sign out", last: true) { store.signOut() }
            }
        }
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

struct CreditsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var payOpen = false

    var body: some View {
        @Bindable var store = store
        Page {
            PageHeader(eyebrow: "Billing", title: "Credits")
            HStack(spacing: 14) {
                KPI(label: "GPU balance", value: Pricing.money(store.balance.balance), hint: "≈ \(Pricing.videosLeft(store.balance.balance)) videos at 10 steps", index: 0)
                KPI(label: "This month", value: Pricing.money(store.balance.month), index: 1)
                KPI(label: "Per video", value: "~\(Pricing.money(Pricing.typicalVideo))", hint: "5s clip · 10 steps · H100", index: 2)
            }
            SectionHeader("Top up")
            HStack(spacing: 10) {
                Seg([10.0, 25, 50, 100].map { ($0, "$\(Int($0))") }, selection: $store.topUpAmount).frame(width: 420)
                MButton("Add \(Pricing.money(store.topUpAmount).replacingOccurrences(of: ".00", with: ""))", icon: "creditcard", kind: .primary) { payOpen = true }
                    .popover(isPresented: $payOpen, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach([("card", "Card · Visa / Mastercard"), ("usdt", "USDT (TRC-20)"), ("virtual", "Virtual dollar card")], id: \.0) { code, m in
                                Button {
                                    payOpen = false
                                    store.topUp(method: code)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "creditcard")
                                        Text(m).font(t.body(13.5))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 36)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                        .frame(width: 260)
                    }
            }
            Muted("Payments are mocked in this build: no card is charged.").padding(.top, 8)
            SectionHeader("Recent spend")
            VStack(spacing: 0) {
                ForEach(store.jobs.filter { !$0.isQueued }) { j in
                    spendRow(j.title + (j.isFailed ? " (failed)" : ""), j.isFailed ? "Refunded" : j.engineName, j.isFailed ? "+\(Pricing.money(j.refunded))" : "−\(Pricing.money(j.cost))")
                }
                spendRow("Photoshoots", "\(store.takes.filter { !$0.isVideo }.count) stills", "−\(Pricing.money(store.takes.filter { !$0.isVideo }.reduce(0) { $0 + $1.cost }))")
            }
        }
    }

    private func spendRow(_ a: String, _ b: String, _ c: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(a).frame(maxWidth: .infinity, alignment: .leading)
                Text(b).foregroundStyle(t.muted).frame(width: 200, alignment: .leading)
                Text(c).font(t.mono(13)).frame(width: 100, alignment: .trailing)
            }
            .font(t.body(14))
            .padding(12)
            Rectangle().fill(t.isD ? Color(hex: 0x111111) : t.line).frame(height: t.lineWidth)
        }
    }
}
