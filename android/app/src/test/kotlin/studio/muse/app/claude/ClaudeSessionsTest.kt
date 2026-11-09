package studio.muse.app.claude

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ClaudeMessage
import studio.muse.app.data.ClaudeSessions
import studio.muse.app.data.FakeClaudeApi
import studio.muse.app.ui.screens.claude.ChatItem
import studio.muse.app.ui.screens.claude.ClaudeChatStore
import studio.muse.app.ui.screens.claude.ClaudeChatUi
import studio.muse.app.ui.screens.claude.LiveTurn
import java.util.TimeZone

/** WS18, the owner's Claude chat report on Android: one bubble per message, and each place's list of chats. */
@OptIn(ExperimentalCoroutinesApi::class)
class ClaudeSessionsTest {
    private val ctx = "[Suite · draft sa_1abcd rev 3 · Photo · Draft, 9:16, 5 s, 1 take · prompt: empty]"
    private val words = "Great place it, and also add the image as reference."

    @Test fun aMessageShowsOnceEvenWithTheContextLineInFront() {
        // The live turn's text and the stored copy differ only by the context line: one bubble.
        val ui = ClaudeChatUi(contextKind = "suite", contextId = "sa_1", loaded = true,
            messages = listOf(ClaudeMessage("cm_1", "ct_1", "user", "mac", "$ctx\n$words", createdAt = 10)),
            turn = LiveTurn(null, "running", "mac", words))
        assertEquals(1, ui.items.count { it is ChatItem.User })
        assertEquals(words, (ui.items.first() as ChatItem.User).text)
    }

    @Test fun keysTitlesAndLastUsed() {
        assertEquals("suite:photo", ClaudeSessions.suiteKey("photo"))
        assertEquals("suite:shot", ClaudeSessions.suiteKey("../x"))
        assertEquals(words, ClaudeSessions.autoTitle("$ctx\n$words"))
        assertEquals("Match shot 4 to please", ClaudeSessions.autoTitle("[Recreate rx_1]\nMatch shot 4 to /Users/me/x.png please"))
        assertNull(ClaudeSessions.autoTitle("$ctx\n  "))
        assertEquals(words, ClaudeSessions.typedText("$ctx\n$words"))
        assertEquals("[note]", ClaudeSessions.typedText("[note]"))
        val utc = TimeZone.getTimeZone("UTC")
        val now = 1_794_200_000_000L
        assertEquals("Just now", ClaudeSessions.lastUsed(now - 20_000, now, utc))
        assertEquals("5 min ago", ClaudeSessions.lastUsed(now - 5 * 60_000, now, utc))
        assertEquals("3 h ago", ClaudeSessions.lastUsed(now - 3 * 3_600_000, now, utc))
        assertEquals("Yesterday", ClaudeSessions.lastUsed(now - 24 * 3_600_000, now, utc))
        assertEquals("4 days ago", ClaudeSessions.lastUsed(now - 4 * 86_400_000L, now, utc))
        assertEquals("10 Oct", ClaudeSessions.lastUsed(now - 30 * 86_400_000L, now, utc))
    }

    @Test fun newChatSwitchRenameDeleteAndComingBack() = runTest {
        var clock = 1_000L
        lateinit var store: ClaudeChatStore
        val api = FakeClaudeApi(this, { clock++ }, { store.onLive(it) }, stepDelayMs = 0)
        val place = "es_sessions_${System.nanoTime()}"
        store = ClaudeChatStore({ api }, this, "edit", place)
        store.load(); advanceUntilIdle()
        val first = store.ui.value.thread!!
        assertTrue(store.ui.value.sessions)
        assertEquals("edit:$place", first.contextKey)
        store.edit("Trim the start"); assertTrue(store.send()); advanceUntilIdle()
        assertEquals(1, store.ui.value.items.count { it is ChatItem.User })

        store.newChat(); advanceUntilIdle()
        val second = store.ui.value.thread!!
        assertNotEquals(first.id, second.id)
        assertTrue(store.ui.value.items.isEmpty())
        assertEquals(2, store.ui.value.threads.size)
        store.newChat(); advanceUntilIdle()
        assertEquals("New chat on an empty chat does nothing", second.id, store.ui.value.thread!!.id)

        store.open(store.ui.value.threads.first { it.id == first.id }); advanceUntilIdle()
        assertEquals(first.id, store.ui.value.thread!!.id)
        assertEquals(1, store.ui.value.items.count { it is ChatItem.User && it.text == "Trim the start" })

        store.rename(store.ui.value.thread!!, "Opening cut"); advanceUntilIdle()
        assertEquals("Opening cut", store.ui.value.threads.first { it.id == first.id }.title)

        // Closing and opening the place again (a new store) comes back to the chat open last, with its messages.
        val again = ClaudeChatStore({ api }, this, "edit", place)
        again.load(); advanceUntilIdle()
        assertEquals(first.id, again.ui.value.thread!!.id)
        assertEquals(1, again.ui.value.items.count { it is ChatItem.User && it.text == "Trim the start" })

        store.delete(store.ui.value.threads.first { it.id == second.id }); advanceUntilIdle()
        assertFalse(store.ui.value.threads.any { it.id == second.id })
        // Deleting the open chat moves to the newest left (a new one when it was the last).
        store.delete(store.ui.value.thread!!); advanceUntilIdle()
        assertNotEquals(first.id, store.ui.value.thread?.id)
        assertTrue(store.ui.value.thread != null)
    }
}
