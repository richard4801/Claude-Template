package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
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
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.ExtendRules
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.Take
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSheet
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SheetKind
import studio.muse.app.ui.screens.suite.composer.ToolSlots

private fun suiteJob(id: String, now: Long) = Job(id, "Café morning", SampleData.DEMO, "Demo model", SampleData.GREEN,
    JobRequest(title = "Café morning", modelId = SampleData.DEMO, outfitId = SampleData.GREEN, engine = SuiteRules.ENGINE, takes = 2, quality = "draft", seconds = 8.0, mode = "reference"),
    "done", 100.0, 2, phase = "Done", totalSeconds = 400.0, createdAt = now - 300_000, finishedAt = now - 240_000, thumb = ImageRef.asset("g_front"), serverEngineLabel = "Shot · Draft · 768p")

private fun suiteTake(jobId: String, i: Int, now: Long) = Take("t_${jobId}_$i", "take", jobId, i, 2, "Café morning", "Draft", "Shot · Draft · 768p", 0.16, 4210L + i,
    thumb = ImageRef.asset(if (i == 1) "g_front" else "g_tq"), createdAt = now - 240_000 + i, durationSec = 8.0, width = 1080, height = 1920)

/**
 * Extend on the composer (empty, a take in the VIDEO slot, the VIDEO picker) and Upscale on finished takes (the take's
 * actions, the Upscale sheet) in all four themes at 360, 390 and 840 dp. Demo mode: Upscale at the demo prices, 4K Soon.
 * PNGs: app/build/outputs/roborazzi/suite_extend_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteExtendUpscaleScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        val SCREENS = listOf("extend_empty", "extend_take", "extend_picker", "take_actions", "upscale_sheet")

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
        val s = c.suite
        val now = System.currentTimeMillis()
        runBlocking {
            fake.debugPut(suiteJob("jx", now)); listOf(1, 2).forEach { fake.debugPutTake(suiteTake("jx", it, now)) }
            c.repo.refresh()
        }
        when (screen) {
            "extend_empty" -> s.composer.value = ComposerDraft(tool = ComposerTool.EXTEND, duration = 5)
            "extend_take", "extend_picker" -> {
                s.composer.value = ComposerDraft(tool = ComposerTool.EXTEND, duration = 5, tokens = PromptTokens().withText("She turns from the counter and walks out into the rain."))
                s.pickExtendTake(c.repo.state.value.takes.first { it.id == "t_jx_1" })
                if (screen == "extend_picker") s.sheet.value = ComposerSheet(SheetKind.VIDEO)
            }
            "upscale_sheet" -> s.openUpscale("t_jx_1")
        }
        compose.mainClock.autoAdvance = false
        val route = if (screen.startsWith("extend")) Routes.suiteCompose("extend") else Routes.suiteTake("jx")
        compose.setContent { MuseApp(c, route) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_extend_${theme}_${screen}_$width.png")
    }
}

/** The store's side of Extend and Upscale: "Extend" on a take, Upscale's job and its 409 path (demo mode). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SuiteExtendUpscaleStoreTest {
    @Test fun `Extend on a take opens the composer on Extend with that take, and Upscale follows its job or greys on 409`() = runBlocking {
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(useFake = true, token = "t", role = "owner")), fake, null)
        val now = System.currentTimeMillis()
        fake.debugPut(suiteJob("jx", now)); fake.debugPutTake(suiteTake("jx", 1, now))
        c.repo.refresh()
        val s = c.suite
        val take = c.repo.state.value.takes.first { it.id == "t_jx_1" }
        assertTrue(s.startExtend(take))
        assertEquals(ComposerTool.EXTEND, s.composer.value.tool)
        assertEquals(ExtendRules.demoKey("t_jx_1"), s.extendSlots.value[ToolSlots.EXTEND_VIDEO]!!.media!!.key)
        assertEquals("Café morning · Take 1 · 8 s", s.extendSlots.value[ToolSlots.EXTEND_VIDEO]!!.name)
        // Upscale: the job is followed like any render and the sheet closes.
        s.openUpscale(take.id)
        val j = s.upscale(take.id, "1080p")!!
        assertEquals("Upscale · 1080p", j.engineLabel); assertEquals(0.16, j.cost, 1e-9)
        assertEquals(j.id, s.shotJobs.value.last()); assertNull(s.upscaleFor.value)
        assertTrue(c.repo.state.value.jobs.any { it.id == j.id })
        // 409 upscale_unavailable: no job, the sheet stays open with every size greyed.
        fake.debugSetUpscale(false)
        s.openUpscale(take.id)
        assertNull(s.upscale(take.id, "2k"))
        assertTrue(s.upscaleSoon.value); assertEquals(take.id, s.upscaleFor.value)
        assertFalse(studio.muse.app.data.UpscaleOffer.choices(c.repo.state.value.video!!.upscale, 8.0, s.upscaleSoon.value).any { it.available })
        scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
        Unit
    }
}
