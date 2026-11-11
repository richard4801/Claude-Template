package studio.muse.app.ui.screens.suite.composer

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import studio.muse.app.data.ImageRef
import studio.muse.app.data.PhotoEstimate
import studio.muse.app.data.PhotoRequest
import studio.muse.app.data.ShootRef
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.Take
import studio.muse.app.data.Template
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.ComposerRigRow
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse

// AI suite · the Photo tool's views (workstream 3). Built to plans/design-direction.md: the picture leads, sentence-case
// labels under each tile, one selection mark, tone instead of boxes, and one filled button on the screen (Generate · price,
// which stays the composer's own). Theme tokens only: canvas = t.bg, raised = t.surface, field = t.surface2, ink2 = t.muted,
// hairline = t.line, action = t.cta.

/** What the composer reads from the Photo tool: its draft, the estimate (in the bar's shape) and Generate. */
class PhotoUi(
    val draft: PhotoDraft,
    val request: PhotoRequest?,
    /** The estimate mapped for the bar and the rig row (null until it arrives). */
    val est: SuiteEstimate?,
    val raw: PhotoEstimate?,
    /** Why the estimate failed, or what stops Generate (uploads, a run in progress). */
    val error: String?,
    val busy: Boolean,
    val setCount: (Int) -> Unit,
    /** Owner only (WS7): pin an image model, null = the studio's. */
    val setImageModel: (String?) -> Unit = {},
    val generate: () -> Unit,
) {
    /** The notes the estimate gave ("Movement doesn’t apply to photos", "The preset sets its own camera and light"). */
    val notes: List<String> get() = raw?.warnings.orEmpty()
}

/** The Photo tool's state for [d] (null on other tools): its estimate ~300 ms after the choices stop changing. */
@Composable
fun rememberPhotoTool(d: ComposerDraft): PhotoUi? {
    if (d.tool != ComposerTool.PHOTO) return null
    val c = LocalContainer.current
    val nav = LocalNav.current
    val store = c.suite.photo
    val p by store.draft.collectAsState()
    val busy by store.busy.collectAsState()
    val scope = rememberCoroutineScope()
    val req = PhotoComposer.request(d, p)
    val est = produceState<Pair<PhotoEstimate?, String?>>(null to null, req) {
        if (req == null) { value = null to null; return@produceState }
        delay(300)
        value = store.estimate(req)
    }.value
    val problem = PhotoComposer.problem(d, p, busy) // ComposerModel.problem no longer asks for a character on Photo
    return PhotoUi(p, req, est.first?.let { PhotoComposer.asEstimate(it) }, est.first, problem ?: est.second, busy, store::setCount, store::setImageModel) {
        val r = req ?: return@PhotoUi
        scope.launch { store.generate(r)?.firstOrNull()?.let { nav.go(Routes.result(it.id)) } }
    }
}

/** Radii by hierarchy (direction §4): container > control > chip, per theme. */
private object PhotoRadii {
    fun container(id: ThemeId): Dp = when (id) { ThemeId.A -> 4.dp; ThemeId.B -> 14.dp; ThemeId.C -> 24.dp; ThemeId.D -> 16.dp }
    fun control(id: ThemeId): Dp = when (id) { ThemeId.A -> 2.dp; ThemeId.B -> 10.dp; ThemeId.C -> 16.dp; ThemeId.D -> 12.dp }
    fun chip(id: ThemeId): Dp = when (id) { ThemeId.A -> 2.dp; ThemeId.B -> 8.dp; ThemeId.C -> 12.dp; ThemeId.D -> 999.dp }
}

@Composable private fun heading() = muse.type.body.copy(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
@Composable private fun label() = muse.type.body.copy(fontSize = 14.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium)
@Composable private fun caption() = muse.type.body.copy(fontSize = 13.sp, lineHeight = 18.sp)

/**
 * Character, Outfit, Product (optional) and References (optional): a picture tile each, its sentence-case name under it.
 * Character and Outfit open the character picker (her outfits are in it); Product and References add a photo.
 */
@Composable
fun PhotoSlotRow(ui: ComposerUi, wide: Boolean) {
    val c = LocalContainer.current
    val store = c.suite.photo
    val p by store.draft.collectAsState()
    val scope = rememberCoroutineScope()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val kind = pendingKind.value ?: return@rememberLauncherForActivityResult
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val media = c.media ?: return@launch c.repo.toast("Couldn't read that photo")
            val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that photo")
            store.upload(kind, media.displayName(uri), bytes, media.mime(uri).takeIf { it.startsWith("image/") } ?: "image/jpeg")
        }
    }
    fun add(kind: String) { pendingKind.value = kind; pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
    val outfit = ui.outfits.firstOrNull { it.id == ui.d.characterOutfit }
    val tile = if (wide) Modifier.width(104.dp) else Modifier
    val aspect = if (wide) .8f else 1f
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(if (wide) 12.dp else 8.dp)) {
        val w = if (wide) tile else Modifier.weight(1f)
        PhotoSlot(w, "Character", ui.lead?.name?.substringBefore(' ') ?: "Pick one", ui.lead?.cover, optional = false, aspect = aspect,
            onClick = { ui.open(ComposerSheet(SheetKind.CHARACTER)) })
        PhotoSlot(w, "Outfit", outfit?.name ?: if (ui.lead == null) "After a character" else "Pick one", outfit?.front, optional = false, aspect = aspect,
            enabled = ui.lead != null, onClick = { ui.open(ComposerSheet(SheetKind.CHARACTER)) })
        PhotoSlot(w, "Product", if (p.uploading == "product") "Uploading…" else if (p.product != null) "Added" else "Optional", p.product, optional = true, aspect = aspect,
            onClick = { if (p.product == null) add("product") }, onClear = if (p.product != null) store::clearProduct else null)
        PhotoSlot(w, "References", when { p.uploading == "ref" -> "Uploading…"; p.refs.isEmpty() -> "Optional"; else -> "${p.refs.size} of ${ShootRef.MAX}" },
            p.refs.firstOrNull()?.image, optional = true, aspect = aspect, onClick = { ui.open(ComposerSheet(SheetKind.REFERENCES)) })
    }
}

/** The picker launcher's target ("product" | "ref"), kept outside composition so a recreated launcher still knows it. */
private val pendingKind = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)

/** One slot: a 4:5 picture (field tone when empty, with a plus), then its name and a caption line. */
@Composable
private fun PhotoSlot(modifier: Modifier, name: String, caption: String, image: ImageRef?, optional: Boolean, enabled: Boolean = true, aspect: Float = .8f,
                      onClick: () -> Unit, onClear: (() -> Unit)? = null) {
    val m = muse
    val shape = RoundedCornerShape(PhotoRadii.container(m.id))
    Column(modifier.alpha(if (enabled) 1f else .5f).press(enabled = enabled, onClick = onClick)
        .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "$name${if (optional) ", optional" else ""}: $caption" },
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(aspect).clip(shape).background(m.t.surface2).let { if (image != null && !m.t.dark) it.border(1.dp, m.t.line, shape) else it },
            contentAlignment = Alignment.Center) {
            if (image != null) RefImage(image, Modifier.fillMaxSize(), 20) else SIc("plus", 20.dp, m.t.muted)
            if (onClear != null) Box(Modifier.align(Alignment.TopEnd).size(48.dp).press(onClick = onClear).semantics { contentDescription = "Remove $name"; role = Role.Button },
                contentAlignment = Alignment.Center) {
                Box(Modifier.size(24.dp).clip(RoundedCornerShape(999.dp)).background(Color(0x99141210)), contentAlignment = Alignment.Center) { SIc("close", 12.dp, Color(0xFFF8F5EF)) }
            }
        }
        Column {
            // The name never shares its line, so "References" isn't cut at 360 dp; an empty optional slot says "Optional" under it.
            T(name, label(), m.t.ink, maxLines = 1)
            T(caption, caption(), m.t.muted, maxLines = 1)
        }
    }
}

/**
 * Photo presets: the studio's photo templates (GET /v1/templates). Picking one sends `presetId`; the preset brings its own
 * camera and light. "All templates" opens the library where they're made and edited.
 */
@Composable
fun PhotoPresets(wide: Boolean, modifier: Modifier = Modifier) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val st by c.repo.state.collectAsState()
    val p by c.suite.photo.draft.collectAsState()
    LaunchedEffect(Unit) { if (c.repo.state.value.templates.isEmpty()) c.repo.loadTemplates(quiet = true) }
    val templates = st.templates
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("Presets", heading(), m.t.ink, Modifier.weight(1f), maxLines = 1)
            Box(Modifier.heightIn(min = 48.dp).press { nav.go(Routes.TEMPLATES) }.semantics { role = Role.Button }.padding(horizontal = 4.dp), contentAlignment = Alignment.CenterEnd) {
                T("All templates", label(), m.link, maxLines = 1)
            }
        }
        if (templates.isEmpty()) {
            T(if (st.loaded) "No photo templates yet · save one from any photo" else "Loading presets…", caption(), m.t.muted)
            return@Column
        }
        val w = if (wide) 132.dp else 112.dp
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            templates.forEach { t -> PresetTile(t, t.id == p.presetId, w) { c.suite.photo.pickPreset(t.id) } }
        }
        if (p.presetId != null) T("The preset sets its own camera and light · tap it again to go back to your chips", caption(), m.t.muted, maxLines = 2)
    }
}

@Composable
private fun PresetTile(t: Template, on: Boolean, w: Dp, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(PhotoRadii.container(m.id))
    val mark = if (m.isD) m.t.ink else m.t.accent
    Column(Modifier.width(w).press(onClick = onClick).semantics(mergeDescendants = true) { selected = on; role = Role.Button; contentDescription = "Preset ${t.name}" },
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(.8f).clip(shape).background(m.t.surface2).let { if (on) it.border(2.dp, mark, shape) else it }) {
            RefImage(t.cover, Modifier.fillMaxSize(), 20)
        }
        T(t.name, label(), if (on) m.t.ink else m.t.ink, maxLines = 1)
    }
}

/**
 * The stills in the library, newest first: old Photoshoot shots and Photo takes alike. While a run is going, tiles shaped
 * like the photos coming stand first. Empty: what appears here.
 */
@Composable
fun PhotoRecent(ui: ComposerUi, takes: List<Take>, wide: Boolean, modifier: Modifier = Modifier) {
    val m = muse
    val nav = LocalNav.current
    val shape = RoundedCornerShape(PhotoRadii.container(m.id))
    val stills = PhotoComposer.recent(takes)
    val running = ui.photo?.busy == true
    val h = if (wide) 178.dp else 160.dp
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("Recent photos", heading(), m.t.ink, maxLines = 1)
        if (stills.isEmpty() && !running) {
            Box(Modifier.fillMaxWidth().height(h).clip(shape).background(m.t.surface2).padding(16.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    T("Your photos appear here", label(), m.t.ink, maxLines = 1)
                    T("Pick a character, then generate", caption(), m.t.muted, maxLines = 1)
                }
            }
            return@Column
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (running) repeat(ui.photo?.draft?.count ?: 4) {
                Box(Modifier.height(h).aspectRatio(.8f).clip(shape).background(m.t.surface2).semantics { contentDescription = "Making the photos" })
            }
            stills.forEach { t ->
                Box(Modifier.height(h).aspectRatio(.8f).clip(shape).background(m.t.surface2).press { nav.go(Routes.result(t.id)) }
                    .semantics { contentDescription = "${t.shownTitle}, ${t.shownLabel}"; role = Role.Button }) {
                    RefImage(t.thumb, Modifier.fillMaxSize(), 20)
                }
            }
        }
    }
}

/** Above the bar: the estimate's notes (one quiet line) and the still rig check (the estimate's `rig`). */
@Composable
fun PhotoRigRow(photo: PhotoUi, wide: Boolean) {
    val m = muse
    photo.notes.firstOrNull()?.let { T(it, caption(), m.t.muted, maxLines = 2) }
    ComposerRigRow(photo.request?.let { studio.muse.app.data.SuiteShotRequest(prompt = it.prompt) }, photo.est, false, wide)
}

/** References on Photo: up to 3 photos, each saying what to take from it (pose, look, scene); her face and outfit never. */
@Composable
fun BoxScope.PhotoReferencesSheet(x: SheetContext) {
    PickerShell("References", x.wide, x.close) { PhotoReferencesBody() }
}

@Composable
private fun ColumnScope.PhotoReferencesBody() {
    val c = LocalContainer.current
    val m = muse
    val store = c.suite.photo
    val p by store.draft.collectAsState()
    val scope = rememberCoroutineScope()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val media = c.media ?: return@launch c.repo.toast("Couldn't read that photo")
            val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that photo")
            store.upload("ref", media.displayName(uri), bytes, media.mime(uri).takeIf { it.startsWith("image/") } ?: "image/jpeg")
        }
    }
    val shape = RoundedCornerShape(PhotoRadii.container(m.id))
    val chip = RoundedCornerShape(PhotoRadii.chip(m.id))
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        T("Copy a pose, a look or a place from up to ${ShootRef.MAX} photos. Her face, body, hair and outfit always come from her own photos.", caption(), m.t.muted)
        p.refs.forEachIndexed { i, r ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.width(72.dp).aspectRatio(.8f).clip(shape).background(m.t.surface2)) { RefImage(r.image, Modifier.fillMaxSize(), 20) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        T("Reference ${i + 1}", label(), m.t.ink, Modifier.weight(1f), maxLines = 1)
                        Box(Modifier.heightIn(min = 48.dp).press { store.removeRef(i) }.semantics { role = Role.Button; contentDescription = "Remove reference ${i + 1}" }.padding(horizontal = 4.dp),
                            contentAlignment = Alignment.CenterEnd) { T("Remove", label(), m.link, maxLines = 1) }
                    }
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        ShootRef.GUIDES.forEach { (id, l) ->
                            val on = id in r.guides
                            Box(Modifier.heightIn(min = 48.dp).press { store.toggleGuide(i, id) }.semantics(mergeDescendants = true) { selected = on; role = Role.Checkbox; contentDescription = l },
                                contentAlignment = Alignment.Center) {
                                Box(Modifier.height(36.dp).clip(chip).background(if (on) m.t.surface else m.t.surface2)
                                    .let { if (on) it.border(if (m.isD) 2.dp else 1.5.dp, if (m.isD) m.t.ink else m.t.accent, chip) else it }.padding(horizontal = 12.dp),
                                    contentAlignment = Alignment.Center) { T(l, label(), if (on) m.t.ink else m.t.muted, maxLines = 1) }
                            }
                        }
                    }
                }
            }
        }
        if (p.canAddRef) {
            val ctl = RoundedCornerShape(PhotoRadii.control(m.id))
            Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(ctl).border(1.dp, m.t.line, ctl).alpha(if (p.uploading == null) 1f else .5f)
                .press(enabled = p.uploading == null) { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                .semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SIc("plus", 16.dp, m.t.ink)
                    T(if (p.uploading == "ref") "Adding…" else "Add reference photo", label(), m.t.ink, maxLines = 1)
                }
            }
        }
        Spacer(Modifier.height(8.dp))
    }
}

/** The bar's Photos list (1–4), for the composer's bottom bar branch. */
fun photoCountLabel(n: Int) = studio.muse.app.data.PhotoRules.noun(n)

/**
 * Opens Suite → Photo with [modelId] and [outfitId] picked: the outfit set generator after saving, the profile's Photo
 * button and the LoRA's "Test it in a photo" (they used to open Photoshoot).
 */
fun openPhoto(c: studio.muse.app.AppContainer, nav: studio.muse.app.ui.Nav, modelId: String?, outfitId: String?) {
    c.suite.composer.value = PhotoComposer.open(c.suite.composer.value, modelId, outfitId)
    c.suite.sheet.value = null
    nav.go(Routes.SUITE_PHOTO)
}
