package studio.muse.core.edit

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * Edit suite voice processing (server/api/src/editor/audio.ts): voice effects and "enhance" as biquad chains, the same
 * coefficients on every platform (checked against functions.json "voice": coefficients + impulse responses).
 */

/** One biquad, normalised by a0 (direct form I: y = b0·x + b1·x1 + b2·x2 − a1·y1 − a2·y2). */
data class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double)

enum class BiquadKind { LOWPASS, HIGHPASS, PEAKING, LOWSHELF, HIGHSHELF }

private fun r9(v: Double): Double = Math.round(v * 1e9).toDouble() / 1e9
private const val SQRT1_2 = 0.7071067811865476

/** RBJ audio-EQ-cookbook biquad, normalised by a0. Shelves use S = 1. */
fun biquad(kind: BiquadKind, f: Double, sr: Double, q: Double = SQRT1_2, gainDb: Double = 0.0): Biquad {
    val a = 10.0.pow(gainDb / 40); val w = 2 * PI * f / sr; val cw = cos(w); val sw = sin(w)
    val alpha = if (kind == BiquadKind.LOWSHELF || kind == BiquadKind.HIGHSHELF) (sw / 2) * sqrt(2.0) else sw / (2 * q)
    val sq = 2 * sqrt(a) * alpha
    val (b, den) = when (kind) {
        BiquadKind.LOWPASS -> doubleArrayOf((1 - cw) / 2, 1 - cw, (1 - cw) / 2) to doubleArrayOf(1 + alpha, -2 * cw, 1 - alpha)
        BiquadKind.HIGHPASS -> doubleArrayOf((1 + cw) / 2, -(1 + cw), (1 + cw) / 2) to doubleArrayOf(1 + alpha, -2 * cw, 1 - alpha)
        BiquadKind.PEAKING -> doubleArrayOf(1 + alpha * a, -2 * cw, 1 - alpha * a) to doubleArrayOf(1 + alpha / a, -2 * cw, 1 - alpha / a)
        BiquadKind.LOWSHELF -> doubleArrayOf(a * (a + 1 - (a - 1) * cw + sq), 2 * a * (a - 1 - (a + 1) * cw), a * (a + 1 - (a - 1) * cw - sq)) to
            doubleArrayOf(a + 1 + (a - 1) * cw + sq, -2 * (a - 1 + (a + 1) * cw), a + 1 + (a - 1) * cw - sq)
        BiquadKind.HIGHSHELF -> doubleArrayOf(a * (a + 1 + (a - 1) * cw + sq), -2 * a * (a - 1 + (a + 1) * cw), a * (a + 1 + (a - 1) * cw - sq)) to
            doubleArrayOf(a + 1 - (a - 1) * cw + sq, 2 * (a - 1 - (a + 1) * cw), a + 1 - (a - 1) * cw - sq)
    }
    val a0 = den[0]
    return Biquad(r9(b[0] / a0), r9(b[1] / a0), r9(b[2] / a0), r9(den[1] / a0), r9(den[2] / a0))
}

/** The filters for a clip's voice: `enhance` first, then the effect. Empty = untouched. */
fun voiceChain(voiceEffect: VoiceEffect?, enhance: Boolean?, sr: Double): List<Biquad> {
    val out = ArrayList<Biquad>()
    if (enhance == true) out += listOf(biquad(BiquadKind.HIGHPASS, 80.0, sr), biquad(BiquadKind.LOWSHELF, 200.0, sr, 0.0, -2.0), biquad(BiquadKind.PEAKING, 3000.0, sr, 1.0, 3.0))
    when (voiceEffect ?: VoiceEffect.NONE) {
        VoiceEffect.WARM -> out += listOf(biquad(BiquadKind.LOWSHELF, 200.0, sr, 0.0, 3.0), biquad(BiquadKind.HIGHSHELF, 6000.0, sr, 0.0, -3.0))
        VoiceEffect.RADIO -> out += listOf(biquad(BiquadKind.HIGHPASS, 500.0, sr), biquad(BiquadKind.LOWPASS, 3000.0, sr), biquad(BiquadKind.PEAKING, 1500.0, sr, 1.0, 4.0))
        VoiceEffect.PHONE -> out += listOf(biquad(BiquadKind.HIGHPASS, 300.0, sr), biquad(BiquadKind.HIGHPASS, 300.0, sr), biquad(BiquadKind.LOWPASS, 3400.0, sr), biquad(BiquadKind.LOWPASS, 3400.0, sr))
        VoiceEffect.DEEP -> out += listOf(biquad(BiquadKind.LOWSHELF, 150.0, sr, 0.0, 6.0), biquad(BiquadKind.HIGHSHELF, 3000.0, sr, 0.0, -4.0))
        VoiceEffect.NONE -> {}
    }
    return out
}

/** Runs a chain over mono samples (direct form I, state per filter). */
fun runChain(chain: List<Biquad>, x: DoubleArray): DoubleArray {
    var cur = x.copyOf()
    for (f in chain) {
        val y = DoubleArray(cur.size)
        var x1 = 0.0; var x2 = 0.0; var y1 = 0.0; var y2 = 0.0
        for (i in cur.indices) {
            val v = f.b0 * cur[i] + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
            x2 = x1; x1 = cur[i]; y2 = y1; y1 = v; y[i] = v
        }
        cur = y
    }
    return cur
}

/**
 * A streaming chain for one channel: keeps each filter's state between calls (an audio processor feeds it buffer by
 * buffer). Not thread-safe.
 */
class BiquadChain(private val chain: List<Biquad>) {
    private val state = Array(chain.size) { DoubleArray(4) }
    val isEmpty: Boolean get() = chain.isEmpty()

    fun process(v0: Double): Double {
        var v = v0
        for (k in chain.indices) {
            val f = chain[k]; val s = state[k]
            val y = f.b0 * v + f.b1 * s[0] + f.b2 * s[1] - f.a1 * s[2] - f.a2 * s[3]
            s[1] = s[0]; s[0] = v; s[3] = s[2]; s[2] = y
            v = y
        }
        return v
    }

    fun reset() { state.forEach { it.fill(0.0) } }
}
