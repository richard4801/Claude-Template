package studio.muse.app.platform

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.SoundPool
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/**
 * The prototype's per-theme UI sounds (app.js SND), synthesised the same way: oscillators with exponential pitch
 * ramps and band-passed noise bursts.
 *
 * Every sound is rendered once to a small WAV in [cacheDir] and preloaded into a [SoundPool], which plays with low
 * latency. Sounds use the media stream (USAGE_GAME), so they follow the media volume, like other apps' UI sounds,
 * rather than the system/touch-sound volume, which is often muted. Each sound is normalised so it is clearly audible.
 * With no [cacheDir] (tests), it falls back to a one-off AudioTrack.
 */
class SoundFx(private val enabled: () -> Boolean, private val theme: () -> String, private val cacheDir: File? = null) {
    enum class Kind { TAP, TICK, NAV, GO, DONE, THEME }

    private val rate = 22050
    private val cache = ConcurrentHashMap<String, ShortArray>()
    private val ids = ConcurrentHashMap<String, Int>()
    private val ready = ConcurrentHashMap.newKeySet<Int>()
    private val pool = Executors.newFixedThreadPool(2) { r -> Thread(r, "muse-sfx").apply { isDaemon = true } }
    private val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    private val soundPool: SoundPool? = cacheDir?.let {
        SoundPool.Builder().setMaxStreams(6).setAudioAttributes(attrs).build().apply {
            setOnLoadCompleteListener { _, id, status -> if (status == 0) ready.add(id) else Log.w(TAG, "load failed $id/$status") }
        }
    }

    init {
        // Preload every theme's sounds in the background, current theme first, so the first tap already plays.
        if (soundPool != null) pool.execute {
            val first = runCatching { theme() }.getOrDefault("a")
            (listOf(first) + listOf("a", "b", "c", "d").filter { it != first }).forEach { t -> Kind.entries.forEach { k -> load(t, k) } }
        }
    }

    private fun load(t: String, k: Kind): Int? {
        val key = t + k.name
        ids[key]?.let { return it }
        val sp = soundPool ?: return null
        return runCatching {
            val f = File(cacheDir, "sfx_v2_$key.wav")
            if (!f.exists()) writeWav(f, cache.getOrPut(key) { render(t, k) })
            sp.load(f.path, 1).also { ids[key] = it }
        }.onFailure { Log.w(TAG, "could not prepare $key", it) }.getOrNull()
    }

    fun play(kind: Kind) {
        if (!enabled()) return
        val t = theme()
        val id = ids[t + kind.name]
        if (soundPool != null && id != null && id in ready) {
            soundPool.play(id, 1f, 1f, 1, 0, 1f)
            return
        }
        pool.execute {
            runCatching {
                if (soundPool != null) load(t, kind)
                val pcm = cache.getOrPut(t + kind.name) { render(t, kind) }
                val track = AudioTrack.Builder()
                    .setAudioAttributes(attrs)
                    .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(max(pcm.size * 2, 4096))
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                val padded = if (pcm.size * 2 < 4096) pcm.copyOf(2048) else pcm
                track.write(padded, 0, padded.size)
                track.play()
                Thread.sleep(padded.size * 1000L / rate + 60)
                track.release()
            }.onFailure { Log.w(TAG, "play failed", it) }
        }
    }

    private fun writeWav(f: File, pcm: ShortArray) {
        val tmp = File(f.path + ".tmp")
        RandomAccessFile(tmp, "rw").use { r ->
            r.setLength(0)
            fun le32(v: Int) { r.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())) }
            fun le16(v: Int) { r.write(byteArrayOf(v.toByte(), (v shr 8).toByte())) }
            r.writeBytes("RIFF"); le32(36 + pcm.size * 2); r.writeBytes("WAVE")
            r.writeBytes("fmt "); le32(16); le16(1); le16(1); le32(rate); le32(rate * 2); le16(2); le16(16)
            r.writeBytes("data"); le32(pcm.size * 2)
            val b = ByteArray(pcm.size * 2)
            for (i in pcm.indices) { b[2 * i] = pcm[i].toInt().toByte(); b[2 * i + 1] = (pcm[i].toInt() shr 8).toByte() }
            r.write(b)
        }
        tmp.renameTo(f)
    }

    private companion object { const val TAG = "MuseSfx" }

    private class Mix(val rate: Int) {
        var buf = FloatArray(rate)
        fun ensure(n: Int) { if (n > buf.size) buf = buf.copyOf(n) }
    }

    private fun Mix.tone(f1: Double, f2: Double?, dur: Double, type: String = "sine", vol: Double = .12, delay: Double = 0.0) {
        val start = (delay * rate).toInt()
        val n = ((dur + .02) * rate).toInt()
        ensure(start + n)
        var phase = 0.0
        for (i in 0 until n) {
            val t = i.toDouble() / rate
            val f = if (f2 != null && t < dur) f1 * (f2 / f1).pow(t / dur) else (f2 ?: f1)
            phase += f / rate
            val p = phase - floor(phase)
            val s = when (type) {
                "square" -> if (p < .5) 1.0 else -1.0
                "triangle" -> 1 - 4 * kotlin.math.abs(p - .5)
                "sawtooth" -> 2 * p - 1
                else -> sin(2 * PI * p)
            }
            buf[start + i] += (s * env(t, dur, vol)).toFloat()
        }
    }

    /** Exponential attack to [vol] over 8 ms, then exponential decay to silence at [dur]. */
    private fun env(t: Double, dur: Double, vol: Double): Double {
        val lo = 0.0001
        return when {
            t < .008 -> lo * (vol / lo).pow(t / .008)
            t < dur -> vol * (lo / vol).pow((t - .008) / max(1e-4, dur - .008))
            else -> 0.0
        }
    }

    private fun Mix.noise(dur: Double, freq: Double, q: Double = 1.0, vol: Double = .15, delay: Double = 0.0, type: String = "bandpass", sweepTo: Double? = null) {
        val start = (delay * rate).toInt()
        val n = (dur * rate).toInt()
        ensure(start + n)
        val rnd = Random(freq.toInt() * 31 + n)
        var x1 = 0.0; var x2 = 0.0; var y1 = 0.0; var y2 = 0.0
        for (i in 0 until n) {
            val t = i.toDouble() / rate
            val f = (if (sweepTo != null) freq * (sweepTo / freq).pow(t / dur) else freq).coerceAtMost(rate / 2.0 - 100)
            val w0 = 2 * PI * f / rate
            val alpha = sin(w0) / (2 * q)
            val cw = cos(w0)
            val (b0, b1, b2) = when (type) {
                "lowpass" -> Triple((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
                "highpass" -> Triple((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
                else -> Triple(alpha, 0.0, -alpha)
            }
            val a0 = 1 + alpha; val a1 = -2 * cw; val a2 = 1 - alpha
            val x0 = rnd.nextDouble() * 2 - 1
            val y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
            val g = vol * (0.0001 / vol).pow(t / dur)
            buf[start + i] += (y0 * g).toFloat()
        }
    }

    private fun render(theme: String, k: Kind): ShortArray {
        val m = Mix(rate)
        with(m) {
            when (theme) {
                "b" -> when (k) {
                    Kind.TAP -> { noise(.018, 2400.0, 6.0, .16); tone(90.0, 50.0, .05, "sine", .12) }
                    Kind.TICK -> noise(.012, 4200.0, 10.0, .14)
                    Kind.NAV -> { noise(.05, 1500.0, 3.0, .12); noise(.05, 900.0, 3.0, .1, .06) }
                    Kind.GO -> { tone(880.0, null, .08, "square", .05); tone(880.0, null, .08, "square", .05, .14); tone(1320.0, null, .18, "square", .05, .28) }
                    Kind.DONE -> { tone(1046.0, null, .12, "triangle", .08); tone(1568.0, null, .3, "triangle", .07, .12) }
                    Kind.THEME -> { noise(.03, 2000.0, 8.0, .2); noise(.08, 600.0, 2.0, .15, .07) }
                }
                "c" -> when (k) {
                    Kind.TAP -> tone(520.0, 380.0, .09, "sine", .1)
                    Kind.TICK -> tone(900.0, 700.0, .03, "sine", .05)
                    Kind.NAV -> tone(330.0, 440.0, .18, "sine", .06)
                    Kind.GO -> tone(440.0, 660.0, .35, "sine", .08)
                    Kind.DONE -> listOf(392.0, 523.0, 659.0, 784.0).forEachIndexed { i, f -> tone(f, null, 1.1, "sine", .06, i * .1) }
                    Kind.THEME -> tone(262.0, 392.0, .5, "sine", .07)
                }
                "d" -> when (k) {
                    Kind.TAP -> tone(500.0, 1100.0, .08, "triangle", .12)
                    Kind.TICK -> tone(1400.0, 1800.0, .03, "square", .03)
                    Kind.NAV -> tone(300.0, 900.0, .12, "triangle", .08)
                    Kind.GO -> { tone(400.0, 1600.0, .25, "sawtooth", .05); noise(.25, 800.0, .7, .06, 0.0, "bandpass", 4000.0) }
                    Kind.DONE -> { listOf(523.0, 659.0, 784.0, 1046.0).forEachIndexed { i, f -> tone(f, null, .25, "square", .05, i * .08) }; tone(1568.0, 2093.0, .3, "triangle", .06, .34) }
                    Kind.THEME -> { tone(200.0, 1200.0, .3, "triangle", .08); tone(1200.0, 1800.0, .15, "square", .03, .2) }
                }
                else -> when (k) {
                    Kind.TAP -> noise(.035, 3200.0, 2.0, .09)
                    Kind.TICK -> noise(.02, 5000.0, 4.0, .06)
                    Kind.NAV -> noise(.22, 1800.0, .6, .05, 0.0, "bandpass", 600.0)
                    Kind.GO -> { tone(392.0, null, .5, "sine", .08); tone(587.0, null, .6, "sine", .06, .08) }
                    Kind.DONE -> listOf(523.0, 659.0, 784.0).forEachIndexed { i, f -> tone(f, null, .9, "sine", .07, i * .12) }
                    Kind.THEME -> noise(.4, 900.0, .5, .06, 0.0, "bandpass", 3000.0)
                }
            }
        }
        // Normalise: the browser sounds are mixed quietly on purpose; on a phone speaker they need a clear peak.
        val peak = m.buf.maxOf { kotlin.math.abs(it) }.coerceAtLeast(1e-4f)
        val gain = (if (k == Kind.TICK) 0.45f else 0.7f) / peak
        val out = ShortArray(m.buf.size)
        for (i in m.buf.indices) out[i] = (m.buf[i] * gain * 32767).toInt().coerceIn(-32768, 32767).toShort()
        return out
    }
}
