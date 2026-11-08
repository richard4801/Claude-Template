package studio.muse.app.claude

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ClaudeMessage
import studio.muse.app.data.ClaudeToolRef
import studio.muse.app.ui.screens.claude.ChatClean
import studio.muse.app.ui.screens.claude.ChatItem
import studio.muse.app.ui.screens.claude.ChatReducer
import studio.muse.app.ui.screens.claude.ChatTime
import studio.muse.app.ui.screens.claude.ClaudeChatUi
import studio.muse.app.ui.screens.claude.ClaudeText
import studio.muse.app.ui.screens.claude.LiveTurn
import java.util.TimeZone

/** Nothing internal reaches the chat (plans/claude-chat-android.md "No leaks"), and time labels. */
class ChatCleanTest {
    @Test fun contextLineTheMacAddsIsStripped() {
        assertEquals("Make it moodier", ChatClean.userText("[Suite · Shot · draft 3 · Noor]\nMake it moodier"))
        assertEquals("Slower push", ChatClean.userText("[Camera session cs_1 · revision 4 · status ready]\n\nSlower push"))
        assertEquals("Keep [this] bracket", ChatClean.userText("Keep [this] bracket"))
        assertEquals("[not a context line] typed by the owner", ChatClean.userText("[not a context line] typed by the owner"))
    }

    @Test fun systemBriefsAreStripped() {
        assertEquals("Cut the silences", ChatClean.userText("<system-reminder>You are MUSE's editor. Tools: …</system-reminder>\nCut the silences"))
        assertEquals("Done.", ChatClean.assistantText("<muse-brief>internal</muse-brief>Done."))
    }

    @Test fun toolSummariesNeverShowJsonPathsOrIds() {
        assertNull(ChatClean.summary("{\"path\":[1,2]}"))
        assertNull(ChatClean.summary("[{\"id\":\"x\"}]"))
        assertNull(ChatClean.summary("error: mcp__muse__set_camera_path failed"))
        assertNull(ChatClean.summary("Traceback (most recent call last):\n  File \"x.py\", line 3"))
        assertEquals("Saved to a file", ChatClean.summary("Saved to /Users/jenne/Library/Muse/edit.json"))
        assertEquals("Trimmed take", ChatClean.summary("Trimmed take tk_8a7sdf9a8sd"))
        assertEquals("Shot draft · estimate \$1.92", ChatClean.summary("Shot draft · estimate \$1.92"))
        assertTrue(ChatClean.summary("x".repeat(200))!!.length <= 80)
    }

    @Test fun errorsArePlainSentences() {
        assertEquals(ChatClean.FAILED, ChatClean.error("java.lang.IllegalStateException: boom\n\tat studio.muse.X.y(X.kt:3)"))
        assertEquals(ChatClean.FAILED, ChatClean.error("{\"error\":{\"type\":\"overloaded_error\"}}".replace("overloaded", "x")))
        assertEquals("Claude is busy right now. Try again in a minute.", ChatClean.error("529 overloaded_error"))
        assertEquals("Claude took too long to answer. Try again.", ChatClean.error("SocketTimeoutException: timeout"))
        assertEquals("Couldn't reach the studio. Check your connection and try again.", ChatClean.error("Unable to resolve host \"api\""))
        assertEquals("Your Mac stopped answering", ChatClean.error("Your Mac stopped answering"))
        assertEquals(ChatClean.FAILED, ChatClean.error(null))
        assertEquals(ChatClean.FAILED, ChatClean.error("   "))
    }

    @Test fun transcriptUsesTheCleanText() {
        val ui = ClaudeChatUi("suite", "sa_1", messages = listOf(
            ClaudeMessage("m1", role = "user", source = "mac", text = "[Suite · Shot]\nMoodier please", createdAt = 1),
            ClaudeMessage("m2", role = "tool", text = "", tool = ClaudeToolRef("t1", "mcp__muse__suite_set_draft", true, "{\"draft\":{}}")),
            ClaudeMessage("m3", role = "tool", text = "", tool = ClaudeToolRef("t2", "mcp__muse__get_frame", false, null)),
            ClaudeMessage("m4", role = "assistant", text = "Done.", createdAt = 2),
        ), loaded = true)
        val items = ui.items
        assertEquals("Moodier please", (items[0] as ChatItem.User).text)
        val draft = items[1] as ChatItem.Tool
        assertEquals("Suite set draft", draft.text)
        assertFalse(draft.text.contains("mcp__"))
        assertFalse(draft.detail.contains("{"))
        val failed = items[2] as ChatItem.Tool
        assertFalse(failed.ok)
        assertEquals("Grabbed a frame didn't work", failed.text)
        assertTrue(failed.detail.contains("didn't work"))
        // Every row's words: no ids, no tool names, no JSON.
        items.forEach { i -> val t = i.toString(); assertFalse(t, t.contains("mcp__")) }
    }

    @Test fun failedTurnLineIsPlain() {
        assertEquals("Couldn't reach the studio. Check your connection and try again.", ClaudeText.ended(LiveTurn("tu_1", "failed", error = "Error: ECONNRESET at /srv/app/index.js:12")))
        assertEquals(ChatClean.FAILED, ClaudeText.ended(LiveTurn("tu_1", "failed", error = "Error: spawn failed at /srv/app/index.js:12")))
        assertEquals("Stopped", ClaudeText.ended(LiveTurn("tu_1", "stopped")))
    }

    @Test fun retryUsesTheLastMessage() {
        val ui = ClaudeChatUi("edit", "es_1", messages = listOf(ClaudeMessage("m1", role = "user", text = "[Edit · v3]\nCut it"), ClaudeMessage("m2", role = "assistant", text = "Ok")))
        assertEquals("Cut it", ChatReducer.lastUserText(ui))
        assertEquals("Again", ChatReducer.lastUserText(ui.copy(turn = LiveTurn("t", "failed", text = "Again"))))
    }

    @Test fun membersNeverSeeModelOrKeyNames() {
        listOf(ClaudeText.NO_KEY_NOTE, ClaudeText.FALLBACK_NOTE, ClaudeText.API, ClaudeText.MODE, ClaudeText.OFFLINE).forEach {
            assertFalse(it, Regex("ANTHROPIC|_KEY|opus|sonnet|haiku|gpt", RegexOption.IGNORE_CASE).containsMatchIn(it))
        }
    }

    @Test fun timeLabels() {
        val utc = TimeZone.getTimeZone("UTC")
        val now = 1_762_600_000_000L // 2025-11-08 11:06 UTC
        assertEquals("Today 10:06", ChatTime.label(now - 3_600_000, now, utc))
        assertEquals("Yesterday 11:06", ChatTime.label(now - 86_400_000, now, utc))
        assertTrue(ChatTime.label(now - 5 * 86_400_000L, now, utc).endsWith(", 11:06"))
        assertTrue(ChatTime.needsLabel(0, now))
        assertFalse(ChatTime.needsLabel(now - 60_000, now))
        assertTrue(ChatTime.needsLabel(now - ChatTime.GAP_MS, now))
        assertFalse(ChatTime.needsLabel(now, 0))
    }
}
