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
            } else if store.recreate.open {
                RecreateView()
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
            PageHeader(eyebrow: "Edit suite", title: "Edit") {
                // "Recreate this edit" (plans/recreate): opens its start page; nothing is uploaded until a video is chosen.
                SuiteToolButton(title: "Recreate an edit", icon: "arrows-clockwise") { store.openRecreate() }
            }
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
                                    Text(String(format: "%.1fs", d)).font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white)
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

/// The editor (E1, plans/edit-layout.md): a 56 pt top bar; media (304 pt), the viewer and the inspector (328 pt), both side
/// panels collapsible; the 268 pt timeline. Or captions & hooks (E3). Under ~1180 pt the media panel collapses on its own,
/// then the inspector.
struct EditSuiteEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var showExport = false
    @State private var showMedia = true
    /// Starts expanded (WS3's click-through walks it).
    @State private var showInspector = true
    /// Hidden by the window getting narrow (shown again when it widens), not by the person.
    @State private var mediaAutoHidden = false
    @State private var inspectorAutoHidden = false
    /// The Claude panel on the right (owner only).
    @State private var showClaude = false

    static let mediaWidth: CGFloat = 304
    static let inspectorWidth: CGFloat = 328
    static let timelineHeight: CGFloat = 268
    /// Editor widths under which the media panel, then the inspector, collapse (a window of about 1180 and 950 pt with
    /// the 72 pt sidebar rail).
    static let mediaFits: CGFloat = 1108
    static let inspectorFits: CGFloat = 880

    var body: some View {
        Group {
            switch session.phase {
            case .loading(let what):
                VStack(spacing: 12) { ProgressView(); Text(what).font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
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
    }

    private var claudeOpen: Bool { showClaude && session.isOwner }

    private var editor: some View {
        GeometryReader { g in
            let full = g.size.width
            let claudeW: CGFloat = full >= 1300 ? 360 : 320
            // The Claude panel takes its width from the editor.
            let w = claudeOpen ? full - claudeW - 1 : full
            VStack(spacing: 0) {
                topBar(width: w)
                SuiteRule()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if session.mode == .captions {
                            EditSuiteCaptionsMode(session: session)
                        } else {
                            HStack(spacing: 0) {
                                if showMedia {
                                    EditSuiteBin(session: session) { setMedia(false) }
                                        .frame(width: Self.mediaWidth)
                                    SuiteRule(vertical: true)
                                }
                                EditSuitePreview(session: session, mediaHidden: !showMedia, showMedia: { setMedia(true) })
                                    .frame(minWidth: 320, maxWidth: .infinity)
                                if showInspector {
                                    SuiteRule(vertical: true)
                                    EditSuiteInspector(session: session) { setInspector(false) }
                                        .frame(width: Self.inspectorWidth)
                                }
                            }
                            .frame(maxHeight: .infinity)
                            SuiteRule()
                            EditSuiteTimeline(session: session, wide: w >= 1360, narrow: w < 760)
                                .frame(height: Self.timelineHeight)
                        }
                    }
                    if claudeOpen {
                        SuiteRule(vertical: true)
                        EditSuiteClaudePanel(session: session) { showClaude = false }
                            .frame(width: claudeW)
                    }
                }
            }
            .onChange(of: w < Self.mediaFits, initial: true) { _, narrow in
                if narrow, showMedia { showMedia = false; mediaAutoHidden = true }
                else if !narrow, mediaAutoHidden { showMedia = true; mediaAutoHidden = false }
            }
            .onChange(of: w < Self.inspectorFits, initial: true) { _, narrow in
                if narrow, showInspector { showInspector = false; inspectorAutoHidden = true }
                else if !narrow, inspectorAutoHidden { showInspector = true; inspectorAutoHidden = false }
            }
        }
        .background(t.roles.canvas)
        // Review mode (SnapshotRunner.editLayoutShots): the collapsed shots.
        .onChange(of: SnapshotRunner.state.editCollapsed) { _, collapsed in
            setMedia(!collapsed)
            setInspector(!collapsed)
        }
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
                EditSuiteClaudeToast(text: text) { session.claudeToast = nil }.padding(.top, 64)
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

    /// The person's choice (a later resize doesn't undo it).
    private func setMedia(_ on: Bool) { showMedia = on; mediaAutoHidden = false }
    private func setInspector(_ on: Bool) { showInspector = on; inspectorAutoHidden = false }

    // MARK: Top bar

    /// Back, the title over its version line, the aspect ratio in the centre, Claude / Templates / Hook ideas as quiet
    /// buttons and Export as the one primary. Narrow (the Claude panel open, a small window): the quiet ones go icon-only.
    private func topBar(width w: CGFloat) -> some View {
        let tight = w < topBarNeeds
        return HStack(spacing: Space.s3) {
            SuiteIconButton(systemName: "caret-left", label: "Close the editor", action: onClose)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1).fitProbe("title")
                Text(session.saveLine).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1).fitProbe("version line")
            }
            .frame(maxWidth: 360, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: Space.s2)
            if session.mode == .captions {
                EditSeg(options: [(EditSuiteSession.Mode.captions, "Transcript"), (.timeline, "Timeline")], selection: session.mode) { session.mode = $0 }
                    .fixedSize()
                Spacer(minLength: Space.s2)
                SuiteToolButton(title: "Done", accent: true) { session.mode = .timeline }
            } else {
                EditSeg(options: EditSuite.Ratio.allCases.map { ($0, $0.label) }, selection: session.state.export.ratio) { r in
                    Task { await session.setRatio(r) }
                }
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Aspect ratio")
                Spacer(minLength: Space.s2)
                // Labelled when there's room, icon-only (tooltip + label) when not: never cut.
                quietButtons(iconOnly: tight)
                SuiteToolButton(title: "Export", icon: "export", accent: true) { showExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .accessibilityLabel("Export")
            }
        }
        .padding(.horizontal, Space.s4)
        .frame(height: 56)
        .background(t.roles.canvas)
    }

    /// The width the top bar needs with the quiet buttons labelled (text at about 7.4 pt a character in `label`, 9 in
    /// `heading`); under it they go icon-only.
    private var topBarNeeds: CGFloat {
        let titles = ["Templates", "Hook ideas"] + (session.isOwner ? ["Claude"] : []) + (showInspector ? [] : ["Show inspector"])
        let quiet = titles.reduce(CGFloat(0)) { $0 + 51 + CGFloat($1.count) * 7.4 + 4 }
        let title = min(360, max(CGFloat(session.title.count) * 9, CGFloat(session.saveLine.count) * 7.2))
        let ratio = CGFloat(EditSuite.Ratio.allCases.count) * 56 + 4
        return 32 + 32 + 12 + title + 12 + 8 + 12 + ratio + 12 + 8 + 12 + quiet + 12 + 100 + 24
    }

    /// Claude (owner only), Templates, Hook ideas and, while the inspector is hidden, Show inspector.
    private func quietButtons(iconOnly: Bool) -> some View {
        HStack(spacing: Space.s1) {
            if session.isOwner {
                SuiteToolButton(title: "Claude", icon: "chat-circle-text", filled: showClaude, plain: !showClaude, iconOnly: iconOnly) { showClaude.toggle() }
                    .accessibilityLabel(showClaude ? "Hide Claude" : "Show Claude")
                    .help(session.liveConnected ? "This edit is shared live with Claude" : "Claude")
            }
            SuiteToolButton(title: "Templates", icon: "stack", plain: true, iconOnly: iconOnly) { setMedia(true); session.binTab = .templates }
            SuiteToolButton(title: "Hook ideas", icon: "lightbulb", plain: true, iconOnly: iconOnly) { session.mode = .captions }
            if !showInspector {
                SuiteToolButton(title: "Show inspector", icon: "sidebar-simple", plain: true, iconOnly: iconOnly) { setInspector(true) }
            }
        }
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
            Ph(warn ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(warn ? t.roles.caution : t.roles.positive)
            Text(text).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(2)
            SuiteIconButton(systemName: "xmark", label: "Dismiss", size: 28, action: dismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.raised))
        .overlay(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).strokeBorder(t.roles.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !warn { dismiss() }
        }
    }
}
