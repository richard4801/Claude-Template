import AppKit
import MuseCore
import SwiftUI

// The rows every Claude chat on the Mac draws (plans/claude-chat-mac.md): the user's messages in bubbles on the right,
// Claude's replies as clean markdown text on the left, tool steps as compact rows (running, done or failed, each expandable
// to one plain line), images as thumbnails. A lazy stack with stable ids; it follows new text while you're at the bottom
// and offers "Jump to latest" when you've scrolled up.

struct ChatImage: Hashable {
    var ref: ImageRef?
    var data: Data?
    /// A video the message carried, with no poster here (sent from the phone, or after a restart): a "Video" chip.
    var video = false
}

struct ChatToolLine: Hashable, Identifiable {
    let id: String
    var name: String
    var summary: String
    var status: ClaudeToolStatus
}

enum ChatRowKind: Hashable {
    case user(text: String, images: [ChatImage], phone: Bool)
    case assistant(text: String, streaming: Bool)
    case tools([ChatToolLine])
    case frame(url: String)
    /// A card Claude put up (ChatCards.swift); `messageId` is its stored line.
    case card(messageId: String, ClaudeCard)
}

struct ChatRow: Identifiable, Hashable {
    let id: String
    var kind: ChatRowKind

    /// The transcript's items as rows: the leak filter on every text, consecutive tool steps grouped, empty text dropped.
    static func build(_ items: [ClaudeChatItem], audience: ChatLeakFilter.Audience, unwrap: ((String) -> String)?,
                      images: (ClaudeChatItem) -> [ChatImage]) -> [ChatRow] {
        var out: [ChatRow] = []
        for item in items {
            switch item {
            case .user(let id, let text, let source):
                let shown = ChatLeakFilter.userText(unwrap?(text) ?? text)
                let imgs = images(item)
                guard !shown.isEmpty || !imgs.isEmpty else { continue }
                out.append(ChatRow(id: id, kind: .user(text: shown, images: imgs, phone: source == "phone")))
            case .assistant(let id, let text, let streaming):
                let shown = ChatLeakFilter.reply(text, audience: audience)
                guard !shown.isEmpty else { continue }
                out.append(ChatRow(id: id, kind: .assistant(text: shown, streaming: streaming)))
            case .tool(let id, let name, let summary, let status):
                let line = ChatToolLine(id: id, name: name, summary: ChatLeakFilter.toolSummary(summary, name: name), status: status)
                if case .tools(let list)? = out.last?.kind {
                    out[out.count - 1].kind = .tools(list + [line])
                } else {
                    out.append(ChatRow(id: "tools_" + id, kind: .tools([line])))
                }
            case .image(let id, let url):
                out.append(ChatRow(id: id, kind: .frame(url: url)))
            case .card(let id, let messageId, let card):
                out.append(ChatRow(id: "card_" + id, kind: .card(messageId: messageId, card)))
            }
        }
        return out
    }
}

/// What the transcript shows besides its rows.
struct ChatTranscriptState: Equatable {
    var loading = false
    /// The thread couldn't load: the words, and whether it was the connection.
    var loadError: String?
    var offline = false
    /// The last turn failed (already in plain words).
    var turnError: String?
    var busy = false
    var emptyTitle = "Chat with Claude"
    var emptyHint = ""
    /// The last turn ran without Blender's tools (its server didn't start): Retry Blender.
    var blenderFailed = false
    /// uvx is fetching Blender's tools (the relay was just switched on).
    var blenderWarming = false
}

struct ChatTranscriptView: View {
    @Environment(\.theme) private var t
    let rows: [ChatRow]
    let state: ChatTranscriptState
    var accessory: AnyView?
    var resolve: (String) -> String = { $0 }
    var onRetry: () -> Void = {}
    var onRetryBlender: () -> Void = {}
    var onReload: () -> Void = {}

    @State private var pinned = true
    @State private var showJump = false
    @State private var lastFrame: CGRect = .zero
    @State private var followPending = false
    @State private var scrollAgain = false
    private static let endId = "chat_end"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s4) {
                        if let accessory { accessory }
                        header
                        ForEach(rows) { row in
                            ChatRowView(row: row, resolve: resolve)
                                .equatable()
                                .id(row.id)
                        }
                        footer
                        Color.clear.frame(height: 1).id(Self.endId)
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s4)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ChatContentFrameKey.self, value: g.frame(in: .named("chatScroll")))
                    })
                }
                .coordinateSpace(.named("chatScroll"))
                .onPreferenceChange(ChatContentFrameKey.self) { f in follow(f, viewport: outer.size.height, proxy: proxy) }
                .onAppear { proxy.scrollTo(Self.endId, anchor: .bottom) }
                .onChange(of: rows.count) { _, _ in if pinned { scrollToEnd(proxy, animated: false) } }
                // Run 612: the window shrank or the composer grew; a chat at its end stays there.
                .onChange(of: outer.size) { _, _ in if pinned { scrollToEnd(proxy, animated: false) } }
                .onChange(of: state.busy) { _, busy in if busy { pinned = true; scrollToEnd(proxy, animated: true) } }
                .overlay(alignment: .bottom) {
                    if showJump {
                        Button { pinned = true; scrollToEnd(proxy, animated: true) } label: {
                            HStack(spacing: Space.s1) {
                                Ph("caret-down", 12)
                                Text("Jump to latest").font(t.scale.label.font)
                            }
                            .foregroundStyle(t.roles.ink)
                            .padding(.horizontal, Space.s3)
                            .frame(height: 30)
                            .background(Capsule().fill(t.roles.raised))
                            .overlay(Capsule().strokeBorder(t.roles.hairline))
                            .museFloat(t)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, Space.s3)
                        .help("Scroll to the newest message")
                        .accessibilityLabel("Jump to latest message")
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: showJump)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation with Claude")
    }

    // MARK: Following new text

    /// The content's frame in the scroll view: its top moves when the reader scrolls, its height when text arrives.
    private func follow(_ f: CGRect, viewport: CGFloat, proxy: ScrollViewProxy) {
        let distance = f.maxY - viewport
        let moved = abs(f.minY - lastFrame.minY) > 0.5
        // Real growth (new text), or a new width (the rows re-wrapped: a resize): the lazy stack re-estimating rows makes the
        // height wobble both ways at one width, which alone must not scroll (runs 595/604).
        let grew = f.height > lastFrame.height + 0.5 || abs(f.width - lastFrame.width) > 0.5
        lastFrame = f
        if moved {
            let p = distance < 48
            if p != pinned { pinned = p }
        } else if grew, pinned, distance > 1, followPending {
            scrollAgain = true
        } else if grew, pinned, distance > 1 {
            // Only when the new text pushed the end out of view, and one scroll at a time (runs 595 and 604: a streaming
            // reply scrolled, re-measured and scrolled again on every frame; the main thread never rested).
            followPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                proxy.scrollTo(Self.endId, anchor: .bottom)
                followPending = false
                if scrollAgain { scrollAgain = false; scrollToEnd(proxy, animated: false) }
            }
        }
        let j = !pinned && distance > 120
        if j != showJump { showJump = j }
    }

    /// Coalesced (run 607: a third of the main thread while a reply streamed was these scrolls, one per new row): at most
    /// one scroll pending, a tenth of a second after the first ask.
    /// Run 610: a request dropped while one was pending left long chats short of the end (the rows were still being
    /// laid out), so a request during a pending scroll asks for one more after it; still at most ten a second.
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !followPending else { scrollAgain = true; return }
        followPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.endId, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.endId, anchor: .bottom)
            }
            followPending = false
            if scrollAgain {
                scrollAgain = false
                scrollToEnd(proxy, animated: false)
            }
        }
    }

    // MARK: States

    @ViewBuilder private var header: some View {
        if state.loading, rows.isEmpty {
            // Shaped like a conversation: a bubble on the right, lines of a reply on the left.
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack { Spacer(); SkeletonBlock(width: 180, height: 32, radius: t.radii.control) }
                SkeletonBlock(width: 240, height: 10)
                SkeletonBlock(width: 280, height: 10)
                SkeletonBlock(width: 160, height: 10)
            }
            .accessibilityLabel("Loading the conversation")
        } else if let e = state.loadError {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Ph(state.offline ? "wifi-slash" : "warning", 16).foregroundStyle(state.offline ? t.roles.ink2 : t.roles.danger)
                    Text(state.offline ? "You're offline" : "Couldn't open this chat").scaled(t.scale.heading, t.roles.ink)
                }
                Text(e).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                RButton("Try again", kind: .quiet, small: true, action: onReload)
            }
            .accessibilityElement(children: .combine)
        } else if rows.isEmpty, !state.busy {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(state.emptyTitle).scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
                if !state.emptyHint.isEmpty {
                    Text(state.emptyHint).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Text("Return sends, Shift-Return starts a new line, ⌘K jumps to the message field.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if state.busy, !lastIsStreamingText {
            HStack(spacing: Space.s2) {
                ChatRunningDot()
                Text("Claude is working…").scaled(t.scale.caption, t.roles.ink2)
            }
            .accessibilityElement(children: .combine)
        }
        if state.blenderWarming {
            HStack(spacing: Space.s2) {
                ProgressView().controlSize(.small)
                Text("Getting Blender ready…").scaled(t.scale.caption, t.roles.ink2)
            }
            .accessibilityElement(children: .combine)
        } else if state.blenderFailed, !state.busy {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Ph("warning", 14).foregroundStyle(t.roles.danger)
                Text("Blender's tools didn't start, so Claude couldn't use Blender this time.")
                    .scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s2)
                RButton("Retry Blender", kind: .quiet, small: true, action: onRetryBlender)
                    .help("Get Blender's tools again, then send your last message again")
            }
            .accessibilityElement(children: .contain)
        }
        if let e = state.turnError, !state.busy {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Ph("warning", 14).foregroundStyle(t.roles.danger)
                Text(e).scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s2)
                RButton("Try again", kind: .quiet, small: true, action: onRetry)
                    .help("Send your last message again")
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var lastIsStreamingText: Bool {
        if case .assistant(_, true)? = rows.last?.kind { return true }
        return false
    }
}

private struct ChatContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: Rows

struct ChatRowView: View, Equatable {
    let row: ChatRow
    var resolve: (String) -> String

    static func == (a: ChatRowView, b: ChatRowView) -> Bool { a.row == b.row }

    var body: some View {
        switch row.kind {
        case .user(let text, let images, let phone): ChatUserBubble(text: text, images: images, phone: phone, resolve: resolve)
        case .assistant(let text, let streaming): ChatAssistantText(text: text, streaming: streaming)
        case .tools(let lines): ChatToolRows(lines: lines)
        case .frame(let url): ChatFrame(url: resolve(url))
        case .card(let messageId, let card): ChatCardView(card: card, messageId: messageId, resolve: resolve)
        }
    }
}

struct ChatUserBubble: View {
    @Environment(\.theme) private var t
    let text: String
    let images: [ChatImage]
    let phone: Bool
    var resolve: (String) -> String = { $0 }

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.s1) {
            if phone { Text("From your phone").scaled(t.scale.micro, t.roles.ink2) }
            if !images.isEmpty {
                HStack(spacing: Space.s1) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, img in thumb(img) }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .typeStep(t.scale.body)
                    .foregroundStyle(t.roles.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                    .background(RoundedRectangle(cornerRadius: min(t.radii.container, 16), style: .continuous).fill(t.roles.field))
                    .contextMenu {
                        Button("Copy") { ChatPasteboard.copy(text) }
                    }
                    .background { if SnapshotRunner.probing { ComposerBarFrame(key: "chat bubble \(text.count)", refreshOnProbe: false) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, Space.s7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(phone ? "You, from your phone: \(text)" : "You: \(text)")
    }

    @ViewBuilder private func thumb(_ img: ChatImage) -> some View {
        Group {
            if img.video {
                VStack(spacing: Space.s1) {
                    Ph("film", 20)
                    Text("Video").scaled(t.scale.caption, t.roles.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(t.roles.field)
            } else if let d = img.data, let ns = NSImage(data: d) {
                Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
            } else {
                MuseImage(ref: img.ref.map { ImageRef(asset: $0.asset, url: $0.url.map(resolve)) }, symbol: "photo")
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: min(t.radii.control, 8), style: .continuous))   // an image, never a pill
        .accessibilityLabel(img.video ? "Attached video" : "Attached image")
    }
}

/// Claude's reply: markdown as clean text on the canvas, no bubble. Copy on hover and in the context menu.
struct ChatAssistantText: View {
    @Environment(\.theme) private var t
    let text: String
    let streaming: Bool
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        let blocks = ChatMarkdown.parse(text, streaming: streaming)
        VStack(alignment: .leading, spacing: Space.s1) {
            // Claude's orb beside the reply while it is being written (it settles when the reply is done).
            if streaming {
                HStack(spacing: Space.s1) {
                    ClaudeOrbView(size: 16)
                    Text("Claude").scaled(t.scale.micro, t.roles.ink2)
                }
                .accessibilityHidden(true)
            }
            ChatMarkdownView(blocks: blocks)
            if !streaming {
                HStack(spacing: Space.s2) {
                    Button { copy() } label: {
                        HStack(spacing: Space.s1) {
                            Ph(copied ? "check" : "copy", 12)
                            Text(copied ? "Copied" : "Copy").font(t.scale.micro.font)
                        }
                        .foregroundStyle(t.roles.ink2)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy Claude's reply")
                    .accessibilityLabel("Copy Claude's reply")
                }
                .opacity(hover || copied ? 1 : 0)
                .accessibilityHidden(!(hover || copied))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy") { ChatPasteboard.copy(text) }
            Button("Copy as plain text") { ChatPasteboard.copy(ChatMarkdown.plainText(blocks)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude: \(ChatMarkdown.plainText(blocks))")
        .accessibilityAction(named: "Copy") { ChatPasteboard.copy(text) }
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "chat reply \(text.count)", refreshOnProbe: false) } }
    }

    private func copy() {
        ChatPasteboard.copy(text)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// Tool steps: one compact line each (a spinner while running, a check when done, a warning when it failed), opening to
/// one plain sentence.
struct ChatToolRows: View {
    let lines: [ChatToolLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { ChatToolRow(line: $0) }
        }
    }
}

struct ChatToolRow: View {
    @Environment(\.theme) private var t
    let line: ChatToolLine
    @State private var open = false

    var body: some View {
        let bad = line.status == .error
        VStack(alignment: .leading, spacing: 2) {
            Button { open.toggle() } label: {
                HStack(spacing: Space.s2) {
                    Group {
                        switch line.status {
                        case .running: ChatRunningDot()
                        case .done: Ph("check", 12).foregroundStyle(t.roles.ink2)
                        case .error: Ph("warning", 12).foregroundStyle(t.roles.danger)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(line.summary)
                        .font(t.scale.caption.font)
                        .foregroundStyle(bad ? t.roles.danger : t.roles.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.s1)
                    Ph(open ? "caret-up" : "caret-down", 10).foregroundStyle(t.roles.ink2)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide details" : "Show what this step did")
            .accessibilityLabel("\(line.summary), \(line.status == .running ? "running" : bad ? "failed" : "done")")
            .accessibilityHint(open ? "Hides the details" : "Shows what this step did")
            if open {
                Text(ChatLeakFilter.toolDetail(name: line.name, summary: line.summary, status: line.status))
                    .scaled(t.scale.caption, t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 16 + Space.s2)
                    .padding(.bottom, Space.s1)
            }
        }
    }
}

struct ChatFrame: View {
    @Environment(\.theme) private var t
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            MuseImage(ref: ImageRef(url: url), symbol: "photo")
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).strokeBorder(t.roles.hairline, lineWidth: t.isDark || t.isD ? 0 : 1))
            Text("Frame Claude looked at").scaled(t.scale.micro, t.roles.ink2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("A frame Claude looked at")
    }
}

/// A step that's still running: a small dot that breathes (still with Reduce Motion). Drawn in SwiftUI, so it never
/// holds up a window snapshot the way a native spinner can.
struct ChatRunningDot: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(t.roles.ink2)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.3 : 1)
            .frame(width: 16, height: 16)
            .onAppear {
                guard !reduceMotion, !SnapshotRunner.probing else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel("Running")
    }
}
