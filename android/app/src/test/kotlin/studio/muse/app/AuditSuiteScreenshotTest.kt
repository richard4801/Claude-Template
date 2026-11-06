package studio.muse.app

import android.os.Looper
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.navigation.compose.rememberNavController
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.ApiException
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.MuseApi
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.Take
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Nav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.claude.ChatReducer
import studio.muse.app.ui.screens.claude.ClaudeChatActions
import studio.muse.app.ui.screens.claude.ClaudeChatContent
import studio.muse.app.ui.screens.claude.ClaudeChatUi
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * Second UX audit (plans/ux-audit-2-android.md): the video suite's states the other screenshot tests miss, in all four
 * themes: the composer while the catalog loads and when it can't, the hub's error, the hub and a take's result on an
 * 840 dp tablet, the rig check at 360 dp, the empty and the filled composer at 360 dp with a long preset picked, and the
 * Claude chat while it opens, when it couldn't open and Mac-offline on a tablet.
 * PNGs: app/build/outputs/roborazzi/audit2_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class AuditSuiteScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        private val CASES = listOf(
            "composer_loading" to 360, "composer_error" to 360, "hub_error" to 360, "hub" to 840, "take_ready" to 840, "take_failed" to 840, "take_ready" to 360,
            "rig_warn" to 360, "rig_more2" to 360, "chat_loading" to 360, "chat_error" to 360, "chat_offline" to 840,
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> CASES.map { (s, w) -> arrayOf<Any>(t, s, w) } }
    }

    /** The real API whose suite catalog and estimate never answer ([hang]) or can't be reached. */
    private class SuiteDown(private val f: FakeMuseApi, private val hang: Boolean) : MuseApi by f {
        private suspend fun <T> gate(): T = if (hang) awaitCancellation() else throw ApiException("network", "Can't reach the server. Check your connection and try again.")
        override suspend fun suiteCatalog(): SuiteCatalog = gate()
        override suspend fun suiteEstimate(req: SuiteShotRequest): SuiteEstimate = gate()
    }

    @get:Rule val compose = createComposeRule()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private fun job(id: String, state: String, now: Long) = Job(id, "Café morning", SampleData.DEMO, "Demo model", SampleData.GREEN,
        JobRequest(title = "Café morning", modelId = SampleData.DEMO, outfitId = SampleData.GREEN, engine = SuiteRules.ENGINE, takes = 2, quality = "hd", seconds = 8.0, mode = "reference"),
        state, if (state == "done") 100.0 else 18.0, 1, phase = "Done", secondsLeft = 0.0, totalSeconds = 400.0, cost = 2.08, createdAt = now, finishedAt = if (state == "done") now - 240_000 else null,
        thumb = ImageRef.asset("g_front"), errorCode = if (state == "failed") "provider_failed" else null, error = if (state == "failed") "Something went wrong · you weren't charged" else null)

    private fun take(i: Int, now: Long) = Take("t_js_$i", "take", "js", i, 2, "Café morning", "HD", "Shot · HD · 2K", 1.04, 4210L + i,
        thumb = ImageRef.asset(if (i == 1) "g_front" else "g_tq"), createdAt = now - 240_000 + i, durationSec = 8.0, width = 1440, height = 2560)

    @Test fun capture() {
        when (width) {
            360 -> RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
            840 -> RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        }
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val down = screen == "composer_loading" || screen == "composer_error" || screen == "hub_error"
        val prefs = AppPrefs(theme = theme, useFake = !down, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")
        val c = AppContainer(scope, MemoryPrefs(prefs), fake, null, httpFactory = { SuiteDown(FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0), screen == "composer_loading") })
        val now = System.currentTimeMillis()
        val cat = fake.suite.camera
        when (screen) {
            "take_ready" -> runBlocking { fake.debugPut(job("js", "done", now)); listOf(1, 2).forEach { fake.debugPutTake(take(it, now)) } }
            "take_failed" -> runBlocking { fake.debugPut(job("js", "failed", now)) }
            "rig_warn" -> c.suite.composer.value = ComposerDraft(tokens = PromptTokens().withText("Low angle as she steps off the tram, coat catching the wind"), modelId = SampleData.DEMO,
                settings = ComposerSettings(height = "high"))
            "rig_more2" -> {
                var t = PromptTokens().withText("She talks to camera about her morning ")
                t = t.addMove(cat.move("orbit_left")!!, t.caretAtEnd).first
                c.suite.composer.value = ComposerDraft(tokens = t, modelId = SampleData.DEMO, speaking = true,
                    settings = ComposerSettings(body = "phone", aperture = "f1.4", focalMm = 14, shotSize = "cu"))
            }
            "hub" -> runBlocking { fake.debugPut(job("jr", "done", now - 60_000)); fake.debugPutTake(take(1, now).copy(jobId = "jr")) }
        }
        compose.mainClock.autoAdvance = false
        if (screen.startsWith("chat")) {
            val api = fake.claude
            val thread = runBlocking { api.thread("camera", FakeCameraApi.SEED_ID).let { api.getThread(it.id) } }
            val status = runBlocking { api.status() }
            val idleUi = ChatReducer.loaded(ClaudeChatUi("camera", FakeCameraApi.SEED_ID, status = status), thread)
            val ui = when (screen) {
                "chat_loading" -> ClaudeChatUi("camera", FakeCameraApi.SEED_ID)
                "chat_error" -> ClaudeChatUi("camera", FakeCameraApi.SEED_ID, loaded = true, error = "Can't reach the server. Check your connection and try again.")
                else -> idleUi.copy(status = status.copy(mac = status.mac.copy(online = false)))
            }
            compose.setContent {
                MuseTheme(ThemeId.fromKey(theme)) {
                    CompositionLocalProvider(LocalContainer provides c, LocalNav provides Nav(rememberNavController())) {
                        ClaudeChatContent(ui, "Direct with Claude", ClaudeChatActions(), Modifier.fillMaxSize())
                    }
                }
            }
        } else {
            val route = when (screen) {
                "hub", "hub_error" -> Routes.SUITE
                "take_ready", "take_failed" -> Routes.suiteTake("js")
                else -> Routes.SUITE_SHOT
            }
            compose.setContent { MuseApp(c, route) }
        }
        repeat(10) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/audit2_${theme}_${screen}_$width.png")
    }
}
