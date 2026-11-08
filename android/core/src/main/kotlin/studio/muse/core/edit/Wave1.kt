package studio.muse.core.edit

import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * Wave 1 of the Edit parity work (plans/edit-parity.md): freeze frames, mirror, blend modes and the blur fill. Ports of
 * server/api/src/editor/model.ts (blendChannel, blendPixel, itemCorners, blurFillRadius, blurFill, blurFillClip), checked
 * against functions.json → wave1.
 */

/** A freeze frame lasts 0.1–30 s. */
const val HOLD_MIN_SEC = 0.1
const val HOLD_MAX_SEC = 30.0
/** The blur fill's darkening of RGB. */
const val BLUR_FILL_DARKEN = 0.85

private fun r6w(v: Double) = Math.round(v * 1e6) / 1e6

/** One channel of the W3C compositing blend functions: [top] = the item (Cs), [below] = the backdrop (Cb), both 0–1. */
fun blendChannel(mode: BlendMode, top: Double, below: Double): Double {
    val s = top; val b = below
    return when (mode) {
        BlendMode.NORMAL -> s
        BlendMode.MULTIPLY -> b * s
        BlendMode.SCREEN -> b + s - b * s
        BlendMode.OVERLAY -> if (b <= 0.5) 2 * b * s else 1 - 2 * (1 - b) * (1 - s)
        BlendMode.SOFT_LIGHT -> if (s <= 0.5) b - (1 - 2 * s) * b * (1 - b) else {
            val d = if (b <= 0.25) ((16 * b - 12) * b + 4) * b else sqrt(b)
            b + (2 * s - 1) * (d - b)
        }
        BlendMode.DARKEN -> min(b, s)
        BlendMode.LIGHTEN -> max(b, s)
        BlendMode.ADD -> min(1.0, b + s)
    }
}

/** A blended pixel: below + (blend − below) × [a] (the item's alpha × opacity), on straight sRGB 0–1. */
fun blendPixel(mode: BlendMode, top: DoubleArray, below: DoubleArray, a: Double): DoubleArray =
    DoubleArray(3) { i -> r6w(below[i] + (blendChannel(mode, top[i], below[i]).coerceIn(0.0, 1.0) - below[i]) * a.coerceIn(0.0, 1.0)) }

/**
 * Where an item's picture corners land on the canvas (px): fitted ([fit]) to the canvas, mirrored about its centre, scaled,
 * rotated clockwise and moved. The picture's own top-left, top-right, bottom-right, bottom-left.
 */
fun itemCorners(canvasW: Int, canvasH: Int, w: Double, h: Double, fit: Fit, t: Transform = Transform()): List<Pair<Double, Double>> {
    val k = if (fit == Fit.COVER) max(canvasW / w, canvasH / h) else min(canvasW / w, canvasH / h)
    val sc = t.scale ?: 1.0
    val hw = w * k * sc / 2; val hh = h * k * sc / 2
    val fx = if (t.flipX == true) -1 else 1; val fy = if (t.flipY == true) -1 else 1
    val a = Math.toRadians(t.rotation ?: 0.0); val c = cos(a); val s = sin(a)
    val cx = (t.x ?: 0.5) * canvasW; val cy = (t.y ?: 0.5) * canvasH
    return listOf(-1 to -1, 1 to -1, 1 to 1, -1 to 1).map { (u, v) ->
        val px = u * hw * fx; val py = v * hh * fy
        r6w(cx + px * c - py * s) to r6w(cy + px * s + py * c)
    }
}

/** The blur fill's box-blur radius in pixels. */
fun blurFillRadius(width: Int, height: Int): Int = max(1, (0.04 * min(width, height)).roundToInt())

/** The blur fill of a cover-fitted frame ([rgb]: w × h × 3, 0–1): a separable box blur (clamp to edge), then × [BLUR_FILL_DARKEN]. */
fun blurFill(rgb: DoubleArray, w: Int, h: Int, radius: Int): DoubleArray {
    fun box(src: DoubleArray, horiz: Boolean): DoubleArray {
        val out = DoubleArray(src.size)
        for (y in 0 until h) for (x in 0 until w) for (ch in 0 until 3) {
            var sum = 0.0
            for (k in -radius..radius) {
                val xx = if (horiz) (x + k).coerceIn(0, w - 1) else x
                val yy = if (horiz) y else (y + k).coerceIn(0, h - 1)
                sum += src[(yy * w + xx) * 3 + ch]
            }
            out[(y * w + x) * 3 + ch] = sum / (2 * radius + 1)
        }
        return out
    }
    return box(box(rgb, true), false).map { r6w(it * BLUR_FILL_DARKEN) }.toDoubleArray()
}

/** Which main clip's frame the blur fill shows at timeline [t]: the incoming one from half-way through a transition. */
fun blurFillClip(p: EditProject, t: Double): Pair<String, Double>? {
    val spans = timeline(p)
    for (i in spans.indices) {
        val s = spans[i]
        if (t < s.startSec - 1e-9 || t > s.endSec + 1e-9) continue
        val next = spans.getOrNull(i + 1)
        val pick = if (next != null && t >= next.startSec && next.transitionSec > 0) (if ((t - next.startSec) / next.transitionSec >= 0.5) next else s) else s
        return pick.id to r6w(t - pick.startSec)
    }
    return null
}
