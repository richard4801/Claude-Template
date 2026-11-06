package studio.muse.app

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.ErrorBody
import studio.muse.app.data.Job
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteSettings
import studio.muse.app.data.SuiteShot
import studio.muse.app.data.Take
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.suite.SuitePane

/**
 * Decodes real /v1/suite answers, captured from server/api (SUITE_MODE=mock, then off) into test/resources/suite, with
 * the same Json settings as HttpMuseApi.
 */
class SuiteDecodeTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()

    @Test fun catalogOwnerAndMember() {
        val o = json.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_owner"))
        assertTrue(o.enabled); assertTrue(o.test)
        assertEquals(listOf("draft", "standard", "hd", "cinema"), o.tiers.map { it.id })
        assertEquals("Draft", o.tiers[0].label)
        assertTrue(o.tiers[0].models!!.isNotEmpty())
        assertEquals(4, o.recastMaxPeople)
        val mem = json.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_member"))
        assertTrue(mem.tiers.all { it.models == null })
        assertEquals(16, mem.camera.library.size)
    }

    @Test fun cameraCatalogHasRendersCaptionsAndTheLibrary() {
        val c = json.decodeFromString(CameraCatalog.serializer(), res("suite_camera"))
        val s35 = c.bodies.first { it.id == "super35" }
        assertEquals("body-02-super35", s35.render)
        assertEquals("Super 35 Digital", s35.name)
        assertEquals("Alexa 35 look · Super 35 · 4.6K", s35.caption)
        // Composer: Super 35 is merged into Cinema camera; the Creator camera (vlog) shows the creator-cine render.
        assertEquals("cinema_digital", s35.mergedInto)
        assertFalse(s35.visible)
        assertEquals("body-07-creator-cine", c.bodies.first { it.id == "vlog" }.render)
        assertEquals(listOf("aperture", "shutter"), c.optics.map { it.id })
        assertEquals("grip-01-dolly", c.grips.first { it.move == "dolly_in" }.render)
        assertEquals(16, c.library.size)
        assertEquals("ugc", c.library.first().tag)
        assertEquals("Locked-off", c.library.first().label)
        assertTrue(c.library.take(4).all { it.tag == "ugc" })
        assertTrue(c.moves.size >= 30)
        // Every render the catalog names is bundled with the app.
        val bundled = java.io.File("src/main/assets/hardware").list()!!.map { it.removeSuffix(".webp") }.toSet()
        val named = (c.bodies + c.lenses + c.looks + c.lighting + c.palettes).mapNotNull { it.render } + c.optics.mapNotNull { it.render } + c.grips.mapNotNull { it.render }
        assertTrue(named.isNotEmpty())
        assertTrue(named.filterNot { it in bundled }.toString(), named.all { it in bundled })
    }

    @Test fun estimatesMemberAndOwner() {
        val m = json.decodeFromString(SuiteEstimate.serializer(), res("suite_estimate_member"))
        assertEquals("Shot · Standard · 768p", m.label)
        assertEquals("Generate · 6 s · $0.96 · 2 takes", m.buttonLabel)
        assertEquals("about $0.96 · 6 s · 2 takes", m.priceLine)
        assertEquals(0.96, m.estimate, 1e-9)
        assertEquals(listOf("dolly_in", "rack_focus"), m.camera!!.moves)
        assertTrue(m.ok); assertNull(m.engine)
        val o = json.decodeFromString(SuiteEstimate.serializer(), res("suite_estimate_owner"))
        assertEquals("h3", o.engine!!.model)
        assertNotNull(o.engine!!.perSec)
    }

    @Test fun recastEstimate() {
        val e = json.decodeFromString(SuiteEstimate.serializer(), res("suite_recast_estimate_member"))
        assertEquals("recast", e.mode)
        assertEquals("Recast · HD · 1080p", e.label)
        assertEquals("the person on the left", e.cast!![0].who)
        assertEquals("yes", e.cast!![0].speaking)
        assertEquals(true, e.keepAudio)
        assertNull(e.engine)
        assertEquals("switch", e.speaking!!.source)
    }

    @Test fun errorsNothingFitsOffAndNoSheet() {
        val nf = json.decodeFromString(ErrorBody.serializer(), res("suite_nothing_fits_member"))
        assertEquals("nothing_fits", nf.code)
        val off = json.decodeFromString(ErrorBody.serializer(), res("suite_estimate_off"))
        assertEquals("engine_unavailable", off.code)
        val cat = json.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_off_owner"))
        assertFalse(cat.enabled)
        assertTrue(cat.tiers.none { it.available })
        assertEquals("bad_request", json.decodeFromString(ErrorBody.serializer(), res("suite_recast_no_sheet")).code)
    }

    @Test fun suiteJobsDecodeInTheJobListAndFollowThePane() {
        val job = json.decodeFromString(Job.serializer(), res("suite_shot_job"))
        assertEquals(SuiteRules.ENGINE, job.request.engine)
        assertEquals("", job.request.clipId)
        assertEquals("reference", job.request.mode)
        assertEquals(6.0, job.request.seconds!!, 0.0)
        assertEquals("Shot · Standard · 768p", job.engineLabel)
        assertEquals(StagePhase.QUEUED, SuitePane.of(job, emptyList(), "Demo model").phase)
        // The whole job list (seeded jobs + the suite job) still decodes.
        val all = json.decodeFromString(ListSerializer(Job.serializer()), res("suite_jobs_owner_all"))
        assertTrue(all.any { it.request.engine == SuiteRules.ENGINE })
        val done = json.decodeFromString(ListSerializer(Job.serializer()), res("suite_jobs_member")).single()
        val takes = json.decodeFromString(ListSerializer(Take.serializer()), res("suite_takes_member"))
        assertEquals(2, takes.size)
        assertEquals("Standard", takes[0].label)
        val pane = SuitePane.of(done, takes, "Demo model")
        assertEquals(StagePhase.READY, pane.phase)
        assertEquals(2, pane.takes.size)
    }

    @Test fun shotDetailAndSettings() {
        val m = json.decodeFromString(SuiteShot.serializer(), res("suite_shot_member"))
        assertNull(m.engine)
        val o = json.decodeFromString(SuiteShot.serializer(), res("suite_shot_owner"))
        assertEquals("replicate", o.engine!!.provider)
        val s = json.decodeFromString(SuiteSettings.serializer(), res("suite_settings"))
        assertEquals("mock", s.mode)
        assertEquals(5.0, s.caps.perJob, 0.0)
        assertTrue(s.ladder.keys.containsAll(SuiteRules.TIERS))
        val open = s.model("h3-open")!!
        assertTrue(open.blocked); assertFalse(open.enabled)
        assertEquals(0.08, s.model("h3")!!.perSec("768P")!!, 1e-9)
        assertEquals("owner_only", json.decodeFromString(ErrorBody.serializer(), res("suite_settings_member")).code)
    }
}
