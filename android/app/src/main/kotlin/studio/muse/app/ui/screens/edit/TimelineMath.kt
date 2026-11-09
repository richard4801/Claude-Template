package studio.muse.app.ui.screens.edit

import kotlin.math.roundToLong

/**
 * Geometry of the Edit timeline (phone-first, owner report 2026-11-08): the playhead is fixed in the centre and the
 * tracks scroll under it. Pure, so the scrub, zoom and hit maths are unit-tested; the composable only draws and
 * forwards gestures. Times are timeline seconds; [ppsPx] is pixels per second at the current zoom.
 */
object TimelineMath {
    /** Zoom range in dp per second: a whole 10-minute edit fits at the low end, single frames at 60 fps are 8 dp at the top. */
    const val MIN_PPS = 8f
    const val MAX_PPS = 480f

    fun clampPps(dpPerSec: Float): Float = dpPerSec.coerceIn(MIN_PPS, MAX_PPS)

    /** x (px) of timeline second [t] on a [width]-px canvas with the playhead (at [view]) in the centre. */
    fun xOf(t: Double, view: Double, width: Float, ppsPx: Float): Float = width / 2f + ((t - view) * ppsPx).toFloat()

    /** The timeline second under x (px). */
    fun timeAt(x: Float, view: Double, width: Float, ppsPx: Float): Double = view + (x - width / 2f) / ppsPx

    /** The playhead after the finger moved [dx] px (the content follows the finger: dragging left goes later). */
    fun dragged(view: Double, dx: Float, ppsPx: Float, duration: Double): Double = (view - dx / ppsPx).coerceIn(0.0, duration.coerceAtLeast(0.0))

    /** [t] on the nearest frame of a [fps] timeline (scrubbing ends there, so a split lands on a real frame). */
    fun snapFrame(t: Double, fps: Double): Double = if (fps <= 0) t else (t * fps).roundToLong() / fps

    /** Seconds between ruler ticks at a zoom (labels every second tick). */
    fun rulerStep(dpPerSec: Float): Double = when {
        dpPerSec < 14 -> 5.0
        dpPerSec < 24 -> 2.0
        dpPerSec < 70 -> 1.0
        dpPerSec < 160 -> 0.5
        else -> 0.25
    }

    /** "0:02" / "0:02.5" for a ruler label. */
    fun rulerLabel(t: Double): String {
        val whole = kotlin.math.floor(t + 1e-6)
        val s = whole.toInt()
        val base = "${s / 60}:" + (s % 60).toString().padStart(2, '0')
        val frac = t - whole
        return if (frac < 1e-3) base else base + "." + ((frac * 100).toInt().toString().padStart(2, '0').trimEnd('0'))
    }

    /**
     * Trimming a main clip by dragging its edge [dxPx]: the new source in/out (constant speed: timeline seconds × speed;
     * a speed curve uses its average). [left] = the start handle. Clamped to the asset and to 0.1 s of source.
     */
    fun trimmed(inSec: Double, outSec: Double, speed: Double, assetDur: Double, left: Boolean, dxPx: Float, ppsPx: Float): Pair<Double, Double> {
        val dSrc = dxPx / ppsPx * speed
        val min = studio.muse.core.edit.EditLimits.MIN_CLIP_SOURCE_SEC
        return if (left) (inSec + dSrc).coerceIn(0.0, outSec - min).let { r3(it) to outSec }
        else inSec to r3((outSec + dSrc).coerceIn(inSec + min, assetDur))
    }

    private fun r3(v: Double) = Math.round(v * 1000) / 1000.0
}
