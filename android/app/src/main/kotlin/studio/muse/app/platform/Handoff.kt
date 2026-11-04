package studio.muse.app.platform

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.core.content.FileProvider
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Platform
import studio.muse.app.ui.components.assetRes
import java.io.File

/**
 * Stage 1 posting (plans/socials.md): MUSE hands the video and caption to the platform's own app, and the user taps Post there.
 * - The caption goes on the clipboard (most apps ignore EXTRA_TEXT for video posts).
 * - ACTION_SEND goes straight to the platform's package when it's installed, otherwise through the system chooser.
 * - The mock has no real video file, so it shares the take's still as a placeholder (or text only when there's none).
 */
object Handoff {
    data class Result(val targeted: Boolean, val message: String)

    fun installedPackage(context: Context, p: Platform): String? = p.androidPackages.firstOrNull { pkg ->
        runCatching { context.packageManager.getPackageInfo(pkg, 0); true }.getOrDefault(false)
    }

    fun copyCaption(context: Context, caption: String) {
        if (caption.isBlank()) return
        runCatching { context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Caption", caption)) }
    }

    /** Builds the ACTION_SEND intent. [video] is the real render once there is one; [placeholder] a still to share in its place. */
    fun sendIntent(caption: String, video: Uri?, placeholder: Uri?, pkg: String?): Intent = Intent(Intent.ACTION_SEND).apply {
        val stream = video ?: placeholder
        type = when { video != null -> "video/mp4"; placeholder != null -> "image/jpeg"; else -> "text/plain" }
        putExtra(Intent.EXTRA_TEXT, caption)
        if (stream != null) {
            putExtra(Intent.EXTRA_STREAM, stream)
            clipData = ClipData.newRawUri("", stream)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (pkg != null) setPackage(pkg)
    }

    /** Copies the caption and opens [platform] (or the chooser). Call from an Activity context. */
    fun open(context: Context, platform: Platform, caption: String, thumb: ImageRef?, video: Uri? = null): Result {
        copyCaption(context, caption)
        val placeholder = if (video == null) placeholderUri(context, thumb) else null
        val pkg = installedPackage(context, platform)
        val send = sendIntent(caption, video, placeholder, pkg)
        val launch = if (pkg != null) send else Intent.createChooser(send, "Post to ${platform.label}")
        if (context !is android.app.Activity) launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(launch)
            Result(pkg != null, if (pkg != null) "Opening ${platform.label} · caption copied" else "${platform.label} isn't installed · pick an app · caption copied")
        } catch (e: ActivityNotFoundException) {
            Result(false, "No app can take this post · caption copied")
        } catch (e: SecurityException) {
            Result(false, "Couldn't open ${platform.label} · caption copied")
        }
    }

    /** Writes the bundled still to cache/share and returns a content:// URI for it. */
    private fun placeholderUri(context: Context, thumb: ImageRef?): Uri? = runCatching {
        val res = assetRes(thumb?.asset) ?: return null
        val dir = File(context.cacheDir, "share").apply { mkdirs() }
        val f = File(dir, "muse_${thumb!!.asset}.jpg")
        if (!f.exists()) {
            val bmp = BitmapFactory.decodeResource(context.resources, res) ?: return null
            f.outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, it) }
        }
        FileProvider.getUriForFile(context, context.packageName + ".share", f)
    }.getOrNull()
}
