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
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.PromptTokens

/**
 * The rig check's warning row (workstream 3) in the Shot composer, just above the bottom bar, in all four themes on a
 * 390 dp phone and an 840 dp tablet: one warning ("warn": the prompt names another angle), a tip with an alt (film stock
 * against palette: the alt in the ⋯ overflow on the phone, beside the fix on the tablet) and three clashes collapsed
 * behind "+2". The demo's own rig check answers (the server's rules, ported). Generate stays live in every state.
 * PNGs: app/build/outputs/roborazzi/rigcheck_<theme>_<state>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class RigCheckRowScreenshotTest(private val theme: String, private val state: String, private val width: Int) {
    companion object {
        val STATES = listOf("warn", "tip_alt", "more2")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> STATES.flatMap { s -> listOf(390, 840).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        if (width == 840) RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val cat = fake.suite.camera
        fun words(s: String) = PromptTokens().withText(s)
        c.suite.composer.value = when (state) {
            "warn" -> ComposerDraft(tokens = words("Low angle as she steps off the tram, coat catching the wind"), modelId = SampleData.DEMO,
                settings = ComposerSettings(height = "high"))
            "tip_alt" -> ComposerDraft(tokens = words("She reads by the window, late afternoon"), modelId = SampleData.DEMO,
                settings = ComposerSettings(stock = "bw_film", palette = "hyper_neon"))
            else -> {
                var t = words("She talks to camera about her morning ")
                t = t.addMove(cat.move("orbit_left")!!, t.caretAtEnd).first
                ComposerDraft(tokens = t, modelId = SampleData.DEMO, speaking = true,
                    settings = ComposerSettings(body = "phone", aperture = "f1.4", focalMm = 14, shotSize = "cu"))
            }
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, Routes.SUITE_SHOT) }
        repeat(10) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/rigcheck_${theme}_${state}_$width.png")
    }
}
