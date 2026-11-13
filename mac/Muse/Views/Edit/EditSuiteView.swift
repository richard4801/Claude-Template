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
                    Text(openId == EditV2.blankSourceId ? "Starting a blank project…" : "Opening the video…").font(t.body(13)).foregroundStyle(t.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.recreate.open {
                RecreateView()
            } else if let page = store.learn.page {
                // The learning editor (plans/learning-editor-ui.md): Playbook and Recipes, owner only.
                switch page {
                case .playbook: LearnPlaybookView()
                case .recipes: LearnRecipesView()
                }
            } else {
                EditSuiteHome { openId = $0 }
            }
        }
        .task(id: openId) { await open(openId) }
        // One Claude: Claude opened an edit session: the editor opens on it (even when its take is already open).
        .task(id: store.suite.editAttach?.id) {
            guard let a = store.suite.editAttach else { return }
            if openId == a.takeId { await open(a.takeId) } else { openId = a.takeId }
        }
        .onChange(of: takeId) { _, new in openId = new }
        .onDisappear { session?.close(); store.linkImport.deliverToEdit = nil }
    }

    private func open(_ id: String?) async {
        let attach = id.flatMap { id in store.suite.editAttach.flatMap { $0.takeId == id ? $0.sessionId : nil } }
        // Run 596 (open_page edit session: "New project" instead of Claude's session): when Edit appears with an attach
        // waiting, both the openId task and the editAttach task call open(). The first used to clear editAttach before
        // its await, so the second found none and opened a fresh project over Claude's. Already on that session: keep it.
        if let s = session, let id, s.take.id == id, s.attachSessionId != nil,
           attach == nil || attach == s.attachSessionId {
            if attach != nil { store.suite.editAttach = nil }
            return
        }
        session?.close()
        session = nil
        store.linkImport.deliverToEdit = nil
        guard let id else { return }
        if attach != nil { store.suite.editAttach = nil }
        guard let s = store.makeEditSuiteSession(takeId: id, attachSessionId: attach) else {
            store.showToast("Only video takes can be edited")
            openId = nil
            return
        }
        session = s
        store.linkImport.deliverToEdit = { [weak s] r in s?.addLinkImport(r) ?? false }
        await s.load()
        // The viewer's Split: the playhead where the take was when Split was pressed.
        if let at = store.suite.editAt {
            store.suite.editAt = nil
            s.seek(at)
        }
    }

    private func close() {
        session?.close()
        session = nil
        store.linkImport.deliverToEdit = nil
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
                // The learning editor (owner only): two quiet text buttons beside it.
                if store.isOwner {
                    SuiteToolButton(title: "Playbook", icon: "book-open-text", plain: true) { store.openLearn(.playbook) }
                    SuiteToolButton(title: "Recipes", icon: "stack", plain: true) { store.openLearn(.recipes) }
                }
                SuiteToolButton(title: "Recreate an edit", icon: "arrows-clockwise") { store.openRecreate() }
                // A fresh project with no source video (owner request 2026-11-11); saved to the Library as a new video.
                SuiteToolButton(title: "New blank project", icon: "plus") { open(EditV2.blankSourceId) }
            }
            if takes.isEmpty {
                Note("Start a blank project, or make a video in the Video suite; its takes show up here to edit.")
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
    /// With the Claude panel open: the editor's least width (the preview and the narrow timeline toolbar) and the panel's.
    static let editorMin: CGFloat = 560
    static let claudeMin: CGFloat = 300

    /// Runs an editor shortcut unless the person is typing (then the key goes to the text box).
    private func shortcut(_ key: EditShortcuts.Key, plain: Bool = true) -> KeyPress.Result {
        guard let action = EditShortcuts.action(for: key, typing: TextInputFocus.isTyping, timeline: session.mode == .timeline,
                                                plainModifiers: plain) else { return .ignored }
        EditShortcutRunner.run(action, session)
        return .handled
    }

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
            // The Claude panel takes its width from the editor, clamped so both fit the window (owner review, run 591: at
            // 1000 × 700 the panel ran off the right edge): the editor keeps at least `editorMin`, the panel at least 300.
            let claudeW: CGFloat = max(Self.claudeMin, min(full >= 1300 ? 360 : 320, full - 1 - Self.editorMin))
            let w = claudeOpen ? max(0, full - claudeW - 1) : full
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
                    // The editor gets exactly its share, so the panel beside it always ends at the window's edge.
                    .frame(width: w)
                    .clipped()
                    if claudeOpen {
                        SuiteRule(vertical: true)
                        EditSuiteClaudePanel(session: session, openPlaybook: {
                            // Leaves the editor for the Playbook.
                            onClose()
                            store.openLearn(.playbook)
                        }) { showClaude = false }
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
        .onAppear {
            focused = true
            // Review mode (SnapshotRunner.learnShots): the Claude panel up on its Playbook tab.
            if SnapshotRunner.state.claudeTab != nil { showClaude = true }
            reportClaudePage()
        }
        // One Claude: Claude sees this edit (its take and live session).
        .onChange(of: session.liveConnected) { _, _ in reportClaudePage() }
        .onDisappear { store.oneClaude.viewPage = nil }
        // Shortcuts are off while a text box has the cursor (owner bug 2026-11-11: typing in Claude chat played,
        // split or deleted clips). The table lives in MuseCore (EditShortcuts) with its tests.
        .onKeyPress(.space) { shortcut(.space) }
        .onKeyPress(.leftArrow) { shortcut(.left) }
        .onKeyPress(.rightArrow) { shortcut(.right) }
        .onKeyPress(.delete) { shortcut(.delete) }
        .onKeyPress(.deleteForward) { shortcut(.deleteForward) }
        .onKeyPress(characters: CharacterSet(charactersIn: "sSjJkKlL")) { press in
            shortcut(.character(press.characters), plain: press.modifiers.isDisjoint(with: [.command, .control, .option]))
        }
        .overlay(alignment: .bottom) { messages.padding(.bottom, 16) }
        .overlay(alignment: .top) {
            if let text = session.claudeToast {
                EditSuiteClaudeToast(text: text) { session.claudeToast = nil }.padding(.top, 64)
            }
        }
        .sheet(item: $session.askPending) { p in EditSuiteClaudeAsk(session: session, pending: p) }
        // A paid AI helper asks first, with its price (2026-11-08: real AI editing). Free ones run at once.
        .alert(session.paidAsk.map { "\($0.title) · \($0.price)" } ?? "",
               isPresented: Binding(get: { session.paidAsk != nil }, set: { if !$0 { session.cancelPaid() } }),
               actions: {
                   Button("Run · \(session.paidAsk?.price ?? "")") { session.confirmPaid() }
                   Button("Cancel", role: .cancel) { session.cancelPaid() }
               },
               message: { Text("Paid from the studio balance. The change lands in the edit when it's done, and you can undo it.") })
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

    private func reportClaudePage() {
        var ids = ["takeId": session.take.id]
        if let s = session.live?.sessionId { ids["sessionId"] = s }
        store.oneClaude.viewPage = ClaudePage(name: "edit", label: session.title, ids: ids)
        store.oneClaudePageChanged()
    }

    /// Claude (owner only), Templates, Hook ideas and, while the inspector is hidden, Show inspector.
    private func quietButtons(iconOnly: Bool) -> some View {
        HStack(spacing: Space.s1) {
            if session.isOwner {
                // One Claude (plans/one-claude.md): the panel on the right of every page.
                let on = store.oneClaude.open
                SuiteToolButton(title: "Claude", icon: "chat-circle-text", filled: on, plain: !on, iconOnly: iconOnly) { store.toggleOneClaude() }
                    .accessibilityLabel(on ? "Hide Claude" : "Show Claude")
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
            message(e, warn: true, recover: session.recoverOffer != nil ? { Task { await session.recover() } } : nil) { session.lastError = nil }
        } else if let n = session.notice {
            message(n, warn: false, file: session.noticeFile) { session.notice = nil }
        }
    }

    private func message(_ text: String, warn: Bool, file: URL? = nil, recover: (() -> Void)? = nil, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Ph(warn ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(warn ? t.roles.caution : t.roles.positive)
            Text(text).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(2)
            // Already made and charged at the provider: Recover is free (owner only); running the helper again would pay again.
            if let recover { MButton(ScreenCopy.recoverLabel, size: .small, action: recover) }
            if let file {
                MButton("Show in Finder", size: .small) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            SuiteIconButton(systemName: "xmark", label: "Dismiss", size: 28, action: dismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.raised))
        .overlay(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).strokeBorder(t.roles.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .task(id: text) {
            // A saved file's notice stays longer so there is time to press Show in Finder.
            try? await Task.sleep(nanoseconds: file == nil ? 5_000_000_000 : 15_000_000_000)
            if !warn { dismiss() }
        }
    }
}
