package studio.muse.app

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.DecideRequest
import studio.muse.app.data.EnhanceFeatures
import studio.muse.app.data.EnhanceRequest
import studio.muse.app.data.FakeCatalog
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SampleData
import studio.muse.app.data.SetStepModelRequest
import studio.muse.app.data.Sheet
import studio.muse.app.data.ToolRun
import studio.muse.app.data.ApiException

/** Model tools in Demo mode (plans/api.md "Model tools"): estimates, Enhance review/apply, catalog, archive (Dress up was removed 2026-11-11). */
class ModelToolsTest {
    @Test fun estimatesMatchTheContract() {
        // Enhance on the defaults: Krea $0.025 + Clarity's typical $0.018 per image → "7 images · about $0.30".
        assertEquals(0.043, FakeCatalog.estimate("black-forest-labs/flux-krea-dev", 1.0, 0.79) + FakeCatalog.estimate("philz1337x/clarity-upscaler", 4.0, 0.79, 2.0), 1e-9)
        assertEquals(0.072, FakeCatalog.estimate("philz1337x/clarity-upscaler", 4.0, 0.79, 4.0), 1e-9)
        assertEquals(0.015 + 0.015 * 1.58 + 0.015, FakeCatalog.estimate("black-forest-labs/flux-2-pro", 1.0, 1.58), 1e-9)
        assertEquals(0.05, FakeCatalog.estimate("nobody/unknown", 1.0, 1.0), 1e-9)
    }

    @Test fun memberLabelsNameNoModelsOrProviders() {
        val e = EnhanceFeatures()
        val text = (e.realism + e.upscale).joinToString { it.label + it.detail }
        assertFalse(Regex("(?i)qwen|flux|replicate|clarity|krea|gpu").containsMatchIn(text))
    }

    @Test fun sheetHasSevenImages() {
        assertEquals(7, SampleData.models().first().slots.size)
        assertEquals(listOf("face", "faceTq", "profile", "front", "tq", "side", "back"), Sheet.SLOTS.map { it.key })
        // Missing the face ¾ still counts as locked (a warning only).
        val m = SampleData.models().first()
        assertTrue(m.copy(slots = m.slots.map { if (it.key == "faceTq") it.copy(image = null) else it }).locked)
        assertFalse(m.copy(slots = m.slots.map { if (it.key == "front") it.copy(image = null) else it }).locked)
    }

    private suspend fun FakeMuseApi.finish(r: ToolRun, tick: suspend () -> Unit): ToolRun {
        var x = r
        repeat(50) { if (x.state == "running") { tick(); x = toolRun(r.id) } }
        return x
    }

    @Test fun enhance() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 40)
        val est = api.enhanceEstimate(SampleData.DEMO, EnhanceRequest())
        assertEquals("7 images · about \$0.30", est.label)
        val run = api.finish(api.startEnhance(SampleData.DEMO, EnhanceRequest())) { testScheduler.advanceTimeBy(100); testScheduler.runCurrent() }
        assertEquals("review", run.state)
        assertEquals(Sheet.SLOTS.map { it.key }, run.items.map { it.slot })
        try { api.applyTool(run.id); error("expected bad_request") } catch (e: ApiException) { assertEquals("bad_request", e.code) }
        api.decideTool(run.id, "face", DecideRequest("keep"))
        api.decideTool(run.id, "back", DecideRequest("reject"))
        val applied = api.applyTool(run.id)
        assertEquals("applied", applied.run.state)
        assertEquals(1, api.sheetVersions(SampleData.DEMO).size)
    }

    @Test fun catalogAndArchive() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 0)
        assertEquals(Sheet.STEPS, api.imageModels().steps.map { it.step })
        val up = api.imageCatalog("upscale")
        assertTrue(up.models.first { it.id == "philz1337x/clarity-upscaler" }.compatible == true)
        try { api.setImageModel("realism", SetStepModelRequest("topazlabs/image-upscale")); error("expected") } catch (e: ApiException) { assertEquals("model_incompatible", e.code) }
        assertFalse(api.setImageModel("upscale", SetStepModelRequest("topazlabs/image-upscale")).isDefault)
        assertTrue(api.resetImageModel("upscale").isDefault)
        api.archiveModel(SampleData.NOOR, true)
        assertNull(api.listModels().firstOrNull { it.id == SampleData.NOOR })
        assertEquals(listOf(SampleData.NOOR), api.archivedModels().map { it.id })
        try { api.startEnhance(SampleData.NOOR, EnhanceRequest()); error("expected") } catch (e: ApiException) { assertEquals("model_archived", e.code) }
        api.archiveModel(SampleData.NOOR, false)
        assertTrue(api.listModels().any { it.id == SampleData.NOOR })
    }
}
