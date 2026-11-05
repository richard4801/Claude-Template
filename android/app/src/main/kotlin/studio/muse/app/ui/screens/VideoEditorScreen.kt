package studio.muse.app.ui.screens

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import studio.muse.app.AppContainer
import studio.muse.app.data.EditListDto
import studio.muse.app.data.ImageRef
import studio.muse.app.data.editTargetFor
import studio.muse.app.platform.SourceInfo
import studio.muse.app.platform.VideoEditEngine
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.EditHistory
import studio.muse.core.EditRules
import studio.muse.core.VideoEdit
import studio.muse.core.stripTimes
import java.io.File

// ======================================================================= state

sealed interface EditorPhase {
    data class Loading(val progress: Float? = null) : EditorPhase
    data object Ready : EditorPhase
    data class Exporting(val progress: Float) : EditorPhase
    data class Saving(val progress: Float) : EditorPhase
    data class Failed(val message: String, val canRetry: Boolean = true) : EditorPhase
}

/** Everything the editor shows (pure, so screenshots can render it without a player). */
data class EditorUi(
    val title: String = "",
    val poster: ImageRef? = null,
    val edit: VideoEdit = VideoEdit.untouched(1.0),
    val selected: Int? = 0,
    /** Speed applies to every part ("Whole video") instead of the selected one. */
    val scopeAll: Boolean = true,
    val playheadSec: Double = 0.0,
    val playing: Boolean = false,
    val canUndo: Boolean = false,
    val canRedo: Boolean = false,
    val fps: Double = 30.0,
    val hasAudio: Boolean = true,
    val phase: EditorPhase = EditorPhase.Loading(),
    /** True when re-opened from an edited version (its cuts are loaded). */
    val reopened: Boolean = false,
) {
    val selectedSegment get() = selected?.let { edit.segments.getOrNull(it) }
    /** The speed the speed row shows: the selected part's, or the common one for "Whole video" (null when mixed). */
    val shownSpeed: Double? get() = if (scopeAll) edit.segments.map { it.speed }.distinct().singleOrNull() else selectedSegment?.speed
}

sealed interface EditorAction {
    data object Undo : EditorAction; data object Redo : EditorAction; data object Reset : EditorAction
    data object PlayPause : EditorAction
    data class Seek(val sec: Double) : EditorAction
    data object Split : EditorAction; data object Delete : EditorAction
    data class Speed(val speed: Double) : EditorAction
    data class Scope(val all: Boolean) : EditorAction
    data class MuteAll(val on: Boolean) : EditorAction
    data class MutePart(val on: Boolean) : EditorAction
    /** A handle drag: [done] = finger lifted (that's when it becomes one undo step). */
    data class TrimStart(val sec: Double, val done: Boolean) : EditorAction
    data class TrimEnd(val sec: Double, val done: Boolean) : EditorAction
    data object Export : EditorAction; data object Cancel : EditorAction; data object Retry : EditorAction
}

class VideoEditorViewModel(private val c: AppContainer, private val takeId: String, context: Context) : ViewModel() {
    private val app = context.applicationContext
    private val engine = VideoEditEngine(app)
    private val _ui = MutableStateFlow(EditorUi())
    val ui: StateFlow<EditorUi> = _ui.asStateFlow()
    private val _frames = MutableStateFlow<List<ImageBitmap?>>(emptyList())
    val frames: StateFlow<List<ImageBitmap?>> = _frames.asStateFlow()

    private var history: EditHistory? = null
    /** A handle being dragged: shown, but not an undo step until the finger lifts. */
    private var dragging: VideoEdit? = null
    private var sourceTakeId: String = takeId
    private var file: File? = null
    private var info: SourceInfo? = null
    private var work: Job? = null
    private var ticker: Job? = null
    var player: ExoPlayer? = null
        private set

    init { load() }

    private fun load() {
        work?.cancel()
        work = viewModelScope.launch {
            _ui.update { it.copy(phase = EditorPhase.Loading()) }
            val takes = c.repo.state.value.takes
            val take = takes.firstOrNull { it.id == takeId }
            val target = take?.let { editTargetFor(it, takes) }
            if (target == null) { _ui.update { it.copy(phase = EditorPhase.Failed("This take has no video to edit", canRetry = false)) }; return@launch }
            sourceTakeId = target.source.id
            _ui.update { it.copy(title = target.source.title, poster = target.source.thumb) }
            try {
                val f = engine.fetchSource(target.source.videoUrl!!) { p -> _ui.update { it.copy(phase = EditorPhase.Loading(p)) } }
                val i = engine.probe(f)
                file = f; info = i
                val dur = i.durationSec.takeIf { it > 0 } ?: target.source.durationSec ?: 1.0
                val start = target.initial?.toEdit()?.takeIf { it.problem() == null } ?: VideoEdit.untouched(dur)
                history = EditHistory(start)
                _ui.update { it.copy(edit = start, fps = i.fps, hasAudio = i.hasAudio, reopened = target.initial != null, phase = EditorPhase.Ready, selected = 0, playheadSec = start.trimIn) }
                setupPlayer(f)
                val px = (56 * app.resources.displayMetrics.density).toInt()
                _frames.value = engine.frames(f, stripTimes(dur, 10), px).map { it?.asImageBitmap() }
            } catch (e: kotlinx.coroutines.CancellationException) { throw e
            } catch (e: Exception) {
                _ui.update { it.copy(phase = EditorPhase.Failed("Couldn't open the video · check your connection and try again")) }
            }
        }
    }

    // ------------------------------------------------------------ preview (ExoPlayer: kept parts in order)
    private fun setupPlayer(f: File) {
        val p = player ?: ExoPlayer.Builder(app).build().also { player = it }
        p.repeatMode = Player.REPEAT_MODE_ALL
        p.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = applyPartSettings()
            override fun onIsPlayingChanged(isPlaying: Boolean) { _ui.update { it.copy(playing = isPlaying) } }
        })
        rebuildPlaylist(f)
        ticker?.cancel()
        ticker = viewModelScope.launch {
            while (isActive) {
                val pl = player
                if (pl != null && pl.isPlaying) {
                    val e = shown()
                    val seg = e.segments.getOrNull(pl.currentMediaItemIndex)
                    if (seg != null) _ui.update { it.copy(playheadSec = (seg.inSec + pl.currentPosition / 1000.0).coerceAtMost(seg.outSec)) }
                }
                delay(50)
            }
        }
    }

    private fun rebuildPlaylist(src: File? = file) {
        val f = src ?: return
        val p = player ?: return
        val e = shown()
        val uri = android.net.Uri.fromFile(f)
        val items = e.segments.mapIndexed { i, s ->
            MediaItem.Builder().setUri(uri).setMediaId("part$i").setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder().setStartPositionMs(Math.round(s.inSec * 1000)).setEndPositionMs(Math.round(s.outSec * 1000)).build(),
            ).build()
        }
        val t = _ui.value.playheadSec
        val idx = e.segmentAt(t) ?: e.segments.indexOfFirst { it.inSec >= t }.takeIf { it >= 0 } ?: 0
        val seg = e.segments[idx]
        p.setMediaItems(items, idx, Math.round((t.coerceIn(seg.inSec, seg.outSec) - seg.inSec) * 1000))
        p.prepare()
        applyPartSettings()
    }

    /** Speed (pitch kept) and sound of the part now playing. */
    private fun applyPartSettings() {
        val p = player ?: return
        val e = shown()
        val i = p.currentMediaItemIndex.coerceIn(0, e.segments.lastIndex)
        p.playbackParameters = PlaybackParameters(e.segments[i].speed.toFloat(), 1f)
        p.volume = if (e.silent(i)) 0f else 1f
    }

    private fun shown(): VideoEdit = dragging ?: history?.current ?: _ui.value.edit

    // ------------------------------------------------------------ actions
    fun act(a: EditorAction) {
        val h = history
        val u = _ui.value
        when (a) {
            EditorAction.Undo -> h?.undo()?.let { if (it) changed() }
            EditorAction.Redo -> h?.redo()?.let { if (it) changed() }
            EditorAction.Reset -> h?.reset()?.let { if (it) changed() }
            EditorAction.PlayPause -> player?.let { if (it.isPlaying) it.pause() else it.play() }
            is EditorAction.Seek -> seek(a.sec)
            EditorAction.Split -> if (h != null && !h.apply(h.current.split(u.playheadSec))) c.repo.toast("Move the playhead inside a part, at least 0.1 s from its edges") else changed(select = u.edit.segmentAt(u.playheadSec)?.plus(1))
            EditorAction.Delete -> {
                val i = u.selected
                if (i == null) c.repo.toast("Tap a part to select it")
                else if (h != null && h.apply(h.current.delete(i))) changed(select = i.coerceAtMost(h.current.segments.lastIndex))
                else c.repo.toast("The last part can't be deleted")
            }
            is EditorAction.Speed -> if (h != null) { if (h.apply(h.current.speed(if (u.scopeAll) null else u.selected ?: 0, a.speed))) changed() }
            is EditorAction.Scope -> _ui.update { it.copy(scopeAll = a.all, selected = it.selected ?: 0) }
            is EditorAction.MuteAll -> if (h != null && h.apply(h.current.muteAll(a.on))) changed()
            is EditorAction.MutePart -> u.selected?.let { i -> if (h != null && h.apply(h.current.muteSegment(i, a.on))) changed() }
            is EditorAction.TrimStart -> trim(a.done) { it.trimStart(EditRules.snap(a.sec, u.fps)) }
            is EditorAction.TrimEnd -> trim(a.done) { it.trimEnd(EditRules.snap(a.sec, u.fps)) }
            EditorAction.Export -> export()
            EditorAction.Cancel -> { work?.cancel(); _ui.update { it.copy(phase = EditorPhase.Ready) } }
            EditorAction.Retry -> if (file == null) load() else _ui.update { it.copy(phase = EditorPhase.Ready) }
        }
    }

    private fun trim(done: Boolean, f: (VideoEdit) -> VideoEdit?) {
        val h = history ?: return
        val next = f(h.current) ?: h.current
        if (!done) {
            dragging = next
            _ui.update { it.copy(edit = next, playheadSec = next.trimIn.coerceAtLeast(minOf(it.playheadSec, next.trimOut))) }
        } else {
            dragging = null
            h.apply(next)
            changed()
        }
    }

    private fun changed(select: Int? = null) {
        val h = history ?: return
        val e = h.current
        _ui.update {
            val sel = (select ?: it.selected)?.coerceIn(0, e.segments.lastIndex)
            it.copy(edit = e, canUndo = h.canUndo, canRedo = h.canRedo, selected = sel, playheadSec = it.playheadSec.coerceIn(e.trimIn, e.trimOut))
        }
        rebuildPlaylist()
    }

    private fun seek(t: Double) {
        val e = shown()
        val tt = t.coerceIn(0.0, e.sourceDurationSec)
        val i = e.segmentAt(tt) ?: e.segments.indexOfFirst { it.inSec >= tt }.takeIf { it >= 0 } ?: e.segments.lastIndex
        val seg = e.segments[i]
        val at = tt.coerceIn(seg.inSec, seg.outSec)
        _ui.update { it.copy(playheadSec = at, selected = i) }
        player?.seekTo(i, Math.round((at - seg.inSec) * 1000))
        applyPartSettings()
    }

    private fun export() {
        val f = file ?: return
        val i = info ?: return
        val current = history?.current ?: return
        if (current.isUntouched) return c.repo.toast("Make a change first · trim, split, speed or sound")
        val edit = current.snapped(i.fps)
        edit.problem()?.let { return c.repo.toast(it) }
        player?.pause()
        work?.cancel()
        work = viewModelScope.launch {
            _ui.update { it.copy(phase = EditorPhase.Exporting(0f)) }
            val made = try {
                engine.export(f, i, edit) { p -> _ui.update { it.copy(phase = EditorPhase.Exporting(p)) } }
            } catch (e: kotlinx.coroutines.CancellationException) { throw e
            } catch (e: Exception) {
                _ui.update { it.copy(phase = EditorPhase.Failed("This phone couldn't make the video · try a shorter edit or 1× speed")) }
                return@launch
            }
            _ui.update { it.copy(phase = EditorPhase.Saving(0f)) }
            try {
                val (take, err) = c.repo.attemptInline {
                    saveTakeVersion(sourceTakeId, made, EditListDto.of(sourceTakeId, edit)) { p -> _ui.update { it.copy(phase = EditorPhase.Saving(p)) } }
                }
                if (take == null) { _ui.update { it.copy(phase = EditorPhase.Failed(err ?: "Couldn't save the video")) }; return@launch }
                c.repo.toast("Saved as a new version · Edited")
                // The live take event puts it in the Gallery; wait briefly so its page has it.
                withTimeoutOrNull(3000) { c.repo.state.first { s -> s.takes.any { it.id == take.id } } }
                _ui.update { it.copy(phase = EditorPhase.Ready) }
                done.value = if (c.repo.state.value.takes.any { it.id == take.id }) Routes.result(take.id) else Routes.GALLERY
            } finally { made.file.delete() }
        }
    }

    /** Where to go once saved. */
    val done = MutableStateFlow<String?>(null)

    override fun onCleared() {
        work?.cancel(); ticker?.cancel()
        player?.release(); player = null
    }
}

// ======================================================================= screen

@Composable
fun VideoEditorScreen(takeId: String) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val context = LocalContext.current
    val vm: VideoEditorViewModel = viewModel(key = "edit-$takeId") { VideoEditorViewModel(c, takeId, context) }
    val ui by vm.ui.collectAsState()
    val frames by vm.frames.collectAsState()
    val done by vm.done.collectAsState()
    androidx.compose.runtime.LaunchedEffect(done) { done?.let { vm.done.value = null; nav.back(); nav.go(it) } }
    androidx.lifecycle.compose.LifecycleResumeEffect(vm) { onPauseOrDispose { vm.player?.pause() } }
    VideoEditorContent(ui, frames, onBack = { nav.back() }, act = vm::act) { mod ->
        val p = vm.player
        if (p != null) PlayerSurface(p, mod) else RefImage(ui.poster, mod, 30)
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun PlayerSurface(player: ExoPlayer, modifier: Modifier) {
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { ctx ->
            androidx.media3.ui.PlayerView(ctx).apply {
                this.player = player
                useController = false
                resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShutterBackgroundColor(android.graphics.Color.BLACK)
            }
        },
        modifier = modifier,
        update = { it.player = player },
    )
}

/** The editor's layout; [preview] draws the video (a player on the phone, the poster in screenshots). */
@Composable
fun VideoEditorContent(
    ui: EditorUi, frames: List<ImageBitmap?>, onBack: () -> Unit, act: (EditorAction) -> Unit,
    preview: @Composable (Modifier) -> Unit,
) {
    val m = muse
    val ready = ui.phase == EditorPhase.Ready
    ScreenBox(statusPad = true) {
        Column(Modifier.fillMaxSize()) {
            TopBar("Edit video", onBack = onBack) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextBtn("↶", "Undo", ui.canUndo && ready) { act(EditorAction.Undo) }
                    TextBtn("↷", "Redo", ui.canRedo && ready) { act(EditorAction.Redo) }
                    TextBtn("Reset", "Reset", ready && !ui.edit.isUntouched) { act(EditorAction.Reset) }
                }
            }
            Box(Modifier.fillMaxWidth().weight(1f).padding(horizontal = 16.dp).clip(RoundedCornerShape(m.t.r)).background(Color.Black)) {
                preview(Modifier.fillMaxSize())
                Box(
                    Modifier.align(Alignment.BottomStart).padding(12.dp).size(48.dp).clip(CircleShape).background(Color.Black.copy(alpha = .55f))
                        .press(enabled = ready) { act(EditorAction.PlayPause) },
                    contentAlignment = Alignment.Center,
                ) { if (ui.playing) T("❚❚", m.type.body.copy(fontSize = 16.sp, fontWeight = FontWeight.Bold), Color.White) else Ic("play", 22.dp, Color.White) }
                if (ui.reopened) Box(Modifier.align(Alignment.TopStart).padding(10.dp)) { Pill("Edited version", "good") }
            }
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                RowB {
                    T("${EditRules.time(ui.edit.outputAt(ui.playheadSec))} / ${EditRules.time(ui.edit.outputSec)}", m.type.mono.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold), m.t.ink)
                    Spacer(Modifier.weight(1f))
                    T("at ${EditRules.time(ui.playheadSec)} of the original", m.type.mono.copy(fontSize = 11.sp), m.t.muted)
                }
                Timeline(ui, frames, act)
                RowB {
                    T("In ${EditRules.time(ui.edit.trimIn)}", m.type.mono.copy(fontSize = 11.5.sp), m.t.muted)
                    Spacer(Modifier.weight(1f))
                    T("Out ${EditRules.time(ui.edit.trimOut)}", m.type.mono.copy(fontSize = 11.5.sp), m.t.muted)
                    Spacer(Modifier.weight(1f))
                    T("${ui.edit.segments.size} part${if (ui.edit.segments.size == 1) "" else "s"} · kept ${EditRules.time(ui.edit.outputSec)}", m.type.mono.copy(fontSize = 11.5.sp), m.t.muted)
                }
                when (val ph = ui.phase) {
                    is EditorPhase.Loading -> Busy(if (ph.progress != null) "Getting the video · ${(ph.progress * 100).toInt()} %" else "Getting the video…", ph.progress, null, act)
                    is EditorPhase.Exporting -> Busy("Making your video on this phone · ${(ph.progress * 100).toInt()} %", ph.progress, "Cancel", act)
                    is EditorPhase.Saving -> Busy("Saving to Gallery · ${(ph.progress * 100).toInt()} %", ph.progress, "Cancel", act)
                    is EditorPhase.Failed -> {
                        NoteBox(ph.message, icon = "shield", warn = true)
                        if (ph.canRetry) Cta2("Try again", { act(EditorAction.Retry) }, Modifier.fillMaxWidth(), height = 46.dp)
                    }
                    EditorPhase.Ready -> Tools(ui, act)
                }
            }
        }
    }
}

@Composable
private fun TextBtn(text: String, desc: String, enabled: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.height(40.dp).clip(RoundedCornerShape(999.dp)).press(enabled = enabled, onClick = onClick).padding(horizontal = 8.dp)
        .semantics { contentDescription = desc }, contentAlignment = Alignment.Center) {
        T(text, m.type.chip.copy(fontSize = if (text.length == 1) 20.sp else 13.sp, fontWeight = FontWeight.Bold), if (enabled) m.t.ink else m.t.muted.copy(alpha = .45f), maxLines = 1)
    }
}

@Composable
private fun Busy(text: String, progress: Float?, cancel: String?, act: (EditorAction) -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T(text, m.type.body.copy(fontWeight = FontWeight.SemiBold), m.t.ink)
        Bar(progress ?: 0f, Modifier.fillMaxWidth(), height = 6.dp)
        if (cancel != null) Cta2(cancel, { act(EditorAction.Cancel) }, Modifier.fillMaxWidth(), height = 46.dp)
    }
}

@Composable
private fun Tools(ui: EditorUi, act: (EditorAction) -> Unit) {
    val m = muse
    val sel = ui.selectedSegment
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Chip("Split", false, { act(EditorAction.Split) })
        Chip("Delete part", false, { act(EditorAction.Delete) })
        Spacer(Modifier.weight(1f))
        if (ui.hasAudio) {
            T("Sound", m.type.tiny, m.t.muted)
            Toggle(!ui.edit.mute, { act(EditorAction.MuteAll(!ui.edit.mute)) })
        } else T("No sound", m.type.tiny, m.t.muted)
    }
    RowB {
        Lbl(if (ui.scopeAll) "Speed · whole video" else "Speed · part ${(ui.selected ?: 0) + 1}")
        Spacer(Modifier.weight(1f))
        Seg(listOf("all" to "Whole video", "part" to "This part"), if (ui.scopeAll) "all" else "part", { act(EditorAction.Scope(it == "all")) }, Modifier.width(210.dp), small = true)
    }
    Seg(EditRules.SPEEDS.map { it.toString() to EditRules.speedLabel(it) }, ui.shownSpeed?.toString() ?: "", { act(EditorAction.Speed(it.toDouble())) }, Modifier.fillMaxWidth(), small = true)
    RowB {
        Box(Modifier.weight(1f)) {
            if (sel != null && ui.hasAudio && !ui.edit.mute) {
                Check("Mute part ${(ui.selected ?: 0) + 1}", sel.muted, { act(EditorAction.MutePart(!sel.muted)) })
            } else Tiny(if (ui.edit.mute) "Sound off for the whole video" else "Tap the strip to pick a part")
        }
        Spacer(Modifier.width(10.dp))
        Cta("Export", { act(EditorAction.Export) }, Modifier.width(150.dp), icon = "export", off = ui.edit.isUntouched)
    }
}

/** Frame strip with trim handles, split marks, cut parts dimmed, the selected part outlined and the playhead. */
@Composable
private fun Timeline(ui: EditorUi, frames: List<ImageBitmap?>, act: (EditorAction) -> Unit) {
    val m = muse
    val e = ui.edit
    val dur = e.sourceDurationSec.coerceAtLeast(0.001)
    val handleW = 14.dp
    val current by rememberUpdatedState(ui)
    val accent = m.t.accent
    BoxWithConstraints(Modifier.fillMaxWidth().height(64.dp)) {
        val density = LocalDensity.current
        val wPx = with(density) { maxWidth.toPx() }
        val hw = with(density) { handleW.toPx() }
        val inner = (wPx - 2 * hw).coerceAtLeast(1f)
        fun xOf(t: Double) = hw + (t / dur).toFloat() * inner
        fun tOf(x: Float) = ((x - hw) / inner).toDouble().coerceIn(0.0, 1.0) * dur
        // Frames
        Row(Modifier.fillMaxSize().padding(horizontal = handleW, vertical = 4.dp).clip(RoundedCornerShape(6.dp)).background(m.t.surface2)) {
            val n = frames.size.coerceAtLeast(10)
            repeat(n) { i ->
                val b = frames.getOrNull(i)
                Box(Modifier.weight(1f).fillMaxHeight().background(if (i % 2 == 0) m.t.surface2 else m.t.surface)) {
                    if (b != null) Image(b, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                }
            }
        }
        Canvas(
            Modifier.fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures { o -> act(EditorAction.Seek(tOf(o.x))) }
                }
                .pointerInput(Unit) {
                    var mode = 0 // 1 = start handle, 2 = end handle, 3 = scrub
                    var x = 0f
                    detectDragGestures(
                        onDragStart = { o ->
                            val ed = current.edit
                            x = o.x
                            mode = when {
                                kotlin.math.abs(o.x - xOf(ed.trimIn)) < hw * 2 -> 1
                                kotlin.math.abs(o.x - xOf(ed.trimOut)) < hw * 2 -> 2
                                else -> 3
                            }
                        },
                        onDragEnd = { when (mode) { 1 -> act(EditorAction.TrimStart(tOf(x), true)); 2 -> act(EditorAction.TrimEnd(tOf(x), true)) } },
                        onDragCancel = { when (mode) { 1 -> act(EditorAction.TrimStart(tOf(x), true)); 2 -> act(EditorAction.TrimEnd(tOf(x), true)) } },
                    ) { change, d ->
                        change.consume()
                        x += d.x
                        when (mode) { 1 -> act(EditorAction.TrimStart(tOf(x), false)); 2 -> act(EditorAction.TrimEnd(tOf(x), false)); else -> act(EditorAction.Seek(tOf(x))) }
                    }
                },
        ) {
            val top = 4.dp.toPx(); val bottom = size.height - 4.dp.toPx()
            val dim = Color.Black.copy(alpha = .62f)
            // Cut and trimmed-off parts
            var prev = 0.0
            e.segments.forEach { s ->
                if (s.inSec > prev) drawRect(dim, Offset(xOf(prev), top), Size(xOf(s.inSec) - xOf(prev), bottom - top))
                prev = s.outSec
            }
            if (prev < dur) drawRect(dim, Offset(xOf(prev), top), Size(xOf(dur) - xOf(prev), bottom - top))
            // Part edges and per-part marks (speed ≠ 1×, muted)
            e.segments.forEachIndexed { i, s ->
                if (i > 0) drawLine(Color.White, Offset(xOf(s.inSec), top), Offset(xOf(s.inSec), bottom), 2.dp.toPx())
                if (s.speed != 1.0 || e.silent(i)) drawRect(Color.White.copy(alpha = .9f), Offset(xOf(s.inSec) + 3.dp.toPx(), bottom - 6.dp.toPx()), Size((xOf(s.outSec) - xOf(s.inSec) - 6.dp.toPx()).coerceAtLeast(0f), 3.dp.toPx()))
            }
            // Selected part
            ui.selected?.let { e.segments.getOrNull(it) }?.let { s ->
                drawRect(accent, Offset(xOf(s.inSec), top + 1.dp.toPx()), Size(xOf(s.outSec) - xOf(s.inSec), bottom - top - 2.dp.toPx()), style = Stroke(3.dp.toPx()))
            }
            // Trim handles
            val hr = androidx.compose.ui.geometry.CornerRadius(4.dp.toPx())
            drawRoundRect(accent, Offset(xOf(e.trimIn) - hw, 0f), Size(hw, size.height), hr)
            drawRoundRect(accent, Offset(xOf(e.trimOut), 0f), Size(hw, size.height), hr)
            listOf(xOf(e.trimIn) - hw / 2, xOf(e.trimOut) + hw / 2).forEach { cx ->
                drawLine(Color.White, Offset(cx, size.height * .35f), Offset(cx, size.height * .65f), 2.dp.toPx())
            }
            // Playhead
            val px = xOf(ui.playheadSec)
            drawLine(Color.White, Offset(px, 0f), Offset(px, size.height), 3.dp.toPx())
            drawCircle(Color.White, 5.dp.toPx(), Offset(px, 2.dp.toPx()))
        }
    }
    // Speeds and mutes under the strip, one line
    val marks = e.segments.mapIndexedNotNull { i, s ->
        listOfNotNull(if (s.speed != 1.0) EditRules.speedLabel(s.speed) else null, if (e.silent(i) && !e.mute) "muted" else null)
            .takeIf { it.isNotEmpty() }?.let { "Part ${i + 1}: ${it.joinToString(", ")}" }
    }
    if (marks.isNotEmpty()) T(marks.joinToString(" · "), m.type.mono.copy(fontSize = 11.sp), m.t.muted, maxLines = 2)
}

/** On a video's page: "Edit video", plus its edited versions (or, on a version, where it was cut from). */
@Composable
fun EditVideoRow(take: studio.muse.app.data.Take, versions: List<studio.muse.app.data.Take>, onEdit: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape).press(onClick = onEdit).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Ic("retry", 20.dp, m.t.ink)
        Column(Modifier.weight(1f)) {
            T("Edit video", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
            Tiny(when {
                take.kind == "edit" -> "Edited version · change its cuts, the original stays"
                versions.isNotEmpty() -> "${versions.size} edited version${if (versions.size == 1) "" else "s"} in Gallery · trim, split, speed, sound"
                else -> "Trim, split, speed, sound · made on this phone, free"
            })
        }
        T("›", m.type.h3, m.t.muted)
    }
}
