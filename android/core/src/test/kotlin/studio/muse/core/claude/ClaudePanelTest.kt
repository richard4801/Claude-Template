package studio.muse.core.claude

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The Claude panel's pure parts on Android, matching the Mac's ClaudeCardsTests / ClaudeOrbTests / ClaudeContextTests.
class ClaudePanelTest {
    private fun j(s: String): JsonElement = Json.parseToJsonElement(s)

    @Test fun cardsDecodeAndUnknownOnesAreSkipped() {
        val plan = ClaudeCard.parse(j("""{"kind":"plan","planId":"swap","title":"Plan: outfit swap","steps":[{"text":"Watch","done":true},{"text":"Swap"}]}""")) as ClaudeCard.Plan
        assertEquals(1, plan.done); assertEquals(2, plan.steps.size)
        val media = ClaudeCard.parse(j("""{"kind":"media","durationSec":15,"video":{"id":"tk","kind":"take","url":"/uploads/a.mp4"},"moments":[{"from":4,"to":10,"label":"Face"},{"from":11,"label":"End"}]}""")) as ClaudeCard.Media
        assertEquals(listOf("0:04–0:10", "0:11"), media.moments.map { it.timecode })
        assertEquals("Clip analysis", media.title)
        val ch = ClaudeCard.parse(j("""{"kind":"changes","rows":[{"what":"Outfit","to":"Hoodie","undoable":true},{"what":"Background","to":"Describe it","undone":true}]}""")) as ClaudeCard.Changes
        assertEquals(listOf(true, false), ch.rows.map { it.undoable }); assertEquals("Outfit changed to Hoodie", CardText.change(ch.rows[0]))
        val ap = ClaudeCard.parse(j("""{"kind":"approve","title":"Generate · 15 s · $1.17","lines":[{"label":"Video","usd":0.99},{"label":"Pictures","usd":0.18}],"totalUsd":1.17,"answer":{"assistId":"sa","pendingId":"sp"}}""")) as ClaudeCard.Approve
        assertEquals(ApproveTarget.Suite("sa", "sp"), ap.target); assertEquals("$1.17", CardText.money(CardText.total(ap.lines, null)))
        assertNull(ClaudeCard.parse(j("""{"kind":"poll"}""")))
        assertNull(ClaudeCard.parse(j("""{"kind":"approve","title":"no answer"}""")))
        assertEquals("1:02:05", CardText.clock(3725.0))
    }

    @Test fun orbStatesFollowEventsErrorFirstAndReduceMotionStills() {
        val o = ClaudeOrb()
        assertEquals(OrbState.IDLE, o.state(0.0))
        o.waiting(1); assertEquals(OrbState.WAITING, o.state(0.0))
        o.turnStarted(); assertEquals(OrbState.THINKING, o.state(1.0))
        o.uiCallBegan("u", 2.0); assertEquals(OrbState.OPERATING, o.state(2.0))
        o.uiCallEnded("u", now = 3.0); o.turnEnded(false, 4.0)
        assertEquals(OrbState.ERROR, o.state(5.0))
        assertEquals(OrbState.WAITING, o.state(4.0 + ClaudeOrb.ERROR_HOLD + 0.1))
        o.chunk(20.0); assertEquals(1.0, o.pulse(20.0), 1e-9); assertEquals(0.0, o.pulse(20.0 + ClaudeOrb.FLASH_DECAY), 1e-9)
        val u = o.uniforms(20.0); assertTrue(u.pop > 0.02); assertEquals(0.05, u.wobble, 1e-9)
        val still = o.uniforms(20.0, reduceMotion = true); assertEquals(0.0, still.wobble, 0.0); assertEquals(0.0, still.pop, 0.0)
        assertEquals(0, o.frameRate(20.0, reduceMotion = true)); assertEquals(30, o.frameRate(20.0))
        for (s in OrbState.values()) assertTrue(ClaudeOrb.uniforms(s, ClaudeOrb.look(s), 1.0, 1.0).wobble <= 0.05)
        assertTrue(ClaudeOrb.look(OrbState.ERROR).swirl < ClaudeOrb.look(OrbState.IDLE).swirl)
        assertEquals(5.0 + 0.25 * 2.7, ClaudeOrb.advance(5.0, 1.0, ClaudeOrb.look(OrbState.THINKING)), 1e-9)
    }

    @Test fun contextStripReadsTheScreenClaudeGets() {
        val screen = j("""{"tool":"remix","request":{"modelId":"m1","outfitId":"of1","engineModel":"seedance-2","remix":{"background":{"mode":"describe","words":"a beach at dusk"}}},
            "settings":{"modelLabel":"Seedance 2.0 · Higgsfield"},
            "inputs":[{"slot":"remix.clip","kind":"video","label":"Walk.mp4","clipId":"c1"},{"slot":"remix.outfit","kind":"image","label":"Hoodie","url":"/u/p.jpg"},
                      {"slot":"reference 1","kind":"image","role":"style","url":"/u/r.jpg"},{"slot":"guide","kind":"video","label":"Blender guide"}]}""")
        val items = ClaudeContext.items(screen, ContextLookups(character = { "Ava" to "/u/face.jpg" }, outfit = { "Hoodie" to null }, clipPoster = { "/u/poster.jpg" }))
        assertEquals(listOf("Clip", "Her", "Outfit", "Background", "Product", "Style", "Guide", "Model"), items.map { it.label })
        assertEquals("/u/poster.jpg", items[0].image); assertEquals("a beach at dusk", items[3].words); assertEquals("Seedance 2.0 · Higgsfield", items.last().detail)
        assertTrue(ClaudeContext.items(null).isEmpty())
        assertEquals(listOf("Watch my clip", "Write the prompt", "Check the price"), ClaudeChip.fallback("suite", "remix").map { it.label })
        val a = ClaudeActivity(); a.step("Opening Swap…"); a.step("Setting outfit…"); a.progress = 0.42
        assertEquals("Opening Swap… setting outfit…", a.line); assertEquals("42%", a.percent)
    }
}
