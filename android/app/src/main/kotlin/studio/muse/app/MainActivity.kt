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
        pendingRoute.value = intent?.getStringExtra(Notifier.EXTRA_ROUTE)
        pendingHandoff.value = intent?.getStringExtra(Notifier.EXTRA_HANDOFF)
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(Notifier.EXTRA_ROUTE)?.let { pendingRoute.value = it }
        intent.getStringExtra(Notifier.EXTRA_HANDOFF)?.let { pendingHandoff.value = it }
    }
}
