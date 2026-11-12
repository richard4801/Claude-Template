import MuseCore
import SwiftUI

/// The owner's Model pill for any purpose (owner requirement 2026-11-08: "anywhere I generate images or video, let me
/// pick the model"). "Model" with the pick under it ("Auto (Kling 4.0)" / "Kling 4.0, 1080p"); its list shows each
/// model's limits and price, Auto first. 4c: everyone sees it (members the models the owner hasn't hidden).
///
/// `selection` is the model id (nil = Auto, the studio's default for the purpose). Without a binding it uses this
/// session's pick for the purpose (store.enginePick), which the requests read (AppStore+EngineChoice.swift).
struct OwnerModelPill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var purpose: EnginePurpose
    var selection: Binding<String?>?
    var resolution: Binding<String?>?
    /// The icon-only form for tight bars (the pick is the tooltip).
    var compact = false
    @State private var open = false

    init(purpose: EnginePurpose, selection: Binding<String?>? = nil, resolution: Binding<String?>? = nil, compact: Bool = false) {
        self.purpose = purpose
        self.selection = selection
        self.resolution = resolution
        self.compact = compact
    }

    var body: some View {
        // 4c (owner, 2026-11-11): model choice is for everyone; members see the models the owner hasn't hidden.
        if store.user != nil {
            let label = pickLabel
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Ph("cpu", 13)
                    if !compact {
                        Text(selectedModel == nil ? "Model" : label).font(t.body(12.5, .medium)).lineLimit(1).fixedSize()
                    }
                }
                .foregroundStyle(t.roles.ink)
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(open ? t.roles.field : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Model for \(purposeLabel.lowercased()): \(label)")
            .accessibilityLabel("Model for \(purposeLabel.lowercased()): \(label)")
            .popover(isPresented: $open, arrowEdge: .top) {
                EngineList(purpose: purpose, selected: selectedModel, selectedResolution: selectedResolution) { model, res in
                    pick(model, res)
                    open = false
                }
                .environment(store).environment(\.theme, t)
            }
            .task { await store.loadEngines() }
        }
    }

    private var selectedModel: String? { selection?.wrappedValue ?? (selection == nil ? store.enginePick(purpose)?.model : nil) }
    private var selectedResolution: String? { resolution?.wrappedValue ?? (selection == nil ? store.enginePick(purpose)?.resolution : nil) }
    private var purposeLabel: String { store.engineChoice.catalog?.purpose(purpose)?.label ?? purpose.fallbackLabel }

    private var pickLabel: String {
        store.engineChoice.catalog?.label(purpose, model: selectedModel, resolution: selectedResolution)
            ?? (selectedModel ?? "Auto")
    }

    private func pick(_ model: String?, _ res: String?) {
        if let selection {
            selection.wrappedValue = model
            resolution?.wrappedValue = res
        } else {
            store.setEnginePick(purpose, model.map { EnginePick(model: $0, resolution: res) })
        }
    }
}

/// The list in the pill's popover: Auto (what it resolves to), then the purpose's models (MUSE's first, then the
/// owner's providers), each with its limits in plain words and its price; video models pick a resolution.
struct EngineList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var purpose: EnginePurpose
    var selected: String?
    var selectedResolution: String?
    var onPick: (String?, String?) -> Void
    @State private var search = ""

    var body: some View {
        let catalog = store.engineChoice.catalog
        let all = catalog?.engines(for: purpose) ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? all : all.filter { "\($0.shownName) \($0.model)".lowercased().contains(q) }
        let label = catalog?.purpose(purpose)?.label ?? purpose.fallbackLabel
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model for \(label.lowercased())").scaled(t.scale.label, t.roles.ink)
                Spacer(minLength: Space.s3)
                Text(store.isOwner ? "Members see these too, unless you hide them in Settings" : "Models the studio offers").scaled(t.scale.caption, t.roles.ink2)
            }
            .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s2)
            if all.count > 6 {
                RTextField(placeholder: "Search \(all.count) models", text: $search)
                    .padding(.horizontal, Space.s4).padding(.bottom, Space.s2)
                    .accessibilityLabel("Search models")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    autoRow(catalog, label: label)
                    let sections: [(String, [EngineEntry])] = [("Models", shown.filter { !$0.custom }), ("Your providers", shown.filter(\.custom))]
                        .filter { !$0.1.isEmpty }
                    ForEach(sections, id: \.0) { section in
                        if sections.count > 1 { group(section.0) }
                        ForEach(section.1, id: \.model) { e in row(e) }
                    }
                    if shown.isEmpty {
                        Text(store.engineChoice.error ?? (all.isEmpty ? (store.engineChoice.loading ? "Loading models…" : "No models for this yet.") : "No model matches “\(search)”."))
                            .scaled(t.scale.caption, t.roles.ink2).padding(Space.s4)
                    }
                }
                .padding(.bottom, Space.s2)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 400, alignment: .leading)
    }

    private func group(_ title: String) -> some View {
        Text(title).scaled(t.scale.caption, t.roles.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s1)
            .accessibilityAddTraits(.isHeader)
    }

    private func autoRow(_ catalog: EngineCatalog?, label: String) -> some View {
        let on = selected == nil
        let info = catalog?.purpose(purpose)
        let defName = info?.default.flatMap { id in catalog?.engines.first { $0.model == id }?.shownName }
        let line = info?.studioDefault != nil && defName != nil ? "The studio's default: \(defName!)" : "MUSE picks the model for \(label.lowercased())"
        return Button { onPick(nil, nil) } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                check(on)
                VStack(alignment: .leading, spacing: 2) {
                    Text(defName.map { "Auto (\($0))" } ?? "Auto").scaled(t.scale.body, t.roles.ink)
                    Text(line).scaled(t.scale.caption, t.roles.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            .background(on ? t.roles.field : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use Auto")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ e: EngineEntry) -> some View {
        let o = e.option
        let on = selected == e.model
        let limits = ComposerModelPicker.limits(o)
        return HStack(alignment: .top, spacing: Space.s2) {
            check(on)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(e.shownName).scaled(t.scale.body, t.roles.ink).lineLimit(1)
                if let n = e.notice, !n.isEmpty { Text(n).scaled(t.scale.caption, t.roles.caution).lineLimit(2) }
                if !limits.isEmpty { Text(limits).scaled(t.scale.caption, t.roles.ink2).lineLimit(1) }
                // Every model on every mode (owner 2026-11-12): one not made for this purpose says what MUSE does with it.
                if let n = e.adaptedNote(purpose) { Text(n).scaled(t.scale.caption, t.roles.ink2).lineLimit(2) }
                if e.livePrice { Text("Priced by the provider when you pick it").scaled(t.scale.caption, t.roles.ink2).lineLimit(1) }
                if o.resolutions.count < 2 {
                    let price = ComposerModelPicker.price(o, resolution: o.resolution)
                    chip(price.isEmpty ? "Use" : price, picked: on, label: "Use \(e.shownName)") { onPick(e.model, o.resolution) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: Space.s1, alignment: .leading)], alignment: .leading, spacing: Space.s1) {
                        ForEach(o.resolutions, id: \.id) { r in
                            let res = ComposerModelPicker.resLabel(r.label)
                            let price = r.perSec > 0 ? ComposerModelPicker.price(o, resolution: r.id) : ""
                            chip(price.isEmpty ? res : "\(res)  \(price)", picked: on && (selectedResolution ?? o.resolution) == r.id,
                                 label: "Use \(e.shownName) at \(res)") { onPick(e.model, r.id) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
        .background(on ? t.roles.field.opacity(0.5) : .clear)
    }

    private func chip(_ text: String, picked: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).monospacedDigit().typeStep(t.scale.caption).lineLimit(1).fixedSize()
                .foregroundStyle(t.roles.ink)
                .padding(.horizontal, Space.s2).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(picked ? t.roles.field : .clear))
                .overlay(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
                    .strokeBorder(picked ? t.roles.selection : t.roles.hairline, lineWidth: picked ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func check(_ on: Bool) -> some View {
        Ph("checkmark", 11).foregroundStyle(t.roles.accent).opacity(on ? 1 : 0).frame(width: 16, height: 20)
    }
}
