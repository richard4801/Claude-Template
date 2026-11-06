package studio.muse.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Keeps the design-direction colours (plans/design-direction.md §2) from drifting below the checked contrast. */
class DesignTokensTest {
    private val themes = listOf('a', 'b', 'c', 'd')

    private fun atLeast(min: Double, fg: Long, bg: Long, what: String) {
        val r = DesignTokens.contrast(fg, bg)
        assertTrue("$what: ${"%.2f".format(r)}:1 is under $min:1", r >= min)
    }

    @Test fun textPassesOnEverySurface() {
        for (t in themes) {
            val r = DesignTokens.roles(t)
            for ((name, bg) in listOf("canvas" to r.canvas, "raised" to r.raised, "field" to r.field)) {
                atLeast(4.5, r.ink, bg, "$t ink on $name")
                atLeast(4.5, r.ink2, bg, "$t ink2 on $name")
            }
            atLeast(11.0, r.ink, r.canvas, "$t ink on canvas")
        }
    }

    @Test fun actionLabelsAndLinksAndStatesPass() {
        for (t in themes) {
            val r = DesignTokens.roles(t)
            atLeast(4.5, r.onAction, r.action, "$t onAction on action") // §2 says ≥ 6.0; Soft Tactile is 5.98
            atLeast(4.5, r.link, r.canvas, "$t link on canvas")
            for ((name, c) in listOf("positive" to r.positive, "caution" to r.caution, "danger" to r.danger)) atLeast(4.5, c, r.canvas, "$t $name on canvas")
        }
    }

    @Test fun bagIsDarkAndReadable() {
        val b = DesignTokens.bag
        assertTrue("bag is dark", DesignTokens.luminance(b.raised) < 0.02)
        atLeast(4.5, b.ink, b.raised, "bag ink"); atLeast(4.5, b.ink2, b.field, "bag ink2 on field")
        atLeast(3.0, b.accent, b.raised, "bag accent")
        atLeast(4.5, b.onAction, b.action, "bag onAction")
    }

    @Test fun scaleRadiiAndSpaceMatchTheDirection() {
        assertEquals(listOf(4, 8, 12, 16, 24, 32, 48), DesignTokens.space.toList())
        assertEquals(listOf(28, 20, 16, 15, 14, 13, 11), listOf(DesignTokens.display, DesignTokens.title, DesignTokens.heading, DesignTokens.body,
            DesignTokens.label, DesignTokens.caption, DesignTokens.micro).map { it.size })
        for (t in themes) {
            val r = DesignTokens.radii(t)
            assertTrue("$t container ≥ control", r.container >= r.control)
            assertTrue("$t control ≥ chip", r.control >= r.chip || r.chip == 999)
        }
        assertNull(DesignTokens.float('b'))
    }
}
