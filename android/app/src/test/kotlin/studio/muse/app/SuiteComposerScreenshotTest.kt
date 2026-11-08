package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
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
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerSheet
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SheetKind

/**
 * The video composer (plans/video-composer.md, mockups composer__P1…P5 / C1…C6) in all four themes on a 360 dp and a
 * 390 dp phone and an 840 dp tablet: empty, filled, the preset-collapsed state and every picker (Camera Setup, Angle,
 * Movement, Style, Look, Lighting, Settings). Pickers are always dark. Demo mode (FakeMuseApi), demo studio's models.
 * PNGs: app/build/outputs/roborazzi/suite_composer_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteComposerScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        val SCREENS = listOf("empty", "filled", "preset", "camera_setup", "camera_angle", "camera_movement", "style", "look", "lighting", "settings", "tools")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.flatMap { s -> listOf(360, 390, 840).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        when (width) {
            360 -> RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
            840 -> RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        }
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val cat = fake.suite.camera
        val filled = run {
            var t = PromptTokens().withText(" walks into a quiet café at golden hour, orders at the counter, then turns to camera with a soft smile. ")
            t = t.addMention("character", SampleData.DEMO, "Demo", t.caretAtEnd.copy(part = 0, offset = 0)).first
            t = t.addMove(cat.move("dolly_in")!!).first
            ComposerDraft(
                tokens = t, modelId = SampleData.DEMO, outfitId = SampleData.GREEN, quality = "hd",
                settings = ComposerSettings(body = "film_35", lens = "anamorphic", focalMm = 50, aperture = "f2.8", genre = "ugc", tempo = "calm", palette = "golden_warmth", lighting = "window", height = "eye", shotSize = "mcu"),
            )
        }
        when (screen) {
            "empty" -> Unit
            "preset" -> c.suite.composer.value = ComposerDraft().pickPreset(cat, "cinematic", SampleData.DEMO)
            else -> {
                c.suite.composer.value = filled
                c.suite.composerSlots.value = InputSlots().put(SlotId(SlotKind.START), SlotValue("window.jpg", image = ImageRef.asset("g_tq")))
            }
        }
        c.suite.sheet.value = when (screen) {
            "camera_setup" -> ComposerSheet(SheetKind.CAMERA, "setup")
            "camera_angle" -> ComposerSheet(SheetKind.CAMERA, "angle")
            "camera_movement" -> ComposerSheet(SheetKind.CAMERA, "movement")
            "style" -> ComposerSheet(SheetKind.STYLE, "genre")
            "look" -> ComposerSheet(SheetKind.LOOK, "palette")
            "lighting" -> ComposerSheet(SheetKind.LIGHTING)
            "settings" -> ComposerSheet(SheetKind.SETTINGS)
            "tools" -> ComposerSheet(SheetKind.TOOLS) // the title's mode menu (owner decision 2026-11-08)
            else -> null
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, Routes.SUITE_SHOT) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_composer_${theme}_${screen}_$width.png")
    }
}
