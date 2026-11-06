package studio.muse.app.claude

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ClaudeSend
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.FakeClaudeApi
import studio.muse.app.ui.screens.claude.ChatItem
import studio.muse.app.ui.screens.claude.ClaudeChatStore
import studio.muse.app.ui.screens.claude.ClaudeText

@OptIn(ExperimentalCoroutinesApi::class)
class FakeClaudeApiTest {
    @Test fun relayFlowQueuedRunningStreamedDone() = runTest {
        lateinit var store: ClaudeChatStore
        val events = mutableListOf<ApiEvent>()
        val api = FakeClaudeApi(this, { 0L }, { events += it; store.onLive(it) }, stepDelayMs = 600)
        store = ClaudeChatStore({ api }, this, "camera", FakeCameraApi.SEED_ID)
        store.load(); advanceUntilIdle()
        val seeded = store.ui.value.items
        assertEquals(listOf("Saved camera path", "Shot draft · $1.92"), seeded.filterIsInstance<ChatItem.Tool>().map { it.text })
        assertEquals(ClaudeText.MODE, ClaudeText.status(store.ui.value).text)

        store.edit("Slower push")
        assertTrue(store.send())
        assertEquals("", store.ui.value.draft)
        runCurrent()
        assertEquals(ClaudeText.WAITING, ClaudeText.status(store.ui.value).text)
        assertFalse(store.send("again")) // busy
        advanceTimeBy(700)
        assertEquals(ClaudeText.ANSWERING, ClaudeText.status(store.ui.value).text)
        advanceTimeBy(250)
        val mid = store.ui.value.items.last()
        assertTrue(mid is ChatItem.Assistant && mid.streaming)
        advanceUntilIdle()
        val ui = store.ui.value
        assertFalse(ui.busy)
        val items = ui.items.drop(seeded.size)
        assertEquals(1, items.count { it is ChatItem.User && it.text == "Slower push" })
        assertEquals("Saved camera path", items.filterIsInstance<ChatItem.Tool>().single().text)
        assertEquals(2, items.count { it is ChatItem.Assistant })
        assertTrue(events.any { it.claude?.op == "event" && it.claude?.event?.type == "done" })
    }

    @Test fun busyFromTheServer() = runTest {
        val api = FakeClaudeApi(this, { 0L }, stepDelayMs = 600)
        val t = api.thread("camera", "cs_x")
        assertTrue(api.post(t.id, "one") is ClaudeSend.Sent)
        assertEquals(ClaudeSend.Busy, api.post(t.id, "two"))
        advanceUntilIdle()
        assertTrue(api.post(t.id, "three") is ClaudeSend.Sent)
        advanceUntilIdle()
    }

    @Test fun offlineOffersOpenInClaudeThenTheApiKey() = runTest {
        lateinit var store: ClaudeChatStore
        val api = FakeClaudeApi(this, { 0L }, { store.onLive(it) }, stepDelayMs = 0)
        store = ClaudeChatStore({ api }, this, "camera", "cs_off")
        store.load(); advanceUntilIdle()
        api.setMac(online = false); advanceUntilIdle()
        assertEquals(ClaudeText.OFFLINE, ClaudeText.status(store.ui.value).text)
        assertTrue(store.send("Lower the camera")); advanceUntilIdle()
        val u = store.ui.value
        assertNotNull(u.refusal)
        assertEquals("Lower the camera", u.refusedText)
        assertNull(u.turn)
        assertFalse(u.refusal!!.apiFallback)
        // The fallback is off: the API turn is refused.
        assertTrue(store.useApiKey()); advanceUntilIdle()
        assertEquals("failed", store.ui.value.turn!!.state)
        // On: it answers on the studio key and the messages are stored.
        api.setApiFallback(true); advanceUntilIdle()
        store.edit("Lower the camera")
        assertTrue(store.useApiKey()); advanceUntilIdle()
        val items = store.ui.value.items
        assertTrue(items.any { it is ChatItem.User && it.source == "api" })
        assertTrue(items.any { it is ChatItem.Tool && it.text == "Saved camera path" })
        assertFalse(store.ui.value.busy)
        // The Mac comes back: the refusal clears.
        api.setMac(online = true); advanceUntilIdle()
        assertNull(store.ui.value.refusal)
        assertEquals(ClaudeText.MODE, ClaudeText.status(store.ui.value).text)
    }

    @Test fun stopInterruptsTheTurn() = runTest {
        lateinit var store: ClaudeChatStore
        val api = FakeClaudeApi(this, { 0L }, { store.onLive(it) }, stepDelayMs = 600)
        store = ClaudeChatStore({ api }, this, "edit", "es_1")
        store.load(); advanceUntilIdle()
        assertTrue(store.send("Trim the pause"))
        advanceTimeBy(800)
        assertTrue(store.ui.value.busy)
        store.stop(); advanceUntilIdle()
        assertFalse(store.ui.value.busy)
        assertEquals("Stopped", ClaudeText.ended(store.ui.value.turn))
    }

    @Test fun editThreadsShowTheGrabbedFrame() = runTest {
        lateinit var store: ClaudeChatStore
        val api = FakeClaudeApi(this, { 0L }, { store.onLive(it) }, stepDelayMs = 0)
        store = ClaudeChatStore({ api }, this, "edit", "es_2")
        store.load(); advanceUntilIdle()
        store.send("Tighten the hook"); advanceUntilIdle()
        val items = store.ui.value.items
        assertEquals("Trimmed 0:03–0:05", items.filterIsInstance<ChatItem.Tool>().single().text)
        assertTrue(items.any { it is ChatItem.Image && it.url != null })
        assertTrue(api.apiTurn(store.ui.value.thread!!.id, "x").toList().single().code == "fallback_off")
    }
}
