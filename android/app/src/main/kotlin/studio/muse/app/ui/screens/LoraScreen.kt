package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
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
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Lora
import studio.muse.app.data.LoraCandidate
import studio.muse.app.data.Model
import studio.muse.app.platform.SoundFx
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing

data class LoraState(val model: Model? = null, val lora: Lora = Lora(""), val balance: Double = 0.0) {
    val trainCost get() = Pricing.loraTrainCost
    val low get() = trainCost > balance + 1e-9
}

class LoraViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<LoraState> = combine(c.repo.state, c.drafts.modelId) { s, mid ->
        val model = s.model(mid) ?: s.models.firstOrNull()
        LoraState(model, s.lora(model?.id), s.balance.balance)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, LoraState())

    private val id get() = state.value.model?.id
    fun build() = viewModelScope.launch {
        val m = id ?: return@launch
        if (Pricing.LORA_SET_COST > state.value.balance + 1e-9) return@launch c.repo.toast("Not enough balance · top up in Credits", Routes.CREDITS)
        if (c.repo.buildLoraSet(m) != null) c.sound.play(SoundFx.Kind.GO)
    }
    fun toggle(cand: LoraCandidate) = viewModelScope.launch { id?.let { c.repo.keepCandidate(it, cand.id, !cand.keep) } }
    fun train() = viewModelScope.launch { id?.let { if (c.repo.trainLora(it) != null) c.sound.play(SoundFx.Kind.GO) } }
    fun use(v: Boolean) = viewModelScope.launch { id?.let { c.repo.setLoraUse(it, v) } }
    fun retrain() = viewModelScope.launch { id?.let { c.repo.retrainLora(it) } }
    fun toast(s: String) = c.repo.toast(s)
}

/** The profile tile line (prototype features.js loraLine). */
fun loraLine(l: Lora): String = when (l.state) {
    "building" -> "Building training set…"
    "review" -> if (l.version > 0) "v${l.version} ${if (l.use) "on" else "off"} · reviewing" else "Review the training set"
    "training" -> "Training · ${l.progress.toInt()}%"
    "ready" -> "v${l.version} ready · ${if (l.use) "on" else "off"}"
    "failed" -> "Training failed · refunded"
    else -> "Not trained · locks face + physique"
}

private fun minutesText(min: Int) = if (min >= 60) "${min / 60} h ${min % 60} min" else "$min min"

@Composable
fun LoraScreen() {
    val c = LocalContainer.current
    val vm: LoraViewModel = viewModel { LoraViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val l = s.lora
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Identity LoRA", onBack = { nav.back() })
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 130.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                when (l.state) {
                    "building" -> LoraGenerating()
                    "review" -> LoraReview(l, vm::toggle)
                    "training" -> LoraTraining(l)
                    "ready" -> LoraDone(l, s.model, vm::use, vm::retrain)
                    else -> LoraIntro(s.model)
                }
            }
        }
        Dock {
            when (l.state) {
                "building" -> Cta("Generating…", {}, Modifier.weight(1f), off = true, busy = true, sound = null)
                "review" -> when {
                    l.kept < Pricing.LORA_MIN_KEEP -> Cta("Keep ${Pricing.LORA_MIN_KEEP - l.kept} more to train", { vm.toast("Keep at least 20 shots so the LoRA learns her well") }, Modifier.weight(1f), off = true)
                    s.low -> Cta("Top up to train · ${Pricing.money(s.trainCost)}", { nav.go(Routes.CREDITS) }, Modifier.weight(1f))
                    else -> Cta("Train · ~${minutesText(Pricing.loraTrainMinutes)} · ${Pricing.money(s.trainCost)}", vm::train, Modifier.weight(1f), sound = null)
                }
                "training" -> Cta2("Back to profile", { nav.back() }, Modifier.weight(1f))
                "ready" -> Cta("Test it in a photoshoot", { nav.go(Routes.SHOOT) }, Modifier.weight(1f))
                else -> Cta("Build training set · ${Pricing.money(Pricing.LORA_SET_COST)}", vm::build, Modifier.weight(1f), sound = null)
            }
        }
    }
}

@Composable
private fun small() = muse.type.body.copy(fontSize = 14.sp, lineHeight = 20.sp)

@Composable
private fun LoraHero(img: String, title: String, sub: String) {
    val m = muse
    val shape = RoundedCornerShape(m.t.rLg)
    Box(Modifier.fillMaxWidth().height(180.dp).clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }) {
        RefImage(ImageRef.asset(img), Modifier.fillMaxSize(), 20)
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = .65f))))
                .padding(start = 14.dp, end = 14.dp, top = 30.dp, bottom = 12.dp),
        ) {
            T(title, m.type.body.copy(fontWeight = FontWeight.Bold), Color.White)
            T(sub, m.type.tiny, Color.White)
        }
    }
}

/** A `.list` row: optional icon, a bold title with a muted line under it, and a trailing control. */
@Composable
fun TwoLineRow(title: String, sub: String?, icon: String? = null, onClick: (() -> Unit)? = null, lead: (@Composable () -> Unit)? = null, trailing: (@Composable () -> Unit)? = null) {
    val m = muse
    Row(
        Modifier.fillMaxWidth().heightIn(min = 58.dp).let { if (onClick != null) it.press(onClick = onClick) else it }.padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (lead != null) lead() else if (icon != null) Ic(icon, 20.dp)
        Column(Modifier.weight(1f)) {
            T(title, m.type.body.copy(fontWeight = if (sub != null) FontWeight.Bold else FontWeight.Normal), m.t.ink)
            if (sub != null) Tiny(sub)
        }
        trailing?.invoke()
    }
}

@Composable
fun ListDivider() {
    val m = muse
    Box(Modifier.fillMaxWidth().height(m.t.stroke).background(m.t.line))
}

@Composable
private fun LoraIntro(model: Model?) {
    val m = muse
    LoraHero("hero", model?.name ?: "Your model", "6 reference shots · no LoRA yet")
    Text(
        buildAnnotatedString {
            append("A LoRA is a small add-on trained on one model. It keeps her ")
            withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("face and physique") }
            append(" the same in every photo and video, beyond what 6 reference shots can hold.")
        },
        style = small(), color = m.t.ink,
    )
    ListGroup {
        TwoLineRow("Photo LoRA", "For photoshoots · ~${Pricing.LORA_PHOTO_MIN} min", "camera")
        ListDivider()
        TwoLineRow("Video LoRA", "For H3 videos · ~${Pricing.LORA_VIDEO_MIN} min", "studio")
    }
    Field("How it works") {
        listOf("We generate 30 varied shots from her sheet", "You keep the ones that look like her", "We train both LoRAs on what you kept").forEachIndexed { i, t ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(24.dp).clip(CircleShape).background(if (m.isD) m.t.blue else m.t.accent).let { if (m.isD) it.border(2.dp, Ink, CircleShape) else it }, contentAlignment = Alignment.Center) {
                    T("${i + 1}", m.type.body.copy(fontSize = 12.sp, fontWeight = FontWeight.Bold), if (m.isD) Color.White else m.t.accentInk)
                }
                T(t, m.type.body.copy(fontSize = 13.sp), m.t.ink)
            }
        }
    }
}

@Composable
private fun ColumnScope.LoraGenerating() {
    T("Generating 30 shots: new angles, outfits, light and expressions, full body included so her physique is learned too.", small(), muse.t.ink)
    Grid4((0 until 12).toList()) { _, mod -> Box(mod.background(muse.t.surface2).shimmer()) }
}

/** 4-column grid of 3:4 tiles (`.lgrid`). */
@Composable
private fun <T> Grid4(items: List<T>, tile: @Composable (T, Modifier) -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r * .6f)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items.chunked(4).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                row.forEach { item -> Box(Modifier.weight(1f)) { tile(item, Modifier.fillMaxWidth().aspectRatio(.75f).clip(shape)) } }
                repeat(4 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

private val dropped = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }.also { cm ->
    val b = .55f
    cm *= ColorMatrix(floatArrayOf(b, 0f, 0f, 0f, 0f, 0f, b, 0f, 0f, 0f, 0f, 0f, b, 0f, 0f, 0f, 0f, 0f, 1f, 0f))
})

@Composable
private fun LoraReview(l: Lora, toggle: (LoraCandidate) -> Unit) {
    val m = muse
    RowB {
        T("${l.kept} kept", m.type.h3, m.t.ink)
        val ok = l.kept >= Pricing.LORA_MIN_KEEP
        Pill(if (ok) "Enough to train" else "Keep at least ${Pricing.LORA_MIN_KEEP}", if (ok) "good" else "warn")
    }
    Tiny("Tap a shot to drop it. Drop anything that doesn't look like her, or shows a tattoo or ring. ${l.flagged} were flagged for you.")
    Grid4(l.candidates) { cnd, mod ->
        Box(mod.press(SoundFx.Kind.TICK) { toggle(cnd) }) {
            RefImage(cnd.image, Modifier.fillMaxSize(), 15, if (cnd.keep) null else dropped)
            if (cnd.flag != null) {
                Box(Modifier.align(Alignment.BottomStart).padding(4.dp).clip(RoundedCornerShape(999.dp)).background(Color(0xFFF6E2C0)).padding(horizontal = 6.dp, vertical = 1.dp)) {
                    T(cnd.flag, m.type.tiny.copy(fontSize = 10.sp, lineHeight = 13.sp, fontWeight = FontWeight.Bold), Color(0xFF6B3F00))
                }
            }
            Box(
                Modifier.align(Alignment.TopEnd).padding(4.dp).size(20.dp).clip(CircleShape).background(if (cnd.keep) (if (m.isD) m.t.blue else m.t.accent) else Color.White),
                contentAlignment = Alignment.Center,
            ) {
                if (cnd.keep) Ic("check", 13.dp, if (m.isD) Color.White else m.t.accentInk) else T("✕", m.type.tiny.copy(fontSize = 11.sp, fontWeight = FontWeight.Bold), Ink)
            }
        }
    }
}

@Composable
private fun LoraTraining(l: Lora) {
    val m = muse
    LoraHero("face", "Training on ${l.kept} shots", "You can leave this screen. We'll notify you.")
    listOf("Photo LoRA" to l.photo.progress, "Video LoRA" to l.video.progress).forEach { (name, p) ->
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            RowB { T(name, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); T("${p.toInt()}%", m.type.mono.copy(fontSize = 11.5.sp), m.t.ink) }
            Bar((p / 100).toFloat(), Modifier.fillMaxWidth(), color = if (m.isD) m.t.blue else m.t.accent, height = 6.dp)
        }
    }
    val left = ((100 - l.progress) / 100 * Pricing.loraTrainMinutes).toInt().coerceAtLeast(1)
    T("~$left min left · demo runs 120× faster", m.type.mono.copy(fontSize = 11.5.sp), m.t.muted)
}

@Composable
private fun LoraDone(l: Lora, model: Model?, use: (Boolean) -> Unit, retrain: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r * .6f)
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        listOf(Triple("c_face", "References only", false), Triple("face", "With LoRA v${l.version}", true)).forEach { (img, label, bold) ->
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                RefImage(ImageRef.asset(img), Modifier.fillMaxWidth().aspectRatio(.75f).clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }, 15)
                T(label, m.type.tiny, if (bold) m.t.ink else m.t.muted, weight = if (bold) FontWeight.Bold else null)
            }
        }
    }
    Tiny("Same prompt and seed. The LoRA keeps her face shape, freckles and build steady across angles.")
    ListGroup {
        TwoLineRow("Use in new renders", "Photos and videos · identity + physique") { Toggle(l.use, { use(!l.use) }) }
        ListDivider()
        TwoLineRow("Trained on", null) { T("${l.trainedOn ?: l.kept} shots · v${l.version}", m.type.mono.copy(fontSize = 11.5.sp), m.t.ink) }
        ListDivider()
        TwoLineRow("Retrain with more shots", null, onClick = retrain) { Ic("chev", 16.dp) }
    }
    if (model != null && l.use) Tiny("Prompts now add “+ LoRA ${studio.muse.core.LoraToken.of(model.name, l.version)}”.")
}

/** The two profile tiles above the dock: Identity LoRA and Accounts (`.pex`). */
@Composable
fun ProfileExtras(lora: Lora, connected: Int, onLora: () -> Unit, onAccounts: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ProfileTile("spark", "Identity LoRA", loraLine(lora), onLora, Modifier.weight(1f))
        ProfileTile("export", "Accounts", "$connected of 5 connected", onAccounts, Modifier.weight(1f))
    }
}

@Composable
private fun ProfileTile(icon: String, title: String, sub: String, onClick: () -> Unit, modifier: Modifier) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    val bg = if (m.isB) Color(0xFF17191B) else m.t.surface
    var mod = modifier.heightIn(min = 52.dp)
    mod = if (m.isD) mod.hardShadow(3.dp, m.t.r) else mod
    mod = mod.clip(shape).background(bg).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape)
    Row(mod.press(onClick = onClick).padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Ic(icon, 18.dp, m.t.ink)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, m.type.body.copy(fontSize = 13.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(sub, m.type.tiny.copy(fontSize = 11.5.sp, lineHeight = 14.sp), m.t.muted, maxLines = 1)
        }
    }
}
