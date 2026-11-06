package studio.muse.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.core.RigDrumMath as M

class RigDrumMathTest {
    @Test fun loopsFromFiveItems() { assertFalse(M.loops(4)); assertTrue(M.loops(5)) }

    @Test fun wrapHandlesNegatives() {
        assertEquals(5, M.wrap(-1, 6)); assertEquals(0, M.wrap(6, 6)); assertEquals(2, M.wrap(-10, 6))
    }

    @Test fun deltaTakesTheShortWayRoundTheSeam() {
        assertEquals(1.0, M.delta(0, 5.0, 6, loop = true), 1e-9)
        assertEquals(-1.0, M.delta(5, 0.0, 6, loop = true), 1e-9)
        assertEquals(-5.0, M.delta(0, 5.0, 6, loop = false), 1e-9)
        assertEquals(0.5, M.delta(0, 11.5, 6, loop = true), 1e-9) // unwrapped position after a long fling
    }

    @Test fun halvesRoundUpOnBothPlatforms() { assertEquals(3.0, M.roundHalfUp(2.5), 0.0); assertEquals(-2.0, M.roundHalfUp(-2.5), 0.0) }

    @Test fun nearestClampsOrWraps() {
        assertEquals(0, M.nearest(-0.4, 4, loop = false)); assertEquals(3, M.nearest(3.5, 4, loop = false))
        assertEquals(0, M.nearest(6.2, 6, loop = true)); assertEquals(5, M.nearest(-1.0, 6, loop = true))
    }

    @Test fun rubberBandIsCappedAtBothEnds() {
        assertEquals(-0.35, M.clampSoft(-1.0, 4, false), 1e-9)
        assertEquals(-0.6, M.clampSoft(-10.0, 4, false), 1e-9)
        assertEquals(3.6, M.clampSoft(20.0, 4, false), 1e-9)
        assertEquals(1.5, M.clampSoft(1.5, 4, false), 1e-9)
        assertEquals(-10.0, M.clampSoft(-10.0, 6, true), 1e-9)
    }

    @Test fun flingLandsOnADetent() {
        assertEquals(3.0, M.flingTarget(1.0, 6.0, 4, loop = false), 1e-9)   // 1 + 1.95 → 3, the last item
        assertEquals(0.0, M.flingTarget(1.0, -20.0, 4, loop = false), 1e-9)
        assertEquals(-5.0, M.flingTarget(1.0, -20.0, 8, loop = true), 1e-9) // 1 - 6.5 = -5.5 rounds half up
        assertEquals(M.flingTarget(2.2, 0.0, 8, true), 2.0, 1e-9)
    }

    @Test fun decayRunsFromStartToTarget() {
        assertEquals(1.0, M.decay(1.0, 4.0, 0.0), 1e-9)
        assertEquals(4.0, M.decay(1.0, 4.0, 10.0), 1e-6)
    }

    @Test fun springSettlesWithoutOvershoot() {
        var x = 1.0; var v = 0.0; var t = 0.0
        while (!M.settled(x, v) && t < 3) { val (nx, nv) = M.springStep(x, v, 1 / 60.0); x = nx; v = nv; t += 1 / 60.0; assertTrue("overshot at $t", x >= -1e-6) }
        assertTrue("settled in $t s", t < 1.5)
    }

    @Test fun lookFallsOffSymmetrically() {
        val c = M.look(0.0, 64.0, selected = true)
        assertTrue(c.visible); assertEquals(1.0, c.scale, 1e-9); assertEquals(1.0, c.alpha, 1e-9); assertEquals(0.0, c.y, 1e-9)
        val up = M.look(-1.0, 64.0, false); val down = M.look(1.0, 64.0, false)
        assertEquals(-up.y, down.y, 1e-9); assertEquals(up.scale, down.scale, 1e-9)
        assertEquals(64.0 * Math.cos(Math.toRadians(10.5)), down.y, 1e-6) // neighbours sit about one row apart
        assertTrue(down.alpha < 1 && down.brightness < 1)
        assertFalse(M.look(5.0, 64.0, false).visible)
    }
}
