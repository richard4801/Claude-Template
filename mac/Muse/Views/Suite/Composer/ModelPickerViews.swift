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
        let tier = store.suite.catalog?.tier(d.quality)
        let all = ComposerModelPicker.options(store.suite.settings, tool: d.tool, tier: tier)
        let shown = ComposerModelPicker.options(store.suite.settings, tool: d.tool, tier: tier, search: search)
        let ladder = Set((tier?.models ?? []).map(\.model))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model").scaled(t.scale.label, t.roles.ink)
                Spacer(minLength: Space.s3)
                Text("Only you see models").scaled(t.scale.caption, t.roles.ink2)
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
                    let sections: [(String, [SuiteRegistryModel])] = [
                        ("On \(SuiteText.tierLabel(d.quality))", shown.filter { ladder.contains($0.id) && !$0.custom }),
                        ("Other models", shown.filter { !ladder.contains($0.id) && !$0.custom }),
                        ("Your providers", shown.filter(\.custom)),
                    ].filter { !$0.1.isEmpty }
                    ForEach(sections, id: \.0) { section in
                        group(section.0)
                        ForEach(section.1, id: \.id) { m in row(m, d) }
                    }
                    if shown.isEmpty {
                        Text(store.suite.settings == nil ? "The model list didn't load. Close this and try again." : "No model matches “\(search)”.")
                            .scaled(t.scale.caption, t.roles.ink2).padding(Space.s4)
                    }
                }
                .padding(.bottom, Space.s2)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 400, alignment: .leading)
        .task { if store.suite.settings == nil { await store.loadSuiteSettings() } }
    }

    private func group(_ title: String) -> some View {
        Text(title).scaled(t.scale.caption, t.roles.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s1)
            .accessibilityAddTraits(.isHeader)
    }

    private func autoRow(_ d: ComposerDraft) -> some View {
        let on = d.engineModel == nil
        return Button {
            store.pinComposerModel(nil)
            onPick()
        } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                check(on)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto").scaled(t.scale.body, t.roles.ink)
                    Text("The \(SuiteText.tierLabel(d.quality)) ladder picks the model for each shot").scaled(t.scale.caption, t.roles.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            .background(on ? t.roles.field : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: Auto")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ m: SuiteRegistryModel, _ d: ComposerDraft) -> some View {
        let on = d.engineModel == m.id
        return HStack(alignment: .top, spacing: Space.s2) {
            check(on)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(m.name).scaled(t.scale.body, t.roles.ink).lineLimit(1)
                Text(ComposerModelPicker.limits(m)).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                HStack(spacing: Space.s1) {
                    ForEach(m.resolutions, id: \.id) { r in
                        let picked = on && (d.resolution ?? m.resolutions.last?.id) == r.id
                        Button {
                            store.pinComposerModel(m, resolution: r.id)
                            onPick()
                        } label: {
                            HStack(spacing: 4) {
                                Text(ComposerModelPicker.resLabel(r.label)).typeStep(t.scale.caption)
                                Text(ComposerModelPicker.price(m, resolution: r.id)).monospacedDigit().typeStep(t.scale.caption)
                                    .foregroundStyle(picked ? t.roles.ink : t.roles.ink2)
                            }
                            .foregroundStyle(t.roles.ink)
                            .padding(.horizontal, Space.s2).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(picked ? t.roles.field : .clear))
                            .overlay(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
                                .strokeBorder(picked ? t.roles.selection : t.roles.hairline, lineWidth: picked ? 2 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Use \(m.name) at \(ComposerModelPicker.resLabel(r.label)), \(ComposerModelPicker.price(m, resolution: r.id))")
                        .accessibilityLabel("Use \(m.name) at \(ComposerModelPicker.resLabel(r.label))")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
        .background(on ? t.roles.field.opacity(0.5) : .clear)
    }

    private func check(_ on: Bool) -> some View {
        Ph("checkmark", 11).foregroundStyle(t.roles.accent).opacity(on ? 1 : 0).frame(width: 16, height: 20)
    }
}
