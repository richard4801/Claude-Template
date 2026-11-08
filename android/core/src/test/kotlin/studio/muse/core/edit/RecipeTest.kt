package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecipeTest {
    private val json = """
        {"version":1,"title":"Café trend","durationSec":8.0,"future":"ignored",
         "slots":[{"startSec":0,"endSec":2.0,"shotSize":"Close-up","confidence":0.9},
                  {"startSec":2.0,"endSec":5.0,"move":"Push in","confidence":0.5,"extra":{"x":1}},
                  {"startSec":5.0,"endSec":8.0}],
         "texts":[{"startSec":0,"endSec":2,"text":"POV","position":"Top"},{"startSec":1,"endSec":2}],
         "transitions":[{"atSec":2.0,"kind":"Whip","confidence":0.8},{"atSec":5.0}],
         "grade":{"name":"Warm film","swatches":["#1a1a1a","#f0e0c0"],"confidence":0.4},
         "beats":{"bpm":120,"beats":[0.5,1.0,1.5,2.02,2.5,4.0],"strong":[2.02]}}
    """.trimIndent()

    @Test fun `reads the plan's fields leniently`() {
        val r = RecipeJson.parse(json)
        assertEquals(3, r.slots.size)
        assertEquals("Push in", r.slots[1].move)
        assertEquals(1.0, r.slots[2].confidence, 0.0) // missing → certain
        assertEquals(1, r.texts.size) // a text without words is dropped
        assertEquals(2, r.transitions.size); assertNull(r.transitions[1].kind) // a kind that couldn't be told stays null
        assertEquals(listOf(2.0, 5.0), r.cuts)
        assertEquals(120.0, r.beats!!.bpm!!, 0.0)
    }

    @Test fun `pacing, beat sync and what to check`() {
        val r = RecipeJson.parse(json)
        assertEquals(8.0 / 3, r.averageShotSec, 1e-9)
        assertEquals(15.0, r.cutsPerMinute, 1e-9)
        assertEquals(0.5, r.cutsOnBeat()!!, 1e-9) // 2.0 is 0.02 from a beat; 5.0 is 1 s off
        assertEquals(3, r.lowConfidence()) // the 0.5 slot, the 0.4 grade and the unknown transition
        assertEquals("92%", RecipeConfidence.percent(.92))
        assertNull(r.copy(beats = null).cutsOnBeat())
    }

    @Test fun `a recipe without shots is refused`() {
        assertTrue(runCatching { RecipeJson.parse("""{"slots":[]}""") }.isFailure)
    }
}
