package studio.muse.app.platform

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import studio.muse.app.MainActivity
import studio.muse.app.R
import studio.muse.app.data.Job
import studio.muse.app.ui.screens.failLine
import studio.muse.core.Pricing

/**
 * Local notifications: a render finished or failed, an Identity LoRA is ready, or it's time to post. Needs
 * POST_NOTIFICATIONS on Android 13+.
 *
 * These are the only sounds MUSE makes. Every channel is IMPORTANCE_HIGH with the phone's default notification sound,
 * and notifications are posted whether or not the app is in the foreground, so the sound plays either way. The user
 * controls sound and alerts per channel in system settings ([openSettings]).
 */
class Notifier(private val context: Context) {
    companion object {
        const val CHANNEL = "renders_v2" // v2: IMPORTANCE_HIGH (a channel's importance can't be raised after it exists)
        const val EXTRA_ROUTE = "muse.route"
        /** Open the post handoff for this post id (scheduled post notification). */
        const val EXTRA_HANDOFF = "muse.handoff"
        const val CHANNEL_POSTS = "posts"
        /** The owner's ongoing "Add-on engine ready" notification: low importance, silent (it updates every minute). */
        const val CHANNEL_WARM = "warm_gpu"
        private const val WARM_ID = 0x5741524d
        private const val WARM_WARNING_ID = 0x5741524e
    }

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm?.deleteNotificationChannel("renders") // the old, quieter channel
            // Sound and importance only apply when a channel is first created; afterwards the user's choices win.
            val defaultSound = Settings.System.DEFAULT_NOTIFICATION_URI
            val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            val ch = NotificationChannel(CHANNEL, context.getString(R.string.channel_renders), NotificationManager.IMPORTANCE_HIGH)
            ch.description = context.getString(R.string.channel_renders_desc)
            ch.setSound(defaultSound, attrs)
            ch.enableVibration(true)
            nm?.createNotificationChannel(ch)
            val posts = NotificationChannel(CHANNEL_POSTS, context.getString(R.string.channel_posts), NotificationManager.IMPORTANCE_HIGH)
            posts.description = context.getString(R.string.channel_posts_desc)
            posts.setSound(defaultSound, attrs)
            posts.enableVibration(true)
            nm?.createNotificationChannel(posts)
            val warm = NotificationChannel(CHANNEL_WARM, context.getString(R.string.channel_warm), NotificationManager.IMPORTANCE_LOW)
            warm.description = context.getString(R.string.channel_warm_desc)
            warm.setSound(null, null)
            warm.enableVibration(false)
            nm?.createNotificationChannel(warm)
        }
    }

    /**
     * Opens system settings for MUSE's notifications: the renders channel's page (sound, pop-up, vibration), or the
     * app's notification page when notifications are off for the whole app or the channel page can't be opened.
     */
    fun openSettings(from: Context) {
        val app = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        val channel = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL)
        val first = if (NotificationManagerCompat.from(context).areNotificationsEnabled()) channel else app
        if (from !is android.app.Activity) { first.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); app.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        runCatching { from.startActivity(first) }.recoverCatching { from.startActivity(app) }
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
        else "Render failed · ${job.title}" to job.failLine()
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

    private fun warmAction(action: String, code: Int): PendingIntent =
        PendingIntent.getBroadcast(context, code, Intent(context, WarmGpuReceiver::class.java).setAction(action), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /**
     * The owner's ongoing "Add-on engine ready" notification, like a foreground service's: it can't be swiped away while it's on, its
     * chronometer counts the minutes by itself, and it has Turn off. Updated on every state change and minute tick.
     */
    fun warmOngoing(w: studio.muse.app.data.WarmGpu) {
        if (!canPost()) return
        val title = if (w.starting) "Add-on engine getting ready… (3–6 min)" else "Add-on engine ready"
        val text = "${Pricing.money(w.costUsd)} so far · about ${Pricing.money(w.ratePerHour)}/hour · turns off after ${w.idleMinutes} min without renders"
        val n = NotificationCompat.Builder(context, CHANNEL_WARM)
            .setSmallIcon(R.drawable.ic_stat_muse)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setUsesChronometer(true)
            .setShowWhen(true)
            .setWhen(w.startedAt ?: System.currentTimeMillis())
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(open("studio", WARM_ID))
            .addAction(0, "Turn off", warmAction(WarmGpuReceiver.TURN_OFF, WARM_ID))
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(WARM_ID, n) }
    }

    fun cancelWarm() {
        runCatching { NotificationManagerCompat.from(context).cancel(WARM_ID) }
        cancelWarmWarning()
    }

    /** The 5-minute warning before an idle or cap auto-off, with Keep ready (owner). */
    fun warmWarning(w: studio.muse.app.data.WarmWarning) {
        if (!canPost()) return
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_muse)
            .setContentTitle(w.message.ifBlank { "Add-on engine turns off in 5 min" }.replace("Warm GPU", "Add-on engine"))
            .setContentText(if (w.reason == "cap") "It reaches its time limit. Keep ready extends it once." else "No renders on it. Keep ready keeps it on.")
            .setAutoCancel(true)
            .setTimeoutAfter((w.autoOffAt - System.currentTimeMillis()).coerceIn(10_000, 6 * 60_000L))
            .setContentIntent(open("studio", WARM_WARNING_ID))
            .addAction(0, "Keep ready", warmAction(WarmGpuReceiver.KEEP_WARM, WARM_WARNING_ID))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(WARM_WARNING_ID, n) }
    }

    fun cancelWarmWarning() { runCatching { NotificationManagerCompat.from(context).cancel(WARM_WARNING_ID) } }

    /** Identity LoRA training finished. */
    fun loraReady(modelName: String, version: Int) =
        show(CHANNEL, "lora_$modelName".hashCode(), "Identity LoRA v$version is ready", "$modelName's face and physique are locked in for new photos and videos.", open("lora", "lora".hashCode()))

    /** A scheduled post's time has come: tapping opens the handoff (each app with the caption ready). */
    fun postDue(postId: String, title: String, platforms: List<String>) {
        val names = platforms.mapNotNull { studio.muse.app.data.Platform.of(it)?.label }.joinToString(", ").ifEmpty { "your accounts" }
        show(CHANNEL_POSTS, postId.hashCode(), "Time to post · $title", "Tap to open $names with the video and caption ready.", open("posts", postId.hashCode(), postId))
    }
}
