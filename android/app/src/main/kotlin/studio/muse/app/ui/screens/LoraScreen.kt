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
import androidx.compose.foundation.layout.width
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
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import studio.muse.core.Pricing

data class LoraState(val model: Model? = null, val lora: Lora = Lora(""), val balance: Double = 0.0, val photo: studio.muse.core.PhotoPrices = studio.muse.core.PhotoPrices(),
    /** The in-app demo studio (its bundled sample stills and sped-up clock); never true against a real server. */
    val demo: Boolean = false) {
    /** Pass-through: the estimate held for the 30 training shots ("about $3.03"). */
    val setCost get() = studio.muse.core.PhotoPricing.loraSet(photo)
    val trainCost get() = Pricing.loraTrainCost
    val low get() = trainCost > balance + 1e-9
}

class LoraViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<LoraState> = combine(c.repo.state, c.drafts.modelId) { s, mid ->
        val model = s.model(mid) ?: s.models.firstOrNull()
        LoraState(model, s.lora(model?.id), s.balance.balance, s.photo, c.repo.demo)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, LoraState())

    private val id get() = state.value.model?.id
    fun build() = viewModelScope.launch {
        val m = id ?: return@launch
        if (state.value.setCost > state.value.balance + 1e-9) return@launch c.repo.toast(lowFundsMessage(c), Routes.CREDITS)
        c.repo.buildLoraSet(m)
    }
    fun toggle(cand: LoraCandidate) = viewModelScope.launch { id?.let { c.repo.keepCandidate(it, cand.id, !cand.keep) } }
    fun train() = viewModelScope.launch { id?.let { c.repo.trainLora(it) } }
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
    else -> "Not trained yet"
}

private fun minutesText(min: Int) = if (min >= 60) "${min / 60} h ${min % 60} min" else "$min min"

@Composable
fun LoraScreen() {
    val c = LocalContainer.current
    val vm: LoraViewModel = viewModel { LoraViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val l = s.lora
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Identity LoRA", onBack = { nav.back() })
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5),
            ) {
                when (l.state) {
                    "building" -> LoraGenerating()
                    "review" -> LoraReview(l, vm::toggle)
                    "training" -> LoraTraining(l, s.model, s.demo)
                    "ready" -> LoraDone(l, s.model, s.demo, vm::use, vm::retrain)
                    "failed" -> {
                        Notice("Training didn't finish, and the cost was refunded. Build a new training set to try again.", tone = NoticeTone.DANGER)
                        LoraIntro(s.model)
                    }
                    else -> LoraIntro(s.model)
                }
            }
        }
        ActionDock {
            when (l.state) {
                "building" -> PrimaryButton("Building the training set…", {}, Modifier.weight(1f), busy = true)
                "review" -> when {
                    l.kept < Pricing.LORA_MIN_KEEP -> PrimaryButton("Keep ${Pricing.LORA_MIN_KEEP - l.kept} more to train", { vm.toast("Keep at least 20 shots so the LoRA learns her well") }, Modifier.weight(1f), off = true)
                    s.low -> PrimaryButton("Top up to train · ${Pricing.money(s.trainCost)}", { nav.go(Routes.CREDITS) }, Modifier.weight(1f))
                    else -> PrimaryButton("Train · about ${minutesText(Pricing.loraTrainMinutes)} · ${Pricing.money(s.trainCost)}", vm::train, Modifier.weight(1f))
                }
                "training" -> SecondaryButton("Back to profile", { nav.back() }, Modifier.weight(1f))
                "ready" -> PrimaryButton("Test it in a photoshoot", { nav.go(Routes.SHOOT) }, Modifier.weight(1f))
                else -> PrimaryButton("Build training set · ${studio.muse.core.PhotoPricing.about(s.setCost)}", vm::build, Modifier.weight(1f))
            }
        }
    }
}

/** Her picture, then a title and one line under it (no text over the photo). */
@Composable
private fun LoraHero(img: ImageRef?, title: String, sub: String) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Box(Modifier.fillMaxWidth().height(200.dp).clip(containerShape()).background(m.roles.field)) { RefImage(img, Modifier.fillMaxSize(), 20) }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, m.scale.heading, m.roles.ink)
            Caption(sub)
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
    LoraHero(model?.cover, model?.name ?: "Your model", "${model?.filled ?: 0} reference shots · no LoRA yet")
    Text(
        buildAnnotatedString {
            append("A LoRA is a small add-on trained on one model. It keeps her ")
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold, color = m.roles.ink)) { append("face and physique") }
            append(" the same in every photo and video, beyond what reference shots alone can hold.")
        },
        style = m.scale.body, color = m.roles.ink2,
    )
    Column {
        RowItem("Photo LoRA", "For photoshoots · about ${Pricing.LORA_PHOTO_MIN} min")
        RowItem("Video LoRA", "For videos · about ${Pricing.LORA_VIDEO_MIN} min")
    }
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Heading("How it works")
        listOf("We make 30 varied shots from her character sheet.", "You keep the ones that look like her.", "We train both LoRAs on what you kept.").forEachIndexed { i, t ->
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                T("${i + 1}", m.scale.body.tabular(), m.roles.ink2, Modifier.width(16.dp))
                T(t, m.scale.body, m.roles.ink, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun LoraGenerating() {
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
        Body("Making 30 shots: new angles, outfits, light and expressions, full body included so her physique is learned too.")
        Grid4((0 until 12).toList()) { _, mod -> Skeleton(mod) }
    }
}

/** 4-column grid of 3:4 tiles. */
@Composable
private fun <T> Grid4(items: List<T>, tile: @Composable (T, Modifier) -> Unit) {
    val shape = controlShape()
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        items.chunked(4).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
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
    val ok = l.kept >= Pricing.LORA_MIN_KEEP
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        T("${l.kept} kept", m.scale.title.tabular(), m.roles.ink)
        T(if (ok) "Enough to train" else "Keep at least ${Pricing.LORA_MIN_KEEP} to train", m.scale.caption, if (ok) m.roles.positive else m.roles.caution)
        Caption("Tap a shot to drop it. Drop anything that doesn't look like her, or shows a tattoo or ring. ${l.flagged} were flagged for you.")
    }
    Grid4(l.candidates) { cnd, mod ->
        Box(mod.background(m.roles.field).press { toggle(cnd) }.semantics { contentDescription = if (cnd.keep) "Kept" else "Dropped" }) {
            RefImage(cnd.image, Modifier.fillMaxSize(), 15, if (cnd.keep) null else dropped)
            // One caption on a scrim where the picture needs it: why it was flagged, or that it's dropped.
            val note = cnd.flag ?: if (!cnd.keep) "Dropped" else null
            if (note != null) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 3.dp)) {
                T(note, m.scale.micro, Color.White, maxLines = 1)
            }
        }
    }
}

@Composable
private fun LoraTraining(l: Lora, model: Model?, demo: Boolean) {
    val m = muse
    LoraHero(model?.slot("face")?.image ?: model?.cover, "Training on ${l.kept} shots", "You can leave this screen. We'll notify you when it's done.")
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
        listOf("Photo LoRA" to l.photo.progress, "Video LoRA" to l.video.progress).forEach { (name, p) ->
            Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                RowB { T(name, m.scale.body, m.roles.ink); RowValue("${p.toInt()}%", m.roles.ink) }
                ProgressLine((p / 100).toFloat(), Modifier.fillMaxWidth())
            }
        }
        val left = ((100 - l.progress) / 100 * Pricing.loraTrainMinutes).toInt().coerceAtLeast(1)
        Caption("About $left min left" + if (demo) " · the demo runs 120× faster" else "")
    }
}

@Composable
private fun LoraDone(l: Lora, model: Model?, demo: Boolean, use: (Boolean) -> Unit, retrain: () -> Unit) {
    val m = muse
    // The side-by-side is the demo's bundled pair; a real studio has no "with LoRA" still yet, so it shows her own photo.
    if (demo) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            listOf(Triple("c_face", "References only", false), Triple("face", "With LoRA v${l.version}", true)).forEach { (img, label, mine) ->
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    RefImage(ImageRef.asset(img), Modifier.fillMaxWidth().aspectRatio(.75f).clip(containerShape()), 15)
                    T(label, m.scale.caption, if (mine) m.roles.ink else m.roles.ink2)
                }
            }
        }
        Caption("Same prompt and seed. The LoRA keeps her face shape and build steady across angles.")
    } else LoraHero(model?.slot("face")?.image ?: model?.cover, "LoRA v${l.version} ready", "Keeps her face shape and build steady across angles.")
    Column {
        RowItem("Use in new renders", "Photos and videos · identity and physique", onClick = { use(!l.use) }) { Toggle(l.use, { use(!l.use) }) }
        RowItem("Trained on") { RowValue("${l.trainedOn ?: l.kept} shots · v${l.version}") }
        RowItem("Retrain with more shots", onClick = retrain) { Chevron() }
    }
    if (model != null && l.use) Caption("Prompts now add “+ LoRA ${studio.muse.core.LoraToken.of(model.name, l.version)}”.")
}

/** Identity LoRA and Accounts on her profile: two plain rows. */
@Composable
fun ProfileExtras(lora: Lora, connected: Int, onLora: () -> Unit, onAccounts: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(top = MuseSpace.s2)) {
        RowItem("Identity LoRA", loraLine(lora), onClick = onLora) { Chevron() }
        RowItem("Accounts", "$connected of 5 connected", onClick = onAccounts) { Chevron() }
    }
}
