package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.data.EditHistoryEntry
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.theme.muse

/*
 * Edit sessions (workstream 3, plans/claude-editing.md A and E): what the owner sees of Claude in the Edit suite — the
 * "Claude" badge in the history, the "Claude edited this" note, the confirmation sheet for paid helpers Claude asks
 * for, and workstream 2's chat (a sheet on the phone, a right panel on a tablet) for the edit's session.
 */

/** The small "Claude" badge on Claude's history entries. */
@Composable
fun ClaudeBadge(modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(999.dp)
    Row(
        modifier.height(20.dp).clip(shape).background(m.t.accent.copy(alpha = .16f)).let { if (m.isD) it.border(1.5.dp, Ink, shape) else it }.padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        EIc("sparkle", 11.dp, m.t.accent)
        T("Claude", m.type.pill.copy(fontSize = 10.5.sp), m.t.accent, maxLines = 1)
    }
}

/** One history entry: label, who, and Undo (through the server) unless it's undone or an undo itself. */
@Composable
fun HistoryRow(e: EditHistoryEntry, onUndo: ((Long) -> Unit)?) {
    val m = muse
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (e.byClaude) ClaudeBadge()
                T(e.label.ifBlank { "Edit" }, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Medium), if (e.undone) m.t.muted else m.t.ink, Modifier.weight(1f, fill = false), maxLines = 2)
            }
            T(listOfNotNull(whoOf(e), if (e.undone) "undone" else null).joinToString(" · "), m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
        }
        if (onUndo != null && !e.undone && e.kind != "undo" && e.kind != "tool") {
            Box(Modifier.size(56.dp, 40.dp).press { onUndo(e.id) }.semantics { contentDescription = "Undo ${e.label}" }, contentAlignment = Alignment.Center) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    EIc("undo", 14.dp, m.t.ink)
                    T("Undo", m.type.body.copy(fontSize = 12.sp, fontWeight = FontWeight.Medium), m.t.ink, maxLines = 1)
                }
            }
        }
    }
}

private fun whoOf(e: EditHistoryEntry): String = when {
    e.byClaude -> if (e.kind == "tool") "Claude looked" else "Claude"
    e.author.startsWith("app:") -> "You"
    else -> "You"
}

/** Panel.HISTORY: the session's history, newest first (Claude's badged; Undo goes through the server). */
@Composable
fun ColumnScope.HistoryBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val s = ui.session
    val list = s?.history.orEmpty().filter { it.kind != "tool" }
    if (list.isEmpty()) T("No changes yet", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    list.forEach { e -> HistoryRow(e) { act(EditAction.UndoEntry(it)) } }
}

/** "Claude · Trimmed 0:00.5–0:06.0": a small note over the preview when one of Claude's changes lands. */
@Composable
fun ClaudeNote(text: String, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    Row(
        modifier.clip(shape).background(m.t.ink).let { if (m.isD) it.border(2.dp, Ink, shape) else it }.press(onClick = onDismiss)
            .padding(horizontal = 14.dp, vertical = 9.dp).semantics { contentDescription = text },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        EIc("sparkle", 14.dp, m.t.bg)
        T(text, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.Medium), m.t.bg, maxLines = 1)
    }
}

/** A paid helper Claude asked for: "Claude wants to run <label> · about $X" with Allow / Not now. */
@Composable
fun PendingSheet(p: studio.muse.app.data.EditPending, act: (EditAction) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    SheetFrame("Claude asks", { act(EditAction.AnswerPending(p.id, false)) }, modifier, scroll = false) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ClaudeBadge()
            T("wants to spend from your balance", m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
        T("Claude wants to run ${p.label} · ${aboutUsd(p.estimateUsd)}", m.type.h3.copy(fontSize = 18.sp), m.t.ink)
        T("Nothing is charged unless you allow it. The result lands on this edit as Claude's change, and Undo takes it back.", m.type.body.copy(fontSize = 13.sp), m.t.muted)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SuiteButton("Not now", { act(EditAction.AnswerPending(p.id, false)) }, Modifier.weight(1f))
            SuiteButton("Allow", { act(EditAction.AnswerPending(p.id, true)) }, Modifier.weight(1f), icon = "check", primary = true)
        }
    }
}

/**
 * Opening the shared edit found changes on this device the session doesn't have, and the session moved on. Nothing is
 * dropped silently: keep them (sent on top of the latest) or use the latest (this device's changes are discarded).
 */
@Composable
fun ConflictSheet(act: (EditAction) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    SheetFrame("Two versions of this edit", { act(EditAction.ResolveConflict(true)) }, modifier, scroll = false) {
        T("This phone has changes that aren't in the shared edit yet, and the shared edit changed since (on another device or by Claude).",
            m.type.body.copy(fontSize = 13.5.sp), m.t.ink)
        T("Keep this device's changes puts them on top of the latest. Use the latest discards them.", m.type.body.copy(fontSize = 13.sp), m.t.muted)
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SuiteButton("Keep this device's changes", { act(EditAction.ResolveConflict(true)) }, Modifier.fillMaxWidth(), icon = "check", primary = true)
            SuiteButton("Use the latest", { act(EditAction.ResolveConflict(false)) }, Modifier.fillMaxWidth(), icon = "refresh")
        }
    }
}

/**
 * The "Claude" button in the editor's top bar (owner only): workstream 2's 48 dp button. Before the edit's session is
 * there (offline, still connecting) it shows dimmed and says why instead of opening.
 */
@Composable
fun EditClaudeButton(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val s = ui.session
    studio.muse.app.ui.screens.claude.ClaudeButton(
        onClick = { act(EditAction.ClaudePanel(!(s?.chatOpen ?: false))) },
        modifier = if (s == null) Modifier.alpha(.45f) else Modifier,
    )
}

/** Tablet / wide: workstream 2's chat as the right panel, for this edit's session (the chat's one panel call site). */
@Composable
fun EditClaudePanel(ui: EditSuiteUi, modifier: Modifier = Modifier) {
    val s = ui.session ?: return
    studio.muse.app.ui.screens.claude.ClaudeChatPanel(contextKind = "edit", contextId = s.id, title = ui.title.ifBlank { "Claude" }, width = 380.dp, modifier = modifier)
}

/** Phone: workstream 2's chat sheet for this edit's session (the chat's one sheet call site). */
@Composable
fun EditClaudeSheet(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val s = ui.session ?: return
    studio.muse.app.ui.screens.claude.ClaudeChatSheet(open = s.chatOpen, onDismiss = { act(EditAction.ClaudePanel(false)) },
        contextKind = "edit", contextId = s.id, title = ui.title.ifBlank { "Claude" })
}

/** Kept for layout: a full-size scrim that closes what it covers. */
@Composable
internal fun Scrim(onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0x40141210)).press(onClick = onClose))
}

