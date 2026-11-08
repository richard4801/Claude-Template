package studio.muse.app

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteTier
import studio.muse.app.data.SuiteTierModel
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.shotFor

/** WS7: the owner's engine pin applies the engine's own limits; "New video" opens Suite → Shot with the character. */
class EnginePinLimitsTest {
    private val short = SuiteTierModel("short-eng", "Short", "720p", minSeconds = 3, maxSeconds = 6, perSec = 0.05)
    private val bare = SuiteTierModel("bare-eng", "Bare", "1080p")
    private val cat = SuiteCatalog(enabled = true, tiers = listOf(SuiteTier("hd", "HD", available = true, minSeconds = 2, maxSeconds = 15, models = listOf(short, bare))))

    @Test fun pinnedEngineLimitsTheLength() {
        val d = ComposerDraft(quality = "hd", duration = 12).pin(short)
        assertEquals(6, d.duration)
        assertEquals(3..6, d.lengthRange(cat))
    }

    @Test fun engineWithoutLimitsFallsBackToTheTier() {
        val d = ComposerDraft(quality = "hd", duration = 12).pin(bare)
        assertEquals(12, d.duration)
        assertEquals(2..15, d.lengthRange(cat))
    }

    @Test fun autoUsesTheTier() {
        val d = ComposerDraft(quality = "hd", duration = 5).pin(short).pin(null)
        assertNull(d.engineModel)
        assertEquals(2..15, d.lengthRange(cat))
    }

    @Test fun olderServerJsonStillDecodes() {
        val json = Json { ignoreUnknownKeys = true }
        val m = json.decodeFromString(SuiteTierModel.serializer(), """{"model":"x","name":"X","resolution":"720p"}""")
        assertNull(m.maxSeconds); assertNull(m.perSec)
        val n = json.decodeFromString(SuiteTierModel.serializer(), """{"model":"x","minSeconds":1,"maxSeconds":10,"perSec":0.065}""")
        assertEquals(10, n.maxSeconds); assertEquals(0.065, n.perSec!!, 1e-9)
    }

    @Test fun newVideoOpensShotWithTheCharacter() {
        val d = shotFor(ComposerDraft(tool = ComposerTool.PHOTO), "m1")
        assertEquals(ComposerTool.SHOT, d.tool)
        assertEquals("m1", d.modelId)
        assertEquals(ComposerTool.SHOT, shotFor(ComposerDraft(tool = ComposerTool.SHOT, modelId = "m2"), null).tool)
        assertEquals("m2", shotFor(ComposerDraft(tool = ComposerTool.SHOT, modelId = "m2"), null).modelId)
    }
}
