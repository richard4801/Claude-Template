package studio.muse.core.edit

import kotlin.math.pow
import kotlin.math.sqrt

/**
 * The chroma key (plans/video-editor.md "Chroma key"), on 0–1 RGB. The contract only names the parameters, so this
 * is the formula Android uses (the GLSL in app ChromaKeyEffect is the same) and the reference for the Mac port:
 *  - d = distance between the pixel's and the key colour's (Cb, Cr) (BT.601 chroma plane, each −0.5…0.5);
 *  - base = d − similarity; alpha = clamp(base / smoothness, 0, 1)^1.5 (a soft edge `smoothness` wide);
 *  - spill: s = clamp(base / spill, 0, 1)^1.5, colour = mix(luma, colour, s): pixels near the key lose its tint.
 */
object ChromaKey {
    const val DEFAULT_SIMILARITY = 0.4
    const val DEFAULT_SMOOTHNESS = 0.08
    const val DEFAULT_SPILL = 0.5

    fun cbCr(r: Double, g: Double, b: Double): Pair<Double, Double> =
        (-0.168736 * r - 0.331264 * g + 0.5 * b) to (0.5 * r - 0.418688 * g - 0.081312 * b)

    /** (r, g, b, alpha) after keying. */
    fun apply(r: Double, g: Double, b: Double, key: Chroma): DoubleArray {
        val k = hexRgb(key.color)
        val (cb, cr) = cbCr(r, g, b); val (kb, kr) = cbCr(k[0], k[1], k[2])
        val d = sqrt((cb - kb).pow(2) + (cr - kr).pow(2))
        val base = d - (key.similarity ?: DEFAULT_SIMILARITY)
        val alpha = clamp(base / maxOf(key.smoothness ?: DEFAULT_SMOOTHNESS, 1e-4), 0.0, 1.0).pow(1.5)
        val s = clamp(base / maxOf(key.spill ?: DEFAULT_SPILL, 1e-4), 0.0, 1.0).pow(1.5)
        val l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return doubleArrayOf(l + (r - l) * s, l + (g - l) * s, l + (b - l) * s, alpha)
    }
}
