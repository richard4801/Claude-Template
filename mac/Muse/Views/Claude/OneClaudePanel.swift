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
    @State private var showManage = false
    @State private var deleteAsk: OneClaudeDeleteAsk?

    static let width: CGFloat = 380
    /// The floating panel's move (translation, ended).
    var onDrag: ((CGSize, Bool) -> Void)?

    init(onDrag: ((CGSize, Bool) -> Void)? = nil) { self.onDrag = onDrag }

    var body: some View {
        let o = store.oneClaude
        let r = t.roles
        VStack(spacing: 0) {
            header
            Rectangle().fill(r.hairline).frame(height: 1)
            lines
            if let id = o.chatId {
                ClaudeChatView(contextKind: "chat", contextId: id, title: o.current?.shownTitle ?? "Claude", showsHeader: false,
                               placeholder: "Tell me what to do next…", emptyHint: "Ask for anything in MUSE. Claude sees this page and can open others. It asks before spending.",
                               wrapOutgoing: { [store] text in store.oneClaudeOutgoing(text) }, unwrapShown: ClaudePage.stripContext)
                    .sessions(nil, onToolDone: { [store] name in store.suiteClaudeToolDone(name) })
                    .panel(chips: o.chips, activity: activityStrip)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(r.raised)
        .sheet(isPresented: $showMemory) { OneClaudeMemorySheet() }
        .sheet(isPresented: $showManage) { OneClaudeManageChats() }
        .alert(OneClaudeDeleteAsk.title(deleteAsk), isPresented: Binding(get: { deleteAsk != nil }, set: { if !$0 { deleteAsk = nil } })) {
            Button("Delete", role: .destructive) {
                guard case .one(let id)? = deleteAsk else { return }
                Task { await store.deleteOneClaudeChats([id]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(OneClaudeDeleteAsk.keeps) }
        .onChange(of: store.claudePage) { _, _ in store.oneClaudePageChanged() }
        // Claude's orb (MuseCore ClaudeOrb) hears what waits for the person and the job Claude started.
        .onChange(of: store.claudeWaitingCount, initial: true) { _, n in service.orbWaiting(n) }
        .onChange(of: store.claudeJobProgress, initial: true) { _, p in
            let failed = store.oneClaude.watchJob.flatMap { id in store.jobs.first { $0.id == id } }?.isFailed ?? false
            service.orbJob(running: p != nil, failed: failed)
            if p == nil, store.oneClaude.watchJob != nil { store.oneClaude.watchJob = nil }
        }
    }

    // MARK: Header: the chat, New chat, what Claude sees

    private var header: some View {
        let o = store.oneClaude
        let r = t.roles
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s1) {
                ClaudeOrbView(size: 24)
                Text("Claude").scaled(t.scale.heading, r.ink).accessibilityAddTraits(.isHeader)
                    .help(o.current?.shownTitle ?? "New chat")
                Spacer(minLength: Space.s2)
                modelMenu
                Button { Task { await store.newOneClaudeChat() } } label: {
                    Ph("plus", 16).foregroundStyle(r.ink2).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("New chat").accessibilityLabel("New chat")
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
                        Button("Delete this chat…", role: .destructive) { deleteAsk = .one(id) }
                    }
                    Button("Manage chats…") { showManage = true }
                } label: {
                    // A Menu label drops custom image sizing (build 530): the system clock glyph, sized by the font.
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(r.ink2)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("History: your chats and Claude's memory")
                .accessibilityLabel("History. Chat: \(o.current?.shownTitle ?? "new chat"). Open the list of chats")
                SuiteIconButton(systemName: "xmark", label: "Hide Claude", size: 26) { store.toggleOneClaude() }
            }
            ClaudeContextStrip(page: store.claudePage.line, items: store.claudeContextItems)
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        // The floating panel moves by its header (the buttons in it still click: a drag starts after 4 pt).
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { onDrag?($0.translation, false) }
            .onEnded { onDrag?($0.translation, true) })
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "claude header") } }
    }

    // MARK: Live activity: Claude operating the window, or a job it started

    private var activityStrip: AnyView? {
        var a = service.activity
        a.job(store.claudeJobProgress)
        guard a.isActive else { return nil }
        return AnyView(ClaudeActivityStrip(activity: a) { service.stopUiFromPanel() })
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
                // A Menu label drops custom image sizing (owner bug, build 530: a ~300 pt chip icon pushed the header into the
                // editor), so no Phosphor image here: text and the system chevron, sized by the font, as ChatSessionsBar does.
                HStack(spacing: Space.s1) {
                    Text(cur.info?.name ?? "Claude").lineLimit(1).fixedSize()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(t.scale.caption.font).foregroundStyle(r.ink2)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "claude model line") } }
            .help(cur.info.map { "\($0.good). \($0.cost). Faster models use less of your Claude plan." } ?? "Pick the Claude model for this chat")
            .accessibilityLabel("Claude model: \(cur.info?.name ?? "default"). Change it")
        } else {
            // The list isn't here yet (or the server is older): the line still shows, and tapping it tries again.
            Button { Task { await store.loadClaudeModels() } } label: {
                HStack(spacing: Space.s1) {
                    Text("Default model").lineLimit(1).fixedSize()
                }
                .font(t.scale.caption.font).foregroundStyle(r.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Loading the models to choose from. Click to try again.")
            .accessibilityLabel("Claude model: default. Load the models to choose from")
            .task { if store.oneClaude.models == nil { await store.loadClaudeModels() } }
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
                // One event, two parts (coordinator, run 591): a " · " and Back in the link colour, so they never read as one
                // sentence. Lower-risk variant (run 595): the same layout as before plus one Text; no fixedSize/layoutPriority.
                Text("Opened \(opened.line) for you").lineLimit(1)
                Text("·").accessibilityHidden(true)
                Button("Back to \(back.label ?? back.line)") { store.oneClaudeBack() }
                    .buttonStyle(.link).foregroundStyle(r.link).lineLimit(1)
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
        ForEach(o.approvals, id: \.self) { a in
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Claude needs your go-ahead").scaled(t.scale.label, r.ink)
                Text(a.summary ?? "").scaled(t.scale.caption, r.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: a.label ?? "Approve", filled: true) { Task { await store.answerClaudeAction(a, approve: true) } }
                    SuiteToolButton(title: "Decline", plain: true) { Task { await store.answerClaudeAction(a, approve: false) } }
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(r.hairline))
            .padding(.horizontal, Space.s4).padding(.top, Space.s3)
        }
        ClaudeEditNoticeLine()
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

/// Delete chats: what the confirmation asks.
enum OneClaudeDeleteAsk: Hashable {
    case one(String)
    case selected([String])
    case olderThan(Int)

    static let keeps = "Its messages are removed; your memory and anything you made are kept."
    static func title(_ a: OneClaudeDeleteAsk?) -> String {
        switch a {
        case .one?: return "Delete this chat?"
        case .selected(let ids)?: return ids.count == 1 ? "Delete this chat?" : "Delete \(ids.count) chats?"
        case .olderThan(let d)?: return "Delete every chat not used for \(d) days?"
        case nil: return ""
        }
    }
}

/// Manage chats (owner, 2026-11-11: "messages are piling up"): pick several and delete them, delete one from its row
/// (right-click), or delete every chat not used for 30 days. Each asks first.
struct OneClaudeManageChats: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var ask: OneClaudeDeleteAsk?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        let r = t.roles
        let chats = store.oneClaude.chats
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Your chats").scaled(t.scale.title, r.ink)
                Spacer()
                SuiteToolButton(title: "Done", filled: true) { dismiss() }
            }
            Text("Deleting a chat removes its messages. Your memory and anything you made stay.").scaled(t.scale.caption, r.ink2)
            if let e = error { Text(e).scaled(t.scale.caption, r.danger) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if chats.isEmpty { Text("No chats yet.").scaled(t.scale.body, r.ink2) }
                    ForEach(chats) { c in
                        HStack(spacing: Space.s3) {
                            Toggle("", isOn: Binding(get: { picked.contains(c.id) }, set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } }))
                                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Select \(c.shownTitle)")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.shownTitle).scaled(t.scale.body, r.ink).lineLimit(1)
                                Text("Last on \(c.lastOn ?? "—") · \(Self.when(c.updatedAt))\(c.messageCount.map { " · \($0) message\($0 == 1 ? "" : "s")" } ?? "")")
                                    .scaled(t.scale.caption, r.ink2).lineLimit(1)
                            }
                            Spacer(minLength: Space.s2)
                            if c.id == store.oneClaude.chatId { Text("Open").scaled(t.scale.caption, r.ink2) }
                            Button { ask = .one(c.id) } label: { Ph("trash", 14).frame(width: 24, height: 24).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(r.ink2).help("Delete this chat…").accessibilityLabel("Delete \(c.shownTitle)")
                        }
                        .padding(.vertical, Space.s2)
                        .contentShape(Rectangle())
                        .contextMenu { Button("Delete…", role: .destructive) { ask = .one(c.id) } }
                        .overlay(alignment: .top) { Rectangle().fill(r.hairline).frame(height: 1) }
                    }
                }
            }
            HStack(spacing: Space.s3) {
                SuiteToolButton(title: picked.isEmpty ? "Delete selected" : "Delete selected (\(picked.count))", disabled: picked.isEmpty || busy, plain: true) {
                    if !picked.isEmpty && !busy { ask = .selected(Array(picked)) }
                }
                SuiteToolButton(title: "Delete chats older than 30 days…", disabled: busy, plain: true) { if !busy { ask = .olderThan(30) } }
                Spacer()
            }
        }
        .padding(Space.s5)
        .frame(width: 620, height: 560)
        .background(r.canvas)
        .task { await store.refreshOneClaudeChats() }
        .alert(OneClaudeDeleteAsk.title(ask), isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
            Button("Delete", role: .destructive) { if let a = ask { run(a) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(OneClaudeDeleteAsk.keeps) }
    }

    private func run(_ a: OneClaudeDeleteAsk) {
        busy = true
        Task {
            let e: String?
            switch a {
            case .one(let id): e = await store.deleteOneClaudeChats([id])
            case .selected(let ids): e = await store.deleteOneClaudeChats(ids)
            case .olderThan(let d): e = await store.deleteOneClaudeChats([], olderThanDays: d)
            }
            error = e
            if e == nil { picked = picked.filter { id in store.oneClaude.chats.contains { $0.id == id } } }
            busy = false
        }
    }

    /// "today", "3 days ago", "12 Oct".
    static func when(_ ms: Double) -> String {
        guard ms > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let days = Int(Date().timeIntervalSince(d) / 86_400)
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days) days ago" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}
