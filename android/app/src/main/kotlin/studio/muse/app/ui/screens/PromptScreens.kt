package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.PromptEntry
import studio.muse.app.data.PromptLibrary
import studio.muse.app.data.PromptPreview
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/**
 * Owner Settings → Prompts (plans/api.md "Shoot references and the prompt library" §3): every prompt the server sends
 * to a model, grouped, each editable with its placeholders, a live preview and Reset to default. Members never get here
 * (the server answers owner_only too).
 */
class PromptsViewModel(private val c: AppContainer) : ViewModel() {
    val library = MutableStateFlow<PromptLibrary?>(null)
    val error = MutableStateFlow<String?>(null)

    init {
        // Another owner device saved or reset one: keep the list in step.
        viewModelScope.launch { c.repo.live.collect { ev -> if (ev.type == "prompts") ev.prompt?.let(::put) } }
    }
    fun load() = viewModelScope.launch { val (v, e) = c.repo.prompts(); v?.let { library.value = it }; error.value = e }
    fun put(e: PromptEntry) = library.update { l -> l?.copy(prompts = l.prompts.map { if (it.key == e.key) e else it }) }
    fun entry(key: String) = library.value?.prompts?.firstOrNull { it.key == key }
}

/** One prompt's editor: the draft text, its live preview (debounced) and the server's validation message. */
class PromptEditViewModel(private val c: AppContainer, val key: String) : ViewModel() {
    val entry = MutableStateFlow<PromptEntry?>(null)
    val groupLabel = MutableStateFlow<String?>(null)
    val draft = MutableStateFlow<String?>(null)
    val preview = MutableStateFlow<PromptPreview?>(null)
    /** prompt_invalid while typing or on Save (shown as the server words it), or why the prompt couldn't load. */
    val problem = MutableStateFlow<String?>(null)
    val busy = MutableStateFlow(false)

    init {
        viewModelScope.launch {
            val (lib, e) = c.repo.prompts()
            val found = lib?.prompts?.firstOrNull { it.key == key }
            entry.value = found
            groupLabel.value = lib?.groups?.firstOrNull { it.id == found?.group }?.label?.let { studio.muse.app.data.takeDisplayTitle(it) }
            problem.value = e ?: if (lib != null && found == null) "That prompt isn't in this studio's library." else null
            if (draft.value == null) draft.value = found?.current
            // The saved text's preview at once, then ~350 ms after the last keystroke.
            var first = true
            draft.collectLatest { t ->
                if (t == null) return@collectLatest
                if (!first) delay(350)
                first = false
                val (p, invalid) = c.repo.previewPrompt(key, t)
                if (p != null) preview.value = p
                problem.value = invalid
            }
        }
        // Another owner device saved or reset this prompt: an untouched draft follows it, one being edited is kept.
        viewModelScope.launch {
            c.repo.live.collect { ev ->
                val p = ev.prompt?.takeIf { ev.type == "prompts" && it.key == key } ?: return@collect
                if (draft.value == entry.value?.current) draft.value = p.current
                entry.value = p
            }
        }
    }
    fun type(t: String) { draft.value = t }
    /** Adds {name} at the end, with a space before it when needed. */
    fun insert(name: String) {
        val t = draft.value.orEmpty()
        draft.value = t + (if (t.isEmpty() || t.endsWith(" ") || t.endsWith("\n")) "" else " ") + "{$name}"
    }
    fun undo() { draft.value = entry.value?.current }
    fun save() = viewModelScope.launch {
        val t = draft.value ?: return@launch
        if (busy.value) return@launch
        busy.value = true
        val (e, err) = c.repo.savePrompt(key, t)
        busy.value = false
        if (e != null) {
            entry.value = e; draft.value = e.current; problem.value = null
            c.repo.toast(if (e.overridden) "Saved · used for every new photo and video" else "Saved · back on the default")
        } else problem.value = err
    }
    fun reset() = viewModelScope.launch {
        val (e, err) = c.repo.resetPrompt(key)
        if (e != null) { entry.value = e; draft.value = e.current; problem.value = null; c.repo.toast("Back on the default") } else err?.let { c.repo.toast(it) }
    }
}

@Composable
fun PromptsScreen() {
    val c = LocalContainer.current
    val vm: PromptsViewModel = viewModel { PromptsViewModel(c) }
    LaunchedEffect(Unit) { vm.load() }
    val lib by vm.library.collectAsState()
    val err by vm.error.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Prompts", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
                // Prompt scripts (workstream 4): Blocks (the texts) | Scripts (which block is used when).
                val tab by c.drafts.promptsTab.collectAsState()
                Segmented(listOf("blocks" to "Blocks", "scripts" to "Scripts"), tab, { c.drafts.promptsTab.value = it })
                if (tab == "scripts") { PromptScriptsList(); return@Column }
                Body("Every prompt MUSE sends when it makes a photo, an outfit set, a sheet angle, a LoRA set or a video. A saved edit is used for every new render in your studio, by you and your members. Work already running keeps its prompt.")
                val l = lib
                if (l == null && err != null) ErrorState("Can't load the prompts", err ?: "", onAction = { vm.load() })
                else err?.let { Notice(it, tone = NoticeTone.DANGER) }
                if (l == null && err == null) repeat(3) { SkeletonLines(3) }
                l?.groups?.forEach { g ->
                    val items = l.prompts.filter { it.group == g.id }
                    if (items.isEmpty()) return@forEach
                    Column {
                        Heading(studio.muse.app.data.takeDisplayTitle(g.label)) { Caption("${items.count { it.overridden }.takeIf { it > 0 }?.let { "$it edited of " } ?: ""}${items.size}") }
                        items.forEach { p ->
                            RowItem(p.title, p.current.replace('\n', ' ').take(90).ifBlank { "Empty, left out" }, onClick = { nav.go(Routes.prompt(p.key)) }) {
                                if (p.overridden) RowValue("Edited", m.roles.caution)
                                Chevron()
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun PromptEditScreen(key: String) {
    val c = LocalContainer.current
    val vm: PromptEditViewModel = viewModel(key = "prompt_$key") { PromptEditViewModel(c, key) }
    val entry by vm.entry.collectAsState()
    val group by vm.groupLabel.collectAsState()
    val draft by vm.draft.collectAsState()
    val preview by vm.preview.collectAsState()
    val problem by vm.problem.collectAsState()
    val busy by vm.busy.collectAsState()
    val nav = LocalNav.current
    var confirmReset by remember { mutableStateOf(false) }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar(entry?.title ?: "Prompt", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
                val e = entry ?: run { problem?.let { Notice(it, tone = NoticeTone.DANGER) } ?: SkeletonLines(4); return@Column }
                val text = draft ?: e.current
                PromptEditorBody(e, group, text, preview, problem, vm::type, vm::insert)
                if (text != e.current) SecondaryButton("Undo changes", { vm.undo() }, Modifier.fillMaxWidth(), icon = "retry")
                if (e.overridden) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    if (confirmReset) {
                        T("Reset “${e.title}” to its default?", muse.scale.heading, muse.roles.ink)
                        Body("Every new photo and video in your studio goes back to MUSE's default text. Your version is not kept.")
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                            SecondaryButton("Reset to default", { confirmReset = false; vm.reset() }, Modifier.weight(1f))
                            SecondaryButton("Keep my version", { confirmReset = false }, Modifier.weight(1f))
                        }
                    } else SecondaryButton("Reset to default", { confirmReset = true }, Modifier.fillMaxWidth(), icon = "retry")
                    e.updatedBy?.let { by -> Caption("Last saved by $by${e.updatedAt?.let { ", " + savedAt(it) } ?: ""}") }
                }
            }
        }
        ActionDock {
            val changed = draft != null && draft != entry?.current
            val blocked = !changed || busy || problem != null
            PrimaryButton(if (busy) "Saving…" else if (changed) "Save prompt" else "Saved", { if (!blocked) vm.save() }, Modifier.weight(1f), off = blocked && !busy, busy = busy)
        }
    }
}

private fun savedAt(ms: Long): String = java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(ms))

/** The editor itself: text, placeholder chips (tap adds; * = needed), the server's message, the live preview and the default. */
@Composable
fun PromptEditorBody(entry: PromptEntry, group: String?, text: String, preview: PromptPreview?, problem: String?, onType: (String) -> Unit, onInsert: (String) -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Caption((group ?: groupLabel(entry.group)) + if (entry.overridden) " · edited" else " · default")
        if (entry.description.isNotBlank()) Body(entry.description)
    }
    Labeled(when (entry.kind) { "list" -> "Text, comma-separated"; "lines" -> "Text, one per line"; else -> "Text" }) {
        Input(text, onType, area = true, placeholder = if (entry.allowEmpty) "Empty leaves this line out" else entry.default, calm = true)
        problem?.let { Notice(it, tone = NoticeTone.DANGER) }
    }
    if (entry.placeholders.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Heading("Placeholders")
        Caption("Tap one to add it. * is needed.")
        FlowRow(hGap = MuseSpace.s2, vGap = 0.dp) {
            entry.placeholders.forEach { p -> ChoiceChip("{${p.name}}" + if (p.required) " *" else "", "{${p.name}}" in text, { onInsert(p.name) }) }
        }
        entry.placeholders.forEach { p -> Caption("{${p.name}}${if (p.required) ", needed" else ""}${if (p.description.isNotBlank()) ": ${p.description}" else ""}") }
    }
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Heading("Preview")
        T(preview?.text?.ifBlank { "Empty: this line is left out." } ?: "Building the preview…", m.scale.body, m.roles.ink)
        if (preview != null && preview.example.isNotBlank() && preview.example != preview.text) {
            Caption("In a whole prompt, with the sample model:")
            T(preview.example, m.scale.caption, m.roles.ink2)
        }
    }
    if (entry.overridden || text != entry.default) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Heading("Default")
        T(entry.default.ifBlank { "Empty" }, m.scale.caption, m.roles.ink2)
    }
}

private fun groupLabel(id: String) = when (id) {
    "photoshoot" -> "Photo"; "references" -> "References"; "sheet" -> "Character sheet"; "outfits" -> "Outfits"; "enhance" -> "Enhance"
    "templates" -> "Templates"; "video" -> "Video"; "lora" -> "LoRA"; else -> id
}
