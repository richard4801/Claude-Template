package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.theme.muse
import studio.muse.core.edit.CurveChannel
import studio.muse.core.edit.CurvePoint
import studio.muse.core.edit.LookLimits
import studio.muse.core.edit.curveFn
import kotlin.math.abs
import kotlin.math.hypot

/** The straight line: no curve. */
private val LINE = listOf(CurvePoint(0.0, 0.0), CurvePoint(1.0, 1.0))

/**
 * Tone curves (plans/edit-parity.md, M "Curves"): the look's master and per-channel curves on a square. Drag a point
 * to move it; touch the line elsewhere to add one (up to 16); tap an inner point without moving to remove it. Ends
 * move up and down only. Every move is shown live and kept as one undo step when the finger lifts.
 */
@Composable
fun CurvesEditor(curves: Map<CurveChannel, List<CurvePoint>>?, enabled: Boolean, act: (EditAction) -> Unit) {
    val m = muse
    var channel by remember { mutableStateOf(CurveChannel.RGB) }
    val pts = curves?.get(channel) ?: LINE
    val ptsNow by rememberUpdatedState(pts)
    val chNow by rememberUpdatedState(channel)
    val actNow by rememberUpdatedState(act)
    val stroke = when (channel) { CurveChannel.RGB -> m.t.ink; CurveChannel.R -> Color(0xFFE5484D); CurveChannel.G -> Color(0xFF30A46C); CurveChannel.B -> Color(0xFF3E63DD) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SuiteLabel("Curves", Modifier.weight(1f))
            if (!curves.isNullOrEmpty()) SuiteLink("Reset curves") { CurveChannel.entries.forEach { c -> if (curves.containsKey(c)) actNow(EditAction.SetCurve(c, null)) } }
        }
        SuiteSeg(listOf("rgb" to "All", "r" to "Red", "g" to "Green", "b" to "Blue"), channel.wire, { w -> channel = CurveChannel.entries.first { it.wire == w } }, Modifier.fillMaxWidth(), fill = true)
        Canvas(
            Modifier.fillMaxWidth().widthIn(max = 360.dp).aspectRatio(1f).background(m.t.surface)
                .semantics { contentDescription = "Tone curve, ${channel.wire.uppercase()}" }
                .pointerInput(enabled) {
                    if (!enabled) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        val pad = 8 * density
                        val sz = size.width.toFloat() - 2 * pad
                        fun toPt(o: Offset) = CurvePoint(((o.x - pad) / sz).toDouble().coerceIn(0.0, 1.0), (1 - (o.y - pad) / sz).toDouble().coerceIn(0.0, 1.0))
                        val start = ptsNow
                        val reach = 24 * density
                        fun dist(i: Int) = hypot(pad + start[i].x * sz - down.position.x, pad + (1 - start[i].y) * sz - down.position.y)
                        var idx = start.indices.minByOrNull(::dist)?.takeIf { dist(it) <= reach } ?: -1
                        var work = start
                        val added = idx < 0
                        if (added) {
                            if (start.size >= LookLimits.MAX_CURVE_POINTS) return@awaitEachGesture
                            val x = toPt(down.position).x
                            if (start.any { abs(it.x - x) < 0.03 }) return@awaitEachGesture
                            val y = curveFn(start)?.invoke(x) ?: x
                            work = (start + CurvePoint(x, y)).sortedBy { it.x }
                            idx = work.indexOfFirst { it.x == x }
                            actNow(EditAction.SetCurve(chNow, work, done = false))
                        }
                        var moved = false
                        while (true) {
                            val ev = awaitPointerEvent()
                            val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                            if (!ch.pressed) break
                            if (!moved && (ch.position - down.position).getDistance() < viewConfiguration.touchSlop) continue
                            moved = true
                            ch.consume()
                            val p = toPt(ch.position)
                            // Ends move vertically; inner points stay between their neighbours.
                            val x = when (idx) { 0 -> work[0].x; work.lastIndex -> work.last().x; else -> p.x.coerceIn(work[idx - 1].x + 0.02, work[idx + 1].x - 0.02) }
                            work = work.toMutableList().also { it[idx] = CurvePoint(x, p.y) }
                            actNow(EditAction.SetCurve(chNow, work, done = false))
                        }
                        when {
                            moved || added -> actNow(EditAction.SetCurve(chNow, work, done = true))
                            idx in 1 until start.lastIndex -> actNow(EditAction.SetCurve(chNow, start.filterIndexed { i, _ -> i != idx }))
                        }
                    }
                },
        ) {
            val pad = 8.dp.toPx()
            val s = size.width - 2 * pad
            val line = m.t.line; val bg = m.t.bg
            translate(pad, pad) { plot(s, pts, stroke, line, bg, enabled) }
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.plot(s: Float, pts: List<CurvePoint>, stroke: Color, line: Color, bg: Color, enabled: Boolean) {
            for (k in 1..3) {
                val g = s * k / 4
                drawLine(line, Offset(g, 0f), Offset(g, s)); drawLine(line, Offset(0f, g), Offset(s, g))
            }
            drawLine(line, Offset(0f, s), Offset(s, 0f))
            val f = curveFn(pts) ?: { x: Double -> x }
            val path = Path()
            for (i in 0..64) { val x = i / 64.0; val px = (x * s).toFloat(); val py = ((1 - f(x).coerceIn(0.0, 1.0)) * s).toFloat(); if (i == 0) path.moveTo(px, py) else path.lineTo(px, py) }
            drawPath(path, stroke, style = Stroke(2.dp.toPx()))
            for (p in pts) {
                val c = Offset((p.x * s).toFloat(), ((1 - p.y) * s).toFloat())
                drawCircle(bg, 6.dp.toPx(), c); drawCircle(stroke, 6.dp.toPx(), c, style = Stroke(2.dp.toPx()))
            }
            if (!enabled) drawRect(bg.copy(alpha = .5f), Offset.Zero, Size(s, s))
}
