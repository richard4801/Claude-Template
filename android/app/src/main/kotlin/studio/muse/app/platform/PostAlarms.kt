package studio.muse.app.platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import studio.muse.app.data.Post

/**
 * Stage 1 scheduling: a local alarm at the post's time shows a notification that opens the handoff.
 * Inexact (setAndAllowWhileIdle), so it may arrive a few minutes late; no exact-alarm permission needed.
 * Alarms don't survive a reboot; stage 2 moves scheduling to the server.
 */
class PostAlarms(private val context: Context) {
    companion object {
        const val EXTRA_POST = "muse.post"
        const val EXTRA_TITLE = "muse.post.title"
        const val EXTRA_PLATFORMS = "muse.post.platforms"
    }

    private fun pending(post: Post, create: Boolean): PendingIntent? {
        val i = Intent(context, PostAlarmReceiver::class.java).apply {
            putExtra(EXTRA_POST, post.id); putExtra(EXTRA_TITLE, post.title); putExtra(EXTRA_PLATFORMS, post.platforms.joinToString(","))
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE
        return PendingIntent.getBroadcast(context, post.id.hashCode(), i, flags)
    }

    fun schedule(post: Post) {
        val at = post.whenMillis ?: return
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val pi = pending(post, true) ?: return
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
    }

    fun cancel(post: Post) {
        val pi = pending(post, false) ?: return
        context.getSystemService(AlarmManager::class.java)?.cancel(pi)
        pi.cancel()
    }
}

class PostAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(PostAlarms.EXTRA_POST) ?: return
        Notifier(context).postDue(id, intent.getStringExtra(PostAlarms.EXTRA_TITLE).orEmpty(), intent.getStringExtra(PostAlarms.EXTRA_PLATFORMS).orEmpty().split(",").filter { it.isNotBlank() })
    }
}
