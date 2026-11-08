package studio.muse.app.claude

import android.os.Looper
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
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
import studio.muse.app.data.ClaudeEvent
import studio.muse.app.data.ClaudeFallback
import studio.muse.app.data.ClaudeLive
import studio.muse.app.data.ClaudeMessage
import studio.muse.app.data.ClaudeThread
import studio.muse.app.data.ClaudeToolRef
import studio.muse.app.data.ClaudeTurn
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Nav
import studio.muse.app.ui.components.T
import studio.muse.app.ui.screens.claude.ChatReducer
import studio.muse.app.ui.screens.claude.ClaudeChatActions
import studio.muse.app.ui.screens.claude.ClaudeChatContent
import studio.muse.app.ui.screens.claude.ClaudeChatUi
import studio.muse.app.ui.screens.claude.ClaudeSheetFrame
import studio.muse.app.ui.screens.claude.LiveTurn
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/**
 * Every Claude chat surface (plans/claude-chat-android.md) in all four themes, on a phone (portrait and, with the keyboard,
 * landscape) and a tablet, with the keyboard closed and open. The keyboard is real IME insets sent to the window; the grey
 * block only marks where the keyboard would be. Plus the states (empty, loading, error, offline, streaming, failed).
 * PNGs: app/build/outputs/roborazzi/chat_<theme>_<surface>_<device>_<kb|nokb>.png and chat_<theme>_state_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ClaudeChatSurfacesScreenshotTest(private val theme: String, private val surface: String, private val device: String, private val keyboard: Boolean) {
    companion object {
        private val SURFACES = listOf("suite", "recreate", "edit", "camera")
        private val STATES = listOf("empty", "loading", "error", "offline", "streaming", "failed")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}_{3}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t ->
            SURFACES.flatMap { s -> listOf("phone", "tablet").flatMap { d -> listOf(false, true).map { k -> arrayOf<Any>(t, s, d, k) } } } +
                SURFACES.map { s -> arrayOf<Any>(t, s, "landscape", true) } +
                STATES.map { st -> arrayOf<Any>(t, "state_$st", "phone", false) }
        }

        private const val T0 = 1_762_600_000_000L

        private fun md(kind: String) = when (kind) {
            "edit" -> """
                ## Tightened the opening
                I made **three changes** to the first 12 s:
                1. Cut the silences longer than *0.4 s*
                2. Added captions in the `Clean` style
                3. Moved the music hit onto the first cut

                | Clip | Before | After |
                |---|---:|---:|
                | Intro | 0:14 | 0:09 |
                | Hook | 0:06 | 0:05 |

                > Every change can be undone from the history.
            """.trimIndent()
            "camera" -> """
                ## Slow push, both faces in frame
                - **Start:** 35 mm, 2.4 m back, eye level
                - **Move:** dolly in over *8 s*, ease out
                - **End:** both faces in the top third

                Saved the camera path. Say **render** and I'll update the guides.
            """.trimIndent()
            "recreate" -> """
                ## What this reference does
                The original cuts on every **beat**: 6 shots in 9 s.
                - Shots 1–3 fit takes you already have
                - Shots 4–6 need new renders, about *${'$'}1.92* in total

                See [how briefs work](https://muse.studio/help/briefs).
            """.trimIndent()
            else -> """
                ## Rooftop at night
                I set up the composer for a **slow push-in**:
                - **Camera:** 35 mm, f/2.8, dolly in over 8 s
                - **Light:** cool rim from the skyline, warm practical on her face
                - *Look:* fine grain, soft halation

                | Setting | Value |
                |---|---:|
                | Aspect | 9:16 |
                | Length | 8 s |
                | Price | ${'$'}0.64 |

                Say **go** and I'll ask you to approve the price.
            """.trimIndent()
        }

        private fun ask(kind: String) = when (kind) {
            "edit" -> "Tighten the first 12 seconds and add captions"
            "camera" -> "Slower push, and keep Noor’s face in frame at the end."
            "recreate" -> "Which of these shots can I reuse?"
            else -> "Moody night shot of Noor on a rooftop, slow push in."
        }

        private fun tool(kind: String) = when (kind) {
            "edit" -> ClaudeToolRef("t1", "mcp__muse__cut_silences", true, "Cut 4 silences, 2.6 s")
            "camera" -> ClaudeToolRef("t1", "mcp__muse__set_camera_path", true, null)
            "recreate" -> ClaudeToolRef("t1", "mcp__muse__list_takes", true, null)
            else -> ClaudeToolRef("t1", "mcp__muse__suite_set_draft", true, "{\"draft\":{\"mode\":\"shot\"}}")
        }

        fun conversation(kind: String): List<ClaudeMessage> = listOf(
            // The Mac's context line and the JSON summary must not show.
            ClaudeMessage("m1", "th", "user", "mac", "[${kind.replaceFirstChar { it.uppercase() }} · draft 3]\n" + ask(kind), createdAt = T0 - 3 * 3_600_000),
            ClaudeMessage("m2", "th", "tool", "mac", "", tool = tool(kind), createdAt = T0 - 3 * 3_600_000 + 4000),
            ClaudeMessage("m3", "th", "assistant", "mac", md(kind), createdAt = T0 - 3 * 3_600_000 + 9000),
            ClaudeMessage("m4", "th", "user", "phone", "Can you show me the prompt?", createdAt = T0 - 600_000),
            ClaudeMessage("m5", "th", "assistant", "mac", "Here it is, ready to paste:\n\n```text\nNight rooftop, city haze. Noor at the rail, wind in her hair.\nCamera: slow dolly in, 35 mm, f/2.8, 8 s.\n```\n\nEdit any line in the composer and I'll see it.", createdAt = T0 - 590_000),
        )
    }

    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    private val kind get() = if (surface.startsWith("state_")) "suite" else surface

    @Test fun capture() {
        when (device) {
            "tablet" -> RuntimeEnvironment.setQualifiers("w1024dp-h768dp-mdpi")
            "landscape" -> RuntimeEnvironment.setQualifiers("w844dp-h390dp-xhdpi")
        }
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        val status = runBlocking { fake.claude.status() }
        val thread = ClaudeThread("th", kind, "ctx")
        val base = ChatReducer.loaded(ClaudeChatUi(kind, "ctx", status = status), thread.copy(messages = conversation(kind)))
        val ui = when (surface) {
            "state_empty" -> ChatReducer.loaded(ClaudeChatUi(kind, "ctx", status = status), thread.copy(messages = emptyList()))
            "state_loading" -> ClaudeChatUi(kind, "ctx")
            "state_error" -> ClaudeChatUi(kind, "ctx", loaded = true, error = "java.net.UnknownHostException: Unable to resolve host \"api\"")
            "state_offline" -> base.copy(status = status.copy(mac = status.mac.copy(online = false)), refusal = ClaudeFallback(status.openInClaudeUrl, true), draft = "Make it warmer")
            "state_streaming" -> listOf(
                ClaudeLive("turn", turn = ClaudeTurn("tu_9", "th", "Make it warmer and slower", "phone", "running")),
                ClaudeLive("event", threadId = "th", turnId = "tu_9", event = ClaudeEvent("tool", id = "tl9", name = "mcp__muse__suite_set_draft", status = "done", summary = "Warmer key, 10 s")),
                ClaudeLive("event", threadId = "th", turnId = "tu_9", event = ClaudeEvent("tool", id = "tl10", name = "mcp__muse__get_frame", status = "running")),
                ClaudeLive("event", threadId = "th", turnId = "tu_9", event = ClaudeEvent("text", delta = "Done. The key is now **warmer** and the push takes *10 s*:\n\n- **Light:** warm practical, `3200 K`\n- **Move:** dolly in, ease o")),
            ).fold(base) { u, l -> ChatReducer.live(u, l) }
            "state_failed" -> base.copy(turn = LiveTurn("tu_8", "failed", "phone", "", error = "java.lang.IllegalStateException: claude exited 1\n\tat studio.muse.Runner.run(Runner.kt:42)"))
            else -> if (keyboard) base.copy(draft = "Make the light warmer and the push a little slower,\nthen show me the new price") else base
        }
        compose.mainClock.autoAdvance = false
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                val nav = Nav(rememberNavController())
                CompositionLocalProvider(LocalContainer provides c, LocalNav provides nav) {
                    val m = muse
                    val tablet = device == "tablet"
                    Box(Modifier.fillMaxSize().background(m.roles.canvas)) {
                        val behind: @androidx.compose.runtime.Composable (String) -> Unit = { label ->
                            Column(Modifier.fillMaxSize().background(m.roles.field).padding(24.dp)) { T(label, m.scale.title, m.roles.ink2) }
                        }
                        when {
                            surface.startsWith("state_") -> ClaudeChatContent(ui, "Claude", ClaudeChatActions(attach = {}), Modifier.fillMaxSize(), now = T0)
                            surface == "suite" -> Box(Modifier.fillMaxSize()) {
                                behind("AI Suite · composer")
                                ClaudeSheetFrame({}, heightFraction = .62f) { ClaudeChatContent(ui, "Claude", ClaudeChatActions(attach = {}), Modifier.fillMaxSize(), now = T0) }
                            }
                            surface == "recreate" -> Box(Modifier.fillMaxSize()) {
                                behind("Recreate · reference")
                                ClaudeSheetFrame({}) { ClaudeChatContent(ui, "Claude", ClaudeChatActions(attach = {}), Modifier.fillMaxSize(), now = T0) }
                            }
                            surface == "edit" && tablet -> Row(Modifier.fillMaxSize()) {
                                Box(Modifier.weight(1f).fillMaxHeight()) { behind("Edit suite · preview") }
                                ClaudeChatContent(ui, "Rooftop edit", ClaudeChatActions(attach = {}), Modifier.width(380.dp).fillMaxHeight(), now = T0)
                            }
                            surface == "edit" -> Box(Modifier.fillMaxSize()) {
                                behind("Edit suite")
                                ClaudeSheetFrame({}) { ClaudeChatContent(ui, "Rooftop edit", ClaudeChatActions(attach = {}), Modifier.fillMaxSize(), now = T0) }
                            }
                            surface == "camera" && tablet -> Row(Modifier.fillMaxSize()) {
                                Box(Modifier.weight(1f).fillMaxHeight()) { behind("Camera stage") }
                                ClaudeChatContent(ui, "Direct with Claude", ClaudeChatActions(), Modifier.width(404.dp).fillMaxHeight(), now = T0)
                            }
                            else -> ClaudeChatContent(ui, "Direct with Claude", ClaudeChatActions(), Modifier.fillMaxSize(), now = T0)
                        }
                        // Where the keyboard is (the chat must end above it).
                        if (keyboard) Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(kbDp()).background(Color(0xFF8E9196)), contentAlignment = Alignment.Center) {
                            T("Keyboard", m.scale.label, Color.White)
                        }
                    }
                }
            }
        }
        if (keyboard) {
            val view = compose.activity.findViewById<ViewGroup>(android.R.id.content).getChildAt(0)
            WindowCompat.setDecorFitsSystemWindows(compose.activity.window, false)
            val px = (kbDp().value * view.resources.displayMetrics.density).toInt()
            val insets = WindowInsetsCompat.Builder().setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, px)).setVisible(WindowInsetsCompat.Type.ime(), true).build()
            compose.runOnUiThread { ViewCompat.dispatchApplyWindowInsets(view, insets) }
        }
        repeat(5) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        fun has(text: String) = check(compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty() ||
            compose.onAllNodesWithContentDescription(text, substring = true).fetchSemanticsNodes().isNotEmpty()) { "missing: $text" }
        fun hasNot(text: String) = check(compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isEmpty()) { "leaked: $text" }
        // Never raw markers, context lines or JSON.
        listOf("**", "##", "```", "[Suite", "[Edit", "[Camera", "[Recreate", "mcp__", "{\"", "Exception", "Runner.kt").forEach(::hasNot)
        when (surface) {
            "state_empty" -> has("Chat with Claude")
            "state_loading" -> has("Opening the chat")
            "state_error" -> { has("You're offline"); has("The chat comes back when the connection does.") }
            "state_offline" -> { has("Claude on your Mac is offline"); has("Use the studio API key") }
            "state_streaming" -> { has("Stop"); has("Grabbing a frame") }
            "state_failed" -> { has("Claude couldn't finish this reply."); has("Try again") }
            else -> { has("Send"); if (!keyboard) has("Copy") }
        }
        val name = if (surface.startsWith("state_")) "chat_${theme}_$surface" else "chat_${theme}_${surface}_${device}_${if (keyboard) "kb" else "nokb"}"
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/$name.png")
    }

    private fun kbDp() = when (device) { "tablet" -> 340.dp; "landscape" -> 190.dp; else -> 300.dp }
}
