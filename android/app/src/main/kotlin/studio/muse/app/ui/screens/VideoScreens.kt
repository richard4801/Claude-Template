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
import studio.muse.app.data.editable
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
    /** The stage (the canvas): the target, or the render started from here for this clip, model and outfit. */
    val stage: StudioStage = StudioStage.IDLE,
    /** The take picked in the stage's take switcher (null = take 1). */
    val stageTake: String? = null,
    /** Demo mode (the in-app fake): the only place the sample clip is offered. */
    val demo: Boolean = false,
) {
    val clip: Clip? get() = draft.clip
    val spec get() = draft.spec(video.pricePerSec(draft.quality))
    val cost get() = Pricing.totalCost(spec)
    val genLabel get() = Pricing.genLabel(spec)
}

private data class VideoExtras(val prefs: studio.muse.app.data.AppPrefs, val busy: Pair<Boolean, Boolean>, val started: List<String>, val take: String?)

class NewVideoViewModel(private val c: AppContainer) : ViewModel() {
    private val busy = MutableStateFlow(false to false)
    private val extras = combine(c.prefs, busy, c.stageJobs.ids, c.stageJobs.take) { p, b, ids, tk -> VideoExtras(p, b, ids, tk) }
    val state: StateFlow<VideoState> = combine(c.repo.state, c.drafts.video, c.drafts.modelId, c.drafts.outfitId, extras) { s, d, mid, oid, x ->
        val p = x.prefs
        val b = x.busy
        val model = s.model(mid)?.takeIf { it.filled > 0 } ?: s.models.firstOrNull { it.locked }
        val outfits = s.outfitsOf(model?.id)
        val outfit = outfits.firstOrNull { it.id == oid } ?: outfits.firstOrNull()
        val video = s.video ?: VideoFeatures.DEFAULT
        var draft = if (!p.fastBeta && d.engine == Engine.VIGGLE) d.pick(VideoOption.DRAFT) else d
        // An option that can't run right now falls back to the first one that can (Render first, then Edit).
        if (!video.available(draft.option.id)) (VideoOption.RENDER + VideoOption.EDIT).firstOrNull { video.available(it.id) }?.let { draft = draft.pick(it) }
        // The stage follows the newest render started from here for this clip, model and outfit (live job and take events).
        val stage = StudioStage.resolve(s.jobs, s.takes, x.started, draft.clip?.id, model?.id, outfit?.id)
        VideoState(draft, s.models, model, outfits, outfit, s.balance.balance, p.fastBeta, b.first, b.second, video, stage, x.take, c.repo.demo)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, VideoState())

    fun edit(f: (VideoDraft) -> VideoDraft) = c.drafts.video.update(f)

    /** The bundled sample clips: demo mode only (no sample performer on a server). */
    fun sample(bad: Boolean) = viewModelScope.launch {
        if (!c.repo.demo) return@launch
        busy.update { true to it.second }
        val clip = c.repo.uploadClip(if (bad) SampleData.badMeta else SampleData.sampleMeta, null)
        busy.update { false to it.second }
        if (clip != null) edit { it.withClip(clip).copy(showBadExample = bad) }
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
            edit { it.withClip(clip.copy(thumb = thumb?.let { t -> ImageRef(url = t) })).copy(showBadExample = false) }
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

    /** Generate (and the stage's Generate again / Try again): the render shows on the stage, so the studio stays open. */
    fun generate() {
        val s = state.value
        if (s.starting) return
        val clip = s.clip ?: return c.repo.toast("Pick a clip first")
        val model = s.model ?: return c.repo.toast("Pick a model first")
        if (s.cost > s.balance + 1e-9) return c.repo.toast(lowFundsMessage(c), Routes.CREDITS)
        viewModelScope.launch {
            busy.update { it.first to true }
            val job = c.repo.createJob(
                s.draft.request(clip.name, model.id, s.outfit?.id ?: "", clip.id, clip.takeIf { it.id != SampleData.SAMPLE_CLIP }?.durationSec),
            )
            busy.update { it.first to false }
            if (job != null) {
                c.stageJobs.started(job.id)
                val n = job.request.takes
                c.repo.toast("Rendering ${if (n > 1) "$n takes" else "1 take"} · ${Pricing.money(job.cost)}. You'll get a notification when it's done.", Routes.QUEUE)
            }
        }
    }

    /** The stage's take switcher. */
    fun pickTake(id: String) { c.stageJobs.take.value = id }

    /** Render (Draft / Standard / HD) or an add-on (Edit, Fast · beta). */
    fun pickOption(o: VideoOption) = edit { it.pick(o) }

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
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("New video", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (clip == null) {
                    T("Pick a short vertical clip with one person. We check it before you spend anything.", m.type.body, m.t.muted)
                    EmptyClipArea(s.checking, pickVideo)
                    // The sample clip and the failing-clip preview are demo mode's only.
                    if (s.demo) {
                        Opt("Use the sample clip", "Living-room dance · 9.4s · 1080×1920", icon = "play", onClick = { vm.sample(false) })
                        T("Preview: what a failing clip looks like", m.type.tiny, if (m.isD) m.t.blue else m.t.accent, Modifier.press { vm.sample(true) }.padding(vertical = 6.dp))
                    }
                } else {
                    ClipCard(clip)
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (s.demo) T(if (s.draft.showBadExample) "Use the good sample clip" else "Preview: what a failing clip looks like", m.type.tiny, if (m.isD) m.t.blue else m.t.accent,
                            Modifier.weight(1f, fill = false).press { vm.sample(!s.draft.showBadExample) }.padding(vertical = 6.dp), maxLines = 2)
                        Spacer(Modifier.weight(1f))
                        T("Change clip", m.type.tiny.copy(fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.press(onClick = pickVideo).padding(vertical = 6.dp))
                    }
                    if (!clip.ok) NoteBox(CLIP_DISCLAIMER, warn = true)
                    run {
                        val len = clip.takeIf { it.id != SampleData.SAMPLE_CLIP }?.durationSec
                        Field("Use") {
                            T("Whole clip · ${s.draft.option.label} · ${Pricing.optionPriceLine(s.spec)}", m.type.body, m.t.ink)
                        }
                    }
                }
            }
        }
        Dock {
            when {
                clip == null -> Cta("Pick a clip to continue", { pickVideo() }, Modifier.weight(1f), off = true)
                else -> Cta("Next: Direct", { nav.go(Routes.DIRECT) }, Modifier.weight(1f))
            }
        }
    }
}

/** Nothing uploaded yet: an empty, dashed area to choose a clip (never a sample performer). */
@Composable
private fun EmptyClipArea(checking: Boolean, onPick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.fillMaxWidth().height(220.dp).clip(shape).background(m.t.surface2.copy(alpha = .6f)).dashed(if (m.isD) Ink else m.t.muted.copy(alpha = .55f), m.t.r, if (m.isD) 2.5.dp else 1.5.dp)
            .press(onClick = onPick).padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
    ) {
        Box(Modifier.size(52.dp).clip(CircleShape).background(m.t.surface).let { if (m.isD) it.border(2.dp, Ink, CircleShape) else it }, contentAlignment = Alignment.Center) {
            Ic("upload", 24.dp, m.t.ink)
        }
        T(if (checking) "Checking your clip…" else StudioText.CHOOSE_TITLE, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
        T(StudioText.CHOOSE_HINT, m.type.tiny, m.t.muted, align = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

/** Shown when a clip misses a check: generating is still allowed (owner decision). */
const val CLIP_DISCLAIMER = "This clip doesn't meet every recommendation. You can still generate, but results may be weaker: " +
    "low resolution looks softer, extra people or watermarks can confuse the swap, and only the first 15 s of a longer clip is used."

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
    val generate = {
        if (Build.VERSION.SDK_INT >= 33 && !vm.notifAsked) { vm.markNotifAsked(); notif.launch(Manifest.permission.POST_NOTIFICATIONS) }
        vm.generate()
    }
    val menu = listOf(
        MenuItem("retry", "Reset settings") { vm.reset() },
        MenuItem("studio", "Change clip") { nav.go(Routes.SOURCE) },
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
            DirectCanvas(s, vm, generate)
            ToolStrip(VIDEO_TOOLS, d.tool) { k -> vm.edit { it.copy(tool = k) } }
            BSheet(12.dp) { DirectSheet(vm, s) }
        }
        Dock(tight = true) {
            Cta(if (s.starting) "Starting…" else s.genLabel, { if (!s.starting) generate() }, Modifier.weight(1f), busy = s.starting, off = s.cost > s.balance || s.clip == null)
        }
    }
}

/**
 * The stage. Idle: the source clip with the target (model in outfit) in the corner, or an empty placeholder before a clip
 * is uploaded. While a render from here runs: blurred and softly moving with its phase, progress and price. Ready: the
 * take playing with Open / Edit video / Generate again. Failed: why, with Try again.
 */
@Composable
private fun DirectCanvas(s: VideoState, vm: NewVideoViewModel, onGenerate: () -> Unit) {
    val m = muse
    val nav = LocalNav.current
    val stage = s.stage
    val target = s.outfit?.front ?: s.model?.cover
    Canvas(300.dp) {
        val clip = s.clip
        when (stage.phase) {
            StagePhase.IDLE -> when {
                clip == null -> StageEmptySource { nav.go(Routes.SOURCE) }
                s.draft.background == "photo" -> Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFFB9C4CF), Color(0xFF6E7A86)))))
                clip.thumb != null -> RefImage(clip.thumb, Modifier.fillMaxSize(), 25)
                else -> ClipPlaceholder(Modifier.fillMaxSize(), 1, showPlay = false)
            }
            // The blurred picture: the clip's first frame, or the model when there's no frame.
            StagePhase.QUEUED, StagePhase.RENDERING -> StageBusy(stage, clip?.thumb ?: target)
            StagePhase.FAILED -> StageFailed(stage, clip?.thumb ?: target, onGenerate)
            StagePhase.READY -> StageReady(
                stage, s.stageTake, target, vm::pickTake, onOpen = { nav.go(Routes.result(it.id)) },
                onEdit = { if (it.editable) nav.go(Routes.editVideo(it.id)) else vm.toast("Edit video works once the take has its video") }, onAgain = onGenerate,
            )
        }
        // Who goes in: the selected model in the selected outfit (the finished take takes the whole stage).
        if (stage.phase != StagePhase.READY) Box(
            Modifier.align(Alignment.TopEnd).padding(top = if (m.isB && stage.phase == StagePhase.IDLE) 36.dp else 12.dp, end = 12.dp).size(64.dp, 86.dp).clip(RoundedCornerShape(10.dp))
                .border(2.dp, Color.White, RoundedCornerShape(10.dp)),
        ) { RefImage(target, Modifier.fillMaxSize()) }
        if (stage.phase == StagePhase.IDLE && clip != null) IdleSourceOverlay(s)
    }
}

/** Idle with a clip: the viewfinder, the source's name and a preview scrubber. */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.IdleSourceOverlay(s: VideoState) {
    val m = muse
    val track = remember { Animatable(.38f) }
    val scope = rememberCoroutineScope()
    val clip = s.clip
    Viewfinder(bottomInset = 44.dp)
    if (m.isB) {
        Row(Modifier.padding(start = 14.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(m.t.rec)); Spacer(Modifier.width(4.dp)); Readout("00:00:05:04")
        }
        Readout("OUTPUT 768×1344", Modifier.align(Alignment.BottomEnd).padding(end = 14.dp, bottom = 44.dp))
    }
    T(clip?.let { "Source · ${it.name}" } ?: "No clip", m.type.tiny.copy(fontSize = 11.sp), Color.White.copy(alpha = .85f),
        Modifier.align(Alignment.TopStart).padding(start = 14.dp, end = 88.dp, top = if (m.isB) 30.dp else 12.dp), maxLines = 1)
    Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.press { scope.launch { track.snapTo(0f); track.animateTo(1f, tween(2500, easing = LinearEasing)); track.snapTo(0f) } }) { Ic("play", 16.dp, Color.White) }
        Box(Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = .35f))) {
            Box(Modifier.fillMaxWidth(track.value).fillMaxHeight().background(Color.White))
        }
        val total = s.spec.lengthSec
        T("0:%02d / 0:%02d".format((track.value * total).toInt(), total.roundToInt()), m.type.mono.copy(fontSize = 12.5.sp), Color.White)
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
            if (d.engine == Engine.VIGGLE) NoteBox("Fast · beta is quicker with exact motion timing, but faces are softer and can warp slightly.", warn = true)
            RowB {
                Column(Modifier.weight(1f)) { T("Takes", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("Different seeds, compared side by side") }
                Stepper(d.takes, 1, Pricing.TAKES_MAX) { n -> vm.edit { it.copy(takes = n) } }
            }
        }
        "bg" -> {
            H3("Background")
            Opt("Keep the real room", "Best realism. Uses the clip's own background.", d.background == "keep", onClick = { vm.edit { it.copy(background = "keep") } })
            if (!d.edit) Tiny("A new background photo is on Edit for now.")
            else Opt("New background photo", "Vertical photo, same camera height, similar light.", d.background == "photo", onClick = { vm.edit { it.copy(background = "photo") } })
            if (d.edit && d.background == "photo") Field("Background motion") {
                Seg(listOf("still" to "Still", "subtle" to "Subtly alive", "busy" to "Busy"), d.motion, { k -> vm.edit { it.copy(motion = k) } })
            }
        }
        "audio" -> {
            H3("Sound")
            Opt("Keep the clip's audio", "The song or voice from your source clip.", d.keepAudio, onClick = { vm.edit { it.copy(keepAudio = true) } })
            Opt("Replace audio", "Upload a new track or voiceover.", !d.keepAudio, onClick = { vm.edit { it.copy(keepAudio = false) }; if (s.demo) vm.toast("Pick a track or voiceover (demo)") })
            // Prompt scripts: whether she talks/sings (lip-sync) or not (her mouth follows the clip, no lip-sync to music).
            RowB {
                Column(Modifier.weight(1f)) { T("Performer is speaking", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny(VideoDraft.speakingHint(d.speaking)) }
                Toggle(d.speaking, { vm.edit { it.toggleSpeaking() } })
            }
            if (d.edit) RowB {
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
            StudioText.neverAdd(s.model?.neverAdd)?.let { Tiny(it) }
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
 * Render (Draft, the default / Standard / HD) and the add-ons (Edit, Fast · beta; Upscale on a finished take), with the
 * price in outcomes ("about $0.14 · 7 s", "about $0.67"): no GPUs, steps or provider names (plans/api.md "App clean-up" §2).
 */
@Composable
fun QualityPicker(s: VideoState, onPick: (VideoOption) -> Unit) {
    val m = muse
    val d = s.draft
    val render = VideoOption.RENDER.filter { s.video.available(it.id) || it == d.option }
    val addons = VideoOption.ADDONS.filter { (s.video.available(it.id) && (it != VideoOption.FAST || s.fastBeta)) || it == d.option }
    H3("Render")
    if (render.isNotEmpty()) Seg(render.map { it.id to it.label }, if (d.option.addon) "" else d.option.id, { k -> onPick(VideoOption.fromId(k)) }, Modifier.fillMaxWidth())
    if (addons.isNotEmpty()) {
        Lbl("Add-ons")
        Seg(addons.map { it.id to it.label }, if (d.option.addon) d.option.id else "", { k -> onPick(VideoOption.fromId(k)) }, Modifier.fillMaxWidth(), small = true)
    }
    val detail = (if (d.option.addon) s.video.addon(d.option.id)?.detail else s.video.option(d.option.id)?.detail)?.ifBlank { null } ?: d.option.detail
    RowB {
        Tiny(detail, Modifier.weight(1f))
        T(Pricing.optionPriceLine(s.spec), m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
    }
    Tiny(if (d.replicate) "Whole clip, billed per second of video. Different takes come out slightly different."
        else "Whole clip. Different takes come out slightly different.")
    val up = s.video.upscale
    Tiny("Upscale to 1080p, 2K or 4K from a finished take · ${if (up.available) "on the take" else "coming soon"}")
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
