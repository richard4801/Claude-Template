import MuseCore
import SwiftUI

/// Settings → Prompts (owner only): every prompt the server sends to a model, grouped, with an editor per entry.
struct PromptsSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        Group {
            if store.editingPrompt != nil {
                PromptEditor()
            } else {
                list
            }
        }
        .task { if store.promptLibrary == nil { await store.loadPrompts() } }
    }

    @ViewBuilder private var list: some View {
        H2("Prompts")
        Muted("Every prompt MUSE sends when it makes a photo, an outfit set, a sheet angle, a LoRA set or a video. A saved edit is used for every new render in your studio, by you and your members. Work already running keeps its prompt.")
        if let err = store.promptLibraryError, store.promptLibrary == nil {
            Note(icon: "exclamationmark.triangle", warn: true, err)
            MButton("Try again", size: .small) { Task { await store.loadPrompts() } }
        } else if let lib = store.promptLibrary {
            ForEach(lib.sections, id: \.group.id) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Lbl(section.group.label)
                    ListBox {
                        ForEach(Array(section.entries.enumerated()), id: \.element.key) { i, e in
                            PromptRow(entry: e, last: i == section.entries.count - 1) { store.openPrompt(e.key) }
                        }
                    }
                }
                .padding(.top, 6)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Muted("Loading prompts…")
            }
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
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(entry.title).font(t.body(14, .semibold)).foregroundStyle(t.ink)
                            if entry.overridden { Pill("Edited", .acc) }
                        }
                        Text(entry.oneLine).font(t.mono(11.5)).foregroundStyle(t.muted).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(hover ? t.surface2.opacity(0.6) : .clear)
                if !last { Rectangle().fill(t.line).frame(height: t.lineWidth).padding(.leading, 16) }
            }
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
            VStack(alignment: .leading, spacing: 14) {
                LinkText("← All prompts") { store.closePrompt() }
                HStack(spacing: 10) {
                    H2(e.title)
                    if e.overridden { Pill("Edited", .acc) }
                }
                if !e.description.isEmpty { Muted(e.description) }
                Field("Text", trailing: e.kindHint) {
                    TextBox(placeholder: e.allowEmpty ? "(empty)" : e.defaultText, text: $store.promptDraft, lines: 7, mono: true)
                }
                if !e.placeholders.isEmpty {
                    Field("Placeholders") {
                        FlowLayout {
                            ForEach(e.placeholders) { p in
                                Chip(p.required ? "\(p.token) *" : p.token) { store.insertPlaceholder(p) }
                                    .help(p.description.isEmpty ? "Insert \(p.token)" : p.description)
                            }
                        }
                        Muted(e.placeholders.contains(where: \.required) ? "Click one to add it. * = this prompt needs it." : "Click one to add it.")
                    }
                }
                if let err = store.promptError {
                    Note(icon: "exclamationmark.triangle", warn: true, err)
                }
                Field("Preview") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let p = store.promptLivePreview {
                            Text(p.text.isEmpty ? "(empty: this line is left out)" : p.text)
                                .font(t.mono(12)).foregroundStyle(t.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if !p.example.isEmpty {
                                Lbl("In a whole prompt")
                                Text(p.example).font(t.mono(11.5)).foregroundStyle(t.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Muted("Building the preview…")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
                }
                HStack(spacing: 10) {
                    MButton(store.promptSaving ? "Saving…" : "Save", kind: .primary, off: !store.promptDirty || store.promptSaving || store.promptError != nil) { store.savePrompt() }
                    if store.promptDirty { MButton("Undo changes") { store.promptDraft = e.current } }
                    Spacer()
                    if e.overridden {
                        MButton("Reset to default", icon: "arrow.uturn.backward") { confirmReset = true }
                    }
                }
                if let by = e.updatedBy, e.overridden {
                    Muted("Last saved by \(by)\(e.updatedAt.map { " · " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "")")
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
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every new render in your studio goes back to MUSE's default text.")
            }
        }
    }
}
