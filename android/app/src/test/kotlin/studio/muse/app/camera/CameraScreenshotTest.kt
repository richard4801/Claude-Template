package studio.muse.app.camera

import android.os.Looper
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
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
import studio.muse.app.AppContainer
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.CameraAsset
import studio.muse.app.data.ClaudeStatus
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.RelayStatus
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Nav
import studio.muse.app.ui.screens.camera.CameraStageScreen
import studio.muse.app.ui.screens.camera.CameraUi
import studio.muse.app.ui.screens.camera.ChatActions
import studio.muse.app.ui.screens.camera.ChatTurn
import studio.muse.app.ui.screens.camera.ConnectionActions
import studio.muse.app.ui.screens.camera.ConnectionsContent
import studio.muse.app.ui.screens.camera.DirectWithClaudeContent
import studio.muse.app.ui.screens.camera.DirectedModePanel
import studio.muse.app.ui.screens.camera.DirectedCameraPaneContent
import studio.muse.app.ui.screens.camera.PaneActions
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * Directed (Blender) mode in all four themes (plans/mcp-bridge.md "Phase 2 · UI"): phone M5 Direct with Claude (working with
 * guides, idle, Blender offline, Mac offline · with the Claude chat on the owner's plan), owner Settings → Connections (tokens + a new token shown once),
 * the Camera stage sessions list (through CameraStageScreen and the demo studio), the Shot builder's Directed tab (DirectedModePanel) and the wide D6 pane at 1280 dp.
 * PNGs land in app/build/outputs/roborazzi/camera_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class CameraScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        private val CASES = listOf(
            "m5_working" to 390, "m5_working" to 360, "m5_idle" to 390, "m5_blender_offline" to 390, "m5_mac_offline" to 390,
            "connections" to 390, "connections" to 360, "sessions" to 390, "sessions" to 360, "panel" to 360, "pane" to 1280,
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> CASES.map { (s, w) -> arrayOf<Any>(t, s, w) } }
    }

    @get:Rule val compose = createComposeRule()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        when (width) {
            360 -> RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
            1280 -> RuntimeEnvironment.setQualifiers("w1280dp-h800dp-mdpi")
        }
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val cam = fake.camera
        val now = System.currentTimeMillis()
        val seed = runBlocking { cam.session(FakeCameraApi.SEED_ID) }
        val conn = runBlocking { cam.connections() }
        val base = CameraUi(sessions = listOf(seed), listLoaded = true, openId = seed.id, session = seed.copy(messages = null), messages = seed.messages!!,
            connections = conn, playhead = 2.4)
        val ask = "Slower orbit, and keep ${seed.characters[1].name.substringBefore(' ')}’s face visible at the end."
        val ui = when (screen) {
            "m5_working", "pane" -> base.copy(
                session = base.session!!.copy(assets = base.session!!.assets + CameraAsset("ca_up1", "greybox", state = "pending", contentType = "video/mp4", createdAt = now)),
                turn = ChatTurn(ask, seed.revision, toolsSeen = 2, toolsDone = 1, text = "Easing the orbit to 45°/s and pivoting around ${seed.characters[1].name.substringBefore(' ')}…", renderProgress = .64f),
                sentHere = setOf(ask))
            "m5_blender_offline" -> base.copy(session = base.session!!.copy(relay = RelayStatus(false, false)))
            "m5_mac_offline" -> base.copy(session = base.session!!.copy(claude = ClaudeStatus(false, null), relay = RelayStatus(false, false)))
            else -> base
        }
        if (screen == "m5_mac_offline") fake.claude.setMac(online = false)
        val tokens = runBlocking { cam.tokens() }
        val created = if (screen == "connections") runBlocking { cam.createToken("Claude Desktop · Studio Mac") } else null
        compose.mainClock.autoAdvance = false
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                val nav = Nav(rememberNavController())
                CompositionLocalProvider(LocalContainer provides c, LocalNav provides nav) {
                    when (screen) {
                        "connections" -> ConnectionsContent(conn, listOf(created!!.copy(token = null)) + tokens, created, now, null, ConnectionActions())
                        "sessions" -> CameraStageScreen()
                        "panel" -> DirectedModePanel("Shot 01") {}
                        "pane" -> DirectedCameraPaneContent(ui, now, ChatActions(use = {}, useLabel = "Use for Shot 01"), PaneActions(dragCharacter = { _, _ -> }, dragCamera = {}, back = {}))
                        else -> DirectWithClaudeContent(ui, now, ChatActions(use = {}, useLabel = "Use for Shot 01"))
                    }
                }
            }
        }
        repeat(6) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        when (screen) {
            "sessions" -> check(compose.onAllNodesWithText("Café walk-and-talk").fetchSemanticsNodes().isNotEmpty())
            "connections" -> check(compose.onAllNodesWithText("You won't see it again", substring = true).fetchSemanticsNodes().isNotEmpty())
            "m5_mac_offline" -> check(compose.onAllNodesWithText("Open in Claude").fetchSemanticsNodes().isNotEmpty())
            "panel" -> check(compose.onAllNodesWithText("Open Direct with Claude").fetchSemanticsNodes().isNotEmpty())
            "m5_working", "m5_idle" -> check(compose.onAllNodesWithText("Saved camera path").fetchSemanticsNodes().isNotEmpty())
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/camera_${theme}_${screen}_$width.png")
    }
}
