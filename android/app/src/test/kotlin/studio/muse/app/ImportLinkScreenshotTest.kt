package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.ImageRef
import studio.muse.app.data.ImportedVideo
import studio.muse.app.ui.screens.ImportLinkContent
import studio.muse.app.ui.screens.ImportPhase
import studio.muse.app.ui.screens.ImportPurpose
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * Import a video from a link (WS7): the four states in all four themes at 390 dp. Typing (from the Library), working
 * (Swap's source), done (Swap: "Use for swap") and failed with the saved-video way in.
 * PNGs: app/build/outputs/roborazzi/import_link_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ImportLinkScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> listOf("enter", "working", "done", "failed").map { s -> arrayOf<Any>(t, s) } }
    }

    @get:Rule val compose = createComposeRule()

    @Test fun capture() {
        val video = ImportedVideo("imp_1", "Rooftop dance at sunset", 9.4, 1080, 1920, sourceUrl = "https://www.tiktok.com/@a/video/1", platform = "tiktok", demoThumb = ImageRef.asset("g_front"))
        val (purpose, phase) = when (state) {
            "enter" -> ImportPurpose.LIBRARY to ImportPhase.Enter
            "working" -> ImportPurpose.SWAP to ImportPhase.Working(.12f, "Uploading the video")
            "done" -> ImportPurpose.SWAP to ImportPhase.Done(video)
            else -> ImportPurpose.LIBRARY to ImportPhase.Failed("The studio server couldn't get this video. Save it to your phone and pick it instead.", pickFile = true)
        }
        compose.setContent { MuseTheme(ThemeId.fromKey(theme)) { ImportLinkContent(purpose, phase, "", {}, {}, {}, {}, {}) } }
        shadowOf(Looper.getMainLooper()).idle()
        when (state) {
            "enter" -> compose.onNodeWithText("Import from link").assertIsDisplayed()
            "working" -> compose.onNodeWithText("Uploading the video…").assertIsDisplayed()
            "done" -> compose.onNodeWithText("Use for swap").assertIsDisplayed()
            else -> compose.onNodeWithText("Pick the saved video").assertIsDisplayed()
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/import_link_${theme}_$state.png")
    }
}
