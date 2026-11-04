package studio.muse.app.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import studio.muse.app.BuildConfig

/** User preferences. The chosen theme persists across launches. */
data class AppPrefs(
    val theme: String = "a",
    val useFake: Boolean = BuildConfig.DEFAULT_USE_FAKE,
    val serverUrl: String = BuildConfig.DEFAULT_SERVER_URL,
    /** "Fast · beta" (Viggle) is behind this flag. */
    val fastBeta: Boolean = true,
    val token: String? = null,
    val studioName: String = "",
    val email: String = "",
    val notifAsked: Boolean = false,
)

interface PrefsStore {
    val prefs: Flow<AppPrefs>
    suspend fun update(f: (AppPrefs) -> AppPrefs)
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "muse")

class DataStorePrefs(private val context: Context) : PrefsStore {
    private object K {
        val theme = stringPreferencesKey("theme")
        /** Removed setting (UI sound effects); cleared on the next write. */
        val legacySound = booleanPreferencesKey("sound")
        val useFake = booleanPreferencesKey("use_fake")
        val serverUrl = stringPreferencesKey("server_url")
        val fastBeta = booleanPreferencesKey("fast_beta")
        val token = stringPreferencesKey("token")
        val studio = stringPreferencesKey("studio")
        val email = stringPreferencesKey("email")
        val notifAsked = booleanPreferencesKey("notif_asked")
    }

    override val prefs: Flow<AppPrefs> = context.dataStore.data.map { p ->
        val d = AppPrefs()
        AppPrefs(
            theme = p[K.theme] ?: d.theme, useFake = p[K.useFake] ?: d.useFake,
            serverUrl = p[K.serverUrl] ?: d.serverUrl, fastBeta = p[K.fastBeta] ?: d.fastBeta, token = p[K.token],
            studioName = p[K.studio] ?: "", email = p[K.email] ?: "", notifAsked = p[K.notifAsked] ?: false,
        )
    }

    override suspend fun update(f: (AppPrefs) -> AppPrefs) {
        context.dataStore.edit { p ->
            val cur = AppPrefs(
                theme = p[K.theme] ?: "a", useFake = p[K.useFake] ?: BuildConfig.DEFAULT_USE_FAKE,
                serverUrl = p[K.serverUrl] ?: BuildConfig.DEFAULT_SERVER_URL, fastBeta = p[K.fastBeta] ?: true, token = p[K.token],
                studioName = p[K.studio] ?: "", email = p[K.email] ?: "", notifAsked = p[K.notifAsked] ?: false,
            )
            val n = f(cur)
            p.remove(K.legacySound)
            p[K.theme] = n.theme; p[K.useFake] = n.useFake; p[K.serverUrl] = n.serverUrl
            p[K.fastBeta] = n.fastBeta; p[K.studio] = n.studioName; p[K.email] = n.email; p[K.notifAsked] = n.notifAsked
            if (n.token == null) p.remove(K.token) else p[K.token] = n.token
        }
    }
}

/** For tests and previews. */
class MemoryPrefs(initial: AppPrefs = AppPrefs()) : PrefsStore {
    private val s = MutableStateFlow(initial)
    override val prefs: Flow<AppPrefs> = s
    override suspend fun update(f: (AppPrefs) -> AppPrefs) = s.update(f)
}
