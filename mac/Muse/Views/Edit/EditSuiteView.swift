import AppKit
import MuseCore
import SwiftUI

/// The Edit suite (designs E1–E4). `takeId` opens that take in the editor; nil shows the Edit home: recent video takes and
/// edited versions to open. Navigation to it belongs to the app's sidebar.
struct EditSuiteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    private let takeId: String?
    @State private var openId: String?
    @State private var session: EditSuiteSession?

    init(takeId: String? = nil) {
        self.takeId = takeId
        _openId = State(initialValue: takeId)
    }

    var body: some View {
        Group {
            if let s = session {
                EditSuiteEditor(session: s, onClose: close)
            } else if openId != nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening the video…").font(t.body(13)).foregroundStyle(t.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EditSuiteHome { openId = $0 }
            }
        }
        .task(id: openId) { await open(openId) }
        .onChange(of: takeId) { _, new in openId = new }
        .onDisappear { session?.close() }
    }

    private func open(_ id: String?) async {
        session?.close()
        session = nil
        guard let id else { return }
        guard let s = store.makeEditSuiteSession(takeId: id) else {
            store.showToast("Only video takes can be edited")
            openId = nil
            return
        }
        session = s
        await s.load()
    }

    private func close() {
        session?.close()
        session = nil
        openId = nil
        // Opened with Edit on a take (Result, Gallery): back there.
        if takeId != nil, store.editor != nil { store.closeEditor() }
    }
}

/// The Edit home: video takes and edited versions, newest first.
struct EditSuiteHome: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var open: (String) -> Void

    var body: some View {
        let takes = store.editSuiteTakes
        let edits = takes.filter(\.isEdit)
        let renders = takes.filter { !$0.isEdit }
        Page {
            PageHeader(eyebrow: "Edit suite", title: "Edit")
            if takes.isEmpty {
                Note("Make a video in the Video suite first; its takes show up here to edit.")
                    .padding(.top, 12)
            }
            if !edits.isEmpty {
                SectionHeader("Edited versions")
                grid(edits)
            }
            if !renders.isEmpty {
                SectionHeader("Video takes")
                grid(renders)
            }
        }
    }

    private func grid(_ list: [Take]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], alignment: .leading, spacing: 16) {
            ForEach(list) { tk in
                Button { open(tk.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MuseImage(ref: tk.thumb, symbol: "film")
                            .aspectRatio(9 / 16, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                            .overlay(alignment: .bottomTrailing) {
                                if let d = tk.durationSec {
                                    Text(String(format: "%.1fs", d)).font(t.mono(10.5)).foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2).background(Color.black.opacity(0.55)).padding(6)
                                }
                            }
                        Text(tk.caption).font(t.body(12.5, .medium)).foregroundStyle(t.ink).lineLimit(1)
                        if tk.isEdit { Pill("Edited") }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(tk.caption)")
            }
        }
        .padding(.top, 6)
    }
}

/// The editor (E1): top bar, media bin, preview, inspector and the multitrack timeline; or captions & hooks (E3).
struct EditSuiteEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var showExport = false
    @State private var showBin = true
    /// The Claude panel on the right (owner only).
    @State private var showClaude = false

    var body: some View {
        Group {
            switch session.phase {
            case .loading(let what):
                VStack(spacing: 12) { ProgressView(); Text(what).font(t.body(13)).foregroundStyle(t.muted) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                VStack(spacing: 14) {
                    Note(warn: true, why)
                    MButton("Back", icon: "chevron.left", action: onClose)
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                editor
            }
        }
        .sheet(isPresented: $showExport, onDismiss: { session.exportAskClosed(started: false) }) {
            EditSuiteExportSheet(session: session) { take in
                store.editSuiteSaved(take)
            }
        }
        // Claude asked for an export: the sheet opens with its preset; the owner confirms.
        .onChange(of: session.exportAsk) { _, ask in if ask != nil { showExport = true } }
        .environment(session)
    }

    private var editor: some View {
        GeometryReader { g in
            let full = g.size.width
            // The Claude panel takes its width from the editor.
            let w = showClaude && session.isOwner ? full - (full >= 1300 ? 360 : 320) : full
            let binW: CGFloat = w >= 1300 ? 300 : w >= 1080 ? 248 : 220
            let inspW: CGFloat = w >= 1300 ? 360 : 300
            let bin = showBin && w >= 900
            let timelineH = max(220, min(330, g.size.height * 0.36))
            VStack(spacing: 0) {
                topBar
                SuiteRule()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if session.mode == .captions {
                            EditSuiteCaptionsMode(session: session)
                        } else {
                            HStack(spacing: 0) {
                                if bin {
                                    EditSuiteBin(session: session).frame(width: binW)
                                    SuiteRule(vertical: true)
                                }
                                EditSuitePreview(session: session, showBin: $showBin, binHidden: !bin)
                                    .frame(minWidth: 320, maxWidth: .infinity)
                                SuiteRule(vertical: true)
                                EditSuiteInspector(session: session).frame(width: inspW)
                            }
                            .frame(maxHeight: .infinity)
                            SuiteRule()
                            EditSuiteTimeline(session: session).frame(height: timelineH)
                        }
                    }
                    if showClaude && session.isOwner {
                        SuiteRule(vertical: true)
                        EditSuiteClaudePanel(session: session) { showClaude = false }
                            .frame(width: full >= 1300 ? 360 : 320)
                    }
                }
            }
        }
        .background(t.bg)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { session.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { session.step(-1); return .handled }
        .onKeyPress(.rightArrow) { session.step(1); return .handled }
        .onKeyPress(.delete) { guard session.mode == .timeline else { return .ignored }; session.edit { $0.deleteSelected() }; return .handled }
        .onKeyPress(.deleteForward) { guard session.mode == .timeline else { return .ignored }; session.edit { $0.deleteSelected() }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "sSjJkKlL")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            switch press.characters.lowercased() {
            case "s": session.edit { $0.split() }
            case "j": session.shuttleStep(-1)
            case "k": session.shuttleStep(0)
            case "l": session.shuttleStep(1)
            default: return .ignored
            }
            return .handled
        }
        .overlay(alignment: .bottom) { messages.padding(.bottom, 16) }
        .overlay(alignment: .top) {
            if let text = session.claudeToast {
                EditSuiteClaudeToast(text: text) { session.claudeToast = nil }.padding(.top, 62)
            }
        }
        .sheet(item: $session.askPending) { p in EditSuiteClaudeAsk(session: session, pending: p) }
        // Edits this Mac never got to the server, and the session moved on: never dropped without asking.
        .alert("This Mac has changes that aren't in the latest edit",
               isPresented: Binding(get: { session.draftAsk != nil }, set: { _ in }),
               actions: {
                   Button("Keep this device's changes") { session.resolveDraft(keep: true) }
                   Button("Use the latest", role: .destructive) { session.resolveDraft(keep: false) }
               },
               message: {
                   Text("Keep puts this Mac's changes on top of the latest version (from Claude or your other devices). Use the latest discards them.")
               })
        .overlay { if session.busy { EditSuiteExportProgress(session: session) } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            SuiteIconButton(systemName: "chevron.left", label: "Close the editor", action: onClose)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(t.body(15, .semibold)).foregroundStyle(t.ink).lineLimit(1)
                Text(session.saveLine).font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)
            if session.isOwner {
                SuiteToolButton(title: "Claude", icon: "sparkle", filled: showClaude) { showClaude.toggle() }
                    .accessibilityLabel(showClaude ? "Hide Claude" : "Show Claude")
                    .help(session.liveConnected ? "This edit is shared live with Claude" : "Claude")
            }
            Spacer(minLength: 8)
            if session.mode == .captions {
                EditSeg(options: [(EditSuiteSession.Mode.captions, "Transcript"), (.timeline, "Timeline")], selection: session.mode) { session.mode = $0 }
                    .frame(width: 200)
                Spacer(minLength: 8)
                Button { session.mode = .timeline } label: {
                    Text("DONE").font(t.mono(12.5, .semibold)).tracking(1.2).foregroundStyle(t.bg)
                        .padding(.horizontal, 16).frame(height: 36).background(Rectangle().fill(t.ink))
                }
                .buttonStyle(.plain)
            } else {
                SuiteIconButton(systemName: "arrow.uturn.backward", label: "Undo", disabled: !session.state.canUndo) { session.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                SuiteIconButton(systemName: "arrow.uturn.forward", label: "Redo", disabled: !session.state.canRedo) { session.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                EditSeg(options: EditSuite.Ratio.allCases.map { ($0, $0.label) }, selection: session.state.export.ratio) { r in
                    Task { await session.setRatio(r) }
                }
                .frame(width: 236)
                Spacer(minLength: 8)
                SuiteToolButton(title: "Templates", icon: "rectangle.stack") { session.binTab = .templates }
                SuiteToolButton(title: "Hook ideas", icon: "sparkles") { session.mode = .captions }
                Button { showExport = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold))
                        Text("EXPORT").font(t.mono(12.5, .semibold)).tracking(1.4)
                    }
                    .foregroundStyle(t.bg)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(Rectangle().fill(t.ink))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("e", modifiers: .command)
                .accessibilityLabel("Export")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(t.chrome)
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        if let e = session.lastError {
            message(e, warn: true) { session.lastError = nil }
        } else if let n = session.notice {
            message(n, warn: false) { session.notice = nil }
        }
    }

    private func message(_ text: String, warn: Bool, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: warn ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(warn ? t.warn : t.good)
            Text(text).font(t.body(13)).foregroundStyle(t.ink).lineLimit(2)
            SuiteIconButton(systemName: "xmark", label: "Dismiss", size: 22, action: dismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.line))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !warn { dismiss() }
        }
    }
}
