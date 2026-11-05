package studio.muse.app.platform

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.SpeedParameters
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import studio.muse.app.data.EditedVideo
import studio.muse.core.VideoEdit
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.roundToInt

/** What the editor needs to know about a video file (display size: rotation already applied). */
data class SourceInfo(val durationSec: Double, val width: Int, val height: Int, val fps: Double, val hasAudio: Boolean, val bitrate: Int)

/**
 * How one kept segment is exported (pure, so it is unit-tested): the clip in milliseconds of the source, its speed
 * (audio time-stretched, pitch kept), whether its sound is removed (silence is generated in its place), and the frame
 * rate faster parts are thinned back to.
 */
data class ExportItem(val startMs: Long, val endMs: Long, val speed: Float, val removeAudio: Boolean, val dropToFps: Float?)
data class ExportPlan(val items: List<ExportItem>, val withAudio: Boolean, val bitrate: Int, val expectedSec: Double)

fun exportPlan(edit: VideoEdit, info: SourceInfo): ExportPlan {
    val withAudio = info.hasAudio && !edit.mute && edit.segments.indices.any { !edit.silent(it) }
    val items = edit.segments.mapIndexed { i, s ->
        ExportItem(
            startMs = Math.round(s.inSec * 1000), endMs = Math.round(s.outSec * 1000), speed = s.speed.toFloat(),
            removeAudio = !withAudio || edit.silent(i),
            dropToFps = if (s.speed > 1.0 && info.fps > 0) info.fps.toFloat() else null,
        )
    }
    // Keep the source's quality: its own bitrate, 2-40 Mbit/s.
    return ExportPlan(items, withAudio, info.bitrate.coerceIn(2_000_000, 40_000_000), edit.outputSec)
}

/**
 * The on-device half of the video editor (plans/video-editor.md): fetches the source once, reads its size, frame rate
 * and sound, grabs timeline frames, and exports an edit with Media3 Transformer (H.264 + AAC, the source's resolution
 * and frame rate, hardware encoder with fallback). Nothing is encoded on the server.
 */
@OptIn(UnstableApi::class)
class VideoEditEngine(private val context: Context) {
    private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(2, TimeUnit.MINUTES).build()
    private val srcDir get() = File(context.cacheDir, "edit-src").apply { mkdirs() }
    private val outDir get() = File(context.cacheDir, "edit-out").apply { mkdirs() }

    /** The source video on disk (downloaded once per take URL; the newest 4 are kept). */
    suspend fun fetchSource(url: String, onProgress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        if (url.startsWith("file:") || url.startsWith("/")) return@withContext File(url.removePrefix("file://"))
        val key = MessageDigest.getInstance("SHA-1").digest(url.substringBefore('?').toByteArray()).joinToString("") { "%02x".format(it) }
        val f = File(srcDir, "$key.mp4")
        if (f.length() > 0) { f.setLastModified(System.currentTimeMillis()); return@withContext f }
        val part = File(srcDir, "$key.part")
        http.newCall(Request.Builder().url(url).build()).execute().use { r ->
            if (!r.isSuccessful) throw java.io.IOException("download failed (${r.code})")
            val body = r.body
            val total = body.contentLength().takeIf { it > 0 }
            var got = 0L
            part.outputStream().use { out ->
                body.byteStream().use { input ->
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        if (!isActive) throw kotlinx.coroutines.CancellationException()
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n); got += n
                        total?.let { onProgress((got.toFloat() / it).coerceAtMost(1f)) }
                    }
                }
            }
        }
        part.renameTo(f)
        srcDir.listFiles { x -> x.extension == "mp4" }?.sortedByDescending { it.lastModified() }?.drop(4)?.forEach { it.delete() }
        f
    }

    fun probe(file: File): SourceInfo {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.absolutePath)
            var w = 0; var h = 0; var fps = 30.0; var rot = 0; var audio = false; var durUs = 0L; var br = 0
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (f.containsKey(MediaFormat.KEY_DURATION)) durUs = maxOf(durUs, f.getLong(MediaFormat.KEY_DURATION))
                if (mime.startsWith("video/") && w == 0) {
                    w = f.getInteger(MediaFormat.KEY_WIDTH); h = f.getInteger(MediaFormat.KEY_HEIGHT)
                    if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) fps = runCatching { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }.getOrElse { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
                    if (f.containsKey(MediaFormat.KEY_ROTATION)) rot = f.getInteger(MediaFormat.KEY_ROTATION)
                    if (f.containsKey(MediaFormat.KEY_BIT_RATE)) br = f.getInteger(MediaFormat.KEY_BIT_RATE)
                } else if (mime.startsWith("audio/")) audio = true
            }
            val dur = durUs / 1_000_000.0
            if (br <= 0 && dur > 0) br = (file.length() * 8 / dur).toInt()
            val swap = rot == 90 || rot == 270
            return SourceInfo(dur, if (swap) h else w, if (swap) w else h, fps, audio, br)
        } finally { ex.release() }
    }

    /** Frames for the timeline strip, [heightPx] tall. */
    suspend fun frames(file: File, times: List<Double>, heightPx: Int): List<Bitmap?> = withContext(Dispatchers.IO) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.absolutePath)
            times.map { t -> runCatching { frame(r, t, heightPx) }.getOrNull() }
        } finally { r.release() }
    }

    private fun frame(r: MediaMetadataRetriever, t: Double, heightPx: Int): Bitmap? {
        val us = (t * 1_000_000).toLong()
        val full = r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return null
        val w = (full.width * heightPx / full.height.toFloat()).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(full, w, heightPx, true).also { if (it !== full) full.recycle() }
    }

    /**
     * Exports [edit] of [source]. Progress 0..1; cancelling the coroutine cancels Transformer and deletes the half-made
     * file. Returns the MP4 with its real length, size and a JPEG frame for the thumbnail.
     */
    suspend fun export(source: File, info: SourceInfo, edit: VideoEdit, onProgress: (Float) -> Unit): EditedVideo {
        val plan = exportPlan(edit, info)
        val out = File(outDir, "edit_${System.currentTimeMillis()}.mp4")
        outDir.listFiles()?.filter { it != out && System.currentTimeMillis() - it.lastModified() > 3_600_000 }?.forEach { it.delete() }
        try {
            withContext(Dispatchers.Main) { runTransformer(source, plan, out, onProgress) }
            val got = probe(out)
            return EditedVideo(out, thumbnail(out, got.durationSec), got.durationSec, got.width, got.height, got.fps.takeIf { it > 0 })
        } catch (e: Throwable) {
            out.delete()
            throw e
        }
    }

    private suspend fun runTransformer(source: File, plan: ExportPlan, out: File, onProgress: (Float) -> Unit) = coroutineScope {
        val uri = android.net.Uri.fromFile(source)
        val items = plan.items.map { p ->
            val mi = MediaItem.Builder().setUri(uri)
                .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionMs(p.startMs).setEndPositionMs(p.endMs).build())
                .build()
            EditedMediaItem.Builder(mi).apply {
                if (p.speed != 1f) setSpeed(SpeedParameters(ConstantSpeed(p.speed), /* shouldMaintainPitch = */ true))
                if (p.removeAudio) setRemoveAudio(true)
                val fx = listOfNotNull<Effect>(p.dropToFps?.let { FrameDropEffect.createDefaultFrameDropEffect(it) })
                if (fx.isNotEmpty()) setEffects(Effects(emptyList(), fx))
            }.build()
        }
        val tracks = if (plan.withAudio) setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO) else setOf(C.TRACK_TYPE_VIDEO)
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(tracks).addItems(items).build()).build()
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(plan.bitrate).build())
            .setEnableFallback(true) // a phone that can't encode the full size gets the nearest size it can
            .build()
        val transformer = Transformer.Builder(context)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
            .build()
        val poll = launch {
            val holder = ProgressHolder()
            while (isActive) {
                if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(holder.progress / 100f)
                delay(200)
            }
        }
        try {
            suspendCancellableCoroutine { cont ->
                transformer.addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) { if (cont.isActive) cont.resume(Unit) }
                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        if (cont.isActive) cont.resumeWithException(exportException)
                    }
                })
                cont.invokeOnCancellation { runCatching { transformer.cancel() } }
                transformer.start(composition, out.absolutePath)
            }
            onProgress(1f)
        } finally { poll.cancel() }
    }

    /** A JPEG of the output (≤ 720 px on the long side), for the new version's thumbnail. */
    private suspend fun thumbnail(file: File, durationSec: Double): ByteArray? = withContext(Dispatchers.IO) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.absolutePath)
            val f = r.getFrameAtTime((minOf(0.5, durationSec / 2) * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: return@withContext null
            val k = 720f / maxOf(f.width, f.height)
            val s = if (k < 1f) Bitmap.createScaledBitmap(f, (f.width * k).roundToInt(), (f.height * k).roundToInt(), true) else f
            ByteArrayOutputStream().use { o -> s.compress(Bitmap.CompressFormat.JPEG, 85, o); o.toByteArray() }
        } catch (_: Exception) { null } finally { r.release() }
    }

    private class ConstantSpeed(private val speed: Float) : SpeedProvider {
        override fun getSpeed(timeUs: Long) = speed
        override fun getNextSpeedChangeTimeUs(timeUs: Long) = C.TIME_UNSET
    }

    companion object {
        /** True on Android versions Transformer exports on (API 21+; the app's minimum is 26). */
        val supported: Boolean get() = Build.VERSION.SDK_INT >= 26
    }
}
