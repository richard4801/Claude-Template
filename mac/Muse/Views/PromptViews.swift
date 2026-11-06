import MuseCore
import SwiftUI

/// Settings → Prompts (owner only): every prompt the server sends to a model, grouped, with an editor per entry.
struct PromptsSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        Group {
            if store.editingPrompt != nil {
                PromptEditor()
            } else if store.promptsTab == .scripts && store.currentScript != nil {
                // Prompt scripts (workstream 4)
                ScriptScreen()
            } else {
                SectionTitle("Prompts", top: 0)
                RSeg([(PromptsTab.blocks, "Blocks"), (PromptsTab.scripts, "Scripts")], selection: $store.promptsTab).frame(width: 240)
                if store.promptsTab == .scripts { ScriptsList() } else { list }
            }
        }
        .task { if store.promptLibrary == nil { await store.loadPrompts() } }
    }

    @ViewBuilder private var list: some View {
        Text("Every prompt MUSE sends when it makes a photo, an outfit set, a sheet angle, a LoRA set or a video. A saved edit is used for every new render in your studio, by you and your members. Work already running keeps its prompt.")
            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            .padding(.top, Space.s2)
        if let err = store.promptLibraryError, store.promptLibrary == nil {
            ErrorState("Couldn't load the prompts", err, actionTitle: "Try again") { Task { await store.loadPrompts() } }
        } else if let lib = store.promptLibrary {
            ForEach(lib.sections, id: \.group.id) { section in
                SectionTitle(section.group.label, top: Space.s5)
                ForEach(Array(section.entries.enumerated()), id: \.element.key) { i, e in
                    PromptRow(entry: e, last: i == section.entries.count - 1) { store.openPrompt(e.key) }
                }
            }
        } else {
            SkeletonRows(count: 5, thumb: false).padding(.top, Space.s4)
        }
    }
}

struct PromptRow: View {
    @Environment(\.theme) private var t
    var entry: PromptEntry
    var last: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s2) {
                        Text(entry.title).scaled(t.scale.label, t.roles.ink)
                        if entry.overridden { StateTag("Edited") }
                    }
                    Text(entry.oneLine).scaled(t.scale.caption, t.roles.ink2).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: Space.s2)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(t.roles.ink2)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.roles.field.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PromptEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        if let e = store.editingPrompt {
            VStack(alignment: .leading, spacing: Space.s4) {
                RButton("All prompts", kind: .plain, small: true) { store.closePrompt() }
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text(e.title).scaled(t.scale.title, t.roles.ink).accessibilityAddTraits(.isHeader)
                        if e.overridden { StateTag("Edited") }
                    }
                    if !e.description.isEmpty { Text(e.description).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true) }
                }
                RField("Text", hint: e.kindHint) {
                    RTextBox(placeholder: e.allowEmpty ? "(empty)" : e.defaultText, text: $store.promptDraft, lines: 7)
                }
                if !e.placeholders.isEmpty {
                    RField("Placeholders", hint: e.placeholders.contains(where: \.required) ? "Click one to add it. * means this prompt needs it." : "Click one to add it.") {
                        FlowLayout(spacing: Space.s2) {
                            ForEach(e.placeholders) { p in
                                ChoiceChip(p.required ? "\(p.token) *" : p.token) { store.insertPlaceholder(p) }
                                    .help(p.description.isEmpty ? "Insert \(p.token)" : p.description)
                            }
                        }
                    }
                }
                if let err = store.promptError {
                    InlineNotice(err, tone: .danger)
                }
                RField("Preview") {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        if let p = store.promptLivePreview {
                            Text(p.text.isEmpty ? "(empty: this line is left out)" : p.text)
                                .scaled(t.scale.body, t.roles.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if !p.example.isEmpty {
                                Text("In a whole prompt").scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s2)
                                Text(p.example).scaled(t.scale.caption, t.roles.ink2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            SkeletonBlock(width: 320, height: 10)
                            SkeletonBlock(width: 240, height: 10)
                        }
                    }
                    .padding(Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                }
                HStack(spacing: Space.s2) {
                    RButton(store.promptSaving ? "Saving…" : "Save prompt", kind: .action, off: !store.promptDirty || store.promptSaving || store.promptError != nil) { store.savePrompt() }
                    if store.promptDirty { RButton("Undo changes", kind: .plain) { store.promptDraft = e.current } }
                    Spacer()
                    if e.overridden {
                        RButton("Reset to default") { confirmReset = true }
                    }
                }
                if let by = e.updatedBy, e.overridden {
                    Text("Last saved by \(by)\(e.updatedAt.map { ", " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "")")
                        .scaled(t.scale.caption, t.roles.ink2)
                }
            }
            // Live preview, debounced: POST /v1/prompts/preview with the draft (it also reports prompt_invalid while typing).
            .task(id: "\(e.key)|\(store.promptDraft)") {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.refreshPromptPreview()
            }
            .confirmationDialog("Reset “\(e.title)” to its default?", isPresented: $confirmReset) {
                Button("Reset to default", role: .destructive) { store.resetPrompt() }
                Button("Keep my edit", role: .cancel) {}
            } message: {
                Text("Every new render in your studio goes back to MUSE's default text.")
            }
        }
    }
}
