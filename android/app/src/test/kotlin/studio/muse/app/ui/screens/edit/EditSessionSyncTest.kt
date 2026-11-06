package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import studio.muse.core.edit.splitAt
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.EditRequestAnswer
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeMuseApi
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.JsonPatch
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.problemOf

/** Edit sessions (workstream 3): the owner's Edit suite in step with the session, against the demo backend's sessions. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditSessionSyncTest {
    private class NoAi : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = null to "off"
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = null to "off"
    }

    private class StubHost : SessionHost {
        val frames = ArrayList<Pair<Double, Int>>()
        val saves = ArrayList<String?>()
        val exports = ArrayList<JsonObject?>()
        override suspend fun renderFrame(project: EditProject, t: Double, width: Int): Pair<ByteArray?, String?> { frames += t to width; return byteArrayOf(1, 2, 3) to null }
        override suspend fun saveVersion(name: String?): Pair<String?, String?> { saves += name; return "t_v2" to null }
        /** The app's real gate: the export sheet opens and waits for the owner. */
        var gate: OwnerExportGate? = null
        override suspend fun export(preset: JsonObject?): Pair<String?, String?> { exports += preset; return gate?.request(preset) ?: ("t_v3" to null) }
    }

    private fun project() = EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true))

    private class Rig(val api: FakeMuseApi, val c: EditSuiteController, val sync: EditSessionSync, val host: StubHost) {
        val sid get() = sync.sessionId!!
    }

    private suspend fun TestScope.rig(events: ((FakeMuseApi) -> Flow<ApiEvent>)? = null): Rig {
        val bg: CoroutineScope = backgroundScope
        val api = FakeMuseApi(bg, null, speed = 0.0, genDelayMs = 0)
        val c = EditSuiteController(bg, NoAi())
        c.load(project(), "Kick test", "t_j1", null, reopened = true)
        val host = StubHost().also { it.gate = OwnerExportGate(bg, c) }
        val sync = EditSessionSync(bg, { api }, events?.invoke(api) ?: api.events(), c, host, "android-test", "Pixel", presenceMs = 3_600_000)
        assertTrue(sync.start("t_j1", EditJson.encode(project()), "t_v1"))
        runCurrent()
        return Rig(api, c, sync, host)
    }

    private fun TestScope.settle() { advanceTimeBy(600); runCurrent() }

    @Test fun localChangesGoUpDebouncedWithTheirLabels() = runTest {
        val r = rig()
        assertEquals(0, r.sync.revision)
        assertNotNull(r.c.ui.value.session)
        r.c.act(EditAction.Seek(5.0)); r.c.act(EditAction.Split)
        r.c.act(EditAction.Seek(8.0)); r.c.act(EditAction.Split)
        settle()
        assertEquals(1, r.api.editPushes.size) // two splits within the debounce → one change
        assertEquals("Split", r.api.editPushes[0].first)
        assertEquals(1, r.sync.revision)
        assertTrue(JsonPatch.jsonEqual(r.api.editProjectOf(r.sid), EditJson.encode(r.c.project!!)))
        assertEquals("app:android-test", r.c.ui.value.session!!.history.first().author)
    }

    @Test fun staleRevisionRefetchesRebasesAndResends() = runTest {
        val r = rig(events = { emptyFlow() }) // the SSE stream missed Claude's change
        r.api.claudeEdit(r.sid, "Background") { it.copy(canvas = it.canvas.copy(background = "#111111")) }
        r.c.act(EditAction.Seek(5.0)); r.c.act(EditAction.Split)
        settle()
        assertEquals(2, r.sync.revision) // Claude's (1) then ours rebased on it (2)
        val server = EditJson.parse(r.api.editProjectOf(r.sid))
        assertEquals(2, server.mainClips.size)
        assertEquals("#111111", server.canvas.background)
        assertEquals(server, r.c.project) // the local editor has Claude's change too
    }

    @Test fun remotePatchesApplyWithAClaudeNoteAndBadge() = runTest {
        val r = rig()
        r.api.claudeEdit(r.sid, "Trimmed 0:00.5–0:06.0") { p -> p.copy(tracks = p.tracks.map { t -> t.copy(items = t.items.map { (it as VideoClip).copy(inSec = 0.5, outSec = 6.0) }) }) }
        runCurrent()
        val clip = r.c.project!!.mainClips.single()
        assertEquals(0.5, clip.inSec, 1e-9); assertEquals(6.0, clip.outSec, 1e-9)
        val s = r.c.ui.value.session!!
        assertEquals("Claude · Trimmed 0:00.5–0:06.0", s.claudeNote)
        assertTrue(s.history.first().byClaude)
        assertEquals(1, r.sync.revision)
        settle()
        assertTrue(r.api.editPushes.isEmpty()) // a remote change isn't sent back
        r.c.act(EditAction.ClearClaudeNote)
        assertNull(r.c.ui.value.session!!.claudeNote)
    }

    @Test fun remoteChangesAreNotInLocalUndo() = runTest {
        val r = rig()
        r.c.act(EditAction.Seek(5.0)); r.c.act(EditAction.Split); settle()
        r.api.claudeEdit(r.sid, "Background") { it.copy(canvas = it.canvas.copy(background = "#111111")) }
        runCurrent()
        assertEquals("#111111", r.c.project!!.canvas.background)
        // Undo takes back this device's split only; Claude's change stays.
        r.c.act(EditAction.Undo)
        assertEquals(1, r.c.project!!.mainClips.size)
        assertEquals("#111111", r.c.project!!.canvas.background)
        assertFalse(r.c.ui.value.canUndo) // nothing of Claude's to undo locally
        r.c.act(EditAction.Redo)
        assertEquals(2, r.c.project!!.mainClips.size)
        assertEquals("#111111", r.c.project!!.canvas.background)
        settle()
        assertEquals("#111111", EditJson.parse(r.api.editProjectOf(r.sid)).canvas.background) // never reverted on the server
    }

    @Test fun undoingClaudesChangeGoesThroughTheHistoryPanel() = runTest {
        val r = rig()
        val entry = r.api.claudeEdit(r.sid, "Trimmed 0:00.5–0:06.0") { p -> p.copy(tracks = p.tracks.map { t -> t.copy(items = t.items.map { (it as VideoClip).copy(inSec = 0.5, outSec = 6.0) }) }) }!!
        runCurrent()
        assertFalse(r.c.ui.value.canUndo) // not this device's change
        r.c.act(EditAction.Undo); runCurrent()
        assertEquals(0.5, r.c.project!!.mainClips.single().inSec, 1e-9)
        r.c.act(EditAction.UndoEntry(entry.id))
        runCurrent(); settle()
        assertEquals(project(), r.c.project)
        assertEquals(project(), EditJson.parse(r.api.editProjectOf(r.sid)))
        val h = r.c.ui.value.session!!.history
        assertEquals("Undo: Trimmed 0:00.5–0:06.0", h.first().label)
        assertTrue(h.first { it.id == entry.id }.undone)
        assertTrue(r.api.editPushes.isEmpty()) // undone on the server, not re-sent as a local edit
        // A local change after that still syncs, and undo of a local change stays local.
        r.c.act(EditAction.Seek(4.0)); r.c.act(EditAction.Split); settle()
        r.c.act(EditAction.Undo); settle()
        assertEquals(listOf("Split", "Undo"), r.api.editPushes.map { it.first })
    }

    @Test fun localEditsBeforeTheSessionAskKeep() = runTest {
        val (api, c, sync) = conflictRig()
        assertTrue(c.ui.value.session!!.conflict)
        settle()
        assertTrue(api.editPushes.isEmpty()) // nothing is sent until the owner picks
        assertEquals(2, c.project!!.mainClips.size) // this device's edit is still shown
        c.act(EditAction.ResolveConflict(keepLocal = true)); runCurrent(); settle()
        assertFalse(c.ui.value.session!!.conflict)
        assertEquals("This device's changes", api.editPushes.single().first)
        val server = EditJson.parse(api.editProjectOf(sync.sessionId!!))
        assertEquals(2, server.mainClips.size) // pushed on top of the latest revision…
        assertEquals("#222222", server.canvas.background) // …which keeps the other device's change
        assertEquals(server, c.project)
        assertEquals(2, sync.revision)
    }

    @Test fun localEditsBeforeTheSessionAskUseTheLatest() = runTest {
        val (api, c, sync) = conflictRig()
        c.act(EditAction.ResolveConflict(keepLocal = false)); runCurrent(); settle()
        assertFalse(c.ui.value.session!!.conflict)
        assertTrue(api.editPushes.isEmpty())
        assertEquals(EditJson.parse(api.editProjectOf(sync.sessionId!!)), c.project)
        assertEquals("#222222", c.project!!.canvas.background)
        assertEquals(1, c.project!!.mainClips.size)
        assertFalse(c.ui.value.canUndo)
    }

    private class MemDrafts : EditDrafts {
        val map = HashMap<String, Pair<JsonObject, JsonObject>>()
        override fun read(takeId: String) = map[takeId]
        override fun write(takeId: String, base: JsonObject, project: JsonObject) { map[takeId] = base to project }
        override fun clear(takeId: String) { map.remove(takeId) }
    }

    @Test fun unsentEditsSurviveTheAppClosingAndKeepPreservesClaudesChange() = runTest {
        val bg = backgroundScope
        val api = FakeMuseApi(bg, null, speed = 0.0, genDelayMs = 0)
        val sid = api.openEditSession(studio.muse.app.data.OpenEditSessionRequest("t_j1", EditJson.encode(project()))).id
        val drafts = MemDrafts()
        // 1. Offline: the phone splits; the edit is written down at once.
        val offlineApi = object : studio.muse.app.data.MuseApi by api {
            override suspend fun openEditSession(req: studio.muse.app.data.OpenEditSessionRequest): studio.muse.app.data.EditSessionDto = throw java.io.IOException("no network")
        }
        val c1 = EditSuiteController(bg, NoAi()).also { it.load(project(), "Kick test", "t_j1", null, reopened = true) }
        val s1 = EditSessionSync(bg, { offlineApi }, api.events(), c1, StubHost(), "android-test", "Pixel", presenceMs = 3_600_000, drafts = drafts)
        bg.launch { s1.connect("t_j1", null, null, retryMs = 60_000) }
        runCurrent()
        c1.act(EditAction.Seek(5.0)); c1.act(EditAction.Split); runCurrent()
        assertEquals(2, EditJson.parse(drafts.read("t_j1")!!.second).mainClips.size)
        // 2. The app closes. Meanwhile Claude changes the background.
        s1.stop(bg)
        api.claudeEdit(sid, "Background") { it.copy(canvas = it.canvas.copy(background = "#222222")) }
        // 3. Reopened online: the unsent split comes back, and the owner is asked.
        val c2 = EditSuiteController(bg, NoAi()).also { it.load(project(), "Kick test", "t_j1", null, reopened = true) }
        val s2 = EditSessionSync(bg, { api }, api.events(), c2, StubHost(), "android-test", "Pixel", presenceMs = 3_600_000, drafts = drafts)
        assertTrue(bg.async { s2.connect("t_j1", null, null) }.await())
        runCurrent()
        assertEquals(2, c2.project!!.mainClips.size)
        assertTrue(c2.ui.value.session!!.conflict)
        // 4. Keep: only this device's split goes on top of the latest; Claude's background stays.
        c2.act(EditAction.ResolveConflict(true)); runCurrent(); settle()
        val server = EditJson.parse(api.editProjectOf(sid))
        assertEquals(2, server.mainClips.size)
        assertEquals("#222222", server.canvas.background)
        assertEquals(server, c2.project)
        assertNull(drafts.read("t_j1")) // the session has them now
    }

    @Test fun unsentEditsOnAnUnchangedSessionGoUpWithoutAsking() = runTest {
        val bg = backgroundScope
        val api = FakeMuseApi(bg, null, speed = 0.0, genDelayMs = 0)
        api.openEditSession(studio.muse.app.data.OpenEditSessionRequest("t_j1", EditJson.encode(project())))
        val split = project().splitAt(5.0)
        val drafts = MemDrafts().also { it.write("t_j1", EditJson.encode(project()), EditJson.encode(split!!)) }
        val c = EditSuiteController(bg, NoAi()).also { it.load(project(), "Kick test", "t_j1", null, reopened = true) }
        val s = EditSessionSync(bg, { api }, api.events(), c, StubHost(), "android-test", "Pixel", presenceMs = 3_600_000, drafts = drafts)
        assertTrue(bg.async { s.connect("t_j1", null, null) }.await())
        runCurrent(); settle()
        assertFalse(c.ui.value.session!!.conflict)
        assertEquals(2, EditJson.parse(api.editProjectOf(s.sessionId!!)).mainClips.size)
        assertNull(drafts.read("t_j1"))
        assertTrue(c.ui.value.canUndo) // the restored edits are this device's own
    }

    @Test fun fileDraftsRoundTrip() {
        val dir = java.nio.file.Files.createTempDirectory("drafts").toFile()
        try {
            val d = FileEditDrafts(dir)
            assertNull(d.read("t_j1"))
            d.write("t_j1", EditJson.encode(project()), EditJson.encode(project().copy(canvas = project().canvas.copy(background = "#111111"))))
            val (b, p) = FileEditDrafts(dir).read("t_j1")!! // a new instance: what the next app start sees
            assertEquals(project(), EditJson.parse(b))
            assertEquals("#111111", EditJson.parse(p).canvas.background)
            d.clear("t_j1")
            assertNull(d.read("t_j1"))
        } finally { dir.deleteRecursively() }
    }

    @Test fun noEditsOnThisDeviceMeansNoQuestion() = runTest {
        val r = rig()
        assertFalse(r.c.ui.value.session!!.conflict)
    }

    /** The session moved on (another device) while this phone edited offline; then the phone connects. */
    private suspend fun TestScope.conflictRig(): Triple<FakeMuseApi, EditSuiteController, EditSessionSync> {
        val bg = backgroundScope
        val api = FakeMuseApi(bg, null, speed = 0.0, genDelayMs = 0)
        val s = api.openEditSession(studio.muse.app.data.OpenEditSessionRequest("t_j1", EditJson.encode(project())))
        api.claudeEdit(s.id, "Background") { it.copy(canvas = it.canvas.copy(background = "#222222")) }
        var offline = true
        val flaky = object : studio.muse.app.data.MuseApi by api {
            override suspend fun openEditSession(req: studio.muse.app.data.OpenEditSessionRequest) =
                if (offline) throw java.io.IOException("no network") else api.openEditSession(req)
        }
        val c = EditSuiteController(bg, NoAi())
        c.load(project(), "Kick test", "t_j1", null, reopened = true)
        val sync = EditSessionSync(bg, { flaky }, api.events(), c, StubHost(), "android-test", "Pixel", presenceMs = 3_600_000)
        val joined = bg.async { sync.connect("t_j1", EditJson.encode(project()), "t_v1", retryMs = 10_000) }
        runCurrent()
        assertTrue(sync.offline)
        c.act(EditAction.Seek(5.0)); c.act(EditAction.Split) // edited while offline
        offline = false
        advanceTimeBy(10_001); runCurrent()
        assertTrue(joined.await())
        return Triple(api, c, sync)
    }

    @Test fun historySheetUndoesAnyEntry() = runTest {
        val r = rig()
        r.c.act(EditAction.Seek(5.0)); r.c.act(EditAction.Split); settle()
        val mine = r.c.ui.value.session!!.history.first()
        r.c.act(EditAction.UndoEntry(mine.id)); runCurrent(); settle()
        assertEquals(1, r.c.project!!.mainClips.size)
        assertEquals(1, EditJson.parse(r.api.editProjectOf(r.sid)).mainClips.size)
    }

    @Test fun frameRequestsRenderUploadAndAnswer() = runTest {
        val r = rig()
        val rid = r.api.claudeFrame(r.sid, 2.0, 320, device = "android-test")
        runCurrent()
        assertEquals(listOf(2.0 to 320), r.host.frames)
        val up = r.api.editFrameAnswers[rid]!!
        assertTrue(r.api.editUploads[up]!!.contentEquals(byteArrayOf(1, 2, 3)))
        // A request for another device is left to it.
        r.api.claudeFrame(r.sid, 3.0, 320, device = "mac-1"); runCurrent()
        assertEquals(1, r.host.frames.size)
    }

    @Test fun saveRequestsRunSaveToGalleryAndAnswer() = runTest {
        val r = rig()
        val save = r.api.claudeAppRequest(r.sid, "save", name = "Cut v2", device = "android-test")
        runCurrent()
        assertEquals(listOf<String?>("Cut v2"), r.host.saves)
        assertEquals("t_v2", r.api.editRequestAnswers[save.id]!!.versionId)
    }

    @Test fun theSaveNameGoesWithTheVersion() = runTest {
        // The request the real API gets: `name`, trimmed and at most 80 characters; none when blank.
        val json = kotlinx.serialization.json.Json { explicitNulls = false; encodeDefaults = true }
        val req = studio.muse.app.data.TakeVersionV2Request("up_1", null, EditJson.encode(project()), 12.0, 1080, 1920, 30.0, name = studio.muse.app.data.versionName("  Cut v2 "))
        assertTrue(json.encodeToString(studio.muse.app.data.TakeVersionV2Request.serializer(), req).contains("\"name\":\"Cut v2\""))
        assertNull(studio.muse.app.data.versionName("   "))
        assertEquals(80, studio.muse.app.data.versionName("x".repeat(120))!!.length)
        val unnamed = req.copy(name = null)
        assertFalse(json.encodeToString(studio.muse.app.data.TakeVersionV2Request.serializer(), unnamed).contains("\"name\""))
        // The demo backend keeps it on the new version (Take.name), like the server.
        val api = FakeMuseApi(backgroundScope, null, speed = 0.0, genDelayMs = 0)
        val f = java.io.File.createTempFile("edit", ".mp4")
        try {
            val t = api.saveProjectVersion("t_j1", studio.muse.app.data.EditedVideo(f, null, 12.0, 1080, 1920, 30.0), EditJson.encode(project()), name = " Cut v2 ")
            assertEquals("Cut v2", t.name)
        } finally { f.delete() }
    }

    @Test fun exportRequestsOpenTheSheetAndWaitForTheOwner() = runTest {
        val r = rig()
        val preset = JsonObject(mapOf("resolution" to JsonPrimitive("720p"), "aiLabel" to JsonPrimitive(true), "c2pa" to JsonPrimitive(true)))
        val ex = r.api.claudeAppRequest(r.sid, "export", preset = preset, device = "android-test")
        runCurrent(); advanceTimeBy(60_000); runCurrent()
        // Not run unattended: the sheet is open with Claude's preset, the disclosure switches untouched, no answer yet.
        assertFalse(r.host.exports.single()!!.containsKey("aiLabel"))
        val u = r.c.ui.value
        assertEquals(Panel.EXPORT, u.panel)
        assertEquals(studio.muse.core.edit.ExportResolution.HD, u.export.resolution)
        assertFalse(u.export.aiLabel); assertFalse(u.export.contentCredentials)
        assertNull(r.api.editRequestAnswers[ex.id])
        assertTrue(r.host.gate!!.isWaiting)
        // The owner taps EXPORT; when it's saved, the request is answered with the new version.
        r.c.setPhase(SuitePhase.Exporting(.5f)); runCurrent()
        r.host.gate!!.exported("t_v3")
        r.c.update { it.copy(phase = SuitePhase.Ready, panel = null) }
        runCurrent()
        assertEquals(EditRequestAnswer("done", versionId = "t_v3"), r.api.editRequestAnswers[ex.id])
        // Closing the sheet instead is a no: failed.
        val ex2 = r.api.claudeAppRequest(r.sid, "export", preset = null, device = "android-test")
        runCurrent()
        assertEquals(Panel.EXPORT, r.c.ui.value.panel)
        r.c.act(EditAction.Open(null)); runCurrent()
        assertEquals("failed", r.api.editRequestAnswers[ex2.id]!!.status)
        // Cancelling (the export sheet's Cancel) too.
        val ex3 = r.api.claudeAppRequest(r.sid, "export", preset = null, device = "android-test")
        runCurrent()
        r.host.gate!!.cancelled(); runCurrent()
        assertEquals("failed", r.api.editRequestAnswers[ex3.id]!!.status)
        assertFalse(r.host.gate!!.isWaiting)
        // The preset never turns the owner's disclosure switches on.
        val s = studio.muse.core.edit.SessionSync.applyExportPreset(ExportSettings(), preset)
        assertFalse(s.aiLabel); assertFalse(s.contentCredentials)
    }

    @Test fun paidHelpersWaitForTheOwnersYes() = runTest {
        val r = rig()
        val p = r.api.claudeAsk(r.sid, "matte", "Remove background", 0.04)
        runCurrent()
        val asking = r.c.ui.value.session!!.asking!!
        assertEquals(p.id, asking.id)
        assertEquals("about $0.04", aboutUsd(asking.estimateUsd))
        r.c.act(EditAction.AnswerPending(p.id, true))
        runCurrent()
        assertNull(r.c.ui.value.session!!.asking)
        assertEquals("running", r.api.editSession(r.sid).pending.single().status)
        // "Not now" declines.
        val q = r.api.claudeAsk(r.sid, "denoise", "Denoise", 0.01); runCurrent()
        r.c.act(EditAction.AnswerPending(q.id, false)); runCurrent()
        assertNull(r.c.ui.value.session!!.asking)
        assertTrue(r.api.editSession(r.sid).pending.none { it.id == q.id })
    }

    @Test fun claudePanelOpensAndCloses() = runTest {
        val r = rig()
        r.c.act(EditAction.ClaudePanel(true)); assertTrue(r.c.ui.value.session!!.chatOpen)
        r.c.act(EditAction.ClaudePanel(false)); assertFalse(r.c.ui.value.session!!.chatOpen)
    }

    @Test fun membersAndOfflineStayLocal() = runTest {
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(project(), "Kick test", "t_j1", null, reopened = false)
        // The default MuseApi (no session support) → start answers false and the editor keeps working alone.
        val plain = object : studio.muse.app.data.MuseApi by FakeMuseApi(backgroundScope, null, speed = 0.0, genDelayMs = 0) {
            override suspend fun openEditSession(req: studio.muse.app.data.OpenEditSessionRequest) = throw studio.muse.app.data.ApiException("owner_only", "Editing with Claude is for the studio owner")
        }
        val sync = EditSessionSync(backgroundScope, { plain }, emptyFlow(), c, StubHost(), "d", "Pixel")
        assertFalse(sync.start("t_j1"))
        assertNull(c.ui.value.session)
        assertNull(c.sessionActions)
        // The Claude button without a session says why instead of opening (no crash, nothing opens).
        c.act(EditAction.ClaudePanel(true))
        assertNull(c.ui.value.session)
        assertTrue(c.ui.value.message!!.startsWith("Claude joins once this edit is online"))
        c.act(EditAction.Seek(5.0)); c.act(EditAction.Split); c.act(EditAction.Undo)
        assertEquals(1, c.project!!.mainClips.size)
    }

    @Test fun aSuiteTakeOpensWithItsLook() {
        val p = EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true), lut = "palette:warm_honey")
        val look = p.mainClips.single().look!!
        assertEquals("palette:warm_honey", look.lut); assertEquals(1.0, look.strength!!, 1e-9)
        assertNull(problemOf(p, paletteIds = setOf("warm_honey")))
        assertNull(EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true), lut = "").mainClips.single().look)
        // Reversible like any look: picking "None" takes it off.
        val c = EditSuiteController(kotlinx.coroutines.MainScope(), NoAi())
        c.load(p, "x", "t_j1", null, reopened = false)
        c.act(EditAction.PickLook(null, null))
        assertNull(c.project!!.mainClips.single().look)
        c.act(EditAction.Undo)
        assertEquals("palette:warm_honey", c.project!!.mainClips.single().look!!.lut)
    }

    @Suppress("unused") private val keep = EditorEstimate::class
}
