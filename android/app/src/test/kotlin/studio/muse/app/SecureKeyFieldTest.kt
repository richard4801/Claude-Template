package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.ui.components.SecureKeyField
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/** WS7: the provider key field sends the key once, clears it, and afterwards shows only the last 4. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SecureKeyFieldTest {
    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun savesOnceAndClears() {
        val sent = mutableListOf<String>()
        compose.setContent { MuseTheme(ThemeId.A) { SecureKeyField(null, "Starts with r8_", busy = false, error = null, keysReady = true, onSave = { sent += it }) } }
        compose.onNode(hasSetTextAction()).performTextInput("r8_secretSECRET1234")
        compose.onNodeWithText("Save key").performClick(); idle()
        assertEquals(listOf("r8_secretSECRET1234"), sent)
        // Cleared after sending: a second Save sends nothing.
        compose.onNodeWithText("Save key").performClick(); idle()
        assertEquals(1, sent.size)
        assertTrue(compose.onAllNodesWithText("r8_secret", substring = true).fetchSemanticsNodes().isEmpty())
    }

    @Test fun savedShowsLastFourOnly() {
        compose.setContent { MuseTheme(ThemeId.B) { SecureKeyField("1234", "Starts with r8_", busy = false, error = null, keysReady = true, onSave = {}) } }
        compose.onNodeWithText("Key ending 1234").assertIsDisplayed()
        compose.onNodeWithText("Replace key").performClick(); idle()
        compose.onNodeWithText("Keep the old key").assertIsDisplayed()
    }

    @Test fun keysNotReady() {
        compose.setContent { MuseTheme(ThemeId.C) { SecureKeyField(null, "", busy = false, error = null, keysReady = false, onSave = {}) } }
        compose.onNodeWithText("Provider keys aren't set up on the server yet").assertIsDisplayed()
    }
}
