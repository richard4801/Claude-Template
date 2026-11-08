package studio.muse.app.ui.screens.claude

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream

/** Images for Claude (plans/claude-chat-android.md): HEIC and WebP go as JPEG, as on the Mac; "Send as JPEG" converts any. */
object ChatImages {
    const val MAX_BYTES = 10 * 1024 * 1024
    /** Formats converted before upload. */
    val CONVERT = setOf("image/heic", "image/heif", "image/webp")
    /** Long edge after conversion: the server scales to 2048 anyway, so this keeps detail and stays well under 10 MB. */
    private const val MAX_EDGE = 4096

    /** [bytes] decoded and re-encoded as JPEG (quality 92), long edge ≤ 4096 px; null when the phone can't decode them. */
    fun toJpeg(bytes: ByteArray): ByteArray? {
        val bmp = decode(bytes) ?: return null
        return try {
            ByteArrayOutputStream().use { out -> bmp.compress(Bitmap.CompressFormat.JPEG, 92, out); out.toByteArray() }
        } finally { bmp.recycle() }
    }

    /** Android 9+: ImageDecoder, which turns the photo upright from its EXIF; older phones: BitmapFactory. */
    private fun decode(bytes: ByteArray): Bitmap? {
        if (android.os.Build.VERSION.SDK_INT >= 28) runCatching {
            return android.graphics.ImageDecoder.decodeBitmap(android.graphics.ImageDecoder.createSource(java.nio.ByteBuffer.wrap(bytes))) { d, info, _ ->
                val edge = maxOf(info.size.width, info.size.height)
                if (edge > MAX_EDGE) { val k = MAX_EDGE.toFloat() / edge; d.setTargetSize((info.size.width * k).toInt(), (info.size.height * k).toInt()) }
                d.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_EDGE) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
