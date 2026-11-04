package studio.muse.app

import org.robolectric.RuntimeEnvironment
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.DataStorePrefs
import studio.muse.app.data.TokenCipher

/**
 * Remember me: on keeps the (encrypted) session and the email across a restart; off keeps them in memory only.
 * A second [DataStorePrefs] on the same storage stands in for the app after its process was killed.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RememberMeTest {
    private val cipher = object : TokenCipher {
        override fun encrypt(plain: String) = "enc:" + plain.reversed()
        override fun decrypt(stored: String) = stored.removePrefix("enc:").reversed()
    }

    @Test fun rememberMeOnAndOff() = runBlocking {
        val ctx: android.content.Context = RuntimeEnvironment.getApplication()

        val first = DataStorePrefs(ctx, cipher)
        first.update { it.copy(token = "muse_on", email = "maya@studio.com", rememberMe = true) }
        DataStorePrefs(ctx, cipher).prefs.first().let { p ->
            assertEquals("muse_on", p.token); assertEquals("maya@studio.com", p.email); assertTrue(p.rememberMe)
        }

        val second = DataStorePrefs(ctx, cipher)
        second.update { it.copy(token = "muse_off", email = "leo@studio.com", rememberMe = false) }
        second.prefs.first().let { p -> assertEquals("muse_off", p.token); assertEquals("leo@studio.com", p.email) } // this run: signed in
        DataStorePrefs(ctx, cipher).prefs.first().let { p ->                                                          // after a restart: signed out
            assertNull(p.token); assertEquals("", p.email); assertFalse(p.rememberMe)
        }

        // Turning it back on persists the session again.
        val third = DataStorePrefs(ctx, cipher)
        third.update { it.copy(token = "muse_back", email = "leo@studio.com", rememberMe = true) }
        DataStorePrefs(ctx, cipher).prefs.first().let { p -> assertEquals("muse_back", p.token); assertEquals("leo@studio.com", p.email) }
    }
}
