import MuseCore
import Observation
import SwiftUI

// Claude in the Edit suite (workstream 3, plans/claude-editing.md A and E), owner only: the "Claude" badge, the shared
// history with server undo, the "Claude edited this" toast, the confirmation sheet for paid helpers, and the right panel with
// workstream 2's chat (ClaudeChatView) about this edit session.

/// The small "Claude" badge on Claude's changes.
struct ClaudeBadge: View {
    @Environment(\.theme) private var t
    var body: some View {
        // No sparkle (plans/design-direction.md: AI has no icon); the word says who made the change.
        Text("Claude").font(t.scale.micro.font)
        .foregroundStyle(t.accentInk)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(t.accentFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("By Claude")
    }
}

/// The session's history, newest first: who made each change (Claude's badged) and Undo for any change still in the edit.
struct EditSuiteHistoryList: View {
    @Environment(\.theme) private var t
    var session: EditSuiteSession
    var limit = 60

    var body: some View {
        let entries = Array(session.liveHistory.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No changes yet. Edits made here, on your phone or by Claude show up in this list.")
                    .font(t.body(12.5)).foregroundStyle(t.muted)
                    .padding(12)
            }
            ForEach(entries) { e in
                row(e)
                SuiteRule()
            }
        }
    }

    private func row(_ e: EditHistoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if e.byClaude { ClaudeBadge() }
                    Text(e.label).font(t.body(12.5, e.kind == "tool" ? .regular : .medium))
                        .foregroundStyle(e.undone || e.kind == "tool" ? t.muted : t.ink)
                        .strikethrough(e.undone)
                        .lineLimit(2)
                }
                Text(subtitle(e)).font(t.body(11)).foregroundStyle(t.muted)
            }
            Spacer(minLength: 6)
            if e.canUndo {
                SuiteToolButton(title: "Undo", icon: "arrow.uturn.backward") { Task { await session.undoLive(e) } }
                    .accessibilityLabel("Undo \(e.label)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func subtitle(_ e: EditHistoryEntry) -> String {
        var parts = [e.who(thisDevice: session.device)]
        if e.createdAt > 0 {
            let d = Date(timeIntervalSince1970: e.createdAt / 1000)
            parts.append(d.formatted(date: .omitted, time: .shortened))
        }
        if e.undone { parts.append("undone") }
        return parts.joined(separator: " · ")
    }
}

/// "Claude edited this": a toast at the top of the editor when Claude's change lands.
struct EditSuiteClaudeToast: View {
    @Environment(\.theme) private var t
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(t.body(13)).foregroundStyle(t.ink).lineLimit(2)
            SuiteIconButton(systemName: "xmark", label: "Dismiss", size: 22, action: dismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.line))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude edited this: \(text)")
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            dismiss()
        }
    }
}

/// The last mask, Invert, green-screen key or cut-out Claude changed in the open edit ("Added an inverted oval mask to
/// clip 2 · Undo"), shown as one line in the chat (the Edit Claude panel and the one-Claude panel). Undo reverts exactly
/// that change through the session's history.
@MainActor
@Observable
final class ClaudeEditNotice {
    static let shared = ClaudeEditNotice()
    private(set) var entry: EditHistoryEntry? = nil
    @ObservationIgnored private weak var session: EditSuiteSession? = nil

    func post(_ e: EditHistoryEntry, from s: EditSuiteSession) { entry = e; session = s }
    func clear(if s: EditSuiteSession? = nil) { if s == nil || s === session { entry = nil; session = nil } }
    func undo() async {
        guard let e = entry, let s = session else { return }
        clear()
        await s.undoLive(e)
    }
}

/// "Added an inverted oval mask to clip 2 · Undo".
struct ClaudeEditNoticeLine: View {
    @Environment(\.theme) private var t
    private var notice: ClaudeEditNotice { .shared }

    var body: some View {
        if let e = notice.entry, let text = e.notice {
            HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                Button("Undo") { Task { await notice.undo() } }
                    .buttonStyle(.link)
                    .help("Undo this change of Claude's")
                Spacer(minLength: 0)
                SuiteIconButton(systemName: "xmark", label: "Dismiss", size: 22) { notice.clear() }
            }
            .font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            .padding(.horizontal, Space.s4).padding(.top, Space.s2)
        }
    }
}

/// "Claude wants to run <label> · about $X": the owner's yes starts the paid helper (its cost held as usual).
struct EditSuiteClaudeAsk: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    var session: EditSuiteSession
    var pending: EditPending

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ClaudeBadge()
                Text("Claude is asking").font(t.body(12.5)).foregroundStyle(t.muted)
            }
            Text(pending.prompt).font(t.body(16, .semibold)).foregroundStyle(t.ink).fixedSize(horizontal: false, vertical: true)
            Text("It's paid from the studio balance like any AI helper. Its change lands in the edit when it's done, and you can undo it.")
                .font(t.body(12.5)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button {
                    let p = pending
                    dismiss()
                    Task { await session.answerPending(p, approve: false) }
                } label: {
                    Text("Not now").font(t.body(13.5, .semibold)).foregroundStyle(t.ink)
                        .padding(.horizontal, 14).frame(height: 38)
                        .overlay(Rectangle().strokeBorder(t.line))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button {
                    let p = pending
                    dismiss()
                    Task { await session.answerPending(p, approve: true) }
                } label: {
                    Text("Allow").font(t.body(13, .semibold)).foregroundStyle(t.bg)
                        .padding(.horizontal, 22).frame(height: 38)
                        .background(Rectangle().fill(t.ink))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(t.surface)
    }
}

/// The right panel the top bar's "Claude" toggle shows (owner only): the chat, the session's history with undo, and the
/// pinned rules of the playbook Claude follows while it edits (read-only, with "Open playbook").
struct EditSuiteClaudePanel: View {
    @Environment(\.theme) private var t
    var session: EditSuiteSession
    var openPlaybook: () -> Void = {}
    var close: () -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ClaudeBadge()
                Text(session.liveConnected ? "Shared with Claude" : "Not shared").font(t.body(12.5)).foregroundStyle(t.muted)
                    .lineLimit(1).fitProbe("claude panel status")
                Spacer(minLength: 4)
                SuiteIconButton(systemName: "xmark", label: "Hide Claude", size: 26, action: close)
                    .background { if SnapshotRunner.probing { ComposerBarFrame(key: "edit claude close") } }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "edit claude header") } }
            EditSeg(options: [(0, "Chat"), (1, "History"), (2, "Playbook")], selection: tab) { tab = $0 }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "edit claude tabs") } }
            SuiteRule()
            if tab == 0 {
                // Review mode: the sample thread stands in for a live session (demo mode has none).
                if let id = session.live?.sessionId ?? (SnapshotRunner.probing && SnapshotRunner.state.chatSample ? "es_review" : nil) {
                    // Workstream 2's chat on the owner's Claude Code, about this edit session.
                    // No second header: this panel already has one (badge, sharing state, close).
                    ClaudeEditNoticeLine()
                    ClaudeChatView(contextKind: "edit", contextId: id, title: session.title, showsHeader: false)
                } else {
                    noSession
                }
            } else if tab == 1 {
                ScrollView { EditSuiteHistoryList(session: session) }
            } else {
                EditSuitePlaybookTab(openPlaybook: openPlaybook)
            }
        }
        .background(t.chrome)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "edit claude panel") } }
        .onAppear { if let x = SnapshotRunner.state.claudeTab { tab = x } } // review mode: the Playbook tab's shot
    }

    /// No edit session yet (still opening, or it couldn't be shared): no chat to attach to.
    private var noSession: some View {
        VStack(spacing: 10) {
            Ph("bubble.left.and.text.bubble.right", 22).foregroundStyle(t.muted).accessibilityHidden(true)
            Text(session.isOwner ? "Sharing this edit with Claude…" : "Claude is for the studio owner")
                .font(t.body(13, .semibold)).foregroundStyle(t.ink)
            Text("The chat opens once the edit is shared. If it doesn't, close and reopen the editor.")
                .font(t.body(12)).foregroundStyle(t.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Claude panel's Playbook tab (plans/learning-editor-ui.md): the pinned rules Claude follows while it edits, compact
/// and read-only under small area labels, with "Open playbook" at the bottom.
struct EditSuitePlaybookTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var openPlaybook: () -> Void

    var body: some View {
        let l = store.learn
        let pinned = l.pinned
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Claude reads these before every edit.").scaled(t.scale.caption, t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if l.rules == nil {
                        VStack(alignment: .leading, spacing: Space.s3) {
                            ForEach(0..<3, id: \.self) { i in SkeletonBlock(width: CGFloat([220, 180, 200][i]), height: 10) }
                        }
                        .padding(.top, Space.s2)
                    } else if pinned.isEmpty {
                        Text("No pinned rules yet. Pin the rules Claude should always follow in the playbook.")
                            .scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.s2)
                    } else {
                        ForEach(LearnFilter.grouped(pinned)) { g in
                            Text(LearnText.area(g.area)).scaled(t.scale.micro, t.roles.ink2)
                                .padding(.top, Space.s2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(g.rules) { r in
                                Text(r.text).scaled(t.scale.caption, t.roles.ink).lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(r.text)
                            }
                        }
                    }
                }
                .padding(Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SuiteRule()
            HStack {
                Button(action: openPlaybook) {
                    HStack(spacing: Space.s2) { Ph("book-open-text", 14); Text("Open playbook").fixedSize().fitProbe("Open playbook") }
                }
                .buttonStyle(RButtonStyle(kind: .plain, small: true))
                .accessibilityLabel("Open playbook")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s2)
            .frame(height: 48)
        }
        .task { await store.loadPinnedRules() }
    }
}
