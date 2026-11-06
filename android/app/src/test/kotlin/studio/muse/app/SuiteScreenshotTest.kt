package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
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
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.RecastPerson
import studio.muse.app.ui.screens.suite.StoryShot
import studio.muse.app.ui.screens.suite.Storyboard
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerTool

/**
 * The Video suite in all four themes on a 390 dp and a 360 dp phone: the hub (M1), suite off for the owner and a member,
 * Character swap and Recast (the composer on those tools), Storyboard (M7), the result states (M8 / D10: ready, rendering,
 * in line, failed) and the owner's Engines (D9). The composer itself is in SuiteComposerScreenshotTest.
 * PNGs: app/build/outputs/roborazzi/suite_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        val SCREENS = listOf("hub", "hub_off_owner", "hub_off_member", "swap", "swap_recast", "storyboard", "take_ready", "take_rendering", "take_queued", "take_failed", "engines")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.flatMap { s -> listOf(390, 360).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun job(id: String, title: String, state: String, progress: Double, take: Int = 1, takes: Int = 2, quality: String = "hd", queue: Int? = null, now: Long) =
        Job(id, title, SampleData.DEMO, "Demo model", SampleData.GREEN, JobRequest(title = title, modelId = SampleData.DEMO, outfitId = SampleData.GREEN, engine = SuiteRules.ENGINE,
            takes = takes, quality = quality, seconds = 8.0, mode = "reference"), state, progress, take, phase = if (state == "running") "take $take/$takes · Rendering · ~2 min left" else "Done",
            secondsLeft = if (state == "running") 110.0 else 0.0, totalSeconds = 400.0, cost = 2.08, createdAt = now, finishedAt = if (state == "done") now - 240_000 else null,
            thumb = ImageRef.asset("g_front"), queuePosition = queue, serverEngineLabel = "Shot · HD · 2K",
            errorCode = if (state == "failed") "provider_failed" else null, error = if (state == "failed") "Something went wrong · you weren't charged" else null, refunded = if (state == "failed") 2.08 else 0.0)

    private fun take(jobId: String, i: Int, now: Long) = Take("t_${jobId}_$i", "take", jobId, i, 2, "Café morning", "HD", "Shot · HD · 2K", 1.04, 4210L + i,
        thumb = ImageRef.asset(if (i == 1) "g_front" else "g_tq"), createdAt = now - 240_000 + i, durationSec = 8.0, width = 1440, height = 2560)

    @Test fun capture() {
        if (width == 360) RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val member = screen == "hub_off_member"
        fake.suiteOwner = !member
        fake.suiteEnabled = !screen.startsWith("hub_off")
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = if (member) "member" else "owner",
            email = if (member) "maya@studio.com" else "jenne@studio.com")), fake, null)
        val now = System.currentTimeMillis()
        runBlocking {
            when (screen) {
                "hub" -> {
                    fake.debugPut(job("jr", "Café morning", "done", 100.0, now = now - 60_000)); take("jr", 1, now).let { fake.debugPutTake(it) }
                    fake.debugPut(job("jp", "Turn to camera", "running", 62.0, take = 2, now = now - 30_000))
                    fake.debugPut(job("jq", "Selfie review", "running", 0.0, queue = 2, now = now))
                }
                "take_ready" -> { fake.debugPut(job("js", "Café morning", "done", 100.0, now = now)); listOf(1, 2).forEach { fake.debugPutTake(take("js", it, now)) } }
                "take_rendering" -> { fake.debugPut(job("js", "Café morning", "running", 62.0, take = 2, now = now)); fake.debugPutTake(take("js", 1, now)) }
                "take_queued" -> fake.debugPut(job("js", "Café morning", "running", 0.0, queue = 2, now = now))
                "take_failed" -> fake.debugPut(job("js", "Café morning", "failed", 18.0, now = now))
                "storyboard" -> {
                    fake.debugPut(job("b1", "Café GRWM · 1", "done", 100.0, takes = 1, now = now - 90_000)); fake.debugPutTake(take("b1", 1, now))
                    fake.debugPut(job("b2", "Café GRWM · 2", "done", 100.0, takes = 1, now = now - 80_000)); fake.debugPutTake(take("b2", 2, now))
                    fake.debugPut(job("b3", "Café GRWM · 3", "running", 40.0, takes = 1, now = now - 10_000))
                    c.suite.board.value = Storyboard("Café GRWM", listOf(SampleData.DEMO, SampleData.NOOR), "cinematic", "hd", listOf(
                        StoryShot("s1", "Street → café door", "Demo walks in from the rain.", "handheld", 3, "b1"),
                        StoryShot("s2", "Order at the counter", "Demo orders a flat white.", "dolly_in", 4, "b2"),
                        StoryShot("s3", "Turn to camera, smile", "Demo turns to camera and smiles.", "orbit_left", 5, "b3"),
                        StoryShot("s4", "Noor joins at the window", "Noor joins Demo at the window seat.", "track_side", 4),
                        StoryShot("s5", "Selfie review, close", "Demo gives the café a 10/10.", "selfie", 5),
                    ))
                }
                "swap" -> {
                    c.suite.recast.value = RecastDraft(SampleData.SAMPLE_CLIP, listOf(RecastPerson("center", SampleData.DEMO)))
                    c.suite.composer.value = ComposerDraft(tool = ComposerTool.SWAP, modelId = SampleData.DEMO, outfitId = SampleData.GREEN, quality = "standard")
                }
                "swap_recast" -> {
                    c.suite.recast.value = RecastDraft(SampleData.SAMPLE_CLIP, listOf(RecastPerson("left", SampleData.DEMO, speaking = true), RecastPerson("right", SampleData.NOOR, speaking = false)))
                    c.suite.composer.value = ComposerDraft(tool = ComposerTool.RECAST, quality = "hd")
                }
            }
        }
        val route = when {
            screen.startsWith("hub") -> Routes.SUITE
            screen == "swap" -> Routes.SUITE_SWAP
            screen == "swap_recast" -> Routes.suiteCompose("recast")
            screen == "storyboard" -> Routes.SUITE_STORYBOARD
            screen == "engines" -> Routes.SUITE_ENGINES
            else -> Routes.suiteTake("js")
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, route) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_${theme}_${screen}_$width.png")
    }
}
