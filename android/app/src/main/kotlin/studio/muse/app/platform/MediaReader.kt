package studio.muse.app.platform

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import studio.muse.app.data.ClipMeta
import java.io.ByteArrayOutputStream
import java.io.File

/** Reads what the Android Photo Picker hands back: image bytes, and a clip's real duration, size and frame rate. */
class MediaReader(private val context: Context) {
    suspend fun bytes(uri: Uri): ByteArray? = withContext(Dispatchers.IO) {
        runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
    }

    fun mime(uri: Uri): String = context.contentResolver.getType(uri) ?: "image/jpeg"

    fun displayName(uri: Uri): String = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    }.getOrNull() ?: uri.lastPathSegment ?: "clip"

    /** Duration/resolution/fps from the file. People and watermark detection happen server-side. */
    suspend fun clipMeta(uri: Uri): ClipMeta = withContext(Dispatchers.IO) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, uri)
            val dur = (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) / 1000.0
            var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
            val frames = if (Build.VERSION.SDK_INT >= 28) r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toIntOrNull() else null
            val fps = if (frames != null && dur > 0) Math.round(frames / dur).toInt() else 30
            ClipMeta(displayName(uri).substringBeforeLast('.'), dur, w, h, fps)
        } finally {
            runCatching { r.release() }
        }
    }

    /** A frame from the picked clip for its thumbnail (the user's own footage). Saved as a JPEG file URI. */
    suspend fun clipThumb(uri: Uri): String? = withContext(Dispatchers.IO) {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, uri)
            val bmp = r.getFrameAtTime(500_000) ?: return@withContext null
            val f = File(context.cacheDir, "clip_${uri.hashCode()}.jpg")
            ByteArrayOutputStream().use { out -> bmp.compress(Bitmap.CompressFormat.JPEG, 82, out); f.writeBytes(out.toByteArray()) }
            f.toURI().toString()
        } catch (e: Exception) {
            null
        } finally {
            runCatching { r.release() }
        }
    }
}
