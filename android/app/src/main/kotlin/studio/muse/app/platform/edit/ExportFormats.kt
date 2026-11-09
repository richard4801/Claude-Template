package studio.muse.app.platform.edit

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import studio.muse.core.edit.GifWriter
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/*
 * The Edit suite's other export formats (plans/edit-parity.md, S rows): sound only and GIF. Both start from the edit
 * rendered by the same engine as a video (so the mix, looks, text and captions match the video export exactly), then:
 * the sound track remuxed into an .m4a without re-encoding; or the frames (rendered at the GIF's size and rate) into
 * core's GifWriter.
 */
object ExportFormats {
    /** [mp4]'s audio track copied into [out] (an .m4a); false when it has none. */
    fun soundOnly(mp4: File, out: File): Boolean {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(mp4.absolutePath)
            val track = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true } ?: return false
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val size = if (fmt.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) fmt.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0
            val buf = ByteBuffer.allocate(maxOf(size, 256 * 1024))
            val info = MediaCodec.BufferInfo()
            val mux = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            try {
                val t = mux.addTrack(fmt)
                mux.start()
                while (true) {
                    val n = ex.readSampleData(buf, 0)
                    if (n < 0) break
                    info.set(0, n, ex.sampleTime, if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    mux.writeSampleData(t, buf, info)
                    ex.advance()
                }
                mux.stop()
            } finally { mux.release() }
            return true
        } finally { ex.release() }
    }

    /**
     * [mp4] (rendered at the GIF's size and [fps]) as an animated GIF in [out]; the number of frames. Progress 0..1.
     * Frames by index where the phone can (Android 9+), else by time.
     */
    suspend fun gif(mp4: File, out: File, fps: Int, onProgress: (Float) -> Unit): Int = withContext(Dispatchers.IO) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(mp4.absolutePath)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: error("no video")
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: error("no video")
            val durSec = (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDoubleOrNull() ?: 0.0) / 1000
            val byIndex = Build.VERSION.SDK_INT >= 28
            val count = if (byIndex) r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull() ?: 0 else 0
            val n = if (count > 0) count else maxOf(1, (durSec * fps).roundToInt())
            val px = IntArray(w * h)
            out.outputStream().buffered(1 shl 16).use { o ->
                val g = GifWriter(o, w, h)
                for (i in 0 until n) {
                    ensureActive()
                    val bmp = frame(r, i, fps, count > 0) ?: continue
                    val f = if (bmp.width == w && bmp.height == h) bmp else Bitmap.createScaledBitmap(bmp, w, h, true)
                    f.getPixels(px, 0, w, 0, 0, w, h)
                    if (f !== bmp) f.recycle()
                    bmp.recycle()
                    // 15 fps → 7, 7, 6 hundredths: the delays add up to the real length.
                    g.add(px, ((i + 1) * 100.0 / fps).roundToInt() - (i * 100.0 / fps).roundToInt())
                    onProgress((i + 1f) / n)
                }
                g.finish()
                g.frameCount
            }
        } finally { r.release() }
    }

    private fun frame(r: MediaMetadataRetriever, i: Int, fps: Int, byIndex: Boolean): Bitmap? =
        if (byIndex && Build.VERSION.SDK_INT >= 28) {
            r.getFrameAtIndex(i, MediaMetadataRetriever.BitmapParams().apply { preferredConfig = Bitmap.Config.ARGB_8888 })
        } else r.getFrameAtTime((i * 1_000_000L) / fps, MediaMetadataRetriever.OPTION_CLOSEST)?.let { if (it.config == Bitmap.Config.ARGB_8888) it else it.copy(Bitmap.Config.ARGB_8888, false) }
}
