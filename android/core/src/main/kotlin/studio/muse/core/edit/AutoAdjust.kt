package studio.muse.core.edit

import kotlin.math.ln
import kotlin.math.roundToInt

/*
 * Auto adjust (plans/edit-parity.md, M): one frame's levels → a gentle Adjust that the colour matrix applies
 * ([colorMatrix]: exposure → temperature → tint → contrast → saturation). Pure, so it's tested on the JVM; the app
 * passes the frame under the playhead, small (e.g. 96 px), as straight sRGB 0–1.
 */

/** The suggested exposure, contrast, saturation, temperature and tint for [rgb] (r, g, b, … 0–1); other fields untouched. */
fun autoAdjust(rgb: DoubleArray, base: Adjust? = null): Adjust {
    val n = rgb.size / 3
    if (n == 0) return base ?: Adjust()
    var r = 0.0; var g = 0.0; var b = 0.0; var chroma = 0.0
    val luma = DoubleArray(n)
    for (i in 0 until n) {
        val R = rgb[i * 3]; val G = rgb[i * 3 + 1]; val B = rgb[i * 3 + 2]
        r += R; g += G; b += B
        luma[i] = 0.2126 * R + 0.7152 * G + 0.0722 * B
        chroma += maxOf(R, G, B) - minOf(R, G, B)
    }
    r /= n; g /= n; b /= n; chroma /= n
    luma.sort()
    val mean = luma.average()
    val lo = luma[(n * 0.02).toInt().coerceIn(0, n - 1)]; val hi = luma[(n * 0.98).toInt().coerceIn(0, n - 1)]
    fun r2(v: Double) = (v * 100).roundToInt() / 100.0
    // Exposure: the mean towards 0.45 (2^e), at most ±0.6 stop.
    val e = if (mean > 1e-3) (ln(0.45 / mean) / ln(2.0)).coerceIn(-0.6, 0.6) else 0.6
    // Contrast: the 2–98 % spread towards 0.85.
    val spread = hi - lo
    val c = if (spread > 1e-3) (0.85 / spread - 1).coerceIn(-0.3, 0.4) else 0.0
    // White balance, half-way: red and blue level (temperature), then green against magenta (tint).
    val rb = (r + b) / 2
    val t = if (r + b > 1e-3) ((b - r) / (0.1 * (r + b)) * 0.5).coerceIn(-1.0, 1.0) else 0.0
    val tn = if (g > 1e-3) ((g - rb) / (0.1 * g + 0.05 * rb) * 0.5).coerceIn(-1.0, 1.0) else 0.0
    // Saturation: lift flat footage a little, calm very saturated footage.
    val s = when { chroma < 0.08 -> 0.15; chroma > 0.35 -> -0.1; else -> 0.0 }
    fun nz(v: Double) = r2(v).takeIf { it != 0.0 }
    val a = (base ?: Adjust()).copy(exposure = nz(e), contrast = nz(c), saturation = nz(s), temperature = nz(t), tint = nz(tn))
    return a
}
