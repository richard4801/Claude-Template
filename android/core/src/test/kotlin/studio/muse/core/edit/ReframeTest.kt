package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class ReframeTest {
    private val w = Reframe.coverWidth(1920, 1080, 1080, 1920) // a 16:9 take in a 9:16 edit

    @Test fun coverGeometry() {
        assertEquals((16.0 / 9) / (9.0 / 16), w, 1e-9) // ≈ 3.16 canvas widths
        assertEquals(0.5, Reframe.centreFor(0.5, w), 1e-9)
        // A face at the source's left third: the picture moves right to centre it.
        assertTrue(Reframe.centreFor(0.33, w) > 0.5)
        // Never so far that the canvas edge shows past the picture.
        val room = (w - 1) / 2
        assertEquals(0.5 + room, Reframe.centreFor(0.0, w), 1e-9); assertEquals(0.5 - room, Reframe.centreFor(1.0, w), 1e-9)
        assertEquals(1.0, Reframe.coverWidth(1080, 1920, 1080, 1920), 1e-9)
    }

    @Test fun followsAMovingFaceWithFewKeys() {
        val times = Reframe.sampleTimes(6.0)
        val samples = times.map { t -> Reframe.Sample(t, listOf(Reframe.Face(0.3 + 0.4 * t / 6, 0.4, 0.12, 0.2))) }
        val keys = Reframe.keyframes(samples, w)
        assertTrue("keys ${keys.size}", keys.size in 2..12)
        // Moving right across the source → the clip moves left on the canvas, and ends near the face's place.
        assertTrue(keys.first().v > keys.last().v)
        assertEquals(Reframe.centreFor(0.7, w), keys.last().v, 0.12)
        assertTrue(keys.zipWithNext().all { (a, b) -> b.t > a.t })
    }

    @Test fun smallHeadMovesDontPan() {
        val samples = Reframe.sampleTimes(5.0).map { t -> Reframe.Sample(t, listOf(Reframe.Face(0.5 + 0.004 * kotlin.math.sin(t * 9), 0.4, 0.15, 0.25))) }
        val keys = Reframe.keyframes(samples, w)
        assertEquals(1, keys.size) // one still position
        assertEquals(0.5, keys[0].v, 0.02)
    }

    @Test fun holdsThroughGapsAndStaysOnTheSamePerson() {
        val samples = Reframe.sampleTimes(4.0).map { t ->
            when {
                t in 1.0..2.0 -> Reframe.Sample(t, emptyList()) // looked away
                // A second, slightly bigger face appears on the other side; we stay with the first person.
                t > 2.0 -> Reframe.Sample(t, listOf(Reframe.Face(0.3, 0.4, 0.12, 0.2), Reframe.Face(0.8, 0.4, 0.14, 0.22)))
                else -> Reframe.Sample(t, listOf(Reframe.Face(0.3, 0.4, 0.12, 0.2)))
            }
        }
        val track = Reframe.track(samples)
        assertTrue(track.filterNotNull().all { abs(it - 0.3) < 1e-9 })
        val keys = Reframe.keyframes(samples, w)
        assertTrue(keys.all { abs(it.v - Reframe.centreFor(0.3, w)) < 0.06 })
    }

    @Test fun nothingToDo() {
        assertTrue(Reframe.keyframes(Reframe.sampleTimes(3.0).map { Reframe.Sample(it, emptyList()) }, w).isEmpty())
        assertTrue(Reframe.keyframes(listOf(Reframe.Sample(0.0, listOf(Reframe.Face(0.2, 0.5, 0.1, 0.1)))), 1.0).isEmpty())
    }
}
