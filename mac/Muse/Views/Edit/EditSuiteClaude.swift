import MuseCore
import SwiftUI

// Claude in the Edit suite (workstream 3, plans/claude-editing.md A and E), owner only: the "Claude" badge, the shared
// history with server undo, the "Claude edited this" toast, the confirmation sheet for paid helpers, and the right panel's
// chat host (a placeholder until workstream 2's chat view is merged).

/// The small "Claude" badge on Claude's changes.
struct ClaudeBadge: View {
    @Environment(\.theme) private var t
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkle").font(.system(size: 8.5, weight: .bold)).accessibilityHidden(true)
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
            Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.accent).accessibilityHidden(true)
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

/// The right panel's chat (E). Workstream 2 builds the shared chat view, `ClaudeChatView(contextKind:contextId:title:)`; until
/// it is merged this placeholder shows Claude's recent changes to this edit. Swapping it is one line in `EditSuiteClaudePanel`.
struct ClaudeChatHost: View {
    @Environment(\.theme) private var t
    @Environment(EditSuiteSession.self) private var session: EditSuiteSession?
    var contextKind: String
    var contextId: String
    var title: String

    var body: some View {
        let mine = (session?.liveHistory ?? []).filter(\.byClaude)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SuiteLabel("Claude's changes", trailing: title)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    if mine.isEmpty {
                        Text("Claude hasn't changed this edit yet. Add MUSE to Claude, open this take there, and its changes show up here live.")
                            .font(t.body(12.5)).foregroundStyle(t.muted)
                            .padding(.horizontal, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(mine.prefix(12)) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: e.kind == "tool" ? "eye" : "wand.and.stars").font(.system(size: 11)).foregroundStyle(t.muted)
                                .accessibilityHidden(true)
                            Text(e.label).font(t.body(12.5)).foregroundStyle(e.undone ? t.muted : t.ink).strikethrough(e.undone).lineLimit(3)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
            SuiteRule()
            Text("Chat with Claude arrives with the next update")
                .font(t.body(12.5)).foregroundStyle(t.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude for \(contextKind) \(contextId)")
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
                    ClaudeChatHost(contextKind: "edit", contextId: id, title: session.title)
                } else {
                    Text("Opening the shared edit…").font(t.body(12.5)).foregroundStyle(t.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView { EditSuiteHistoryList(session: session) }
            }
        }
        .background(t.chrome)
    }
}
