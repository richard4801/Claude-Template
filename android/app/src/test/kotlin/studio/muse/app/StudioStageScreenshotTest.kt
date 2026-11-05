package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.update
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
import studio.muse.app.data.Clip
import studio.muse.app.data.ClipRules
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Job
import studio.muse.app.data.JobClock
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.data.Take
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.core.Engine
import studio.muse.core.Pricing

/**
 * The Video studio's stage (owner request 2026-11-05) in all four themes: idle, waiting in line, rendering, ready (two takes,
 * the take switcher, unmute, Open / Edit video / Generate again) and failed (Try again); and the empty source before a clip
 * is uploaded on a server (no sample clip) with the stage's empty placeholder. Each on a 390 dp phone and a small 360 dp one.
 * PNGs land in app/build/outputs/roborazzi/stage_<theme>_<state>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class StudioStageScreenshotTest(private val theme: String, private val state: String, private val width: Int) {
    companion object {
        val STATES = listOf("idle", "queued", "rendering", "ready", "failed", "source_empty", "direct_empty")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> STATES.flatMap { s -> listOf(390, 360).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        if (width == 360) RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        // The empty source is the real app (a server, signed out so nothing loads over the network): no sample clip there.
        // The empty stage is the demo studio before a clip is picked (its models show as the target).
        val server = state == "source_empty"
        val noClip = state.endsWith("_empty")
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = !server, token = if (server) null else "t", studioName = "Jenne Studio", role = "owner",
            email = "jenne@studio.com")), fake, null)
        val clip = Clip("clip_7s", "Kitchen dance", 7.0, 1080, 1920, 30, ClipRules.checks(SampleData.sampleMeta))
        if (!noClip) c.drafts.video.update { it.copy(clip = clip) }
        val req = JobRequest("Kitchen dance", SampleData.DEMO, SampleData.GREEN, clip.id, Engine.REPLICATE.id, quality = "draft", takes = 2, clipSeconds = 7.0)
        val total = Pricing.totalSeconds(req.spec())
        val cost = Pricing.totalCost(req.spec())
        val now = System.currentTimeMillis()
        fun job(st: String) = Job("js", "Kitchen dance", SampleData.DEMO, "Demo model", SampleData.GREEN, req, st, totalSeconds = total, cost = cost, createdAt = now,
            thumb = ImageRef.asset("g_front"))
        val stageJob = when (state) {
            "queued" -> job("running").copy(phase = "Waiting to start", secondsLeft = total, queuePosition = 2, etaSeconds = 540.0)
            "rendering" -> JobClock.progress(req, total * .42).let { p -> job("running").copy(progress = p.progress, take = p.take, step = p.step, phase = p.phase, secondsLeft = p.secondsLeft) }
            "ready" -> job("done").copy(progress = 100.0, phase = "Done", finishedAt = now)
            "failed" -> job("failed").copy(progress = 18.0, phase = "Failed", refunded = cost, errorCode = "provider_refused",
                error = "This clip was refused by the content filter · you weren't charged")
            else -> null
        }
        if (stageJob != null) runBlocking {
            fake.debugPut(stageJob)
            if (state == "ready") listOf(1, 2).forEach { i ->
                fake.debugPutTake(Take("t_js_$i", "take", "js", i, 2, "Kitchen dance", "Draft", "Draft · 768P", cost / 2, 4210L + i, thumb = ImageRef.asset(if (i == 1) "g_front" else "g_tq"),
                    createdAt = now + i, videoUrl = "/uploads/r/js/take_$i.mp4", durationSec = 7.0, width = 768, height = 1344))
            }
            c.stageJobs.started("js")
        }
        val route = if (state == "source_empty") Routes.SOURCE else Routes.DIRECT
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, route) }
        repeat(6) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/stage_${theme}_${state}_$width.png")
    }
}
