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
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.Clip
import studio.muse.app.data.ClipRules
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.JobClock
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.core.Pricing

/**
 * Renders the key screens in all four themes with Robolectric + Roborazzi (no emulator needed).
 * Run `./gradlew :app:recordRoborazziDebug`; PNGs land in app/build/outputs/roborazzi/.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ScreenshotTest(private val theme: String, private val screen: String) {
    companion object {
        val SCREENS = listOf(
            "splash", "welcome", "signin", "signup", "home", "profile", "create1", "create3", "outfit", "shoot", "shoot_prompt",
            "source", "source_bad", "direct", "queue", "queue_run", "result", "gallery", "settings", "credits",
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.map { arrayOf<Any>(t, it) } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test
    fun capture() {
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, token = "t", studioName = "Jenne Studio", sound = false)), fake, null, soundsOn = false)
        val sample = Clip(SampleData.SAMPLE_CLIP, "Living-room dance", 9.4, 1080, 1920, 30, ClipRules.checks(SampleData.sampleMeta))
        when (screen) {
            "create3" -> runBlocking {
                c.drafts.modelId.value = SampleData.NOOR
                listOf("face" to "face", "profile" to "profile", "front" to "g_front").forEach { (k, img) ->
                    fake.setSlot(SampleData.NOOR, k, studio.muse.app.data.SetSlotRequest(studio.muse.app.data.ImageRef.asset(img)))
                }
            }
            "shoot_prompt" -> c.drafts.shoot.update { it.copy(tool = "spark", direction = "laughing mid-step, hair blowing") }
            "source", "direct" -> c.drafts.video.update { it.copy(clip = sample) }
            "source_bad" -> c.drafts.video.update {
                it.copy(clip = Clip(SampleData.BAD_CLIP, "Mirror trend (download)", 22.0, 1080, 1920, 30, ClipRules.checks(SampleData.badMeta)), showBadExample = true)
            }
            "queue_run" -> runBlocking {
                val req = JobRequest("Living-room dance", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP)
                val total = Pricing.totalSeconds(req.spec())
                val p = JobClock.progress(req, total * .42)
                fake.debugPut(Job("jr", "Living-room dance", SampleData.SIENNA, "Sienna Vale", SampleData.GREEN, req, "running", p.progress, p.take, p.step, p.totalSteps,
                    p.phase, p.secondsLeft, total, Pricing.totalCost(req.spec()), createdAt = System.currentTimeMillis(), thumb = studio.muse.app.data.ImageRef.asset("g_front")))
            }
        }
        val route = when (screen) {
            "shoot_prompt" -> Routes.SHOOT
            "source_bad" -> Routes.SOURCE
            "queue_run" -> Routes.QUEUE
            "result" -> Routes.HOME
            else -> screen
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, route, if (screen == "result") Routes.result("j1") else null) }
        repeat(6) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/${theme}_$screen.png")
    }
}
