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
import kotlinx.coroutines.launch
import androidx.compose.runtime.collectAsState
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
import studio.muse.app.ui.theme.scale
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.radii
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width

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

/** Tablet / wide: workstream 2's chat as the right panel, for this edit's session, with the Playbook segment. */
@Composable
fun EditClaudePanel(ui: EditSuiteUi, modifier: Modifier = Modifier) {
    val s = ui.session ?: return
    val m = muse
    ChatAndPlaybook(s.id, ui.title.ifBlank { "Claude" }, modifier.width(380.dp).fillMaxHeight()
        .drawBehind { drawLine(m.roles.hairline, androidx.compose.ui.geometry.Offset(0f, 0f), androidx.compose.ui.geometry.Offset(0f, size.height), 1f) })
}

/** Phone: workstream 2's chat sheet for this edit's session, with the Playbook segment (plans/learning-editor-ui.md). */
@Composable
fun EditClaudeSheet(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val s = ui.session ?: return
    if (!s.chatOpen) return
    studio.muse.app.ui.screens.claude.ClaudeSheetFrame(onDismiss = { act(EditAction.ClaudePanel(false)) }) {
        ChatAndPlaybook(s.id, ui.title.ifBlank { "Claude" }, Modifier.fillMaxSize())
    }
}

/** "Open playbook" from inside the editor: the Edit screen leaves the editor for the Playbook (null: not offered). */
val LocalOpenPlaybook = androidx.compose.runtime.staticCompositionLocalOf<(() -> Unit)?> { null }

/**
 * Chat | Playbook: Claude's chat for the edit, or a read-only list of the pinned rules Claude follows while it edits,
 * with "Open playbook" (plans/learning-editor-ui.md "Inside the editor"). The chat stays composed under the segment.
 */
@Composable
private fun ChatAndPlaybook(sessionId: String, title: String, modifier: Modifier) {
    var tab by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableIntStateOf(0) }
    val store = studio.muse.app.ui.screens.claude.rememberClaudeChatStore("edit", sessionId)
    Column(modifier) {
        OtherEditApprovals(sessionId)
        studio.muse.app.ui.screens.edit.learn.LearnSegmented(listOf("Chat", "Playbook"), tab, Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth()) { tab = it }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (tab == 0) studio.muse.app.ui.screens.claude.ClaudeChat(store, title, Modifier.fillMaxSize())
            else PinnedRules()
        }
    }
}

@Composable
private fun PinnedRules() {
    val m = muse
    val c = studio.muse.app.ui.LocalContainer.current
    val open = LocalOpenPlaybook.current
    var rules by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<List<studio.muse.app.data.LearnRule>?>(null) }
    var failed by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        runCatching { c.repo.api.playbook() }.onSuccess { rules = it.filter { r -> r.pinned } }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it; failed = true }
    }
    Column(Modifier.fillMaxSize().verticalScroll(androidx.compose.foundation.rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        T("Claude follows these pinned rules while it edits.", m.scale.caption, m.roles.ink2)
        when {
            failed -> T("The playbook couldn't load.", m.scale.body, m.roles.ink2)
            rules == null -> studio.muse.app.ui.screens.edit.learn.SkeletonRows(3)
            rules!!.isEmpty() -> T("No pinned rules yet.", m.scale.body, m.roles.ink2)
            else -> rules!!.forEach { r ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(r.text, m.scale.body, m.roles.ink)
                    T(r.byline, m.scale.caption, m.roles.ink2, maxLines = 1)
                }
            }
        }
        if (open != null) studio.muse.app.ui.screens.edit.learn.LearnLink("Open playbook", onClick = open)
    }
}

/** Kept for layout: a full-size scrim that closes what it covers. */
@Composable
internal fun Scrim(onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0x40141210)).press(onClick = onClose))
}


/**
 * Paid helpers Claude asked for on the owner's OTHER edits (owner issue ci_e546642a4026, 2026-11-12): listed at the top
 * of this edit's Claude sheet, each naming its edit, and answered on that edit's own session without switching edits.
 * This edit's own ask has its own sheet ("Claude asks"). Owner only, like the server's events.
 */
@Composable
internal fun OtherEditApprovals(openSessionId: String) {
    val m = muse
    val c = studio.muse.app.ui.LocalContainer.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var list by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(studio.muse.core.edit.EditApprovalList()) }
    var busy by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(emptySet<String>()) }
    val studioState by c.repo.state.collectAsState()
    suspend fun reload() { loadEditApprovals(c.repo.api)?.let { list = it } }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (!c.repo.ownerNow()) return@LaunchedEffect
        reload()
        c.repo.live.collect { ev ->
            if (ev.type != "edit" || ev.op != "pending") return@collect
            val sid = ev.sessionId ?: return@collect
            val p = ev.pending ?: return@collect
            val known = list.items.any { it.sessionId == sid }
            list = editApprovalEvent(list, ev) ?: return@collect
            if (p.status == "waiting" && !known) reload()
        }
    }
    val shown = list.except(openSessionId)
    if (shown.isEmpty()) return
    fun nameOf(a: studio.muse.core.edit.EditApproval) =
        studio.muse.core.edit.EditApprovalList.editName(a.takeId, studioState.takes.firstOrNull { it.id == a.takeId }?.title)
    fun answer(a: studio.muse.core.edit.EditApproval, approve: Boolean) {
        if (a.id in busy) return
        busy = busy + a.id
        scope.launch {
            val (gone, said) = answerEditApproval(c.repo.api, a, approve, nameOf(a))
            if (gone) list = list.remove(a.id)
            c.repo.toast(said)
            busy = busy - a.id
        }
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        shown.forEach { a ->
            val name = nameOf(a)
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).border(1.dp, m.roles.hairline, RoundedCornerShape(m.radii.container))
                .padding(12.dp).semantics { contentDescription = "Claude asks to run ${a.label} in $name" },
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Claude needs your go-ahead", m.scale.label, m.roles.ink)
                T("Run ${a.label} in “$name”", m.scale.caption, m.roles.ink2)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SuiteButton("Not now", { answer(a, false) }, Modifier.weight(1f), enabled = a.id !in busy)
                    SuiteButton(a.allowLabel, { answer(a, true) }, Modifier.weight(1f), primary = true, enabled = a.id !in busy)
                }
            }
        }
    }
}

/** Every open edit's waiting paid helpers (GET /v1/edit-sessions); null when they couldn't load (keep what is shown). */
internal suspend fun loadEditApprovals(api: studio.muse.app.data.MuseApi): studio.muse.core.edit.EditApprovalList? =
    runCatching { api.recentEditSessions(50) }
        .onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
        .getOrNull()
        ?.let { all -> studio.muse.core.edit.EditApprovalList.of(all.flatMap { d -> d.pending.map { p ->
            studio.muse.core.edit.SessionPending(d.id, d.takeId, p.id, p.label, p.estimateUsd, p.createdAt, p.status) } }) }

/** A live `edit` `pending` event applied to the list (null: not one). */
internal fun editApprovalEvent(list: studio.muse.core.edit.EditApprovalList, ev: studio.muse.app.data.ApiEvent): studio.muse.core.edit.EditApprovalList? {
    if (ev.type != "edit" || ev.op != "pending") return null
    val sid = ev.sessionId ?: return null
    val p = ev.pending ?: return null
    return list.apply(studio.muse.core.edit.SessionPending(sid, "", p.id, p.label, p.estimateUsd, p.createdAt, p.status), takeIdKnown = false)
}

/** Allow / Not now on another edit's helper, on that edit's own session. → (off the list?, what to say). */
internal suspend fun answerEditApproval(api: studio.muse.app.data.MuseApi, a: studio.muse.core.edit.EditApproval, approve: Boolean, editName: String): Pair<Boolean, String> =
    try {
        api.answerEditPending(a.sessionId, a.pendingId, approve)
        true to (if (approve) "${a.label} started in “$editName”. Claude's change lands when it's done." else "Told Claude not now")
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: studio.muse.app.data.ApiException) {
        if (e.code == "not_found") true to "That was already answered" else false to "Couldn't answer Claude · try again"
    } catch (e: Exception) {
        false to "Couldn't answer Claude · try again"
    }
