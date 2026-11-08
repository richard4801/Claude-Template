package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** WS1's `muse.recipe/1`, read from the server's own fixture (server/api/test/fixtures/recipe-v1.json, copied as a resource). */
class RecipeTest {
    private val fixture = RecipeTest::class.java.getResource("/recipe-v1.json")!!.readText()

    @Test fun `reads a whole reference from the server's fixture`() {
        val ref = RecipeJson.reference(fixture)
        assertEquals("rx_example", ref.id)
        assertEquals("ready", ref.state)
        val r = ref.recipe!!
        assertEquals("Tuff edit", r.title)
        assertEquals(4.4, r.durationSec, 1e-9)
        assertEquals(3, r.slots.size)
        assertEquals(listOf(1.5, 2.667), r.cuts)
        assertEquals("Close-up", r.slots[1].shotSize)
        assertEquals("Eye level", r.slots[1].angle)
        assertEquals("Zoom in", r.slots[1].move)
        assertEquals("Pan", r.slots[0].move)
        assertNull(r.slots[0].brief) // no brief yet
        assertTrue(r.slots[1].brief!!.startsWith("She flips her hair in a studio"))
        assertEquals(listOf("Cut", "Crossfade", "Flash"), r.transitions.map { it.kind })
        assertEquals("SUMMER", r.texts.single().text)
        assertEquals("Lower third", r.texts.single().position)
        assertEquals("Teal & orange", r.grade!!.name)
        assertEquals(5, r.grade!!.swatches.size)
        assertEquals(120.1, r.beats!!.bpm!!, 1e-9)
        assertEquals("Original sound, 120 BPM", r.sound)
        assertTrue(r.gaps.isEmpty())
        assertEquals(listOf(false, true, false), r.slots.map { it.poseRead })
        assertEquals("Three beats: a pan, a push-in, a still with a caption.", r.summary)
    }

    @Test fun `an analysis in progress, a failure, and unknown transitions`() {
        val running = RecipeJson.reference("""{"id":"rx1","name":"Clip","state":"analyzing","progress":45,"phase":"Listening for the beat"}""")
        assertEquals("Listening for the beat", running.phase)
        assertNull(running.recipe)
        val failed = RecipeJson.reference("""{"id":"rx2","name":"Clip","state":"failed","error":"The analysis didn’t finish: bad file"}""")
        assertEquals("failed", failed.state)
        val r = RecipeJson.parse("""{"schema":"muse.recipe/1","source":{"durationSec":4},"slots":[{"id":"s1","startSec":0,"endSec":2,"confidence":0.5},{"id":"s2","startSec":2,"endSec":4}],
            "transitions":[{"atSec":2,"kind":"unknown","confidence":0.3}],"text":[{"id":"x1","startSec":0,"endSec":1,"words":null,"box":{"x":0,"y":0.05,"w":1,"h":0.1}}]}""")
        assertNull(r.transitions.single().kind)
        assertEquals("Top", r.texts.single().position)
        assertEquals(2, r.lowConfidence()) // the 0.5 slot and the unknown transition
    }

    @Test fun `pacing, beat sync and percentages`() {
        val r = RecipeJson.reference(fixture).recipe!!
        assertEquals(4.4 / 3, r.averageShotSec, 1e-9)
        assertEquals(2 * 60.0 / 4.4, r.cutsPerMinute, 1e-9)
        assertEquals("92%", RecipeConfidence.percent(.92))
        assertNull(r.copy(beats = null).cutsOnBeat())
    }

    @Test fun `a recipe without shots is refused`() {
        assertTrue(runCatching { RecipeJson.parse("""{"schema":"muse.recipe/1","slots":[]}""") }.isFailure)
    }
}
