package studio.muse.core

import org.junit.Assert.assertEquals
import org.junit.Test

/** The outfit page's paging (plans/outfit-head-looks.md §4). */
class OutfitPagesTest {
    private data class O(val id: String, val at: Long)
    private fun list(n: Int) = OutfitPages.newestFirst((0 until n).map { O("o$it", 1000L + it) }) { it.at }

    @Test fun pagesAndLabel() {
        assertEquals(1, OutfitPages.count(0))
        assertEquals(1, OutfitPages.count(8))
        assertEquals(2, OutfitPages.count(9))
        assertEquals("1 of 3", OutfitPages.label(0, 17))
        assertEquals("3 of 3", OutfitPages.label(9, 17))
    }

    @Test fun newestFirstAndSlices() {
        val l = list(17)
        assertEquals("o16", l.first().id)
        assertEquals((16 downTo 9).map { "o$it" }, OutfitPages.slice(l, 0).map { it.id })
        assertEquals(listOf("o0"), OutfitPages.slice(l, 2).map { it.id })
    }

    @Test fun deleteRefillsAndStepsBack() {
        val l = list(9).filterNot { it.id == "o5" }
        assertEquals(8, OutfitPages.slice(l, 0).size)
        assertEquals("o0", OutfitPages.slice(l, 0).last().id)
        assertEquals(0, OutfitPages.clamp(1, l.size))
    }
}
