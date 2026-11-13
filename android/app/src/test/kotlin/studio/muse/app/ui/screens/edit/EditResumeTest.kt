package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.OpenEditSessionRequest
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditPlace
import studio.muse.core.edit.EditRecent
import studio.muse.core.edit.EditRecentEntry
import studio.muse.core.edit.PreviewView
import studio.muse.core.edit.RecentSession
import studio.muse.core.edit.SourceSize

/**
 * Continue a draft (owner, 2026-11-12): where the editor was left goes out and comes back through the real controller, the
 * demo server keeps it and lists the last worked on first, and the phone's file keeps a member's edit across a restart.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EditResumeTest {
    @get:Rule val tmp = TemporaryFolder()

    private class NoAi : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = null to "off"
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = null to "off"
    }

    private fun project() = EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true))

    @Test fun thePlaceComesBackWhereItWasLeft() = runTest {
        val a = EditSuiteController(backgroundScope, NoAi())
        a.load(project(), "Kick test", "t_j1", null, reopened = true)
        a.act(EditAction.Seek(4.5)); a.act(EditAction.Zoom(80f)); a.act(EditAction.Open(Panel.AUDIO))
        a.act(EditAction.PreviewOf(a.ui.value.preview.copy(view = PreviewView.REELS)))
        val clip = a.project!!.tracks.first().items.first().id
        a.act(EditAction.Select(clip))
        // A field this app doesn't show (the Mac's media bin tab) is kept.
        val place = placeOf(a.ui.value, EditPlace(binTab = "uploads"))
        assertEquals("audio", place.tab)
        assertEquals("reels", place.safeArea)
        assertEquals("uploads", place.binTab)

        // Another editor (the app reopened) on the same edit: back to the same place.
        val b = EditSuiteController(backgroundScope, NoAi())
        b.load(project(), "Kick test", "t_j1", null, reopened = true)
        b.restorePlace(EditPlace.of(place.toJson())!!)
        val u = b.ui.value
        assertEquals(4.5, u.playheadSec, 1e-6)
        assertEquals(80f, u.pxPerSec)
        assertEquals(Panel.AUDIO, u.panel)
        assertEquals(PreviewView.REELS, u.preview.view)
        assertEquals(clip, u.selectedId)
    }

    @Test fun aStaleOrForeignPlaceNeverBreaksOpening() = runTest {
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(project(), "Kick test", "t_j1", null, reopened = true)
        val before = c.ui.value
        // From the Mac (an inspector tab Android has no panel for), a deleted clip, a playhead past the end, "off".
        c.restorePlace(EditPlace(playhead = 999.0, tab = "anim", selection = "gone", safeArea = "off", zoom = 9999.0))
        val u = c.ui.value
        assertEquals(u.duration, u.playheadSec, 1e-6)
        assertNull(u.panel)
        assertEquals(before.selectedId, u.selectedId)
        assertEquals(PreviewView.CLEAN, u.preview.view)
        assertEquals(240f, u.pxPerSec)
    }

    @Test fun theDemoServerKeepsThePlaceAndListsTheLastWorkedOnFirst() = runTest {
        val api = FakeMuseApi(backgroundScope, null, speed = 0.0, genDelayMs = 0)
        val takes = api.listTakes().take(2)
        assertEquals(2, takes.size)
        val s1 = api.openEditSession(OpenEditSessionRequest(takes[0].id))
        val s2 = api.openEditSession(OpenEditSessionRequest(takes[1].id))
        api.saveEditView(s1.id, EditPlace(playhead = 2.0, binTab = "uploads").toJson())
        val recent = api.recentEditSessions()
        assertEquals(listOf(s1.id, s2.id), recent.map { it.id })
        assertEquals(2.0, EditPlace.of(recent[0].view)!!.playhead!!, 1e-9)
        assertTrue(recent[0].history.isEmpty())
        assertEquals("uploads", EditPlace.of(api.editSession(s1.id).view)!!.binTab)
        val items = EditRecent.items(recent.map { RecentSession(it.id, it.takeId, it.status, it.updatedAt, it.lastTouchedAt, EditPlace.of(it.view)) }, emptyList()) { null }
        assertEquals(s1.id, items.first().sessionId)
    }

    @Test fun thePhonesFileKeepsAMembersEditAcrossARestart() {
        val dir = tmp.newFolder()
        val p = EditJson.encode(project())
        EditRecentFile.of(dir).save(EditRecentEntry("t_j1", project = p, place = EditPlace(playhead = 3.0), title = "Kick test", savedAt = 1))
        EditRecentFile.of(dir).save(EditRecentEntry("t_j2", project = p, title = "Other", savedAt = 2))
        val again = EditRecentFile.of(dir).load() // a new file object: the app restarted
        assertEquals(listOf("Other", "Kick test"), again.map { it.title })
        assertEquals(project(), EditJson.parse(again[1].project!!))
        val items = EditRecent.items(emptyList(), again) { null }
        assertEquals("local:t_j2", items.first().id)
    }

}
