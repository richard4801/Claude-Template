package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.data.ShootRef
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerSheet
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PhotoDraft
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SheetKind

/**
 * The Photo tool on the composer (workstream 3) in all four themes on a 390 dp phone and an 840 dp tablet: empty (no
 * character yet), filled (character, outfit, product, two references, chips that trip the still rig check), a photo
 * preset picked, the References sheet and the Camera picker (Setup and Angle only). Demo mode.
 * PNGs: app/build/outputs/roborazzi/suite_photo_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuitePhotoScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        val SCREENS = listOf("empty", "filled", "preset", "references", "camera")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.flatMap { s -> listOf(390, 840).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        if (width == 840) RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val filled = ComposerDraft(
            tool = ComposerTool.PHOTO, tokens = PromptTokens().withText("Laughing on a rooftop at golden hour, wind in her hair"),
            modelId = SampleData.DEMO, outfitId = SampleData.GREEN,
            settings = ComposerSettings(body = "phone", aperture = "f1.4", focalMm = 85, shotSize = "mcu", genre = "ugc", palette = "golden_warmth", lighting = "window"),
        )
        val refs = listOf(ShootRef(ImageRef.asset("c_front"), listOf("pose")), ShootRef(ImageRef.asset("c_tq"), listOf("look", "scene")))
        when (screen) {
            "empty" -> c.suite.composer.value = ComposerDraft(tool = ComposerTool.PHOTO)
            "preset" -> { c.suite.composer.value = filled; c.suite.photo.draft.value = PhotoDraft(count = 2, presetId = "tpl_mirror-selfie") }
            else -> { c.suite.composer.value = filled; c.suite.photo.draft.value = PhotoDraft(refs = refs, product = ImageRef.asset("hero")) }
        }
        c.suite.sheet.value = when (screen) {
            "references" -> ComposerSheet(SheetKind.REFERENCES)
            "camera" -> ComposerSheet(SheetKind.CAMERA, "setup")
            else -> null
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, Routes.SUITE_PHOTO) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        if (screen == "filled" || screen == "empty") {
            // The bar: one Photos list, no Quality, Shape, Length, Sound, Speaking or Takes.
            assertEquals(1, compose.onAllNodesWithContentDescription("Photos: ", substring = true).fetchSemanticsNodes().size)
            listOf("Quality", "Shape:", "Length:", "Sound:", "Speaking:", "Takes:", "Settings").forEach { k ->
                assertTrue(k, compose.onAllNodesWithContentDescription(k, substring = true).fetchSemanticsNodes().isEmpty())
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_photo_${theme}_${screen}_$width.png")
    }
}
