package studio.muse.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.CatalogModel
import studio.muse.app.data.DressUpDraft
import studio.muse.app.data.DressUpRequest
import studio.muse.app.data.EnhanceDraft
import studio.muse.app.data.EnhanceRequest
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Model
import studio.muse.app.data.Sheet
import studio.muse.app.data.StepModel
import studio.muse.app.data.ToolEstimate
import studio.muse.app.data.ToolItem
import studio.muse.app.data.ToolRun
import studio.muse.app.data.ToolsFeatures
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

// Model tools (plans/api.md "Model tools"): Enhance and Dress up for the character sheet (everyone), the image model
// catalog and archived models (owner only). Members never see a model or provider name here.

private fun isOwner(c: AppContainer) = c.repo.demo || c.prefs.value.owner

// ---------------------------------------------------------------- Enhance

data class EnhanceState(val model: Model? = null, val draft: EnhanceDraft = EnhanceDraft(), val run: ToolRun? = null, val tools: ToolsFeatures = ToolsFeatures(),
    val estimate: ToolEstimate? = null)

class EnhanceViewModel(private val c: AppContainer) : ViewModel() {
    private val est = MutableStateFlow<ToolEstimate?>(null)
    val state: StateFlow<EnhanceState> = combine(c.repo.state, c.drafts.modelId, c.drafts.enhance, est) { s, mid, d, e ->
        EnhanceState(s.model(mid) ?: s.models.firstOrNull(), d, d.runId?.let { s.toolRuns[it] }, s.tools, e)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, EnhanceState())

    init { refreshEstimate() }
    private fun req(d: EnhanceDraft) = EnhanceRequest(d.realism, d.upscale, models = d.models.ifEmpty { null })
    fun refreshEstimate() = viewModelScope.launch {
        val id = c.drafts.modelId.value
        est.value = c.repo.enhanceEstimate(id, req(c.drafts.enhance.value)).first
    }
    fun set(f: (EnhanceDraft) -> EnhanceDraft) { c.drafts.enhance.update(f); refreshEstimate() }
    fun start() = viewModelScope.launch {
        val d = c.drafts.enhance.value
        if (d.realism == "off" && d.upscale == "off") return@launch c.repo.toast("Turn on realism or upscale")
        val r = c.repo.startEnhance(c.drafts.modelId.value, req(d)) ?: return@launch
        c.drafts.enhance.update { it.copy(runId = r.id) }
    }
    fun decide(item: ToolItem, keep: Boolean) = viewModelScope.launch { state.value.run?.let { c.repo.decideTool(it.id, item.slot, keep) } }
    fun retry(item: ToolItem) = viewModelScope.launch { state.value.run?.let { c.repo.retryTool(it.id, item.slot) } }
    fun keepAll() = viewModelScope.launch { state.value.run?.let { c.repo.pickTool(it.id, "a") } }
    fun apply(done: () -> Unit) = viewModelScope.launch {
        val r = state.value.run ?: return@launch
        if (c.repo.applyTool(r.id) != null) { c.repo.toast("Character sheet updated · the old one is kept as a version"); c.drafts.enhance.update { it.copy(runId = null) }; done() }
    }
    fun discard() = viewModelScope.launch { state.value.run?.let { c.repo.discardTool(it.id) }; c.drafts.enhance.update { it.copy(runId = null) } }
}

@Composable
fun EnhanceScreen() {
    val c = LocalContainer.current
    val vm: EnhanceViewModel = viewModel { EnhanceViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val run = s.run?.takeIf { it.state == "running" || it.state == "review" }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Enhance", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 130.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (run == null) EnhanceSetup(s, vm, isOwner(c)) else ToolReview(run, s.model, onKeep = { i, k -> vm.decide(i, k) }, onRetry = { vm.retry(it) })
            }
        }
        Dock {
            when {
                run == null -> Cta("Enhance · ${s.estimate?.label ?: "7 images"}", vm::start, Modifier.weight(1f), off = s.estimate == null || s.estimate?.images == 0)
                run.state == "running" -> Cta(run.phase.ifBlank { "Enhancing…" }, {}, Modifier.weight(1f), off = true, busy = true)
                else -> {
                    Cta2("Discard", vm::discard)
                    Cta("Save kept · ${run.kept}", { vm.apply { nav.back() } }, Modifier.weight(1f), off = run.kept == 0)
                }
            }
        }
    }
}

@Composable
private fun EnhanceSetup(s: EnhanceState, vm: EnhanceViewModel, owner: Boolean) {
    val m = muse
    val model = s.model
    T("Makes every photo of ${model?.name?.substringBefore(' ')?.let { "$it's" } ?: "her"} character sheet look like a real phone photo, then sharpens it. Same look on all of them.", m.type.body, m.t.muted)
    SheetStrip(model)
    Field("Realism") {
        Seg(s.tools.enhance.realism.map { it.id to it.label }, s.draft.realism, { v -> vm.set { it.copy(realism = v) } }, Modifier.fillMaxWidth())
    }
    Tiny(when (s.draft.realism) { "subtle" -> "Barely there: skin texture only."; "strong" -> "Most natural skin and light, a little further from the original."; "off" -> "No realism pass."
        else -> "Natural skin texture and light, close to the original." })
    Field("Sharper") {
        Seg(s.tools.enhance.upscale.map { it.id to it.label }, s.draft.upscale, { v -> vm.set { it.copy(upscale = v) } }, Modifier.fillMaxWidth())
    }
    if (owner) OwnerModelLine(listOf("realism", "upscale"), s.draft.models, s.tools.enhance.models?.mapValues { it.value.name } ?: emptyMap())
    NoteBox("${s.estimate?.label ?: "Working out the price…"}. You review every photo before anything changes, and the current sheet is kept as a version you can restore.", icon = "check")
}

/** The sheet's images in a row, in display order. */
@Composable
private fun SheetStrip(model: Model?) {
    val m = muse
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Sheet.SLOTS.forEach { si ->
            val img = model?.slot(si.key)?.image
            Box(Modifier.weight(1f).aspectRatio(3f / 4f).clip(RoundedCornerShape(m.t.r * .4f)).background(m.t.surface2)) { if (img != null) RefImage(img, Modifier.fillMaxSize()) }
        }
    }
}

/** Before / after for every image (and both options for Dress up · Both): Keep, Reject, Retry. */
@Composable
fun ToolReview(run: ToolRun, model: Model?, onKeep: (ToolItem, Boolean) -> Unit, onRetry: (ToolItem) -> Unit, onPick: ((ToolItem, String) -> Unit)? = null) {
    val m = muse
    if (run.state == "running") {
        Bar((run.progress / 100).toFloat(), Modifier.fillMaxWidth())
        Tiny(run.phase)
    } else Tiny("${run.items.count { it.state == "done" }} of ${run.items.size} ready · keep the ones you like")
    run.items.forEach { item ->
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            RowB { Lbl(item.label.ifBlank { Sheet.label(item.slot) }); Spacer(Modifier.weight(1f))
                Tiny(when { item.state == "failed" -> "Didn't work · not charged"; item.decision == "keep" -> "Kept"; item.decision == "reject" -> "Rejected"; else -> "" },
                    color = if (item.decision == "keep") m.t.good else m.t.muted) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ReviewTile("Before", item.before, false, Modifier.weight(1f))
                run.engines.forEach { e ->
                    val label = if (run.kind == "enhance") "After" else if (e == "a") "Option A" else "Option B"
                    val on = item.decision == "keep" && (item.pick ?: "a") == e
                    ReviewTile(label, item.results.of(e), on, Modifier.weight(1f), busy = item.state == "running" || (item.state == "waiting" && run.state == "running"),
                        onClick = if (onPick != null && item.results.of(e) != null) ({ onPick(item, e) }) else null)
                }
            }
            if (run.state == "review" && item.state != "running") Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (item.state == "done" && !run.both) Cta2(if (item.decision == "keep") "Kept" else "Keep", { onKeep(item, true) }, Modifier.weight(1f), icon = "check", height = 40.dp)
                Cta2(if (item.decision == "reject") "Rejected" else "Reject", { onKeep(item, false) }, Modifier.weight(1f), height = 40.dp)
                Cta2("Retry", { onRetry(item) }, Modifier.weight(1f), icon = "retry", height = 40.dp)
            }
        }
    }
}

@Composable
private fun ReviewTile(label: String, img: ImageRef?, on: Boolean, modifier: Modifier, busy: Boolean = false, onClick: (() -> Unit)? = null) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r * .6f)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(shape).background(m.t.surface2).border(if (on) 3.dp else m.t.stroke, if (on) m.t.accent else m.t.line, shape)
            .let { if (onClick != null) it.press(onClick = onClick) else it }.let { if (busy && img == null) it.shimmer() else it }) {
            if (img != null) RefImage(img, Modifier.fillMaxSize())
            if (on) Box(Modifier.align(Alignment.TopEnd).padding(6.dp)) { Pill("Kept", "good") }
        }
        Tiny(label, weight = if (on) FontWeight.Bold else null)
    }
}

/** Owner only: which model each step uses for this run ("Default" = the studio's choice). Tapping opens the catalog. */
@Composable
fun OwnerModelLine(steps: List<String>, chosen: Map<String, String>, defaults: Map<String, String>) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).border(m.t.stroke, m.t.line, RoundedCornerShape(m.t.r)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        RowB { Ic("spark", 14.dp, m.t.muted); Spacer(Modifier.width(6.dp)); Lbl("Model · owner only") }
        steps.forEach { step ->
            RowB(Modifier.press { c.drafts.catalogStep.value = step; c.drafts.catalogFor.value = "run"; nav.go(Routes.CATALOG) }) {
                Tiny(STEP_NAMES[step] ?: step); Spacer(Modifier.weight(1f))
                T(chosen[step] ?: defaults[step]?.let { "Default · $it" } ?: "Default", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                Spacer(Modifier.width(4.dp)); Ic("chev", 12.dp, m.t.muted)
            }
        }
    }
}

val STEP_NAMES = mapOf("shot" to "New shots", "edit" to "Edits", "realism" to "Realism", "upscale" to "Upscale", "dressA" to "Option A", "dressB" to "Option B")

// ---------------------------------------------------------------- Dress up

data class DressUpState(val model: Model? = null, val draft: DressUpDraft = DressUpDraft(), val run: ToolRun? = null, val tools: ToolsFeatures = ToolsFeatures(),
    val estimate: ToolEstimate? = null)

class DressUpViewModel(private val c: AppContainer) : ViewModel() {
    private val est = MutableStateFlow<ToolEstimate?>(null)
    val state: StateFlow<DressUpState> = combine(c.repo.state, c.drafts.modelId, c.drafts.dressUp, est) { s, mid, d, e ->
        DressUpState(s.model(mid) ?: s.models.firstOrNull(), d, d.runId?.let { s.toolRuns[it] }, s.tools, e)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, DressUpState())

    init { refreshEstimate() }
    private fun req(d: DressUpDraft) = DressUpRequest(d.outfitImage, d.name.ifBlank { null }, d.engine, d.models.ifEmpty { null })
    fun refreshEstimate() = viewModelScope.launch { est.value = c.repo.dressUpEstimate(c.drafts.modelId.value, req(c.drafts.dressUp.value)).first }
    fun set(f: (DressUpDraft) -> DressUpDraft) { c.drafts.dressUp.update(f); refreshEstimate() }
    fun upload(uri: Uri) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that image")
        val ref = c.repo.uploadImage(media.displayName(uri), bytes, media.mime(uri)) ?: return@launch
        val name = media.displayName(uri).substringBeforeLast('.').replace(Regex("[_-]+"), " ").trim().take(40)
        c.drafts.dressUp.update { it.copy(outfitImage = ref, name = it.name.ifBlank { name }) }
    }
    fun start() = viewModelScope.launch {
        val d = c.drafts.dressUp.value
        if (d.outfitImage == null) return@launch c.repo.toast("Add the outfit photo first")
        val r = c.repo.startDressUp(c.drafts.modelId.value, req(d)) ?: return@launch
        c.drafts.dressUp.update { it.copy(runId = r.id) }
    }
    fun decide(item: ToolItem, keep: Boolean) = viewModelScope.launch { state.value.run?.let { c.repo.decideTool(it.id, item.slot, keep) } }
    fun pick(item: ToolItem, e: String) = viewModelScope.launch { state.value.run?.let { c.repo.decideTool(it.id, item.slot, true, e) } }
    fun pickAll(e: String) = viewModelScope.launch { state.value.run?.let { c.repo.pickTool(it.id, e) } }
    fun retry(item: ToolItem) = viewModelScope.launch { state.value.run?.let { c.repo.retryTool(it.id, item.slot, it.engines.first()) } }
    fun apply(done: () -> Unit) = viewModelScope.launch {
        val r = state.value.run ?: return@launch
        val res = c.repo.applyTool(r.id, c.drafts.dressUp.value.name.ifBlank { null }) ?: return@launch
        c.repo.toast("Saved as a new outfit · ${res.outfit?.name ?: "Dressed look"}")
        res.outfit?.let { c.drafts.outfitId.value = it.id }
        c.drafts.dressUp.value = DressUpDraft()
        done()
    }
    fun discard() = viewModelScope.launch { state.value.run?.let { c.repo.discardTool(it.id) }; c.drafts.dressUp.update { it.copy(runId = null) } }
}

@Composable
fun DressUpScreen() {
    val c = LocalContainer.current
    val vm: DressUpViewModel = viewModel { DressUpViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val run = s.run?.takeIf { it.state == "running" || it.state == "review" }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) vm.upload(uri) }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Dress up", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 130.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (run == null) DressUpSetup(s, vm, isOwner(c)) { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                else {
                    if (run.both && run.state == "review") Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Cta2("Use all A", { vm.pickAll("a") }, Modifier.weight(1f), height = 40.dp)
                        Cta2("Use all B", { vm.pickAll("b") }, Modifier.weight(1f), height = 40.dp)
                    }
                    ToolReview(run, s.model, onKeep = { i, k -> vm.decide(i, k) }, onRetry = { vm.retry(it) }, onPick = if (run.both) ({ i, e -> vm.pick(i, e) }) else null)
                }
            }
        }
        Dock {
            when {
                run == null -> Cta("Dress up · ${s.estimate?.label?.substringAfterLast("· ") ?: "7 images"}", vm::start, Modifier.weight(1f), off = s.draft.outfitImage == null)
                run.state == "running" -> Cta(run.phase.ifBlank { "Dressing up…" }, {}, Modifier.weight(1f), off = true, busy = true)
                else -> {
                    Cta2("Discard", vm::discard)
                    Cta("Save outfit · ${run.kept}", { vm.apply { nav.back() } }, Modifier.weight(1f), off = run.kept == 0)
                }
            }
        }
    }
}

@Composable
private fun DressUpSetup(s: DressUpState, vm: DressUpViewModel, owner: Boolean, onPick: () -> Unit) {
    val m = muse
    val first = s.model?.name?.substringBefore(' ') ?: "her"
    T("Drop one photo of an outfit (clothes and accessories). $first's whole character sheet is made again wearing it: the full-body photos get the outfit, the close-ups get the jewellery, glasses or hat and the neckline. Face, hair, pose and background stay the same.",
        m.type.body, m.t.muted)
    val shape = RoundedCornerShape(m.t.r)
    Box(Modifier.fillMaxWidth().height(210.dp).clip(shape).background(m.t.surface).dashed(m.t.line, m.t.r, m.t.stroke).press(onClick = onPick), contentAlignment = Alignment.Center) {
        val img = s.draft.outfitImage
        if (img != null) RefImage(img, Modifier.fillMaxSize(), 50)
        else Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Ic("upload", 22.dp, m.t.muted); Tiny("Add the outfit photo")
        }
    }
    Field("Outfit name") { Input(s.draft.name, { v -> vm.set { it.copy(name = v.take(80)) } }, placeholder = "Named after the photo") }
    Field("Look") {
        Seg(s.tools.dressUp.options.map { it.id to it.label }, s.draft.engine, { v -> vm.set { it.copy(engine = v) } }, Modifier.fillMaxWidth())
    }
    Tiny(s.tools.dressUp.options.firstOrNull { it.id == s.draft.engine }?.detail ?: "")
    if (owner) OwnerModelLine(if (s.draft.engine == "both") listOf("dressA", "dressB") else listOf(if (s.draft.engine == "b") "dressB" else "dressA"), s.draft.models,
        s.tools.dressUp.models?.mapValues { it.value.name } ?: emptyMap())
    NoteBox("${s.estimate?.label ?: "Working out the price…"}. Saved as a new outfit you can shoot and film. The character sheet itself never changes.", icon = "check")
}

// ---------------------------------------------------------------- Owner: image models and the catalog

class ImageModelsViewModel(private val c: AppContainer) : ViewModel() {
    val steps = MutableStateFlow<List<StepModel>>(emptyList())
    val error = MutableStateFlow<String?>(null)
    fun load() = viewModelScope.launch { val (v, e) = c.repo.imageModels(); v?.let { steps.value = it.steps }; error.value = e }
    fun reset(step: String) = viewModelScope.launch { c.repo.resetImageModel(step).first?.let { s -> steps.update { l -> l.map { if (it.step == step) s else it } } } }
}

@Composable
fun ImageModelsScreen() {
    val c = LocalContainer.current
    val vm: ImageModelsViewModel = viewModel { ImageModelsViewModel(c) }
    LaunchedEffect(Unit) { vm.load() }
    val steps by vm.steps.collectAsState()
    val err by vm.error.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Image models", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                T("Each step can run on any public Replicate model. Members never see these names: they get your choices.", m.type.body, m.t.muted)
                err?.let { NoteBox(it, warn = true) }
                steps.forEach { s ->
                    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).border(m.t.stroke, m.t.line, RoundedCornerShape(m.t.r)).padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        RowB { Lbl(s.label); Spacer(Modifier.weight(1f)); if (s.isDefault) Pill("Default") else Pill("Changed", "warn") }
                        T(s.name, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                        Tiny("${s.model}${if (!s.official) " · community" else ""}")
                        Tiny(s.priceLine)
                        if (s.warnings.isNotEmpty()) Tiny(s.warnings.joinToString(" · "), color = m.t.warn)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                            Cta2("Change", { c.drafts.catalogStep.value = s.step; c.drafts.catalogFor.value = "settings"; nav.go(Routes.CATALOG) }, Modifier.weight(1f), height = 40.dp)
                            if (!s.isDefault) Cta2("Use default", { vm.reset(s.step) }, Modifier.weight(1f), height = 40.dp)
                        }
                    }
                }
            }
        }
    }
}

class CatalogViewModel(private val c: AppContainer) : ViewModel() {
    val models = MutableStateFlow<List<CatalogModel>>(emptyList())
    val loading = MutableStateFlow(true)
    val error = MutableStateFlow<String?>(null)
    val query = MutableStateFlow("")
    private var job: kotlinx.coroutines.Job? = null
    fun load() { job?.cancel(); job = viewModelScope.launch {
        loading.value = true
        val q = query.value.trim()
        // "owner/name" pasted in full: read that one model.
        val (page, e) = if (Regex("^[\\w.-]+/[\\w.-]+$").matches(q)) c.repo.imageModel(q, c.drafts.catalogStep.value).let { (d, e) -> d?.let { listOf(it.asCatalog()) } to e }
            else c.repo.imageCatalog(c.drafts.catalogStep.value, q.ifBlank { null }).let { (p, e) -> p?.models to e }
        page?.let { models.value = it }; error.value = e; loading.value = false
    } }
    fun search(q: String) { query.value = q }
    fun choose(m: CatalogModel, done: () -> Unit) = viewModelScope.launch {
        if (m.compatible == false) return@launch c.repo.toast("Not compatible: ${m.reasons.joinToString()}")
        val step = c.drafts.catalogStep.value
        if (c.drafts.catalogFor.value == "run") {
            val put: (Map<String, String>) -> Map<String, String> = { it + (step to m.id) }
            if (step == "realism" || step == "upscale") c.drafts.enhance.update { it.copy(models = put(it.models)) }
            else if (step == "dressA" || step == "dressB") c.drafts.dressUp.update { it.copy(models = put(it.models)) }
            else c.drafts.shoot.update { it.copy(models = put(it.models)) }
            c.repo.toast("This run uses ${m.id}")
            return@launch done()
        }
        val (v, e) = c.repo.setImageModel(step, m.id)
        if (v != null) { c.repo.toast("${v.label} now runs on ${v.name}"); done() } else e?.let { c.repo.toast(it) }
    }
}

@Composable
fun CatalogScreen() {
    val c = LocalContainer.current
    val vm: CatalogViewModel = viewModel { CatalogViewModel(c) }
    val step by c.drafts.catalogStep.collectAsState()
    val q by vm.query.collectAsState()
    // Searches as the owner types (a pasted owner/name reads that one model).
    LaunchedEffect(step, q) { if (q.isNotBlank()) kotlinx.coroutines.delay(400); vm.load() }
    val list by vm.models.collectAsState()
    val loading by vm.loading.collectAsState()
    val err by vm.error.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Choose a model", onBack = { nav.back() })
            Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Lbl("${STEP_NAMES[step] ?: step}${if (c.drafts.catalogFor.value == "run") " · this run only" else " · studio default"}")
                Input(q, vm::search, placeholder = "Search, or paste owner/model")
            }
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                err?.let { e -> item(key = "error", contentType = "note") { NoteBox(e, warn = true) } }
                if (loading && list.isEmpty()) items(4, key = { "shimmer$it" }, contentType = { "shimmer" }) { Box(Modifier.fillMaxWidth().height(86.dp).clip(RoundedCornerShape(m.t.r)).background(m.t.surface2).shimmer()) }
                items(list, contentType = { "model" }) { cm -> CatalogRow(cm) { vm.choose(cm) { nav.back() } } }
                if (!loading && list.isEmpty() && err == null) item(key = "none", contentType = "note") { Tiny("No models found") }
            }
        }
    }
}

@Composable
private fun CatalogRow(cm: CatalogModel, onClick: () -> Unit) {
    val m = muse
    val off = cm.compatible == false
    val shape = RoundedCornerShape(m.t.r)
    Column(Modifier.fillMaxWidth().clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape).press(onClick = onClick).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp)) {
        RowB {
            T(cm.name.ifBlank { cm.id }, m.type.body.copy(fontWeight = FontWeight.Bold), if (off) m.t.muted else m.t.ink, maxLines = 1)
            Spacer(Modifier.weight(1f))
            when (cm.compatible) { true -> Pill("Compatible", "good"); false -> Pill("Not compatible", "warn"); null -> Pill("Not checked") }
        }
        Tiny("${cm.owner} · ${cm.runsLabel}${if (!cm.official) " · community" else ""}")
        if (cm.description.isNotBlank()) Tiny(cm.description, color = if (off) m.t.muted else m.t.ink)
        Tiny(cm.priceLine, weight = FontWeight.Bold)
        if (off) Tiny("Not compatible: ${cm.reasons.joinToString(", ")}", color = m.t.warn)
        else if (cm.warnings.isNotEmpty()) Tiny(cm.warnings.joinToString(" · "), color = m.t.muted)
    }
}

// ---------------------------------------------------------------- Owner: archived models

@Composable
fun ArchivedModelsScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    var list by remember { mutableStateOf<List<Model>?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { list = c.repo.archivedModels() ?: emptyList() }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Archived models", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                T("Archived models are hidden everywhere. Their outfits, photos, videos and history are kept.", m.type.body, m.t.muted)
                val l = list
                if (l == null) Box(Modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(m.t.r)).background(m.t.surface2).shimmer())
                else if (l.isEmpty()) Tiny("No archived models")
                else l.forEach { md ->
                    RowB(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).padding(12.dp)) {
                        ModelInitial(md); Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) { T(md.name, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("${md.niche} · ${md.outfitIds.size} outfits") }
                        Cta2("Restore", { scope.launch { if (c.repo.archiveModel(md.id, false) != null) { list = l - md; c.repo.toast("${md.name} is back") } } }, height = 40.dp)
                    }
                }
            }
        }
    }
}
