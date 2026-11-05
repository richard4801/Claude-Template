package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.Account
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.Balance
import studio.muse.app.data.LiveEvents
import studio.muse.app.data.SampleData
import studio.muse.app.data.StudioBalance
import studio.muse.app.data.StudioState
import studio.muse.app.data.Take
import studio.muse.app.data.Template

/** Live events from another device (the Mac, a member's phone) land in the right place in the studio state. */
class LiveEventsTest {
    private val now = 1_700_000_000_000L
    private val base = StudioState(models = SampleData.models(), outfits = SampleData.outfits(), jobs = SampleData.jobs(now), takes = SampleData.takes(now), loaded = true)
    private fun apply(s: StudioState, ev: ApiEvent, owner: Boolean = false) = LiveEvents.apply(s, ev, owner)
    private fun shot(id: String, at: Long = now + 10) = Take(id = id, kind = "shot", title = "Shoot · Beach", label = "Beach · 1", createdAt = at)

    @Test fun aPhotoshootOnAnotherDeviceAppearsFirstThenChangesInPlaceAndGoes() {
        var s = apply(base, ApiEvent("take", take = shot("s_new")))
        assertEquals("s_new", s.takes.first().id)
        assertEquals(base.takes.size + 1, s.takes.size)
        // The same take again (our own shoot response, or a reconnect) never doubles it.
        s = apply(s, ApiEvent("take", take = shot("s_new")))
        assertEquals(base.takes.size + 1, s.takes.size)
        s = apply(s, ApiEvent("take", take = shot("s_new").copy(status = "final")))
        assertEquals("final", s.takes.first { it.id == "s_new" }.status)
        assertEquals(0, s.takes.indexOfFirst { it.id == "s_new" })
        s = apply(s, ApiEvent("take", op = "delete", id = "s_new"))
        assertTrue(s.takes.none { it.id == "s_new" })
        assertEquals(base.takes, s.takes)
    }

    @Test fun finishedJobTakesAndJobDelete() {
        val job = base.jobs.first()
        val s = apply(base, ApiEvent("job", job = job.copy(state = "done"), takes = listOf(shot("t_a", now + 5), shot("t_b", now + 6))))
        assertEquals(listOf("t_b", "t_a"), s.takes.take(2).map { it.id })
        assertEquals("done", s.job(job.id)!!.state)
        val gone = apply(s, ApiEvent("job", op = "delete", id = job.id))
        assertNull(gone.job(job.id))
    }

    @Test fun modelsCreateArchiveDelete() {
        val m = SampleData.models().first().copy(id = "m_live", name = "Live")
        var s = apply(base, ApiEvent("model", model = m))
        assertEquals("Live", s.model("m_live")!!.name)
        s = apply(s, ApiEvent("model", model = m.copy(name = "Renamed")))
        assertEquals("Renamed", s.model("m_live")!!.name)
        assertEquals(1, s.models.count { it.id == "m_live" })
        // Archived on the Mac: drops out here.
        s = apply(s, ApiEvent("model", model = m.copy(archived = true)))
        assertNull(s.model("m_live"))
        // Deleted: her outfits and accounts go with her.
        val withAccount = apply(base, ApiEvent("account", account = Account(SampleData.DEMO, "tiktok", "@demo")))
        assertEquals(1, withAccount.accountsOf(SampleData.DEMO).size)
        s = apply(withAccount, ApiEvent("model", op = "delete", id = SampleData.DEMO))
        assertNull(s.model(SampleData.DEMO))
        assertTrue(s.outfits.none { it.modelId == SampleData.DEMO })
        assertTrue(s.accountsOf(SampleData.DEMO).isEmpty())
    }

    @Test fun outfitsGenerateThenSaveOntoTheModel() {
        val o = SampleData.outfits().first().copy(id = "o_live", modelId = SampleData.DEMO, state = "generating")
        var s = apply(base, ApiEvent("outfit", outfit = o))
        assertEquals("generating", s.outfit("o_live")!!.state)
        assertTrue("o_live" !in s.model(SampleData.DEMO)!!.outfitIds)
        s = apply(s, ApiEvent("outfit", outfit = o.copy(state = "ready")))
        assertTrue("o_live" in s.model(SampleData.DEMO)!!.outfitIds)
    }

    @Test fun templatesUpsertKeepRecentAndDelete() {
        val t = Template(id = "tpl_live", name = "Laundrette", recent = emptyList())
        var s = apply(base, ApiEvent("template", template = t))
        assertEquals("Laundrette", s.templates.single().name)
        s = apply(s, ApiEvent("template", template = Template(id = "tpl_live", name = "Laundrette 2", uses = 3)))
        assertEquals(3, s.templates.single().uses)
        assertEquals(emptyList<Any>(), s.templates.single().recent)
        s = apply(s, ApiEvent("template", op = "delete", id = "tpl_live"))
        assertTrue(s.templates.isEmpty())
    }

    @Test fun moneyEventsAndOwnerOnlyStudioCard() {
        var s = apply(base, ApiEvent("balance", balance = Balance(12.5, 1.0)))
        assertEquals(12.5, s.balance.balance, 0.0)
        val card = StudioBalance(balanceUsd = 125.0, toppedUpUsd = 125.0)
        assertNull(apply(s, ApiEvent("studio", studioBalance = card), owner = false).studioBalance)
        s = apply(s, ApiEvent("studio", studioBalance = card), owner = true)
        assertEquals(125.0, s.studioBalance!!.balanceUsd, 0.0)
    }

    @Test fun accountsConnectAndDisconnect() {
        var s = apply(base, ApiEvent("account", modelId = SampleData.NOOR, account = Account(SampleData.NOOR, "instagram", "@noor")))
        assertEquals("@noor", s.account(SampleData.NOOR, "instagram")!!.handle)
        s = apply(s, ApiEvent("account", op = "delete", modelId = SampleData.NOOR, platform = "instagram"))
        assertNull(s.account(SampleData.NOOR, "instagram"))
    }

    @Test fun theConnectMarkerChangesNothing() {
        assertEquals(base, apply(base, ApiEvent(ApiEvent.CONNECTED)))
    }
}
