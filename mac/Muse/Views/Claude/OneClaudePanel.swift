import MuseCore
import SwiftUI

/// One Claude (plans/one-claude.md, design/one-claude/*.png): the Claude panel on the right of every page. The chat's
/// name opens the chat list (each with where it was last used), New chat starts one, and "Sees:" says which page Claude
/// is looking at. Claude opens pages itself ("Opened … · Back"), asks first with Open when the person is busy, asks
/// "Shall I remember: …?" (Remember / No) and saves only when asked. Money, deletes, posting and settings still need the
/// person's press. Everyone chats on their own Claude plan (Claude Code on this Mac); the setup states are the chat's.
struct OneClaudePanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared
    @State private var showMemory = false

    static let width: CGFloat = 380

    var body: some View {
        let o = store.oneClaude
        let r = t.roles
        VStack(spacing: 0) {
            header
            Rectangle().fill(r.hairline).frame(height: 1)
            lines
            if let id = o.chatId {
                ClaudeChatView(contextKind: "chat", contextId: id, title: o.current?.shownTitle ?? "Claude", showsHeader: false,
                               placeholder: "Ask Claude", emptyHint: "Ask for anything in MUSE. Claude sees this page and can open others. It asks before spending.",
                               wrapOutgoing: { [store] text in store.oneClaudeOutgoing(text) }, unwrapShown: ClaudePage.stripContext)
                    .sessions(nil, onToolDone: { [store] name in store.suiteClaudeToolDone(name) })
                    .id(id)
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
                    Button("Your memory…") { showMemory = true }
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
            modelMenu
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
    }

    // MARK: The chat's Claude model (step 6b): speed and cost in plain words, per chat, with your own default

    @ViewBuilder private var modelMenu: some View {
        let r = t.roles
        if let list = store.oneClaude.models, !list.models.isEmpty {
            let cur = store.oneClaudeModel
            Menu {
                Section("Model for this chat") {
                    ForEach(list.models) { m in
                        Button { Task { await store.setOneClaudeModel(m.id) } } label: {
                            let words = "\(m.name): \(m.speed.lowercased()), \(m.cost.lowercased())"
                            if m.id == cur.info?.id && !cur.isDefault { Label(words, systemImage: "checkmark") } else { Text(words) }
                        }
                    }
                }
                Divider()
                Button(cur.isDefault ? "Using your default" : "Use your default") { Task { await store.setOneClaudeModel(nil) } }
                    .disabled(cur.isDefault)
                if let id = cur.info?.id, id != list.default {
                    Button("Make \(cur.info?.name ?? "this") your default") { Task { await store.setOneClaudeDefaultModel(id) } }
                }
            } label: {
                HStack(spacing: Space.s1) {
                    Ph("cpu", 13)
                    Text("\(cur.info?.name ?? "Claude")\(cur.isDefault ? " (your default)" : "") · \(cur.info?.speed ?? "")").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(t.scale.caption.font).foregroundStyle(r.ink2)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(cur.info.map { "\($0.good). \($0.cost). Faster models use less of your Claude plan." } ?? "Pick the Claude model for this chat")
            .accessibilityLabel("Claude model: \(cur.info?.name ?? "default"). Change it")
        }
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
        if let q = o.suggestion, let text = q.suggest {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Shall I remember this?").scaled(t.scale.label, r.ink)
                Text("“\(text)”").scaled(t.scale.caption, r.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: "Remember", filled: true) { Task { await store.rememberSuggestion() } }
                    SuiteToolButton(title: "No", plain: true) { store.oneClaude.suggestion = nil }
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(r.hairline))
            .padding(.horizontal, Space.s4).padding(.top, Space.s3)
        }
        if let m = o.remembered, let text = m.text {
            HStack(alignment: .top, spacing: Space.s1) {
                Ph("push-pin", 13)
                Text("Remembered: “\(text)”").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(t.scale.caption.font).foregroundStyle(r.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s2)
        }
    }
}

/// Your memory, read by every one of your chats (per person: nobody else sees it). Pin or remove rules here; the owner's
/// memory is also her editing Playbook (edit words there).
struct OneClaudeMemorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = t.roles
        let rules = store.oneClaude.memory?.rules ?? []
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Your memory").scaled(t.scale.title, r.ink)
                Spacer()
                if store.isOwner {
                    SuiteToolButton(title: "Edit in Playbook", plain: true) { dismiss(); store.openLearn(.playbook) }
                }
                SuiteToolButton(title: "Done", filled: true) { dismiss() }
            }
            Text("Every one of your chats reads this, and only you see it. Pinned rules are always followed. Claude saves here only when you ask, or when you press Remember.")
                .scaled(t.scale.caption, r.ink2)
            if let e = store.oneClaude.memoryError { Text(e).scaled(t.scale.caption, r.danger) }
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
                                    Text(rule.source == "owner" ? "You" : "Saved by Claude").scaled(t.scale.caption, r.ink2)
                                    Button { Task { await store.pinOneClaudeMemory(rule) } } label: { Ph("push-pin", 14).frame(width: 24, height: 24).contentShape(Rectangle()) }
                                        .buttonStyle(.plain).foregroundStyle(rule.pinned ? r.ink : r.ink2)
                                        .help(rule.pinned ? "Unpin" : "Pin: always followed").accessibilityLabel(rule.pinned ? "Unpin rule" : "Pin rule")
                                    Button { Task { await store.deleteOneClaudeMemory(rule) } } label: { Ph("trash", 14).frame(width: 24, height: 24).contentShape(Rectangle()) }
                                        .buttonStyle(.plain).foregroundStyle(r.ink2)
                                        .help("Remove from your memory").accessibilityLabel("Remove rule")
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
