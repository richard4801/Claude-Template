package studio.muse.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.OpenEditSessionRequest
import studio.muse.app.ui.screens.edit.answerEditApproval
import studio.muse.app.ui.screens.edit.editApprovalEvent
import studio.muse.app.ui.screens.edit.loadEditApprovals
import studio.muse.core.edit.BLANK_SOURCE
import studio.muse.core.edit.EditApprovalList

/**
 * Owner issue ci_e546642a4026 (2026-11-12) on Android, demo mode: a paid helper Claude asked for on ANOTHER edit session
 * is listed in the open edit's Claude sheet, named after its edit, and Allow answers it on its own session.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class EditApprovalsTest {
    private fun <T> withFake(f: suspend (FakeMuseApi) -> T): T = runBlocking {
        val work = CoroutineScope(Dispatchers.Default)
        try { f(FakeMuseApi(work, null, speed = 0.0, genDelayMs = 0)) } finally { work.cancel() }
    }

    @Test fun anotherEditsHelperIsListedAndAllowedOnItsOwnSession() = withFake { fake ->
        val open = fake.openEditSession(OpenEditSessionRequest(BLANK_SOURCE))
        val other = fake.openEditSession(OpenEditSessionRequest(BLANK_SOURCE))
        val p = fake.claudeAsk(other.id, "matte", "Remove background", 0.4)
        val list = loadEditApprovals(fake)
        assertNotNull(list)
        val shown = list!!.except(open.id)
        assertEquals(listOf(other.id), shown.map { it.sessionId })
        val a = shown.single()
        assertEquals("Allow · $0.40", a.allowLabel)
        assertEquals("New project", EditApprovalList.editName(a.takeId, null))
        val (gone, said) = answerEditApproval(fake, a, approve = true, editName = "New project")
        assertTrue(gone)
        assertEquals("Remove background started in “New project”. Claude's change lands when it's done.", said)
        assertTrue("answered on its own session", fake.recentEditSessions(50).first { it.id == other.id }.pending.none { it.id == p.id && it.status == "waiting" })
        assertTrue(loadEditApprovals(fake)!!.except(open.id).isEmpty())
        // Answered again (another phone got there first): off the list, said plainly.
        assertEquals(true to "That was already answered", answerEditApproval(fake, a, approve = false, editName = "New project"))
    }

    @Test fun liveEventsKeepTheListCurrent() = withFake { fake ->
        val s = fake.openEditSession(OpenEditSessionRequest(BLANK_SOURCE))
        val p = fake.claudeAsk(s.id, "captions", "Captions", 0.05)
        val listed = editApprovalEvent(EditApprovalList(), ApiEvent("edit", sessionId = s.id, op = "pending", pending = p))
        assertEquals(listOf("${s.id}/${p.id}"), listed?.items?.map { it.id })
        val gone = editApprovalEvent(listed!!, ApiEvent("edit", sessionId = s.id, op = "pending", pending = p.copy(status = "running")))
        assertTrue(gone!!.isEmpty())
        assertNull(editApprovalEvent(listed, ApiEvent("edit", sessionId = s.id, op = "patch")))
        assertNull(editApprovalEvent(listed, ApiEvent("jobs")))
    }
}
