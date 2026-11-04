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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.data.ShootDraft
import studio.muse.app.data.ShootRequest
import studio.muse.app.platform.SoundFx
import studio.muse.app.ui.LocalCelebrate
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.core.BuiltPrompt
import studio.muse.core.CameraSpec
import studio.muse.core.OutfitSpec
import studio.muse.core.Pricing
import studio.muse.core.PromptEngine
import studio.muse.core.ShootSpec
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
    val prompt: BuiltPrompt? = null,
    /** idle | busy | ready */
    val phase: String = "idle",
)

class ShootViewModel(private val c: AppContainer) : ViewModel() {
    private val phase = MutableStateFlow("idle")
    val state: StateFlow<ShootState> = combine(c.repo.state, c.drafts.shoot, c.drafts.modelId, c.drafts.outfitId, phase) { s, d, mid, oid, ph ->
        val model = s.model(mid)?.takeIf { it.locked } ?: s.models.firstOrNull { it.locked }
        val outfits = s.outfitsOf(model?.id)
        val outfit = outfits.firstOrNull { it.id == oid } ?: outfits.firstOrNull()
        val prompt = model?.let { buildPrompt(it, outfit, d) }
        ShootState(d, model, s.models, outfits, outfit, prompt, ph)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ShootState())

    fun edit(f: (ShootDraft) -> ShootDraft) { c.drafts.shoot.update(f); if (phase.value == "ready") phase.value = "idle" }
    fun outfit(id: String) { c.drafts.outfitId.value = id }
    fun resetCamera() = edit { it.copy(shot = "Medium", lens = 35, aperture = "f/2.8") }
    fun toast(s: String) = c.repo.toast(s)

    fun shoot(celebrate: () -> Unit) = viewModelScope.launch {
        val s = state.value
        if (s.phase == "busy") return@launch
        val model = s.model ?: return@launch c.repo.toast("Only Sienna is ready · Noor needs close-ups")
        val p = s.prompt ?: return@launch
        phase.value = "busy"
        c.sound.play(SoundFx.Kind.GO)
        val shots = c.repo.shoot(ShootRequest(model.id, s.outfit?.id ?: "", s.draft.scene ?: PromptEngine.DEFAULT_SCENE, p.text, p.seed))
        if (shots == null) { phase.value = "idle"; return@launch }
        c.drafts.freshShots.value = shots.size
        c.drafts.galleryTab.value = "tests"
        phase.value = "ready"
        celebrate()
    }

    companion object {
        fun buildPrompt(m: Model, o: Outfit?, d: ShootDraft): BuiltPrompt = PromptEngine.photoshoot(
            ShootSpec(FakeMuseApi.identity(m), OutfitSpec(o?.name ?: "outfit"), d.scene, CameraSpec(d.shot, d.lens, d.aperture), d.light, d.grade, d.direction, d.lockSeed),
        )
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
                MoreMenu(listOf(
                    MenuItem("spark", "Show prompt") { vm.edit { it.copy(tool = "spark") } },
                    MenuItem("quality", "Save as preset") { vm.toast("Saved as preset \"${(d.scene ?: PromptEngine.DEFAULT_SCENE).substringBefore(" · ")} · ${d.lens}mm\"") },
                    MenuItem("retry", "Reset camera") { vm.resetCamera() },
                    MenuItem("model", "Change model") { vm.toast("Only Sienna is ready · Noor needs close-ups") },
                ))
            }
            Canvas(220.dp) {
                RefImage(s.outfit?.angles?.getOrNull(1) ?: s.outfit?.front, Modifier.fillMaxSize(), 20)
                Viewfinder()
                if (m.isB) Readout("${d.lens}MM · ${d.aperture.uppercase()} · 4300K", Modifier.padding(start = 14.dp, top = 12.dp))
                Sticker((d.scene ?: PromptEngine.DEFAULT_SCENE).lowercase().take(24), "yellow", -4f, Modifier.align(Alignment.BottomStart).padding(12.dp))
            }
            ToolStrip(SHOOT_TOOLS, d.tool) { k -> vm.edit { it.copy(tool = k) } }
            BSheet(14.dp) {
                when (d.tool) {
                    "spark" -> {
                        RowB { H3("Prompt"); Tiny("Built from your choices") }
                        Field("Your direction") { Input(d.direction, { v -> vm.edit { it.copy(direction = v) } }, area = true, placeholder = "e.g. laughing mid-step, hair blowing, holding an iced coffee") }
                        RowB {
                            Column(Modifier.weight(1f)) { T("Lock look", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("Same seed, so retakes stay consistent") }
                            Toggle(d.lockSeed, { vm.edit { it.copy(lockSeed = !it.lockSeed) } })
                        }
                        s.prompt?.let { p ->
                            Field("Final prompt") { PromptBox(p) }
                            if (p.removed.isNotEmpty()) NoteBox("Left out of your direction: ${p.removed.joinToString("; ")}. It would change her identity or add a never-add item.", warn = true)
                            val clip = LocalClipboardManager.current
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Cta2("Copy", { clip.setText(AnnotatedString(p.text)); vm.toast("Prompt copied") }, Modifier.weight(1f))
                                Cta2("Edit as text", { vm.toast("Advanced: edit the full prompt as text (pro mode)") }, Modifier.weight(1f))
                            }
                        }
                    }
                    "camera" -> {
                        RowB { H3("Camera"); T("Reset", m.type.tiny, if (m.isD) m.t.blue else m.t.accent, Modifier.press { vm.resetCamera() }.padding(6.dp)) }
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
                    }
                    "outfit" -> {
                        H3("Outfit")
                        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            s.outfits.forEach { o -> OutfitTile(o, o.id == s.outfit?.id, { vm.outfit(o.id) }) }
                            AddOutfitTile({ nav.go(Routes.OUTFIT) })
                        }
                    }
                    else -> {
                        H3("Model")
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            s.models.forEach { md ->
                                val on = md.id == s.model?.id
                                Column(Modifier.width(74.dp).press { if (!md.locked) vm.toast("${md.name.substringBefore(' ')} needs close-ups first") }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
                else -> Cta(Pricing.SHOOT_LABEL, { vm.shoot(celebrate) }, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun Tiny(text: String, maxLines: Int) = T(text, muse.type.tiny.copy(fontSize = 11.5.sp), muse.t.muted, maxLines = maxLines)

/** The final prompt broken down by slot (`.pbox`). */
@Composable
fun PromptBox(p: BuiltPrompt) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        p.slots.forEach { slot ->
            Row {
                T(slot.layer.key.uppercase(), m.type.mono.copy(fontSize = 10.sp, letterSpacing = .08.em), m.t.muted, Modifier.width(74.dp))
                T(slot.body, m.type.body.copy(fontSize = 12.5.sp, lineHeight = 17.sp), m.t.ink, Modifier.weight(1f))
            }
        }
    }
}
