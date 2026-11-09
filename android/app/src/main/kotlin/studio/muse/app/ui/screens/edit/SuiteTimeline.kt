package studio.muse.app.ui.screens.edit

import androidx.compose.animation.core.AnimationState
import androidx.compose.animation.core.animateDecay
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.MediaClip
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.captionPages
import studio.muse.core.edit.clipLength
import studio.muse.core.edit.clipSourceAt
import studio.muse.core.edit.itemSpan
import studio.muse.core.edit.timeline
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** What a lane shows: a track's items, or the main clips' own sound (under the video, as on the desktop). */
enum class LaneKind { TRACK, CLIP_SOUND }

/** One horizontal lane of the timeline: its track, top and height in dp (below the ruler). */
data class Lane(val track: Track?, val top: Float, val height: Float, val kind: LaneKind = LaneKind.TRACK)

/** The ruler's height (dp); lanes start under it and scroll vertically under it when they don't all fit. */
const val RULER_DP = 28f

/**
 * The lanes for [p]: main video, the clips' own sound (when any clip has sound), captions, overlays, music, voice
 * (incl. detached clip sound), sfx, text. [roomy]: the tablet's taller lanes beside their named headers.
 */
fun lanesOf(p: EditProject, roomy: Boolean = false): List<Lane> {
    val out = ArrayList<Lane>()
    var y = RULER_DP + 2f
    fun add(t: Track, h: Float, gap: Float, kind: LaneKind = LaneKind.TRACK) { out += Lane(t, y, h, kind); y += h + gap }
    add(p.main, if (roomy) 60f else 52f, 4f)
    if (p.mainClips.any { SuiteOps.hasSound(p, it) }) add(p.main, if (roomy) 34f else 30f, 8f, LaneKind.CLIP_SOUND)
    val order = listOf(TrackKind.CAPTION, TrackKind.ADJUST, TrackKind.VIDEO, TrackKind.IMAGE, TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX, TrackKind.TEXT)
    for (k in order) for (t in p.tracks) if (t.kind == k) add(t,
        if (roomy) when (k) { TrackKind.CAPTION, TrackKind.TEXT -> 28f; else -> 34f }
        else when (k) { TrackKind.CAPTION, TrackKind.TEXT -> 22f; else -> 30f },
        6f)
    return out
}

/** A lane's name in the tablet's header column. */
fun laneName(l: Lane): String = if (l.kind == LaneKind.CLIP_SOUND) "Clip sound" else l.track?.let(::trackName) ?: ""

/** A track's name in the tablet's header column. */
fun trackName(t: Track): String = when (t.kind) {
    TrackKind.MAIN -> "Video"; TrackKind.CAPTION -> "Captions"; TrackKind.MUSIC -> "Music"
    TrackKind.VOICE -> if (t.name == SuiteOps.CLIP_SOUND_TRACK) "Detached sound" else "Voice-over"
    TrackKind.SFX -> "Sound effects"; TrackKind.TEXT -> "Text"; TrackKind.IMAGE -> "Image"; TrackKind.ADJUST -> "Adjustment"; else -> if (t.name == "Cut-out") "Cut-out" else "Overlay"
}

private fun laneIcon(l: Lane): String = if (l.kind == LaneKind.CLIP_SOUND) "waveform" else when (l.track?.kind) {
    TrackKind.MAIN -> "film-strip"; TrackKind.CAPTION -> "closed-captioning"; TrackKind.MUSIC -> "music"; TrackKind.VOICE -> "mic"
    TrackKind.SFX -> "waveform"; TrackKind.TEXT -> "text-t"; TrackKind.ADJUST -> "sliders-horizontal"; else -> "layers"
}

/** Colours of the sound/text lanes (music green, voice violet, clip sound blue-grey, hook rose), darker on dark themes. */
private data class LaneColors(val music: Color, val musicWave: Color, val voice: Color, val voiceWave: Color, val sound: Color, val soundWave: Color, val hook: Color, val pip: Color)

@Composable
private fun laneColors(): LaneColors = if (muse.t.dark) LaneColors(Color(0xFF1E3524), Color(0xFF7BD88F), Color(0xFF2A2440), Color(0xFFA99BF0), Color(0xFF1C2C38), Color(0xFF7FB6DA), Color(0xFF3A2222), Color(0xFF26313A))
else LaneColors(Color(0xFFDCEBDD), Color(0xFF2F6B3A), Color(0xFFE6E0F2), Color(0xFF4B3F86), Color(0xFFDCE7F0), Color(0xFF2E5A7A), Color(0xFFF1D9D9), Color(0xFFDDE5EC))

/**
 * The Edit timeline (rebuilt phone-first, owner report 2026-11-08): the playhead is fixed in the centre and the tracks
 * scroll under it. One finger drags (and flings) through the video, two fingers pinch to zoom around the playhead, a
 * tap selects the clip under it, and the selected main clip's edges drag to trim it. While the finger moves the
 * timeline draws from its own state every frame and tells the editor where it is about 30 times a second (the
 * preview seeks to the latest of those); when it stops, the playhead lands on the nearest frame. Lanes: video frames,
 * the clips' own sound (real waveform, volume, fades, muted), captions, overlays, music, voice, sound effects, text.
 * [frames]: frames of each video asset spread evenly over its length; [waves]: decoded peaks per asset (none in tests →
 * a flat line, never invented levels).
 */
@Composable
fun SuiteTimeline(ui: EditSuiteUi, frames: Map<String, List<ImageBitmap>>, act: (EditAction) -> Unit, modifier: Modifier = Modifier,
                  /** Tablet: named track headers on the left, taller lanes, no floating "+" (the toolbar has Add). */
                  headers: Boolean = false,
                  waves: Map<String, Peaks> = emptyMap()) {
    val m = muse
    val p = ui.project ?: return
    val lanes = remember(p, headers) { lanesOf(p, headers) }
    if (headers) {
        val h = (lanes.lastOrNull()?.let { it.top + it.height } ?: 100f) + 8f
        Row(modifier.fillMaxWidth().height(h.dp.coerceAtMost(320.dp)).background(m.t.bg)) {
            Box(Modifier.width(196.dp).fillMaxHeight()) {
                for (lane in lanes) {
                    val t = lane.track ?: continue
                    Row(Modifier.offset(y = lane.top.dp).height(lane.height.dp).fillMaxWidth().padding(start = 16.dp, end = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        EIc(laneIcon(lane), 16.dp, m.t.muted)
                        studio.muse.app.ui.components.T(laneName(lane), m.scale.caption, m.t.ink, Modifier.weight(1f), maxLines = 1)
                        val name = laneName(lane).lowercase()
                        // The main track's sound is muted from its sound lane; its pictures are hidden from the video lane.
                        val sound = lane.kind == LaneKind.CLIP_SOUND || t.kind.isAudio
                        if (sound) HeaderToggle(if (t.muted == true) "speaker-slash" else "speaker-high",
                            if (t.muted == true) "Unmute $name" else "Mute $name", t.muted == true) { act(EditAction.ToggleTrackMuted(t.id)) }
                        else HeaderToggle(if (t.hidden == true) "eye-slash" else "eye", if (t.hidden == true) "Show $name" else "Hide $name", t.hidden == true) {
                            act(EditAction.ToggleTrackHidden(t.id))
                        }
                    }
                }
            }
            Box(Modifier.width(1.dp).fillMaxHeight().background(m.t.line))
            TimelineCanvas(ui, frames, waves, act, lanes, Modifier.weight(1f), plus = false)
        }
        return
    }
    TimelineCanvas(ui, frames, waves, act, lanes, modifier, plus = true)
}

/** A gesture's mode once it has moved past the touch slop. */
private enum class Mode { NONE, SCRUB, VSCROLL, PINCH, TRIM_LEFT, TRIM_RIGHT, MOVE, KEY }

@Composable
private fun TimelineCanvas(ui: EditSuiteUi, frames: Map<String, List<ImageBitmap>>, waves: Map<String, Peaks>, act: (EditAction) -> Unit, lanes: List<Lane>, modifier: Modifier, plus: Boolean) {
    val m = muse
    val p = ui.project ?: return
    val roomy = !plus
    val contentH = (lanes.lastOrNull()?.let { it.top + it.height } ?: 100f) + 8f
    val measurer = rememberTextMeasurer(cacheSize = 96)
    val colors = laneColors()
    val spans = remember(p) { timeline(p) }
    val pages = remember(p) { captionPages(p) }
    val beats = remember(p, ui.beatMarks) { SuiteOps.beatTimes(p, ui.beatMarks == BeatMarks.STRONG) }
    val detached = remember(p) { detachedSounds(p) }
    val state by rememberUpdatedState(ui)
    val actNow by rememberUpdatedState(act)
    val lanesNow by rememberUpdatedState(lanes)
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    val hapticNow = { haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress) }

    // The timeline's own playhead (seconds) and zoom (dp/s): drawn every frame from here while a finger is down or a
    // fling runs; otherwise they follow the editor (playback, undo, the tablet's buttons).
    val view = remember { mutableDoubleStateOf(ui.playheadSec) }
    val pps = remember { mutableFloatStateOf(ui.pxPerSec) }
    val vScroll = remember { mutableFloatStateOf(0f) }
    val busy = remember { mutableStateOf(false) }
    LaunchedEffect(ui.pxPerSec) { if (!busy.value) pps.floatValue = TimelineMath.clampPps(ui.pxPerSec) }
    LaunchedEffect(ui.playheadSec, ui.playing) {
        if (busy.value) return@LaunchedEffect
        view.doubleValue = ui.playheadSec
        if (ui.playing) {
            // Smooth scrolling while playing: the player reports ~20 times a second; between reports, move with the clock.
            val base = ui.playheadSec
            val t0 = withFrameNanos { it }
            while (isActive) withFrameNanos { n -> if (!busy.value) view.doubleValue = min(base + (n - t0) / 1e9, state.duration) }
        }
    }

    BoxWithConstraints(modifier.fillMaxWidth().let { if (roomy) it.fillMaxHeight() else it.height(contentH.coerceAtLeast(160f).dp.coerceAtMost(260.dp)) }.background(m.t.bg)) {
        val visibleH = constraints.maxHeight.toFloat()
        Canvas(
            Modifier.fillMaxSize()
                .semantics { contentDescription = "Timeline"; stateDescription = "${suiteTime(ui.playheadSec)} of ${suiteTime(ui.duration)}" }
                .pointerInput(Unit) {
                    val decay = splineBasedDecay<Float>(this)
                    var fling: Job? = null
                    var lastSent = 0L
                    fun send(t: Double, end: Boolean) {
                        view.doubleValue = t
                        val now = System.nanoTime()
                        if (end || now - lastSent > 32_000_000L) { lastSent = now; actNow(EditAction.Scrub(t, end)) }
                    }
                    coroutineScope {
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            val wasFlinging = fling?.isActive == true
                            fling?.cancel(); fling = null
                            if (wasFlinging) send(view.doubleValue, true)
                            val s = state
                            val proj = s.project ?: return@awaitEachGesture
                            val dur = s.duration
                            val w = size.width.toFloat()
                            val ppsPx = pps.floatValue * density
                            val hit = hitAt(down.position, w, density, proj, lanesNow, view.doubleValue, pps.floatValue, vScroll.floatValue)
                            // The selected item's edges are trim handles (20 dp either side), on its own lane.
                            var pendingTrim = Mode.NONE
                            var pendingKey: Double? = null
                            val selId = s.selectedId
                            if (selId != null && hit.lane != null && hit.lane.kind == LaneKind.TRACK && hit.lane.track?.items?.any { it.id == selId } == true) {
                                val tr = hit.lane.track
                                val sp = itemSpan(proj, tr, tr.items.first { it.id == selId })
                                val l = TimelineMath.xOf(sp.startSec, view.doubleValue, w, ppsPx); val r = TimelineMath.xOf(sp.endSec, view.doubleValue, w, ppsPx)
                                val reach = 20 * density
                                pendingTrim = when { abs(down.position.x - r) <= reach -> Mode.TRIM_RIGHT; abs(down.position.x - l) <= reach -> Mode.TRIM_LEFT; else -> Mode.NONE }
                                // A keyframe ◆ (the lane's lower band) drags the keyframe instead.
                                val laneBottom = (hit.lane.top + hit.lane.height) * density - vScroll.floatValue * density
                                if (down.position.y >= laneBottom - 18 * density) {
                                    pendingKey = SuiteOps.keyTimes(tr.items.first { it.id == selId })
                                        .minByOrNull { abs(TimelineMath.xOf(sp.startSec + it, view.doubleValue, w, ppsPx) - down.position.x) }
                                        ?.takeIf { abs(TimelineMath.xOf(sp.startSec + it, view.doubleValue, w, ppsPx) - down.position.x) <= 14 * density }
                                    if (pendingKey != null) pendingTrim = Mode.NONE
                                }
                            }
                            val tracker = VelocityTracker()
                            tracker.addPosition(down.uptimeMillis, down.position)
                            val slop = viewConfiguration.touchSlop
                            var mode = Mode.NONE
                            var last = down.position
                            busy.value = true
                            // Long-press on an item (finger still): move it (main clips reorder).
                            if (hit.item != null && pendingTrim == Mode.NONE && pendingKey == null) {
                                var lifted = false
                                val held = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                                    while (true) {
                                        val ev = awaitPointerEvent()
                                        val ch = ev.changes.firstOrNull { it.id == down.id } ?: ev.changes.first()
                                        if (!ch.pressed || ev.changes.count { it.pressed } > 1) { lifted = !ch.pressed; return@withTimeoutOrNull false }
                                        tracker.addPosition(ch.uptimeMillis, ch.position)
                                        if ((ch.position - down.position).getDistance() > slop) return@withTimeoutOrNull false
                                    }
                                }
                                if (held == null) { mode = Mode.MOVE; hapticNow(); actNow(EditAction.Select(hit.item.id)) }
                                else if (lifted) {
                                    busy.value = false
                                    tap(down.position, w, density, state, lanesNow, view.doubleValue, pps.floatValue, vScroll.floatValue, actNow)
                                    return@awaitEachGesture
                                }
                            }
                            var lastIndex = -1
                            while (true) {
                                val ev = awaitPointerEvent()
                                val pressed = ev.changes.filter { it.pressed }
                                if (pressed.isEmpty()) break
                                if (pressed.size >= 2 && (mode == Mode.NONE || mode == Mode.SCRUB || mode == Mode.PINCH)) {
                                    if (mode != Mode.PINCH) { if (mode == Mode.SCRUB) send(view.doubleValue, false); mode = Mode.PINCH }
                                    val z = ev.calculateZoom()
                                    if (z != 1f && z.isFinite()) pps.floatValue = TimelineMath.clampPps(pps.floatValue * z)
                                    ev.changes.forEach { it.consume() }
                                    continue
                                }
                                if (mode == Mode.PINCH) continue // the second finger lifted: wait for the first one
                                val ch = pressed.firstOrNull { it.id == down.id } ?: pressed.first()
                                tracker.addPosition(ch.uptimeMillis, ch.position)
                                val d = ch.position - last
                                last = ch.position
                                val totalX = ch.position.x - down.position.x; val totalY = ch.position.y - down.position.y
                                if (mode == Mode.NONE && (abs(totalX) > slop || abs(totalY) > slop)) {
                                    mode = when {
                                        pendingKey != null && abs(totalX) >= abs(totalY) -> Mode.KEY
                                        pendingTrim != Mode.NONE && abs(totalX) >= abs(totalY) -> pendingTrim
                                        abs(totalY) > abs(totalX) * 1.2f && contentH * density > visibleH -> Mode.VSCROLL
                                        else -> Mode.SCRUB
                                    }
                                }
                                val px = pps.floatValue * density
                                when (mode) {
                                    Mode.SCRUB -> { send(TimelineMath.dragged(view.doubleValue, d.x, px, dur), false); ch.consume() }
                                    Mode.VSCROLL -> { vScroll.floatValue = (vScroll.floatValue - d.y / density).coerceIn(0f, max(0f, contentH - visibleH / density)); ch.consume() }
                                    Mode.TRIM_LEFT, Mode.TRIM_RIGHT -> { actNow(EditAction.TrimBy(selId!!, mode == Mode.TRIM_LEFT, totalX / px.toDouble(), done = false, snapSec = 10.0 / pps.floatValue)); ch.consume() }
                                    Mode.KEY -> { actNow(EditAction.MoveKey(selId!!, pendingKey!!, totalX / px.toDouble(), done = false)); ch.consume() }
                                    Mode.MOVE -> {
                                        val item = hit.item!!
                                        if (hit.lane?.track?.kind == TrackKind.MAIN) {
                                            val cur = state.project ?: proj
                                            val t = TimelineMath.timeAt(ch.position.x, view.doubleValue, w, px)
                                            val idx = timeline(cur).indexOfFirst { t >= it.startSec && t < it.endSec }.let { if (it < 0) (if (t < 0) 0 else cur.main.items.size - 1) else it }
                                            if (idx != lastIndex) { lastIndex = idx; actNow(EditAction.Reorder(item.id, idx, done = false)) }
                                        } else actNow(EditAction.MoveBy(item.id, totalX / px.toDouble(), snapSec = 10.0 / pps.floatValue, done = false))
                                        ch.consume()
                                    }
                                    else -> {}
                                }
                            }
                            val px = pps.floatValue * density
                            val totalX = last.x - down.position.x
                            when (mode) {
                                Mode.PINCH -> { actNow(EditAction.Zoom(pps.floatValue)); send(view.doubleValue, true); busy.value = false }
                                Mode.TRIM_LEFT, Mode.TRIM_RIGHT -> { actNow(EditAction.TrimBy(selId!!, mode == Mode.TRIM_LEFT, totalX / px.toDouble(), done = true, snapSec = 10.0 / pps.floatValue)); busy.value = false }
                                Mode.KEY -> { actNow(EditAction.MoveKey(selId!!, pendingKey!!, totalX / px.toDouble(), done = true)); busy.value = false }
                                Mode.MOVE -> {
                                    val item = hit.item!!
                                    if (hit.lane?.track?.kind == TrackKind.MAIN) { if (lastIndex >= 0) actNow(EditAction.Reorder(item.id, lastIndex, done = true)) }
                                    else actNow(EditAction.MoveBy(item.id, totalX / px.toDouble(), snapSec = 10.0 / pps.floatValue, done = true))
                                    busy.value = false
                                }
                                Mode.SCRUB -> {
                                    val vx = tracker.calculateVelocity().x
                                    if (abs(vx) < 50f * density) { send(view.doubleValue, true); busy.value = false }
                                    else fling = launch {
                                        val start = view.doubleValue
                                        try {
                                            AnimationState(0f, -vx).animateDecay(decay) {
                                                val t = (start + value / px).coerceIn(0.0, state.duration)
                                                send(t, false)
                                                if (t <= 0.0 || t >= state.duration) cancelAnimation()
                                            }
                                            send(view.doubleValue, true)
                                        } finally { busy.value = false }
                                    }
                                }
                                Mode.VSCROLL -> busy.value = false
                                Mode.NONE -> {
                                    busy.value = false
                                    tap(down.position, w, density, state, lanesNow, view.doubleValue, pps.floatValue, vScroll.floatValue, actNow)
                                }
                            }
                        }
                    }
                },
        ) {
            val dp = density
            val w = size.width
            val ppsPx = pps.floatValue * dp
            val v = view.doubleValue
            val vs = vScroll.floatValue * dp
            fun xOf(t: Double) = TimelineMath.xOf(t, v, w, ppsPx)
            val tStart = TimelineMath.timeAt(0f, v, w, ppsPx); val tEnd = TimelineMath.timeAt(w, v, w, ppsPx)
            // Before 0 and after the end: a darker band, so the start and end of the edit read at a glance.
            drawRect(m.t.surface, Offset(0f, 0f), Size(max(0f, xOf(0.0)), size.height))
            drawRect(m.t.surface, Offset(min(w, xOf(ui.duration)), 0f), Size(max(0f, w - xOf(ui.duration)), size.height))

            clipRect(0f, RULER_DP * dp, w, size.height) {
                for (lane in lanes) {
                    val t = lane.track ?: continue
                    val top = lane.top * dp - vs; val h = lane.height * dp
                    if (top > size.height || top + h < RULER_DP * dp) continue
                    when {
                        lane.kind == LaneKind.CLIP_SOUND -> clipSoundLane(p, t, spans, waves, detached, top, h, ::xOf, ppsPx, colors, ui.selectedId, measurer, m.t.accent, m.t.muted, m.t.surface2, m.t.body, tStart, tEnd)
                        t.kind == TrackKind.MAIN -> t.items.forEachIndexed { i, it ->
                            val c = it as VideoClip
                            val sp = spans[i]
                            val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                            if (r < 0 || l > w) return@forEachIndexed
                            clipTile(c, l, r, top, h, frames[c.asset].orEmpty(), p.asset(c.asset)?.durationSec ?: 1.0, ppsPx, m.t.surface2)
                            if (c.speedCurve != null || c.speed != 1.0 || c.holdSec != null) {
                                val lbl = if (c.holdSec != null) "${trim(c.holdSec!!)} s" else if (c.speedCurve != null) "Curve" else "${trim(c.speed)}×"
                                val tl = measurer.measure(lbl, TextStyle(fontFamily = m.t.body, fontSize = 11.sp, color = Color.White, fontFeatureSettings = "tnum"))
                                drawRect(Color.Black.copy(alpha = .55f), Offset(l + 3 * dp, top + h - tl.size.height - 4 * dp), Size(tl.size.width + 6f * dp, tl.size.height.toFloat()))
                                drawText(tl, topLeft = Offset(l + 6 * dp, top + h - tl.size.height - 4 * dp))
                            }
                            if (ui.selectedId == c.id) {
                                drawRoundRect(m.t.accent, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp), style = Stroke(2 * dp))
                                // Trim handles.
                                for (x in listOf(l, r - 10 * dp)) {
                                    drawRoundRect(m.t.accent, Offset(x, top), Size(10 * dp, h), CornerRadius(3 * dp))
                                    drawRect(Color.White, Offset(x + 4 * dp, top + h / 2 - 8 * dp), Size(2 * dp, 16 * dp))
                                }
                            }
                        }
                        t.kind == TrackKind.CAPTION -> for (pg in pages) {
                            val l = xOf(pg.startSec); val r = xOf(pg.endSec) - 2 * dp
                            if (r < 0 || l > w) continue
                            chip(measurer, pg.words.joinToString(" ") { it.text }, l, r, top, h, m.t.surface2, m.t.line, m.t.ink, m.t.body)
                        }
                        t.kind.isAudio -> for (it in t.items) {
                            val c = it as AudioClip
                            val sp = itemSpan(p, t, c)
                            val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                            if (r < 0 || l > w) continue
                            val (bg, wave) = when (t.kind) { TrackKind.MUSIC -> colors.music to colors.musicWave; TrackKind.VOICE -> if (t.name == SuiteOps.CLIP_SOUND_TRACK) colors.sound to colors.soundWave else colors.voice to colors.voiceWave; else -> colors.voice to colors.voiceWave }
                            val muted = c.muted == true || t.muted == true || p.mute == true
                            drawRoundRect(if (muted) m.t.surface2 else bg, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp))
                            soundBars(c, waves[c.asset], l, r, top, h, if (muted) m.t.muted else wave, ppsPx, muted, max(l, 0f), min(r, w))
                            fadeRamps(c, l, r, top, h, ppsPx, wave)
                            val label = when (t.kind) { TrackKind.MUSIC -> "Music"; TrackKind.SFX -> "Sound effect"; else -> if (t.name == SuiteOps.CLIP_SOUND_TRACK) "Detached sound" else "Voice-over" } + if (muted) " · muted" else ""
                            laneLabel(measurer, label, l, r, top, h, m.t.ink, m.t.body, if (muted) m.t.surface2 else bg)
                            if (ui.selectedId == it.id) drawRoundRect(m.t.accent, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp), style = Stroke(2 * dp))
                            if (t.kind == TrackKind.MUSIC) for (b in beats) { val x = xOf(b); if (x in l..r) drawRect(m.t.accent, Offset(x, top), Size(2 * dp, 5 * dp)) }
                        }
                        t.kind == TrackKind.TEXT -> for (it in t.items) {
                            val sp = itemSpan(p, t, it)
                            val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                            if (r < 0 || l > w) continue
                            chip(measurer, (it as studio.muse.core.edit.TextItem).text, l, r, top, h, colors.hook, if (ui.selectedId == it.id) m.t.accent else Color.Transparent, m.t.ink, m.t.body)
                        }
                        t.kind == TrackKind.ADJUST -> for (it in t.items) {
                            val sp = itemSpan(p, t, it)
                            val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                            if (r < 0 || l > w) continue
                            chip(measurer, "Adjustment", l, r, top, h, m.t.surface2, if (ui.selectedId == it.id) m.t.accent else m.t.line, m.t.ink, m.t.body)
                        }
                        t.kind == TrackKind.VIDEO || t.kind == TrackKind.IMAGE -> for (it in t.items) {
                            val sp = itemSpan(p, t, it)
                            val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                            if (r < 0 || l > w) continue
                            val label = if (t.name == "Cut-out") "Cut-out" else if (t.kind == TrackKind.IMAGE) "Image" else "Overlay"
                            chip(measurer, label, l, r, top, h, colors.pip, if (ui.selectedId == it.id) m.t.accent else m.t.line, m.t.ink, m.t.body)
                        }
                        else -> {}
                    }
                }
                // Trim handles on the selected item of any other lane (the main lane draws its own above).
                ui.selectedId?.let { sid ->
                    for (lane in lanes) {
                        val t = lane.track ?: continue
                        if (lane.kind != LaneKind.TRACK || t.kind == TrackKind.MAIN || t.kind == TrackKind.CAPTION) continue
                        val item = t.items.firstOrNull { it.id == sid } ?: continue
                        val sp = itemSpan(p, t, item)
                        val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                        val top = lane.top * dp - vs; val h = lane.height * dp
                        for (x in listOf(l, r - 8 * dp)) {
                            drawRoundRect(m.t.accent, Offset(x, top), Size(8 * dp, h), CornerRadius(3 * dp))
                            drawRect(Color.White, Offset(x + 3 * dp, top + h / 2 - 5 * dp), Size(2 * dp, 10 * dp))
                        }
                    }
                }
                // The selected item's keyframes: ◆ along its lane's lower edge (drag one to move it).
                ui.selectedId?.let { sid ->
                    for (lane in lanes) {
                        val t = lane.track ?: continue
                        if (lane.kind != LaneKind.TRACK) continue
                        val item = t.items.firstOrNull { it.id == sid } ?: continue
                        val sp = itemSpan(p, t, item)
                        val cy = (lane.top + lane.height) * dp - vs - 8 * dp
                        for (k in SuiteOps.keyTimes(item)) {
                            val x = xOf(sp.startSec + k)
                            if (x < -10 * dp || x > w + 10 * dp) continue
                            val r = 5 * dp
                            val path = Path().apply { moveTo(x, cy - r); lineTo(x + r, cy); lineTo(x, cy + r); lineTo(x - r, cy); close() }
                            drawPath(path, Color.White); drawPath(path, m.t.accent, style = Stroke(1.5f * dp))
                        }
                    }
                }
                // Transition marks on the cuts.
                val mainLane = lanes.first()
                p.mainClips.forEachIndexed { i, c ->
                    if (i == 0 || c.transitionIn == null) return@forEachIndexed
                    val x = xOf(spans[i].startSec + spans[i].transitionSec / 2) - 1 * dp
                    val cy = (mainLane.top + mainLane.height / 2) * dp - vs
                    val r = 7 * dp
                    val path = Path().apply { moveTo(x, cy - r); lineTo(x + r, cy); lineTo(x, cy + r); lineTo(x - r, cy); close() }
                    drawPath(path, m.t.accent); drawPath(path, Color.White, style = Stroke(1.5f * dp))
                }
            }
            // Ruler (pinned): ticks every step, labels every second tick, frame ticks when zoomed far in.
            drawRect(m.t.bg, Offset(0f, 0f), Size(w, RULER_DP * dp))
            val step = TimelineMath.rulerStep(pps.floatValue)
            var k = floor(max(0.0, tStart) / step).toLong()
            while (k * step <= min(ui.duration, tEnd) + 1e-9) {
                val t = k * step
                val x = xOf(t)
                val major = k % 2 == 0L
                if (major) drawText(measurer.measure(TimelineMath.rulerLabel(t), TextStyle(fontFamily = m.t.body, fontSize = 11.sp, color = m.t.muted, fontFeatureSettings = "tnum"), softWrap = false), topLeft = Offset(x + 3 * dp, 4 * dp))
                drawRect(m.t.line, Offset(x, if (major) 4 * dp else 16 * dp), Size(1 * dp, if (major) 20 * dp else 8 * dp))
                k++
            }
            drawRect(m.t.line, Offset(0f, RULER_DP * dp - 1 * dp), Size(w, 1 * dp))
            // Recording a voice-over: a red bar along the ruler from where it started to the playhead.
            ui.recordingAt?.let { from ->
                val l = xOf(from); val r = xOf(maxOf(from, view.doubleValue))
                if (r > l) drawRect(Color(0xFFE5484D), Offset(l, RULER_DP * dp - 5 * dp), Size(r - l, 4 * dp))
            }
            // The playhead, fixed in the centre, with a small head on the ruler.
            val cx = w / 2f
            drawRect(m.t.ink, Offset(cx - 1 * dp, 0f), Size(2 * dp, size.height))
            val head = Path().apply { moveTo(cx - 6 * dp, 0f); lineTo(cx + 6 * dp, 0f); lineTo(cx + 6 * dp, 6 * dp); lineTo(cx, 12 * dp); lineTo(cx - 6 * dp, 6 * dp); close() }
            drawPath(head, m.t.ink)
        }
        // "+": add a clip or an overlay (the tablet's toolbar has Add instead).
        if (plus) Box(
            Modifier.align(Alignment.TopEnd).offset(x = (-4).dp, y = (RULER_DP + 2).dp).size(48.dp).press { act(EditAction.Open(Panel.OVERLAY)) }.padding(8.dp).background(m.t.surface).border(1.dp, m.t.line)
                .semantics { contentDescription = "Add" },
            contentAlignment = Alignment.Center,
        ) { EIc("plus", 16.dp, m.t.ink) }
    }
}

/** What is under a point: its lane and the item there (null on the ruler or an empty spot). */
private data class Hit(val lane: Lane?, val item: studio.muse.core.edit.Item?)

private fun hitAt(o: Offset, width: Float, density: Float, proj: EditProject, lanes: List<Lane>, view: Double, ppsDp: Float, vScrollDp: Float): Hit {
    if (o.y / density < RULER_DP) return Hit(null, null)
    val t = TimelineMath.timeAt(o.x, view, width, ppsDp * density)
    val yDp = o.y / density + vScrollDp
    val lane = lanes.firstOrNull { yDp >= it.top - 3 && yDp <= it.top + it.height + 3 } ?: return Hit(null, null)
    if (lane.kind == LaneKind.CLIP_SOUND) return Hit(lane, null)
    val track = lane.track ?: return Hit(lane, null)
    return Hit(lane, track.items.firstOrNull { val sp = itemSpan(proj, track, it); t >= sp.startSec && t < sp.endSec })
}

/** A tap: selects the item under it (the clip-sound lane selects its clip and opens Audio; captions open Captions). */
private fun tap(o: Offset, width: Float, density: Float, s: EditSuiteUi, lanes: List<Lane>, view: Double, ppsDp: Float, vScrollDp: Float, act: (EditAction) -> Unit) {
    val proj = s.project ?: return
    val t = TimelineMath.timeAt(o.x, view, width, ppsDp * density)
    if (o.y / density < RULER_DP) { act(EditAction.Scrub(t.coerceIn(0.0, s.duration), end = true)); return } // tap the ruler: go there
    val yDp = o.y / density + vScrollDp
    val lane = lanes.firstOrNull { yDp >= it.top - 3 && yDp <= it.top + it.height + 3 }
    val track = lane?.track
    if (lane?.kind == LaneKind.CLIP_SOUND) {
        val hit = proj.main.items.firstOrNull { val sp = itemSpan(proj, proj.main, it); t >= sp.startSec && t < sp.endSec }
        if (hit != null) { act(EditAction.Select(hit.id)); act(EditAction.Open(Panel.AUDIO)) } else act(EditAction.Select(null))
        return
    }
    val hit = track?.items?.firstOrNull { val sp = itemSpan(proj, track, it); t >= sp.startSec && t < sp.endSec }
    when {
        hit is studio.muse.core.edit.AdjustItem && s.selectedId != hit.id -> { act(EditAction.Select(hit.id)); act(EditAction.Open(Panel.FILTERS)) }
        hit != null -> act(EditAction.Select(if (s.selectedId == hit.id) null else hit.id))
        track?.kind == TrackKind.CAPTION -> act(EditAction.Open(Panel.CAPTIONS))
        else -> act(EditAction.Select(null))
    }
}

/** Main clip ids whose sound was detached (muted, with a detached-sound clip of the same source). */
private fun detachedSounds(p: EditProject): Set<String> {
    val outs = p.tracks.filter { it.kind == TrackKind.VOICE && it.name == SuiteOps.CLIP_SOUND_TRACK }.flatMap { it.items }.filterIsInstance<AudioClip>()
    if (outs.isEmpty()) return emptySet()
    return p.mainClips.filter { c -> c.muted == true && outs.any { (it.asset == (c.audioAsset ?: c.asset)) && abs(it.inSec - c.inSec) < 1e-3 } }.map { it.id }.toSet()
}

/** The source second at [local] timeline seconds into [c] (constant speed without allocating). */
private fun srcAt(c: MediaClip, local: Double): Double {
    if ((c as? VideoClip)?.holdSec != null) return c.inSec // a freeze frame shows one frame
    val sp = when (c) { is VideoClip -> if (c.speedCurve != null) null else c.speed; is AudioClip -> c.speed ?: 1.0 }
    return if (sp != null) c.inSec + local * sp else clipSourceAt(c, local)
}

private fun DrawScope.clipSoundLane(
    p: EditProject, main: Track, spans: List<studio.muse.core.edit.MainSpan>, waves: Map<String, Peaks>, detached: Set<String>, top: Float, h: Float,
    xOf: (Double) -> Float, ppsPx: Float, colors: LaneColors, selected: String?, measurer: TextMeasurer, accent: Color, muted: Color, off: Color,
    font: androidx.compose.ui.text.font.FontFamily, tStart: Double, tEnd: Double,
) {
    val dp = density
    p.mainClips.forEachIndexed { i, c ->
        val sp = spans[i]
        if (sp.endSec < tStart || sp.startSec > tEnd) return@forEachIndexed
        val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
        val has = SuiteOps.hasSound(p, c)
        val silent = c.muted == true || main.muted == true || p.mute == true || c.holdSec != null
        drawRoundRect(if (!has || silent) off else colors.sound, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp))
        if (has) {
            soundBars(c, waves[c.audioAsset ?: c.asset], l, r, top, h, if (silent) muted else colors.soundWave, ppsPx, silent, max(l, 0f), min(r, size.width))
            if (!silent) fadeRamps(c, l, r, top, h, ppsPx, colors.soundWave)
        }
        val label = when { !has -> "No sound"; c.holdSec != null -> "Freeze frame"; c.id in detached -> "Sound detached"; silent -> "Muted"; else -> null }
        if (label != null) laneLabel(measurer, label, l, r, top, h, muted, font, off)
        if (selected == c.id) drawRoundRect(accent, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp), style = Stroke(2 * dp))
    }
}

/** Real levels (peaks of the source under each 3 dp bar) × the clip's volume; a flat line when silent or not decoded yet. */
private fun DrawScope.soundBars(c: MediaClip, peaks: Peaks?, l: Float, r: Float, top: Float, h: Float, color: Color, ppsPx: Float, silent: Boolean, from: Float, to: Float) {
    val dp = density
    val mid = top + h / 2
    if (silent || peaks == null) { drawRect(color, Offset(from, mid - 0.5f * dp), Size(max(0f, to - from), 1 * dp)); return }
    val step = 3 * dp
    val gain = (c.volume ?: 1.0).toFloat()
    val len = clipLength(c)
    var x = l + floor(((from - l) / step).toDouble()).toFloat().coerceAtLeast(0f) * step
    while (x < to) {
        val a = ((x - l) / ppsPx).toDouble(); val b = ((x + step - l) / ppsPx).toDouble()
        val level = peaks.max(srcAt(c, a), srcAt(c, min(b, len)))
        val fade = fadeGain(c, a, len)
        val bh = max(1 * dp, (h - 6 * dp) * min(1f, level * gain * fade))
        drawRect(color, Offset(x, mid - bh / 2), Size(1.6f * dp, bh))
        x += step
    }
}

private fun fadeGain(c: MediaClip, local: Double, len: Double): Float {
    var g = 1.0
    c.fadeInSec?.takeIf { it > 0 }?.let { if (local < it) g *= local / it }
    c.fadeOutSec?.takeIf { it > 0 }?.let { if (local > len - it) g *= (len - local) / it }
    return g.coerceIn(0.0, 1.0).toFloat()
}

/** Fade-in / fade-out as ramps over the lane. */
private fun DrawScope.fadeRamps(c: MediaClip, l: Float, r: Float, top: Float, h: Float, ppsPx: Float, color: Color) {
    val dp = density
    c.fadeInSec?.takeIf { it > 0 }?.let { f -> drawLine(color, Offset(l, top + h - 1 * dp), Offset(min(r, l + (f * ppsPx).toFloat()), top + 1 * dp), 1.5f * dp) }
    c.fadeOutSec?.takeIf { it > 0 }?.let { f -> drawLine(color, Offset(max(l, r - (f * ppsPx).toFloat()), top + 1 * dp), Offset(r, top + h - 1 * dp), 1.5f * dp) }
}

/** A lane item's name on a small backing of the lane colour, pinned to the visible left edge of the item. */
private fun DrawScope.laneLabel(measurer: TextMeasurer, text: String, l: Float, r: Float, top: Float, h: Float, ink: Color, font: androidx.compose.ui.text.font.FontFamily, bg: Color) {
    if (r - l < 40 * density) return
    clipRect(max(l, 0f), top, min(r, size.width), top + h) {
        val tl = measurer.measure(text, TextStyle(fontFamily = font, fontSize = 11.sp, color = ink), maxLines = 1, softWrap = false)
        val x = max(l, 0f) + 4 * density
        val y = top + (h - tl.size.height) / 2
        drawRoundRect(bg, Offset(x, y), Size(tl.size.width + 8 * density, tl.size.height.toFloat()), CornerRadius(3 * density))
        drawText(tl, topLeft = Offset(x + 4 * density, y))
    }
}

private fun trim(v: Double): String = if (v == floor(v)) v.toInt().toString() else ((v * 100).roundToInt() / 100.0).toString()

/** A video clip as a strip of source frames (each 40 dp wide), or a plain tile without frames. */
private fun DrawScope.clipTile(c: VideoClip, l: Float, r: Float, top: Float, h: Float, frames: List<ImageBitmap>, assetDur: Double, pps: Float, fallback: Color) {
    clipRect(max(l, 0f), top, min(r, size.width), top + h) {
        drawRoundRect(fallback, Offset(l, top), Size(r - l, h), CornerRadius(4 * density))
        if (frames.isEmpty()) return@clipRect
        val tw = 40 * density
        // Only the tiles on screen.
        var x = l + floor(((max(l, 0f) - l) / tw).toDouble()).toFloat() * tw
        val end = min(r, size.width)
        while (x < end) {
            val local = ((x + tw / 2 - l) / pps).toDouble()
            val src = srcAt(c, local)
            val k = ((src / assetDur.coerceAtLeast(0.01)) * (frames.size - 1)).roundToInt().coerceIn(0, frames.lastIndex)
            val f = frames[k]
            val scale = maxOf(tw / f.width, h / f.height)
            val sw = (tw / scale).roundToInt().coerceIn(1, f.width); val sh = (h / scale).roundToInt().coerceIn(1, f.height)
            drawImage(f, IntOffset((f.width - sw) / 2, (f.height - sh) / 2), IntSize(sw, sh), IntOffset(x.roundToInt(), top.roundToInt()), IntSize(tw.roundToInt() + 1, h.roundToInt()))
            x += tw
        }
    }
}

/** A labelled chip clipped to its span. */
private fun DrawScope.chip(
    measurer: TextMeasurer, text: String, l: Float, r: Float, top: Float, h: Float, bg: Color, border: Color, ink: Color, font: androidx.compose.ui.text.font.FontFamily,
) {
    clipRect(max(l, 0f), top, min(r, size.width), top + h) {
        drawRect(bg, Offset(l, top), Size(r - l, h))
        if (border != Color.Transparent) drawRect(border, Offset(l, top), Size(r - l, h), style = Stroke(1 * density))
        val tl = measurer.measure(text, TextStyle(fontFamily = font, fontSize = 11.sp, color = ink), maxLines = 1, softWrap = false)
        drawText(tl, topLeft = Offset(max(l, 0f) + 12 * density, top + (h - tl.size.height) / 2)) // clear of a trim handle
    }
}

/** A track header's small toggle (mute, hide): 32 dp, tinted when on. */
@Composable
private fun HeaderToggle(icon: String, label: String, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(32.dp).press(onClick = onClick).semantics { contentDescription = label; role = androidx.compose.ui.semantics.Role.Switch; stateDescription = if (on) "On" else "Off" },
        contentAlignment = Alignment.Center) { EIc(icon, 16.dp, if (on) m.t.accent else m.t.muted) }
}
