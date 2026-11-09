package studio.muse.app.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import studio.muse.app.BuildConfig
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** User preferences. The chosen theme persists across launches. */
data class AppPrefs(
    val theme: String = "a",
    /** Demo mode: the in-app fake with the bundled sample studio, no server. Off by default. */
    val useFake: Boolean = BuildConfig.DEFAULT_USE_FAKE,
    val serverUrl: String = BuildConfig.DEFAULT_SERVER_URL,
    /** "Fast · beta" (Viggle) is behind this flag. */
    val fastBeta: Boolean = true,
    /** The session token. Stored encrypted with an Android Keystore key (see [TokenCipher]). */
    val token: String? = null,
    val studioName: String = "",
    val email: String = "",
    val notifAsked: Boolean = false,
    /** "owner" or "member" (from sign-in or GET /v1/auth/me). Owner-only screens follow it. */
    val role: String = "member",
    val userId: String = "",
    /**
     * Sign in's Remember me. On: the session (encrypted) and the email are saved. Off: the token lives in memory only (signed
     * out when the process ends) and the email isn't saved.
     */
    val rememberMe: Boolean = true,
    /** Settings redesign (owner, 2026-11-09): Advanced (server, testing) shows only once turned on under Account. */
    val showAdvanced: Boolean = false,
    /** Settings → Studio → Start at: the quality new shots start on (draft | standard | hd | cinema). */
    val startAt: String = "draft",
) {
    val owner get() = role == "owner"
}

interface PrefsStore {
    val prefs: Flow<AppPrefs>
    suspend fun update(f: (AppPrefs) -> AppPrefs)
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "muse")

/**
 * Encrypts the session token with an AES-GCM key that never leaves the Android Keystore. If the Keystore is unavailable
 * the token is kept in memory only (the user signs in again next launch), never written in the clear.
 */
interface TokenCipher {
    fun encrypt(plain: String): String?
    fun decrypt(stored: String): String?
}

class KeystoreTokenCipher(private val alias: String = "muse_session_v1") : TokenCipher {
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build(),
        )
        return gen.generateKey()
    }

    override fun encrypt(plain: String): String? = runCatching {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val out = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(out, Base64.NO_WRAP)
    }.getOrNull()

    override fun decrypt(stored: String): String? = runCatching {
        val (iv, data) = stored.split(":", limit = 2)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP))) }
        String(c.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8)
    }.getOrNull()
}

class DataStorePrefs(private val context: Context, private val cipher: TokenCipher = KeystoreTokenCipher()) : PrefsStore {
    private object K {
        val theme = stringPreferencesKey("theme")
        /** Removed setting (UI sound effects); cleared on the next write. */
        val legacySound = booleanPreferencesKey("sound")
        val useFake = booleanPreferencesKey("use_fake")
        val serverUrl = stringPreferencesKey("server_url")
        val fastBeta = booleanPreferencesKey("fast_beta")
        val showAdvanced = booleanPreferencesKey("show_advanced")
        val startAt = stringPreferencesKey("start_at")
        /** Old plaintext token (before 2026-11-04): moved to [tokenEnc] and removed. */
        val legacyToken = stringPreferencesKey("token")
        val tokenEnc = stringPreferencesKey("token_enc")
        val studio = stringPreferencesKey("studio")
        val email = stringPreferencesKey("email")
        val notifAsked = booleanPreferencesKey("notif_asked")
        val role = stringPreferencesKey("role")
        val userId = stringPreferencesKey("user_id")
        val rememberMe = booleanPreferencesKey("remember_me")
        val version = intPreferencesKey("prefs_version")
    }

    /** Holds the token when the Keystore can't encrypt it (never persisted in the clear). */
    @Volatile private var memoryToken: String? = null
    @Volatile private var decrypted: Pair<String, String?>? = null
    /** The signed-in email while Remember me is off (not persisted). */
    @Volatile private var memoryEmail: String? = null

    private fun tokenOf(p: Preferences): String? {
        val enc = p[K.tokenEnc] ?: return memoryToken
        decrypted?.let { (e, t) -> if (e == enc) return t }
        return cipher.decrypt(enc).also { decrypted = enc to it }
    }

    private fun read(p: Preferences): AppPrefs {
        val d = AppPrefs()
        // Version 2: the real server became the default. Older installs had the in-app fake and the emulator URL saved.
        val v2 = (p[K.version] ?: 1) >= 2
        return AppPrefs(
            theme = p[K.theme] ?: d.theme,
            useFake = if (v2) p[K.useFake] ?: d.useFake else d.useFake,
            serverUrl = if (v2) p[K.serverUrl] ?: d.serverUrl else d.serverUrl,
            fastBeta = p[K.fastBeta] ?: d.fastBeta,
            showAdvanced = p[K.showAdvanced] ?: d.showAdvanced,
            startAt = p[K.startAt] ?: d.startAt,
            token = if (v2) tokenOf(p) else null,
            studioName = p[K.studio] ?: "", email = p[K.email]?.ifBlank { null } ?: memoryEmail ?: "", notifAsked = p[K.notifAsked] ?: false,
            role = p[K.role] ?: d.role, userId = p[K.userId] ?: "", rememberMe = p[K.rememberMe] ?: d.rememberMe,
        )
    }

    // Performance: the Keystore decrypt of the token (a binder call) runs off the main thread at launch.
    override val prefs: Flow<AppPrefs> = context.dataStore.data.map(::read).flowOn(kotlinx.coroutines.Dispatchers.IO)

    override suspend fun update(f: (AppPrefs) -> AppPrefs) {
        context.dataStore.edit { p ->
            val n = f(read(p))
            p.remove(K.legacySound)
            p.remove(K.legacyToken)
            p[K.version] = 2
            p[K.theme] = n.theme; p[K.useFake] = n.useFake; p[K.serverUrl] = n.serverUrl
            p[K.fastBeta] = n.fastBeta; p[K.studio] = n.studioName; p[K.notifAsked] = n.notifAsked; p[K.showAdvanced] = n.showAdvanced; p[K.startAt] = n.startAt
            p[K.role] = n.role; p[K.userId] = n.userId; p[K.rememberMe] = n.rememberMe
            val token = n.token
            if (!n.rememberMe) {
                // Memory only: nothing about the session or the email survives the process.
                p.remove(K.tokenEnc); memoryToken = token
                p[K.email] = ""; memoryEmail = n.email
            } else {
                p[K.email] = n.email; memoryEmail = null
            }
            if (!n.rememberMe) Unit
            else if (token == null) { memoryToken = null; p.remove(K.tokenEnc) }
            else if (p[K.tokenEnc] == null || token != tokenOf(p)) {
                val enc = cipher.encrypt(token)
                if (enc != null) { p[K.tokenEnc] = enc; decrypted = enc to token; memoryToken = null } else { p.remove(K.tokenEnc); memoryToken = token }
            }
        }
    }
}

/** For tests and previews. */
class MemoryPrefs(initial: AppPrefs = AppPrefs()) : PrefsStore {
    private val s = MutableStateFlow(initial)
    override val prefs: Flow<AppPrefs> = s
    override suspend fun update(f: (AppPrefs) -> AppPrefs) = s.update(f)
}
