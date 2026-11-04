package studio.muse.app

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.DataStorePrefs
import studio.muse.app.data.Drafts
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MuseApi
import studio.muse.app.data.MuseRepository
import studio.muse.app.data.PrefsStore
import studio.muse.app.platform.Notifier
import studio.muse.app.platform.SoundFx
import java.io.File

/** Manual dependency container (no DI framework). */
class AppContainer(
    val scope: CoroutineScope,
    val prefsStore: PrefsStore,
    val fake: MuseApi,
    val notifier: Notifier?,
    val media: studio.muse.app.platform.MediaReader? = null,
    initialPrefs: AppPrefs = AppPrefs(),
    soundsOn: Boolean = true,
) {
    val prefs: StateFlow<AppPrefs> = prefsStore.prefs.stateIn(scope, SharingStarted.Eagerly, initialPrefs)
    val repo = MuseRepository(scope, prefsStore, fake)
    val drafts = Drafts()
    val sound = SoundFx(enabled = { soundsOn && prefs.value.sound }, theme = { prefs.value.theme })

    init {
        repo.listener = studio.muse.app.data.JobListener { job ->
            sound.play(if (job.done) SoundFx.Kind.DONE else SoundFx.Kind.TAP)
            notifier?.jobFinished(job)
            if (job.done) repo.toast("Render done · tap to watch", "result/${job.id}") else repo.toast("Render failed · ${studio.muse.core.Pricing.money(job.refunded)} refunded", "queue")
        }
    }

    companion object {
        fun create(context: Context): AppContainer {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val fake = FakeMuseApi(scope, File(context.filesDir, "uploads"))
            return AppContainer(scope, DataStorePrefs(context), fake, Notifier(context), studio.muse.app.platform.MediaReader(context))
        }
    }
}
