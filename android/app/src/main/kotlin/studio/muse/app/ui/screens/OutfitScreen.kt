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

    fun save(celebrate: () -> Unit, onDone: () -> Unit) = viewModelScope.launch {
        val id = state.value.draft.previewId ?: return@launch
        val o = c.repo.saveOutfit(id) ?: return@launch
        c.drafts.outfitId.value = o.id
        c.drafts.outfit.value = OutfitDraft()
        celebrate()
        c.repo.toast("Outfit saved · selected for your next shoot")
        onDone()
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
    val name = s.model?.name?.substringBefore(' ') ?: "Sienna"
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("New outfit", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                H2("Outfit set")
                T("$name in a new outfit, from four angles. Used by every shoot and video with this outfit.", m.type.body, m.t.muted)
                Seg(listOf("describe" to "Describe", "photo" to "From a photo", "own" to "My own set"), s.draft.mode, vm::mode)
                when (s.draft.mode) {
                    "describe" -> Field("Describe the outfit") { Input(s.draft.description, { v -> vm.edit { it.copy(description = v) } }, area = true) }
                    "photo" -> Opt("Upload a product or outfit photo", if (s.draft.images.isEmpty()) "Flat-lay, mannequin or model photo. We'll dress $name in it." else "Photo added · tap to replace", icon = "upload", onClick = { pickOne.launch(img) })
                    else -> Opt("Upload front, ¾, side and back", if (s.draft.images.isEmpty()) "Already have a set? Bring it in as is. Any missing angle can be generated later." else "${s.draft.images.size} of 4 added · tap to replace", icon = "upload", onClick = { pickFour.launch(img) })
                }
                Field("Name") { Input(s.draft.name, { v -> vm.edit { it.copy(name = v) } }) }
                OutfitAngle.entries.chunked(2).forEachIndexed { r, row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEachIndexed { i, a ->
                            val idx = r * 2 + i
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                val shape = RoundedCornerShape(m.t.r * .6f)
                                val ref: ImageRef? = if (s.done) s.preview?.angles?.getOrNull(idx) else if (s.draft.mode == "own") s.draft.images.getOrNull(idx) else null
                                Box(Modifier.fillMaxWidth().height(132.dp).clip(shape).background(m.t.surface2).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }.shimmer(s.busy)) {
                                    if (ref != null) RefImage(ref, Modifier.fillMaxSize())
                                }
                                Tiny(a.label)
                            }
                        }
                    }
                }
                Tiny("Plain, unbranded clothes work best. Visible logos carry into the video.")
            }
        }
        Dock {
            if (s.done) {
                Cta2("Retake", { vm.generate() }, icon = "retry")
                Cta("Save outfit", { vm.save(celebrate) { nav.back() } }, Modifier.weight(1f))
            } else {
                Cta(
                    if (s.busy) "Generating…" else if (s.draft.mode == "own") "Use my images" else "Generate outfit set · ${Pricing.money(Pricing.OUTFIT_SET_COST)}",
                    { if (!s.busy) vm.generate() }, Modifier.weight(1f), busy = s.busy,
                )
            }
        }
    }
}
