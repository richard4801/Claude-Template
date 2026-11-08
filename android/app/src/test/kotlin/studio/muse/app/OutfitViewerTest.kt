package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.components.ImageViewerContent
import studio.muse.app.ui.components.ViewerImage
import studio.muse.app.ui.theme.MuseTheme

/**
 * The outfit viewer (owner request 2026-11-08): the new outfit's angles full size, swipe between them, close.
 * Screenshots in all four themes at 390 dp and 840 dp: app/build/outputs/roborazzi/outfit_viewer_<theme>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class OutfitViewerTest(private val theme: String, private val width: Int) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> listOf(390, 840).map { w -> arrayOf<Any>(t, w) } }

        val SET = listOf(
            ViewerImage(ImageRef.asset("g_front"), "Front"), ViewerImage(ImageRef.asset("g_tq"), "¾"),
            ViewerImage(ImageRef.asset("g_side"), "Side"), ViewerImage(ImageRef.asset("g_back"), "Back"),
        )
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun viewer() {
        if (width == 840) RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        var closed = false
        compose.setContent { MuseTheme(studio.muse.app.ui.theme.ThemeId.fromKey(theme)) { ImageViewerContent(SET, 0, onClose = { closed = true }) } }
        idle()
        compose.onNodeWithText("Front").assertIsDisplayed()
        compose.onNodeWithText("1 of 4").assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/outfit_viewer_${theme}_$width.png")
        // One-finger swipe at 1× moves to the next angle.
        compose.onNodeWithTag("image_viewer").performTouchInput { swipeLeft() }
        idle(); compose.waitForIdle()
        compose.onNodeWithText("2 of 4").assertIsDisplayed()
        compose.onNodeWithContentDescription("Close").performClick()
        assertTrue(closed)
    }
}
