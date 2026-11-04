package studio.muse.app.ui.screens

import android.Manifest
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
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
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.Clip
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.data.SampleData
import studio.muse.app.data.VideoDraft
import studio.muse.app.data.VideoFeatures
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Pricing
import studio.muse.core.VideoOption
import kotlin.math.atan2
import kotlin.math.roundToInt

data class VideoState(
    val draft: VideoDraft = VideoDraft(),
    val models: List<Model> = emptyList(),
    val model: Model? = null,
    val outfits: List<Outfit> = emptyList(),
    val outfit: Outfit? = null,
    val balance: Double = 0.0,
    val fastBeta: Boolean = true,
    val checking: Boolean = false,
    val starting: Boolean = false,
    /** The quality picker's options and live prices (features.video). */
    val video: VideoFeatures = VideoFeatures.DEFAULT,
) {
    val clip: Clip? get() = draft.clip
    val spec get() = draft.spec(video.pricePerSec(draft.quality))
    val cost get() = Pricing.totalCost(spec)
    val genLabel get() = Pricing.genLabel(spec)
}

class NewVideoViewModel(private val c: AppContainer) : ViewModel() {
    private val busy = MutableStateFlow(false to false)
    val state: StateFlow<VideoState> = combine(c.repo.state, c.drafts.video, c.drafts.modelId, c.drafts.outfitId, combine(c.prefs, busy) { p, b -> p to b }) { s, d, mid, oid, (p, b) ->
        val model = s.model(mid)?.takeIf { it.filled > 0 } ?: s.models.firstOrNull { it.locked }
        val outfits = s.outfitsOf(model?.id)
        val video = s.video ?: VideoFeatures.DEFAULT
        var draft = if (!p.fastBeta && d.engine == Engine.VIGGLE) d.copy(engine = Engine.H3) else d
        // A quality the server can't run right now falls back to the first one it can (Replicate not set up → Exact edit).
        if (!video.available(draft.option.id)) VideoOption.entries.firstOrNull { video.available(it.id) }?.let { draft = draft.pick(it) }
        VideoState(draft, s.models, model, outfits, outfits.firstOrNull { it.id == oid } ?: outfits.firstOrNull(), s.balance.balance, p.fastBeta, b.first, b.second, video)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, VideoState())

    fun edit(f: (VideoDraft) -> VideoDraft) = c.drafts.video.update(f)

    fun steps(n: Int) {
        val v = Pricing.clampSteps(n)
        if (v != c.drafts.video.value.steps) edit { it.copy(steps = v) }
    }

    fun sample(bad: Boolean) = viewModelScope.launch {
        busy.update { true to it.second }
        val clip = c.repo.uploadClip(if (bad) SampleData.badMeta else SampleData.sampleMeta, null)
        busy.update { false to it.second }
        if (clip != null) { edit { it.copy(clip = clip, showBadExample = bad) }; creatingStarted() }
    }

    /** A clip from the Android Photo Picker: read its real metadata, upload it, run the checks. */
    fun pick(uri: Uri) = viewModelScope.launch {
        val media = c.media ?: return@launch
        busy.update { true to it.second }
        try {
            val meta = media.clipMeta(uri)
            val thumb = media.clipThumb(uri)
            val bytes = if (c.repo.api is studio.muse.app.data.HttpMuseApi) media.bytes(uri) else null
            val clip = c.repo.uploadClip(meta, bytes, media.mime(uri).takeIf { it.startsWith("video/") } ?: "video/mp4") ?: return@launch
            edit { it.copy(clip = clip.copy(thumb = thumb?.let { t -> ImageRef(url = t) }), showBadExample = false) }
            creatingStarted()
        } catch (e: Exception) {
            c.repo.toast("Couldn't read that clip")
        } finally {
            busy.update { false to it.second }
        }
    }

    fun selectModel(m: Model) {
        if (m.filled == 0) return c.repo.toast("${m.name.substringBefore(' ')} needs close-ups first")
        c.drafts.modelId.value = m.id
        c.repo.state.value.outfitsOf(m.id).firstOrNull()?.let { c.drafts.outfitId.value = it.id }
    }

    fun selectOutfit(o: Outfit) { c.drafts.outfitId.value = o.id }
    fun toast(s: String) = c.repo.toast(s)
    fun reset() { c.drafts.resetVideo(); c.repo.toast("Reset to recommended") }

    fun generate(onStarted: () -> Unit) {
        val s = state.value
        val clip = s.clip ?: return c.repo.toast("Pick a clip first")
        val model = s.model ?: return c.repo.toast("Pick a model first")
        if (!clip.ok) return c.repo.toast("Fix the clip checks first")
        if (s.cost > s.balance + 1e-9) return c.repo.toast(lowFundsMessage(c), Routes.CREDITS)
        viewModelScope.launch {
            busy.update { it.first to true }
            val job = c.repo.createJob(
                s.draft.request(clip.name, model.id, s.outfit?.id ?: "", clip.id, clip.takeIf { it.id != SampleData.SAMPLE_CLIP }?.durationSec),
            )
            delay(900)
            busy.update { it.first to false }
            if (job != null) onStarted()
        }
    }

    /**
     * Keep GPU warm: creating started (a clip picked or uploaded, or the video studio opened). Nudges once per flow, and
     * only for Exact edit: Draft / Standard / HD run on Replicate and never use our GPU.
     */
    fun creatingStarted() { if (c.drafts.video.value.engine == Engine.H3) c.warmUi.creatingStarted(c.repo.state.value.warm) }

    /** The quality picker. Switching to Exact edit is when creating on our GPU starts (the warm nudge, once per flow). */
    fun pickOption(o: VideoOption) {
        edit { it.pick(o) }
        if (o == VideoOption.EXACT) creatingStarted()
    }
    fun enterFlow() = c.warmUi.enterFlow()
    fun leaveFlow() = c.warmUi.leaveFlow()

    fun markNotifAsked() = viewModelScope.launch { c.prefsStore.update { it.copy(notifAsked = true) } }
    val notifAsked get() = c.prefs.value.notifAsked
}

@Composable
private fun videoVm(): NewVideoViewModel {
    val c = LocalContainer.current
    return viewModel { NewVideoViewModel(c) }
}

// ======================================================================= Source (New video)

@Composable
fun SourceScreen() {
    val vm = videoVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) vm.pick(uri) }
    val pickVideo = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) }
    val clip = s.clip
    DisposableEffect(Unit) { vm.enterFlow(); onDispose { vm.leaveFlow() } }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("New video", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (clip == null) {
                    T("Pick a short vertical clip with one person. We check it before you spend anything.", m.type.body, m.t.muted)
                    Opt(if (s.checking) "Checking your clip…" else "Choose from camera roll", "Up to 15s · 9:16 · one person · no watermark", icon = "upload", onClick = pickVideo)
                    Opt("Use the sample clip", "Living-room dance · 9.4s · 1080×1920", icon = "play", onClick = { vm.sample(false) })
                    T("Preview: what a failing clip looks like", m.type.tiny, if (m.isD) m.t.blue else m.t.accent, Modifier.press { vm.sample(true) }.padding(vertical = 6.dp))
                } else {
                    ClipCard(clip)
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        T(if (s.draft.showBadExample) "Use the good sample clip" else "Preview: what a failing clip looks like", m.type.tiny, if (m.isD) m.t.blue else m.t.accent,
                            Modifier.press { vm.sample(!s.draft.showBadExample) }.padding(vertical = 6.dp))
                        Spacer(Modifier.weight(1f))
                        T("Change clip", m.type.tiny.copy(fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.press(onClick = pickVideo).padding(vertical = 6.dp))
                    }
                    if (clip.ok) {
                        val len = clip.takeIf { it.id != SampleData.SAMPLE_CLIP }?.durationSec
                        if (s.draft.exact) Field("Use · price at ${s.draft.steps} steps") {
                            Seg(ClipUse.entries.map { it.id to Pricing.sourceOption(it, s.draft.steps, len) }, s.draft.use.id, { k -> vm.edit { it.copy(use = ClipUse.fromId(k)) } }, small = false)
                        } else if (s.draft.replicate) Field("Use") {
                            T("Whole clip · ${s.spec.replicateSeconds} s · ${s.draft.quality.label} ${Pricing.priceLine(s.spec)}", m.type.body, m.t.ink)
                        }
                    }
                }
            }
        }
        Dock {
            when {
                clip == null -> Cta("Pick a clip to continue", { pickVideo() }, Modifier.weight(1f), off = true)
                !clip.ok -> Cta("Fix the clip to continue", { vm.toast("Fix the clip checks first") }, Modifier.weight(1f), off = true)
                else -> Cta("Next: Direct", { nav.go(Routes.DIRECT) }, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun ClipCard(clip: Clip) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = Modifier.fillMaxWidth()
    mod = when {
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        m.isA -> mod.clip(shape).border(1.dp, m.t.line, shape)
        else -> mod.clip(shape).background(m.t.surface).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape)
    }
    Row(mod.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        val ts = RoundedCornerShape(m.t.r * .6f)
        Box(Modifier.size(92.dp, 164.dp).clip(ts).let { if (m.isD) it.border(2.5.dp, Ink, ts) else it }) {
            if (clip.thumb != null) { RefImage(clip.thumb, Modifier.fillMaxSize(), 30); PlayBadge() } else ClipPlaceholder(Modifier.fillMaxSize(), clip.name.length)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            clip.checks.forEach { ck ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    RowB {
                        T(ck.label, m.type.tiny, m.t.ink, Modifier.weight(1f), maxLines = 2)
                        Pill((if (ck.status == "bad") "✕ " else if (ck.status == "good") "✓ " else "") + ck.value, if (ck.status == "bad") "warn" else ck.status.takeIf { it == "good" } ?: "")
                    }
                    ck.fix?.let { T(it, m.type.tiny, m.t.warn) }
                }
            }
        }
    }
}

// ======================================================================= Direct (Video studio)

@Composable
fun DirectScreen() {
    val vm = videoVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val d = s.draft
    val notif = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    val container = LocalContainer.current
    val studio by container.repo.state.collectAsState()
    // Opening the video studio (Generate) starts creating: the Keep GPU warm nudge, unless this flow already had it.
    DisposableEffect(Unit) { vm.enterFlow(); onDispose { vm.leaveFlow() } }
    LaunchedEffect(Unit) { vm.creatingStarted() }
    val generate = {
        if (Build.VERSION.SDK_INT >= 33 && !vm.notifAsked) { vm.markNotifAsked(); notif.launch(Manifest.permission.POST_NOTIFICATIONS) }
        vm.generate { nav.go(Routes.QUEUE) }
    }
    val menu = listOf(
        MenuItem("spark", "Show prompt") { vm.toast("Prompt: replace the performer with ${s.model?.name ?: "your model"} · keep motion & room · ${Pricing.engineLabel(s.spec)}") },
        MenuItem("quality", "Save as preset") { vm.toast("Saved as preset \"${s.clip?.name ?: "Clip"} · ${Pricing.engineLabel(s.spec)}\"") },
        MenuItem("retry", "Reset settings") { vm.reset() },
        MenuItem("studio", "Change clip") { nav.go(Routes.SOURCE) },
        MenuItem("quality", "How steps work") { vm.toast("10 steps is enough: 15 and 20 looked the same in testing") },
    )
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            if (m.isA) {
                Row(Modifier.fillMaxWidth().height(52.dp).drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }.padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    TbBtn("back", { nav.back() })
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Wordmark() }
                    T("VIDEO STUDIO", m.type.mono.copy(fontSize = 12.5.sp, letterSpacing = .12.em), m.t.ink)
                    MoreMenu(menu)
                }
            } else TopBar("Video studio", onBack = { nav.back() }) { MoreMenu(menu) }
            DirectCanvas(s)
            ToolStrip(VIDEO_TOOLS, d.tool) { k -> vm.edit { it.copy(tool = k) } }
            // Keep GPU warm is for Exact edit only (Replicate renders don't use our GPU).
            if (d.exact) WarmSwitchRow(container, studio.warm)
            BSheet(12.dp) { DirectSheet(vm, s) }
        }
        Dock(tight = true) {
            Cta(if (s.starting) (if (d.exact) "Starting GPU…" else "Starting…") else s.genLabel, { if (!s.starting) generate() }, Modifier.weight(1f), busy = s.starting, off = s.cost > s.balance)
        }
    }
}

@Composable
private fun DirectCanvas(s: VideoState) {
    val m = muse
    val track = remember { Animatable(.38f) }
    val scope = rememberCoroutineScope()
    Canvas(300.dp) {
        val clip = s.clip
        when {
            s.draft.background == "photo" -> Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFFB9C4CF), Color(0xFF6E7A86)))))
            clip?.thumb != null -> RefImage(clip.thumb, Modifier.fillMaxSize(), 25)
            else -> ClipPlaceholder(Modifier.fillMaxSize(), 1, showPlay = false)
        }
        // Who goes in: the selected model in the selected outfit.
        Box(
            Modifier.align(Alignment.TopEnd).padding(top = if (m.isB) 36.dp else 12.dp, end = 12.dp).size(64.dp, 86.dp).clip(RoundedCornerShape(10.dp))
                .border(2.dp, Color.White, RoundedCornerShape(10.dp)),
        ) { RefImage(s.outfit?.front ?: s.model?.cover, Modifier.fillMaxSize()) }
        Viewfinder(bottomInset = 44.dp)
        if (m.isB) {
            Row(Modifier.padding(start = 14.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(m.t.rec)); Spacer(Modifier.width(4.dp)); Readout("00:00:05:04")
            }
            Readout("OUTPUT 768×1344", Modifier.align(Alignment.BottomEnd).padding(end = 14.dp, bottom = 44.dp))
        }
        T(clip?.let { "Source · ${it.name}" } ?: "No clip", m.type.tiny.copy(fontSize = 11.sp), Color.White.copy(alpha = .85f), Modifier.align(Alignment.TopStart).padding(start = 14.dp, top = if (m.isB) 30.dp else 12.dp))
        Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.press { scope.launch { track.snapTo(0f); track.animateTo(1f, tween(2500, easing = LinearEasing)); track.snapTo(0f) } }) { Ic("play", 16.dp, Color.White) }
            Box(Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = .35f))) {
                Box(Modifier.fillMaxWidth(track.value).fillMaxHeight().background(Color.White))
            }
            val total = s.spec.lengthSec
            T("0:%02d / 0:%02d".format((track.value * total).toInt(), total.roundToInt()), m.type.mono.copy(fontSize = 12.5.sp), Color.White)
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.ColumnScope.DirectSheet(vm: NewVideoViewModel, s: VideoState) {
    val m = muse
    val nav = LocalNav.current
    val d = s.draft
    when (d.tool) {
        "quality" -> {
            QualityPicker(s, vm::pickOption)
            if (s.fastBeta && !d.replicate) RowB {
                Tiny("GPU engine", Modifier.weight(1f))
                Seg(listOf("h3" to "Exact edit", "viggle" to "Fast · beta"), d.engine.id, { k -> vm.edit { it.copy(engine = Engine.fromId(k)) } }, Modifier.width(210.dp), small = true)
            }
            when (d.engine) {
                Engine.VIGGLE -> NoteBox("Fast · beta renders in about 2 minutes with exact motion timing, but faces are softer and can warp slightly. Fixed quality, no steps.", warn = true)
                Engine.H3 -> StepsControl(d.steps, vm::steps, Pricing.stepsDelta(s.spec))
                Engine.REPLICATE -> Unit
            }
            RowB {
                Column(Modifier.weight(1f)) { T("Takes", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("Different seeds, compared side by side") }
                Stepper(d.takes, 1, Pricing.TAKES_MAX) { n -> vm.edit { it.copy(takes = n) } }
            }
        }
        "bg" -> {
            H3("Background")
            Opt("Keep the real room", "Best realism. Uses the clip's own background.", d.background == "keep", onClick = { vm.edit { it.copy(background = "keep") } })
            if (d.replicate) Tiny("A new background photo is on Exact edit for now.")
            else Opt("New background photo", "Vertical photo, same camera height, similar light.", d.background == "photo", onClick = { vm.edit { it.copy(background = "photo") } })
            if (!d.replicate && d.background == "photo") Field("Background motion") {
                Seg(listOf("still" to "Still", "subtle" to "Subtly alive", "busy" to "Busy"), d.motion, { k -> vm.edit { it.copy(motion = k) } })
            }
        }
        "audio" -> {
            H3("Sound")
            Opt("Keep the clip's audio", "The song or voice from your source clip.", d.keepAudio, onClick = { vm.edit { it.copy(keepAudio = true) } })
            Opt("Replace audio", "Upload a new track or voiceover.", !d.keepAudio, onClick = { vm.edit { it.copy(keepAudio = false) }; vm.toast("Pick a track or voiceover (demo)") })
            if (d.replicate) Tiny("Mouth movements follow the clip. A separate lip sync pass is on Exact edit.")
            else RowB {
                Column(Modifier.weight(1f)) { T("Lip sync", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("Only when the performer talks or sings · adds ~4 min") }
                Toggle(d.lipSync, { vm.edit { it.copy(lipSync = !it.lipSync) } })
            }
        }
        "outfit" -> {
            H3("Outfit")
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                s.outfits.forEach { o -> OutfitTile(o, o.id == s.outfit?.id, { vm.selectOutfit(o) }) }
                AddOutfitTile({ nav.go(Routes.OUTFIT) })
            }
            Tiny("Never add: ${s.model?.neverAdd?.joinToString(", ")?.ifBlank { null } ?: "nothing set"}. Removed automatically.")
        }
        else -> {
            H3("Model")
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                s.models.forEach { md ->
                    val on = md.id == s.model?.id
                    Column(Modifier.width(74.dp).press { vm.selectModel(md) }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        val shape = RoundedCornerShape(m.t.r * .6f)
                        Box(Modifier.fillMaxWidth().height(78.dp).let { if (on) it.border(2.dp, m.t.accent, shape) else it }.clip(shape)) {
                            val face = md.slot("face")?.image ?: md.cover
                            if (face != null) RefImage(face, Modifier.fillMaxSize()) else ModelInitial(md, Modifier.fillMaxSize(), 26f)
                        }
                        T(if (md.hasBothFaces) md.name.substringBefore(' ') else "${md.name.substringBefore(' ')} · needs close-ups", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
                    }
                }
            }
        }
    }
}

/**
 * The quality picker: Draft (default) / Standard / HD on Replicate, Exact edit on our GPU, with the live price
 * ("about $0.14 · 7 s") from the shared pricing formula and the server's per-second prices.
 */
@Composable
fun QualityPicker(s: VideoState, onPick: (VideoOption) -> Unit) {
    val m = muse
    val d = s.draft
    val options = VideoOption.entries.filter { s.video.available(it.id) || it == d.option }
    RowB { H3("Quality"); Pill(if (d.replicate) "MiniMax H3 · Replicate" else "MiniMax H3 · our GPU") }
    Seg(options.map { it.id to it.label }, d.option.id, { k -> onPick(VideoOption.fromId(k)) }, Modifier.fillMaxWidth())
    val info = s.video.option(d.option.id)
    val detail = info?.detail?.ifBlank { null } ?: d.option.quality?.detail ?: VideoOption.EXACT_DETAIL
    if (d.replicate) {
        RowB {
            Tiny(detail, Modifier.weight(1f))
            T(Pricing.priceLine(s.spec), m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
        }
        Tiny("Whole clip, billed per second of video. Different takes come out slightly different.")
    } else Tiny(detail)
}

@Composable
private fun Stepper(value: Int, min: Int, max: Int, onChange: (Int) -> Unit) {
    val m = muse
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Cta2("", { if (value > min) onChange(value - 1) }, icon = "back", height = 40.dp)
        T("$value", m.type.mono.copy(fontSize = 18.sp, fontWeight = FontWeight.Bold), m.t.ink)
        Cta2("", { if (value < max) onChange(value + 1) }, icon = "chev", height = 40.dp)
    }
}

/** Steps 4–30 with the per-theme control: dial plate (Camera Body) or slider (the others). */
@Composable
fun StepsControl(steps: Int, onSteps: (Int) -> Unit, delta: String) {
    val m = muse
    if (m.isB) return DialPlate(steps, onSteps)
    val shape = RoundedCornerShape(22.dp)
    Column(
        Modifier.fillMaxWidth().let { if (m.isC) it.clip(shape).background(m.t.surface).padding(16.dp) else it },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RowB {
            Lbl("Steps")
            if (m.isD) Sticker(Pricing.stepsBadge(steps, loud = true), "yellow", -5f, size = 13f)
            else Pill(Pricing.stepsBadge(steps).let { if (it == "Below tested range") "Below tested" else it }, if (steps == Pricing.STEPS_DEFAULT) "good" else "warn")
        }
        T("$steps", if (m.isA) m.type.stepNum else m.type.stepNum.copy(fontFamily = if (m.isC || m.isD) m.type.stepNum.fontFamily else m.t.mono), m.t.ink,
            if (m.isA) Modifier.fillMaxWidth() else Modifier, align = if (m.isA) androidx.compose.ui.text.style.TextAlign.Center else null)
        MuseSlider(steps, Pricing.STEPS_MIN, Pricing.STEPS_MAX, onSteps)
        Scale("4", "10", "20", "30")
        Tiny(delta)
    }
}

@Composable
private fun DialPlate(steps: Int, onSteps: (Int) -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(Brush.verticalGradient(listOf(Color(0xFF24282B), Color(0xFF121415)))).border(1.dp, Color(0xFF33373A), shape)
            .drawBehind {
                listOf(Offset(11.dp.toPx(), 11.dp.toPx()), Offset(size.width - 11.dp.toPx(), 11.dp.toPx()), Offset(11.dp.toPx(), size.height - 11.dp.toPx()), Offset(size.width - 11.dp.toPx(), size.height - 11.dp.toPx()))
                    .forEach { drawCircle(Brush.radialGradient(listOf(Color(0xFF5A5F63), Color(0xFF1C1F21)), it, 3.5.dp.toPx()), 3.5.dp.toPx(), it) }
            }.padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Lbl("Steps")
        Box(Modifier.clip(RoundedCornerShape(8.dp)).background(Color(0xFF0B0C0D)).border(1.dp, Color(0xFF2F3336), RoundedCornerShape(8.dp)).padding(horizontal = 12.dp)) {
            T("$steps", m.type.mono.copy(fontSize = 24.sp, lineHeight = 31.sp), m.t.accent)
        }
        T(Pricing.stepsBadge(steps), m.type.tiny, m.t.accent)
        RowB {
            KnobBtn("back") { onSteps(steps - 1) }
            Knob(steps, onSteps)
            KnobBtn("chev") { onSteps(steps + 1) }
        }
        Row(Modifier.fillMaxWidth().height(26.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
            repeat(27) { i ->
                val on = i + 4 == steps
                Box(Modifier.width(if (on) 3.dp else 1.5.dp).height(if (on) 26.dp else if (i % 5 == 0) 18.dp else 10.dp).background(if (on) m.t.accent else m.t.muted.copy(alpha = if (i % 5 == 0) 1f else .6f)))
            }
        }
        Scale("4", "10", "20", "30")
    }
}

@Composable
private fun KnobBtn(icon: String, onClick: () -> Unit) {
    Box(Modifier.size(34.dp).clip(CircleShape).background(Color(0xFF15181A)).border(1.dp, Color(0xFF3A3F43), CircleShape).press(onClick = onClick), contentAlignment = Alignment.Center) {
        Ic(icon, 16.dp, muse.t.muted)
    }
}

/** Camera Body's rotary knob: drag around it, 10° per step. */
@Composable
private fun Knob(steps: Int, onSteps: (Int) -> Unit) {
    val m = muse
    var start by remember { mutableStateOf<Pair<Float, Int>?>(null) }
    Box(
        Modifier.size(80.dp).pointerInput(Unit) {
            detectDragGestures(
                onDragStart = { p -> start = atan2(p.y - size.height / 2f, p.x - size.width / 2f) to steps },
                onDragEnd = { start = null },
            ) { ch, _ ->
                val st = start ?: return@detectDragGestures
                var a = atan2(ch.position.y - size.height / 2f, ch.position.x - size.width / 2f) - st.first
                if (a > Math.PI) a -= (2 * Math.PI).toFloat()
                if (a < -Math.PI) a += (2 * Math.PI).toFloat()
                onSteps(st.second + (a * 180 / Math.PI / 10).roundToInt())
            }
        }.rotate((steps - 17) * 10f).drawBehind {
            val r = size.minDimension / 2
            drawCircle(Color(0xFF31363A), r + 8.dp.toPx())
            drawCircle(Color(0xFF191C1E), r + 7.dp.toPx())
            drawCircle(Brush.radialGradient(listOf(Color(0xFF4A5055), Color(0xFF16191B)), Offset(size.width * .38f, size.height * .32f), r * 1.3f), r)
            drawLine(m.t.accent, Offset(size.width / 2, 8.dp.toPx()), Offset(size.width / 2, 28.dp.toPx()), 3.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round)
        },
    )
}
