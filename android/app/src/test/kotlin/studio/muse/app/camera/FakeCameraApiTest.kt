package studio.muse.app.camera

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ApiException
import studio.muse.app.data.CharacterTrack
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.NewCameraSession
import studio.muse.app.data.NewCast
import studio.muse.app.data.PathUpdate
import studio.muse.app.data.RelayStatus
import studio.muse.app.data.SampleData
import studio.muse.app.ui.screens.camera.CameraStore
import studio.muse.app.ui.screens.camera.P2

@OptIn(ExperimentalCoroutinesApi::class)
class FakeCameraApiTest {
    private val events = mutableListOf<ApiEvent>()
    private fun api() = FakeCameraApi(emit = { events += it }, stepDelayMs = 0)

    @Test fun seedUsesTheStudiosRealCharacters() = runTest {
        val a = api()
        val list = a.sessions()
        assertEquals(2, list.size)
        assertNull(list[0].messages)
        val s = a.session(FakeCameraApi.SEED_ID)
        assertEquals(listOf("Demo model", "Noor Ellis"), s.characters.map { it.name })
        assertTrue(s.messages!!.none { "Sienna" in it.text })
        assertEquals(4, s.revision)
        assertEquals(1.92, s.shotDraft!!.estimate.usd, 0.0)
    }

    @Test fun theDemoStudioExposesTheCameraApi() = runTest {
        val fake = FakeMuseApi(backgroundScope, null, speed = 0.0, genDelayMs = 0)
        val names = fake.camera.session(FakeCameraApi.SEED_ID).characters.map { it.name }
        assertEquals(fake.listModels().take(2).map { it.name }, names)
    }

    @Test fun chatStreamsToolStepsAndBumpsTheRevision() = runTest {
        val a = api()
        val ev = a.chat(FakeCameraApi.SEED_ID, "Slower orbit, and keep Noor's face visible at the end.").toList()
        assertEquals("message", ev.first().type)
        assertEquals(listOf("running", "done", "running", "done"), ev.filter { it.type == "tool" }.map { it.status })
        assertTrue(ev.any { it.type == "waiting" && it.reason == "blender" })
        assertEquals("done", ev.last().type)
        val s = a.session(FakeCameraApi.SEED_ID)
        assertTrue(s.revision > 4)
        assertFalse(s.claude.chatBusy)
        assertEquals("assistant", s.messages!!.last().role)
        assertTrue(events.any { it.type == "camera" && it.op == "message" })
        assertTrue(events.any { it.type == "camera" && it.op == "upsert" })
    }

    @Test fun chatRefusals() = runTest {
        val a = api()
        a.inAppChat = false
        val ev = a.chat(FakeCameraApi.SEED_ID, "hi").toList()
        assertEquals(1, ev.size); assertEquals("director_unavailable", ev[0].code)
        a.inAppChat = true
        assertEquals("bad_request", a.chat(FakeCameraApi.SEED_ID, " ").toList().single().code)
    }

    @Test fun tokensAreShownOnceAndRevocable() = runTest {
        val a = api()
        val t = a.createToken("Claude Desktop")
        assertTrue(t.token!!.startsWith("muse_pat_"))
        assertTrue(t.token!!.startsWith(t.prefix))
        val list = a.tokens()
        assertEquals(2, list.size)
        assertTrue(list.all { it.token == null })
        a.revokeToken(t.id)
        assertEquals(1, a.tokens().size)
        assertEquals(1, a.connections().claudeApp.tokens)
    }

    @Test fun pathNeedsTheCastAndMovesDraftingToBlocking() = runTest {
        val a = api()
        val s = a.createSession(NewCameraSession("Test", characters = listOf(NewCast(SampleData.NOOR))))
        assertEquals("drafting", s.status)
        try { a.putPath(s.id, PathUpdate(characters = listOf(CharacterTrack(SampleData.DEMO)))); fail() } catch (e: ApiException) { assertEquals("bad_request", e.code) }
        val p = a.putPath(s.id, PathUpdate(characters = listOf(CharacterTrack(SampleData.NOOR))))
        assertEquals("blocking", p.status)
        assertEquals(s.revision + 1, p.revision)
        try { a.createSession(NewCameraSession(characters = listOf(NewCast("m_nobody")))); fail() } catch (e: ApiException) { assertEquals("bad_request", e.code) }
    }

    @Test fun shotDraftWithoutGuidesHasNoGuide() = runTest {
        val a = api()
        val s = a.createSession(NewCameraSession("Empty"))
        val d = a.shotDraft(s.id)
        assertNull(d.camera)
        val seeded = a.shotDraft(FakeCameraApi.SEED_ID)
        assertNotNull(seeded.camera)
        try { a.linkJob(s.id, "j"); } catch (e: ApiException) { fail(e.code) }
        try { a.linkJob(a.createSession(NewCameraSession()).id, "j"); fail() } catch (e: ApiException) { assertEquals("no_draft", e.code) }
    }

    @Test fun relayEvents() {
        val a = api()
        a.reportRelay(RelayStatus(online = false, blender = false))
        val e = events.last()
        assertEquals("blender" to "relay", e.type to e.op)
        assertEquals(false, e.online)
    }

    @Test fun storeSendsChatsAndDebouncesDrags() = runTest {
        val a = api()
        val store = CameraStore({ a }, this)
        store.loadList(); advanceUntilIdle()
        store.open(FakeCameraApi.SEED_ID); advanceUntilIdle()
        assertEquals(4, store.ui.value.session!!.revision)
        assertEquals(7, store.ui.value.messages.size)
        assertTrue(store.send("Slower orbit"))
        assertNotNull(store.ui.value.turn)
        assertFalse(store.send("again")) // busy
        assertEquals("chat_busy", store.ui.value.notice!!.code)
        advanceUntilIdle()
        assertNull(store.ui.value.turn)
        assertTrue(store.ui.value.session!!.revision > 4)
        assertTrue("Slower orbit" in store.ui.value.sentHere)

        val rev = store.ui.value.session!!.revision
        store.setPlayhead(1.2)
        val id = store.ui.value.session!!.characters[0].modelId
        store.dragCharacter(id, P2(-1.0, 2.0))
        store.dragCharacter(id, P2(-1.1, 2.1))
        store.dragCamera(P2(0.0, -1.5))
        advanceUntilIdle()
        val saved = a.session(FakeCameraApi.SEED_ID)
        assertEquals(rev + 1, saved.revision) // one PUT for all three drags
        assertEquals(listOf(-1.1, 2.1, 0.0), saved.blocking!!.characters[0].keyframes[1].position)
        assertEquals(listOf(0.0, -1.5, 1.5), saved.cameraPath!!.keyframes.first { it.t == 1.2 }.position)

        val h = store.handoff().getOrThrow()
        assertEquals(FakeCameraApi.SEED_ID, h.sessionId)
    }
}
