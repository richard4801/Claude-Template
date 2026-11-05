package studio.muse.app.platform

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment

/** Result → Download: saves a finished photo or video to the phone's Downloads (Android 10+), else opens it to save from there. */
object Downloads {
    /** A file name from the take's title: "Living-room dance.mp4". */
    fun fileName(title: String, url: String): String {
        val ext = url.substringBefore('?').substringAfterLast('.', "").lowercase().takeIf { it in setOf("mp4", "mov", "jpg", "jpeg", "png", "webp") } ?: "mp4"
        val base = title.replace(Regex("[^A-Za-z0-9 ._-]"), "").trim().ifBlank { "MUSE" }.take(60)
        return "$base.$ext"
    }

    /** Starts the download and returns the toast to show. */
    fun save(context: Context, url: String, title: String): String = runCatching {
        val name = fileName(title, url)
        if (Build.VERSION.SDK_INT >= 29) {
            val dm = context.getSystemService(DownloadManager::class.java) ?: error("no download manager")
            dm.enqueue(
                DownloadManager.Request(Uri.parse(url)).setTitle(name)
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "MUSE/$name"),
            )
            "Downloading · $name"
        } else {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "Opened · save it from there"
        }
    }.getOrElse { "Couldn't download this one · try again" }
}
