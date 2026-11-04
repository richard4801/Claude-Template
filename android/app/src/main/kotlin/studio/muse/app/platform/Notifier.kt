package studio.muse.app.platform

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import studio.muse.app.MainActivity
import studio.muse.app.R
import studio.muse.app.data.Job
import studio.muse.core.Pricing

/** Local "push" notification when a mock render finishes or fails. Needs POST_NOTIFICATIONS on Android 13+. */
class Notifier(private val context: Context) {
    companion object {
        const val CHANNEL = "renders_v2" // v2: IMPORTANCE_HIGH (a channel's importance can't be raised after it exists)
        const val EXTRA_ROUTE = "muse.route"
        /** Open the post handoff for this post id (scheduled post notification). */
        const val EXTRA_HANDOFF = "muse.handoff"
        const val CHANNEL_POSTS = "posts"
    }

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm?.deleteNotificationChannel("renders") // the old, quieter channel
            val ch = NotificationChannel(CHANNEL, context.getString(R.string.channel_renders), NotificationManager.IMPORTANCE_HIGH)
            ch.description = context.getString(R.string.channel_renders_desc)
            ch.enableVibration(true)
            nm?.createNotificationChannel(ch)
            val posts = NotificationChannel(CHANNEL_POSTS, context.getString(R.string.channel_posts), NotificationManager.IMPORTANCE_HIGH)
            posts.description = context.getString(R.string.channel_posts_desc)
            nm?.createNotificationChannel(posts)
        }
    }

    fun canPost(): Boolean = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun jobFinished(job: Job) {
        if (!canPost()) return
        val route = if (job.done) "result/${job.id}" else "queue"
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_ROUTE, route)
        }
        val pi = PendingIntent.getActivity(context, job.id.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val (title, text) = if (job.done) "Render done · ${job.title}" to "${job.engineLabel} · ${Pricing.money(job.cost)} · tap to watch"
        else "Render failed · ${job.title}" to "${job.error ?: "The GPU disconnected."} ${Pricing.money(job.refunded)} refunded."
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_muse)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(job.id.hashCode(), n) }
    }

    private fun open(route: String, code: Int, handoff: String? = null): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_ROUTE, route)
            handoff?.let { putExtra(EXTRA_HANDOFF, it) }
        }
        return PendingIntent.getActivity(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun show(channel: String, id: Int, title: String, text: String, pi: PendingIntent) {
        if (!canPost()) return
        val n = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_muse)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id, n) }
    }

    /** Identity LoRA training finished. */
    fun loraReady(modelName: String, version: Int) =
        show(CHANNEL, "lora_$modelName".hashCode(), "Identity LoRA v$version is ready", "$modelName's face and physique are locked in for new photos and videos.", open("lora", "lora".hashCode()))

    /** A scheduled post's time has come: tapping opens the handoff (each app with the caption ready). */
    fun postDue(postId: String, title: String, platforms: List<String>) {
        val names = platforms.mapNotNull { studio.muse.app.data.Platform.of(it)?.label }.joinToString(", ").ifEmpty { "your accounts" }
        show(CHANNEL_POSTS, postId.hashCode(), "Time to post · $title", "Tap to open $names with the video and caption ready.", open("posts", postId.hashCode(), postId))
    }
}
