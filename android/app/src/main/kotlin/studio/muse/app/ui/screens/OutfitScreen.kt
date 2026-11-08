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

data class OutfitState(val draft: OutfitDraft = OutfitDraft(), val model: Model? = null, val preview: Outfit? = null) {
    val busy get() = preview?.state == "generating"
    val done get() = preview != null && preview.state != "generating"
}

class OutfitViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<OutfitState> = combine(c.repo.state, c.drafts.outfit, c.drafts.modelId) { s, d, mid ->
        OutfitState(d, s.model(mid) ?: s.models.firstOrNull(), s.outfit(d.previewId))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, OutfitState())

    fun edit(f: (OutfitDraft) -> OutfitDraft) = c.drafts.outfit.update(f)
    fun mode(m: String) = edit { it.copy(mode = m, previewId = null, images = emptyList()) }

    fun addImages(uris: List<Uri>) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val refs = uris.mapNotNull { u -> media.bytes(u)?.let { c.repo.uploadImage(media.displayName(u), it, media.mime(u)) } }
        if (refs.isNotEmpty()) {
            edit { it.copy(images = refs) }
            c.repo.toast(if (state.value.draft.mode == "own") "${refs.size} of 4 angles added" else "Photo added")
        }
    }

    fun generate() = viewModelScope.launch {
        val s = state.value
        val model = s.model ?: return@launch
        if (s.draft.mode != "describe" && s.draft.images.isEmpty()) {
            c.repo.toast(if (s.draft.mode == "own") "Upload front, ¾, side and back first" else "Upload a product or outfit photo first")
            return@launch
        }
        val o = c.repo.createOutfit(CreateOutfitRequest(model.id, s.draft.name, s.draft.mode, s.draft.description, s.draft.images)) ?: return@launch
        edit { it.copy(previewId = o.id) }
    }

    /** Saves the set, then [onDone] with the character and the new outfit (the screen opens Suite → Photo with them picked). */
    fun save(celebrate: () -> Unit, onDone: (modelId: String?, outfitId: String) -> Unit) = viewModelScope.launch {
        val id = state.value.draft.previewId ?: return@launch
        val o = c.repo.saveOutfit(id) ?: return@launch
        c.drafts.outfitId.value = o.id
        c.drafts.outfit.value = OutfitDraft()
        celebrate()
        c.repo.toast("Outfit saved · ready in Photo")
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
    val pickFour = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(4)) { us -> if (us.isNotEmpty()) vm.addImages(us) }
    val name = s.model?.name?.substringBefore(' ') ?: "Her"
    // The four angles as they show in the grid; a tap opens them full size (pinch to zoom, swipe between angles).
    val angles: List<ImageRef?> = OutfitAngle.entries.indices.map { idx ->
        if (s.done) s.preview?.angles?.getOrNull(idx) else if (s.draft.mode == "own") s.draft.images.getOrNull(idx) else null
    }
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
                    Body("$name in a new outfit, from four angles. Every shoot and video with this outfit uses them.")
                }
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                    Segmented(listOf("describe" to "Describe", "photo" to "From a photo", "own" to "My own set"), s.draft.mode, vm::mode)
                    when (s.draft.mode) {
                        "describe" -> Labeled("Describe the outfit") { Input(s.draft.description, { v -> vm.edit { it.copy(description = v) } }, area = true, calm = true) }
                        "photo" -> {
                            SecondaryButton(if (s.draft.images.isEmpty()) "Upload an outfit photo" else "Replace the photo", { pickOne.launch(img) }, Modifier.fillMaxWidth(), icon = "upload")
                            Caption(if (s.draft.images.isEmpty()) "A flat-lay, mannequin or model photo. We'll dress $name in it." else "Photo added.")
                        }
                        else -> {
                            SecondaryButton(if (s.draft.images.isEmpty()) "Upload front, ¾, side and back" else "Replace the images", { pickFour.launch(img) }, Modifier.fillMaxWidth(), icon = "upload")
                            Caption(if (s.draft.images.isEmpty()) "Already have a set? Bring it in as it is. Any missing angle can be generated later." else "${s.draft.images.size} of 4 added.")
                        }
                    }
                }
                Labeled("Name") { Input(s.draft.name, { v -> vm.edit { it.copy(name = v) } }, calm = true) }
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                    OutfitAngle.entries.chunked(2).forEachIndexed { r, row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            row.forEachIndexed { i, a ->
                                val idx = r * 2 + i
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                                    val ref: ImageRef? = angles[idx]
                                    val tile = Modifier.fillMaxWidth().aspectRatio(3f / 4f)
                                    if (s.busy && ref == null) Skeleton(tile, containerShape())
                                    else Box(
                                        tile.clip(containerShape()).background(m.roles.field).let { t ->
                                            if (ref == null) t else t.press { viewing = angles.filterNotNull().indexOf(ref) }
                                                .semantics { contentDescription = "${a.label}, view full size"; role = Role.Button }
                                        },
                                    ) { if (ref != null) RefImage(ref, Modifier.fillMaxSize()) }
                                    Caption(a.label)
                                }
                            }
                        }
                    }
                    Caption("Plain, unbranded clothes work best. Visible logos carry into the video.")
                }
                RowItem("Dress up the whole character sheet", "One outfit photo: all 7 sheet photos made again wearing it, saved as a new outfit",
                    onClick = { nav.go(studio.muse.app.ui.Routes.DRESSUP) }) { Chevron() }
            }
        }
        viewing?.let { start ->
            val shown = OutfitAngle.entries.mapIndexedNotNull { i, a -> angles[i]?.let { ViewerImage(it, a.label) } }
            if (shown.isNotEmpty()) ImageViewer(shown, start) { viewing = null }
        }
        ActionDock {
            if (s.done) {
                SecondaryButton("Generate again", { vm.generate() }, icon = "retry")
                PrimaryButton("Save outfit", { vm.save(celebrate) { mid, oid -> nav.back(); studio.muse.app.ui.screens.suite.composer.openPhoto(c, nav, mid, oid) } }, Modifier.weight(1f))
            } else {
                PrimaryButton(
                    if (s.busy) "Generating the outfit set…" else if (s.draft.mode == "own") "Use my images" else "Generate outfit set · ${studio.muse.core.PhotoPricing.about(studio.muse.core.PhotoPricing.outfitSet(photoPrices()))}",
                    { if (!s.busy) vm.generate() }, Modifier.weight(1f), busy = s.busy,
                )
            }
        }
    }
}
