package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.data.ShootDraft
import studio.muse.app.data.ShootPreview
import studio.muse.app.data.ShootRef
import studio.muse.app.data.FakePromptLibrary
import studio.muse.app.data.PromptSlotView
import studio.muse.app.ui.LocalCelebrate
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.core.PromptEngine
import studio.muse.app.ui.theme.muse

val SCENES = listOf("Rooftop · golden hour", "Bedroom mirror", "Café window", "Beach noon", "City night")
val LIGHTS = listOf("Golden hour", "Overcast", "Ring light", "Window light", "Flash", "Neon night")
val GRADES = listOf("Phone-natural", "Warm film", "Editorial", "Muted")

data class ShootState(
    val draft: ShootDraft = ShootDraft(),
    val model: Model? = null,
    val models: List<Model> = emptyList(),
    val outfits: List<Outfit> = emptyList(),
    val outfit: Outfit? = null,
    /** The final prompt, images and price: from the server (POST /v1/shoots/preview), else the app's own fallback engine. */
    val preview: ShootPreview? = null,
    /** idle | busy | ready */
    val phase: String = "idle",
    /** A reference image is being uploaded. */
    val uploading: Boolean = false,
    /** The preview is the app's own because the server couldn't be reached (never in Demo mode). */
    val local: Boolean = false,
)

class ShootViewModel(private val c: AppContainer) : ViewModel() {
    private val phase = MutableStateFlow("idle")
    private val preview = MutableStateFlow<ShootPreview?>(null)
    private val uploading = MutableStateFlow(false)
    /** The last preview request failed (an older server, or offline): the app's own version is shown, with a note. */
    private val previewFailed = MutableStateFlow(false)
    /** Bumped by `prompts` events (the owner saved or reset a prompt), so the preview refetches with the new wording. */
    private val promptsRev = MutableStateFlow(0)
    private data class Base(val d: ShootDraft, val model: Model?, val models: List<Model>, val outfits: List<Outfit>, val outfit: Outfit?, val lora: studio.muse.app.data.Lora?,
        val prices: studio.muse.core.PhotoPrices)
    private val base = combine(c.repo.state, c.drafts.shoot, c.drafts.modelId, c.drafts.outfitId) { s, d, mid, oid ->
        val model = s.model(mid)?.takeIf { it.locked } ?: s.models.firstOrNull { it.locked }
        val outfits = s.outfitsOf(model?.id)
        Base(d, model, s.models, outfits, outfits.firstOrNull { it.id == oid } ?: outfits.firstOrNull(), model?.let { s.loras[it.id] }, s.photo)
    }
    val state: StateFlow<ShootState> = combine(base, preview, phase, uploading, previewFailed) { b, p, ph, up, failed ->
        ShootState(b.d, b.model, b.models, b.outfits, b.outfit, p ?: b.model?.let { localPreview(it, b.outfit, b.d, b.lora, b.prices) }, ph, up,
            local = p == null && failed && b.model != null && !c.repo.demo)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ShootState())

    init {
        viewModelScope.launch { c.repo.live.collect { ev -> if (ev.type == "prompts") promptsRev.update { it + 1 } } }
        // The server builds the prompt from the studio's prompt library: fetch it now, then again ~300 ms after the last change
        // (collectLatest cancels the wait when another change comes in).
        viewModelScope.launch {
            var first = true
            combine(base.map { b -> b.model?.let { m -> b.d.request(m.id, b.outfit?.id ?: "") } }, promptsRev) { req, rev -> req to rev }
                .distinctUntilChanged().collectLatest { (req, _) ->
                    if (req == null) { preview.value = null; return@collectLatest }
                    if (!first) delay(300)
                    first = false
                    val p = c.repo.previewShoot(req)
                    preview.value = p
                    previewFailed.value = p == null
                }
        }
    }

    /** Templates for the strip on the Model tool (loaded once). */
    val templates: StateFlow<List<studio.muse.app.data.Template>> = c.repo.state.map { it.templates }.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    init { viewModelScope.launch { if (c.repo.state.value.templates.isEmpty()) c.repo.loadTemplates(quiet = true) } }

    fun edit(f: (ShootDraft) -> ShootDraft) { c.drafts.shoot.update(f); if (phase.value == "ready") phase.value = "idle" }
    fun outfit(id: String) { c.drafts.outfitId.value = id }
    /** No model ready: a new one, or the first draft's character sheet. */
    fun fixModel(nav: studio.muse.app.ui.Nav) {
        val draft = c.repo.state.value.models.firstOrNull() ?: return nav.go(Routes.CREATE1)
        c.drafts.modelId.value = draft.id
        nav.go(Routes.CREATE3)
    }
    /** Shoot another (locked) model: her first outfit comes with her. */
    fun model(id: String) {
        if (c.drafts.modelId.value == id) return
        c.drafts.modelId.value = id
        c.repo.state.value.outfitsOf(id).firstOrNull()?.let { c.drafts.outfitId.value = it.id }
        if (phase.value == "ready") phase.value = "idle"
    }
    fun resetCamera() = edit { it.copy(shot = "Medium", lens = 35, aperture = "f/2.8") }
    fun toast(s: String) = c.repo.toast(s)

    /** Adds a reference image (uploaded first, POST /v1/uploads/images). It starts on the first guide the others don't use yet. */
    fun addRef(uri: android.net.Uri) = viewModelScope.launch {
        if (uploading.value) return@launch
        if (state.value.draft.refs.size >= ShootRef.MAX) return@launch toast("Up to ${ShootRef.MAX} reference images")
        val media = c.media ?: return@launch
        uploading.value = true
        try {
            val bytes = media.bytes(uri) ?: return@launch toast("Couldn't read that image")
            val ref = c.repo.uploadImage(media.displayName(uri), bytes, media.mime(uri)) ?: return@launch
            edit { d -> if (d.refs.size >= ShootRef.MAX) d else d.copy(refs = d.refs + ShootRef(ref, listOf(ShootRef.defaultGuide(d.refs)))) }
        } finally { uploading.value = false }
    }
    /** Pose & framing / Look & colour / Scene: at least one stays on. */
    fun toggleGuide(i: Int, guide: String) = edit { d ->
        val r = d.refs.getOrNull(i) ?: return@edit d
        val next = r.toggled(guide) ?: run { toast("Keep at least one on: pose, look or scene"); return@edit d }
        d.copy(refs = d.refs.toMutableList().also { it[i] = next })
    }
    fun removeRef(i: Int) = edit { d -> d.copy(refs = d.refs.filterIndexed { k, _ -> k != i }) }

    /** Sends the choices (the server builds the prompt), or the user's own text on "Edit as text". */
    fun shoot(celebrate: () -> Unit) = viewModelScope.launch {
        val s = state.value
        if (s.phase == "busy") return@launch
        val model = s.model ?: return@launch c.repo.toast(NO_READY_MODEL)
        if (s.uploading) return@launch toast("Wait a moment · the reference photo is still uploading")
        phase.value = "busy"
        val shots = c.repo.shoot(s.draft.request(model.id, s.outfit?.id ?: ""))
        if (shots == null) { phase.value = "idle"; return@launch }
        c.drafts.freshShots.value = shots.size
        c.drafts.galleryTab.value = "tests"
        phase.value = "ready"
        celebrate()
    }

    companion object {
        /** The offline fallback (until the server's preview arrives): the app's own engine, checked against the server's fixture (shoot_prompt_fixture.json). */
        fun localPreview(m: Model, o: Outfit?, d: ShootDraft, lora: studio.muse.app.data.Lora? = null, prices: studio.muse.core.PhotoPrices = studio.muse.core.PhotoPrices()): ShootPreview =
            FakePromptLibrary.shootPreview(FakeMuseApi.identity(m, lora), o?.name, d.request(m.id, o?.id ?: ""), prices)
    }
}

@Composable
fun ShootScreen() {
    val c = LocalContainer.current
    val vm: ShootViewModel = viewModel { ShootViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val celebrate = LocalCelebrate.current
    val d = s.draft
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Photoshoot", onBack = { nav.back() }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                T("Templates", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.link, Modifier.press { nav.go(Routes.TEMPLATES) }.padding(8.dp))
                MoreMenu(listOf(
                    MenuItem("grid", "Templates") { nav.go(Routes.TEMPLATES) },
                    MenuItem("spark", "Show prompt") { vm.edit { it.copy(tool = "spark") } },
                    MenuItem("retry", "Reset camera") { vm.resetCamera() },
                    MenuItem("model", "Change model") { vm.edit { it.copy(tool = "model") } },
                ))
                }
            }
            Canvas(220.dp) {
                RefImage(s.outfit?.angles?.getOrNull(1) ?: s.outfit?.front, Modifier.fillMaxSize(), 20)
                Viewfinder()
                if (m.isB) Readout("${d.lens}MM · ${d.aperture.uppercase()}", Modifier.padding(start = 14.dp, top = 12.dp))
                Sticker((d.scene ?: PromptEngine.DEFAULT_SCENE).lowercase().take(24), "yellow", -4f, Modifier.align(Alignment.BottomStart).padding(12.dp))
            }
            ToolStrip(SHOOT_TOOLS, d.tool) { k -> vm.edit { it.copy(tool = k) } }
            BSheet(14.dp) {
                // A new studio (or only drafts): say why there's nothing to shoot, and where to fix it.
                if (s.model == null && d.tool != "model") NoModelNote(s.models.isEmpty()) { vm.fixModel(nav) }
                when (d.tool) {
                    "spark" -> {
                        RowB { H3("Prompt"); Tiny("Built from your choices") }
                        Field("Your direction") { Input(d.direction, { v -> vm.edit { it.copy(direction = v) } }, area = true, placeholder = "e.g. laughing mid-step, hair blowing, holding an iced coffee") }
                        RowB {
                            Column(Modifier.weight(1f)) {
                                T("Presets", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                                Tiny(if (d.presets) "Adds scene, camera, light, style and never-add lines" else "Off: only her identity, outfit, your direction and references are sent")
                            }
                            Toggle(d.presets, { vm.edit { it.copy(presets = !it.presets) } })
                        }
                        RowB {
                            Column(Modifier.weight(1f)) { T("Lock look", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("Same seed, so retakes stay consistent") }
                            Toggle(d.lockSeed, { vm.edit { it.copy(lockSeed = !it.lockSeed) } })
                        }
                        // Owner only: run this shoot on another model (members never see model names).
                        if (c.repo.demo || c.prefs.value.owner) OwnerModelLine(listOf("shot"), d.models, emptyMap())
                        s.preview?.let { p ->
                            if (d.promptText != null) {
                                Field("Final prompt · your text") {
                                    Input(d.promptText, { v -> vm.edit { it.copy(promptText = v) } }, area = true, placeholder = "The whole prompt, exactly as it will be sent")
                                }
                                Tiny("Sent exactly as written. Scene, camera, light and direction choices are ignored until you go back to the built prompt.")
                            } else Field("Final prompt") { PromptBox(p.slots) }
                            if (p.removed.isNotEmpty() && d.promptText == null) NoteBox("Left out of your direction: ${p.removed.joinToString("; ")}. It would change her identity or add a never-add item.", warn = true)
                            if (s.local) Tiny("Can't reach the server, so this is the app's own version. The server's wording applies when you shoot.")
                            val clip = LocalClipboardManager.current
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Cta2("Copy", { clip.setText(AnnotatedString(d.promptText ?: p.text)); vm.toast("Prompt copied") }, Modifier.weight(1f))
                                if (d.promptText == null) Cta2("Edit as text", { vm.edit { it.copy(promptText = p.text) } }, Modifier.weight(1f))
                                else Cta2("Use built prompt", { vm.edit { it.copy(promptText = null) } }, Modifier.weight(1f))
                            }
                        }
                    }
                    "camera" -> {
                        RowB { H3("Camera"); T("Reset", m.type.tiny, m.link, Modifier.press { vm.resetCamera() }.padding(6.dp)) }
                        Field("Shot") { Seg(listOf("Close", "Medium", "Full", "Wide").map { it to it }, d.shot, { v -> vm.edit { it.copy(shot = v) } }) }
                        Field("Lens · ${d.lens}mm") { ChipRow(listOf("16", "24", "35", "50", "85"), d.lens.toString(), { v -> vm.edit { it.copy(lens = v.toInt()) } }) { "${it}mm" } }
                        Field("Aperture") { ChipRow(listOf("f/1.4", "f/2.8", "f/5.6", "f/11"), d.aperture, { v -> vm.edit { it.copy(aperture = v) } }) }
                    }
                    "light" -> {
                        H3("Light")
                        ChipRow(LIGHTS, d.light, { v -> vm.edit { it.copy(light = v) } })
                        Field("Grade") { ChipRow(GRADES, d.grade ?: PromptEngine.DEFAULT_GRADE, { v -> vm.edit { it.copy(grade = v) } }) }
                    }
                    "bg" -> {
                        H3("Scene")
                        ChipRow(SCENES, if (d.sceneCustom.isNotBlank()) null else (d.scene ?: PromptEngine.DEFAULT_SCENE), { v -> vm.edit { it.copy(scene = v, sceneCustom = "") } })
                        Field("Or describe your own") {
                            Input(d.sceneCustom, { v -> vm.edit { it.copy(sceneCustom = v, scene = v.ifBlank { null }) } }, area = true, placeholder = "e.g. sunlit rooftop bar, string lights, city skyline")
                        }
                        val pick = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) vm.addRef(uri) }
                        ReferencesPanel(d.refs, s.preview, s.uploading, onAdd = { pick.launch(androidx.activity.result.PickVisualMediaRequest(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                            onToggle = vm::toggleGuide, onRemove = vm::removeRef)
                    }
                    "outfit" -> {
                        H3("Outfit")
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            s.outfits.forEach { o -> OutfitTile(o, o.id == s.outfit?.id, { vm.outfit(o.id) }) }
                            AddOutfitTile({ nav.go(Routes.OUTFIT) })
                        }
                    }
                    else -> {
                        val templates by vm.templates.collectAsState()
                        if (templates.isNotEmpty()) TemplateStrip(templates, { t -> nav.go(Routes.template(t.id)) }, { nav.go(Routes.TEMPLATES) })
                        H3("Model")
                        if (s.model == null) NoModelNote(s.models.isEmpty()) { vm.fixModel(nav) }
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            s.models.forEach { md ->
                                val on = md.id == s.model?.id
                                Column(Modifier.width(74.dp).press { if (md.locked) vm.model(md.id) else vm.toast("${md.name.substringBefore(' ')} needs close-ups first") }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    val shape = RoundedCornerShape(m.t.r * .6f)
                                    Box(Modifier.fillMaxWidth().heightIn(min = 78.dp, max = 78.dp).let { if (on) it.border(2.dp, m.t.accent, shape) else it }.clip(shape)) {
                                        if (md.cover != null) RefImage(md.slot("face")?.image ?: md.cover, Modifier.fillMaxSize()) else ModelInitial(md, Modifier.fillMaxSize(), 26f)
                                    }
                                    Tiny(if (md.locked) md.name.substringBefore(' ') else "${md.name.substringBefore(' ')} · draft", maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        Dock(tight = true) {
            when (s.phase) {
                "ready" -> Cta("${c.drafts.freshShots.value} shots ready · View in Gallery", { nav.tab(Routes.GALLERY) }, Modifier.weight(1f), icon = "grid")
                "busy" -> Cta("Shooting…", {}, Modifier.weight(1f), busy = true)
                else -> Cta(if (s.model == null) "Shoot 4" else "Shoot 4 · ${s.preview?.estimateLabel?.ifBlank { null } ?: studio.muse.core.PhotoPricing.about(studio.muse.core.PhotoPricing.shoot(photoPrices()))}", { vm.shoot(celebrate) }, Modifier.weight(1f), off = s.model == null)
            }
        }
    }
}

/** Shown wherever there's no model ready to shoot (real studios start empty; drafts need their close-ups). */
const val NO_READY_MODEL = "No model is ready yet · finish a character sheet first"

@Composable
private fun NoModelNote(noModels: Boolean, onFix: () -> Unit) {
    NoteBox(if (noModels) "No models yet. Create one, then come back to shoot her." else "None of your models is ready yet. Add her close-ups to finish the character sheet.", icon = "model")
    Cta2(if (noModels) "New model" else "Finish character sheet", onFix, Modifier.fillMaxWidth(), icon = if (noModels) "plus" else "grid", height = 46.dp)
}

@Composable
private fun Tiny(text: String, maxLines: Int) = T(text, muse.type.tiny.copy(fontSize = 11.5.sp), muse.t.muted, maxLines = maxLines)

/** The server's final prompt by slot (the label is the layer; reference lines are "REF"). */
@Composable
fun PromptBox(slots: List<PromptSlotView>) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        slots.forEach { slot ->
            Row {
                T(if (slot.layer == "reference") "REF" else slot.layer.uppercase(), m.type.mono.copy(fontSize = 10.sp, letterSpacing = .08.em), m.t.muted, Modifier.width(74.dp))
                T(slot.text.replaceFirst(Regex("^[A-Za-z ]+: "), ""), m.type.body.copy(fontSize = 12.5.sp, lineHeight = 17.sp), m.t.ink, Modifier.weight(1f))
            }
        }
    }
}

/**
 * Shoot → Scene (and template shoots): up to 3 reference images, each with what it guides (at least one on), "Image n" / "Not sent"
 * from the server's preview, and remove. Her face, body and outfit never come from them.
 */
@Composable
fun ReferencesPanel(refs: List<ShootRef>, preview: ShootPreview?, uploading: Boolean, onAdd: () -> Unit, onToggle: (Int, String) -> Unit, onRemove: (Int) -> Unit) {
    val m = muse
    RowB { H3("References"); Tiny("${refs.size}/${ShootRef.MAX}") }
    Tiny("Optional · copy a pose, a look or a place from up to ${ShootRef.MAX} photos. Her face, body, hair and outfit always come from her own photos.")
    refs.forEachIndexed { i, r ->
        val shape = RoundedCornerShape(m.t.r * .6f)
        val sent = preview?.refs?.getOrNull(i)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.width(64.dp).heightIn(min = 84.dp, max = 84.dp).clip(shape).border(if (m.isD) 2.dp else m.t.stroke, m.t.line, shape)) {
                RefImage(r.image, Modifier.fillMaxSize())
                if (sent != null) T(sent.badge, m.type.mono.copy(fontSize = 9.5.sp, fontWeight = FontWeight.Bold), androidx.compose.ui.graphics.Color.White,
                    Modifier.align(Alignment.BottomStart).padding(4.dp).clip(RoundedCornerShape(4.dp))
                        .background(if (sent.dropped) m.t.warn.copy(alpha = .9f) else androidx.compose.ui.graphics.Color.Black.copy(alpha = .6f)).padding(horizontal = 5.dp, vertical = 2.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                RowB {
                    T("Reference ${i + 1}", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                    T("Remove", m.type.tiny, m.link, Modifier.press { onRemove(i) }.padding(4.dp))
                }
                FlowRow(hGap = 6.dp, vGap = 6.dp) { ShootRef.GUIDES.forEach { (id, label) -> Chip(label, id in r.guides, { onToggle(i, id) }) } }
            }
        }
    }
    preview?.takeIf { it.droppedRefs > 0 }?.let { p ->
        NoteBox("This shoot can take only ${p.images} images in all, so ${if (p.droppedRefs == 1) "1 reference isn't" else "${p.droppedRefs} references aren't"} sent.", warn = true)
    }
    if (refs.size < ShootRef.MAX) Cta2(if (uploading) "Adding…" else "Add reference photo", { if (!uploading) onAdd() }, Modifier.fillMaxWidth(), icon = "plus", height = 46.dp)
}

