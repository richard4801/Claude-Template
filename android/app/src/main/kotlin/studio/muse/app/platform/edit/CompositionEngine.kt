package studio.muse.app.platform.edit

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.SpeedParameters
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Crop
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.MultipleInputVideoGraph
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.CompositionPlayer
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
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import studio.muse.app.data.EditedVideo
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.AudioLane
import studio.muse.core.edit.ClipEntry
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.Gap
import studio.muse.core.edit.LayerRole
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.PlannedClip
import studio.muse.core.edit.RenderPlan
import studio.muse.core.edit.StillEntry
import studio.muse.core.edit.VideoLayer
import studio.muse.core.edit.planRender
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.roundToInt

/**
 * The Editor v2 composition engine (plans/video-editor.md "Editor v2"): renders a v2 project on the device with Media3
 * 1.11 Transformer — H.264 + AAC MP4 at the canvas size and fps, progress 0..1, coroutine cancel (deletes the
 * half-made file), hardware encoder with fallback, a JPEG thumbnail — and builds a [CompositionPlayer] preview from the
 * same composition. Nothing is encoded on the server.
 *
 * All decisions live in the pure planner (studio.muse.core.edit.planRender, unit-tested on the JVM); this class only
 * translates its [RenderPlan] into Media3 objects:
 *  - each plan layer → an EditedMediaItemSequence (gaps via `addGap`, stills as image items at the canvas fps), all
 *    composited by [PlanCompositorSettings] (per-frame alpha/position/scale/rotation from the plan);
 *  - each clip → clipping + `SpeedParameters(…, shouldMaintainPitch = true)` + FrameDropEffect when faster (like v1),
 *    Crop → Presentation (texture size) → [ChromaKeyEffect] → [ColorMatrixEffect], and its sound through an
 *    [EnvelopeAudioProcessor];
 *  - each audio lane → an audio-only sequence;
 *  - text, captions and black/white flashes → one composition-level OverlayEffect ([EditOverlay]).
 *
 * Media3 gaps and workarounds (1.11.1, checked against its sources):
 *  - Composition can't crossfade inside a sequence → A/B roll over two main sequences (the planner).
 *  - DefaultVideoCompositor draws its primary input (the first one registered) on top, times the output by it, and
 *    stalls when an input runs out → a transparent "clock" image sequence is sequence 0 and every sequence is padded
 *    to the full duration. In Transformer sequence 0 always registers first (TransformerInternal only lets the other
 *    sequences get a GraphInput after sequence 0 has created the video exporter and registered); in
 *    CompositionPlayer registration follows renderer start-up, so the preview's layer order needs a device check.
 *  - Video gaps render black frames → layers are given alpha 0 where they have no item.
 *  - StaticOverlaySettings rejects anchors outside −1…1 → [LayerOverlaySettings] implements OverlaySettings directly.
 *  - GainProcessor wraps 16-bit samples above gain 1 → our own clamping [EnvelopeAudioProcessor].
 *  - No background-colour setting in the compositor → a canvas-size solid image as the bottom layer (non-black only).
 *  - Overlay effects are composition-wide, so text/captions/flashes draw over every video layer, including PiP tracks
 *    that come after the text track (the contract's track order is kept among video/image layers).
 * Needs a real device to confirm: per-frame timestamps seen by the compositor/overlays are the composition timeline's
 * (presentation time of the output), the AudioProcessor flush offset on preview seeks, rotation of portrait sources
 * before Crop, and encoder fallback at 2K/4K canvases.
 */
@OptIn(UnstableApi::class, ExperimentalApi::class)
class EditCompositionEngine(private val context: Context) {
    private val outDir get() = File(context.cacheDir, "edit2-out").apply { mkdirs() }
    private val stillDir get() = File(context.cacheDir, "edit2-still").apply { mkdirs() }

    /** File facts the planner needs (display size: rotation applied). */
    fun probe(file: File, kind: AssetKind): MediaInfo {
        if (kind == AssetKind.IMAGE) {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, o)
            return MediaInfo(0.0, maxOf(1, o.outWidth), maxOf(1, o.outHeight))
        }
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.absolutePath)
            var w = 0; var h = 0; var fps = 0.0; var rot = 0; var audio = false; var durUs = 0L
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (f.containsKey(MediaFormat.KEY_DURATION)) durUs = maxOf(durUs, f.getLong(MediaFormat.KEY_DURATION))
                if (mime.startsWith("video/") && w == 0) {
                    w = f.getInteger(MediaFormat.KEY_WIDTH); h = f.getInteger(MediaFormat.KEY_HEIGHT)
                    if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) fps = runCatching { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }.getOrElse { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
                    if (f.containsKey(MediaFormat.KEY_ROTATION)) rot = f.getInteger(MediaFormat.KEY_ROTATION)
                } else if (mime.startsWith("audio/")) audio = true
            }
            val swap = rot == 90 || rot == 270
            return MediaInfo(durUs / 1_000_000.0, if (swap) h else w, if (swap) w else h, fps, audio)
        } finally { ex.release() }
    }

    /** The plan for [project] with its asset files probed ([files]: asset id → local file). */
    fun plan(project: EditProject, files: Map<String, File>): RenderPlan =
        planRender(project, project.assets.filter { it.id in files }.associate { it.id to probe(files.getValue(it.id), it.kind) })

    /** The Media3 composition for [plan] (also what the preview plays). */
    fun composition(plan: RenderPlan, files: Map<String, File>): Composition {
        val sequences = plan.layers.map { layerSequence(plan, it, files) } + plan.audioLanes.map { audioSequence(it, files) }
        val overlay = EditOverlay(plan)
        return Composition.Builder(sequences)
            .setVideoCompositorSettings(PlanCompositorSettings(plan))
            .apply { if (overlay.isNeeded) setEffects(Effects(emptyList(), listOf<Effect>(OverlayEffect(listOf(overlay))))) }
            .build()
    }

    /**
     * A preview player for [plan] (experimental Media3 API). Multi-sequence compositions need the multiple-input video
     * graph; attach a SurfaceView/TextureView with the Player methods and call prepare()/play().
     */
    fun previewPlayer(plan: RenderPlan, files: Map<String, File>, looper: Looper = Looper.getMainLooper()): CompositionPlayer =
        CompositionPlayer.Builder(context).setLooper(looper).setVideoGraphFactory(MultipleInputVideoGraph.Factory()).build()
            .also { it.setComposition(composition(plan, files)) }

    /**
     * Renders [plan] to an MP4. Progress 0..1; cancelling the coroutine cancels Transformer and deletes the half-made
     * file. Returns the file with its real length, size (the encoder may have fallen back to a smaller one) and a
     * JPEG frame for the thumbnail.
     */
    suspend fun export(plan: RenderPlan, files: Map<String, File>, onProgress: (Float) -> Unit): EditedVideo {
        val out = File(outDir, "edit_${System.currentTimeMillis()}.mp4")
        outDir.listFiles()?.filter { it != out && System.currentTimeMillis() - it.lastModified() > 3_600_000 }?.forEach { it.delete() }
        try {
            withContext(Dispatchers.Main) { runTransformer(composition(plan, files), plan, out, onProgress) }
            val got = probe(out, AssetKind.VIDEO)
            return EditedVideo(out, thumbnail(out, got.durationSec), got.durationSec, got.width, got.height, got.fps.takeIf { it > 0 })
        } catch (e: Throwable) {
            out.delete()
            throw e
        }
    }

    // ------------------------------------------------------------------ plan → Media3
    private fun layerSequence(plan: RenderPlan, layer: VideoLayer, files: Map<String, File>): EditedMediaItemSequence {
        val types = if (layer.withAudio) setOf(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO) else setOf(C.TRACK_TYPE_VIDEO)
        val b = EditedMediaItemSequence.Builder(types)
        for (e in layer.entries) when (e) {
            is Gap -> b.addGap(e.durationUs)
            is StillEntry -> b.addItem(still(plan, e, layer.role))
            is ClipEntry -> b.addItem(clipItem(plan, e.clip, files))
        }
        return b.build()
    }

    private fun audioSequence(lane: AudioLane, files: Map<String, File>): EditedMediaItemSequence {
        val b = EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
        for (e in lane.entries) when (e) {
            is Gap -> b.addGap(e.durationUs)
            is ClipEntry -> b.addItem(mediaClip(e.clip, files, video = false))
            is StillEntry -> {}
        }
        return b.build()
    }

    /** The clock (transparent, input 0) or the background colour, as an image held for the whole duration. */
    private fun still(plan: RenderPlan, e: StillEntry, role: LayerRole): EditedMediaItem {
        val transparent = e.argb == 0 || role == LayerRole.CLOCK
        val (w, h) = if (transparent) 16 to 16 else plan.width to plan.height
        val f = File(stillDir, "still_${Integer.toHexString(e.argb)}_${w}x$h.png")
        if (f.length() == 0L) {
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { eraseColor(if (transparent) 0 else e.argb) }
            f.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bmp.recycle()
        }
        return image(Uri.fromFile(f), e.durationUs, plan.fps, emptyList())
    }

    private fun image(uri: Uri, durationUs: Long, fps: Double, effects: List<Effect>): EditedMediaItem {
        val mi = MediaItem.Builder().setUri(uri).setImageDurationMs(maxOf(1L, durationUs / 1000)).build()
        return EditedMediaItem.Builder(mi).setDurationUs(maxOf(1L, durationUs)).setFrameRate(maxOf(1, fps.roundToInt()))
            .apply { if (effects.isNotEmpty()) setEffects(Effects(emptyList(), effects)) }.build()
    }

    private fun clipItem(plan: RenderPlan, c: PlannedClip, files: Map<String, File>): EditedMediaItem {
        if (!c.isImage) return mediaClip(c, files, video = true)
        return image(Uri.fromFile(file(files, c.assetId)), c.durationUs, plan.fps, videoEffects(c))
    }

    private fun mediaClip(c: PlannedClip, files: Map<String, File>, video: Boolean): EditedMediaItem {
        val mi = MediaItem.Builder().setUri(Uri.fromFile(file(files, c.assetId)))
            .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionUs(c.clipStartUs).setEndPositionUs(c.clipEndUs).build())
            .build()
        val audio = if (c.withAudio) listOf<AudioProcessor>(EnvelopeAudioProcessor(c.startUs / 1_000_000.0, c.envelope)) else emptyList()
        val fx = if (video && !c.removeVideo) videoEffects(c) else emptyList()
        return EditedMediaItem.Builder(mi).apply {
            if (c.speed != 1.0) setSpeed(SpeedParameters(ConstantSpeed(c.speed.toFloat()), /* shouldMaintainPitch = */ true))
            if (!c.withAudio) setRemoveAudio(true)
            if (c.removeVideo || !video) setRemoveVideo(true)
            if (audio.isNotEmpty() || fx.isNotEmpty()) setEffects(Effects(audio, fx))
        }.build()
    }

    private fun videoEffects(c: PlannedClip): List<Effect> {
        val look = c.look ?: return emptyList()
        return buildList {
            c.frameDropFps?.let { add(FrameDropEffect.createDefaultFrameDropEffect(it.toFloat())) }
            look.crop?.let { add(Crop(it.left.toFloat(), it.right.toFloat(), it.bottom.toFloat(), it.top.toFloat())) }
            add(Presentation.createForWidthAndHeight(look.textureWidth, look.textureHeight, Presentation.LAYOUT_STRETCH_TO_FIT))
            look.chroma?.let { add(ChromaKeyEffect(it)) }
            look.colorMatrix?.let { add(ColorMatrixEffect(it)) }
        }
    }

    private val PlannedClip.durationUs: Long get() = endUs - startUs

    private fun file(files: Map<String, File>, assetId: String): File = files[assetId] ?: throw IllegalArgumentException("no file for asset $assetId")

    private suspend fun runTransformer(composition: Composition, plan: RenderPlan, out: File, onProgress: (Float) -> Unit) = coroutineScope {
        // Bitrate for the canvas: ~0.12 bit per pixel per frame, 4–40 Mbit/s.
        val bitrate = (plan.width.toDouble() * plan.height * plan.fps * 0.12).toInt().coerceIn(4_000_000, 40_000_000)
        val encoders = DefaultEncoderFactory.Builder(context)
            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate).build())
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
}
