package studio.muse.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import studio.muse.app.platform.Notifier
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes

class MainActivity : ComponentActivity() {
    private val pendingRoute = mutableStateOf<String?>(null)
    /** A scheduled post whose notification was tapped: open its handoff once the posts are loaded. */
    private val pendingHandoff = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as MuseApplication).container
        // Cold start (plans/perf-audit.md "Android"): "Fully drawn" in logcat once the studio's lists have loaded (or there is
        // nothing to load: signed out), on the frame after. `adb shell am start -W` reports TotalTime up to the first frame.
        lifecycleScope.launch {
            container.repo.state.first { it.loaded }
            window.decorView.post { reportFullyDrawn() }
        }
        pendingRoute.value = intent?.getStringExtra(Notifier.EXTRA_ROUTE)
        pendingHandoff.value = intent?.getStringExtra(Notifier.EXTRA_HANDOFF)
        intent?.let(::takeShare)
        setContent {
            val prefs by container.prefs.collectAsState()
            val dark = prefs.theme == "b"
            LaunchedEffect(dark) {
                enableEdgeToEdge(
                    statusBarStyle = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT) else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
                    navigationBarStyle = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT) else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
                )
            }
            MuseApp(container, Routes.SPLASH, pendingRoute.value, { pendingRoute.value = null }, pendingHandoff.value) { pendingHandoff.value = null }
        }
    }

    /** Back in the foreground: restart the live stream and refetch, so changes made on other devices meanwhile show up. */
    override fun onStart() {
        super.onStart()
        (application as MuseApplication).container.repo.onForeground()
    }

    override fun onStop() {
        super.onStop()
        (application as MuseApplication).container.repo.onBackground()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(Notifier.EXTRA_ROUTE)?.let { pendingRoute.value = it }
        intent.getStringExtra(Notifier.EXTRA_HANDOFF)?.let { pendingHandoff.value = it }
        takeShare(intent)
    }

    /**
     * Share → MUSE (plans/recreate-edit.md): a shared video file or a shared link opens the chooser (Recreate, Use for swap,
     * Import to library; WS7). The server
     * decides what a link can be fetched from (plans/research/platform-download-rules.md); the app only passes it on.
     */
    private fun takeShare(intent: Intent) {
        if (intent.action != Intent.ACTION_SEND) return
        val container = (application as MuseApplication).container
        @Suppress("DEPRECATION")
        val stream = (if (android.os.Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, android.net.Uri::class.java)
            else intent.getParcelableExtra(Intent.EXTRA_STREAM) as? android.net.Uri)
        val shared = when {
            stream != null && (intent.type ?: "").startsWith("video/") -> studio.muse.app.data.SharedReference.File(stream, intent.type)
            else -> studio.muse.core.edit.SharedLink.first(intent.getStringExtra(Intent.EXTRA_TEXT))?.let { studio.muse.app.data.SharedReference.Link(it) }
        } ?: return
        container.shared.value = shared
        // WS7: ask what to do with it (Recreate first, and back still lands there; Use for swap; Import to library).
        pendingRoute.value = Routes.SHARE
        intent.action = null // once
    }
}
