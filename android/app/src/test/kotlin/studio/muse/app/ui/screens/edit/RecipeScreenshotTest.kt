package studio.muse.app.ui.screens.edit

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
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
import studio.muse.app.data.FakeRecipes
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * "Recreate this edit" (plans/recreate-edit.md), build phase 1: the Recipe view in all four themes. The pick and analysis
 * states, the recipe on a phone (the first screen and the whole page) and on a tablet, and the Edit home's entry.
 * PNGs: app/build/outputs/roborazzi/recipe_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class RecipeScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t ->
            listOf("pick", "analysing", "ready", "ready_full", "ready_tablet", "home").map { arrayOf<Any>(t, it) }
        }
    }

    @get:Rule val compose = createComposeRule()

    @Test fun capture() {
        when (state) {
            "ready_full" -> RuntimeEnvironment.setQualifiers("w390dp-h2600dp-xhdpi")
            "ready_tablet" -> RuntimeEnvironment.setQualifiers("w1280dp-h1600dp-mdpi")
        }
        val recipe = FakeRecipes.cafeTrend()
        val ui = when (state) {
            "pick" -> RecipeUi()
            "analysing" -> RecipeUi(RecipePhase.Analysing(.6f, "Reading the text"), "cafe_morning.mp4")
            else -> RecipeUi(RecipePhase.Ready(recipe), "cafe_morning.mp4")
        }
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                if (state == "home") EditHomeContent(
                    listOf(
                        TakeChoice("e1", "Morning café", "Edited", ImageRef.asset("g_front"), 18.0, true, true),
                        TakeChoice("t1", "Morning café", "HD", ImageRef.asset("g_tq"), 18.4, false, true),
                    ), onBack = {}, onOpen = {}, onRecreate = {},
                )
                else RecipeContent(ui, onBack = {}, onPick = {})
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/recipe_${theme}_$state.png")
    }

    @Test fun `the stand-in recipe reads like the plan`() {
        val r = FakeRecipes.cafeTrend()
        assertEquals(7, r.slots.size)
        assertEquals(15.0, r.durationSec, 0.0)
        assertEquals(1.0, r.cutsOnBeat()!!, 0.0) // every cut on a beat
        assertTrue(r.lowConfidence() >= 2) // the 0.55 shot, the 0.58 text and the unknown transition
    }
}
