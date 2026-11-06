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

    init(contextKind: String, contextId: String, title: String) {
        self.contextKind = contextKind
        self.contextId = contextId
        self.title = title
    }

    init(contextKind: String, contextId: String, title: String, showsHeader: Bool, footer: String? = nil, placeholder: String? = nil, accessory: AnyView? = nil) {
        self.contextKind = contextKind
        self.contextId = contextId
        self.title = title
        self.showsHeader = showsHeader
        self.footer = footer
        self.placeholder = placeholder
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Rectangle().fill(t.line).frame(height: 1)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.surface)
        .task(id: "\(contextKind)|\(contextId)|\(service.configured)|\(service.baseURL?.absoluteString ?? "")") {
            await model.attach(service, contextKind: contextKind, contextId: contextId)
        }
        .onDisappear { model.detach() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(t.body(16, .bold)).foregroundStyle(t.ink)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if !store.isOwner {
            centered { Muted("Claude chat is for the studio owner.", size: 13) }
        } else if !service.configured {
            centered { Muted("Sign in to your MUSE server to chat with Claude.", size: 13) }
        } else if !service.checkedOnce || (service.checking && !service.info.installed) {
            centered {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Muted("Looking for Claude Code on this Mac…", size: 13)
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
        VStack { c() }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Setup states

    private func setup(installed: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(installed ? "Sign in to Claude" : "Use Claude on your own plan").font(t.body(15, .bold)).foregroundStyle(t.ink)
                Muted(installed
                      ? "Claude Code is installed. Sign in with your Claude account so chats here run on your subscription."
                      : "MUSE runs Anthropic's Claude Code on this Mac, signed in to your Claude subscription. Nothing is billed to the studio.", size: 13)
                if !installed {
                    step(1, "Install", "Opens Terminal and runs Anthropic's official installer (claude.ai/install.sh).", primary: true) { service.openInstall() }
                }
                step(installed ? 1 : 2, "Sign in", "Opens Claude's own sign-in page. MUSE never sees your password or keys.", primary: installed, off: !installed) { service.openSignIn() }
                HStack(spacing: 8) {
                    MButton(service.checking ? "Checking…" : "Re-check", icon: "arrow.clockwise", size: .small, off: service.checking) {
                        Task { await service.recheck() }
                    }
                    if let v = service.info.version { Text("Claude Code \(v)").font(t.mono(11)).foregroundStyle(t.muted) }
                }
                if let e = service.lastError { Text(e).font(t.body(12)).foregroundStyle(t.accent) }
            }
            .padding(18)
        }
        .frame(maxHeight: .infinity)
    }

    private func step(_ n: Int, _ title: String, _ hint: String, primary: Bool, off: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(t.mono(12, .semibold)).foregroundStyle(t.muted).frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
                MButton(title, kind: primary ? .primary : .secondary, size: .small, off: off, action: action)
                Muted(hint)
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let items = model.transcript.items
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let accessory { accessory }
                    if model.loading, items.isEmpty { ProgressView().controlSize(.small) }
                    if let e = model.loadError { Note(icon: "exclamationmark.circle", warn: true, e) }
                    if items.isEmpty, !model.loading, model.loadError == nil {
                        Text(contextKind == "edit"
                             ? "Ask Claude to edit: trim, add captions, change the Look, check a frame. Every change can be undone."
                             : "Tell Claude what happens in the shot: who walks where, when they turn, how the camera moves.")
                            .font(t.body(13)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(chunks(items)) { chunk in
                        switch chunk {
                        case .single(let item): row(item)
                        case .chips(_, let tools): chipRow(tools)
                        }
                    }
                    if let e = model.transcript.lastError, !model.busy { Note(icon: "exclamationmark.triangle", warn: true, e) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
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
        case .user(_, let text, let source): userBubble(text, source: source)
        case .assistant(_, let text, let streaming): assistant(text, streaming: streaming)
        case .image(_, let url): frame(url)
        case .tool: EmptyView()
        }
    }

    private func userBubble(_ text: String, source: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Lbl(source == "phone" ? "You · phone" : "You")
            Text(text).font(t.body(13)).foregroundStyle(t.bg).lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: t.isA ? 0 : t.r).fill(t.ink))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistant(_ text: String, streaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Lbl("Claude")
            (Text(text) + Text(streaming ? " ▍" : "").foregroundStyle(t.muted))
                .font(t.body(13)).foregroundStyle(t.ink).lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipRow(_ tools: [ClaudeChatItem]) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(tools) { item in
                if case .tool(_, let name, let summary, let status) = item { chip(name: name, summary: summary, status: status) }
            }
        }
    }

    private func chip(name: String, summary: String, status: ClaudeToolStatus) -> some View {
        let bad = status == .error
        return HStack(spacing: 5) {
            if status == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: bad ? "exclamationmark.triangle" : name.hasPrefix("blender_") ? "cube" : "wand.and.stars").font(.system(size: 9.5))
            }
            Text(summary).font(t.mono(10, .medium)).lineLimit(1)
        }
        .foregroundStyle(bad ? t.accent : t.muted)
        .padding(.horizontal, 7).frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 4).strokeBorder(bad ? t.accent : t.line, lineWidth: 1))
        .help(bad ? "\(summary) (\(ClaudeChipText.words(name)))" : ClaudeChipText.words(name))
        .accessibilityLabel(bad ? "\(summary), failed" : summary)
    }

    private func frame(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Lbl("Frame Claude grabbed")
            MuseImage(ref: ImageRef(url: service.resolve(url)), symbol: "photo")
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: t.isA ? 0 : t.r))
                .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : t.r).strokeBorder(t.line, lineWidth: 1))
        }
    }

    // MARK: Phone strip and composer

    private var phoneStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 12, weight: .semibold))
            Text("Answering from your phone").font(t.body(12.5, .semibold))
            Spacer()
            ProgressView().controlSize(.small)
        }
        .foregroundStyle(t.ink)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(t.surface2)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var composer: some View {
        let busy = model.busy
        let empty = model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder ?? "Ask Claude…", text: $model.composer, axis: .vertical)
                    .lineLimit(1...5)
                    .onSubmit { if !busy { model.send() } }
                    .fieldChrome()
                if busy {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(MuseButtonStyle(kind: .secondary))
                    .frame(width: 44)
                    .help("Stop Claude")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.send() } label: {
                        Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(MuseButtonStyle(kind: .primary, off: empty || model.thread == nil))
                    .frame(width: 44)
                    .disabled(empty || model.thread == nil)
                    .help("Send to Claude")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(t.good).frame(width: 6, height: 6)
                Text(modeLine).font(t.mono(10.5)).foregroundStyle(t.muted).lineLimit(1)
            }
            .help("Runs in Claude Code on this Mac, billed to the Claude account it is signed in with")
            if let footer { Text(footer).font(t.body(12)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
    }

    /// "On your Claude plan · claude-sonnet-4-5" (the model name is owner only; this view is too).
    private var modeLine: String {
        let model = self.model.transcript.model ?? service.info.model
        return "On your Claude plan" + (model.map { " · \($0)" } ?? "")
    }
}
