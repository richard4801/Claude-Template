package studio.muse.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoEditTest {
    private val ten = VideoEdit.untouched(10.0)
    private fun near(e: Double, a: Double) = assertEquals(e, a, 1e-9)

    @Test fun untouchedPlaysTheWholeSource() {
        near(10.0, ten.outputSec)
        assertTrue(ten.isUntouched)
        assertNull(ten.problem())
    }

    @Test fun splitThenDeleteCutsOutTheMiddle() {
        val e = ten.split(3.0)!!.split(4.0)!!
        assertEquals(listOf(EditSegment(0.0, 3.0), EditSegment(3.0, 4.0), EditSegment(4.0, 10.0)), e.segments)
        val cut = e.delete(1)!!
        assertEquals(listOf(EditSegment(0.0, 3.0), EditSegment(4.0, 10.0)), cut.segments)
        near(9.0, cut.outputSec)
        assertNull(cut.segmentAt(3.5)) // the cut part
        assertEquals(1, cut.segmentAt(4.0))
        near(3.0, cut.outputAt(3.5)) // a cut maps to the next kept part
        assertFalse(cut.isUntouched)
    }

    @Test fun splitRules() {
        assertNull("too close to the start", ten.split(0.05))
        assertNull("too close to the end", ten.split(9.95))
        assertNull("in a cut", ten.split(3.0)!!.split(4.0)!!.delete(1)!!.split(3.5))
        assertNotNull(ten.split(0.1))
        var e = ten
        repeat(EditRules.MAX_SEGMENTS - 1) { e = e.split(0.15 * (it + 1))!! }
        assertEquals(EditRules.MAX_SEGMENTS, e.segments.size)
        assertNull("at most 50 parts", e.split(9.0))
    }

    @Test fun splitKeepsSpeedAndMute() {
        val e = ten.speed(null, 2.0)!!.muteSegment(0, true)!!.split(4.0)!!
        assertEquals(listOf(EditSegment(0.0, 4.0, 2.0, true), EditSegment(4.0, 10.0, 2.0, true)), e.segments)
    }

    @Test fun deleteRules() {
        assertNull("the last part can't go", ten.delete(0))
        assertNull(ten.split(5.0)!!.delete(5))
        // Deleting so the output gets shorter than 0.5 s is refused.
        val tiny = VideoEdit(1.0, listOf(EditSegment(0.0, 0.3), EditSegment(0.3, 0.6)))
        assertNull(tiny.delete(0))
    }

    @Test fun speedAndOutputDurationMath() {
        val e = ten.split(2.0)!!.split(4.0)!!.speed(1, 0.5)!!
        near(2.0 + 4.0 + 6.0, e.outputSec) // the slow-motion middle doubles
        val fast = ten.speed(null, 2.0)!!
        near(5.0, fast.outputSec)
        near(10.0 / 1.5, ten.speed(null, 1.5)!!.outputSec)
        near(10.0 / 0.75, ten.speed(0, 0.75)!!.outputSec)
        near(8.0, ten.speed(0, 1.25)!!.outputSec)
        assertNull("no change", ten.speed(0, 1.0))
        // Output ↔ source mapping across speeds.
        near(2.0, e.outputAt(2.0))
        near(4.0, e.outputAt(3.0)) // 1 s of source at 0.5× = 2 s
        near(6.0, e.outputAt(4.0))
        assertEquals(1 to 3.0, e.sourceAt(4.0))
        assertEquals(2 to 5.0, e.sourceAt(7.0))
        assertEquals(2 to 10.0, e.sourceAt(99.0))
    }

    @Test(expected = IllegalArgumentException::class)
    fun onlyTheSixSpeeds() { ten.speed(null, 3.0) }

    @Test fun trimHandlesClamp() {
        val e = ten.trimStart(0.5)!!.trimEnd(9.8)!!
        near(0.5, e.trimIn); near(9.8, e.trimOut); near(9.3, e.outputSec)
        near(9.5, ten.trimStart(20.0)!!.trimIn) // the output keeps at least 0.5 s
        near(4.9, ten.split(5.0)!!.trimStart(20.0)!!.trimIn) // other parts keep it long enough: 0.1 s minimum
        near(10.0, e.trimEnd(50.0)!!.trimOut)
        assertNull(ten.trimStart(-3.0)) // already at 0: no change
        val split = ten.split(5.0)!!.trimStart(3.0)!!
        assertEquals(EditSegment(3.0, 5.0), split.segments[0])
    }

    @Test fun muteWholeAndPerSegment() {
        val e = ten.split(5.0)!!.muteSegment(1, true)!!
        assertFalse(e.silent(0)); assertTrue(e.silent(1))
        val all = e.muteAll(true)!!
        assertTrue(all.silent(0))
        assertNull(all.muteAll(true))
    }

    @Test fun undoRedoReset() {
        val h = EditHistory(ten)
        assertFalse(h.canUndo)
        assertTrue(h.apply(h.current.split(3.0)))
        assertTrue(h.apply(h.current.delete(0)))
        assertFalse("refused change is not recorded", h.apply(h.current.delete(0)))
        assertEquals(1, h.current.segments.size)
        assertTrue(h.undo()); assertEquals(2, h.current.segments.size)
        assertTrue(h.undo()); assertEquals(ten, h.current)
        assertFalse(h.undo())
        assertTrue(h.redo()); assertTrue(h.redo()); assertFalse(h.redo())
        near(7.0, h.current.outputSec)
        assertTrue(h.reset()); assertEquals(ten, h.current)
        assertTrue("reset can be undone", h.undo()); near(7.0, h.current.outputSec)
        // A new change clears redo.
        h.undo(); assertTrue(h.canRedo); h.apply(h.current.muteAll(true)); assertFalse(h.canRedo)
    }

    @Test fun historyIsCapped() {
        val h = EditHistory(ten, limit = 3)
        listOf(1.0, 2.0, 3.0, 4.0, 5.0).forEach { h.apply(h.current.split(it)) }
        var n = 0
        while (h.undo()) n++
        assertEquals(3, n)
    }

    @Test fun validationMatchesTheServer() {
        assertNull(ten.split(3.0)!!.speed(0, 0.5)!!.problem())
        assertEquals("Parts overlap", VideoEdit(10.0, listOf(EditSegment(0.0, 5.0), EditSegment(4.0, 6.0))).problem())
        assertEquals("Speed 3.0 isn't allowed", VideoEdit(10.0, listOf(EditSegment(0.0, 5.0, 3.0))).problem())
        assertEquals("Part 1 is too short", VideoEdit(10.0, listOf(EditSegment(0.0, 0.05), EditSegment(1.0, 3.0))).problem())
        assertEquals("Part 1 is outside the video", VideoEdit(10.0, listOf(EditSegment(0.0, 10.2))).problem())
        assertEquals("The edit must be at least 0.5 s", VideoEdit(10.0, listOf(EditSegment(0.0, 0.6, 2.0))).problem())
    }

    @Test fun framesAndLabels() {
        near(10.0 / 30, EditRules.snap(0.34, 30.0))
        val s = VideoEdit(10.0, listOf(EditSegment(0.31, 9.99))).snapped(30.0)
        near(9.0 / 30, s.segments[0].inSec); near(10.0, s.segments[0].outSec)
        assertEquals("0:03.40", EditRules.time(3.4))
        assertEquals("1:05.00", EditRules.time(65.0))
        assertEquals("0.75×", EditRules.speedLabel(0.75))
        assertEquals(listOf(1.0, 3.0, 5.0, 7.0, 9.0), stripTimes(10.0, 5))
    }
}
