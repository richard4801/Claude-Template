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
 * The Video suite redesign (owner-approved 2026-11-14, plans/design/suite-redesign/) on Android: Home, Shot and Swap in
 * Editorial (light) and Camera Body (dark, the lifted Suite tokens), on a 390 dp phone and an 840 dp tablet, for the
 * side-by-side with the approved frames. Demo mode (FakeMuseApi). PNGs: app/build/outputs/roborazzi/suite_redesign_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteRedesignScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        val SCREENS = listOf("home", "shot", "swap", "take", "storyboard")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b").flatMap { t -> SCREENS.flatMap { s -> listOf(390, 840).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        if (width == 840) RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        c.suite.newSwap.on.value = false // the classic Swap screen (New Swap has SuiteNewSwapScreenshotTest)
        val cat = fake.suite.camera
        if (screen == "shot") {
            var t = PromptTokens().withText(" dances on a rooftop at golden hour, hair catching the backlight. ")
            t = t.addMention("character", SampleData.DEMO, "Demo", t.caretAtEnd.copy(part = 0, offset = 0)).first
            cat.move("dolly_in")?.let { t = t.addMove(it).first }
            c.suite.composer.value = ComposerDraft(tokens = t, modelId = SampleData.DEMO, outfitId = SampleData.GREEN, aspect = "9:16", duration = 8,
                settings = ComposerSettings(body = "film_35", lens = "anamorphic", genre = "ugc", tempo = "calm", palette = "golden_warmth", lighting = "window"))
        }
        // A finished take: the demo studio's done job "Kick test" (owner decision 2: Keep above the video).
        val doneJob: String? = "j1"
        val route = when (screen) {
            "home" -> Routes.SUITE; "shot" -> Routes.SUITE_SHOT; "take" -> doneJob?.let { Routes.suiteTake(it) } ?: Routes.SUITE
            "storyboard" -> Routes.SUITE_STORYBOARD; else -> Routes.SUITE_SWAP
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, route) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_redesign_${theme}_${screen}_$width.png")
    }
}
