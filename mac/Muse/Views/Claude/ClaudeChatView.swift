import MuseCore
import SwiftUI

/// The one Claude chat (plans/claude-editing.md E): used by Camera stage (Direct with Claude) and the Edit suite.
/// It runs on the owner's own Claude Code ("On your Claude plan"): user bubbles, streaming text, tool chips, frames Claude
/// grabbed, Send and Stop, and the setup states (Install / Sign in) when Claude Code isn't ready. Owner only.
///
/// Workstream 3 places it in the Edit suite with: `ClaudeChatView(contextKind: "edit", contextId: <edit session id>, title: "Claude")`.
struct ClaudeChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared
    @ObservedObject private var blender: BlenderRelayService = .shared
    @State private var model = ClaudeChatModel()

    let contextKind: String
    let contextId: String
    let title: String
    /// Camera stage draws its own header (status rows) above the chat.
    var showsHeader = true
    /// A line under the composer (Camera stage: the no-spend footer).
    var footer: String?
    var placeholder: String?
    /// Above the transcript, inside the scroll view (Camera stage: the Guides ready card).
    var accessory: AnyView?
    /// Recreate: the context to fall back to when the server doesn't accept `contextKind` yet.
    var fallback: (kind: String, id: String)?
    /// Chips over the composer, sent as if typed.
    var suggestions: [RecreateClaude.Suggestion] = []
    /// Recreate: what each sent message carries in front, and how a stored message is shown without it.
    var wrapOutgoing: ((String) -> String)?
    var unwrapShown: ((String) -> String)?
    var emptyHint: String?
    /// ⌘Return sends (off where ⌘Return is already Generate's, as in the Suite composer).
    var sendShortcut = true
    /// The Suite: the attachments row over the field, Send held while images upload, and the images a sent message
    /// carried (read from its text) as thumbnails in its bubble. Set with `attachments(…)`.
    var composerTop: AnyView?
    var sendBlocked = false
    var userImages: ((String) -> [String])?
    var takeFiles: ((String) -> [ClaudeAttachmentFile])?
    /// The Suite's own routes for "+", paste and drop (it uploads); nil keeps images on this Mac.
    var suiteAttach: (() -> Void)?
    var suiteImages: ((_ urls: [URL], _ data: [(name: String, data: Data, mime: String)]) -> Void)?
    /// WS18: the Suite's own new/open/delete (its chats are bound to shared drafts), and a finished tool step.
    var sessionHooks: ClaudeChatModel.SessionHooks?
    var onToolDone: ((String) -> Void)?
    /// The Suite: the model, so the bridge can follow the open chat.
    var onModel: ((ClaudeChatModel) -> Void)?

    func sessions(_ hooks: ClaudeChatModel.SessionHooks?, onToolDone: ((String) -> Void)? = nil, onModel: ((ClaudeChatModel) -> Void)? = nil) -> ClaudeChatView {
        var c = self
        c.sessionHooks = hooks
        c.onToolDone = onToolDone
        c.onModel = onModel
        return c
    }

    func attachments(top: AnyView?, sendBlocked: Bool, userImages: ((String) -> [String])?,
                     takeFiles: ((String) -> [ClaudeAttachmentFile])? = nil,
                     attach: (() -> Void)? = nil,
                     images: ((_ urls: [URL], _ data: [(name: String, data: Data, mime: String)]) -> Void)? = nil) -> ClaudeChatView {
        var c = self
        c.composerTop = top
        c.sendBlocked = sendBlocked
        c.userImages = userImages
        c.takeFiles = takeFiles
        c.suiteAttach = attach
        c.suiteImages = images
        return c
    }

    /// One Claude (owner bug, build 520: two headers stacked): inside the one-Claude panel ("chat") the panel's own header
    /// is the only chat switcher, New chat and close, on every page; only the older per-place chats show their own.
    static func ownChatSwitcher(contextKind: String) -> Bool { contextKind != "chat" }

    init(contextKind: String, contextId: String, title: String) {
        self.contextKind = contextKind
        self.contextId = contextId
        self.title = title
    }

    init(contextKind: String, contextId: String, title: String, showsHeader: Bool, footer: String? = nil, placeholder: String? = nil, accessory: AnyView? = nil,
         fallback: (kind: String, id: String)? = nil, suggestions: [RecreateClaude.Suggestion] = [], emptyHint: String? = nil,
         wrapOutgoing: ((String) -> String)? = nil, unwrapShown: ((String) -> String)? = nil, sendShortcut: Bool = true) {
        self.contextKind = contextKind
        self.contextId = contextId
        self.title = title
        self.showsHeader = showsHeader
        self.footer = footer
        self.placeholder = placeholder
        self.accessory = accessory
        self.fallback = fallback
        self.suggestions = suggestions
        self.emptyHint = emptyHint
        self.wrapOutgoing = wrapOutgoing
        self.unwrapShown = unwrapShown
        self.sendShortcut = sendShortcut
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Rectangle().fill(t.roles.hairline).frame(height: 1)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.roles.raised)
        .task(id: "\(contextKind)|\(contextId)|\(fallback?.id ?? "")|\(service.configured)|\(service.baseURL?.absoluteString ?? "")|\(sampleKey)") {
            model.wrapOutgoing = wrapOutgoing
            model.unwrapShown = unwrapShown
            model.takeFiles = takeFiles
            model.sessionHooks = sessionHooks
            model.onToolDone = onToolDone
            onModel?(model)
            await model.attach(service, contextKind: contextKind, contextId: contextId, fallback: fallback)
        }
        .onDisappear { model.detach() }
        // Images dropped anywhere on the chat go with the next message.
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter(ChatImageInput.isImage)
            guard !images.isEmpty else { return false }
            if let suiteImages { suiteImages(images, []) } else { model.addImages(urls: images, data: []) }
            return true
        }
    }

    /// Review mode: the sample thread's settings, so a change shows it again.
    private var sampleKey: String {
        guard SnapshotRunner.probing else { return "" }
        let s = SnapshotRunner.state
        return "\(s.chatSample)|\(s.chatStreaming)|\(s.chatComposerText ?? "")|\(s.chatAttach)"
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
            Spacer()
            if model.busy { Text("Claude is working…").scaled(t.scale.caption, t.roles.ink2) }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
    }

    @ViewBuilder private var content: some View {
        if !store.isOwner && contextKind != "chat" { // one Claude: members chat on their own Claude plan
            centered { EmptyState("Owner only", "Claude chat is for the studio owner. Ask them to run this edit with Claude.") }
        } else if !service.configured {
            centered {
                EmptyState("Not connected", "Sign in to your MUSE server to chat with Claude. Demo mode has no Claude chat.",
                           actionTitle: "Open settings") { store.openSettings(.advanced) }
            }
        } else if !service.checkedOnce || (service.checking && !service.info.installed) {
            centered {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Looking for Claude Code on this Mac…").scaled(t.scale.caption, t.roles.ink2)
                    SkeletonBlock(width: 200, height: 10)
                    SkeletonBlock(width: 140, height: 10)
                }
            }
        } else if !service.info.installed {
            setup(installed: false)
        } else if !service.info.signedIn {
            setup(installed: true)
        } else {
            if model.sessionsAvailable, model.thread != nil, Self.ownChatSwitcher(contextKind: contextKind) {
                ChatSessionsBar(model: model)
                Rectangle().fill(t.roles.hairline).frame(height: 1)
            }
            transcript
            if model.answeringPhone { phoneStrip }
            composer
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading) { c() }.padding(Space.s5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Setup states

    private func setup(installed: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(installed ? "Sign in to Claude" : "Use Claude on your own plan").scaled(t.scale.heading, t.roles.ink)
                Text(installed
                     ? "Claude Code is installed. Sign in with your Claude account so chats here run on your subscription."
                     : "MUSE runs Anthropic's Claude Code on this Mac, signed in to your Claude subscription. Nothing is billed to the studio.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                if !installed {
                    step(1, "Install", "Opens Terminal and runs Anthropic's official installer (claude.ai/install.sh).", primary: true) { service.openInstall() }
                }
                step(installed ? 1 : 2, "Sign in", "Opens Claude's own sign-in page. MUSE never sees your password or keys.", primary: installed, off: !installed) { service.openSignIn() }
                HStack(spacing: Space.s2) {
                    RButton(service.checking ? "Checking…" : "Check again", kind: .plain, small: true, off: service.checking) {
                        Task { await service.recheck() }
                    }
                    if let v = service.info.version { Text("Claude Code \(v)").scaled(t.scale.micro, t.roles.ink2) }
                }
                if let e = service.lastError { InlineNotice(e, tone: .danger) }
            }
            .padding(Space.s4)
        }
        .frame(maxHeight: .infinity)
    }

    private func step(_ n: Int, _ title: String, _ hint: String, primary: Bool, off: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Text("\(n)").monospacedDigit().scaled(t.scale.label, t.roles.ink2).frame(width: 14).padding(.top, 6)
            VStack(alignment: .leading, spacing: Space.s1) {
                RButton(title, kind: primary ? .action : .quiet, small: true, off: off, action: action)
                Text(hint).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Transcript

    private var rows: [ChatRow] {
        let tr = model.transcript
        return ChatRow.build(tr.items, audience: store.isOwner ? .owner : .member, unwrap: unwrapShown) { item in
            guard case .user(let id, let text, _) = item else { return [] }
            let stored = tr.attachmentURLs(id)
            if !stored.isEmpty { return stored.map { ChatImage(ref: ImageRef(url: $0)) } }
            if let urls = userImages?(text), !urls.isEmpty { return urls.map { ChatImage(ref: ImageRef(url: $0)) } }
            let shown = ChatLeakFilter.userText(unwrapShown?(text) ?? text)
            return (model.sentLocal[shown] ?? []).map { ChatImage(data: $0) }
        }
    }

    private var transcript: some View {
        let hint = emptyHint ?? (contextKind == "edit"
            ? "Ask Claude to edit: trim, add captions, change the Look, check a frame. Every change can be undone."
            : "Tell Claude what happens in the shot: who walks where, when they turn, how the camera moves.")
        return ChatTranscriptView(
            rows: rows,
            state: ChatTranscriptState(loading: model.loading, loadError: model.loadError, offline: model.offline,
                                       turnError: model.turnError, busy: model.busy, emptyHint: hint,
                                       blenderFailed: model.blenderFailed, blenderWarming: blender.running && blender.toolsState == .warming),
            accessory: accessory,
            resolve: { service.resolve($0) },
            onRetry: { model.retry() },
            onRetryBlender: { model.retryBlender() },
            onReload: { Task { await model.retryLoad() } })
    }

    // MARK: Phone strip and composer

    private var phoneStrip: some View {
        HStack(spacing: Space.s2) {
            Text("Answering a chat from your phone").scaled(t.scale.caption, t.roles.ink)
            Spacer()
            ProgressView().controlSize(.small)
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
        .background(t.roles.field)
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        let local = suiteAttach == nil
        return ChatComposerBar(
            text: $model.composer,
            placeholder: placeholder ?? "Message Claude…",
            busy: model.busy,
            held: model.thread == nil || sendBlocked,
            suggestions: suggestions,
            top: composerTop,
            localImages: local ? model.localImages : [],
            onRemoveLocal: { model.removeImage($0) },
            attachNote: local ? model.attachNote : nil,
            footer: ["On your Claude plan"] + (footer.map { [$0] } ?? []),
            footerHelp: "Runs in Claude Code on this Mac, billed to the Claude account it is signed in with"
                + ((model.transcript.model ?? service.info.model).map { " (\($0))" } ?? ""),
            commandReturnSends: sendShortcut,
            onSend: { model.send() },
            onStop: { model.stop() },
            onSuggestion: { model.send($0) },
            onAttach: suiteAttach ?? { model.pickImages() },
            onImages: suiteImages ?? { urls, data in model.addImages(urls: urls, data: data) })
    }
}
