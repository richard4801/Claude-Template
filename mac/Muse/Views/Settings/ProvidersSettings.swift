import MuseCore
import SwiftUI

/// Settings → Providers (owner-approved mock 2026-11-09): connected providers with the key's last 4 and Replace key /
/// Remove; Add a provider with a secure key field (checked by the server, never shown again); the provider's models
/// with search, a filter (All / Video / Image / On), an on/off switch, Rename, an Image/Video tag and the price.
struct ProvidersSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var removing: ProviderAccount?
    @State private var renaming: ProviderCatalogModel?
    @State private var newName = ""

    var body: some View {
        let s = store.providersState
        VStack(alignment: .leading, spacing: 0) {
            if !s.keysReady {
                InlineNotice("Provider keys aren't set up on the server yet. Adding a key works once they are.", tone: .caution)
                    .padding(.bottom, Space.s4)
            }
            if let e = s.loadError {
                ErrorState("Providers didn't load", e, actionTitle: "Try again") { Task { await store.loadProviders() } }
            } else if !s.loaded {
                SkeletonRows(count: 3, thumb: false)
            } else if s.adding {
                ProviderKeyForm()
            } else if s.accounts.isEmpty {
                EmptyState("No providers yet", "Add an API key for an AI provider you use. Its image and video models can then be picked per shot, by you and your members (hide any in What members see).",
                           actionTitle: "Add a provider", actionKind: .action) { store.openProviderForm() }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.s5)
                    .disabled(!s.keysReady)
            } else {
                accounts
                models
            }
        }
        .task { await store.loadProviders() }
        .confirmationDialog(removing.map { "Remove \($0.label)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { p in
            Button("Remove \(p.label)", role: .destructive) { store.removeProvider(p) }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("Its key is deleted and its models leave the AI Suite.")
        }
        .alert("Rename model", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let m = renaming { store.renameProviderModel(m, to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The name you see in the AI Suite's model picker.")
        }
    }

    private var accounts: some View {
        let s = store.providersState
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                RButton("Add a provider", small: true, off: !s.keysReady) { store.openProviderForm() }
            }
            ForEach(s.accounts) { p in
                SettingRow(p.label, hint: ProviderText.line(p)) {
                    HStack(spacing: Space.s3) {
                        if s.accounts.count > 1 && s.selected != p.id {
                            RButton("Show models", kind: .plain, small: true) {
                                s.selected = p.id
                                Task { await store.loadProviderModels() }
                            }
                        }
                        RButton("Replace key", kind: .plain, small: true, off: !s.keysReady) { store.openProviderForm(replacing: p.id) }
                        RButton("Remove", kind: .plain, small: true) { removing = p }
                    }
                }
            }
        }
    }

    @ViewBuilder private var models: some View {
        let s = store.providersState
        if let p = s.accounts.first(where: { $0.id == s.selected }) {
            SectionTitle("\(p.label) models") {
                RSeg([("all", "All"), ("video", "Video"), ("image", "Image"), ("on", "On")], selection: Binding(get: { s.filter }, set: { s.filter = $0 })) { _ in
                    Task { await store.loadProviderModels() }
                }
                .frame(width: 300)
            }
            RTextField(placeholder: "Search \(p.label) models", text: Binding(get: { s.search }, set: { s.search = $0 })) {
                Task { await store.loadProviderModels() }
            }
            .frame(maxWidth: 360)
            .padding(.bottom, Space.s2)
            .accessibilityLabel("Search models")
            let shown = s.filter == "on" ? s.catalog.filter { store.customModel(for: $0)?.enabled == true } : s.catalog
            if s.loadingModels && s.catalog.isEmpty {
                SkeletonRows(count: 4, thumb: false)
            } else if shown.isEmpty {
                Text(s.filter == "on" ? "No models switched on yet." : "No models match.").scaled(t.scale.caption, t.roles.ink2).padding(.vertical, Space.s3)
            } else {
                ForEach(shown) { m in row(m) }
            }
        }
    }

    private func row(_ m: ProviderCatalogModel) -> some View {
        let c = store.customModel(for: m)
        let on = c?.enabled == true
        let name = c?.displayName ?? m.name
        return HStack(spacing: Space.s3) {
            RSwitch(label: "Use \(name)", isOn: Binding(get: { on }, set: { store.setProviderModel(m, on: $0) }))
                .disabled(!m.ready && !on)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s2) {
                    Text(name).scaled(t.scale.body, t.roles.ink).lineLimit(1)
                    if let k = m.kind { KindTag(text: k == "image" ? "Image" : "Video") }
                }
                Text(m.ready ? (name == m.name ? m.ref : "\(m.name), \(m.ref)") : "Needs a setting MUSE can't fill in yet: \(m.missing.joined(separator: ", "))")
                    .scaled(t.scale.caption, m.ready ? t.roles.ink2 : t.roles.caution).lineLimit(1)
            }
            Spacer(minLength: Space.s3)
            Text(ProviderText.price(c?.price ?? m.price)).monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
            RButton("Rename", kind: .plain, small: true) {
                newName = name
                renaming = m
            }
            .accessibilityLabel("Rename \(name)")
        }
        .frame(minHeight: 44)
    }
}

/// The add-a-key form (or replace a provider's key). The key field is secure, never filled in and cleared after saving.
struct ProviderKeyForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @FocusState private var focused: Bool

    var body: some View {
        let s = store.providersState
        let kind = s.kinds.first { $0.kind == s.addKind }
        let label = kind?.label ?? s.addKind
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(s.replacing == nil ? "Add a provider" : "Replace the \(label) key").scaled(t.scale.heading, t.roles.ink)
            if s.replacing == nil {
                RField("Provider") {
                    RSeg(s.kinds.map { ($0.kind, $0.label) }, selection: Binding(get: { s.addKind }, set: { s.addKind = $0; s.formError = nil }))
                        .frame(width: max(160, CGFloat(s.kinds.count) * 110))
                }
            }
            RField("API key", hint: "Saved encrypted on the MUSE server, checked with \(label) first. Afterwards you only see its last 4 characters.") {
                SecureField(kind?.keyHint ?? "Paste the key", text: Binding(get: { s.keyText }, set: { s.keyText = $0; s.formError = nil }))
                    .textContentType(.password)
                    .focused($focused)
                    .onSubmit { store.saveProviderKey() }
                    .roleField(focused: focused)
                    .frame(width: 420)
                    .accessibilityLabel("API key")
            }
            if let u = kind?.keyUrl, let url = URL(string: u) {
                Link("Where to find your \(label) key", destination: url).font(t.scale.caption.font).foregroundStyle(t.roles.link)
            }
            if let e = s.formError { InlineNotice(e, tone: .caution) }
            HStack(spacing: Space.s3) {
                RButton(s.saving ? "Checking the key…" : "Save key", kind: .action, off: s.saving || !s.keysReady) { store.saveProviderKey() }
                    .keyboardShortcut(.defaultAction)
                RButton("Cancel", kind: .plain) { store.closeProviderForm() }
            }
        }
        .onAppear { focused = true }
        .onDisappear { s.keyText = "" }
    }
}

/// An information-bearing tag (Image / Video): caption text in a hairline outline at the chip radius.
struct KindTag: View {
    @Environment(\.theme) private var t
    var text: String

    var body: some View {
        Text(text).scaled(t.scale.caption, t.roles.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).strokeBorder(t.roles.hairline, lineWidth: 1))
    }
}

/// AI & spending → Default models (owner): one row per purpose, Auto or a model. Each screen's Model pill starts there.
struct DefaultModelsSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let catalog = store.engineChoice.catalog
        SectionTitle("Default models").id("settings.models")
        Text("What \u{201C}Auto\u{201D} uses for each kind of work. Anyone in the studio can still pick another model each time.")
            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true).padding(.bottom, Space.s2)
        if let catalog {
            ForEach(EnginePurpose.allCases) { p in
                let info = catalog.purpose(p)
                let engines = catalog.engines(for: p)
                if !engines.isEmpty {
                    SettingRow(info?.label ?? p.fallbackLabel) {
                        Menu {
                            Button("Auto: MUSE picks") { store.setEngineDefault(p, model: nil) }
                            Divider()
                            ForEach(engines, id: \.model) { e in
                                Button(e.name) { store.setEngineDefault(p, model: e.model) }
                            }
                        } label: {
                            Text(info?.studioDefault.flatMap { id in engines.first { $0.model == id }?.name } ?? "Auto: MUSE picks")
                                .scaled(t.scale.body, info?.studioDefault == nil ? t.roles.ink2 : t.roles.ink)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Default model for \((info?.label ?? p.fallbackLabel).lowercased())")
                    }
                }
            }
        } else if let e = store.engineChoice.error {
            InlineNotice(e, tone: .caution)
        } else {
            SkeletonRows(count: 4, thumb: false)
        }
    }
}

/// 4c (owner, 2026-11-11): what members see of the studio's models. "Show provider names to members" (on for now, while
/// the studio settles on a provider) and a "Hide from members" switch on every video and image model. Members see every
/// model that isn't hidden and pick it themselves; keys, costs and the switches stay the owner's.
struct MemberModelsSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var view: EngineMembers?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { rows }
            .task { await load() }
    }

    @ViewBuilder private var rows: some View {
        SectionTitle("What members see").id("settings.members.models")
        Text("Members can pick any model below that isn't hidden. Keys, costs and these switches stay yours.")
            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true).padding(.bottom, Space.s2)
        if let v = view {
            SettingRow("Show provider names to members", hint: "Members see \u{201C}Kling 4.0 · Replicate\u{201D} instead of just the model") {
                RSwitch(label: "Show provider names to members", isOn: Binding(get: { v.showProviderNames }, set: { on in save(showProviderNames: on, hidden: [:]) }))
            }
            ForEach(v.models) { m in
                SettingRow(m.shownName, hint: m.kind == "image" ? "Image" : "Video") {
                    RSwitch(label: "Hide \(m.shownName) from members", isOn: Binding(get: { !m.members }, set: { hide in save(showProviderNames: nil, hidden: [m.model: hide]) }))
                }
            }
            Text("The switch hides a model from members. You always see every model.")
                .scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s1)
        } else if let error {
            Text(error).scaled(t.scale.caption, t.roles.ink2)
        } else {
            SkeletonBlock(width: 220, height: 10)
        }
    }

    private func load() async {
        guard let api = store.engineChoiceAPI else { error = "Sign in to your MUSE server first."; return }
        do { view = try await api.engineMembers(); error = nil } catch {
            self.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    private func save(showProviderNames: Bool?, hidden: [String: Bool]) {
        guard let api = store.engineChoiceAPI, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { view = try await api.setEngineMembers(showProviderNames: showProviderNames, hidden: hidden) } catch {
                store.showToast("Couldn't save that. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
            }
        }
    }
}
