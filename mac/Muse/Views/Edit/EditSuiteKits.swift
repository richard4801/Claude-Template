import MuseCore
import SwiftUI

/// Style kits (parity, as Android's Edit → Style kits): save this edit's look, colour, transition, caption and text styles
/// and background by name, and apply a saved one to this edit (one undo step). Members see their own kits, the owner the
/// studio's.
struct StyleKitsPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var name = ""
    @State private var saving = false
    @State private var deleting: EditKit?

    var body: some View {
        EditPanel(title: "Style kits") {
            HStack(spacing: Space.s2) {
                TextField("\(session.title) style", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("Style kit name")
                SuiteToolButton(title: "Save style", disabled: saving) { save() }
                    .help("Save this edit's look, colour, transition, captions and text style")
            }
            if let kits = session.kits {
                if kits.isEmpty {
                    Text("No style kits yet. Save this edit's style to use it on another edit.")
                        .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(kits) { k in row(k) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { if session.kits == nil { await session.loadKits() } }
        .confirmationDialog(deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete kit", role: .destructive) {
                if let k = deleting { Task { await session.deleteKit(k) } }
                deleting = nil
            }
            Button("Keep", role: .cancel) { deleting = nil }
        } message: {
            Text("Edits that used it keep their style.")
        }
    }

    private func row(_ k: EditKit) -> some View {
        HStack(spacing: Space.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(k.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Text(k.kit.partsLabel).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
            }
            Spacer(minLength: Space.s2)
            SuiteToolButton(title: "Apply", plain: true) { session.applyKit(k) }
                .help("Use this style on this edit")
                .accessibilityLabel("Apply \(k.name)")
            SuiteToolButton(title: "Delete style kit", icon: "trash", plain: true, iconOnly: true) { deleting = k }
        }
        .padding(.vertical, 2)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = String((n.isEmpty ? "\(session.title) style" : n).prefix(60))
        saving = true
        Task {
            if await session.saveKit(name: finalName) { name = "" }
            saving = false
        }
    }
}
