package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.Item
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.captionPages
import studio.muse.core.edit.clipSourceAt
import studio.muse.core.edit.itemSpan
import studio.muse.core.edit.timeline
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/** One horizontal lane of the phone timeline: its track (null = ruler), top and height in dp. */
data class Lane(val track: Track?, val top: Float, val height: Float)

/**
 * The lanes for [p]: ruler, main video, captions, overlays, music, voice, sfx, text (design EM1 order). [roomy]: the
 * tablet's taller lanes beside their named headers (plans/edit-layout.md).
 */
fun lanesOf(p: EditProject, roomy: Boolean = false): List<Lane> {
    val out = ArrayList<Lane>()
    var y = 30f
    fun add(t: Track, h: Float, gap: Float = 6f) { out += Lane(t, y, h); y += h + gap }
    add(p.main, if (roomy) 60f else 52f, 8f)
    val order = listOf(TrackKind.CAPTION, TrackKind.VIDEO, TrackKind.IMAGE, TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX, TrackKind.TEXT)
    for (k in order) for (t in p.tracks) if (t.kind == k) add(t,
        if (roomy) when (k) { TrackKind.CAPTION, TrackKind.TEXT, TrackKind.SFX -> 28f; else -> 32f }
        else when (k) { TrackKind.CAPTION, TrackKind.TEXT, TrackKind.SFX -> 20f; TrackKind.MUSIC -> 26f; TrackKind.VOICE -> 22f; else -> 26f },
        if (roomy) 6f else if (k == TrackKind.CAPTION) 6f else 4f)
    return out
}

/** A track's name in the tablet's header column. */
fun trackName(t: Track): String = when (t.kind) {
    TrackKind.MAIN -> "Video"; TrackKind.CAPTION -> "Captions"; TrackKind.MUSIC -> "Music"; TrackKind.VOICE -> "Voice-over"
    TrackKind.SFX -> "Sound effects"; TrackKind.TEXT -> "Text"; TrackKind.IMAGE -> "Image"; else -> if (t.name == "Cut-out") "Cut-out" else "Overlay"
}

private fun trackIcon(t: Track): String = when (t.kind) {
    TrackKind.MAIN -> "film-strip"; TrackKind.CAPTION -> "closed-captioning"; TrackKind.MUSIC -> "music"; TrackKind.VOICE -> "mic"
    TrackKind.SFX -> "waveform"; TrackKind.TEXT -> "text-t"; else -> "layers"
}

/** "0:02" for the ruler (tabular figures, no monospace). */
private fun rulerTime(s: Int): String = "${s / 60}:" + (s % 60).toString().padStart(2, '0')

/** Colours of the audio/text lanes (design: music green, voice violet, hook rose), darker on dark themes. */
private data class LaneColors(val music: Color, val musicWave: Color, val voice: Color, val voiceWave: Color, val hook: Color, val pip: Color)

@Composable
private fun laneColors(): LaneColors = if (muse.t.dark) LaneColors(Color(0xFF1E3524), Color(0xFF7BD88F), Color(0xFF2A2440), Color(0xFFA99BF0), Color(0xFF3A2222), Color(0xFF26313A))
else LaneColors(Color(0xFFDCEBDD), Color(0xFF2F6B3A), Color(0xFFE6E0F2), Color(0xFF4B3F86), Color(0xFFF1D9D9), Color(0xFFDDE5EC))

/**
 * The phone timeline (EM1): the playhead stays in the centre and the tracks scroll under it (drag to scrub, pinch to
 * zoom, tap to select). Video clips show frames of their source with transition diamonds at the cuts; captions show
 * their pages as chips; music and voice show waveforms with the beat marks; text/hooks show chips. "+" adds clips.
 * [frames]: frames of each video asset spread evenly over its length (none in tests → plain tiles).
 */
@Composable
fun SuiteTimeline(ui: EditSuiteUi, frames: Map<String, List<ImageBitmap>>, act: (EditAction) -> Unit, modifier: Modifier = Modifier,
                  /** Tablet: named track headers on the left, taller lanes, no floating "+" (the toolbar has Add). */
                  headers: Boolean = false) {
    val m = muse
    val p = ui.project ?: return
    val lanes = remember(p, headers) { lanesOf(p, headers) }
    if (headers) {
        val h = (lanes.lastOrNull()?.let { it.top + it.height } ?: 100f) + 8f
        Row(modifier.fillMaxWidth().height(h.dp.coerceAtMost(300.dp)).background(m.t.bg)) {
            Box(Modifier.width(196.dp).fillMaxHeight()) {
                for (lane in lanes) {
                    val t = lane.track ?: continue
                    Row(Modifier.offset(y = lane.top.dp).height(lane.height.dp).fillMaxWidth().padding(start = 16.dp, end = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        EIc(trackIcon(t), 16.dp, m.t.muted)
                        studio.muse.app.ui.components.T(trackName(t), m.scale.caption, m.t.ink, Modifier.weight(1f), maxLines = 1)
                        // Mute a track with sound, hide a track with pictures (one undo step each, as on the Mac).
                        val name = trackName(t).lowercase()
                        if (t.kind.isAudio || t.kind == studio.muse.core.edit.TrackKind.MAIN) HeaderToggle(if (t.muted == true) "speaker-slash" else "speaker-high",
                            if (t.muted == true) "Unmute $name" else "Mute $name", t.muted == true) { act(EditAction.ToggleTrackMuted(t.id)) }
                        if (!t.kind.isAudio) HeaderToggle(if (t.hidden == true) "eye-slash" else "eye", if (t.hidden == true) "Show $name" else "Hide $name", t.hidden == true) {
                            act(EditAction.ToggleTrackHidden(t.id))
                        }
                    }
                }
            }
            Box(Modifier.width(1.dp).fillMaxHeight().background(m.t.line))
            TimelineCanvas(ui, frames, act, lanes, Modifier.weight(1f), plus = false)
        }
        return
    }
    TimelineCanvas(ui, frames, act, lanes, modifier, plus = true)
}

@Composable
private fun TimelineCanvas(ui: EditSuiteUi, frames: Map<String, List<ImageBitmap>>, act: (EditAction) -> Unit, lanes: List<Lane>, modifier: Modifier, plus: Boolean) {
    val m = muse
    val p = ui.project ?: return
    val roomy = !plus
    val height = (lanes.lastOrNull()?.let { it.top + it.height } ?: 100f).coerceAtLeast(200f - 8f) + 8f
    val measurer = rememberTextMeasurer()
    val colors = laneColors()
    val spans = remember(p) { timeline(p) }
    val pages = remember(p) { captionPages(p) }
    val beats = remember(p, ui.beatMarks) { SuiteOps.beatTimes(p, ui.beatMarks == BeatMarks.STRONG) }
    val state by rememberUpdatedState(ui)
    val actNow by rememberUpdatedState(act)
    val dragStart = remember { mutableFloatStateOf(0f) }
    BoxWithConstraints(modifier.fillMaxWidth().let { if (roomy) it.fillMaxHeight() else it.height(height.dp.coerceAtMost(260.dp)) }.background(m.t.bg)) {
        val widthPx = constraints.maxWidth.toFloat()
        Canvas(
            Modifier.fillMaxSize()
                .semantics { contentDescription = "Timeline" }
                .pointerInput(Unit) {
                    detectHorizontalDragGestures(onDragStart = { dragStart.floatValue = state.playheadSec.toFloat() }) { c, dx ->
                        c.consume()
                        val pps = state.pxPerSec * density
                        dragStart.floatValue = (dragStart.floatValue - dx / pps).coerceIn(0f, state.duration.toFloat())
                        actNow(EditAction.Seek(dragStart.floatValue.toDouble()))
                    }
                }
                .pointerInput(Unit) { detectTransformGestures { _, _, zoom, _ -> if (zoom != 1f) actNow(EditAction.Zoom(state.pxPerSec * zoom)) } }
                .pointerInput(Unit) {
                    detectTapGestures { o ->
                        val s = state
                        val proj = s.project ?: return@detectTapGestures
                        val pps = s.pxPerSec * density
                        val t = s.playheadSec + (o.x - size.width / 2f) / pps
                        val yDp = o.y / density
                        val lane = lanesOf(proj, roomy).firstOrNull { yDp >= it.top - 2 && yDp <= it.top + it.height + 2 }?.track
                        val hit = lane?.items?.firstOrNull { val sp = itemSpan(proj, lane, it); t >= sp.startSec && t < sp.endSec }
                        val captionHit = lane?.kind == TrackKind.CAPTION
                        when {
                            hit != null -> actNow(EditAction.Select(if (s.selectedId == hit.id) null else hit.id))
                            captionHit -> actNow(EditAction.Open(Panel.CAPTIONS))
                            else -> actNow(EditAction.Select(null))
                        }
                    }
                },
        ) {
            val pps = ui.pxPerSec * density
            val x0 = size.width / 2f - (ui.playheadSec * pps).toFloat()
            fun xOf(t: Double) = x0 + (t * pps).toFloat()
            val dp = density
            // Ruler: seconds, labelled every 2 s ("0 s", "·" between).
            val step = when { ui.pxPerSec < 14 -> 5; ui.pxPerSec < 24 -> 2; else -> 1 }
            var s = 0
            while (s <= ui.duration + step) {
                val x = xOf(s.toDouble())
                if (x > -40 && x < size.width + 40) {
                    if (s % (step * 2) == 0) drawText(measurer.measure(rulerTime(s), TextStyle(fontFamily = m.t.body, fontSize = 11.sp, color = m.t.muted, fontFeatureSettings = "tnum"), softWrap = false), topLeft = Offset(x + 3 * dp, 5 * dp))
                    drawRect(m.t.line, Offset(x, if (s % (step * 2) == 0) 4 * dp else 14 * dp), Size(1 * dp, if (s % (step * 2) == 0) 18 * dp else 8 * dp))
                }
                s += step
            }
            for (lane in lanes) {
                val t = lane.track ?: continue
                val top = lane.top * dp; val h = lane.height * dp
                when (t.kind) {
                    TrackKind.MAIN -> t.items.forEachIndexed { i, it ->
                        val c = it as VideoClip
                        val sp = spans[i]
                        val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                        if (r < 0 || l > size.width) return@forEachIndexed
                        clipTile(c, l, r, top, h, frames[c.asset].orEmpty(), p.asset(c.asset)?.durationSec ?: 1.0, sp.startSec, pps, m.t.surface2)
                        if (ui.selectedId == c.id) drawRoundRect(m.t.accent, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp), style = Stroke(2 * dp))
                        if (c.speedCurve != null || c.speed != 1.0) {
                            val lbl = if (c.speedCurve != null) "curve" else "${trim(c.speed)}×"
                            val tl = measurer.measure(lbl, TextStyle(fontFamily = m.t.body, fontSize = 11.sp, color = Color.White, fontFeatureSettings = "tnum"))
                            drawRect(Color.Black.copy(alpha = .55f), Offset(l + 3 * dp, top + h - tl.size.height - 4 * dp), Size(tl.size.width + 6f * dp, tl.size.height.toFloat()))
                            drawText(tl, topLeft = Offset(l + 6 * dp, top + h - tl.size.height - 4 * dp))
                        }
                    }
                    TrackKind.CAPTION -> for (pg in pages) {
                        val l = xOf(pg.startSec); val r = xOf(pg.endSec) - 2 * dp
                        if (r < 0 || l > size.width) continue
                        chip(measurer, pg.words.joinToString(" ") { it.text }, l, r, top, h, m.t.surface2, m.t.line, m.t.ink, m.t.body)
                    }
                    TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX -> for (it in t.items) {
                        val sp = itemSpan(p, t, it)
                        val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                        if (r < 0 || l > size.width) continue
                        val (bg, wave) = if (t.kind == TrackKind.MUSIC) colors.music to colors.musicWave else colors.voice to colors.voiceWave
                        drawRoundRect(bg, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp))
                        waveform(l, r, top, h, wave, (it.id.hashCode() and 0xffff), x0, pps / 7f)
                        if (ui.selectedId == it.id) drawRoundRect(m.t.accent, Offset(l, top), Size(r - l, h), CornerRadius(4 * dp), style = Stroke(2 * dp))
                        if (t.kind == TrackKind.MUSIC) for (b in beats) { val x = xOf(b); if (x in l..r) drawRect(m.t.accent, Offset(x, top - 4 * dp), Size(2 * dp, 4 * dp)) }
                    }
                    TrackKind.TEXT -> for (it in t.items) {
                        val sp = itemSpan(p, t, it)
                        val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                        if (r < 0 || l > size.width) continue
                        chip(measurer, "T " + (it as studio.muse.core.edit.TextItem).text, l, r, top, h, colors.hook, if (ui.selectedId == it.id) m.t.accent else Color.Transparent, m.t.accent, m.t.body)
                    }
                    TrackKind.VIDEO, TrackKind.IMAGE -> for (it in t.items) {
                        val sp = itemSpan(p, t, it)
                        val l = xOf(sp.startSec); val r = xOf(sp.endSec) - 2 * dp
                        if (r < 0 || l > size.width) continue
                        val label = if (t.name == "Cut-out") "Cut-out" else if (t.kind == TrackKind.IMAGE) "Image" else "PiP"
                        chip(measurer, label, l, r, top, h, colors.pip, if (ui.selectedId == it.id) m.t.accent else m.t.line, m.t.ink, m.t.mono)
                    }
                    else -> {}
                }
            }
            // Transition diamonds on the cuts.
            val mainLane = lanes.first()
            p.mainClips.forEachIndexed { i, c ->
                if (i == 0) return@forEachIndexed
                val x = xOf(spans[i].startSec + spans[i].transitionSec / 2) - 1 * dp
                val cy = (mainLane.top + mainLane.height / 2) * dp
                val r = 7 * dp
                val path = Path().apply { moveTo(x, cy - r); lineTo(x + r, cy); lineTo(x, cy + r); lineTo(x - r, cy); close() }
                if (c.transitionIn != null) { drawPath(path, m.t.accent); drawPath(path, Color.White, style = Stroke(1.5f * dp)) }
            }
            // The playhead, fixed in the centre.
            drawRect(m.t.ink, Offset(size.width / 2f - 1 * dp, 0f), Size(2 * dp, size.height))
        }
        // "+": add a clip or an overlay (the tablet's toolbar has Add instead).
        if (plus) Box(
            Modifier.align(Alignment.TopEnd).offset(x = (-4).dp, y = 32.dp).size(48.dp).press { act(EditAction.Open(Panel.OVERLAY)) }.padding(8.dp).background(m.t.surface).border(1.dp, m.t.line)
                .semantics { contentDescription = "Add" },
            contentAlignment = Alignment.Center,
        ) { EIc("plus", 16.dp, m.t.ink) }
    }
}

private fun trim(v: Double): String = if (v == floor(v)) v.toInt().toString() else ((v * 100).roundToInt() / 100.0).toString()

/** A video clip as a strip of source frames (each 40 dp wide), or a plain tile without frames. */
private fun DrawScope.clipTile(c: VideoClip, l: Float, r: Float, top: Float, h: Float, frames: List<ImageBitmap>, assetDur: Double, start: Double, pps: Float, fallback: Color) {
    clipRect(l, top, r, top + h) {
        drawRoundRect(fallback, Offset(l, top), Size(r - l, h), CornerRadius(4 * density))
        if (frames.isEmpty()) return@clipRect
        val tw = 40 * density
        var x = l
        while (x < r) {
            val local = ((x + tw / 2 - l) / pps).toDouble()
            val src = clipSourceAt(c, local)
            val k = ((src / assetDur.coerceAtLeast(0.01)) * (frames.size - 1)).roundToInt().coerceIn(0, frames.lastIndex)
            val f = frames[k]
            // Cover-crop the frame into a tw × h tile.
            val scale = maxOf(tw / f.width, h / f.height)
            val sw = (tw / scale).roundToInt().coerceIn(1, f.width); val sh = (h / scale).roundToInt().coerceIn(1, f.height)
            drawImage(f, IntOffset((f.width - sw) / 2, (f.height - sh) / 2), IntSize(sw, sh), IntOffset(x.roundToInt(), top.roundToInt()), IntSize(tw.roundToInt() + 1, h.roundToInt()))
            x += tw
        }
    }
}

/** A labelled chip clipped to its span. */
private fun DrawScope.chip(
    measurer: androidx.compose.ui.text.TextMeasurer, text: String, l: Float, r: Float, top: Float, h: Float, bg: Color, border: Color, ink: Color, font: androidx.compose.ui.text.font.FontFamily,
) {
    clipRect(l, top, r, top + h) {
        drawRect(bg, Offset(l, top), Size(r - l, h))
        if (border != Color.Transparent) drawRect(border, Offset(l, top), Size(r - l, h), style = Stroke(1 * density))
        val tl = measurer.measure(text, TextStyle(fontFamily = font, fontSize = 11.sp, color = ink), maxLines = 1, softWrap = false)
        drawText(tl, topLeft = Offset(l + 4 * density, top + (h - tl.size.height) / 2))
    }
}

/** A deterministic waveform (bars every 3 dp) — the look of the design; the real levels aren't decoded on the phone. */
private fun DrawScope.waveform(l: Float, r: Float, top: Float, h: Float, color: Color, seed: Int, x0: Float, unit: Float) {
    val step = 3 * density
    var x = l + 4 * density
    val mid = top + h / 2
    while (x < r - 4 * density) {
        val k = ((x - x0) / step).toInt()
        val n = (((k * 1103515245 + seed * 12345) ushr 8) and 1023) / 1023f
        val env = 0.35f + 0.65f * abs(kotlin.math.sin((k + seed) * 0.21f))
        val bh = (h - 6 * density) * (0.2f + 0.8f * n * env)
        drawRect(color, Offset(x, mid - bh / 2), Size(1.6f * density, bh))
        x += step
    }
}

/** A track header's small toggle (mute, hide): 32 dp, tinted when on. */
@Composable
private fun HeaderToggle(icon: String, label: String, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(32.dp).press(onClick = onClick).semantics { contentDescription = label; role = androidx.compose.ui.semantics.Role.Switch; stateDescription = if (on) "On" else "Off" },
        contentAlignment = Alignment.Center) { EIc(icon, 16.dp, if (on) m.t.accent else m.t.muted) }
}
