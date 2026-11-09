package studio.muse.core.edit

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The effects library (owner-approved 2026-11-09): the reference maths of server/api/src/editor/effects.ts, pixel by
 * pixel (the fixture's numbers). The engine runs the same as GL shaders (app: EffectShaders). u, v ∈ [0, 1] with v
 * down; t = item-local seconds; noise = [hash3] over Perlin's permutation (a 256×1 texture on the GPU).
 */
enum class EffectId(override val wire: String) : Wire {
    GLITCH("glitch"), VHS("vhs"), FILM("film"), BLUR("blur"), ZOOM_BLUR("zoomBlur"), MIRROR("mirror"), PIXELATE("pixelate"),
    POSTERIZE("posterize"), DUOTONE("duotone"), SHAKE("shake"), FLASH("flash"), RAIN("rain");
    /** Effects whose look moves over time (they take a speed). */
    val timed: Boolean get() = this in setOf(GLITCH, VHS, FILM, SHAKE, FLASH, RAIN)
}

data class Effect(val id: EffectId, val amount: Double, val speed: Double? = null, val colors: List<String>? = null)

object Effects {
    val DUOTONE_DEFAULT = listOf("#1B1464", "#FF6B6B")

    /** Ken Perlin's permutation (improved noise, 2002). */
    val PERM = intArrayOf(151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10,
        23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68,
        175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65,
        25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226,
        250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44,
        154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34,
        242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50,
        45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180)

    private fun m256(i: Double) = ((floor(i).toInt() % 256) + 256) % 256
    private fun m256(i: Int) = ((i % 256) + 256) % 256
    /** Noise in [0, 1] from three integers: exact on every platform. */
    fun hash3(i: Double, j: Double, k: Double): Double = PERM[m256(PERM[m256(PERM[m256(i)] + floor(j).toInt())] + floor(k).toInt())] / 255.0
    private fun fract(x: Double) = x - floor(x)
    private fun c01(x: Double) = min(1.0, max(0.0, x))
    private fun mix(a: Double, b: Double, k: Double) = a + (b - a) * k
    private fun hex(h: String) = doubleArrayOf(h.substring(1, 3).toInt(16) / 255.0, h.substring(3, 5).toInt(16) / 255.0, h.substring(5, 7).toInt(16) / 255.0)

    /** One output pixel of [e] at (u, v) of a [w]×[h] frame at item-local [t]; [sample] clamps at the edges. */
    fun pixel(e: Effect, t: Double, w: Int, h: Int, u: Double, v: Double, sample: (Double, Double) -> DoubleArray): DoubleArray {
        val a = c01(e.amount); val ts = t * (e.speed ?: 1.0)
        if (a <= 0) return sample(u, v)
        return when (e.id) {
            EffectId.GLITCH -> {
                val n = floor(ts * 12); val b = floor(v * 16)
                val u2 = if (hash3(b, n, 1.0) > 1 - 0.5 * a) u + (hash3(b, n, 2.0) - 0.5) * 0.2 * a else u
                val sp = 0.015 * a
                doubleArrayOf(sample(u2 + sp, v)[0], sample(u2, v)[1], sample(u2 - sp, v)[2])
            }
            EffectId.VHS -> {
                val u2 = u + sin(40 * v + 6 * ts) * 0.004 * a
                val c = doubleArrayOf(sample(u2 + 0.006 * a, v)[0], sample(u2, v)[1], sample(u2 - 0.006 * a, v)[2])
                val scan = 1 - 0.2 * a * (0.5 + 0.5 * cos(2 * PI * 240 * v))
                val nz = (hash3(floor(320 * u), floor(240 * v), floor(24 * ts)) - 0.5) * 0.1 * a
                DoubleArray(3) { c01(c[it] * scan + nz) }
            }
            EffectId.FILM -> {
                val c = sample(u + sin(7 * ts) * 0.002 * a, v + cos(5 * ts) * 0.002 * a)
                val g = (hash3(floor(480 * u), floor(480 * v), floor(24 * t)) - 0.5) * 0.16 * a
                val dust = if (hash3(floor(160 * u), floor(160 * v), floor(12 * ts) + 7) >= 1 - 0.02 * a) 0.35 else 1.0
                doubleArrayOf(c01((c[0] + g) * dust * (1 + 0.05 * a)), c01((c[1] + g) * dust), c01((c[2] + g) * dust * (1 - 0.05 * a)))
            }
            EffectId.BLUR -> {
                val r = 0.02 * a
                val wt = DoubleArray(13) { exp(-0.5 * ((it - 6) / 3.0) * ((it - 6) / 3.0)) }
                val sum = wt.sum()
                val out = DoubleArray(3)
                for (i in 0 until 13) for (j in 0 until 13) {
                    val k = (wt[i] / sum) * (wt[j] / sum)
                    val c = sample(u + ((i - 6) * r / 6) * h / w, v + (j - 6) * r / 6)
                    for (q in 0..2) out[q] += k * c[q]
                }
                out
            }
            EffectId.ZOOM_BLUR -> {
                val out = DoubleArray(3)
                for (k in 0 until 10) {
                    val z = 1 - 0.15 * a * k / 9
                    val c = sample(0.5 + (u - 0.5) * z, 0.5 + (v - 0.5) * z)
                    for (q in 0..2) out[q] += c[q] / 10
                }
                out
            }
            EffectId.MIRROR -> sample(if (u < 0.5) u else 1 - u, if (a >= 0.5) (if (v < 0.5) v else 1 - v) else v)
            EffectId.PIXELATE -> {
                val n = (160 - 150 * a).roundHalfUp(); val cw = 1.0 / n; val ch = cw * w / h
                sample((floor(u / cw) + 0.5) * cw, (floor(v / ch) + 0.5) * ch)
            }
            EffectId.POSTERIZE -> {
                val l = (16 - 13 * a).roundHalfUp()
                sample(u, v).let { c -> DoubleArray(3) { (c[it] * (l - 1)).roundHalfUp().toDouble() / (l - 1) } }
            }
            EffectId.DUOTONE -> {
                val cs = (e.colors ?: DUOTONE_DEFAULT).map(::hex)
                val c = sample(u, v)
                val y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
                DoubleArray(3) { mix(c[it], mix(cs[0][it], cs[1][it], y), a) }
            }
            EffectId.SHAKE -> {
                val n = floor(15 * ts); val z = 1 + 0.05 * a
                sample(0.5 + (u - 0.5) / z + (hash3(n, 3.0, 0.0) - 0.5) * 0.04 * a, 0.5 + (v - 0.5) / z + (hash3(n, 4.0, 0.0) - 0.5) * 0.04 * a)
            }
            EffectId.FLASH -> {
                val f = max(0.0, 1 - 4 * fract(ts))
                sample(u, v).let { c -> DoubleArray(3) { c[it] + (1 - c[it]) * f * a } }
            }
            EffectId.RAIN -> {
                val cx = floor(48 * u)
                val on = hash3(cx, 5.0, 0.0) < 0.6
                val sp = 0.4 + 0.8 * hash3(cx, 6.0, 0.0)
                val y0 = fract(hash3(cx, 7.0, 0.0) + ts * sp)
                val d = fract(v - y0)
                val i = if (on && d < 0.08) 1 - d / 0.08 else 0.0
                sample(u + 0.006 * a * i, v).let { c -> DoubleArray(3) { c01(c[it] + 0.12 * a * i) } }
            }
        }
    }

    /** JS Math.round (half up), as the reference. */
    private fun Double.roundHalfUp(): Int = floor(this + 0.5).toInt()

    /** A bilinear, clamp-to-edge sampler over a [w]×[h] RGB image (row-major, 0–1), like a GPU texture. */
    fun sampler(w: Int, h: Int, px: List<DoubleArray>): (Double, Double) -> DoubleArray {
        fun at(x: Int, y: Int) = px[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))]
        return { u, v ->
            val fx = min(w - 0.5, max(0.5, u * w)) - 0.5; val fy = min(h - 0.5, max(0.5, v * h)) - 0.5
            val x0 = floor(fx).toInt(); val y0 = floor(fy).toInt(); val dx = fx - x0; val dy = fy - y0
            val a = at(x0, y0); val b = at(x0 + 1, y0); val c = at(x0, y0 + 1); val d = at(x0 + 1, y0 + 1)
            DoubleArray(3) { (a[it] * (1 - dx) + b[it] * dx) * (1 - dy) + (c[it] * (1 - dx) + d[it] * dx) * dy }
        }
    }
}
