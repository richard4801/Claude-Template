package studio.muse.app.ui.screens.camera

import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import studio.muse.app.data.CamKey
import studio.muse.app.data.CameraAsset
import studio.muse.app.data.CameraSession
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.roundToInt

// ---------------------------------------------------------------- icons the app's set doesn't have

object CamIcons {
    private val PATHS = mapOf(
        "send" to "M4 12l16-8-6 16-2.5-6.5z M11.5 13.5L20 4",
        "cube" to "M12 3l8 4.5v9L12 21l-8-4.5v-9z M4 7.5l8 4.5 8-4.5 M12 12v9",
        "copy" to "M9 9h10v11h-10z M5 15V4h10",
        "refresh" to "M20 12a8 8 0 1 1 -2.3-5.6 M20 4v5h-5",
        "link" to "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0 -5.7-5.7l-1 1 M14 10a4 4 0 0 0 -5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
        "film" to "M4 5h16v14H4z M8 5v14M16 5v14M4 9h4M4 15h4M16 9h4M16 15h4",
        "cam" to "M3 8h11v8H3z M14 11l6-3v8l-6-3z",
    )
    private val cache = HashMap<String, ImageVector>()
    fun get(name: String): ImageVector = cache.getOrPut(name) {
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            addPath(addPathNodes(PATHS.getValue(name)), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = 1.7f,
                strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
        }.build()
    }
}

@Composable
fun CamIc(name: String, size: Dp = 18.dp, tint: Color = muse.t.ink, modifier: Modifier = Modifier) =
    Icon(CamIcons.get(name), null, modifier.size(size), tint = tint)

// ---------------------------------------------------------------- small pieces

/** The design's `.box`: surface, 1 px line (2.5 ink in Creator Pop). */
@Composable
fun Modifier.camBox(bg: Color = muse.t.surface): Modifier {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else m.t.r * .8f)
    return clip(shape).background(bg).border(if (m.isD) 2.dp else 1.dp, if (m.isD) Ink else m.t.line, shape)
}

@Composable
fun dotColor(d: Dot): Color = when (d) { Dot.GOOD -> muse.t.good; Dot.WARN -> Color(0xFFE08A1E); Dot.OFF -> muse.t.muted.copy(alpha = .6f) }

@Composable
fun StatusLine(row: StatusRow, modifier: Modifier = Modifier) {
    val m = muse
    Row(modifier.fillMaxWidth().height(26.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dotColor(row.dot)))
        T(row.title, m.type.body.copy(fontSize = 13.5.sp), m.t.ink, weight = FontWeight.SemiBold, maxLines = 1)
        T(row.text, m.type.tiny.copy(fontSize = 12.5.sp), m.t.muted, Modifier.weight(1f), align = TextAlign.End, maxLines = 1)
    }
}

/** `● LIVE` / `OFFLINE`. */
@Composable
fun LivePill(live: Boolean) = Pill(if (live) "● Live" else "Offline", if (live) "good" else "")

/** The session id chip (ink on bg), e.g. `cs_7Q2M`. */
@Composable
fun IdChip(id: String, modifier: Modifier = Modifier) {
    val m = muse
    Box(modifier.clip(RoundedCornerShape(if (m.isA) 2.dp else 6.dp)).background(m.t.ink).padding(horizontal = 8.dp, vertical = 4.dp)) {
        T(SessionText.idChip(id), m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .06.sp), m.t.bg, maxLines = 1)
    }
}

/** A guide thumbnail: the asset's image when it has a URL, else a drawn greybox / depth / pose frame. */
@Composable
fun GuideThumb(kind: String, asset: CameraAsset?, modifier: Modifier = Modifier, frame: Int = 0) {
    val url = asset?.url?.takeIf { asset.contentType.startsWith("image/") }
    Box(modifier.clip(RoundedCornerShape(2.dp))) {
        if (url != null) AsyncImage(url, null, Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        else Canvas(Modifier.fillMaxSize()) { drawGreybox(kind, frame) }
    }
}

private fun DrawScope.drawGreybox(kind: String, frame: Int) {
    val w = size.width; val h = size.height
    val (bg, fig) = when (kind) {
        "depth" -> Brush.verticalGradient(listOf(Color(0xFF050505), Color(0xFF3A3A3A))) to Color(0xFFEDEDED)
        "pose", "tracks" -> SolidColor(Color(0xFF060606)) to Color.Transparent
        else -> Brush.verticalGradient(listOf(Color(0xFFD9D9D6), Color(0xFF9C9B98))) to Color(0xFF5A5957)
    }
    drawRect(bg)
    if (kind != "depth" && kind != "pose" && kind != "tracks") drawRect(Color(0xFFB9B8B4), Offset(0f, h * .72f), Size(w, h * .28f))
    // Two figures: the lead (nearer, larger) and the second.
    val people = listOf(Triple(.36f + frame * .08f, .78f, .34f), Triple(.72f, .74f, .22f))
    people.forEachIndexed { i, (cx, base, hh) ->
        val x = w * cx; val y = h * base; val ph = h * hh
        if (kind == "pose" || kind == "tracks") {
            val cs = listOf(Color(0xFFFF3B30), Color(0xFFFFCC00), Color(0xFF34C759), Color(0xFF0A84FF), Color(0xFFFF2D92))
            val sw = (w * .025f).coerceAtLeast(1.2f)
            drawCircle(cs[i], ph * .09f, Offset(x, y - ph * .92f), style = Stroke(sw))
            drawLine(cs[1], Offset(x, y - ph * .82f), Offset(x, y - ph * .45f), sw)
            drawLine(cs[2], Offset(x, y - ph * .75f), Offset(x - ph * .2f, y - ph * .5f), sw)
            drawLine(cs[3], Offset(x, y - ph * .75f), Offset(x + ph * .2f, y - ph * .5f), sw)
            drawLine(cs[4], Offset(x, y - ph * .45f), Offset(x - ph * .14f, y), sw)
            drawLine(cs[0], Offset(x, y - ph * .45f), Offset(x + ph * .14f, y), sw)
        } else {
            val c = if (kind == "depth") fig.copy(alpha = if (i == 0) 1f else .55f) else fig.copy(alpha = if (i == 0) .9f else .6f)
            drawCircle(c, ph * .1f, Offset(x, y - ph * .9f))
            drawRoundRect(c, Offset(x - ph * .13f, y - ph * .78f), Size(ph * .26f, ph * .42f), androidx.compose.ui.geometry.CornerRadius(ph * .06f))
            drawRect(c, Offset(x - ph * .1f, y - ph * .38f), Size(ph * .08f, ph * .38f))
            drawRect(c, Offset(x + ph * .02f, y - ph * .38f), Size(ph * .08f, ph * .38f))
        }
    }
}

// ---------------------------------------------------------------- the plan

/** One line style per cast member: accent, ink, good, warn. */
@Composable
fun castColors(): List<Color> = listOf(muse.t.accent, muse.t.ink, muse.t.good, muse.t.warn)

private sealed interface Grab {
    data class Char(val modelId: String) : Grab
    data object Cam : Grab
}

/**
 * The top-down plan (or the side view, X/Z): grid, scale bar, each character's dashed path with time ticks and a token at
 * the playhead, the dotted camera path with its glyph, view cone and label. [onDragCharacter]/[onDragCamera] make it editable.
 */
@Composable
fun PlanView(
    session: CameraSession, playhead: Double, modifier: Modifier = Modifier, side: Boolean = false, compact: Boolean = false,
    onDragCharacter: ((String, P2) -> Unit)? = null, onDragCamera: ((P2) -> Unit)? = null,
) {
    val m = muse
    val measurer = rememberTextMeasurer()
    val colors = castColors()
    val tracks = session.blocking?.characters.orEmpty()
    val names = session.characters.associate { it.modelId to it.name }
    val heights = session.characters.associate { it.modelId to (it.heightM ?: 1.68) }
    val b = Plan.bounds(session.cameraPath, tracks, side)
    if (b == null) {
        Box(modifier.background(m.t.surface).padding(16.dp), contentAlignment = Alignment.Center) {
            T("No blocking yet · ask Claude in the chat, or block it in Blender from your Claude app.", m.type.tiny, m.t.muted, align = TextAlign.Center)
        }
        return
    }
    val small = TextStyle(fontFamily = m.t.mono, fontSize = if (compact) 8.sp else 10.sp, color = m.t.muted)
    BoxWithConstraints(modifier.background(m.t.surface)) {
        val wPx = constraints.maxWidth.toFloat(); val hPx = constraints.maxHeight.toFloat()
        val fit = PlanFit(b, wPx, hPx)
        fun pt(v: List<Double>, char: String? = null): Offset {
            val y = if (!side) v.getOrElse(1) { 0.0 } else if (char != null) (heights[char] ?: 1.68) * .93 else v.getOrElse(2) { 0.0 }
            return Offset(fit.x(v[0]), fit.y(y))
        }
        val editable = !side && (onDragCharacter != null || onDragCamera != null)
        val gestures = if (!editable) Modifier else Modifier.pointerInput(session.id, playhead, b) {
            var grab: Grab? = null
            detectDragGestures(
                onDragStart = { at ->
                    val hit = 28.dp.toPx()
                    val chars = tracks.mapNotNull { tr -> Plan.characterAt(tr.keyframes, playhead)?.let { tr.modelId to pt(it.position) } }
                    val cam = session.cameraPath?.keyframes?.let { Plan.cameraAt(it, playhead) }?.let { pt(it.position) }
                    val best = chars.minByOrNull { (it.second - at).getDistance() }
                    grab = when {
                        best != null && (best.second - at).getDistance() < hit -> Grab.Char(best.first)
                        cam != null && (cam - at).getDistance() < hit -> Grab.Cam
                        else -> null
                    }
                },
                onDrag = { change, _ ->
                    val g = grab ?: return@detectDragGestures
                    change.consume()
                    val p = fit.toMetres(change.position.x, change.position.y)
                    when (g) { is Grab.Char -> onDragCharacter?.invoke(g.modelId, p); Grab.Cam -> onDragCamera?.invoke(p) }
                },
                onDragEnd = { grab = null },
            )
        }
        Canvas(Modifier.fillMaxSize().then(gestures)) {
            // Grid every 0.5 m, a heavier line every metre.
            val (gx, gy) = Plan.gridLines(b)
            val grid = m.t.muted
            gx.forEach { x -> drawLine(grid.copy(alpha = if (abs(x % 1.0) < 1e-6) .22f else .1f), Offset(fit.x(x), 0f), Offset(fit.x(x), size.height), 1f) }
            gy.forEach { y -> drawLine(grid.copy(alpha = if (abs(y % 1.0) < 1e-6) .22f else .1f), Offset(0f, fit.y(y)), Offset(size.width, fit.y(y)), 1f) }
            if (side) drawLine(m.t.ink.copy(alpha = .5f), Offset(0f, fit.y(0.0)), Offset(size.width, fit.y(0.0)), 1.5.dp.toPx())

            // Camera path (dotted), view cone, glyph, label.
            val ck = session.cameraPath?.keyframes.orEmpty()
            val cam = Plan.cameraAt(ck, playhead)
            if (cam != null && !side) {
                val (c, e1, e2) = Plan.viewCone(cam, session.cameraPath?.sensorMm ?: Plan.SENSOR_MM)
                val cone = Path().apply { moveTo(fit.x(c.x), fit.y(c.y)); lineTo(fit.x(e1.x), fit.y(e1.y)); lineTo(fit.x(e2.x), fit.y(e2.y)); close() }
                drawPath(cone, m.t.accent.copy(alpha = .13f))
                drawPath(cone, m.t.accent.copy(alpha = .35f), style = Stroke(1f))
            }
            if (ck.size > 1) {
                val path = Path().apply { ck.forEachIndexed { i, k -> val o = pt(k.position); if (i == 0) moveTo(o.x, o.y) else lineTo(o.x, o.y) } }
                drawPath(path, m.t.ink.copy(alpha = .75f), style = Stroke(1.4.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 4.dp.toPx()), 0f), cap = StrokeCap.Round))
            }
            if (cam != null) {
                val o = pt(cam.position)
                if (side) cam.target?.let { tgt -> drawLine(m.t.accent.copy(alpha = .5f), o, pt(tgt), 1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 4f))) }
                val ang = cam.target?.let { t -> val to = pt(t); Math.toDegrees(atan2((to.y - o.y).toDouble(), (to.x - o.x).toDouble())).toFloat() } ?: -90f
                camGlyph(o, ang, m.t.ink, if (compact) 9.dp.toPx() else 11.dp.toPx())
                if (!compact || !side) label(measurer, Plan.camLabel(cam), Offset(o.x + 14.dp.toPx(), o.y + 8.dp.toPx()), small.copy(color = m.t.ink), m.t.surface, m.t.line)
            }

            // Characters: dashed path, keyframe ticks, token at the playhead, facing arrow, active action.
            tracks.forEachIndexed { i, tr ->
                val col = colors[i % colors.size]
                val ks = tr.keyframes
                if (ks.size > 1) {
                    val path = Path().apply { ks.forEachIndexed { j, k -> val o = pt(k.position, tr.modelId); if (j == 0) moveTo(o.x, o.y) else lineTo(o.x, o.y) } }
                    drawPath(path, col, style = Stroke(1.6.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx())), cap = StrokeCap.Round))
                }
                val showTicks = !compact && !side
                val token = Plan.characterAt(ks, playhead)?.let { pt(it.position, tr.modelId) }
                ks.forEachIndexed { j, k ->
                    val o = pt(k.position, tr.modelId)
                    drawCircle(col, 2.5.dp.toPx(), o)
                    val dup = j > 0 && hypot((pt(ks[j - 1].position) - o).x.toDouble(), (pt(ks[j - 1].position) - o).y.toDouble()) < 6.0
                    val underToken = token != null && (token - o).getDistance() < 20.dp.toPx()
                    if (showTicks && !dup && !underToken) label(measurer, Plan.tick(k.t), Offset(o.x - 8.dp.toPx(), o.y - 16.dp.toPx()), small.copy(color = col), null, null)
                }
                val at = Plan.characterAt(ks, playhead) ?: return@forEachIndexed
                val o = pt(at.position, tr.modelId)
                val r = if (compact) 9.dp.toPx() else 12.dp.toPx()
                if (!side) {
                    val f = Plan.facing(at.facingDeg ?: 0.0)
                    val tip = Offset(o.x + (f.x * (r + 7.dp.toPx())).toFloat(), o.y - (f.y * (r + 7.dp.toPx())).toFloat())
                    val ang = Math.toDegrees(atan2((tip.y - o.y).toDouble(), (tip.x - o.x).toDouble())).toFloat()
                    rotate(ang, tip) {
                        val a = 4.dp.toPx()
                        drawPath(Path().apply { moveTo(tip.x + a, tip.y); lineTo(tip.x - a, tip.y - a); lineTo(tip.x - a, tip.y + a); close() }, col)
                    }
                } else drawLine(col, Offset(o.x, fit.y(0.0)), o, 2.dp.toPx())
                drawCircle(col, r, o)
                val ini = Plan.initials(names[tr.modelId] ?: "?")
                val tl = measurer.measure(ini, TextStyle(fontFamily = m.t.body, fontSize = if (compact) 7.sp else 9.sp, fontWeight = FontWeight.Bold, color = if (col == m.t.ink) m.t.bg else Color.White))
                drawText(tl, topLeft = Offset(o.x - tl.size.width / 2f, o.y - tl.size.height / 2f))
                val action = at.action
                if (!side && action != null && !compact) label(measurer, action.substringBefore(" · "), Offset(o.x - r, o.y + r + 6.dp.toPx()), small.copy(color = col), null, null)
            }

            // 1 m scale bar, bottom right.
            val bar = fit.len(1.0)
            val bx = size.width - bar - 10.dp.toPx(); val by = size.height - 12.dp.toPx()
            drawLine(m.t.ink.copy(alpha = .7f), Offset(bx, by), Offset(bx + bar, by), 1.2f)
            drawLine(m.t.ink.copy(alpha = .7f), Offset(bx, by - 4), Offset(bx, by + 4), 1.2f)
            drawLine(m.t.ink.copy(alpha = .7f), Offset(bx + bar, by - 4), Offset(bx + bar, by + 4), 1.2f)
            label(measurer, "1 m", Offset(bx + bar / 2 - 8.dp.toPx(), by - 15.dp.toPx()), small, null, null)
        }
    }
}

private fun DrawScope.label(measurer: TextMeasurer, text: String, at: Offset, style: TextStyle, bg: Color?, border: Color?) {
    val l = measurer.measure(text, style, maxLines = 1)
    val x = at.x.coerceIn(2f, (size.width - l.size.width - 2f).coerceAtLeast(2f))
    val y = at.y.coerceIn(2f, (size.height - l.size.height - 2f).coerceAtLeast(2f))
    if (bg != null) {
        drawRect(bg, Offset(x - 4, y - 2), Size(l.size.width + 8f, l.size.height + 4f))
        if (border != null) drawRect(border, Offset(x - 4, y - 2), Size(l.size.width + 8f, l.size.height + 4f), style = Stroke(1f))
    }
    drawText(l, topLeft = Offset(x, y))
}

/** A small film camera pointing at [deg] (screen degrees). */
private fun DrawScope.camGlyph(o: Offset, deg: Float, color: Color, s: Float) {
    rotate(deg, o) {
        drawRect(color, Offset(o.x - s, o.y - s * .6f), Size(s * 1.3f, s * 1.2f))
        drawPath(Path().apply { moveTo(o.x + s * .3f, o.y); lineTo(o.x + s, o.y - s * .55f); lineTo(o.x + s, o.y + s * .55f); close() }, color)
        drawCircle(color, s * .32f, Offset(o.x - s * .65f, o.y - s * .85f), style = Stroke(1.5f))
        drawCircle(color, s * .32f, Offset(o.x - s * .05f, o.y - s * .85f), style = Stroke(1.5f))
    }
}

// ---------------------------------------------------------------- the timeline

/** Ruler, CAMERA / one track per character / CUTS, keyframe diamonds, spans with labels, playhead (drag to scrub), END chip. */
@Composable
fun TimelineView(session: CameraSession, playhead: Double, onScrub: (Double) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val measurer = rememberTextMeasurer()
    val dur = session.durationSec.coerceAtLeast(0.1)
    val lanes = buildList {
        add("CAMERA" to Timeline.cameraSpans(session.cameraPath).map { Triple(it, it.label.startsWith("orbit"), true) } to session.cameraPath?.keyframes.orEmpty().map { it.t })
        session.blocking?.characters.orEmpty().forEach { tr ->
            val name = session.characters.firstOrNull { it.modelId == tr.modelId }?.name ?: "?"
            add(name.uppercase() to Timeline.characterSpans(tr.keyframes, dur).map { Triple(it, false, true) } to tr.keyframes.filter { !it.action.isNullOrBlank() }.map { it.t })
        }
        add("CUTS" to emptyList<Triple<Span, Boolean, Boolean>>() to session.cameraPath?.cuts.orEmpty())
    }
    val laneH = 36.dp
    val labelW = 110.dp
    Box(modifier.fillMaxWidth().height(26.dp + laneH * lanes.size + 8.dp).background(m.t.surface)) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val trackStart = with(androidx.compose.ui.platform.LocalDensity.current) { labelW.toPx() }
            val trackW = constraints.maxWidth - trackStart - with(androidx.compose.ui.platform.LocalDensity.current) { 24.dp.toPx() }
            fun xOf(t: Double) = trackStart + (t / dur * trackW).toFloat()
            fun tOf(x: Float) = ((x - trackStart) / trackW * dur).coerceIn(0.0, dur)
            Canvas(Modifier.fillMaxSize()
                .pointerInput(dur, trackW) { detectTapGestures { onScrub(tOf(it.x)) } }
                .pointerInput(dur, trackW) { detectDragGestures { change, _ -> change.consume(); onScrub(tOf(change.position.x)) } }) {
                val mono = TextStyle(fontFamily = m.t.mono, fontSize = 10.5.sp, color = m.t.muted)
                // Ruler
                Plan.ruler(dur).forEach { (t, l) ->
                    val x = xOf(t)
                    drawLine(m.t.line, Offset(x, 0f), Offset(x, 22.dp.toPx()), 1f)
                    drawText(measurer.measure(l, mono), topLeft = Offset(x + 4.dp.toPx(), 4.dp.toPx()))
                }
                drawLine(m.t.line, Offset(0f, 26.dp.toPx()), Offset(size.width, 26.dp.toPx()), 1f)
                lanes.forEachIndexed { i, (head, keys) ->
                    val (name, spans) = head
                    val top = 26.dp.toPx() + laneH.toPx() * i
                    drawText(measurer.measure(name, mono.copy(color = m.t.ink, fontWeight = FontWeight.Medium, letterSpacing = 1.sp), maxLines = 1, constraints = androidx.compose.ui.unit.Constraints(maxWidth = (trackStart - 20.dp.toPx()).toInt().coerceAtLeast(1))),
                        topLeft = Offset(14.dp.toPx(), top + laneH.toPx() / 2 - 7.dp.toPx()))
                    spans.forEach { (sp, red, _) ->
                        val x0 = xOf(sp.start); val x1 = xOf(sp.end)
                        val bg = if (red) m.t.accent.copy(alpha = .16f) else m.t.surface2
                        drawRect(bg, Offset(x0, top + 7.dp.toPx()), Size((x1 - x0).coerceAtLeast(1f), 22.dp.toPx()))
                        val maxW = (x1 - x0 - 16.dp.toPx()).toInt()
                        if (maxW > 8) drawText(measurer.measure(sp.label, mono.copy(color = if (red) m.t.accent else m.t.ink), maxLines = 1,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, constraints = androidx.compose.ui.unit.Constraints(maxWidth = maxW)),
                            topLeft = Offset(x0 + 10.dp.toPx(), top + 11.dp.toPx()))
                    }
                    keys.forEach { t ->
                        val c = Offset(xOf(t), top + 18.dp.toPx())
                        val d = 5.dp.toPx()
                        drawPath(Path().apply { moveTo(c.x, c.y - d); lineTo(c.x + d, c.y); lineTo(c.x, c.y + d); lineTo(c.x - d, c.y); close() }, if (name == "CUTS") m.t.ink else m.t.accent)
                    }
                    drawLine(m.t.line, Offset(trackStart, top + laneH.toPx() - 1), Offset(size.width, top + laneH.toPx() - 1), 1f)
                }
                // END chip
                val end = measurer.measure("END ${SessionText.seconds(dur)}".uppercase(), mono.copy(color = m.t.muted))
                val lastTop = 26.dp.toPx() + laneH.toPx() * (lanes.size - 1)
                val ex = xOf(dur) - end.size.width - 14.dp.toPx()
                drawRect(m.t.line, Offset(ex - 6, lastTop + 8.dp.toPx()), Size(end.size.width + 12f, end.size.height + 6f), style = Stroke(1f))
                drawText(end, topLeft = Offset(ex, lastTop + 8.dp.toPx() + 3))
                // Playhead + time chip
                val px = xOf(playhead)
                drawLine(m.t.accent, Offset(px, 0f), Offset(px, size.height), 2.dp.toPx())
                val chip = measurer.measure(Plan.chip(playhead).uppercase(), mono.copy(color = m.t.accent))
                val cx = (px + 6.dp.toPx()).coerceAtMost(size.width - chip.size.width - 12f)
                val cy = size.height - chip.size.height - 10.dp.toPx()
                drawRect(m.t.surface, Offset(cx - 6, cy - 3), Size(chip.size.width + 12f, chip.size.height + 6f))
                drawRect(m.t.accent, Offset(cx - 6, cy - 3), Size(chip.size.width + 12f, chip.size.height + 6f), style = Stroke(1f))
                drawText(chip, topLeft = Offset(cx, cy))
            }
        }
    }
}

/** The legend under the plan: one line style per character, then the camera. */
@Composable
fun PlanLegend(session: CameraSession, modifier: Modifier = Modifier, note: Boolean = true) {
    val m = muse
    val colors = castColors()
    androidx.compose.foundation.layout.FlowRow(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        session.characters.forEachIndexed { i, c ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.width(14.dp).height(3.dp).background(colors[i % colors.size]))
                T(if (i == 0) "${c.name}’s path" else c.name, m.type.tiny, m.t.muted, maxLines = 1)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            CamIc("cam", 16.dp, m.t.ink); T("Camera path & view", m.type.tiny, m.t.muted, maxLines = 1)
        }
        if (note) T("Drag a token or the camera to adjust · Claude sees your edits", m.type.tiny, m.t.muted)
    }
}

/** The Camera view: the newest preview / keyframe still nearest the playhead. */
@Composable
fun CameraStill(session: CameraSession, playhead: Double, modifier: Modifier = Modifier) {
    val m = muse
    val dur = session.durationSec
    val stills = session.assets.filter { it.ready && (it.kind.startsWith("keyframe_") || it.kind == "preview" || it.kind == "still") }
    fun at(a: CameraAsset) = when (a.kind) { "keyframe_start" -> 0.0; "keyframe_mid" -> dur / 2; "keyframe_end" -> dur; else -> playhead }
    val best = stills.sortedByDescending { it.createdAt }.minByOrNull { abs(at(it) - playhead) }
    Box(modifier.background(m.t.surface), contentAlignment = Alignment.Center) {
        if (best == null) T("No stills yet · they arrive with the guides", m.type.tiny, m.t.muted)
        else Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            GuideThumb("greybox", best, Modifier.height(220.dp).width(124.dp), frame = (at(best) / dur.coerceAtLeast(.1) * 2).roundToInt())
            T("${SessionText.assetLabel(best.kind)} · ${Plan.chip(at(best))}", m.type.mono.copy(fontSize = 11.sp), m.t.muted)
        }
    }
}

/** A tool chip: cube + BUILD_STAGE ×2, red outline when it failed. */
@Composable
fun ToolChipView(c: ToolChip) {
    val m = muse
    val col = if (c.ok) m.t.muted else m.t.accent
    Row(Modifier.height(22.dp).border(1.dp, if (c.ok) m.t.line else m.t.accent, RoundedCornerShape(if (m.isA) 2.dp else 999.dp)).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        CamIc("cube", 11.dp, col)
        T(c.label, m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = .8.sp), col, maxLines = 1)
    }
}

/** The send button (ink square). */
@Composable
fun SendButton(enabled: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(44.dp).clip(RoundedCornerShape(if (m.isA) 2.dp else 999.dp)).background(if (enabled) m.t.cta else m.t.line).press(enabled, onClick),
        contentAlignment = Alignment.Center) { CamIc("send", 18.dp, if (enabled) m.t.ctaInk else m.t.muted) }
}

@Composable
fun Gap(h: Dp) = Spacer(Modifier.height(h))
