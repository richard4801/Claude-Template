package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.SuiteResolution
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ModelPicker
import studio.muse.app.ui.screens.suite.composer.PickerEngine
import studio.muse.app.ui.screens.suite.composer.pinEngine
import studio.muse.app.ui.screens.suite.composer.pinNote

/** One model on several providers (server 2026-11-14): each resolution names its provider; live-priced chips show. */
class PickerRoutesTest {
    private val seedance = PickerEngine(
        "seedance-2.5", "Seedance 2.5 · Replicate + Higgsfield", listOf("cinema"), "720p",
        listOf(
            SuiteResolution("480p", "480p", 480, 0.1028, "replicate", "Replicate", "Seedance 2.5 · Replicate"),
            SuiteResolution("720p", "720p", 720, 0.2312, "replicate", "Replicate", "Seedance 2.5 · Replicate"),
            SuiteResolution("1080p", "1080p", 1080, 0.0, "higgsfield", "Higgsfield", "Seedance 2.5 · Higgsfield", livePrice = true),
        ),
        4, 30, null, listOf("9:16", "16:9"), 0.2312, null, custom = false,
    )
    private val kling = PickerEngine(
        "kling-v4", "Kling 4.0", listOf("standard"), "720p",
        listOf(SuiteResolution("720p", "720p", 720, 0.157), SuiteResolution("1080p", "1080p", 1080, 0.235)),
        3, 30, null, listOf("9:16", "16:9"), 0.157, null, custom = false,
    )

    @Test fun liveResolutionsShowAsPricedAtGenerate() {
        assertEquals(listOf("480p  $0.10/s", "720p  $0.23/s", "1080p  priced at Generate"), seedance.chips.map { it.second })
        assertEquals("1080p  priced at Generate", seedance.price("1080p"))
        assertTrue(seedance.resolutions[2].pricedAtGenerate)
        assertFalse(kling.resolutions[0].pricedAtGenerate)
    }

    @Test fun theProviderOfTheChosenResolution() {
        assertEquals("Seedance 2.5 · Higgsfield", seedance.nameAt("1080p"))
        assertEquals("Seedance 2.5 · Replicate", seedance.nameAt("480p"))
        assertEquals("an older server: the model's own name", "Kling 4.0", kling.nameAt("720p"))
    }

    @Test fun switchingModelsKeepsTheResolutionElseTheNearestWithANote() {
        val hi = ComposerDraft(quality = "cinema").pinEngine(seedance, "1080p")
        assertEquals("1080p", hi.resolution)
        assertEquals("1080p", hi.pinEngine(kling).resolution)
        assertNull(hi.pinNote(kling))
        val low = hi.pinEngine(seedance, "480p")
        assertEquals("720p", low.pinEngine(kling).resolution)
        assertEquals("Kling 4.0 makes 720p, 1080p · using 720p", low.pinNote(kling))
        // From Auto: the ladder's resolution, no note.
        assertEquals("720p", ComposerDraft(quality = "standard").pinEngine(kling).resolution)
        assertNull(ComposerDraft(quality = "standard").pinNote(kling))
        assertEquals("1080p", kling.snapRes("4k"))
        assertEquals("1080p", kling.snapRes("1080P"))
        assertEquals(1440, ModelPicker.pixels("2K"))
        assertEquals(768, ModelPicker.pixels("768P"))
    }
}
