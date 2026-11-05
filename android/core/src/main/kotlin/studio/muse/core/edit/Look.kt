package studio.muse.core.edit

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * Editor v2 "looks": the filter stack (plans/video-editor.md "Looks"). A Kotlin port of the TypeScript reference
 * server/api/src/editor/look.ts — the same data, the same answers (fixture src/test/resources/editor/looks.json) — and
 * the CPU renderer the app uses for filter thumbnails. Pure: no I/O, no Android types.
 *
 * Per item, on sRGB values 0–1, in this order:
 *   1 sharpen (unsharp mask)  2 chromatic aberration  3 colour matrix (adjust + filter)  4 tone curves
 *   5 3D LUT (trilinear, blended by strength)  6 lift (faded blacks)  7 halation  8 light leak  9 vignette  10 grain
 * Pictures are stored as 32-bit floats like the reference's Float32Array, so the renders agree to ~1e-6.
 */

enum class LeakKind(override val wire: String) : Wire { WARM("warm"), ROSE("rose"), AMBER("amber"), TEAL("teal"), RAINBOW("rainbow") }
enum class CurveChannel(override val wire: String) : Wire { RGB("rgb"), R("r"), G("g"), B("b") }

data class CurvePoint(val x: Double, val y: Double)
/** Tone curves by channel, in JSON order (master `rgb`, then the channel's own). */
typealias Curves = Map<CurveChannel, List<CurvePoint>>

data class Grain(val amount: Double, val size: Double? = null)
data class Vignette(val amount: Double, val size: Double? = null, val softness: Double? = null)
data class Halation(val amount: Double, val radius: Double? = null, val threshold: Double? = null)
data class Leak(val kind: LeakKind, val amount: Double, val angle: Double? = null)

/** A look: every part optional. [lut] = "pack:<id>" (a bundled look) or the id of a project asset of kind "lut". */
data class Look(
    val lut: String? = null,
    val strength: Double? = null,
    val curves: Curves? = null,
    val lift: Double? = null,
    val sharpen: Double? = null,
    val chromatic: Double? = null,
    val halation: Halation? = null,
    val leak: Leak? = null,
    val vignette: Vignette? = null,
    val grain: Grain? = null,
) {
    /** The bundled look id when [lut] is "pack:<id>". */
    val packId: String? get() = lut?.takeIf { it.startsWith(PACK_PREFIX) }?.substring(PACK_PREFIX.length)

    /** True when the look changes nothing (whatever LUT it would load). */
    fun isNoop(hasLut: Boolean = lut != null): Boolean =
        !(hasLut && (strength ?: 1.0) > 0) && curvesFn(curves) == null && (lift ?: 0.0) <= 0 && (sharpen ?: 0.0) <= 0 && (chromatic ?: 0.0) <= 0 &&
            (halation?.amount ?: 0.0) <= 0 && (leak?.amount ?: 0.0) <= 0 && (vignette?.amount ?: 0.0) == 0.0 && (grain?.amount ?: 0.0) <= 0

    companion object {
        const val PACK_PREFIX = "pack:"
        val KEYS = listOf("lut", "strength", "curves", "lift", "sharpen", "chromatic", "halation", "leak", "vignette", "grain")
    }
}

/** A parsed 3D LUT: [data] is rgb triples, red changing fastest (index ((b·N + g)·N + r)·3). */
class Lut(val size: Int, val title: String?, val domainMin: DoubleArray, val domainMax: DoubleArray, val data: FloatArray)

object LookLimits {
    const val MAX_LUT_SIZE = 64
    const val MIN_LUT_SIZE = 2
    const val MAX_CUBE_BYTES = 12 * 1024 * 1024
    const val MAX_CURVE_POINTS = 16
}

private fun lclamp(v: Double, lo: Double, hi: Double) = min(hi, max(lo, v))
private fun lc01(v: Double) = lclamp(v, 0.0, 1.0)
private fun lsmooth(a: Double, b: Double, x: Double): Double { val t = lc01((x - a) / (b - a)); return t * t * (3 - 2 * t) }
private const val L0 = 0.2126
private const val L1 = 0.7152
private const val L2 = 0.0722

// ------------------------------------------------------------------ .cube
class CubeException(message: String) : IllegalArgumentException(message)

/** `Number(s)` as JavaScript reads a whitespace-split token. */
private fun jsNumber(s: String?): Double {
    if (s == null) return Double.NaN
    val t = s.trim()
    if (t.isEmpty()) return 0.0
    if (t == "Infinity" || t == "+Infinity") return Double.POSITIVE_INFINITY
    if (t == "-Infinity") return Double.NEGATIVE_INFINITY
    Regex("^0([xXoObB])([0-9a-fA-F]+)$").find(t)?.let { m ->
        val radix = when (m.groupValues[1].lowercase()) { "x" -> 16; "o" -> 8; else -> 2 }
        return m.groupValues[2].toBigIntegerOrNull(radix)?.toDouble() ?: Double.NaN
    }
    if (!Regex("^[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?$").matches(t)) return Double.NaN
    return t.toDouble()
}

private val COMMENT = Regex("#.*$")
private val SPACES = Regex("\\s+")
private val QUOTES = Regex("^\"|\"$")

/** Parses an Adobe/Resolve .cube 3D LUT (red changes fastest). Throws [CubeException] naming the line on anything invalid. */
fun parseCube(text: String): Lut {
    if (text.length > LookLimits.MAX_CUBE_BYTES) throw CubeException("the file is over ${LookLimits.MAX_CUBE_BYTES / 1024 / 1024} MB")
    var size = 0
    var title: String? = null
    var dmin = doubleArrayOf(0.0, 0.0, 0.0)
    var dmax = doubleArrayOf(1.0, 1.0, 1.0)
    var data: FloatArray? = null
    var n = 0
    val lines = text.split(Regex("\r?\n"))
    for ((i, raw) in lines.withIndex()) {
        val line = COMMENT.replace(raw, "").trim()
        if (line.isEmpty()) continue
        val at = "line ${i + 1}"
        val c0 = line[0]
        if (c0 in 'A'..'Z' || c0 in 'a'..'z' || c0 == '_') {
            val parts = line.split(SPACES)
            val k = parts[0].uppercase()
            val rest = parts.drop(1)
            when (k) {
                "TITLE" -> title = QUOTES.replace(line.substring(5).trim(), "").take(120)
                "LUT_3D_SIZE" -> {
                    val v = jsNumber(rest.firstOrNull())
                    if (!(v.isFinite() && v == floor(v)) || v < LookLimits.MIN_LUT_SIZE || v > LookLimits.MAX_LUT_SIZE)
                        throw CubeException("$at: LUT_3D_SIZE must be ${LookLimits.MIN_LUT_SIZE}–${LookLimits.MAX_LUT_SIZE}")
                    size = v.toInt()
                    data = FloatArray(size * size * size * 3)
                }
                "LUT_1D_SIZE" -> throw CubeException("$at: 1D LUTs are not supported, use a 3D .cube")
                "DOMAIN_MIN", "DOMAIN_MAX" -> {
                    val v = rest.map(::jsNumber)
                    if (v.size != 3 || v.any { !it.isFinite() }) throw CubeException("$at: $k needs three numbers")
                    if (k == "DOMAIN_MIN") dmin = v.toDoubleArray() else dmax = v.toDoubleArray()
                }
                "LUT_3D_INPUT_RANGE" -> {
                    val v = rest.map(::jsNumber)
                    if (v.size != 2 || v.any { !it.isFinite() }) throw CubeException("$at: LUT_3D_INPUT_RANGE needs two numbers")
                    dmin = doubleArrayOf(v[0], v[0], v[0]); dmax = doubleArrayOf(v[1], v[1], v[1])
                }
                else -> {} // other keywords are ignored
            }
            continue
        }
        val d = data ?: throw CubeException("$at: numbers before LUT_3D_SIZE")
        val v = line.split(SPACES).map(::jsNumber)
        if (v.size != 3 || v.any { !it.isFinite() }) throw CubeException("$at: expected three numbers")
        if (n >= size * size * size) throw CubeException("$at: more than ${size}³ entries")
        d[n * 3] = v[0].toFloat(); d[n * 3 + 1] = v[1].toFloat(); d[n * 3 + 2] = v[2].toFloat()
        n++
    }
    val d = data ?: throw CubeException("no LUT_3D_SIZE line")
    if (n != size * size * size) throw CubeException("expected ${size}³ = ${size * size * size} entries, found $n")
    for (c in 0 until 3) if (!(dmax[c] > dmin[c])) throw CubeException("DOMAIN_MAX must be above DOMAIN_MIN")
    return Lut(size, title, dmin, dmax, d)
}

/** The outcome of checking a user's .cube before it is imported: its size and title, or the reason it was refused. */
sealed interface CubeCheck {
    data class Ok(val size: Int, val title: String?, val lut: Lut) : CubeCheck
    data class Bad(val message: String) : CubeCheck
}

/** [parseCube] as a result instead of an exception (the import screen shows [CubeCheck.Bad.message]). */
fun checkCube(text: String): CubeCheck = try { parseCube(text).let { CubeCheck.Ok(it.size, it.title, it) } } catch (e: CubeException) { CubeCheck.Bad(e.message ?: "not a .cube file") }

/** Trilinear lookup into [out] (length ≥ 3). */
fun lutSample(l: Lut, r: Double, g: Double, b: Double, out: DoubleArray = DoubleArray(3)): DoubleArray {
    val n = l.size; val m = n - 1
    fun pos(v: Double, c: Int) = lc01((v - l.domainMin[c]) / (l.domainMax[c] - l.domainMin[c])) * m
    val fr = pos(r, 0); val fg = pos(g, 1); val fb = pos(b, 2)
    val r0 = floor(fr).toInt(); val g0 = floor(fg).toInt(); val b0 = floor(fb).toInt()
    val r1 = min(m, r0 + 1); val g1 = min(m, g0 + 1); val b1 = min(m, b0 + 1)
    val dr = fr - r0; val dg = fg - g0; val db = fb - b0
    val d = l.data
    fun at(ri: Int, gi: Int, bi: Int, c: Int): Double = d[((bi * n + gi) * n + ri) * 3 + c].toDouble()
    for (c in 0 until 3) {
        val c00 = at(r0, g0, b0, c) * (1 - dr) + at(r1, g0, b0, c) * dr
        val c10 = at(r0, g1, b0, c) * (1 - dr) + at(r1, g1, b0, c) * dr
        val c01v = at(r0, g0, b1, c) * (1 - dr) + at(r1, g0, b1, c) * dr
        val c11 = at(r0, g1, b1, c) * (1 - dr) + at(r1, g1, b1, c) * dr
        out[c] = (c00 * (1 - dg) + c10 * dg) * (1 - db) + (c01v * (1 - dg) + c11 * dg) * db
    }
    return out
}

// ------------------------------------------------------------------ curves
/** A tone curve through [pts] (x ascending, both 0–1), monotone cubic (Fritsch–Carlson), flat beyond the end points. */
fun curveFn(pts: List<CurvePoint>?): ((Double) -> Double)? {
    if (pts == null || pts.size < 2) return null
    val n = pts.size
    val xs = DoubleArray(n) { pts[it].x }; val ys = DoubleArray(n) { pts[it].y }
    val d = DoubleArray(n - 1) { (ys[it + 1] - ys[it]) / (xs[it + 1] - xs[it]) }
    val m = DoubleArray(n)
    m[0] = d[0]; m[n - 1] = d[n - 2]
    for (i in 1 until n - 1) m[i] = if (d[i - 1] * d[i] <= 0) 0.0 else (d[i - 1] + d[i]) / 2
    for (i in 0 until n - 1) {
        if (d[i] == 0.0) { m[i] = 0.0; m[i + 1] = 0.0; continue }
        val a = m[i] / d[i]; val b = m[i + 1] / d[i]; val s = a * a + b * b
        if (s > 9) { val t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
    }
    return { x ->
        if (x <= xs[0]) ys[0]
        else if (x >= xs[n - 1]) ys[n - 1]
        else {
            var k = 0
            while (k < n - 2 && x > xs[k + 1]) k++
            val h = xs[k + 1] - xs[k]; val t = (x - xs[k]) / h; val t2 = t * t; val t3 = t2 * t
            (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k] + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1]
        }
    }
}

/** The four curves applied together (master, then the channel's own), each result clamped; in place on [rgb]. */
fun curvesFn(c: Curves?): ((DoubleArray) -> DoubleArray)? {
    if (c == null) return null
    val m = curveFn(c[CurveChannel.RGB])
    val ch = arrayOf(curveFn(c[CurveChannel.R]), curveFn(c[CurveChannel.G]), curveFn(c[CurveChannel.B]))
    if (m == null && ch.all { it == null }) return null
    return { rgb ->
        for (i in 0 until 3) { var o = m?.invoke(rgb[i]) ?: rgb[i]; ch[i]?.let { o = it(o) }; rgb[i] = lc01(o) }
        rgb
    }
}

// ------------------------------------------------------------------ noise, vignette, leak
/** 32-bit integer hash (lowbias32) → 0…1. The same bits as the reference (Math.imul) and Swift (UInt32). */
fun hash01(x: Int, y: Int, frame: Int): Double {
    var h = (x * 0x27d4eb2d) xor (y * 0x165667b1) xor (frame * 0x9e3779b9.toInt())
    h = h xor (h ushr 16); h *= 0x7feb352d
    h = h xor (h ushr 15); h *= 0x846ca68b.toInt()
    h = h xor (h ushr 16)
    return (h.toLong() and 0xffffffffL).toDouble() / 4294967295.0
}

/** Vignette amount at u, v (0–1): m = lsmooth(size, size + softness, r), r = 1 at the corners. */
fun vignetteMask(v: Vignette, u: Double, w: Double): Double {
    val dx = (u - 0.5) * 2; val dy = (w - 0.5) * 2; val r = sqrt(dx * dx + dy * dy) / sqrt(2.0)
    val size = lclamp(v.size ?: 0.45, 0.0, 1.0); val soft = max(0.05, lclamp(v.softness ?: 0.5, 0.0, 1.0))
    return lsmooth(size, size + soft, r)
}

/** The two colours of each leak kind (near the source → far). */
val LEAK_COLORS: Map<LeakKind, Array<DoubleArray>> = mapOf(
    LeakKind.WARM to arrayOf(doubleArrayOf(1.0, 0.55, 0.2), doubleArrayOf(1.0, 0.8, 0.45)),
    LeakKind.ROSE to arrayOf(doubleArrayOf(1.0, 0.35, 0.45), doubleArrayOf(1.0, 0.7, 0.6)),
    LeakKind.AMBER to arrayOf(doubleArrayOf(1.0, 0.65, 0.1), doubleArrayOf(1.0, 0.9, 0.5)),
    LeakKind.TEAL to arrayOf(doubleArrayOf(0.2, 0.85, 0.85), doubleArrayOf(0.6, 0.95, 1.0)),
    LeakKind.RAINBOW to arrayOf(doubleArrayOf(1.0, 0.3, 0.3), doubleArrayOf(0.4, 0.6, 1.0)),
)

/** Light-leak colour (to screen over the picture) at u, v and time t seconds: a soft blob from one edge that drifts. */
fun leakColor(l: Leak, u: Double, v: Double, t: Double, out: DoubleArray = DoubleArray(3)): DoubleArray {
    val a = (l.angle ?: 30.0) * PI / 180 + 0.25 * sin(t * 0.6)
    val cx = 0.5 + 0.75 * cos(a); val cy = 0.5 - 0.75 * sin(a)
    val d = sqrt((u - cx) * (u - cx) + (v - cy) * (v - cy))
    val k = lclamp(l.amount, 0.0, 1.0) * (1 - lsmooth(0.15, 0.95, d))
    val (c0, c1) = LEAK_COLORS.getValue(l.kind)
    val mix = lsmooth(0.1, 0.8, d)
    for (i in 0 until 3) out[i] = k * (c0[i] * (1 - mix) + c1[i] * mix)
    return out
}

// ------------------------------------------------------------------ CPU renderer
/** An RGB picture: row-major rgb triples, 0–1, 32-bit floats (like the reference's Float32Array). */
class LookImage(val width: Int, val height: Int, val data: FloatArray = FloatArray(width * height * 3)) {
    init { require(data.size == width * height * 3) { "data must hold width × height × 3 values" } }

    companion object {
        /** From packed ARGB pixels (android.graphics.Bitmap.getPixels order); alpha is ignored. */
        fun fromArgb(width: Int, height: Int, argb: IntArray): LookImage {
            val d = FloatArray(width * height * 3)
            for (i in 0 until width * height) {
                val p = argb[i]
                d[i * 3] = ((p shr 16) and 0xff) / 255f; d[i * 3 + 1] = ((p shr 8) and 0xff) / 255f; d[i * 3 + 2] = (p and 0xff) / 255f
            }
            return LookImage(width, height, d)
        }
    }

    /** Packed opaque ARGB pixels (rounded to 8 bits). */
    fun toArgb(): IntArray = IntArray(width * height) { i ->
        fun b(c: Int) = (lc01(data[i * 3 + c].toDouble()) * 255).roundToLong().toInt()
        (0xff shl 24) or (b(0) shl 16) or (b(1) shl 8) or b(2)
    }
}

private fun px(img: LookImage, x: Int, y: Int, c: Int): Double =
    img.data[(y.coerceIn(0, img.height - 1) * img.width + x.coerceIn(0, img.width - 1)) * 3 + c].toDouble()

/** Box blur, separable, clamp to edge, radius in pixels (≥ 1). */
fun boxBlur(img: LookImage, radius: Double): LookImage {
    val w = img.width; val h = img.height; val r = max(1L, jsRound(radius)).toInt(); val n = 2 * r + 1
    val tmp = LookImage(w, h)
    for (y in 0 until h) for (x in 0 until w) for (c in 0 until 3) {
        var s = 0.0
        for (k in -r..r) s += px(img, x + k, y, c)
        tmp.data[(y * w + x) * 3 + c] = (s / n).toFloat()
    }
    val out = LookImage(w, h)
    for (y in 0 until h) for (x in 0 until w) for (c in 0 until 3) {
        var s = 0.0
        for (k in -r..r) s += px(tmp, x, y + k, c)
        out.data[(y * w + x) * 3 + c] = (s / n).toFloat()
    }
    return out
}

private fun bilinear(img: LookImage, fx: Double, fy: Double, c: Int): Double {
    val x0 = floor(fx).toInt(); val y0 = floor(fy).toInt(); val dx = fx - x0; val dy = fy - y0
    return (px(img, x0, y0, c) * (1 - dx) + px(img, x0 + 1, y0, c) * dx) * (1 - dy) + (px(img, x0, y0 + 1, c) * (1 - dx) + px(img, x0 + 1, y0 + 1, c) * dx) * dy
}

/** JavaScript's Math.round (halves round up). */
private fun jsRound(v: Double): Long = floor(v + 0.5).toLong()

/** Pixel radii for the spatial steps, from the picture's short side (so they scale with resolution). */
fun sharpenRadius(short: Int): Int = max(1L, jsRound(short * 0.0015)).toInt()
fun halationRadius(short: Int, h: Halation): Int = max(1L, jsRound(short * 0.04 * lclamp(h.radius ?: 0.5, 0.05, 1.0))).toInt()
fun grainCell(short: Int, g: Grain): Int = max(1L, jsRound(short / 1080.0 * lclamp(g.size ?: 1.0, 0.5, 3.0))).toInt()

/**
 * Steps 3–6 (colour matrix → curves → LUT by strength → lift), each clamped: the per-pixel colour part of a look.
 * The GPU path bakes exactly this into one 3D LUT ([bakeCube]).
 */
class ColorStack(matrix: List<Double>?, look: Look, lut: Lut?, tone: Tone? = null) {
    private val m: DoubleArray? = matrix?.toDoubleArray()
    private val sh = tone?.shadows ?: 0.0
    private val hi = tone?.highlights ?: 0.0
    private val curves = curvesFn(look.curves)
    private val strength = lclamp(look.strength ?: 1.0, 0.0, 1.0)
    private val l: Lut? = lut?.takeIf { strength > 0 }
    private val lift = 0.12 * lclamp(look.lift ?: 0.0, 0.0, 1.0)
    private val t = DoubleArray(3)

    /** True when the stack changes nothing. */
    val isIdentity: Boolean get() = m == null && sh == 0.0 && hi == 0.0 && curves == null && l == null && lift <= 0

    /** Applies the stack to [rgb] in place (not thread-safe: one instance per thread). */
    fun apply(rgb: DoubleArray): DoubleArray {
        m?.let { m ->
            val r = rgb[0]; val g = rgb[1]; val b = rgb[2]
            for (i in 0 until 3) rgb[i] = lc01(m[i * 4] * r + m[i * 4 + 1] * g + m[i * 4 + 2] * b + m[i * 4 + 3])
        }
        // 3b. highlights / shadows (Adjust)
        if (sh != 0.0 || hi != 0.0) for (i in 0 until 3) rgb[i] = toneAdjust(rgb[i], sh, hi)
        curves?.invoke(rgb)
        l?.let { lut ->
            lutSample(lut, rgb[0], rgb[1], rgb[2], t)
            for (i in 0 until 3) rgb[i] = lc01(rgb[i] + (t[i] - rgb[i]) * strength)
        }
        if (lift > 0) for (i in 0 until 3) rgb[i] = lift + rgb[i] * (1 - lift)
        return rgb
    }

    /**
     * The stack sampled on a [size]³ grid over 0–1, rgb triples in Media3's `int[R][G][B]` order (index
     * ((r·N + g)·N + b)·3). With a 17³ pack LUT and size 33 (= 2·16 + 1) the grid nests, so a trilinear lookup of the
     * baked cube equals the original LUT exactly; the matrix and curves are exact at the grid points.
     */
    fun bakeCube(size: Int = 33): FloatArray {
        val out = FloatArray(size * size * size * 3)
        val rgb = DoubleArray(3)
        val k = 1.0 / (size - 1)
        for (r in 0 until size) for (g in 0 until size) for (b in 0 until size) {
            rgb[0] = r * k; rgb[1] = g * k; rgb[2] = b * k
            apply(rgb)
            val i = ((r * size + g) * size + b) * 3
            out[i] = rgb[0].toFloat(); out[i + 1] = rgb[1].toFloat(); out[i + 2] = rgb[2].toFloat()
        }
        return out
    }
}

/**
 * Renders [look] on [img]. [matrix] = the item's colour matrix (colorMatrix, 3×4) or null; [lut] = the resolved LUT or
 * null; [frame]/[fps] animate the grain and the leak.
 */
fun renderLook(img: LookImage, look: Look, matrix: List<Double>? = null, lut: Lut? = null, frame: Int = 0, fps: Double = 30.0, tone: Tone? = null): LookImage {
    val w = img.width; val h = img.height; val short = min(w, h)
    var src = img
    // 1. sharpen
    val sh = lclamp(look.sharpen ?: 0.0, 0.0, 1.0)
    if (sh > 0) {
        val bl = boxBlur(src, sharpenRadius(short).toDouble())
        val d = FloatArray(src.data.size)
        for (i in d.indices) { val v = src.data[i].toDouble(); d[i] = lc01(v + 1.5 * sh * (v - bl.data[i])).toFloat() }
        src = LookImage(w, h, d)
    }
    // 2. chromatic aberration (red out, blue in, from the centre); 3–6 the colour stack
    val ca = lclamp(look.chromatic ?: 0.0, 0.0, 1.0) * 0.006
    val stack = ColorStack(matrix, look, lut, tone)

    val out = FloatArray(w * h * 3)
    val rgb = DoubleArray(3)
    for (y in 0 until h) for (x in 0 until w) {
        if (ca > 0) {
            val u = (x + 0.5) / w - 0.5; val v = (y + 0.5) / h - 0.5
            rgb[0] = bilinear(src, x + u * ca * w, y + v * ca * h, 0); rgb[1] = px(src, x, y, 1); rgb[2] = bilinear(src, x - u * ca * w, y - v * ca * h, 2)
        } else { rgb[0] = px(src, x, y, 0); rgb[1] = px(src, x, y, 1); rgb[2] = px(src, x, y, 2) }
        stack.apply(rgb)
        val i = (y * w + x) * 3
        out[i] = rgb[0].toFloat(); out[i + 1] = rgb[1].toFloat(); out[i + 2] = rgb[2].toFloat()
    }
    val res = LookImage(w, h, out)
    // 7. halation: blurred highlights, warm red, screened on
    val ha = look.halation
    if (ha != null && ha.amount > 0) {
        val thr = lclamp(ha.threshold ?: 0.7, 0.0, 0.99); val bl = boxBlur(res, halationRadius(short, ha).toDouble()); val k = lclamp(ha.amount, 0.0, 1.0)
        for (i in 0 until w * h) {
            val l = L0 * bl.data[i * 3] + L1 * bl.data[i * 3 + 1] + L2 * bl.data[i * 3 + 2]
            val hgl = lc01((l - thr) / (1 - thr)) * k
            for (c in 0 until 3) out[i * 3 + c] = (1 - (1 - out[i * 3 + c].toDouble()) * (1 - HALATION_TINT[c] * hgl)).toFloat()
        }
    }
    val t = frame / fps
    val vg = look.vignette?.takeIf { it.amount != 0.0 }
    val gr = look.grain?.takeIf { it.amount > 0 }
    val lk = look.leak?.takeIf { it.amount > 0 }
    if (vg != null || gr != null || lk != null) {
        val cell = if (gr != null) grainCell(short, gr) else 1
        val ga = if (gr != null) lclamp(gr.amount, 0.0, 1.0) * 0.18 else 0.0
        val va = if (vg != null) lclamp(vg.amount, -1.0, 1.0) else 0.0
        val c = DoubleArray(3)
        for (y in 0 until h) for (x in 0 until w) {
            val i = (y * w + x) * 3; val u = (x + 0.5) / w; val v = (y + 0.5) / h
            // 8. light leak (screen)
            if (lk != null) { leakColor(lk, u, v, t, c); for (k in 0 until 3) out[i + k] = (1 - (1 - out[i + k].toDouble()) * (1 - c[k])).toFloat() }
            // 9. vignette
            if (vg != null) {
                val m = vignetteMask(vg, u, v)
                for (k in 0 until 3) {
                    val o = out[i + k].toDouble()
                    out[i + k] = (if (va > 0) o * (1 - va * m) else o + -va * m * (1 - o)).toFloat()
                }
            }
            // 10. grain: mono, strongest in the mid-tones, cells of `cell` px, a new pattern every frame
            if (gr != null) {
                val n = hash01(x / cell, y / cell, frame) - 0.5
                val l = L0 * out[i] + L1 * out[i + 1] + L2 * out[i + 2]
                val g = ga * n * (1 - abs(2 * l - 1) * 0.5)
                for (k in 0 until 3) out[i + k] = (out[i + k] + g).toFloat()
            }
            for (k in 0 until 3) out[i + k] = lc01(out[i + k].toDouble()).toFloat()
        }
    }
    return res
}

/** The warm tint of halation (screened). */
val HALATION_TINT = doubleArrayOf(1.0, 0.35, 0.2)

/** Highlights/shadows of an item's Adjust (Edit suite), applied right after the colour matrix ([toneAdjust]). */
data class Tone(val shadows: Double = 0.0, val highlights: Double = 0.0) {
    val isNoop: Boolean get() = shadows == 0.0 && highlights == 0.0

    companion object {
        /** The tone of [adjust], or null when it has none. */
        fun of(adjust: Adjust?): Tone? = Tone(adjust?.shadows ?: 0.0, adjust?.highlights ?: 0.0).takeUnless { it.isNoop }
    }
}
