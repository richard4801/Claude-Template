package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
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

/** Share → MUSE (WS7): the chooser for a shared link and for a shared file, all four themes. PNGs: share_chooser_<theme>_<kind>.png. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ShareChooserScreenshotTest(private val theme: String, private val kind: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> listOf("link", "file").map { k -> arrayOf<Any>(t, k) } }
    }

    @get:Rule val compose = createComposeRule()

    @Test fun capture() {
        val item = if (kind == "link") studio.muse.app.data.SharedReference.Link("https://www.tiktok.com/@dancer/video/7301234567890")
            else studio.muse.app.data.SharedReference.File(android.net.Uri.parse("content://media/video/1"), "video/mp4")
        var picked = ""
        compose.setContent { MuseTheme(ThemeId.fromKey(theme)) { studio.muse.app.ui.screens.ShareChooserContent(item, { picked = "recreate" }, { picked = "swap" }, { picked = "library" }, {}) } }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onNodeWithText("Recreate an edit").assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/share_chooser_${theme}_$kind.png")
        compose.onNodeWithText("Use for swap").performClick()
        org.junit.Assert.assertEquals("swap", picked)
    }
}

/** The Library with an imported video (WS12: imports are listed by GET /v1/imports), all four themes. PNGs: library_imports_<theme>.png. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class LibraryImportsScreenshotTest(private val theme: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").map { arrayOf<Any>(it) }
    }

    @get:Rule val compose = createComposeRule()

    @Test fun capture() {
        val scope = kotlinx.coroutines.MainScope()
        val fake = studio.muse.app.data.FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        kotlinx.coroutines.runBlocking { fake.imports.fromUpload(studio.muse.app.data.ImportUpload("up1", "https://www.tiktok.com/@a/video/1", "Rooftop dance")) }
        val c = AppContainer(scope, studio.muse.app.data.MemoryPrefs(studio.muse.app.data.AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        compose.mainClock.autoAdvance = false
        compose.setContent { studio.muse.app.ui.MuseApp(c, studio.muse.app.ui.Routes.GALLERY) }
        repeat(6) { shadowOf(Looper.getMainLooper()).idle(); compose.mainClock.advanceTimeBy(400) }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onNodeWithText("Imported videos").assertIsDisplayed()
        compose.onNodeWithText("Rooftop dance").assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/library_imports_$theme.png")
    }
}
