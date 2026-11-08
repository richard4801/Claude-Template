package studio.muse.app

import android.os.Looper
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.navigation.compose.rememberNavController
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
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
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.Take
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Nav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerSheet
import studio.muse.app.ui.screens.suite.composer.PromptPart
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SheetKind
import studio.muse.app.ui.screens.suite.composer.SuiteFeedView
import studio.muse.app.ui.screens.suite.saveRig
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * The AI suite plan in the current Suite (plans/ai-suite-design.md): the Rigs sheet (saved rigs, save, a character's
 * default), the Rigs row after a rig is applied (Undo), the results feed, Compare, and a take's actions (Vary up front).
 * PNGs: app/build/outputs/roborazzi/suiteplan_<theme>_<state>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteFeedScreenshotTest(private val theme: String, private val state: String, private val width: Int) {
    companion object {
        private val CASES = listOf("rigs" to 360, "rig_applied" to 360, "feed" to 360, "feed" to 840, "compare" to 360, "compare" to 840, "take" to 360)

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> CASES.map { (s, w) -> arrayOf<Any>(t, s, w) } }
    }

    @get:Rule val compose = createComposeRule()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun job(id: String, state: String, now: Long, progress: Double = 100.0) = Job(id, if (state == "failed") "Rain on the window" else "Café morning", SampleData.DEMO, "Demo model", SampleData.GREEN,
        JobRequest(title = "Café morning", modelId = SampleData.DEMO, outfitId = SampleData.GREEN, engine = SuiteRules.ENGINE, takes = 1, quality = "hd", seconds = 8.0, mode = "reference"),
        state, progress, 1, phase = "Rendering", totalSeconds = 400.0, cost = 1.04, createdAt = now, finishedAt = if (state == "done") now - 240_000 else null, thumb = ImageRef.asset("g_tq"),
        error = if (state == "failed") "Something went wrong · you weren't charged" else null)

    private fun take(id: String, jobId: String, now: Long, asset: String) = Take(id, "take", jobId, 1, 1, "Café morning", "HD", "Shot · HD", 1.04, 4210L,
        thumb = ImageRef.asset(asset), createdAt = now, durationSec = 8.0, width = 1440, height = 2560)

    @Test fun capture() {
        if (width == 840) RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi") else RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val now = System.currentTimeMillis()
        runBlocking {
            fake.debugPut(job("ja", "done", now)); fake.debugPutTake(take("t_a", "ja", now, "g_front"))
            fake.debugPut(job("jb", "done", now - 60_000)); fake.debugPutTake(take("t_b", "jb", now - 60_000, "g_tq"))
            fake.debugPut(job("jc", "running", now - 1_000, 42.0)); fake.debugPut(job("jd", "failed", now - 120_000, 0.0))
            c.repo.refresh(); c.suite.load()
        }
        val model = c.repo.state.value.models.first()
        val cam = fake.suite.camera
        when (state) {
            "rigs", "rig_applied" -> runBlocking {
                c.suite.composer.value = ComposerDraft(settings = ComposerSettings(body = cam.bodies.first().id, lens = cam.lenses.first().id))
                c.suite.saveRig("Golden hour handheld")
                c.suite.composer.value = ComposerDraft(tokens = PromptTokens(listOf(PromptPart.Mention("character", model.id, model.name.substringBefore(' '), 1), PromptPart.Text(" walks into the café"))),
                    settings = ComposerSettings(body = cam.bodies.first().id), modelId = model.id)
                if (state == "rigs") c.suite.sheet.value = ComposerSheet(SheetKind.RIGS)
                else c.suite.rigUndo.value = "Applied Golden hour handheld" to ComposerDraft()
            }
            "compare" -> c.suite.compareIds.value = listOf("t_a", "t_b")
        }
        compose.setContent {
            when (state) {
                "feed" -> MuseTheme(ThemeId.fromKey(theme)) {
                    CompositionLocalProvider(LocalContainer provides c, LocalNav provides Nav(rememberNavController())) {
                        SuiteFeedView(photo = false, wide = width == 840, onOpen = {}, modifier = Modifier.fillMaxSize())
                    }
                }
                "take" -> MuseApp(c, Routes.suiteTake("ja"))
                else -> MuseApp(c, Routes.SUITE_SHOT)
            }
        }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suiteplan_${theme}_${state}_$width.png")
    }
}
