package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Background removal's alpha matte (workstream 1, plans/api.md "VideoClip.alphaMatte"): model, JSON, rules and timing. */
class AlphaMatteTest {
    private fun project(matteKind: String = "video") = EditJson.parse("""
        {"version":2,"sourceTakeId":"t1","canvas":{"width":1080,"height":1920,"fps":30},
         "assets":[{"id":"src","kind":"video","take":"t1","durationSec":10},{"id":"m1","kind":"$matteKind","upload":"up_m","durationSec":10}],
         "tracks":[{"id":"main","kind":"main","items":[{"id":"c1","asset":"src","inSec":2,"outSec":8,"speed":1,"alphaMatte":{"asset":"m1","invert":true}}]}]}
    """.trimIndent())

    @Test fun `reads and writes alphaMatte`() {
        val c = project().mainClips.single()
        assertEquals(AlphaMatte("m1", true), c.alphaMatte)
        val again = EditJson.parse(EditJson.encode(project()).toString()).mainClips.single()
        assertEquals(c.alphaMatte, again.alphaMatte)
        assertNull(c.chroma)
    }

    @Test fun `the matte must be a video asset (the server's message)`() {
        assertNull(problemOf(project()))
        val p = problemOf(project(matteKind = "audio"))
        assertTrue(p!!.message!!.contains("alphaMatte.asset"))
        assertTrue(p.message!!.contains("must be a video asset"))
    }

    @Test fun `the matte follows the clip's source time through trims and speed`() {
        val c = PlannedClip("main", "c1", "src", startUs = 1_000_000, endUs = 4_000_000, clipStartUs = 2_000_000, clipEndUs = 8_000_000, speed = 2.0,
            isImage = false, withAudio = false, removeVideo = false, envelope = emptyList(), frameDropFps = null, look = null)
        assertEquals(2_000_000, c.sourceUsAt(1_000_000)) // the clip's first frame: its in point
        assertEquals(4_000_000, c.sourceUsAt(2_000_000)) // 1 s in at 2× → 2 s of source
        assertEquals(8_000_000, c.sourceUsAt(9_000_000)) // clamped to the out point
        val curve = c.copy(pieces = listOf(PlannedPiece(2_000_000, 4_000_000, 1.0), PlannedPiece(4_000_000, 8_000_000, 2.0)))
        assertEquals(3_000_000, curve.sourceUsAt(2_000_000)) // inside the first piece
        assertEquals(6_000_000, curve.sourceUsAt(4_000_000)) // 1 s into the second piece at 2×
    }
}
