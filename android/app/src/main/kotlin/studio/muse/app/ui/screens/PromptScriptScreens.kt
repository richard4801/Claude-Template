package studio.muse.app.ui.screens

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import studio.muse.app.AppContainer
import studio.muse.app.data.Cond
import studio.muse.app.data.CondOpInfo
import studio.muse.app.data.InputDef
import studio.muse.app.data.PromptEntry
import studio.muse.app.data.PromptScriptsList
import studio.muse.app.data.Rule
import studio.muse.app.data.ScriptPreview
import studio.muse.app.data.ScriptView
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

/*
 * Prompt scripts (workstream 4), owner Settings → Prompts → Scripts (plans/api.md "Prompt scripts" §2): every prompt is a
 * script of typed inputs → rules → blocks. The owner reads the rules as sentences, switches them on or off, edits them in a
 * structured form (never code), previews the script with sample inputs, saves (PUT) or resets (DELETE). Members never get here.
 */

// ------------------------------------------------------------------------------------------------ wording (pure, tested)
object ScriptText {
    /** "Yes/no", "Choice", "Number", "Text", "List". */
    fun typeLabel(type: String) = when (type) { "bool" -> "Yes/no"; "enum" -> "Choice"; "number" -> "Number"; "text" -> "Text"; "list" -> "List"; else -> type }

    /** A value as the sentence says it: yes/no, an option's label, a number, "text"; several joined with "or". */
    fun value(def: InputDef?, v: JsonElement?): String = when (v) {
        null, is JsonNull -> ""
        is JsonArray -> v.joinToString(" or ") { value(def, it) }
        is JsonPrimitive -> when {
            !v.isString && v.booleanOrNull != null -> if (v.booleanOrNull == true) "yes" else "no"
            !v.isString && v.doubleOrNull != null -> num(v.doubleOrNull!!)
            else -> (def?.options?.firstOrNull { it.id == v.content } ?: def?.fields?.flatMap { it.options }?.firstOrNull { it.id == v.content })?.label ?: "“${v.content}”"
        }
        else -> v.toString()
    }
    fun num(d: Double) = if (d == Math.floor(d) && !d.isInfinite()) d.toLong().toString() else d.toString()

    /** "Performer is speaking is no", "Guides includes Scene", "Scene is empty". */
    fun cond(s: ScriptView, ops: List<CondOpInfo>, c: Cond, target: String): String {
        val def = inputFor(s, c.input, target)
        val op = ops.firstOrNull { it.id == c.op }?.label ?: c.op
        val v = value(def, c.value)
        return listOf(def?.label ?: c.input, op, v).filter { it.isNotBlank() }.joinToString(" ")
    }

    /** The rule as a sentence: "When Performer is speaking is no → Summary: <block title>" ("Always → …" without conditions). */
    fun sentence(s: ScriptView, ops: List<CondOpInfo>, r: Rule, blockTitle: (String) -> String): String {
        val place = s.targets.firstOrNull { it.id == r.target }?.label ?: r.target
        val whenText = if (r.conds.isEmpty()) "Always" else "When " + r.conds.joinToString(" and ") { cond(s, ops, it, r.target) }
        return "$whenText → $place: ${blockTitle(r.block)}"
    }

    fun inputFor(s: ScriptView, name: String, target: String): InputDef? = studio.muse.app.data.FakePromptScripts.inputFor(s, name, target)

    /** The inputs a rule in [target] can test: the script's, then "item.<field>" when that place repeats per list item. */
    fun inputsFor(s: ScriptView, target: String): List<Pair<String, InputDef>> {
        val each = s.sections.firstOrNull { it.id == target }?.each
        val items = each?.let { e -> s.inputs.firstOrNull { it.name == e }?.fields?.map { "item.${it.name}" to it } }.orEmpty()
        return s.inputs.map { it.name to it } + items
    }

    /** Tests for an input type (from the server's `ops`). */
    fun opsFor(ops: List<CondOpInfo>, def: InputDef?) = ops.filter { def != null && def.type in it.types }

    /** A test's starting value: no for yes/no, the first option, 0, empty text; none for empty/not empty. */
    fun defaultValue(def: InputDef?, op: String): JsonElement? = when {
        def == null || op == "empty" || op == "notEmpty" -> null
        op == "in" || op == "notIn" -> JsonArray(listOfNotNull(def.options.firstOrNull()?.let { JsonPrimitive(it.id) }))
        op == "has" || op == "hasNot" -> JsonPrimitive(def.options.firstOrNull()?.id ?: "")
        op == "atLeast" || op == "atMost" -> JsonPrimitive(0)
        def.type == "bool" -> JsonPrimitive(false)
        def.type == "enum" -> JsonPrimitive(def.options.firstOrNull()?.id ?: "")
        def.type == "number" -> JsonPrimitive(0)
        else -> JsonPrimitive("")
    }

    /** A condition on [input], with its first test and that test's starting value. */
    fun newCond(s: ScriptView, ops: List<CondOpInfo>, input: String, target: String): Cond {
        val def = inputFor(s, input, target)
        val op = opsFor(ops, def).firstOrNull()?.id ?: "is"
        return Cond(input, op, defaultValue(def, op))
    }

    /** A rule id not yet used: "rule.1", "rule.2", … */
    fun newId(rules: List<Rule>): String = generateSequence(1) { it + 1 }.map { "rule.$it" }.first { id -> rules.none { it.id == id } }

    /** Moves the rule [id] up (-1) or down (+1) past the next rule in the same place; the order elsewhere is kept. */
    fun move(rules: List<Rule>, id: String, dir: Int): List<Rule> {
        val i = rules.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return rules
        val target = rules[i].target
        val j = if (dir < 0) (i - 1 downTo 0).firstOrNull { rules[it].target == target } else (i + 1 until rules.size).firstOrNull { rules[it].target == target }
        j ?: return rules
        return rules.toMutableList().also { l -> val t = l[i]; l[i] = l[j]; l[j] = t }
    }

    /** The preview values: each input's sample, as JSON. */
    fun samples(s: ScriptView) = JsonObject(s.inputs.associate { it.name to (it.sample ?: JsonNull) })
}

// ------------------------------------------------------------------------------------------------ view models
class PromptScriptsViewModel(private val c: AppContainer) : ViewModel() {
    val list = MutableStateFlow<PromptScriptsList?>(null)
    val error = MutableStateFlow<String?>(null)

    init {
        // Another owner device saved or reset a script: keep the list in step.
        viewModelScope.launch {
            c.repo.live.collect { ev ->
                val s = ev.script?.takeIf { ev.type == "promptScript" } ?: return@collect
                list.update { l -> l?.copy(scripts = l.scripts.map { if (it.id == s.id) s else it }) }
            }
        }
    }
    fun load() = viewModelScope.launch { val (v, e) = c.repo.promptScripts(); v?.let { list.value = it }; error.value = e }
}

/** The rule form's state: [index] in the draft list (null = a new rule) and the rule being edited. */
data class RuleEdit(val index: Int?, val rule: Rule)

class PromptScriptViewModel(private val c: AppContainer, val id: String) : ViewModel() {
    val script = MutableStateFlow<ScriptView?>(null)
    val ops = MutableStateFlow<List<CondOpInfo>>(emptyList())
    val groupLabel = MutableStateFlow<String?>(null)
    /** Library entries by key (block titles and their Edited badge). */
    val blocks = MutableStateFlow<Map<String, PromptEntry>>(emptyMap())
    val rules = MutableStateFlow<List<Rule>?>(null)
    val inputs = MutableStateFlow<JsonObject?>(null)
    val preview = MutableStateFlow<ScriptPreview?>(null)
    /** script_invalid (from the preview while editing, or Save), shown as the server words it; or why it couldn't load. */
    val problem = MutableStateFlow<String?>(null)
    val busy = MutableStateFlow(false)
    val editing = MutableStateFlow<RuleEdit?>(null)

    init {
        viewModelScope.launch {
            val (list, e) = c.repo.promptScripts()
            val s = list?.scripts?.firstOrNull { it.id == id }
            ops.value = list?.ops.orEmpty()
            groupLabel.value = list?.groups?.firstOrNull { it.id == s?.group }?.label
            problem.value = e ?: if (list != null && s == null) "That script isn't in this studio." else null
            if (s != null) show(s)
            c.repo.prompts().first?.let { lib -> blocks.value = lib.prompts.associateBy { it.key } }
            // The preview at once, then ~300 ms after the last change.
            var first = true
            combine(rules, inputs) { r, i -> r to i }.collectLatest { (r, i) ->
                if (r == null || i == null) return@collectLatest
                if (!first) delay(300)
                first = false
                val changed = r != script.value?.rules
                val (p, invalid) = c.repo.previewPromptScript(id, i, r.takeIf { changed })
                if (p != null) preview.value = p
                problem.value = invalid
            }
        }
        // Another owner device saved or reset this script: untouched rules follow it, edited ones are kept.
        viewModelScope.launch {
            c.repo.live.collect { ev ->
                val s = ev.script?.takeIf { ev.type == "promptScript" && it.id == id } ?: return@collect
                if (rules.value == script.value?.rules) rules.value = s.rules
                script.value = s
            }
        }
    }
    private fun show(s: ScriptView) {
        script.value = s
        rules.value = s.rules
        if (inputs.value == null) inputs.value = ScriptText.samples(s)
    }

    fun title(key: String) = blocks.value[key]?.title?.ifBlank { null } ?: key
    fun setInput(name: String, v: JsonElement) = inputs.update { JsonObject((it ?: JsonObject(emptyMap())) + (name to v)) }
    fun toggle(ruleId: String) = rules.update { l -> l?.map { if (it.id == ruleId && !it.isLocked) it.copy(enabled = if (it.isOn) false else null) else it } }
    fun move(ruleId: String, dir: Int) = rules.update { l -> l?.let { ScriptText.move(it, ruleId, dir) } }
    fun open(index: Int) { rules.value?.getOrNull(index)?.let { editing.value = RuleEdit(index, it) } }
    fun add(target: String) {
        val s = script.value ?: return
        val l = rules.value ?: return
        val block = s.blocks.firstOrNull { b -> l.any { it.target == target && it.block == b } } ?: s.blocks.firstOrNull() ?: return
        editing.value = RuleEdit(null, Rule(ScriptText.newId(l), "New rule", target, emptyList(), block))
    }
    fun change(f: (Rule) -> Rule) = editing.update { it?.copy(rule = f(it.rule)) }
    fun closeForm() { editing.value = null }
    /** Puts the form's rule into the draft list (a new one goes after the last rule of its place). */
    fun applyForm() {
        val e = editing.value ?: return
        rules.update { l ->
            val list = l.orEmpty().toMutableList()
            if (e.index != null && e.index in list.indices) list[e.index] = e.rule
            else list.add((list.indexOfLast { it.target == e.rule.target } + 1).takeIf { it > 0 } ?: list.size, e.rule)
            list
        }
        editing.value = null
    }
    /** Keeps the form's changes (not a locked rule's) and moves the rule up (-1) or down (+1) within its place. */
    fun applyAndMove(dir: Int) {
        val e = editing.value ?: return
        if (!e.rule.isLocked) applyForm() else editing.value = null
        move(e.rule.id, dir)
    }
    /** Added rules only (the defaults can be switched off, not deleted). */
    fun delete() {
        val e = editing.value ?: return
        if (e.index != null) rules.update { l -> l?.filterIndexed { i, _ -> i != e.index } }
        editing.value = null
    }
    fun undo() { rules.value = script.value?.rules }
    fun save() = viewModelScope.launch {
        val r = rules.value ?: return@launch
        if (busy.value) return@launch
        busy.value = true
        val (s, err) = c.repo.savePromptScript(id, r)
        busy.value = false
        if (s != null) {
            show(s); problem.value = null
            c.repo.toast(if (s.overridden) "Saved · used for every new prompt" else "Saved · back on the default")
        } else problem.value = err
    }
    fun reset() = viewModelScope.launch {
        val (s, err) = c.repo.resetPromptScript(id)
        if (s != null) { show(s); problem.value = null; c.repo.toast("Back on the default") } else err?.let { c.repo.toast(it) }
    }
}

// ------------------------------------------------------------------------------------------------ Scripts list (a tab of Prompts)
@Composable
fun PromptScriptsList() {
    val c = LocalContainer.current
    val vm: PromptScriptsViewModel = viewModel { PromptScriptsViewModel(c) }
    LaunchedEffect(Unit) { vm.load() }
    val list by vm.list.collectAsState()
    val err by vm.error.collectAsState()
    val nav = LocalNav.current
    val m = muse
    T("Each prompt is put together by a script: facts about the job (is she speaking? which outfit?) choose the blocks. Change which block is used when; the blocks' text is edited under Blocks.",
        m.type.body, m.t.muted)
    err?.let { NoteBox(it, warn = true); Cta2("Try again", { vm.load() }, Modifier.fillMaxWidth(), icon = "retry", height = 46.dp) }
    val l = list
    if (l == null && err == null) Tiny("Loading…")
    l?.groups?.forEach { g ->
        val items = l.scripts.filter { it.group == g.id }
        if (items.isEmpty()) return@forEach
        RowB { Lbl(g.label); Tiny("${items.count { it.overridden }.takeIf { it > 0 }?.let { "$it edited · " } ?: ""}${items.size}") }
        ListGroup {
            items.forEach { s ->
                Li("grid", s.title, sub = s.description.take(110), onClick = { nav.go(Routes.promptScript(s.id)) }) {
                    if (s.overridden) Pill("Edited", "warn")
                    Ic("chev", 14.dp)
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------ one script
@Composable
fun PromptScriptScreen(id: String) {
    val c = LocalContainer.current
    val vm: PromptScriptViewModel = viewModel(key = "script_$id") { PromptScriptViewModel(c, id) }
    val s by vm.script.collectAsState()
    val rules by vm.rules.collectAsState()
    val editing by vm.editing.collectAsState()
    val problem by vm.problem.collectAsState()
    val busy by vm.busy.collectAsState()
    val nav = LocalNav.current
    if (editing != null) return RuleFormScreen(vm)
    var confirmReset by remember { mutableStateOf(false) }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(s?.title ?: "Script", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val sc = s ?: run { problem?.let { NoteBox(it, warn = true) } ?: Tiny("Loading…"); return@Column }
                ScriptBody(vm, sc, rules ?: sc.rules, problem)
                if (rules != null && rules != sc.rules) Cta2("Undo changes", { vm.undo() }, Modifier.fillMaxWidth(), icon = "retry", height = 46.dp)
                if (sc.overridden) {
                    if (confirmReset) {
                        NoteBox("Reset “${sc.title}” to its default rules? Every new prompt in your studio goes back to MUSE's rules. Your rules are not kept; block texts are not touched.", warn = true)
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Cta2("Reset to default", { confirmReset = false; vm.reset() }, Modifier.weight(1f), height = 46.dp)
                            Cta2("Cancel", { confirmReset = false }, Modifier.weight(1f), height = 46.dp)
                        }
                    } else Cta2("Reset to default", { confirmReset = true }, Modifier.fillMaxWidth(), icon = "retry", height = 46.dp)
                    sc.updatedBy?.let { by -> Tiny("Last saved by $by") }
                }
            }
        }
        Dock(tight = true) {
            val changed = rules != null && rules != s?.rules
            val blocked = !changed || busy || problem != null
            Cta(if (busy) "Saving…" else if (changed) "Save" else "Saved", { if (!blocked) vm.save() }, Modifier.weight(1f), off = blocked && !busy, busy = busy)
        }
    }
}

@Composable
private fun ColumnScope.ScriptBody(vm: PromptScriptViewModel, s: ScriptView, rules: List<Rule>, problem: String?) {
    val m = muse
    val nav = LocalNav.current
    val group by vm.groupLabel.collectAsState()
    val ops by vm.ops.collectAsState()
    val blocks by vm.blocks.collectAsState()
    RowB { Lbl(group ?: s.group); if (s.overridden) Pill("Edited", "warn") else Pill("Default") }
    if (s.description.isNotBlank()) T(s.description, m.type.body, m.t.muted)
    if (s.stale) NoteBox("The rules saved for this script no longer fit it (MUSE changed the script), so it's back on its defaults.", warn = true)
    problem?.let { NoteBox(it, warn = true) }

    if (s.inputs.isNotEmpty()) {
        Lbl("Inputs")
        ListGroup {
            s.inputs.forEach { i ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    RowB { T(i.label, m.type.body, m.t.ink, Modifier.weight(1f)); Pill(ScriptText.typeLabel(i.type)) }
                    val opts = (i.options.ifEmpty { i.fields.flatMap { it.options } }).joinToString(" · ") { it.label }
                    Tiny(i.description + if (opts.isNotBlank()) " ($opts)" else "")
                }
            }
        }
    }

    Lbl("Rules")
    Tiny("Read top to bottom: in each place the first rule that applies is used (repeating places and Details use every one).")
    s.targets.forEach { t ->
        val inPlace = rules.withIndex().filter { it.value.target == t.id }
        RowB { T(t.label, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); T("+ Add rule", m.type.tiny.copy(fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.press { vm.add(t.id) }.padding(vertical = 4.dp)) }
        if (inPlace.isEmpty()) Tiny("No rules · nothing is put here")
        else ListGroup {
            inPlace.forEach { (i, r) ->
                Row(Modifier.fillMaxWidth().press { vm.open(i) }.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        T(r.label, m.type.body, if (r.isOn) m.t.ink else m.t.muted, maxLines = 2)
                        Tiny(ScriptText.sentence(s, ops, r, vm::title) + if (r.isOn) "" else " · off")
                    }
                    if (r.isLocked) Ic("lock", 18.dp, m.t.muted) else Toggle(r.isOn, { vm.toggle(r.id) })
                }
            }
        }
    }

    Lbl("Blocks · tap to edit the text")
    ListGroup {
        s.blocks.forEach { key ->
            val e = blocks[key]
            Li("spark", e?.title?.ifBlank { null } ?: key, sub = e?.current?.replace('\n', ' ')?.take(80)?.ifBlank { "(empty · left out)" }, onClick = { nav.go(Routes.prompt(key)) }) {
                if (e?.overridden == true) Pill("Edited", "warn")
                Ic("chev", 14.dp)
            }
        }
    }

    PreviewPanel(vm, s, rules)
}

/** A control per input pre-filled with its sample (switch / menu / number / text), the assembled text and the rules that fired. */
@Composable
private fun PreviewPanel(vm: PromptScriptViewModel, s: ScriptView, rules: List<Rule>) {
    val m = muse
    val inputs by vm.inputs.collectAsState()
    val preview by vm.preview.collectAsState()
    Lbl("Preview · sample values")
    s.inputs.forEach { i ->
        val v = inputs?.get(i.name)
        when (i.type) {
            "bool" -> RowB {
                T(i.label, m.type.body, m.t.ink, Modifier.weight(1f))
                val on = (v as? JsonPrimitive)?.booleanOrNull == true
                Toggle(on, { vm.setInput(i.name, JsonPrimitive(!on)) })
            }
            "enum" -> Field(i.label) {
                val cur = (v as? JsonPrimitive)?.content
                Picker(i.options.firstOrNull { it.id == cur }?.label ?: cur.orEmpty(), i.options.map { it.id to it.label }) { vm.setInput(i.name, JsonPrimitive(it)) }
            }
            "number" -> Field(i.label) { NumberInput((v as? JsonPrimitive)?.doubleOrNull) { d -> vm.setInput(i.name, numberJson(d)) } }
            "text" -> Field(i.label) { Input((v as? JsonPrimitive)?.content.orEmpty(), { vm.setInput(i.name, JsonPrimitive(it)) }) }
            else -> RowB { T(i.label, m.type.body, m.t.ink, Modifier.weight(1f)); Tiny(listSummary(v)) }
        }
    }
    val shape = RoundedCornerShape(m.t.r)
    Column(Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val p = preview
        T(p?.text?.trimEnd()?.ifBlank { "(empty)" } ?: "Building the preview…", m.type.mono.copy(fontSize = 11.sp, lineHeight = 15.sp), m.t.ink)
        if (p != null) {
            val labels = p.fired.distinct().map { f -> rules.firstOrNull { it.id == f }?.label ?: f }
            Tiny("Rules used: " + labels.joinToString(", ").ifBlank { "none" })
        }
    }
}

private fun listSummary(v: JsonElement?): String = when (v) {
    is JsonArray -> if (v.isEmpty()) "none" else "${v.size} sample item${if (v.size == 1) "" else "s"}"
    else -> "sample"
}
private fun numberJson(d: Double): JsonPrimitive = if (d == Math.floor(d) && !d.isInfinite() && kotlin.math.abs(d) < 1e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)

@Composable
private fun NumberInput(value: Double?, onChange: (Double) -> Unit) {
    var text by remember { mutableStateOf(value?.let { ScriptText.num(it) } ?: "") }
    Input(text, { t -> text = t; t.trim().toDoubleOrNull()?.let(onChange) }, keyboard = KeyboardType.Decimal)
}

/** A field that opens a menu of choices (id → label). */
@Composable
fun Picker(current: String, options: List<Pair<String, String>>, modifier: Modifier = Modifier, enabled: Boolean = true, onPick: (String) -> Unit) {
    val m = muse
    var open by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(m.t.r)
    Box(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().height(48.dp).clip(shape).background(m.t.surface).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape)
            .press(enabled) { open = true }.padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            T(current.ifBlank { "Choose…" }, m.type.body, if (enabled) m.t.ink else m.t.muted, Modifier.weight(1f), maxLines = 1)
            if (enabled) Ic("chev", 14.dp, m.t.muted, Modifier.padding(0.dp))
        }
        DropdownMenu(open, { open = false }, containerColor = m.t.surface) {
            options.forEach { (id, label) ->
                DropdownMenuItem(text = { T(label, m.type.body, m.t.ink) }, onClick = { open = false; onPick(id) })
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------ the rule form
@Composable
fun RuleFormScreen(vm: PromptScriptViewModel) {
    val m = muse
    val s by vm.script.collectAsState()
    val e by vm.editing.collectAsState()
    val ops by vm.ops.collectAsState()
    val problem by vm.problem.collectAsState()
    val nav = LocalNav.current
    BackHandler { vm.closeForm() }
    val sc = s ?: return
    val edit = e ?: return
    val r = edit.rule
    val added = sc.defaultRules.none { it.id == r.id }
    val locked = r.isLocked
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(if (edit.index == null) "New rule" else "Rule", onBack = { vm.closeForm() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                T(sc.title, m.type.tiny, m.t.muted)
                if (locked) NoteBox("This rule is locked: it can't be switched off or changed. Only its block's text can be edited.", icon = "lock")
                problem?.let { NoteBox(it, warn = true) }
                Field("Name") { if (locked) T(r.label, m.type.body, m.t.ink) else Input(r.label, { t -> vm.change { it.copy(label = t.take(120)) } }) }
                Field("Place") {
                    Picker(sc.targets.firstOrNull { it.id == r.target }?.label ?: r.target, sc.targets.map { it.id to it.label }, enabled = !locked) { t ->
                        // Item fields only work in a place that repeats per item.
                        vm.change { it.copy(target = t, conds = it.conds.filter { c -> !c.input.startsWith("item.") || ScriptText.inputFor(sc, c.input, t) != null }) }
                    }
                }
                Field("Block") {
                    Picker(vm.title(r.block), sc.blocks.map { it to vm.title(it) }, enabled = !locked) { b -> vm.change { it.copy(block = b) } }
                }
                Lbl("Conditions · all must hold")
                if (r.conds.isEmpty()) Tiny("None · the rule always applies")
                r.conds.forEachIndexed { ci, c -> CondEditor(sc, ops, r.target, c, locked, onChange = { nc -> vm.change { it.copy(conds = it.conds.mapIndexed { k, x -> if (k == ci) nc else x }) } },
                    onRemove = { vm.change { it.copy(conds = it.conds.filterIndexed { k, _ -> k != ci }) } }) }
                if (!locked && r.conds.size < 8) Cta2("Add condition", {
                    val first = ScriptText.inputsFor(sc, r.target).firstOrNull()?.first ?: return@Cta2
                    vm.change { it.copy(conds = it.conds + ScriptText.newCond(sc, ops, first, r.target)) }
                }, Modifier.fillMaxWidth(), icon = "plus", height = 46.dp)
                Lbl("Reads as")
                T(ScriptText.sentence(sc, ops, r, vm::title), m.type.body, m.t.ink)
                if (edit.index != null) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Cta2("Move up", { vm.applyAndMove(-1) }, Modifier.weight(1f), height = 46.dp)
                    Cta2("Move down", { vm.applyAndMove(1) }, Modifier.weight(1f), height = 46.dp)
                }
                if (locked) Cta2("Edit the block's text", { vm.closeForm(); nav.go(Routes.prompt(r.block)) }, Modifier.fillMaxWidth(), icon = "spark", height = 46.dp)
                if (added && edit.index != null) Cta2("Delete rule", { vm.delete() }, Modifier.fillMaxWidth(), height = 46.dp)
            }
        }
        Dock(tight = true) {
            Cta2("Cancel", { vm.closeForm() }, Modifier.weight(1f))
            Cta(if (edit.index == null) "Add" else "Done", { if (!locked) vm.applyForm() else vm.closeForm() }, Modifier.weight(1f))
        }
    }
}

@Composable
private fun CondEditor(s: ScriptView, ops: List<CondOpInfo>, target: String, c: Cond, locked: Boolean, onChange: (Cond) -> Unit, onRemove: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    val def = ScriptText.inputFor(s, c.input, target)
    Column(Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val inputs = ScriptText.inputsFor(s, target)
        Picker(inputs.firstOrNull { it.first == c.input }?.let { (n, d) -> if (n.startsWith("item.")) "$n · ${d.label}" else d.label } ?: c.input,
            inputs.map { (n, d) -> n to if (n.startsWith("item.")) "$n · ${d.label}" else d.label }, enabled = !locked) { n -> onChange(ScriptText.newCond(s, ops, n, target)) }
        val allowed = ScriptText.opsFor(ops, def)
        Picker(allowed.firstOrNull { it.id == c.op }?.label ?: c.op, allowed.map { it.id to it.label }, enabled = !locked) { op -> onChange(c.copy(op = op, value = ScriptText.defaultValue(def, op))) }
        ValueEditor(def, c, locked, onChange)
        if (!locked) T("Remove condition", m.type.tiny.copy(fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.press(onClick = onRemove).padding(vertical = 4.dp))
    }
}

/** The value: a switch (yes/no), a menu of options, option chips (is one of), a number or a short text. */
@Composable
private fun ValueEditor(def: InputDef?, c: Cond, locked: Boolean, onChange: (Cond) -> Unit) {
    val m = muse
    def ?: return
    when (c.op) {
        "empty", "notEmpty" -> return
        "in", "notIn" -> {
            val on = (c.value as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
            FlowRow(hGap = 6.dp, vGap = 6.dp) {
                def.options.forEach { o ->
                    Chip(o.label, o.id in on, {
                        if (!locked) onChange(c.copy(value = JsonArray(def.options.map { it.id }.filter { id -> if (id == o.id) id !in on else id in on }.map { JsonPrimitive(it) })))
                    })
                }
            }
        }
        "atLeast", "atMost" -> NumberInput((c.value as? JsonPrimitive)?.doubleOrNull) { d -> if (!locked) onChange(c.copy(value = numberJson(d))) }
        else -> when {
            def.type == "bool" -> RowB {
                val on = (c.value as? JsonPrimitive)?.booleanOrNull == true
                T(if (on) "Yes" else "No", m.type.body, m.t.ink, Modifier.weight(1f))
                Toggle(on, { if (!locked) onChange(c.copy(value = JsonPrimitive(!on))) })
            }
            def.options.isNotEmpty() -> {
                val cur = (c.value as? JsonPrimitive)?.content
                Picker(def.options.firstOrNull { it.id == cur }?.label ?: cur.orEmpty(), def.options.map { it.id to it.label }, enabled = !locked) { onChange(c.copy(value = JsonPrimitive(it))) }
            }
            def.type == "number" -> NumberInput((c.value as? JsonPrimitive)?.doubleOrNull) { d -> if (!locked) onChange(c.copy(value = numberJson(d))) }
            else -> Input((c.value as? JsonPrimitive)?.content.orEmpty(), { if (!locked) onChange(c.copy(value = JsonPrimitive(it.take(200)))) })
        }
    }
}
