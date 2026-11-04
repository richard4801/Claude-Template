package studio.muse.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.DataStorePrefs
import studio.muse.app.data.Drafts
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MuseApi
import studio.muse.app.data.MuseRepository
import studio.muse.app.data.PrefsStore
import studio.muse.app.platform.Notifier
import java.io.File

/** Manual dependency container (no DI framework). */
class AppContainer(
    val scope: CoroutineScope,
    val prefsStore: PrefsStore,
    val fake: MuseApi,
    val notifier: Notifier?,
    val media: studio.muse.app.platform.MediaReader? = null,
    initialPrefs: AppPrefs = AppPrefs(),
    val postAlarms: studio.muse.app.platform.PostAlarms? = null,
) {
    val prefs: StateFlow<AppPrefs> = prefsStore.prefs.stateIn(scope, SharingStarted.Eagerly, initialPrefs)
    val repo = MuseRepository(scope, prefsStore, fake)
    val drafts = Drafts()
    val warmUi = studio.muse.app.data.WarmUi()

    init {
        repo.listener = studio.muse.app.data.JobListener { job ->
            notifier?.jobFinished(job)
            if (job.done) repo.toast("Render done · tap to watch", "result/${job.id}") else repo.toast("Render failed · ${studio.muse.core.Pricing.money(job.refunded)} refunded", "queue")
        }
        scope.launch { prefs.collect { repo.setStudioName(it.studioName) } }
        // Keep GPU warm: the ongoing notification follows the state; the warning is a notification and a banner.
        scope.launch {
            repo.state.map { it.warm }.distinctUntilChanged().collect { w ->
                if (w?.on == true) notifier?.warmOngoing(w) else notifier?.cancelWarm()
                // The warning goes once the GPU is off, or when Keep warm / a render moved the auto-off.
                val b = warmUi.banner.value
                if (b != null && w != null && (!w.on || w.autoOffAt != b.autoOffAt)) warmUi.banner.value = null
            }
        }
        scope.launch {
            repo.warmWarnings.collect { w ->
                warmUi.banner.value = w
                notifier?.warmWarning(w)
            }
        }
        repo.onLoraReady = { model, lora ->
            notifier?.loraReady(model?.name ?: "Your model", lora.version)
            repo.toast("Identity LoRA v${lora.version} is ready", "lora")
        }
    }

    companion object {
        fun create(context: Context): AppContainer {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            File(context.cacheDir, "sfx").deleteRecursively() // WAVs left by the removed UI sound effects
            val fake = FakeMuseApi(scope, File(context.filesDir, "uploads"))
            return AppContainer(scope, DataStorePrefs(context), fake, Notifier(context), studio.muse.app.platform.MediaReader(context), postAlarms = studio.muse.app.platform.PostAlarms(context))
        }
    }
}
