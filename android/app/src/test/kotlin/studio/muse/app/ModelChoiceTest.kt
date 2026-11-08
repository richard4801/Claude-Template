package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.ModelPurpose
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.ModelChoiceContent
import studio.muse.app.ui.screens.ModelPick
import studio.muse.app.ui.screens.label
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/** WS7: "pick the model everywhere": the per-purpose lists, the defaults, and Swap / Recast / Extend sending the pick. */
class ModelChoiceLogicTest {
    private val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
    private val cat = FakeSuite().catalog(owner = true)

    @Test fun eachPurposeHasItsOwnList() = runBlocking {
        val swap = api.modelChoice.models(ModelPurpose.SWAP).models.map { it.model }
        assertEquals(listOf("wan-2.2-animate", "kling-o1", "h3-max-recast"), swap)
        val shot = api.modelChoice.models(ModelPurpose.SHOT).models
        assertTrue(shot.all { it.kind == "video" } && shot.any { it.model == "kling-v4" })
        assertTrue(api.modelChoice.models(ModelPurpose.OUTFIT).models.all { it.kind == "image" })
    }

    @Test fun defaultsAreWhatAutoUses() = runBlocking {
        val o = api.modelChoice.setDefault(ModelPurpose.UPSCALE, "kling-v4")
        assertEquals("kling-v4", o.default)
        assertEquals("Auto (Kling 4.0)", o.label(ModelPick()))
        assertEquals("Kling 4.0, 1080p", o.label(ModelPick("kling-v4", "1080p")))
        assertNull(api.modelChoice.setDefault(ModelPurpose.UPSCALE, null).default)
    }

    @Test fun recastAndExtendSendThePick() {
        val d = ComposerDraft(tool = ComposerTool.RECAST, quality = "hd", engineModel = "kling-o1", resolution = "1080p")
        val r = d.request(InputSlots(), cat.tier("hd")!!.slots, RecastDraft(clipId = "c1"))
        assertEquals("kling-o1", r.engineModel); assertEquals("1080p", r.resolution)
        // fit() keeps a recast model (it isn't a shot engine).
        assertEquals("kling-o1", d.fit(cat).engineModel)
        // Auto sends nothing.
        assertNull(d.copy(engineModel = null, resolution = null).request(InputSlots(), cat.tier("hd")!!.slots, RecastDraft(clipId = "c1")).engineModel)
    }

    @Test fun aPickDoesNotCarryToAnotherKindOfWork() {
        val shot = ComposerDraft(tool = ComposerTool.SHOT, engineModel = "kling-v4", resolution = "720p")
        assertNull(shot.withTool(ComposerTool.RECAST).engineModel)
        assertEquals("kling-v4", shot.withTool(ComposerTool.TALKING).engineModel)
    }
}

/**
 * The shared model list (Swap's, the recast models) and Settings → Default models, all four themes at 390 dp.
 * PNGs: model_choice_<theme>_swap.png, default_models_<theme>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ModelChoiceScreenshotTest(private val theme: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").map { arrayOf<Any>(it) }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun swapList() {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val options = runBlocking { api.modelChoice.models(ModelPurpose.SWAP) }
        compose.setContent { MuseTheme(ThemeId.fromKey(theme)) { ModelChoiceContent(ModelPurpose.SWAP, options, ModelPick("kling-o1", "1080p"), null, {}, {}) } }
        idle()
        compose.onNodeWithText("Model for character swap").assertIsDisplayed()
        compose.onNodeWithText("Kling O1 Edit").assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/model_choice_${theme}_swap.png")
    }

    @Test fun defaultModels() {
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        runBlocking { fake.modelChoice.setDefault(ModelPurpose.SHOT, "kling-v4") }
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, Routes.DEFAULT_MODELS) }
        repeat(6) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onNodeWithText("Kling 4.0").assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/default_models_$theme.png")
    }
}
