package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.EditedVideo
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.OpenEditSessionRequest
import studio.muse.core.edit.BLANK_SOURCE
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.blankProject

/** "New" in Edit on Android (owner 2026-11-12): a blank project edits, joins its own session, and saves as a new Library video. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditBlankTest {
    private class NoAi : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = null to "off"
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = null to "off"
    }

    private fun take() = TakeChoice("t_j1", "Kick test", "HD", null, 6.0, edited = false, hasVideo = true)

    @Test fun aBlankProjectTakesItsFirstClipAndOtherChangesBeforeIt() = runTest {
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(blankProject(), "New project", BLANK_SOURCE, null, reopened = false)
        assertEquals(0.0, c.ui.value.duration, 1e-9)
        // Zoom, ratio and the platform view work on the empty timeline (nothing refused, nothing thrown).
        c.act(EditAction.Zoom(60f)); c.act(EditAction.Seek(3.0))
        assertEquals(0.0, c.ui.value.playheadSec, 1e-9)
        c.act(EditAction.AppendTake(take()))
        val p = c.project!!
        assertEquals(1, p.main.items.size)
        assertTrue(p.isBlank)
        assertEquals(6.0, c.ui.value.duration, 1e-9)
        assertNull(studio.muse.core.edit.problemOf(p)) // now savable
        c.act(EditAction.Undo)
        assertTrue(c.project!!.main.items.isEmpty())
    }

    @Test fun newOpensAFreshSessionAndContinueJoinsTheSameOne() = runTest {
        val api = FakeMuseApi(backgroundScope, null, speed = 0.0, genDelayMs = 0)
        val a = api.openEditSession(OpenEditSessionRequest(BLANK_SOURCE))
        val b = api.openEditSession(OpenEditSessionRequest(BLANK_SOURCE))
        assertNotEquals(a.id, b.id) // every "New" is its own project
        assertEquals(blankProject(), EditJson.parse(a.project))
        // Continue draft joins the session by id (its take id "blank" would open a new one).
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(blankProject(), "New project", BLANK_SOURCE, null, reopened = false)
        val sync = EditSessionSync(backgroundScope, { api }, api.events(), c, object : SessionHost {
            override suspend fun renderFrame(project: studio.muse.core.edit.EditProject, t: Double, width: Int) = null to "no"
            override suspend fun saveVersion(name: String?) = null to "no"
            override suspend fun export(preset: JsonObject?) = null to "no"
        }, "android-test", "Pixel", presenceMs = 3_600_000)
        assertTrue(sync.start(BLANK_SOURCE, attach = a.id))
        runCurrent()
        assertEquals(a.id, sync.sessionId)
        // The empty blank's edits go up (the server's draft rule), so the phone and the Mac see the same project.
        c.act(EditAction.AppendTake(take()))
        sync.flush()
        assertEquals(1, EditJson.parse(api.editSession(a.id).project).main.items.size)
    }

    @Test fun theFirstSaveIsANewLibraryVideo() = runTest {
        val api = FakeMuseApi(backgroundScope, null, speed = 0.0, genDelayMs = 0)
        val file = kotlin.io.path.createTempFile(suffix = ".mp4").toFile()
        val video = EditedVideo(file, null, 6.0, 1080, 1920, 30.0)
        val empty = EditJson.encode(blankProject())
        assertEquals("bad_request", runCatching { api.saveProjectVersion(BLANK_SOURCE, video, empty, null, {}, false) }.exceptionOrNull().let { (it as ApiException).code })
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(blankProject(), "New project", BLANK_SOURCE, null, reopened = false)
        c.act(EditAction.AppendTake(take()))
        val t = api.saveProjectVersion(BLANK_SOURCE, video, EditJson.encode(c.project!!), "Promo", {}, false)
        assertNull(t.parentTakeId)
        assertEquals("edit", t.kind)
        assertEquals(BLANK_SOURCE, (t.edits!!.project!!["sourceTakeId"] as JsonPrimitive).content)
        // The next save is a version of that video.
        val v2 = api.saveProjectVersion(t.id, video, EditJson.encode(c.project!!.copy(sourceTakeId = t.id)), null, {}, false)
        assertEquals(t.id, v2.parentTakeId)
        file.delete()
    }
}
