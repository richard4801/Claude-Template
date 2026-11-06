package studio.muse.app.ui.screens

import android.graphics.BitmapFactory
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
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import studio.muse.app.data.CreateModelRequest
import studio.muse.app.data.Model
import studio.muse.app.data.ModelDraft
import studio.muse.app.ui.LocalCelebrate
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import studio.muse.core.Pricing
import studio.muse.core.SheetAngle

val NICHES = listOf("Fashion", "Beauty", "Fitness", "Travel", "Food", "Tech")

data class SheetState(val model: Model? = null, val balance: Double = 0.0, val draft: ModelDraft = ModelDraft(), val creating: Boolean = false)

class CreateModelViewModel(private val c: AppContainer) : ViewModel() {
    private val creating = kotlinx.coroutines.flow.MutableStateFlow(false)
    val state: StateFlow<SheetState> = combine(c.repo.state, c.drafts.modelId, c.drafts.model, creating) { s, id, d, cr ->
        SheetState(s.model(id), s.balance.balance, d, cr)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SheetState())

    fun edit(f: (ModelDraft) -> ModelDraft) = c.drafts.model.update(f)

    /** Step 1 → creates the draft model, then the character sheet. */
    fun next(onDone: () -> Unit) = viewModelScope.launch {
        val d = c.drafts.model.value
        // Never a made-up name: a blank one would have created a model called after the demo's sample character.
        if (d.name.isBlank()) return@launch c.repo.toast("Give her a name first")
        if (creating.value) return@launch
        creating.value = true
        val m = c.repo.createModel(CreateModelRequest(d.name.trim(), d.age, d.niche))
        creating.value = false
        if (m != null) { c.drafts.modelId.value = m.id; onDone() }
    }

    /** Uploads one image into a slot. Wide images look like a character sheet, which we warn about. */
    fun upload(slot: String, uri: Uri) = viewModelScope.launch {
        val media = c.media ?: return@launch
        val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that image")
        warnIfSheet(bytes)
        val ref = c.repo.uploadImage(media.displayName(uri), bytes, media.mime(uri)) ?: return@launch
        val id = state.value.model?.id ?: return@launch
        c.repo.setSlot(id, slot, ref, "upload")?.let { c.repo.toast("Image added · ${SheetAngle.fromKey(slot)?.label ?: slot}") }
    }

    /** "Upload images": fills the empty slots in order. */
    fun uploadMany(uris: List<Uri>) = viewModelScope.launch {
        val model = state.value.model ?: return@launch
        val empty = model.slots.filter { it.image == null }.map { it.key }
        if (empty.isEmpty()) return@launch c.repo.toast("All 7 slots filled · tap one to replace")
        val media = c.media ?: return@launch
        var n = 0
        uris.take(empty.size).forEachIndexed { i, u ->
            val bytes = media.bytes(u) ?: return@forEachIndexed
            warnIfSheet(bytes)
            val ref = c.repo.uploadImage(media.displayName(u), bytes, media.mime(u)) ?: return@forEachIndexed
            if (c.repo.setSlot(model.id, empty[i], ref, "upload") != null) n++
        }
        if (n > 0) c.repo.toast("$n image${if (n > 1) "s" else ""} added")
    }

    private fun warnIfSheet(bytes: ByteArray) {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        if (o.outHeight > 0 && o.outWidth.toFloat() / o.outHeight > 1.6f) c.repo.toast("Looks like a character sheet · upload separate images")
    }

    fun fill() = viewModelScope.launch {
        val id = state.value.model?.id ?: return@launch
        c.repo.fillAngles(id)
    }

    fun save(celebrate: () -> Unit, onDone: () -> Unit) {
        val m = state.value.model ?: return
        celebrate()
        c.repo.toast(if (m.locked) "Model saved · character sheet ready" else "Model saved with ${m.filled}/7 shots · add more angles any time")
        c.drafts.model.value = ModelDraft()
        onDone()
    }
}

/** "Step 1 of 2" and the step's title. */
@Composable
private fun StepTitle(step: Int, title: String) {
    Column(Modifier.padding(horizontal = MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Caption("Step $step of 2")
        DisplayTitle(title)
    }
}

@Composable
fun CreateBasicsScreen() {
    val c = LocalContainer.current
    val vm: CreateModelViewModel = viewModel { CreateModelViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("New model", onBack = { nav.back() })
            StepTitle(1, "Who is she?")
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s5, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5),
            ) {
                Labeled("Name") { Input(s.draft.name, { v -> vm.edit { it.copy(name = v) } }, placeholder = "Her name", calm = true) }
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                    RowB { T("Age", m.scale.label, m.roles.ink); T("${s.draft.age}", m.scale.label.tabular(), m.roles.ink) }
                    MuseSlider(s.draft.age, 18, 70, { v -> if (v != s.draft.age) vm.edit { it.copy(age = v) } })
                }
                Labeled("Niche") {
                    FlowRow(hGap = MuseSpace.s2, vGap = 0.dp) { NICHES.forEach { n -> ChoiceChip(n, n == s.draft.niche, { vm.edit { it.copy(niche = n) } }) } }
                }
                Notice("Models are always 18+ and original. No lookalikes of real people.")
            }
        }
        ActionDock { PrimaryButton("Next: character sheet", { vm.next { nav.go(Routes.CREATE3) } }, Modifier.weight(1f), busy = s.creating, off = s.draft.name.isBlank()) }
    }
}

@Composable
fun CharacterSheetScreen() {
    val c = LocalContainer.current
    val vm: CreateModelViewModel = viewModel { CreateModelViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val celebrate = LocalCelebrate.current
    val m = muse
    var pendingSlot by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    val pickOne = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> val k = pendingSlot; if (uri != null && k != null) vm.upload(k, uri) }
    val pickMany = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(7)) { uris -> if (uris.isNotEmpty()) vm.uploadMany(uris) }
    val img = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
    val model = s.model
    val filled = model?.filled ?: 0
    val faces = model?.slots?.count { (it.key == "face" || it.key == "profile") && it.image != null } ?: 0
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar(if (model != null && model.locked) model.name else "New model", onBack = { nav.back() })
            StepTitle(2, "Character sheet")
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s3, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5),
            ) {
                Body("Upload your model's images. Tap a slot to add or replace a shot.")
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                    SheetAngle.DISPLAY.chunked(3).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                            row.forEach { a ->
                                val slot = model?.slot(a.key)
                                Column(
                                    Modifier.weight(1f).press { pendingSlot = a.key; pickOne.launch(img) }.semantics { contentDescription = "${a.label}: ${if (slot?.image != null) "replace" else "add"} image" },
                                    verticalArrangement = Arrangement.spacedBy(MuseSpace.s1),
                                ) {
                                    val tile = Modifier.fillMaxWidth().aspectRatio(3f / 4f)
                                    when {
                                        slot?.busy == true -> Skeleton(tile, containerShape())
                                        slot?.image != null -> Box(tile.clip(containerShape())) { RefImage(slot.image, Modifier.fillMaxSize()) }
                                        else -> Box(tile.clip(containerShape()).background(m.roles.field), contentAlignment = Alignment.Center) { Ic("upload", 20.dp, m.roles.ink2) }
                                    }
                                    val src = if (slot?.image != null && !slot.busy) (if (slot.source == "generated") " · filled in" else " · yours") else ""
                                    Caption(a.label + src, maxLines = 1)
                                }
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    SecondaryButton("Upload images", { pickMany.launch(img) }, Modifier.fillMaxWidth(), icon = "upload")
                    if (filled in 1..6) {
                        val miss = 7 - filled
                        SecondaryButton("Fill $miss missing angle${if (miss > 1) "s" else ""} · ${studio.muse.core.PhotoPricing.about(studio.muse.core.PhotoPricing.sheetAngles(photoPrices(), miss, filled))}",
                            { vm.fill() }, Modifier.fillMaxWidth())
                    }
                    if (filled > 0) Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                        SecondaryButton("Enhance", { nav.go(Routes.ENHANCE) }, Modifier.weight(1f))
                        SecondaryButton("Dress up", { nav.go(Routes.DRESSUP) }, Modifier.weight(1f))
                    }
                }
                if (faces < 2) Notice("Two face close-ups keep her face sharp and consistent in videos. You can still save without them.", tone = NoticeTone.CAUTION)
                else Notice("$filled of 7 shots. ${if (filled < 7) "More angles help when she turns." else "Full sheet: her identity is locked."}", tone = if (filled == 7) NoticeTone.POSITIVE else NoticeTone.NEUTRAL)
            }
        }
        ActionDock { PrimaryButton("Save model · $filled of 7", { vm.save(celebrate) { nav.reset(Routes.HOME) } }, Modifier.weight(1f)) }
    }
}
