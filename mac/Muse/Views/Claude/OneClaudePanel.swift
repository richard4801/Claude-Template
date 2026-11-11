import MuseCore
import SwiftUI

/// One Claude (plans/one-claude.md, design/one-claude/*.png): the Claude panel on the right of every page. The chat's
/// name opens the chat list (each with where it was last used), New chat starts one, and "Sees:" says which page Claude
/// is looking at. Claude opens pages itself ("Opened … · Back"), asks first with Open when the person is busy, and shows
/// "Remembered: …" (Undo for the owner). Money, deletes, posting and settings still need the person's press.
struct OneClaudePanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared
    @State private var showMemory = false
    @State private var memberText = ""

    static let width: CGFloat = 380

    var body: some View {
        let o = store.oneClaude
        let r = t.roles
        VStack(spacing: 0) {
            header
            Rectangle().fill(r.hairline).frame(height: 1)
            lines
            if let id = o.chatId {
                if store.oneClaudeOnMac {
                    ClaudeChatView(contextKind: "chat", contextId: id, title: o.current?.shownTitle ?? "Claude", showsHeader: false,
                                   placeholder: "Ask Claude", emptyHint: "Ask for anything in MUSE. Claude sees this page and can open others. It asks before spending.",
                                   wrapOutgoing: { [store] text in store.oneClaudeOutgoing(text) }, unwrapShown: ClaudePage.stripContext)
                        .sessions(nil, onToolDone: { [store] name in store.suiteClaudeToolDone(name) })
                        .id(id)
                } else {
                    memberChat
                }
            } else if let e = o.listError {
                VStack(spacing: Space.s3) {
                    Text(e).scaled(t.scale.body, r.ink2).multilineTextAlignment(.center)
                    SuiteToolButton(title: "Try again") { Task { await store.startOneClaude() } }
                }
                .padding(Space.s5).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: Space.s2) { SkeletonBlock(width: 220, height: 10); SkeletonBlock(width: 160, height: 10) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(r.raised)
        .sheet(isPresented: $showMemory) { OneClaudeMemorySheet() }
        .onChange(of: store.claudePage) { _, _ in store.oneClaudePageChanged() }
    }

    // MARK: Header: the chat, New chat, what Claude sees

    private var header: some View {
        let o = store.oneClaude
        let r = t.roles
        return VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Menu {
                    Section("Chats") {
                        ForEach(o.chats) { c in
                            Button { store.pickOneClaudeChat(c.id) } label: {
                                let words = "\(c.shownTitle), last on \(c.lastOn ?? "—")"
                                if c.id == o.chatId { Label(words, systemImage: "checkmark") } else { Text(words) }
                            }
                        }
                    }
                    Divider()
                    Button("Claude's memory…") { showMemory = true }
                    if let id = o.chatId {
                        Button("Hide this chat") { Task { await store.archiveOneClaudeChat(id) } }
                    }
                } label: {
                    HStack(spacing: Space.s1) {
                        Text(o.current?.shownTitle ?? "Claude").scaled(t.scale.label, r.ink).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(r.ink2)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .help("Your chats: switch, or open Claude's memory")
                .accessibilityLabel("Chat: \(o.current?.shownTitle ?? "Claude"). Open the list of chats")
                Spacer(minLength: Space.s2)
                Button { Task { await store.newOneClaudeChat() } } label: {
                    HStack(spacing: Space.s1) { Ph("plus", 14); Text("New chat").fixedSize() }
                        .font(t.scale.label.font).foregroundStyle(r.ink2).frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Start a chat for a new piece of work").accessibilityLabel("New chat")
                SuiteIconButton(systemName: "xmark", label: "Hide Claude", size: 26) { store.toggleOneClaude() }
            }
            HStack(spacing: Space.s1) {
                Ph("map-pin", 13)
                Text("Sees: \(store.claudePage.line)").lineLimit(1).truncationMode(.middle)
            }
            .font(t.scale.caption.font).foregroundStyle(r.ink2)
            .accessibilityLabel("Claude sees \(store.claudePage.line)")
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
    }

    // MARK: Claude's lines: open a page, back, remembered

    @ViewBuilder private var lines: some View {
        let o = store.oneClaude
        let r = t.roles
        if let ask = o.askOpen, let target = ask.target {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Open \(target.line)?").scaled(t.scale.label, r.ink)
                Text("You'll leave this page for a moment. Your work here is saved.").scaled(t.scale.caption, r.ink2)
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: "Open", filled: true) { store.performOneClaudeOpen(ask) }
                    SuiteToolButton(title: "Stay here", plain: true) { store.oneClaude.askOpen = nil }
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(r.hairline))
            .padding(.horizontal, Space.s4).padding(.top, Space.s3)
        }
        if let opened = o.opened, let back = o.back {
            HStack(spacing: Space.s1) {
                Ph("arrow-square-out", 13)
                Text("Opened \(opened.line) for you").lineLimit(1)
                Button("Back to \(back.label ?? back.line)") { store.oneClaudeBack() }
                    .buttonStyle(.link).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(t.scale.caption.font).foregroundStyle(r.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s2)
        }
        if let m = o.remembered, let text = m.text {
            HStack(alignment: .top, spacing: Space.s1) {
                Ph("push-pin", 13)
                Text("Remembered: “\(text)”").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if m.undo == true, store.isOwner {
                    Button("Undo") { Task { await store.undoOneClaudeMemory() } }.buttonStyle(.link)
                }
            }
            .font(t.scale.caption.font).foregroundStyle(r.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s2)
        }
    }

    // MARK: The chat on the studio's Claude (members, or the owner without Claude Code on this Mac)

    private var memberChat: some View {
        let o = store.oneClaude
        let r = t.roles
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s3) {
                        if o.lines.isEmpty && o.streaming.isEmpty {
                            Text("Ask for anything in MUSE. Claude sees this page and can open others. It asks before spending.")
                                .scaled(t.scale.caption, r.ink2)
                        }
                        ForEach(o.lines) { l in
                            Text(l.text).scaled(t.scale.body, r.ink).textSelection(.enabled)
                                .padding(l.fromClaude ? 0 : Space.s2)
                                .background(l.fromClaude ? Color.clear : r.field, in: RoundedRectangle(cornerRadius: t.radii.container))
                                .frame(maxWidth: .infinity, alignment: l.fromClaude ? .leading : .trailing)
                        }
                        if !o.streaming.isEmpty {
                            Text(o.streaming).scaled(t.scale.body, r.ink).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let e = o.sendError { Text(e).scaled(t.scale.caption, r.danger) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(Space.s4)
                }
                .onChange(of: o.lines.count) { _, _ in proxy.scrollTo("end") }
            }
            HStack(spacing: Space.s2) {
                TextField("Ask Claude", text: $memberText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .onSubmit { sendMember() }
                Button { sendMember() } label: { Ph("paper-plane-right", 16).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(r.ink2)
                    .disabled(o.sending || memberText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send").accessibilityLabel("Send")
            }
            .padding(Space.s3)
            .background(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(r.hairline))
            .padding(Space.s4)
        }
    }

    private func sendMember() {
        let text = memberText
        memberText = ""
        Task { await store.sendMemberLine(text) }
    }
}

/// Claude's memory, read from every chat: figure rules, style, preferred models, things said no to, editing rules.
/// Everyone can read it; the owner edits it in the Playbook (pins, edits, deletes).
struct OneClaudeMemorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = t.roles
        let rules = store.oneClaude.memory?.rules ?? []
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Claude's memory").scaled(t.scale.title, r.ink)
                Spacer()
                if store.isOwner {
                    SuiteToolButton(title: "Edit in Playbook", plain: true) { dismiss(); store.openLearn(.playbook) }
                }
                SuiteToolButton(title: "Done", filled: true) { dismiss() }
            }
            Text("Every chat reads this. Pinned rules are always followed; Claude asks before breaking one.\(store.isOwner ? "" : " Only the owner can change it.")")
                .scaled(t.scale.caption, r.ink2)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    if rules.isEmpty { Text("Nothing remembered yet.").scaled(t.scale.body, r.ink2) }
                    ForEach(Learn.areas.filter { a in rules.contains { $0.area == a } }, id: \.self) { a in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(LearnText.area(a)).scaled(t.scale.label, r.ink).padding(.bottom, Space.s2)
                            ForEach(rules.filter { $0.area == a }) { rule in
                                HStack(alignment: .top, spacing: Space.s2) {
                                    if rule.pinned { Ph("push-pin", 14) } else { Color.clear.frame(width: 14, height: 14) }
                                    Text(rule.text).scaled(t.scale.body, r.ink).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: Space.s2)
                                    Text(rule.source == "owner" ? "You" : "Claude learned").scaled(t.scale.caption, r.ink2)
                                }
                                .padding(.vertical, Space.s2)
                                .overlay(alignment: .top) { Rectangle().fill(r.hairline).frame(height: 1) }
                            }
                        }
                    }
                }
            }
        }
        .padding(Space.s5)
        .frame(width: 620, height: 560)
        .background(r.canvas)
        .task { await store.loadOneClaudeMemory() }
    }
}
