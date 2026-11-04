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
        creating.value = true
        val d = c.drafts.model.value
        val m = c.repo.createModel(CreateModelRequest(d.name.ifBlank { "Noor Ellis" }, d.age, d.niche))
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
        if (empty.isEmpty()) return@launch c.repo.toast("All 6 slots filled · tap one to replace")
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
        c.repo.toast(if (m.filled == 6) "Model saved · character sheet ready" else "Model saved with ${m.filled}/6 shots · add more angles any time")
        c.drafts.model.value = ModelDraft()
        onDone()
    }
}

@Composable
private fun StepBars(n: Int) {
    val m = muse
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        repeat(2) { i -> Box(Modifier.weight(1f).height(4.dp).clip(RoundedCornerShape(2.dp)).background(if (i < n) m.t.accent else m.t.surface2)) }
    }
}

@Composable
fun CreateBasicsScreen() {
    val c = LocalContainer.current
    val vm: CreateModelViewModel = viewModel { CreateModelViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("New model", onBack = { nav.back() })
            Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                StepBars(1); Lbl("Step 1 of 2"); H2("Who is she?")
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 12.dp, bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Field("Name") { Input(s.draft.name, { v -> vm.edit { it.copy(name = v) } }, placeholder = "Noor Ellis") }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row { Lbl("Age · "); T("${s.draft.age}", m.type.mono.copy(fontSize = 11.5.sp, fontWeight = FontWeight.Bold), m.t.ink) }
                    MuseSlider(s.draft.age, 18, 70, { v -> if (v != s.draft.age) vm.edit { it.copy(age = v) } })
                    Scale("18", "70")
                }
                Field("Niche") { ChipRow(NICHES, s.draft.niche, { v -> vm.edit { it.copy(niche = v) } }) }
                NoteBox("Models are always 18+ and original. No lookalikes of real people.")
            }
        }
        Dock { Cta("Next: Character sheet", { vm.next { nav.go(Routes.CREATE3) } }, Modifier.weight(1f), busy = s.creating) }
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
    val pickMany = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(6)) { uris -> if (uris.isNotEmpty()) vm.uploadMany(uris) }
    val img = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
    val model = s.model
    val filled = model?.filled ?: 0
    val faces = model?.slots?.count { (it.key == "face" || it.key == "profile") && it.image != null } ?: 0
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(if (model != null && model.locked) model.name else "New model", onBack = { nav.back() })
            Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                StepBars(2); Lbl("Step 2 of 2"); H2("Character sheet")
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                T("Upload your model's images. Tap a slot to add or replace a shot.", m.type.body, m.t.muted)
                SheetAngle.entries.chunked(3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { a ->
                            val slot = model?.slot(a.key)
                            Column(Modifier.weight(1f).press { pendingSlot = a.key; pickOne.launch(img) }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                val shape = RoundedCornerShape(m.t.r * .6f)
                                when {
                                    slot?.busy == true -> Box(Modifier.fillMaxWidth().height(132.dp).clip(shape).background(m.t.surface2).shimmer())
                                    slot?.image != null -> Box(Modifier.fillMaxWidth().height(132.dp).clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }) { RefImage(slot.image, Modifier.fillMaxSize()) }
                                    else -> Box(Modifier.fillMaxWidth().height(132.dp).clip(shape).background(m.t.surface).dashed(m.t.line, m.t.r * .6f, m.t.stroke), contentAlignment = Alignment.Center) { Ic("upload", 20.dp, m.t.muted) }
                                }
                                val label = androidx.compose.ui.text.buildAnnotatedString {
                                    append(a.label)
                                    if (slot?.image != null && !slot.busy) {
                                        append(" · ")
                                        withStyle(androidx.compose.ui.text.SpanStyle(fontWeight = FontWeight.Bold, color = if (slot.source == "generated") m.t.accent else m.t.muted)) {
                                            append(if (slot.source == "generated") "filled in" else "yours")
                                        }
                                    }
                                }
                                androidx.compose.material3.Text(label, style = m.type.tiny.copy(fontSize = 12.sp), color = m.t.muted, maxLines = 1)
                            }
                        }
                    }
                }
                Cta2("Upload images", { pickMany.launch(img) }, Modifier.fillMaxWidth(), icon = "upload", height = 44.dp)
                if (filled in 1..5) {
                    val miss = 6 - filled
                    Opt("Fill missing angles from your images", "Optional. Adds the $miss missing angle${if (miss > 1) "s" else ""} of your model · ${studio.muse.core.PhotoPricing.about(studio.muse.core.PhotoPricing.sheetAngles(photoPrices(), miss, filled))}", icon = "spark", onClick = { vm.fill() })
                }
                if (faces < 2) NoteBox("Tip: two face close-ups keep her face sharp and consistent in videos. You can still save without them.", warn = true)
                else NoteBox("$filled of 6 shots. ${if (filled < 6) "More angles help when she turns. Optional." else "Full sheet. Her identity is locked."}", icon = "check")
            }
        }
        Dock { Cta("Save model · $filled/6", { vm.save(celebrate) { nav.reset(Routes.HOME) } }, Modifier.weight(1f)) }
    }
}

