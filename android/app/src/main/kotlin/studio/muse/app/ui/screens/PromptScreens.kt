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
            groupLabel.value = lib?.groups?.firstOrNull { it.id == found?.group }?.label
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
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Prompts", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Prompt scripts (workstream 4): Blocks (the texts) | Scripts (which block is used when).
                val tab by c.drafts.promptsTab.collectAsState()
                Seg(listOf("blocks" to "Blocks", "scripts" to "Scripts"), tab, { c.drafts.promptsTab.value = it }, Modifier.fillMaxWidth())
                if (tab == "scripts") { PromptScriptsList(); return@Column }
                T("Every prompt MUSE sends when it makes a photo, an outfit set, a sheet angle, a LoRA set or a video. A saved edit is used for every new render in your studio, by you and your members. Work already running keeps its prompt.",
                    m.type.body, m.t.muted)
                err?.let { NoteBox(it, warn = true); Cta2("Try again", { vm.load() }, Modifier.fillMaxWidth(), icon = "retry", height = 46.dp) }
                val l = lib
                if (l == null && err == null) Tiny("Loading…")
                l?.groups?.forEach { g ->
                    val items = l.prompts.filter { it.group == g.id }
                    if (items.isEmpty()) return@forEach
                    RowB { Lbl(g.label); Tiny("${items.count { it.overridden }.takeIf { it > 0 }?.let { "$it edited · " } ?: ""}${items.size}") }
                    ListGroup {
                        items.forEach { p ->
                            Li("spark", p.title, sub = p.current.replace('\n', ' ').take(90).ifBlank { "(empty · left out)" }, onClick = { nav.go(Routes.prompt(p.key)) }) {
                                if (p.overridden) Pill("Edited", "warn")
                                Ic("chev", 14.dp)
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
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(entry?.title ?: "Prompt", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val e = entry ?: run { problem?.let { NoteBox(it, warn = true) } ?: Tiny("Loading…"); return@Column }
                val text = draft ?: e.current
                PromptEditorBody(e, group, text, preview, problem, vm::type, vm::insert)
                if (text != e.current) Cta2("Undo changes", { vm.undo() }, Modifier.fillMaxWidth(), icon = "retry", height = 46.dp)
                if (e.overridden) {
                    if (confirmReset) {
                        NoteBox("Reset “${e.title}” to its default? Every new photo and video in your studio goes back to MUSE's default text. Your version is not kept.", warn = true)
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Cta2("Reset to default", { confirmReset = false; vm.reset() }, Modifier.weight(1f), height = 46.dp)
                            Cta2("Cancel", { confirmReset = false }, Modifier.weight(1f), height = 46.dp)
                        }
                    } else Cta2("Reset to default", { confirmReset = true }, Modifier.fillMaxWidth(), icon = "retry", height = 46.dp)
                    e.updatedBy?.let { by -> Tiny("Last saved by $by${e.updatedAt?.let { " · " + savedAt(it) } ?: ""}") }
                }
            }
        }
        Dock(tight = true) {
            val changed = draft != null && draft != entry?.current
            val blocked = !changed || busy || problem != null
            Cta(if (busy) "Saving…" else if (changed) "Save" else "Saved", { if (!blocked) vm.save() }, Modifier.weight(1f), off = blocked && !busy, busy = busy)
        }
    }
}

private fun savedAt(ms: Long): String = java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(ms))

/** The editor itself: text, placeholder chips (tap adds; * = needed), the server's message, the live preview and the default. */
@Composable
fun PromptEditorBody(entry: PromptEntry, group: String?, text: String, preview: PromptPreview?, problem: String?, onType: (String) -> Unit, onInsert: (String) -> Unit) {
    val m = muse
    RowB { Lbl(group ?: groupLabel(entry.group)); if (entry.overridden) Pill("Edited", "warn") else Pill("Default") }
    if (entry.description.isNotBlank()) T(entry.description, m.type.body, m.t.muted)
    Field(when (entry.kind) { "list" -> "Text · comma-separated"; "lines" -> "Text · one per line"; else -> "Text" }) {
        Input(text, onType, area = true, placeholder = if (entry.allowEmpty) "Empty leaves this line out" else entry.default)
    }
    problem?.let { NoteBox(it, warn = true) }
    if (entry.placeholders.isNotEmpty()) {
        Lbl("Placeholders · tap to add")
        FlowRow(hGap = 6.dp, vGap = 6.dp) {
            entry.placeholders.forEach { p -> Chip("{${p.name}}" + if (p.required) " *" else "", "{${p.name}}" in text, { onInsert(p.name) }) }
        }
        entry.placeholders.forEach { p -> Tiny("{${p.name}}${if (p.required) " · needed" else ""}${if (p.description.isNotBlank()) ": ${p.description}" else ""}") }
    }
    Lbl("Preview")
    val shape = RoundedCornerShape(m.t.r)
    Column(Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T(preview?.text?.ifBlank { "(empty · this line is left out)" } ?: "Building the preview…", m.type.body.copy(fontWeight = FontWeight.Bold, fontSize = 13.sp, lineHeight = 18.sp), m.t.ink)
        if (preview != null && preview.example.isNotBlank() && preview.example != preview.text) {
            Tiny("In a whole prompt (sample model):")
            T(preview.example, m.type.mono.copy(fontSize = 11.sp, lineHeight = 15.sp), m.t.muted)
        }
    }
    if (entry.overridden || text != entry.default) {
        Lbl("Default")
        T(entry.default.ifBlank { "(empty)" }, m.type.mono.copy(fontSize = 11.sp, lineHeight = 15.sp), m.t.muted)
    }
    Spacer(Modifier.padding(2.dp))
}

private fun groupLabel(id: String) = when (id) {
    "photoshoot" -> "Photoshoot"; "references" -> "References"; "sheet" -> "Character sheet"; "outfits" -> "Outfits"; "enhance" -> "Enhance"
    "dressup" -> "Dress up"; "templates" -> "Templates"; "video" -> "Video"; "lora" -> "LoRA"; else -> id
}
