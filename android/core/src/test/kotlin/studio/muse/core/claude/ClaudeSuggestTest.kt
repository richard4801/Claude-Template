package studio.muse.core.claude

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Live chips on Android (the Mac's ClaudeSuggestTests): the query, the server's answer, the steady order.
class ClaudeSuggestTest {
    private fun c(l: String) = ClaudeChip(l, l, "x")

    @Test fun queryIsSortedAndPlain() {
        val q = ClaudeSuggestQuery("suite", "shot", mapOf("assistId" to "sa_1", "modelId" to "m1", "takeId" to "bad id!"), "ct_1")
        assertEquals("assistId=sa_1&chatId=ct_1&page=suite&tool=shot", q.queryString())
    }

    @Test fun parsesTheServersChips() {
        val l = ClaudeSuggest.parse(Json.parseToJsonElement("""{"chips":[{"id":"suite.fill","label":"Build from my idea","prompt":"Fill in…","icon":"sliders-horizontal","why":"x"},{"label":""},7],"key":"suite.fill"}"""))
        assertEquals(listOf("Build from my idea"), l.map { it.label })
        assertEquals("sliders-horizontal", l[0].icon)
        assertTrue(ClaudeSuggest.parse(Json.parseToJsonElement("""{"nope":1}""")).isEmpty())
    }

    @Test fun steadyKeepsChipsInTheirPlaces() {
        val old = listOf(c("A"), c("B"), c("C"))
        assertEquals(listOf("D", "B", "C"), ClaudeSuggest.steady(old, listOf(c("B"), c("D"), c("C"))).map { it.label })
        assertEquals(listOf("A", "B", "C"), ClaudeSuggest.steady(old, listOf(c("C"), c("B"), c("A"))).map { it.label })
        assertEquals(listOf("X", "Y"), ClaudeSuggest.steady(emptyList(), listOf(c("X"), c("Y"))).map { it.label })
        assertEquals(listOf("Z"), ClaudeSuggest.steady(old, listOf(c("Z"))).map { it.label })
    }
}
