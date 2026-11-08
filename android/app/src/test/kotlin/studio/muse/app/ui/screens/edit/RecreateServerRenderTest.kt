package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MuseApi
import studio.muse.core.edit.RecreateRender

/** Compare and export use the studio server's render first and fall back to the phone when it can't render. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RecreateServerRenderTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun thePreviewIsPolledUntilReadyThenDownloaded() = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val r = RecreateServerRender(api, tmp.root, pollMs = 1).preview("es_1")
        assertNotNull(r)
        assertTrue(r!!.file.length() > 0)
        assertTrue(r.render.ready)
        assertEquals("Preview of the cut", r.render.label) // the demo leaves captions out
    }

    @Test fun theExportCarriesItsReminderAndSaysWhenItIsRendering() = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        var rendering = false
        val r = RecreateServerRender(api, tmp.root, pollMs = 1).export("rx_1", "es_1", guide = true) { rendering = true }
        assertTrue(rendering)
        assertEquals("guide", r!!.render.sound)
        assertEquals("Post with the original sound", r.render.useThisSound!!.title)
    }

    @Test fun noReferenceSoundIsRaisedSoTheSheetOffersSilent() = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0).apply { debugNoReferenceSound = true }
        val render = RecreateServerRender(api, tmp.root, pollMs = 1)
        try { render.export("rx_1", "es_1", guide = true); fail("expected no_reference_sound") } catch (e: ApiException) { assertEquals("no_reference_sound", e.code) }
        assertNotNull(render.export("rx_1", "es_1", guide = false)) // silent still works
    }

    @Test fun anOlderServerOrAFailedRenderFallsBackToThePhone() = runBlocking {
        val old = object : MuseApi by FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0) {
            override suspend fun editPreview(sessionId: String, start: Boolean, revision: Int?): RecreateRender = throw ApiException("not_found", "no")
            override suspend fun recreateExport(id: String, sessionId: String, sound: String, start: Boolean, revision: Int?): RecreateRender = throw java.io.IOException("offline")
        }
        assertNull(RecreateServerRender(old, tmp.root, pollMs = 1).preview("es_1"))
        assertNull(RecreateServerRender(old, tmp.root, pollMs = 1).export("rx_1", "es_1", guide = true))
        val failing = object : MuseApi by FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0) {
            override suspend fun editPreview(sessionId: String, start: Boolean, revision: Int?) = RecreateRender(sessionId, 1, if (start) "rendering" else "failed", error = "render_failed")
        }
        assertNull(RecreateServerRender(failing, tmp.root, pollMs = 1).preview("es_1"))
        val slow = object : MuseApi by FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0) {
            override suspend fun editPreview(sessionId: String, start: Boolean, revision: Int?) = RecreateRender(sessionId, 1, "rendering")
        }
        assertNull(RecreateServerRender(slow, tmp.root, pollMs = 1, maxWaitMs = 5).preview("es_1"))
    }
}
