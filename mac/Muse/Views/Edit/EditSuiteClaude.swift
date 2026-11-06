import MuseCore
import SwiftUI

// Claude in the Edit suite (workstream 3, plans/claude-editing.md A and E), owner only: the "Claude" badge, the shared
// history with server undo, the "Claude edited this" toast, the confirmation sheet for paid helpers, and the right panel with
// workstream 2's chat (ClaudeChatView) about this edit session.

/// The small "Claude" badge on Claude's changes.
struct ClaudeBadge: View {
    @Environment(\.theme) private var t
    var body: some View {
        HStack(spacing: 3) {
            Ph("sparkle", 8.5).accessibilityHidden(true)
            Text("Claude").font(t.mono(10.5, .semibold))
        }
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
            Ph("sparkle", 13).foregroundStyle(t.accent).accessibilityHidden(true)
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
                    Text("Allow").font(t.mono(13, .semibold)).tracking(1.2).foregroundStyle(t.bg)
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

/// The right panel the top bar's "Claude" toggle shows (owner only): the chat, and the session's history with undo.
struct EditSuiteClaudePanel: View {
    @Environment(\.theme) private var t
    var session: EditSuiteSession
    var close: () -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ClaudeBadge()
                Text(session.liveConnected ? "Shared with Claude" : "Not shared").font(t.body(12.5)).foregroundStyle(t.muted)
                Spacer()
                SuiteIconButton(systemName: "xmark", label: "Hide Claude", size: 26, action: close)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            EditSeg(options: [(0, "Chat"), (1, "History")], selection: tab) { tab = $0 }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            SuiteRule()
            if tab == 0 {
                if let id = session.live?.sessionId {
                    // Workstream 2's chat on the owner's Claude Code, about this edit session.
                    // No second header: this panel already has one (badge, sharing state, close).
                    ClaudeChatView(contextKind: "edit", contextId: id, title: session.title, showsHeader: false)
                } else {
                    noSession
                }
            } else {
                ScrollView { EditSuiteHistoryList(session: session) }
            }
        }
        .background(t.chrome)
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
