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
        const val CHANNEL = "renders"
        const val EXTRA_ROUTE = "muse.route"
    }

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, context.getString(R.string.channel_renders), NotificationManager.IMPORTANCE_DEFAULT)
            ch.description = context.getString(R.string.channel_renders_desc)
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
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
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(job.id.hashCode(), n) }
    }
}
