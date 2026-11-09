package studio.muse.app.ui.screens.edit

/**
 * A sound's loudness over its file: the peak level (0–1) of every 1/[perSec] s slice, loudest channel. Decoded on the
 * phone (`platform/edit/WaveformDecoder`) for the timeline's sound lanes, the same idea as the Mac's `EditSuite.Peaks`.
 */
class Peaks(val perSec: Float, val values: FloatArray) {
    val durationSec: Double get() = values.size / perSec.toDouble()

    /** The level at source second [sec] (0 outside the file). */
    fun at(sec: Double): Float {
        val i = (sec * perSec).toInt()
        return if (i in values.indices) values[i] else 0f
    }

    /** The loudest level in source seconds [a, b) (at least one slice). */
    fun max(a: Double, b: Double): Float {
        val i0 = (a * perSec).toInt().coerceAtLeast(0)
        val i1 = ((b * perSec).toInt()).coerceAtMost(values.size - 1).coerceAtLeast(i0)
        if (i0 >= values.size) return 0f
        var m = 0f
        for (i in i0..i1) if (values[i] > m) m = values[i]
        return m
    }

    companion object {
        /**
         * Builds peaks from interleaved 16-bit PCM read in chunks: feed each chunk to [Builder.add], then [Builder.build].
         * The loudest channel of each frame counts.
         */
        class Builder(private val sampleRate: Int, private val channels: Int, private val perSec: Float = 50f) {
            private val framesPerSlice = (sampleRate / perSec).toInt().coerceAtLeast(1)
            private val out = ArrayList<Float>()
            private var cur = 0f
            private var n = 0

            fun add(pcm: ShortArray, count: Int = pcm.size) {
                val ch = channels.coerceAtLeast(1)
                var i = 0
                while (i + ch <= count) {
                    var peak = 0
                    for (c in 0 until ch) { val v = kotlin.math.abs(pcm[i + c].toInt()); if (v > peak) peak = v }
                    val f = peak / 32768f
                    if (f > cur) cur = f
                    n++
                    if (n == framesPerSlice) { out += cur; cur = 0f; n = 0 }
                    i += ch
                }
            }

            fun build(): Peaks {
                if (n > 0) { out += cur; cur = 0f; n = 0 }
                return Peaks(sampleRate.toFloat() / framesPerSlice, out.toFloatArray())
            }
        }
    }
}
