package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSheet
import studio.muse.app.ui.screens.suite.composer.ModelPicker
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SheetKind
import studio.muse.app.ui.screens.suite.composer.modelLabel
import studio.muse.app.ui.screens.suite.composer.pinEngine

/** WS7: the owner's model picker logic (the Mac's "Model" pill on Android). */
class ModelPickerLogicTest {
    private val owner = FakeSuite().catalog(owner = true)
    private val member = FakeSuite().catalog(owner = false)

    @Test fun groupsPutThisQualityFirstThenOthersThenYours() {
        val g = ModelPicker.groups(owner, "hd")
        assertTrue(g.ladder.isNotEmpty() && g.ladder.all { it.tier == "hd" })
        assertTrue(g.others.none { it.tier == "hd" })
        assertEquals(listOf("c_demo2"), g.custom.map { it.id })
        // Every ladder row carries a price per second and lengths from the demo registry.
        assertTrue(g.ladder.all { it.perSec != null && it.maxSeconds != null })
    }

    @Test fun membersGetNoModels() {
        assertTrue(ModelPicker.groups(member, "hd").isEmpty)
        assertNull(member.engines)
    }

    @Test fun pickingALadderEngineMovesQualityAndClampsLength() {
        val veo = ModelPicker.groups(owner, "standard").all.first { it.id == "veo-3.1-lite" && it.tier == "draft" }
        val d = ComposerDraft(quality = "standard", duration = 12).pinEngine(veo)
        assertEquals("draft", d.quality)
        assertEquals(8, d.duration)
        assertEquals(4..8, d.lengthRange(owner))
        assertEquals("Veo 3.1 Lite · 720p", d.modelLabel(owner))
        // Fit keeps the pin on its own quality, and drops it on another.
        assertEquals("veo-3.1-lite", d.fit(owner).engineModel)
        assertNull(d.copy(quality = "cinema").fit(owner).engineModel)
    }

    @Test fun customModelKeepsQualityAndClampsShape() {
        val mine = ModelPicker.groups(owner, "hd").custom.single()
        val d = ComposerDraft(quality = "hd", duration = 15, aspect = "4:5").pinEngine(mine)
        assertEquals("hd", d.quality)
        assertEquals(10, d.duration)
        assertEquals("9:16", d.aspect)
        assertEquals("c_demo2", d.fit(owner).engineModel)
        assertTrue(d.inputsFor(owner).start)
        assertFalse(d.inputsFor(owner).end)
        assertEquals("$0.07/s", mine.price)
    }

    @Test fun autoGoesBack() {
        val mine = ModelPicker.groups(owner, "hd").custom.single()
        val d = ComposerDraft(quality = "hd").pinEngine(mine).pinEngine(null)
        assertNull(d.engineModel); assertNull(d.resolution)
        assertEquals("Auto", d.modelLabel(owner))
    }

    @Test fun rates() {
        assertEquals("$0.065", ModelPicker.rate(0.065))
        assertEquals("$0.13", ModelPicker.rate(0.13))
        assertEquals("$1.20", ModelPicker.rate(1.2))
    }

    @Test fun pinnedEnginePricesTheDemoEstimate() = runBlocking {
        val api = FakeSuite()
        val base = studio.muse.app.data.SuiteShotRequest(prompt = "x", quality = "hd", duration = 5)
        val auto = api.estimate(base, true, emptyList(), null)
        val mine = api.estimate(base.copy(engineModel = "c_demo2"), true, emptyList(), null)
        assertEquals(0.65, auto.estimate, 1e-9)
        assertEquals(0.35, mine.estimate, 1e-9)
    }
}

/**
 * The model list in the composer's Settings sheet (phone), all four themes at 390 dp: Auto opened by tapping the row, a
 * ladder engine of another quality pinned, a custom model pinned. A member's sheet has no Model row (asserted).
 * PNGs: app/build/outputs/roborazzi/model_picker_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ModelPickerScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> listOf("auto", "ladder", "custom").map { s -> arrayOf<Any>(t, s) } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        if (state != "member") RuntimeEnvironment.setQualifiers("w390dp-h1400dp-xhdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val role = if (state == "member") "member" else "owner"
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = role, email = "jenne@studio.com")), fake, null)
        val cat = fake.suite.catalog(owner = true)
        var d = ComposerDraft(tokens = PromptTokens().withText("She walks into a quiet café at golden hour"), modelId = SampleData.DEMO, quality = "hd", duration = 8)
        when (state) {
            "ladder" -> d = d.pinEngine(ModelPicker.groups(cat, "hd").others.first { it.id == "kling-v4" && it.tier == "standard" })
            "custom" -> d = d.pinEngine(ModelPicker.groups(cat, "hd").custom.single())
        }
        c.suite.composer.value = d
        c.suite.sheet.value = ComposerSheet(SheetKind.SETTINGS)
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, Routes.SUITE_SHOT) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        if (state == "member") {
            assertTrue(compose.onAllNodesWithTag("model_picker").fetchSemanticsNodes().isEmpty())
            assertTrue(compose.onAllNodesWithText("Model ·", substring = true).fetchSemanticsNodes().isEmpty())
        } else {
            if (state == "auto") { compose.onNodeWithText("Model · Auto").performClick(); repeat(3) { idle(); compose.mainClock.advanceTimeBy(400) } }
            assertEquals(1, compose.onAllNodesWithTag("model_picker", useUnmergedTree = true).fetchSemanticsNodes().size)
            // Scroll the sheet to the end of the list: "Your providers" and the custom model.
            compose.onAllNodesWithText("Your providers", useUnmergedTree = true).onFirst().performScrollTo()
            repeat(3) { idle(); compose.mainClock.advanceTimeBy(400) }
            compose.onAllNodesWithText("Kling turbo", substring = true, useUnmergedTree = true).onFirst().assertIsDisplayed()
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/model_picker_${theme}_$state.png")
    }
}
