package studio.muse.app.platform

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.launch
import studio.muse.app.MuseApplication

/** The warm GPU notification actions: Turn off (ongoing notification) and Keep warm (the 5-minute warning). */
class WarmGpuReceiver : BroadcastReceiver() {
    companion object {
        const val TURN_OFF = "studio.muse.app.WARM_TURN_OFF"
        const val KEEP_WARM = "studio.muse.app.WARM_KEEP"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val c = (context.applicationContext as? MuseApplication)?.container ?: return
        val done = goAsync()
        c.scope.launch {
            try {
                when (intent.action) {
                    TURN_OFF -> c.repo.setWarm(false)
                    KEEP_WARM -> { c.repo.keepWarm(); c.notifier?.cancelWarmWarning(); c.warmUi.banner.value = null }
                }
            } finally { done.finish() }
        }
    }
}
