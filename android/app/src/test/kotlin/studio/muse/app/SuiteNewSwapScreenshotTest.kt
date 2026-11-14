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
import studio.muse.app.data.RemixDraft
import studio.muse.app.data.SampleData
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes

/**
 * New Swap on Android (owner-approved 2026-11-14; redesign frames "New Swap" empty, filled light and filled dark) in
 * Editorial and Camera Body on a 390 dp phone and an 840 dp tablet. Demo mode (FakeMuseApi): its estimate is a free test
 * render, so Generate reads "Test render · Free". PNGs: app/build/outputs/roborazzi/suite_newswap_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteNewSwapScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b").flatMap { t -> listOf("empty", "filled").flatMap { s -> listOf(390, 840).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        if (width == 840) RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val ns = c.suite.newSwap
        ns.on.value = true
        if (screen == "empty") ns.demoSample = false
        else ns.draft.value = RemixDraft(backgroundOn = true, backgroundWords = "A rooftop at golden hour, city lights behind her",
            outfitOn = true, outfitId = SampleData.GREEN, characterOn = true, modelId = SampleData.DEMO)
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, Routes.SUITE_SWAP) }
        repeat(10) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_newswap_${theme}_${screen}_$width.png")
    }
}
