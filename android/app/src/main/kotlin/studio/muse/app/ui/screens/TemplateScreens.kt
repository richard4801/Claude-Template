package studio.muse.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Job as CoJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.CreateTemplateRequest
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.data.PatchTemplateRequest
import studio.muse.app.data.PoolSlots
import studio.muse.app.data.PromptSlotView
import studio.muse.app.data.ShootRequest
import studio.muse.app.data.Template
import studio.muse.app.data.TemplateDraft
import studio.muse.app.data.TemplateFilter
import studio.muse.app.data.TemplateLayers
import studio.muse.app.data.TemplatePrompt
import studio.muse.app.data.TemplatePromptRequest
import studio.muse.app.data.TemplateUseDraft
import studio.muse.app.ui.LocalCelebrate
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing

// ======================================================================= Library (Photoshoot → Templates)

data class TemplatesState(val filter: TemplateFilter = TemplateFilter(), val shown: List<Template> = emptyList(), val tags: List<String> = emptyList(), val loaded: Boolean = false)

class TemplatesViewModel(private val c: AppContainer) : ViewModel() {
    private val loaded = MutableStateFlow(false)
    val state: StateFlow<TemplatesState> = combine(c.repo.state, c.drafts.templateFilter, loaded) { s, f, l ->
        val all = s.templates
        TemplatesState(f, filter(all, f), all.flatMap { it.tags }.groupingBy { it.lowercase() }.eachCount().entries.sortedByDescending { it.value }
            .mapNotNull { e -> all.firstNotNullOfOrNull { t -> t.tags.firstOrNull { it.lowercase() == e.key } } }.take(12), l || all.isNotEmpty())
    }.stateIn(viewModelScope, SharingStarted.Eagerly, TemplatesState())

    fun load() = viewModelScope.launch { c.repo.loadTemplates(); loaded.value = true }
    fun edit(f: (TemplateFilter) -> TemplateFilter) = c.drafts.templateFilter.update(f)
    fun favourite(t: Template) = viewModelScope.launch { c.repo.favouriteTemplate(t.id, !t.favourite) }

    companion object {
        /** The tabs and search, on the phone (the list is scope=all: mine + the studio's public ones). */
        fun filter(all: List<Template>, f: TemplateFilter): List<Template> {
            val q = f.query.trim().lowercase()
            return all.filter {
                when (f.tab) { "mine" -> it.isOwner; "public" -> it.public; "favourites" -> it.favourite; else -> true }
            }.filter { t -> q.isEmpty() || t.name.lowercase().contains(q) || t.tags.any { it.lowercase().contains(q) } }
                .filter { t -> f.tag == null || t.tags.any { it.equals(f.tag, true) } }
        }
    }
}

@Composable
fun TemplatesScreen() {
    val c = LocalContainer.current
    val vm: TemplatesViewModel = viewModel { TemplatesViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    LaunchedEffect(Unit) { vm.load() }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Templates", onBack = { nav.back() }) {
                MoreMenu(listOf(
                    MenuItem("camera", "Make one from a photo") { c.repo.toast("Open any photo you like → Save as template") },
                    MenuItem("retry", "Refresh") { vm.load() },
                ))
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Seg(listOf("all" to "All", "mine" to "Mine", "public" to "Public", "favourites" to "Favourites"), s.filter.tab, { v -> vm.edit { it.copy(tab = v) } }, small = true)
                Input(s.filter.query, { v -> vm.edit { it.copy(query = v) } }, placeholder = "Search by name or tag")
                if (s.tags.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    s.tags.forEach { tag -> Chip(tag, s.filter.tag.equals(tag, true), { vm.edit { it.copy(tag = if (it.tag.equals(tag, true)) null else tag) } }) }
                }
                if (s.shown.isEmpty() && s.loaded) NoteBox(
                    when (s.filter.tab) {
                        "mine" -> "No templates of yours yet. Open a photo you like and tap Save as template."
                        "favourites" -> "No favourites yet. Open a template and tap Favourite."
                        else -> if (s.filter.query.isNotBlank() || s.filter.tag != null) "Nothing matches. Try another word or tag." else "No templates yet."
                    }, icon = "grid",
                )
                s.shown.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        pair.forEach { t -> TemplateCard(t, Modifier.weight(1f)) { nav.go(Routes.template(t.id)) } }
                        if (pair.size == 1) Box(Modifier.weight(1f))
                    }
                }
                if (s.shown.isNotEmpty()) Tiny("Same look, a different moment every time: each shot draws a new pose, angle and framing. A template's prompt stays with the person who made it.", color = m.t.muted)
            }
        }
    }
}

/** Library card: cover, name, owner, uses and a private/public badge. */
@Composable
fun TemplateCard(t: Template, modifier: Modifier = Modifier, height: Dp = 200.dp, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(modifier.press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().height(height).clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }.background(m.t.surface2)) {
            if (t.cover != null) RefImage(t.cover, Modifier.fillMaxSize(), 20) else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Ic("camera", 28.dp, m.t.muted) }
            VisibilityBadge(t, Modifier.align(Alignment.TopStart).padding(8.dp))
            if (t.favourite) Box(Modifier.align(Alignment.TopEnd).padding(8.dp).size(26.dp).clip(RoundedCornerShape(999.dp)).background(Color.Black.copy(alpha = .45f)), contentAlignment = Alignment.Center) {
                T("♥", m.type.body.copy(fontSize = 14.sp), Color.White)
            }
        }
        T(t.name, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
        T("${if (t.isOwner) "You" else t.ownerName} · ${usesText(t.uses)}", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
    }
}

fun usesText(n: Int) = if (n == 1) "1 use" else "$n uses"

@Composable
fun VisibilityBadge(t: Template, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(999.dp)
    Row(
        modifier.height(24.dp).clip(shape).background(if (t.public) m.t.surface.copy(alpha = .92f) else Color.Black.copy(alpha = .6f)).padding(horizontal = 9.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (!t.public) Ic("lock", 11.dp, Color.White)
        T(if (t.public) "Public" else "Private", m.type.pill, if (t.public) m.t.ink else Color.White, upper = m.isA, maxLines = 1)
    }
}

// ======================================================================= Detail

data class TemplateDetailState(val t: Template? = null, val error: String? = null, val editing: Boolean = false, val edit: TemplateEdit? = null, val busy: Boolean = false)

/** The owner's editable copy of a template. Tags are typed comma-separated. */
data class TemplateEdit(val name: String, val tags: String, val layers: TemplateLayers, val pool: Map<String, List<String>>)

class TemplateDetailViewModel(private val c: AppContainer, private val id: String) : ViewModel() {
    private val _s = MutableStateFlow(TemplateDetailState(t = c.repo.state.value.templates.firstOrNull { it.id == id }))
    val state: StateFlow<TemplateDetailState> = _s

    fun load() = viewModelScope.launch {
        val (t, err) = c.repo.template(id)
        _s.update { it.copy(t = t ?: it.t, error = if (t == null) err else null) }
    }
    private fun keepRecent(n: Template?) = n?.copy(recent = _s.value.t?.recent)
    fun favourite() = viewModelScope.launch { val t = _s.value.t ?: return@launch; c.repo.favouriteTemplate(t.id, !t.favourite)?.let { n -> _s.update { it.copy(t = keepRecent(n)) } } }
    fun visibility(public: Boolean) = viewModelScope.launch {
        c.repo.patchTemplate(id, PatchTemplateRequest(visibility = if (public) "public" else "private"))?.let { n ->
            _s.update { it.copy(t = keepRecent(n)) }
            c.repo.toast(if (public) "Public · everyone in the studio can use it" else "Private · only you can see it")
        }
    }
    fun duplicate(go: (String) -> Unit) = viewModelScope.launch { c.repo.duplicateTemplate(id)?.let { c.repo.toast("Duplicated as \"${it.name}\""); go(it.id) } }
    fun delete(done: () -> Unit) = viewModelScope.launch { if (c.repo.deleteTemplate(id) != null) { c.repo.toast("Template deleted"); done() } }

    fun startEdit() { val t = _s.value.t ?: return; _s.update { it.copy(editing = true, edit = TemplateEdit(t.name, t.tags.joinToString(", "), t.layers ?: TemplateLayers(), t.variationPool.orEmpty())) } }
    fun cancelEdit() = _s.update { it.copy(editing = false, edit = null) }
    fun change(f: (TemplateEdit) -> TemplateEdit) = _s.update { s -> s.copy(edit = s.edit?.let(f)) }
    fun save() = viewModelScope.launch {
        val e = _s.value.edit ?: return@launch
        if (e.name.isBlank()) return@launch c.repo.toast("Give it a name")
        _s.update { it.copy(busy = true) }
        val n = c.repo.patchTemplate(id, PatchTemplateRequest(e.name.trim(), splitTags(e.tags), layers = e.layers, variationPool = e.pool))
        _s.update { it.copy(busy = false, t = keepRecent(n) ?: it.t, editing = n == null, edit = if (n == null) it.edit else null) }
        if (n != null) c.repo.toast("Template saved")
    }
    fun use(go: () -> Unit) { c.drafts.templateUse.value = TemplateUseDraft(id); go() }
}

fun splitTags(s: String) = s.split(',').map { it.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }.take(12)

@Composable
fun TemplateDetailScreen(id: String) {
    val c = LocalContainer.current
    val vm: TemplateDetailViewModel = viewModel(key = "template-$id") { TemplateDetailViewModel(c, id) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    LaunchedEffect(id) { vm.load() }
    val t = s.t
    var confirmDelete by remember { mutableStateOf(false) }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(if (s.editing) "Edit template" else "Template", onBack = { if (s.editing) vm.cancelEdit() else nav.back() }) {
                if (t?.isOwner == true && !s.editing) MoreMenu(listOf(
                    MenuItem("spark", "Edit") { vm.startEdit() },
                    MenuItem("retry", "Duplicate") { vm.duplicate { nav.go(Routes.template(it)) } },
                    MenuItem("shield", "Delete", danger = true) { confirmDelete = true },
                ))
            }
            if (t == null) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    NoteBox(s.error ?: "Loading…", icon = "grid", warn = s.error != null)
                    if (s.error != null) Cta2("Back to Templates", { nav.back() }, Modifier.fillMaxWidth())
                }
                return@Column
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (s.editing && s.edit != null) {
                    Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) { TemplateEditor(s.edit!!, vm::change) }
                    return@Column
                }
                Canvas(300.dp) {
                    RefImage(t.cover, Modifier.fillMaxSize(), 20)
                    VisibilityBadge(t, Modifier.align(Alignment.TopStart).padding(12.dp))
                    if (t.starter != null) Sticker("starter pack", "yellow", -4f, Modifier.align(Alignment.BottomStart).padding(12.dp))
                }
                Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    RowB(align = Alignment.Top) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            H2(t.name)
                            Tiny("by ${if (t.isOwner) "you" else t.ownerName} · ${usesText(t.uses)}")
                        }
                        Chip(if (t.favourite) "♥ Favourite" else "♡ Favourite", t.favourite, { vm.favourite() })
                    }
                    if (t.tags.isNotEmpty()) FlowRow { t.tags.forEach { Pill(it) } }
                    val recent = t.recent.orEmpty()
                    if (recent.isNotEmpty()) Field("Recent results") {
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            recent.forEach { r ->
                                val shape = RoundedCornerShape(m.t.r * .6f)
                                Box(Modifier.width(82.dp).height(110.dp).clip(shape).press { nav.go(Routes.result(r.id)) }) { RefImage(r.thumb, Modifier.fillMaxSize()) }
                            }
                        }
                    }
                    if (t.isOwner) {
                        Card {
                            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                RowB {
                                    Column(Modifier.weight(1f)) {
                                        T("Public", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                                        Tiny(if (t.public) "Everyone in the studio can see and use it. They never see its prompt." else "Only you can see and use it.")
                                    }
                                    Toggle(t.public, { vm.visibility(!t.public) })
                                }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Cta2("Duplicate", { vm.duplicate { nav.go(Routes.template(it)) } }, Modifier.weight(1.2f), height = 46.dp)
                            Cta2("Edit", { vm.startEdit() }, Modifier.weight(1f), height = 46.dp)
                            Cta2(if (confirmDelete) "Sure?" else "Delete", { if (confirmDelete) vm.delete { nav.back() } else confirmDelete = true }, Modifier.weight(1f), height = 46.dp)
                        }
                        t.layers?.let { LayersSummary(it, t.variationPool.orEmpty()) }
                    } else {
                        NoteBox("${t.ownerName}'s look stays underneath: you pick the model, the outfit and, if you like, how she's placed. Every shot draws a new moment.", icon = "lock")
                    }
                }
            }
        }
        Dock(tight = true) {
            if (t != null && s.editing) {
                Cta2("Cancel", { vm.cancelEdit() }, Modifier.weight(1f))
                Cta("Save", { vm.save() }, Modifier.weight(1f), busy = s.busy)
            } else if (t != null) Cta("Use template", { vm.use { nav.go(Routes.templateUse(t.id)) } }, Modifier.weight(1f), icon = "camera")
        }
    }
}

/** The creator's view of the hidden layers (read-only on the detail page). */
@Composable
private fun LayersSummary(l: TemplateLayers, pool: Map<String, List<String>>) {
    val m = muse
    Field("Prompt layers · only you see these") {
        val shape = RoundedCornerShape(m.t.r)
        Column(
            Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            listOf("style" to l.style, "scene" to l.scene, "camera" to l.camera, "light" to l.light, "product" to l.product, "never" to l.negative).forEach { (k, v) ->
                if (!v.isNullOrBlank()) SlotLine(k, v)
            }
            l.afterEffects?.let { fx ->
                val parts = listOfNotNull(fx.grade?.let { "grade $it" }, fx.grain?.takeIf { it > 0 }?.let { "grain ${(it * 100).toInt()}%" }, fx.faceMotionBlur?.takeIf { it > 0 }?.let { "face motion blur ${(it * 100).toInt()}%" })
                if (parts.isNotEmpty()) SlotLine("after", parts.joinToString(", "))
            }
            PoolSlots.ALL.forEach { k -> pool[k]?.takeIf { it.isNotEmpty() }?.let { SlotLine(PoolSlots.label(k).substringBefore(' ').lowercase(), it.joinToString(" / ")) } }
        }
    }
}

@Composable
private fun SlotLine(label: String, text: String, locked: Boolean = false) {
    val m = muse
    Row(verticalAlignment = Alignment.Top) {
        T(label.uppercase(), m.type.mono.copy(fontSize = 10.sp, letterSpacing = .08.em), m.t.muted, Modifier.width(74.dp))
        if (locked) { Ic("lock", 12.dp, m.t.ink, Modifier.padding(top = 2.dp, end = 4.dp)) }
        T(text, m.type.body.copy(fontSize = 12.5.sp, lineHeight = 17.sp, fontWeight = if (locked) FontWeight.Bold else null), m.t.ink, Modifier.weight(1f))
    }
}

/** Name, tags, the layers and the variation pool, for the template's owner. */
@Composable
private fun TemplateEditor(e: TemplateEdit, change: ((TemplateEdit) -> TemplateEdit) -> Unit) {
    Field("Name") { Input(e.name, { v -> change { it.copy(name = v) } }) }
    Field("Tags") { Input(e.tags, { v -> change { it.copy(tags = v) } }, placeholder = "Faceless, Golden hour") }
    val l = e.layers
    Field("Style") { Input(l.style.orEmpty(), { v -> change { it.copy(layers = it.layers.copy(style = v)) } }, area = true) }
    Field("Scene") { Input(l.scene.orEmpty(), { v -> change { it.copy(layers = it.layers.copy(scene = v)) } }, area = true) }
    Field("Camera") { Input(l.camera.orEmpty(), { v -> change { it.copy(layers = it.layers.copy(camera = v)) } }, area = true) }
    Field("Light and grade") { Input(l.light.orEmpty(), { v -> change { it.copy(layers = it.layers.copy(light = v)) } }, area = true) }
    Field("Never add (on top of the model's own)") { Input(l.negative.orEmpty(), { v -> change { it.copy(layers = it.layers.copy(negative = v)) } }) }
    Field("Colour grade (after the shot)") {
        ChipRow(GRADE_CHOICES.map { it.first }, l.afterEffects?.grade ?: "none", { v -> change { it.copy(layers = it.layers.copy(afterEffects = (it.layers.afterEffects ?: studio.muse.app.data.TemplateAfterEffects()).copy(grade = v))) } }) { k -> GRADE_CHOICES.first { it.first == k }.second }
    }
    PoolEditor(e.pool) { p -> change { it.copy(pool = p) } }
}

val GRADE_CHOICES = listOf("none" to "None", "phone-natural" to "Phone-natural", "underexposed" to "Underexposed", "moody-blue" to "Moody blue",
    "golden" to "Golden", "harsh-sun" to "Harsh sun", "faded" to "Faded", "mono" to "Mono")

/** The variation pool: each slot's options as removable chips, plus a box to add one. */
@Composable
fun PoolEditor(pool: Map<String, List<String>>, onChange: (Map<String, List<String>>) -> Unit) {
    val m = muse
    Field("Variation pool") {
        Tiny("Each shot draws one option from every slot, so the look stays and the moment changes. A Direction replaces Pose and Body angle.")
        PoolSlots.ALL.forEach { k ->
            val opts = pool[k].orEmpty()
            var adding by remember(k) { mutableStateOf("") }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                T(PoolSlots.label(k), m.type.body.copy(fontWeight = FontWeight.Bold, fontSize = 13.sp), m.t.ink)
                if (opts.isNotEmpty()) FlowRow(hGap = 6.dp, vGap = 6.dp) {
                    opts.forEach { o -> Chip("$o  ×", false, { onChange(pool + (k to opts.filterNot { it == o })) }) }
                }
                Input(adding, { adding = it }, placeholder = "Add an option", trailing = {
                    T("Add", m.type.tiny.copy(fontWeight = FontWeight.Bold), if (m.isD) m.t.blue else m.t.accent, Modifier.press {
                        val v = adding.trim()
                        if (v.isNotEmpty() && opts.size < 12) { onChange(pool + (k to (opts + v).distinct())); adding = "" }
                    }.padding(8.dp))
                })
            }
        }
    }
}

// ======================================================================= Using a template

data class TemplateUseState(
    val t: Template? = null,
    val draft: TemplateUseDraft = TemplateUseDraft(),
    val model: Model? = null,
    val models: List<Model> = emptyList(),
    val outfits: List<Outfit> = emptyList(),
    val outfit: Outfit? = null,
    val prompt: TemplatePrompt? = null,
    /** idle | busy | ready */
    val phase: String = "idle",
)

class TemplateUseViewModel(private val c: AppContainer, private val id: String) : ViewModel() {
    private val phase = MutableStateFlow("idle")
    private val prompt = MutableStateFlow<TemplatePrompt?>(null)
    private var promptJob: CoJob? = null
    val state: StateFlow<TemplateUseState> = combine(c.repo.state, c.drafts.templateUse, c.drafts.modelId, c.drafts.outfitId, combine(phase, prompt) { a, b -> a to b }) { s, d, mid, oid, pp ->
        val model = s.model(mid)?.takeIf { it.locked } ?: s.models.firstOrNull { it.locked }
        val outfits = s.outfitsOf(model?.id)
        val outfit = outfits.firstOrNull { it.id == oid } ?: outfits.firstOrNull()
        TemplateUseState(s.templates.firstOrNull { it.id == id }, d, model, s.models, outfits, outfit, pp.second, pp.first)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, TemplateUseState())

    init {
        if (c.drafts.templateUse.value.templateId != id) c.drafts.templateUse.value = TemplateUseDraft(id)
        viewModelScope.launch { if (c.repo.state.value.templates.none { it.id == id }) c.repo.template(id) }
    }

    fun edit(f: (TemplateUseDraft) -> TemplateUseDraft) {
        c.drafts.templateUse.update(f)
        if (phase.value == "ready") phase.value = "idle"
        if (c.drafts.templateUse.value.showPrompt) refreshPrompt()
    }
    fun model(id: String) { c.drafts.modelId.value = id; refreshPromptIfShown() }
    fun outfit(id: String) { c.drafts.outfitId.value = id; refreshPromptIfShown() }
    fun shuffle() { edit { it.copy(shuffleSeed = kotlin.random.Random.nextLong(1L shl 31)) }; c.repo.toast("Shuffled · a new pose, angle and framing") }
    fun togglePrompt() { edit { it.copy(showPrompt = !it.showPrompt) } }
    private fun refreshPromptIfShown() { if (c.drafts.templateUse.value.showPrompt) refreshPrompt() }

    /** The prompt view comes from the server: non-owners get the template as one locked line. Debounced while typing. */
    fun refreshPrompt(debounce: Boolean = true) {
        promptJob?.cancel()
        promptJob = viewModelScope.launch {
            if (debounce) delay(250)
            val s = state.value
            val m = s.model ?: return@launch
            val d = c.drafts.templateUse.value
            val (p, _) = c.repo.templatePrompt(id, TemplatePromptRequest(m.id, s.outfit?.id, d.direction.ifBlank { null }, d.shuffleSeed, d.lockSeed))
            prompt.value = p
        }
    }

    fun setProduct(uri: Uri) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val bytes = media.bytes(uri) ?: return@launch
        c.repo.uploadImage(media.displayName(uri), bytes, media.mime(uri))?.let { ref -> edit { it.copy(product = ref) }; c.repo.toast("Product photo added") }
    }

    fun shoot(celebrate: () -> Unit) = viewModelScope.launch {
        val s = state.value
        if (s.phase == "busy") return@launch
        val model = s.model ?: return@launch c.repo.toast("Pick a model with a finished character sheet")
        val d = s.draft
        phase.value = "busy"
        val shots = c.repo.shoot(ShootRequest(model.id, s.outfit?.id ?: "", "", "", templateId = id, direction = d.direction.trim().ifBlank { null },
            shuffleSeed = d.shuffleSeed, lockSeed = d.lockSeed, productImage = d.product?.takeIf { s.t?.acceptsProduct == true }))
        if (shots == null) { phase.value = "idle"; return@launch }
        c.drafts.freshShots.value = shots.size
        c.drafts.galleryTab.value = "tests"
        // Next Shoot draws a new moment unless Lock look is on.
        c.drafts.templateUse.update { if (it.lockSeed) it else it.copy(shuffleSeed = kotlin.random.Random.nextLong(1L shl 31)) }
        phase.value = "ready"
        celebrate()
        c.repo.loadTemplates()
    }
}

@Composable
fun TemplateUseScreen(id: String) {
    val c = LocalContainer.current
    val vm: TemplateUseViewModel = viewModel(key = "use-$id") { TemplateUseViewModel(c, id) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val celebrate = LocalCelebrate.current
    val d = s.draft
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> if (u != null) vm.setProduct(u) }
    LaunchedEffect(d.showPrompt, s.model?.id) { if (d.showPrompt) vm.refreshPrompt(debounce = false) }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(s.t?.name ?: "Template", onBack = { nav.back() }) {
                MoreMenu(listOf(
                    MenuItem("spark", if (d.showPrompt) "Hide prompt" else "Show prompt") { vm.togglePrompt() },
                    MenuItem("grid", "All templates") { nav.go(Routes.TEMPLATES) },
                ))
            }
            Canvas(200.dp) {
                RefImage(s.t?.cover, Modifier.fillMaxSize(), 20)
                Viewfinder()
                Sticker((s.t?.name ?: "template").lowercase().take(24), "yellow", -4f, Modifier.align(Alignment.BottomStart).padding(12.dp))
            }
            BSheet(14.dp) {
                // Shown first when asked for: the prompt view (one locked line for someone else's template).
                if (d.showPrompt) {
                    s.prompt?.let { p -> Field("Final prompt") { TemplatePromptBox(p) } } ?: Tiny("Building the prompt…")
                    s.prompt?.removed?.takeIf { it.isNotEmpty() }?.let { NoteBox("Left out of your direction: ${it.joinToString("; ")}. It would change her identity or add a never-add item.", warn = true) }
                }
                Field("Model") {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        s.models.forEach { md ->
                            val on = md.id == s.model?.id
                            Column(Modifier.width(66.dp).press { if (md.locked) vm.model(md.id) else vm.edit { it }.also { c.repo.toast("${md.name.substringBefore(' ')} needs close-ups first") } },
                                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                val shape = RoundedCornerShape(m.t.r * .6f)
                                Box(Modifier.fillMaxWidth().height(70.dp).let { if (on) it.border(2.dp, m.t.accent, shape) else it }.clip(shape)) {
                                    if (md.cover != null) RefImage(md.slot("face")?.image ?: md.cover, Modifier.fillMaxSize()) else ModelInitial(md, Modifier.fillMaxSize(), 24f)
                                }
                                T(if (md.locked) md.name.substringBefore(' ') else "${md.name.substringBefore(' ')} · draft", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
                            }
                        }
                    }
                }
                Field("Outfit") {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        s.outfits.forEach { o -> OutfitTile(o, o.id == s.outfit?.id, { vm.outfit(o.id) }) }
                        AddOutfitTile({ nav.go(Routes.OUTFIT) })
                    }
                }
                if (s.t?.acceptsProduct == true) Opt("Product photo (optional)", if (d.product == null) "The product becomes the hero of every shot" else "Photo added · tap to replace", d.product != null, "upload",
                    { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                Field("Direction (optional)") {
                    Input(d.direction, { v -> vm.edit { it.copy(direction = v) } }, area = true, placeholder = "How should she be placed? e.g. sitting on the steps, looking back over her shoulder")
                    Tiny("Replaces the template's pose and angle. The rest of the look stays.")
                }
                RowB {
                    Column(Modifier.weight(1f)) { T("Lock look", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny(if (d.lockSeed) "Same seed every shot" else "Off: a new seed and a new moment every shot") }
                    Toggle(d.lockSeed, { vm.edit { it.copy(lockSeed = !it.lockSeed) } })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Cta2("Shuffle", { vm.shuffle() }, Modifier.weight(1f), icon = "retry", height = 46.dp)
                    Cta2(if (d.showPrompt) "Hide prompt" else "Show prompt", { vm.togglePrompt() }, Modifier.weight(1f), icon = "spark", height = 46.dp)
                }
            }
        }
        Dock(tight = true) {
            when (s.phase) {
                "ready" -> Cta("${c.drafts.freshShots.value} shots ready · View in Gallery", { nav.tab(Routes.GALLERY) }, Modifier.weight(1f), icon = "grid")
                "busy" -> Cta("Shooting…", {}, Modifier.weight(1f), busy = true)
                else -> Cta("Shoot 4 · ${studio.muse.core.PhotoPricing.about(studio.muse.core.PhotoPricing.shoot(photoPrices()))}", { vm.shoot(celebrate) }, Modifier.weight(1f), icon = "camera")
            }
        }
    }
}

/** "Scene: …" → "…" (the label column already says it). The identity line keeps her name. */
private val SLOT_PREFIX = Regex("^(Scene|Camera|Light|Pose|Direction|Style|Never add|Seed|Wearing|Product): ")

/** The prompt view for a template shoot: hidden layers show as one locked line for anyone but the template's owner. */
@Composable
fun TemplatePromptBox(p: TemplatePrompt) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        p.slots.forEach { slot: PromptSlotView -> SlotLine(slot.layer, if (slot.locked) slot.text else slot.text.replace(SLOT_PREFIX, ""), slot.locked) }
    }
}

// ======================================================================= Save as template

data class SaveTemplateState(
    val draft: TemplateDraft? = null, val error: String? = null, val name: String = "", val tags: String = "", val public: Boolean = false,
    val pool: Map<String, List<String>> = emptyMap(), val busy: Boolean = false,
)

class SaveTemplateViewModel(private val c: AppContainer, private val shotId: String) : ViewModel() {
    private val _s = MutableStateFlow(SaveTemplateState())
    val state: StateFlow<SaveTemplateState> = _s

    fun load() = viewModelScope.launch {
        val (d, err) = c.repo.templateDraft(shotId)
        _s.update { if (d != null) it.copy(draft = d, name = d.name, tags = d.tags.joinToString(", "), pool = d.variationPool, error = null) else it.copy(error = err) }
    }
    fun edit(f: (SaveTemplateState) -> SaveTemplateState) = _s.update(f)
    fun save(go: (String) -> Unit) = viewModelScope.launch {
        val s = _s.value
        if (s.name.isBlank()) return@launch c.repo.toast("Give it a name")
        _s.update { it.copy(busy = true) }
        val (t, err) = c.repo.createTemplate(CreateTemplateRequest(s.name.trim(), splitTags(s.tags), if (s.public) "public" else "private", variationPool = s.pool, fromShotId = shotId))
        _s.update { it.copy(busy = false, error = err) }
        if (t != null) { c.repo.toast(if (t.public) "Saved · the studio can use it now" else "Saved as a private template"); go(t.id) }
    }
}

@Composable
fun SaveTemplateScreen(shotId: String) {
    val c = LocalContainer.current
    val vm: SaveTemplateViewModel = viewModel(key = "save-$shotId") { SaveTemplateViewModel(c, shotId) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    LaunchedEffect(shotId) { vm.load() }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Save as template", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                val d = s.draft
                if (d == null) {
                    NoteBox(s.error ?: "Reading this photo's look…", icon = if (s.error != null) "lock" else "spark", warn = s.error != null)
                    return@Column
                }
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    val shape = RoundedCornerShape(m.t.r * .6f)
                    Box(Modifier.width(92.dp).height(124.dp).clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }) { RefImage(d.cover, Modifier.fillMaxSize()) }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        T("This photo's look", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                        Tiny("Its style, scene, camera and light become the template, with this photo as the cover. Her identity, outfit, never-add list and seed stay with the model.")
                    }
                }
                Field("Name") { Input(s.name, { v -> vm.edit { it.copy(name = v) } }, placeholder = "e.g. Bathroom mirror") }
                Field("Tags") { Input(s.tags, { v -> vm.edit { it.copy(tags = v) } }, placeholder = "Faceless, Selfie") }
                Field("Who can use it") {
                    Seg(listOf("private" to "Private · only me", "public" to "Public · the studio"), if (s.public) "public" else "private", { v -> vm.edit { it.copy(public = v == "public") } })
                    Tiny(if (s.public) "Everyone in the studio sees the name and cover and can shoot with it. The prompt stays with you." else "Only you can see and use it. You can make it public any time.")
                }
                val layerLines = listOf("style" to d.layers.style, "scene" to d.layers.scene, "camera" to d.layers.camera, "light" to d.layers.light).filter { !it.second.isNullOrBlank() }
                if (layerLines.isNotEmpty()) Field("Prompt layers · only you see these") {
                    val shape = RoundedCornerShape(m.t.r)
                    Column(Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf("style" to d.layers.style, "scene" to d.layers.scene, "camera" to d.layers.camera, "light" to d.layers.light).forEach { (k, v) -> if (!v.isNullOrBlank()) SlotLine(k, v) }
                    }
                }
                PoolEditor(s.pool) { p -> vm.edit { it.copy(pool = p) } }
                s.error?.let { NoteBox(it, warn = true) }
            }
        }
        Dock(tight = true) {
            Cta("Save template", { vm.save { id -> nav.back(); nav.go(Routes.template(id)) } }, Modifier.weight(1f), busy = s.busy, off = s.draft == null)
        }
    }
}

/** A strip of templates for the Photoshoot screen, with "See all". */
@Composable
fun TemplateStrip(templates: List<Template>, onOpen: (Template) -> Unit, onAll: () -> Unit) {
    val m = muse
    RowB { H3("Templates"); T("See all", m.type.tiny.copy(fontWeight = FontWeight.Bold), if (m.isD) m.t.blue else m.t.accent, Modifier.press(onClick = onAll).padding(6.dp)) }
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        templates.take(8).forEach { t -> TemplateCard(t, Modifier.width(112.dp), 140.dp) { onOpen(t) } }
    }
}

