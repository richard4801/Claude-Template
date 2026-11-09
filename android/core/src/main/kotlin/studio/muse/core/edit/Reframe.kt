package studio.muse.core.edit

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Auto reframe (owner-approved 2026-11-09): a wide clip in a narrower canvas follows the speaker's face. Faces are
 * found on the device (ML Kit on Android, Vision on the Mac) a few times a second; this turns them into the clip's
 * x keyframes. It's pure, so the Mac can port it and tests can drive it.
 *
 * With cover fit the picture is [coverWidth] canvas-widths wide. To put a source point fx (0–1 across the source) at the
 * canvas centre, the clip's centre goes to x = 0.5 + (0.5 − fx)·coverWidth, clamped so the picture still covers the
 * canvas.
 */
object Reframe {
    /** One sample: clip-local time, and the faces found (centre x and width as fractions of the source frame). */
    data class Sample(val localSec: Double, val faces: List<Face>)
    data class Face(val cx: Double, val cy: Double, val w: Double, val h: Double)

    /** How wide the cover-fitted picture is, in canvas widths (≥ 1 when the source is wider than the canvas). */
    fun coverWidth(srcW: Int, srcH: Int, canvasW: Int, canvasH: Int, scale: Double = 1.0): Double {
        val src = srcW.toDouble() / srcH; val cv = canvasW.toDouble() / canvasH
        return max(src / cv, 1.0) * scale
    }

    /** The clip centre x that puts source point [fx] at the canvas centre, kept inside the cover range. */
    fun centreFor(fx: Double, coverWidth: Double): Double {
        val room = max(0.0, (coverWidth - 1) / 2)
        return (0.5 + (0.5 - fx) * coverWidth).coerceIn(0.5 - room, 0.5 + room)
    }

    /**
     * The face to follow in each sample: the largest at the start, then the one nearest to the last followed face
     * (so it doesn't jump between two people of similar size); null where there's none (it holds).
     */
    fun track(samples: List<Sample>): List<Double?> {
        var last: Double? = null
        return samples.map { s ->
            val f = if (s.faces.isEmpty()) null
                else if (last == null) s.faces.maxBy { it.w * it.h }
                else s.faces.minBy { abs(it.cx - last!!) + 0.5 * (1 - it.w) }
            f?.cx?.also { last = it }
        }
    }

    /**
     * The x keyframes (clip-local seconds) that follow the face over [samples]: missing samples hold the last
     * position (the centre before the first face); the path is smoothed (exponential, [smoothing] 0–1) and kept still
     * inside a dead zone ([deadZone] of the canvas width) so small head moves don't pan; then reduced to the fewest
     * keys within [tolerance] (at most [maxKeys]). Empty when no face is ever seen or the picture can't move.
     */
    fun keyframes(
        samples: List<Sample>, coverWidth: Double, smoothing: Double = 0.6, deadZone: Double = 0.04, tolerance: Double = 0.01, maxKeys: Int = 40,
    ): List<Keyframe> {
        if (samples.isEmpty() || coverWidth <= 1.0 + 1e-6) return emptyList()
        val cx = track(samples)
        if (cx.all { it == null }) return emptyList()
        // Hold through gaps; before the first face, use the first one seen.
        val first = cx.first { it != null }!!
        var hold = first
        val raw = cx.map { v -> (v ?: hold).also { hold = it } }.map { centreFor(it, coverWidth) }
        // Smooth, then hold still inside the dead zone.
        val a = (1 - smoothing.coerceIn(0.0, 0.95))
        var s = raw.first(); var shown = s
        val path = raw.map { v ->
            s += a * (v - s)
            if (abs(s - shown) > deadZone) shown = s - deadZone * kotlin.math.sign(s - shown)
            shown
        }
        // Fewest keys that stay within tolerance (Ramer–Douglas–Peucker), then capped.
        var tol = tolerance
        var keep = rdp(samples.map { it.localSec }, path, tol)
        while (keep.size > maxKeys) { tol *= 1.5; keep = rdp(samples.map { it.localSec }, path, tol) }
        val keys = keep.map { i -> Keyframe(Math.round(samples[i].localSec * 1000) / 1000.0, Math.round(path[i] * 10000) / 10000.0, Ease.EASE_IN_OUT) }
        // One key = no movement: a single static position is better as the transform's x (the caller sets it).
        return if (keys.size < 2 || keys.all { abs(it.v - keys[0].v) < 1e-4 }) keys.take(1) else keys
    }

    private fun rdp(t: List<Double>, v: List<Double>, tol: Double): List<Int> {
        val keep = BooleanArray(t.size); keep[0] = true; keep[t.size - 1] = true
        fun walk(a: Int, b: Int) {
            if (b <= a + 1) return
            var worst = -1; var d = tol
            for (i in a + 1 until b) {
                val f = if (t[b] == t[a]) 0.0 else (t[i] - t[a]) / (t[b] - t[a])
                val e = abs(v[i] - (v[a] + f * (v[b] - v[a])))
                if (e > d) { d = e; worst = i }
            }
            if (worst >= 0) { keep[worst] = true; walk(a, worst); walk(worst, b) }
        }
        walk(0, t.size - 1)
        return keep.indices.filter { keep[it] }
    }

    /** Sample times (clip-local seconds) for a clip [lengthSec] long at [fps] (always the first and last moment). */
    fun sampleTimes(lengthSec: Double, fps: Double = 5.0): List<Double> {
        val n = max(1, (lengthSec * fps).toInt())
        return (0..n).map { min(lengthSec, it / fps) }.distinct()
    }
}
