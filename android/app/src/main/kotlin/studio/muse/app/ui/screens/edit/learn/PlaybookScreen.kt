package studio.muse.app.ui.screens.edit.learn

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.muse.app.data.LEARN_AREAS
import studio.muse.app.data.LearnCorrection
import studio.muse.app.data.LearnEvidence
import studio.muse.app.data.LearnLesson
import studio.muse.app.data.LearnRule
import studio.muse.app.data.LearnRuleRequest
import studio.muse.app.data.MuseApi
import studio.muse.app.data.learnAreaLabel
import studio.muse.app.data.relativeTime
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// The Playbook (plans/learning-editor-ui.md §1, the owner-approved mock): the rules Claude follows, in plain words. The
// owner reads, adds, edits, pins and deletes them; Suggestions come from the lessons, History from the corrections.
// Data: /v1/learn/playbook, /lessons, /corrections (owner only).

enum class PlaybookTab(val label: String) { RULES("Rules"), SUGGESTIONS("Suggestions"), HISTORY("History") }

/** The rule editor's draft. [id] null = a new rule. */
data class RuleDraft(
    val id: String? = null,
    val text: String = "",
    val area: String = "other",
    val evidence: List<LearnEvidence> = emptyList(),
    /** "Add a note" opened its field. */
    val noting: Boolean = false,
    val note: String = "",
)

data class PlaybookUi(
    val tab: PlaybookTab = PlaybookTab.RULES,
    val rules: List<LearnRule>? = null,
    val lessons: List<LearnLesson>? = null,
    val corrections: List<LearnCorrection>? = null,
    val error: String? = null,
    val editor: RuleDraft? = null,
    /** The rule a delete confirmation is open for. */
    val deleting: String? = null,
    val busy: Boolean = false,
)

sealed interface PlaybookAction {
    data class Tab(val tab: PlaybookTab) : PlaybookAction
    data object Retry : PlaybookAction
    data object AddRule : PlaybookAction
    data class EditRule(val rule: LearnRule) : PlaybookAction
    data class Pin(val rule: LearnRule) : PlaybookAction
    data class AskDelete(val id: String) : PlaybookAction
    data object ConfirmDelete : PlaybookAction
    data object KeepRule : PlaybookAction
    data class MakeRule(val lesson: LearnLesson) : PlaybookAction
    data class Draft(val draft: RuleDraft) : PlaybookAction
    data object SaveRule : PlaybookAction
    data object CloseEditor : PlaybookAction
    data class OpenCorrection(val c: LearnCorrection) : PlaybookAction
}

/** The most rules a studio keeps (the server's limit). */
const val PLAYBOOK_MAX = 200

/** The Playbook's state and calls. */
class PlaybookModel(private val api: () -> MuseApi, private val toast: (String) -> Unit, private val openTake: (String) -> Unit) {
    var ui by mutableStateOf(PlaybookUi())
        private set

    suspend fun load() {
        ui = ui.copy(error = null)
        runCatching {
            val a = api()
            Triple(a.playbook(), runCatching { a.lessons() }.getOrDefault(emptyList()), runCatching { a.corrections(50) }.getOrDefault(emptyList()))
        }.onSuccess { (r, l, c) -> ui = ui.copy(rules = r, lessons = l, corrections = c) }
            .onFailure { ui = ui.copy(error = "Couldn't load the playbook · check your connection") }
    }

    suspend fun act(a: PlaybookAction) {
        when (a) {
            is PlaybookAction.Tab -> ui = ui.copy(tab = a.tab)
            PlaybookAction.Retry -> load()
            PlaybookAction.AddRule -> ui = ui.copy(editor = RuleDraft())
            is PlaybookAction.EditRule -> ui = ui.copy(editor = RuleDraft(a.rule.id, a.rule.text, a.rule.area, a.rule.evidence))
            is PlaybookAction.MakeRule -> ui = ui.copy(editor = RuleDraft(area = a.lesson.area,
                evidence = a.lesson.ids.mapIndexed { i, id -> LearnEvidence("correction", id.toString(), a.lesson.examples.getOrNull(i) ?: a.lesson.examples.firstOrNull(), a.lesson.last) }))
            is PlaybookAction.Draft -> ui = ui.copy(editor = a.draft)
            PlaybookAction.CloseEditor -> ui = ui.copy(editor = null)
            is PlaybookAction.Pin -> call { api().patchRule(a.rule.id, LearnRuleRequest(pinned = !a.rule.pinned)) }
            is PlaybookAction.AskDelete -> ui = ui.copy(deleting = a.id)
            PlaybookAction.KeepRule -> ui = ui.copy(deleting = null)
            PlaybookAction.ConfirmDelete -> {
                val id = ui.deleting ?: return
                ui = ui.copy(deleting = null, editor = null)
                call { api().deleteRule(id) }
            }
            PlaybookAction.SaveRule -> {
                val d = ui.editor ?: return
                val text = d.text.trim()
                if (text.isEmpty()) return toast("Say what Claude should do")
                val evidence = d.evidence + listOfNotNull(d.note.trim().takeIf { it.isNotEmpty() }?.let { LearnEvidence("note", note = it, at = System.currentTimeMillis()) })
                val req = LearnRuleRequest(text = text.take(300), area = d.area, evidence = evidence)
                ui = ui.copy(busy = true)
                val ok = call { if (d.id == null) api().addRule(req) else api().patchRule(d.id, req) }
                ui = ui.copy(busy = false, editor = if (ok) null else ui.editor)
            }
            is PlaybookAction.OpenCorrection -> a.c.takeId?.let(openTake)
        }
    }

    /** Runs a change and reloads the rules; a failure is a toast in words. */
    private suspend fun call(block: suspend () -> Unit): Boolean = runCatching { block() }
        .onSuccess { runCatching { api().playbook() }.onSuccess { ui = ui.copy(rules = it) } }
        .onFailure { toast(it.message?.takeIf { m -> m.isNotBlank() } ?: "Couldn't save · try again") }.isSuccess
}

@Composable
fun PlaybookScreen(onBack: () -> Unit, onOpenTake: (String) -> Unit) {
    val c = LocalContainer.current
    val scope = rememberCoroutineScope()
    val model = remember { PlaybookModel({ c.repo.api }, { c.repo.toast(it) }, onOpenTake) }
    LaunchedEffect(Unit) { model.load() }
    val ui = model.ui
    BackHandler {
        when {
            ui.deleting != null -> scope.launch { model.act(PlaybookAction.KeepRule) }
            ui.editor != null -> scope.launch { model.act(PlaybookAction.CloseEditor) }
            else -> onBack()
        }
    }
    PlaybookContent(ui, onBack) { a -> scope.launch { model.act(a) } }
}

private val AREA_ORDER = LEARN_AREAS

/** The screen as a function of [ui] (screenshots render it). */
@Composable
fun PlaybookContent(ui: PlaybookUi, onBack: () -> Unit, act: (PlaybookAction) -> Unit) {
    val m = muse
    val full = (ui.rules?.size ?: 0) >= PLAYBOOK_MAX
    ScreenBox(statusPad = true) {
        BoxWithConstraints(Modifier.fillMaxSize().background(m.roles.canvas)) {
            val wide = maxWidth >= 720.dp
            val hasRules = !ui.rules.isNullOrEmpty()
            Column(Modifier.fillMaxSize()) {
                LearnTopBar(onBack) { if (wide && hasRules) LearnPrimary("Add rule", Modifier.padding(end = 16.dp), enabled = !full) { act(PlaybookAction.AddRule) } }
                Column(
                    Modifier.weight(1f).align(Alignment.CenterHorizontally).let { if (wide) it.widthIn(max = 760.dp) else it }.fillMaxWidth()
                        .verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 32.dp else 16.dp),
                ) {
                    T("Playbook", m.scale.display, m.roles.ink)
                    T("Claude reads these before every edit.", m.scale.caption, m.roles.ink2, Modifier.padding(top = 4.dp))
                    LearnSegmented(PlaybookTab.entries.map { it.label }, ui.tab.ordinal, Modifier.padding(top = 20.dp).let { if (wide) it.widthIn(max = 420.dp) else it }.fillMaxWidth()) {
                        act(PlaybookAction.Tab(PlaybookTab.entries[it]))
                    }
                    Spacer(Modifier.height(16.dp))
                    when {
                        ui.error != null && ui.rules == null -> LearnError(ui.error) { act(PlaybookAction.Retry) }
                        ui.rules == null -> SkeletonRows()
                        ui.tab == PlaybookTab.RULES -> if (hasRules) RulesList(ui.rules, act) else Empty(
                            "No rules yet. Claude suggests some from the changes you make to its edits, and you can add your own.", "Add rule") { act(PlaybookAction.AddRule) }
                        ui.tab == PlaybookTab.SUGGESTIONS -> if (ui.lessons.isNullOrEmpty())
                            T("No suggestions yet. They appear after you change or undo a few of Claude's edits.", m.scale.body, m.roles.ink2, Modifier.padding(top = 16.dp))
                        else SuggestionsList(ui.lessons, act)
                        else -> if (ui.corrections.isNullOrEmpty()) T("Nothing yet. Your changes to Claude's edits show here.", m.scale.body, m.roles.ink2, Modifier.padding(top = 16.dp))
                        else HistoryList(ui.corrections, act)
                    }
                    if (full && ui.tab == PlaybookTab.RULES) T("The playbook holds 200 rules · delete some first", m.scale.caption, m.roles.ink2, Modifier.padding(top = 16.dp))
                    Spacer(Modifier.height(96.dp))
                }
                // Phone: the one primary action in the bottom bar.
                if (!wide && hasRules && ui.tab == PlaybookTab.RULES) {
                    LearnHairline()
                    Box(Modifier.fillMaxWidth().background(m.roles.canvas).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp)) {
                        LearnPrimary("Add rule", Modifier.fillMaxWidth(), enabled = !full) { act(PlaybookAction.AddRule) }
                    }
                }
            }
            ui.editor?.let { RuleEditor(it, wide, ui.busy, act) }
            ui.deleting?.let { LearnConfirm("Delete this rule?", null, "Delete rule", { act(PlaybookAction.ConfirmDelete) }, { act(PlaybookAction.KeepRule) }) }
        }
    }
}

@Composable
private fun Empty(text: String, action: String, onClick: () -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().padding(top = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        T(text, m.scale.body, m.roles.ink2)
        LearnPrimary(action, onClick = onClick)
    }
}

@Composable
private fun RulesList(rules: List<LearnRule>, act: (PlaybookAction) -> Unit) {
    val m = muse
    val groups = rules.groupBy { if (it.area in AREA_ORDER) it.area else "other" }
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) { // groups by space, not boxes
        AREA_ORDER.filter { it in groups }.forEach { area ->
            Column {
                T(learnAreaLabel(area), m.scale.heading, m.roles.ink, Modifier.padding(bottom = 4.dp))
                groups.getValue(area).sortedByDescending { it.pinned }.forEach { r -> RuleRow(r, act) }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RuleRow(r: LearnRule, act: (PlaybookAction) -> Unit) {
    val m = muse
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp)
            // Tap opens the editor; a long-press offers Delete. No row menus.
            .combinedClickable(onClickLabel = "Edit rule", onLongClickLabel = "Delete rule", onLongClick = { act(PlaybookAction.AskDelete(r.id)) }) { act(PlaybookAction.EditRule(r)) }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(r.text, m.scale.body, m.roles.ink, maxLines = 3)
            T(r.byline, m.scale.caption, m.roles.ink2, maxLines = 1)
        }
        Box(Modifier.size(48.dp).press { act(PlaybookAction.Pin(r)) }.semantics { contentDescription = if (r.pinned) "Unpin rule" else "Pin rule"; role = Role.Switch },
            contentAlignment = Alignment.Center) { EIc("push-pin", 20.dp, if (r.pinned) m.roles.accent else m.roles.ink2) }
    }
}

@Composable
private fun SuggestionsList(lessons: List<LearnLesson>, act: (PlaybookAction) -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        lessons.forEach { l ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(l.sentence, m.scale.body, m.roles.ink)
                // The latest example, in the correction's own words, and when.
                l.examples.firstOrNull()?.let { T(listOf(it, relativeTime(l.last)).joinToString(" · "), m.scale.caption, m.roles.ink2, maxLines = 2) }
                LearnLink("Make a rule") { act(PlaybookAction.MakeRule(l)) }
            }
        }
    }
}

@Composable
private fun HistoryList(corrections: List<LearnCorrection>, act: (PlaybookAction) -> Unit) {
    val m = muse
    Column {
        corrections.forEach { c ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp).let { if (c.takeId != null) it.press { act(PlaybookAction.OpenCorrection(c)) } else it }.padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(c.what, m.scale.body, m.roles.ink, maxLines = 2)
                    T(learnAreaLabel(c.area), m.scale.caption, m.roles.ink2, maxLines = 1)
                }
                T(relativeTime(c.createdAt), m.scale.caption, m.roles.ink2, maxLines = 1)
            }
        }
    }
}

/** The rule editor: a sheet that floats on the phone (the only shadow here); a centred panel on a tablet. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RuleEditor(d: RuleDraft, wide: Boolean, busy: Boolean, act: (PlaybookAction) -> Unit) {
    val m = muse
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press { act(PlaybookAction.CloseEditor) }, contentAlignment = if (wide) Alignment.Center else Alignment.BottomCenter) {
        val shape = if (wide) RoundedCornerShape(m.radii.container) else RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)
        Column(
            Modifier.let { if (wide) it.widthIn(max = 560.dp).padding(32.dp) else it }.fillMaxWidth().imePadding()
                .let { if (wide) it else it.shadow(16.dp, shape) }.clip(shape).background(m.roles.raised).press { }
                .verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 16.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (!wide) Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Box(Modifier.size(40.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(m.roles.hairline)) }
            T(if (d.id == null) "Add rule" else "Edit rule", m.scale.title, m.roles.ink, Modifier.padding(top = if (wide) 12.dp else 0.dp))
            Box(Modifier.fillMaxWidth().heightIn(min = 96.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(12.dp)) {
                BasicTextField(
                    d.text, { act(PlaybookAction.Draft(d.copy(text = it.take(300)))) }, Modifier.fillMaxWidth().semantics { contentDescription = "Rule" },
                    textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                    decorationBox = { inner -> Box { if (d.text.isEmpty()) T("Say what Claude should do instead", m.scale.body, m.roles.ink2); inner() } },
                )
            }
            if (d.text.length >= 250) T("${d.text.length} / 300", m.scale.caption.copy(fontFeatureSettings = "tnum"), m.roles.ink2)
            T("Area", m.scale.label, m.roles.ink)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                LEARN_AREAS.forEach { a -> LearnChip(learnAreaLabel(a), on = a == d.area) { act(PlaybookAction.Draft(d.copy(area = a))) } }
            }
            if (d.evidence.isNotEmpty()) {
                T("Evidence", m.scale.label, m.roles.ink)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    d.evidence.take(6).forEach { e ->
                        val kind = when (e.kind) { "correction" -> "Correction"; "post" -> "Post"; "recipe" -> "Recipe"; else -> "Note" }
                        T(listOfNotNull(kind, e.note, e.at?.let(::relativeTime)).joinToString(" · "), m.scale.caption, m.roles.ink2, maxLines = 2)
                    }
                }
            }
            if (d.noting) Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(12.dp)) {
                BasicTextField(d.note, { act(PlaybookAction.Draft(d.copy(note = it.take(200)))) }, Modifier.fillMaxWidth().semantics { contentDescription = "Note" },
                    textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                    decorationBox = { inner -> Box { if (d.note.isEmpty()) T("Why this rule", m.scale.body, m.roles.ink2); inner() } })
            } else LearnLink("Add a note") { act(PlaybookAction.Draft(d.copy(noting = true))) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                LearnPrimary("Save rule", Modifier.weight(1f), enabled = !busy && d.text.isNotBlank()) { act(PlaybookAction.SaveRule) }
                LearnQuiet("Cancel") { act(PlaybookAction.CloseEditor) }
            }
            if (d.id != null) LearnLink("Delete rule", m.roles.danger, Modifier.padding(top = 8.dp)) { act(PlaybookAction.AskDelete(d.id)) }
        }
    }
}
