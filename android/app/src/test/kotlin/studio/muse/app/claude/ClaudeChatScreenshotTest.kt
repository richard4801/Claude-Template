package studio.muse.app.claude

import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
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
import studio.muse.app.data.ApiFallbackStatus
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.ClaudeFallback
import studio.muse.app.data.ClaudeLive
import studio.muse.app.data.ClaudeEvent
import studio.muse.app.data.ClaudeTurn
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Nav
import studio.muse.app.ui.components.T
import studio.muse.app.ui.screens.camera.ConnectionActions
import studio.muse.app.ui.screens.camera.ConnectionsContent
import studio.muse.app.ui.screens.claude.ChatReducer
import studio.muse.app.ui.screens.claude.ClaudeButton
import studio.muse.app.ui.screens.claude.ClaudeChatActions
import studio.muse.app.ui.screens.claude.ClaudeChatContent
import studio.muse.app.ui.screens.claude.ClaudeChatUi
import studio.muse.app.ui.screens.claude.ClaudeSheetFrame
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse

/**
 * The Claude chat (claude-editing.md part E) in all four themes: a relayed turn streaming, the idle transcript, the Mac
 * offline (with and without the API fallback), the phone sheet, a tablet's right panel, and Settings → Connections with
 * "Claude on your plan" and "Add MUSE to Claude". PNGs: app/build/outputs/roborazzi/claude_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ClaudeChatScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        private val CASES = listOf(
            "streaming" to 390, "streaming" to 360, "idle" to 390, "offline" to 390, "offline" to 360, "offline_api" to 390,
            "sheet" to 390, "sheet" to 360, "panel" to 1024, "connections" to 390, "connections" to 360,
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
            1024 -> RuntimeEnvironment.setQualifiers("w1024dp-h768dp-mdpi")
        }
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val api = fake.claude
        val thread = runBlocking { api.thread("camera", FakeCameraApi.SEED_ID).let { api.getThread(it.id) } }
        val status = runBlocking { api.status() }
        val idleUi = ChatReducer.loaded(ClaudeChatUi("camera", FakeCameraApi.SEED_ID, status = status), thread)
        val streaming = listOf(
            ClaudeLive("turn", turn = ClaudeTurn("tu_9", thread.id, "Slower push, and keep Noor’s face in frame at the end.", "phone", "running")),
            ClaudeLive("event", threadId = thread.id, turnId = "tu_9", event = ClaudeEvent("text", delta = "Pushing in slower over the first 3 s and keeping both faces in frame.")),
            ClaudeLive("event", threadId = thread.id, turnId = "tu_9", event = ClaudeEvent("tool", id = "tl9", name = "mcp__muse__set_camera_path", status = "done", summary = "Saved camera path")),
            ClaudeLive("event", threadId = thread.id, turnId = "tu_9", event = ClaudeEvent("tool", id = "tl10", name = "mcp__muse__create_shot_draft", status = "running")),
            ClaudeLive("event", threadId = thread.id, turnId = "tu_9", event = ClaudeEvent("text", delta = "Now updating the Shot draft so the estimate")),
        ).fold(idleUi) { u, l -> ChatReducer.live(u, l) }
        val offline = idleUi.copy(status = status.copy(mac = status.mac.copy(online = false)), refusal = ClaudeFallback(status.openInClaudeUrl, false),
            refusedText = "Lower the camera", draft = "Lower the camera")
        val ui = when (screen) {
            "streaming", "sheet", "panel" -> streaming
            "offline" -> offline
            "offline_api" -> offline.copy(status = offline.status!!.copy(apiFallback = ApiFallbackStatus(true, true)), refusal = ClaudeFallback(status.openInClaudeUrl, true))
            else -> idleUi
        }
        val conn = runBlocking { fake.camera.connections() }
        val tokens = runBlocking { fake.camera.tokens() }
        compose.mainClock.autoAdvance = false
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                val nav = Nav(rememberNavController())
                CompositionLocalProvider(LocalContainer provides c, LocalNav provides nav) {
                    val m = muse
                    when (screen) {
                        "connections" -> ConnectionsContent(conn, tokens, null, System.currentTimeMillis(), null, ConnectionActions(),
                            status.copy(mac = status.mac.copy(online = false)))
                        "sheet" -> Box(Modifier.fillMaxSize().background(m.t.bg)) {
                            T("Edit suite", m.type.h3, m.t.ink, Modifier.padding(20.dp))
                            ClaudeButton({}, Modifier.align(Alignment.TopEnd).padding(12.dp))
                            ClaudeSheetFrame({}) { ClaudeChatContent(ui, "Claude", ClaudeChatActions(), Modifier.fillMaxSize()) }
                        }
                        "panel" -> Row(Modifier.fillMaxSize().background(m.t.bg)) {
                            Box(Modifier.weight(1f).fillMaxHeight().background(m.t.surface2), contentAlignment = Alignment.Center) { T("Edit suite preview", m.type.tiny, m.t.muted) }
                            ClaudeChatContent(ui, "Claude", ClaudeChatActions(), Modifier.width(380.dp).fillMaxHeight())
                        }
                        else -> ClaudeChatContent(ui, "Direct with Claude", ClaudeChatActions(), Modifier.fillMaxSize())
                    }
                }
            }
        }
        repeat(4) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        fun has(text: String) = check(compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty() ||
            compose.onAllNodesWithContentDescription(text, substring = true).fetchSemanticsNodes().isNotEmpty()) { "missing: $text" }
        when (screen) {
            "streaming", "sheet", "panel" -> { has("Your Mac is answering"); has("Stop"); has("Saved camera path"); has("Making a shot draft") }
            "idle" -> { has("On your Claude plan, answered by your Mac"); has("Shot draft · $1.92") }
            "offline" -> { has("Open in Claude"); has("Turn on the API fallback") }
            "offline_api" -> has("Use the studio API key")
            "connections" -> { has("Claude on your plan"); has("Add MUSE to Claude"); has("billed per use") }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/claude_${theme}_${screen}_$width.png")
    }
}
