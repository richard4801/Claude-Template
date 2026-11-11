package studio.muse.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.CreateOutfitRequest
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.data.OutfitDraft
import studio.muse.app.data.OutfitBaseAngles
import studio.muse.app.data.OutfitPictures
import androidx.compose.foundation.layout.heightIn
import studio.muse.app.ui.LocalCelebrate
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import androidx.compose.foundation.layout.aspectRatio
import studio.muse.core.OutfitAngle
import studio.muse.core.Pricing
import studio.muse.core.OutfitNaming

data class OutfitState(val draft: OutfitDraft = OutfitDraft(), val model: Model? = null, val preview: Outfit? = null) {
    val busy get() = preview?.state == "generating"
    val done get() = preview != null && preview.state != "generating"
}

class OutfitViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<OutfitState> = combine(c.repo.state, c.drafts.outfit, c.drafts.modelId) { s, d, mid ->
        OutfitState(d, s.model(mid) ?: s.models.firstOrNull(), s.outfit(d.previewId))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, OutfitState())

    fun edit(f: (OutfitDraft) -> OutfitDraft) = c.drafts.outfit.update(f)
    /** Keep-from-base (§6): the four base images that will be sent (the set's own, or the angle chosen instead). */
    fun baseSet(s: OutfitState): List<ImageRef?> {
        val st = c.repo.state.value
        val own = s.draft.baseOutfitId?.let { st.outfit(it) }?.let { o -> (0 until 4).map { o.angles.getOrNull(it) } }
            ?: OutfitBaseAngles.KEYS.map { k -> s.model?.slots?.firstOrNull { it.key == k }?.image }
        return (0 until 4).map { s.draft.baseAngles[it] ?: own[it] }
    }
    fun herOutfits(s: OutfitState): List<Outfit> = c.repo.state.value.outfitsOf(s.model?.id).filter { it.state == "ready" }
    fun setBaseSource(id: String?) = edit { it.copy(baseOutfitId = id, baseAngles = OutfitBaseAngles()) }
    fun swapAngle(i: Int, r: ImageRef?) = edit { it.copy(baseAngles = it.baseAngles.with(i, r)) }
    fun uploadAngle(i: Int, u: Uri) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val r = media.bytes(u)?.let { c.repo.uploadImage(media.displayName(u), it, media.mime(u)) } ?: return@launch
        swapAngle(i, r)
    }

    fun mode(m: String) = edit { it.copy(mode = m, previewId = null, images = emptyList(), own = listOf(null, null, null, null)) }

    /** "My own set": the photo for one angle box, uploaded and set on exactly that angle (never by file order). */
    fun setOwn(i: Int, u: Uri) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val r = media.bytes(u)?.let { c.repo.uploadImage(media.displayName(u), it, media.mime(u)) } ?: return@launch
        edit { d -> d.copy(own = d.own.toMutableList().also { it[i] = r }) }
    }
    fun clearOwn(i: Int) = edit { d -> d.copy(own = d.own.toMutableList().also { it[i] = null }) }

    fun addImages(uris: List<Uri>) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val refs = uris.mapNotNull { u -> media.bytes(u)?.let { c.repo.uploadImage(media.displayName(u), it, media.mime(u)) } }
        if (refs.isNotEmpty()) {
            edit { it.copy(images = refs, photoName = uris.firstOrNull()?.let(media::displayName)) }
            c.repo.toast(if (state.value.draft.mode == "own") "${refs.size} of 4 angles added" else "Photo added")
        }
    }

    fun generate() = viewModelScope.launch {
        val s = state.value
        val model = s.model ?: return@launch
        if (s.draft.mode == "photo" && s.draft.images.isEmpty()) {
            c.repo.toast("Upload a product or outfit photo first")
            return@launch
        }
        if (s.draft.mode == "own" && s.draft.own.firstOrNull() == null) {
            c.repo.toast("Add the front photo first")
            return@launch
        }
        if (s.draft.mode == "describe" && s.draft.description.isBlank()) {
            c.repo.toast("Describe the outfit first")
            return@launch
        }
        // §5: a name from the start (what was typed, the photo's file name, else "Outfit · 11 Nov"); it can be changed
        // before it's added. Never a generic "Product look".
        val name = s.draft.name.trim().ifEmpty {
            OutfitNaming.suggestion(if (s.draft.mode == "describe") s.draft.description else "", s.draft.photoName.takeIf { s.draft.mode == "photo" }, outfitDay(System.currentTimeMillis()))
        }
        edit { it.copy(name = name) }
        val o = c.repo.createOutfit(CreateOutfitRequest(model.id, name.take(OutfitNaming.MAX), s.draft.mode, s.draft.description, if (s.draft.mode == "own") s.draft.own else s.draft.images, s.draft.imageModel.takeIf { s.draft.mode != "own" }, s.draft.base?.takeIf { it.keeping })) ?: return@launch
        edit { it.copy(previewId = o.id) }
    }

    /** Saves the set, then [onDone] with the character and the new outfit (the screen opens Suite → Photo with them picked). */
    fun save(celebrate: () -> Unit, onDone: (modelId: String?, outfitId: String) -> Unit) = viewModelScope.launch {
        val id = state.value.draft.previewId ?: return@launch
        val name = state.value.draft.name.trim()
        if (name.isEmpty()) { c.repo.toast("Give the outfit a name"); return@launch }
        val o = c.repo.saveOutfit(id, name.take(OutfitNaming.MAX)) ?: return@launch
        c.drafts.outfitId.value = o.id
        c.drafts.outfit.value = OutfitDraft()
        c.drafts.outfitPage.value = 0 // newest first: it's on page 1
        celebrate()
        c.repo.toast("Added to her outfits · ready in Photo")
        onDone(state.value.model?.id, o.id)
    }
}

@Composable
fun OutfitScreen() {
    val c = LocalContainer.current
    val vm: OutfitViewModel = viewModel { OutfitViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val celebrate = LocalCelebrate.current
    val m = muse
    val img = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
    val pickOne = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> if (u != null) vm.addImages(listOf(u)) }
    // "My own set": each angle box picks its own photo.
    var ownFor by remember { mutableStateOf(0) }
    val pickAngle = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> if (u != null) vm.setOwn(ownFor, u) }
    val name = s.model?.name?.substringBefore(' ') ?: "Her"
    // "My own set" before it's sent: the four angle boxes (each picks its photo). No face boxes: MUSE makes those.
    val ownPicking = s.draft.mode == "own" && !s.done && !s.busy
    val angles: List<ImageRef?> = OutfitAngle.entries.indices.map { idx -> if (ownPicking) s.draft.own.getOrNull(idx) else null }
    // Otherwise the 7 pictures (4 body angles, 3 face close-ups) as they come back; a tap opens them full size.
    val pictures: List<ImageRef?> = s.preview?.takeIf { s.done || s.busy }?.let { OutfitPictures.all(it) } ?: List(OutfitPictures.KEYS.size) { null }
    var viewing by remember { mutableStateOf<Int?>(null) }
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("New outfit", onBack = { nav.back() })
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    DisplayTitle("Outfit set")
                    Body("$name in a new outfit: four angles and three face close-ups with its hair and make-up. Every shoot and video with this outfit uses them.")
                }
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                    Segmented(listOf("describe" to "Describe", "photo" to "From a photo", "own" to "My own set"), s.draft.mode, vm::mode)
                    if (s.draft.mode != "own") BaseKeep(s, vm)
                    when (s.draft.mode) {
                        "describe" -> Labeled(if (s.draft.fromBase) "What to change" else "Describe the outfit") { Input(s.draft.description, { v -> vm.edit { it.copy(description = v) } }, area = true, calm = true) }
                        "photo" -> {
                            SecondaryButton(if (s.draft.images.isEmpty()) "Upload an outfit photo" else "Replace the photo", { pickOne.launch(img) }, Modifier.fillMaxWidth(), icon = "upload")
                            Caption(if (s.draft.images.isEmpty()) "A flat-lay, mannequin or model photo. We'll dress $name in it." else "Photo added.")
                        }
                        else -> {
                            Caption("Tap a box to add that view. Any you skip can be made later from the front.")
                            Caption("MUSE makes her 3 face close-ups from your front")
                        }
                    }
                }
                Labeled("Name") { Input(s.draft.name, { v -> vm.edit { it.copy(name = v.take(OutfitNaming.MAX)) } }, placeholder = "Suggested when the set is made", calm = true) }
                // WS7/WS13: the owner's model for the set (not for "My own set": only its face close-ups are made, on the default).
                if (s.draft.mode != "own") ModelChoiceRow(studio.muse.app.data.ModelPurpose.OUTFIT, ModelPick(s.draft.imageModel), { p -> vm.edit { it.copy(imageModel = p.model) } })
                if (!ownPicking) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                    OutfitPictureGrid(pictures, emptyList(), busy = s.busy) { i -> viewing = OutfitPictures.pageOf(pictures, i) }
                    Caption("Plain, unbranded clothes work best. Visible logos carry into the video.")
                } else Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                    OutfitAngle.entries.chunked(2).forEachIndexed { r, row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            row.forEachIndexed { i, a ->
                                val idx = r * 2 + i
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                                    val ref: ImageRef? = angles[idx]
                                    val tile = Modifier.fillMaxWidth().aspectRatio(3f / 4f)
                                    Box(
                                        tile.clip(containerShape()).background(m.roles.field).press { ownFor = idx; pickAngle.launch(img) }
                                            .semantics { contentDescription = if (ref == null) "Choose the ${a.label} photo" else "Replace the ${a.label} photo"; role = Role.Button },
                                        contentAlignment = androidx.compose.ui.Alignment.Center,
                                    ) {
                                        if (ref != null) {
                                            RefImage(ref, Modifier.fillMaxSize())
                                            Box(Modifier.align(androidx.compose.ui.Alignment.TopEnd).size(48.dp).press { vm.clearOwn(idx) }
                                                .semantics { contentDescription = "Clear the ${a.label} photo"; role = Role.Button }, contentAlignment = androidx.compose.ui.Alignment.Center) {
                                                Box(Modifier.size(24.dp).clip(androidx.compose.foundation.shape.CircleShape).background(androidx.compose.ui.graphics.Color.Black.copy(alpha = .6f)), contentAlignment = androidx.compose.ui.Alignment.Center) {
                                                    studio.muse.app.ui.theme.Ic("x", 14.dp, androidx.compose.ui.graphics.Color.White)
                                                }
                                            }
                                        } else studio.muse.app.ui.theme.Ic("plus", 22.dp, m.roles.ink2)
                                    }
                                    Caption(a.label)
                                }
                            }
                        }
                    }
                    Caption("Plain, unbranded clothes work best. Visible logos carry into the video.")
                }
            }
        }
        viewing?.let { start ->
            val shown = OutfitPictures.shown(pictures).map { (i, r) -> ViewerImage(r, OutfitPictures.LABELS[i]) }
            if (shown.isNotEmpty()) ImageViewer(shown, start) { viewing = null }
        }
        ActionDock {
            if (s.done) {
                SecondaryButton("Generate again", { vm.generate() }, icon = "retry")
                PrimaryButton("Add to her outfits", { vm.save(celebrate) { mid, oid -> nav.back(); studio.muse.app.ui.screens.suite.composer.openPhoto(c, nav, mid, oid) } }, Modifier.weight(1f))
            } else {
                // The full price: the body angles and the 3 face close-ups ("My own set": the faces alone).
                val price = Pricing.money(OutfitPictures.createEstimate(photoPrices(), s.draft.mode, s.draft.base?.keeping == true))
                PrimaryButton(
                    if (s.busy) "Making the 7 pictures…" else if (s.draft.mode == "own") (if (s.draft.own.firstOrNull() == null) "Add the front photo" else "Use my images · $price") else "Make 7 pictures · $price",
                    { if (!s.busy) vm.generate() }, Modifier.weight(1f), busy = s.busy,
                )
            }
        }
    }
}

/** §6: start from her base photos (her profile photos or one of her outfits), see and swap each angle, tick what to keep. */
@Composable
private fun BaseKeep(st: OutfitState, vm: OutfitViewModel) {
    val d = st.draft
    val m = muse
    var swapping by remember { mutableStateOf<Int?>(null) }
    var uploadFor by remember { mutableStateOf(0) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> if (u != null) vm.uploadAngle(uploadFor, u) }
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Check("Start from her base photos", d.fromBase, { vm.edit { it.copy(fromBase = !it.fromBase) } }, Modifier.heightIn(min = 48.dp))
        if (d.fromBase) {
            val fits = vm.herOutfits(st)
            var sourceMenu by remember { mutableStateOf(false) }
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Caption("Start from", Modifier.padding(end = MuseSpace.s2))
                Box {
                    TextAction(fits.firstOrNull { it.id == d.baseOutfitId }?.name ?: "Her profile photos", { sourceMenu = true })
                    MuseMenu(sourceMenu, { sourceMenu = false },
                        listOf(MenuItem("user", "Her profile photos") { vm.setBaseSource(null) }) + fits.map { o -> MenuItem("outfit", o.name) { vm.setBaseSource(o.id) } })
                }
            }
            val set = vm.baseSet(st)
            val labels = listOf("Front", "¾", "Side", "Back")
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                (0 until 4).forEach { i ->
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(containerShape()).background(m.roles.field).press { swapping = i }
                            .semantics { contentDescription = "${labels[i]} base photo, swap"; role = Role.Button }) {
                            set[i]?.let { RefImage(it, Modifier.fillMaxSize()) }
                            if (swapping == i) {
                                val items = buildList {
                                    st.model?.let { md -> OutfitBaseAngles.KEYS.forEachIndexed { k, key -> md.slots.firstOrNull { it.key == key }?.image?.let { r -> add(MenuItem("user", "Her ${labels[k]}") { vm.swapAngle(i, r) }) } } }
                                    fits.forEach { o -> (0 until 4).forEach { k -> o.angles.getOrNull(k)?.let { r -> add(MenuItem("outfit", "${o.name}, ${labels[k]}") { vm.swapAngle(i, r) }) } } }
                                    add(MenuItem("upload", "Upload a photo of her") { uploadFor = i; pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                                    if (d.baseAngles[i] != null) add(MenuItem("retry", "Use the set's own") { vm.swapAngle(i, null) })
                                }
                                MuseMenu(true, { swapping = null }, items)
                            }
                        }
                        Caption(if (set[i] == null && i > 0) "Uses the front" else labels[i], maxLines = 1)
                    }
                }
            }
            val k = d.keep
            listOf(listOf("Top" to k.top, "Bottom" to k.bottom), listOf("Shoes" to k.shoes, "Accessories" to k.accessories)).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                    row.forEach { (label, on) ->
                        Check(label, on, {
                            vm.edit { dr ->
                                val kk = dr.keep
                                dr.copy(keep = when (label) {
                                    "Top" -> kk.copy(top = !kk.top); "Bottom" -> kk.copy(bottom = !kk.bottom)
                                    "Shoes" -> kk.copy(shoes = !kk.shoes); else -> kk.copy(accessories = !kk.accessories)
                                })
                            }
                        }, Modifier.weight(1f).heightIn(min = 48.dp))
                    }
                }
            }
            Input(d.keepNote, { v -> vm.edit { it.copy(keepNote = v.take(200)) } }, placeholder = "Note, e.g. the black lace bra", calm = true)
            Caption(d.base?.summary.orEmpty())
        }
    }
}
