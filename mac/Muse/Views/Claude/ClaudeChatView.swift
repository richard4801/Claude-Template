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

    init(contextKind: String, contextId: String, title: String) {
        self.contextKind = contextKind
        self.contextId = contextId
        self.title = title
    }

    init(contextKind: String, contextId: String, title: String, showsHeader: Bool, footer: String? = nil, placeholder: String? = nil, accessory: AnyView? = nil,
         fallback: (kind: String, id: String)? = nil, suggestions: [RecreateClaude.Suggestion] = [], emptyHint: String? = nil,
         wrapOutgoing: ((String) -> String)? = nil, unwrapShown: ((String) -> String)? = nil) {
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
        .task(id: "\(contextKind)|\(contextId)|\(fallback?.id ?? "")|\(service.configured)|\(service.baseURL?.absoluteString ?? "")") {
            model.wrapOutgoing = wrapOutgoing
            await model.attach(service, contextKind: contextKind, contextId: contextId, fallback: fallback)
        }
        .onDisappear { model.detach() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
            Spacer()
            if model.busy { Text("Working…").scaled(t.scale.caption, t.roles.ink2) }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
    }

    @ViewBuilder private var content: some View {
        if !store.isOwner {
            centered { EmptyState("Owner only", "Claude chat is for the studio owner. Ask them to run this edit with Claude.") }
        } else if !service.configured {
            centered {
                EmptyState("Not connected", "Sign in to your MUSE server to chat with Claude. Demo mode has no Claude chat.",
                           actionTitle: "Open settings") { store.openSettings(.developer) }
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

    private var transcript: some View {
        let items = model.transcript.items
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    if let accessory { accessory }
                    if model.loading, items.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s2) {
                            SkeletonBlock(width: 220, height: 10)
                            SkeletonBlock(width: 260, height: 10)
                            SkeletonBlock(width: 160, height: 10)
                        }
                    }
                    if let e = model.loadError { InlineNotice("Couldn't load this chat. \(e)", tone: .danger) }
                    if items.isEmpty, !model.loading, model.loadError == nil {
                        Text(emptyHint ?? (contextKind == "edit"
                             ? "Ask Claude to edit: trim, add captions, change the Look, check a frame. Every change can be undone."
                             : "Tell Claude what happens in the shot: who walks where, when they turn, how the camera moves."))
                            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(chunks(items)) { chunk in
                        switch chunk {
                        case .single(let item): row(item)
                        case .chips(_, let tools): chipRow(tools)
                        }
                    }
                    if let e = model.transcript.lastError, !model.busy { InlineNotice(e, tone: .danger) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
            }
            .onChange(of: scrollKey(items)) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollKey(_ items: [ClaudeChatItem]) -> String {
        var len = 0
        if case .assistant(_, let text, _)? = items.last { len = text.count }
        return "\(items.count)|\(len)"
    }

    /// Consecutive tool chips share one flowing row.
    private enum Chunk: Identifiable {
        case single(ClaudeChatItem)
        case chips(String, [ClaudeChatItem])
        var id: String {
            switch self {
            case .single(let i): return i.id
            case .chips(let id, _): return "chips_" + id
            }
        }
    }

    private func chunks(_ items: [ClaudeChatItem]) -> [Chunk] {
        var out: [Chunk] = []
        for i in items {
            if case .tool = i {
                if case .chips(let id, let list)? = out.last {
                    out[out.count - 1] = .chips(id, list + [i])
                } else {
                    out.append(.chips(i.id, [i]))
                }
            } else {
                out.append(.single(i))
            }
        }
        return out
    }

    @ViewBuilder private func row(_ item: ClaudeChatItem) -> some View {
        switch item {
        case .user(_, let text, let source): userBubble(unwrapShown?(text) ?? text, source: source)
        case .assistant(_, let text, let streaming): assistant(text, streaming: streaming)
        case .image(_, let url): grabbedFrame(url)
        case .tool: EmptyView()
        }
    }

    private func userBubble(_ text: String, source: String) -> some View {
        VStack(alignment: .trailing, spacing: Space.s1) {
            Text(source == "phone" ? "You, from your phone" : "You").scaled(t.scale.micro, t.roles.ink2)
            Text(text).scaled(t.scale.body, t.roles.ink)
                .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistant(_ text: String, streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("Claude").scaled(t.scale.micro, t.roles.ink2)
            (Text(text) + Text(streaming ? " ▍" : "").foregroundStyle(t.roles.ink2))
                .scaled(t.scale.body, t.roles.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipRow(_ tools: [ClaudeChatItem]) -> some View {
        FlowLayout(spacing: Space.s1) {
            ForEach(tools) { item in
                if case .tool(_, let name, let summary, let status) = item { chip(name: name, summary: summary, status: status) }
            }
        }
    }

    private func chip(name: String, summary: String, status: ClaudeToolStatus) -> some View {
        let bad = status == .error
        // A tool step: its summary in the text face; only a failure or a running step gets a mark.
        return HStack(spacing: Space.s1) {
            if status == .running { ProgressView().controlSize(.mini) }
            Text(bad ? "\(summary) failed" : summary).font(t.scale.micro.font).lineLimit(1)
        }
        .foregroundStyle(bad ? t.roles.danger : t.roles.ink2)
        .padding(.horizontal, Space.s2).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
        .help(bad ? "\(summary) (\(ClaudeChipText.words(name)))" : ClaudeChipText.words(name))
        .accessibilityLabel(bad ? "\(summary), failed" : summary)
    }

    private func grabbedFrame(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("Frame Claude grabbed").scaled(t.scale.micro, t.roles.ink2)
            MuseImage(ref: ImageRef(url: service.resolve(url)), symbol: "photo")
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).strokeBorder(t.roles.hairline, lineWidth: t.isDark || t.isD ? 0 : 1))
        }
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
        let busy = model.busy
        let empty = model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Space.s2) {
            if !suggestions.isEmpty {
                FlowLayout(spacing: Space.s1) {
                    ForEach(suggestions) { s in
                        Button { model.send(s.prompt) } label: { Text(s.label).fixedSize() }
                            .buttonStyle(RButtonStyle(kind: .quiet, small: true, off: busy || model.thread == nil))
                            .disabled(busy || model.thread == nil)
                            .help(s.prompt)
                            .accessibilityLabel(s.label)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Space.s2) {
                TextField(placeholder ?? "Ask Claude…", text: $model.composer, axis: .vertical)
                    .lineLimit(1...5)
                    .onSubmit { if !busy { model.send() } }
                    .roleField(multiline: true)
                if busy {
                    Button { model.stop() } label: {
                        Ph("stop.fill", 13)
                    }
                    .buttonStyle(RButtonStyle(kind: .quiet))
                    .frame(width: 40)
                    .help("Stop Claude")
                    .accessibilityLabel("Stop Claude")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.send() } label: {
                        Ph("paperplane.fill", 14)
                    }
                    .buttonStyle(RButtonStyle(kind: .action, off: empty || model.thread == nil))
                    .frame(width: 40)
                    .disabled(empty || model.thread == nil)
                    .help("Send to Claude")
                    .accessibilityLabel("Send to Claude")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            Text(modeLine).scaled(t.scale.micro, t.roles.ink2).lineLimit(1)
                .help("Runs in Claude Code on this Mac, billed to the Claude account it is signed in with")
            if let footer { Text(footer).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s4)
        .overlay(alignment: .top) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
    }

    /// "On your Claude plan · claude-sonnet-4-5" (the model name is owner only; this view is too).
    private var modeLine: String {
        let model = self.model.transcript.model ?? service.info.model
        return "On your Claude plan" + (model.map { " · \($0)" } ?? "")
    }
}
