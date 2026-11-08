package studio.muse.app.platform.edit

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import studio.muse.app.ui.screens.edit.Peaks
import java.io.File
import java.nio.ByteOrder

/**
 * The timeline's waveforms: decodes a file's first audio track to PCM on the phone (MediaExtractor + MediaCodec) and
 * keeps the peak of every 1/50 s. Null when the file has no sound or the phone can't decode it (the lane then shows a
 * flat line, never invented levels).
 */
object WaveformDecoder {
    suspend fun peaks(file: File, perSec: Float = 50f): Peaks? = withContext(Dispatchers.IO) {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(file.absolutePath)
            val track = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true } ?: return@withContext null
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val mime = fmt.getString(MediaFormat.KEY_MIME) ?: return@withContext null
            val c = MediaCodec.createDecoderByType(mime)
            codec = c
            c.configure(fmt, null, null, 0)
            c.start()
            var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var float = false
            var builder = Peaks.Companion.Builder(rate, channels, perSec)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var shorts = ShortArray(0)
            while (true) {
                ensureActive()
                if (!inputDone) {
                    val i = c.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = c.getInputBuffer(i)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) { c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { c.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                }
                val o = c.dequeueOutputBuffer(info, 10_000)
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = c.outputFormat
                        rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE); channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        float = f.containsKey(MediaFormat.KEY_PCM_ENCODING) && f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                        builder = Peaks.Companion.Builder(rate, channels, perSec)
                    }
                    o >= 0 -> {
                        val buf = c.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
                        buf.position(info.offset); buf.limit(info.offset + info.size)
                        if (float) {
                            val fb = buf.asFloatBuffer()
                            if (shorts.size < fb.remaining()) shorts = ShortArray(fb.remaining())
                            val n = fb.remaining()
                            for (k in 0 until n) shorts[k] = (fb.get().coerceIn(-1f, 1f) * 32767f).toInt().toShort()
                            builder.add(shorts, n)
                        } else {
                            val sb = buf.asShortBuffer()
                            val n = sb.remaining()
                            if (shorts.size < n) shorts = ShortArray(n)
                            sb.get(shorts, 0, n)
                            builder.add(shorts, n)
                        }
                        c.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                }
            }
            builder.build().takeIf { it.values.isNotEmpty() }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e
        } catch (e: Exception) { null
        } finally {
            runCatching { codec?.stop() }; runCatching { codec?.release() }; ex.release()
        }
    }
}
