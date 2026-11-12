import MuseCore
import SwiftUI

/// The owner's model picker (owner request 2026-11-08), the Model pill's list: Auto (the quality's ladder) and every
/// registry model this tool can run, the ladder's first. Each row shows what the model does in plain words (its lengths
/// and shapes) and its price per second at each resolution; picking a resolution pins that model there, and the
/// composer's Length and Shape follow its limits (ComposerModelPicker). Owner only: members never see this.
struct ModelPickerList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onPick: () -> Void
    @State private var search = ""

    var body: some View {
        let d = store.suite.composer
        let photo = d.tool == .photo
        let all = store.composerModelOptions()
        let shown = store.composerModelOptions(search: search)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model").scaled(t.scale.label, t.roles.ink)
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
                    autoRow(d)
                    let sections: [(String, [SuiteModelOption])] = (photo ? [
                        ("Photo models", shown.filter { !$0.custom }),
                        ("Your providers", shown.filter(\.custom)),
                    ] : [
                        ("On \(SuiteText.tierLabel(d.quality))", shown.filter { $0.tiers.contains(d.quality) && !$0.custom }),
                        ("Other models", shown.filter { !$0.tiers.contains(d.quality) && !$0.custom }),
                        ("Your providers", shown.filter(\.custom)),
                    ]).filter { !$0.1.isEmpty }
                    ForEach(sections, id: \.0) { section in
                        group(section.0)
                        ForEach(section.1, id: \.id) { m in row(m, d) }
                    }
                    if shown.isEmpty {
                        Text(all.isEmpty ? "The model list didn't load. Close this and try again." : "No model matches “\(search)”.")
                            .scaled(t.scale.caption, t.roles.ink2).padding(Space.s4)
                    }
                }
                .padding(.bottom, Space.s2)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 400, alignment: .leading)
        .task { if store.suite.catalog?.engines == nil && store.suite.settings == nil { await store.loadSuiteSettings() } }
    }

    private func group(_ title: String) -> some View {
        Text(title).scaled(t.scale.caption, t.roles.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s1)
            .accessibilityAddTraits(.isHeader)
    }

    private func autoRow(_ d: ComposerDraft) -> some View {
        let on = store.composerPinnedModel == nil
        return Button {
            store.pinComposerModel(nil)
            onPick()
        } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                check(on)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto").scaled(t.scale.body, t.roles.ink)
                    Text(d.tool == .photo ? "The studio's photo model" : "MUSE picks the model for this quality").scaled(t.scale.caption, t.roles.ink2)
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

    private func row(_ m: SuiteModelOption, _ d: ComposerDraft) -> some View {
        let on = store.composerPinnedModel == m.model
        let limits = ComposerModelPicker.limits(m)
        return HStack(alignment: .top, spacing: Space.s2) {
            check(on)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(m.shownName).scaled(t.scale.body, t.roles.ink).lineLimit(1)
                if !limits.isEmpty { Text(limits).scaled(t.scale.caption, t.roles.ink2).lineLimit(1) }
                // Every model on every mode (owner 2026-11-12): one the tool adapts says what MUSE does with it.
                if let n = ComposerModelPicker.adaptedNote(m, tool: d.tool) { Text(n).scaled(t.scale.caption, t.roles.ink2).lineLimit(2) }
                if m.resolutions.isEmpty {
                    // A photo model, or a per-run model: one choice, one price.
                    chip(ComposerModelPicker.price(m).isEmpty ? "Use" : ComposerModelPicker.price(m), picked: on,
                         help: "Use \(m.shownName)", label: "Use \(m.shownName)") { store.pinComposerModel(m) }
                } else {
                    // Wraps: Seedance 2.0 has four resolutions, more than one line holds with their prices whole.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: Space.s1, alignment: .leading)], alignment: .leading, spacing: Space.s1) {
                        ForEach(m.resolutions, id: \.id) { r in
                            let res = ComposerModelPicker.resLabel(r.label)
                            let price = ComposerModelPicker.price(m, resolution: r.id)
                            chip("\(res)  \(price)", picked: on && (d.resolution ?? m.resolution) == r.id,
                                 help: "Use \(m.shownName) at \(res), \(price)", label: "Use \(m.shownName) at \(res)") { store.pinComposerModel(m, resolution: r.id) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
        .background(on ? t.roles.field.opacity(0.5) : .clear)
    }

    private func chip(_ text: String, picked: Bool, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onPick()
        } label: {
            Text(text).monospacedDigit().typeStep(t.scale.caption).lineLimit(1).fixedSize()
                .foregroundStyle(t.roles.ink)
                .padding(.horizontal, Space.s2).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(picked ? t.roles.field : .clear))
                .overlay(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
                    .strokeBorder(picked ? t.roles.selection : t.roles.hairline, lineWidth: picked ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private func check(_ on: Bool) -> some View {
        Ph("checkmark", 11).foregroundStyle(t.roles.accent).opacity(on ? 1 : 0).frame(width: 16, height: 20)
    }
}
