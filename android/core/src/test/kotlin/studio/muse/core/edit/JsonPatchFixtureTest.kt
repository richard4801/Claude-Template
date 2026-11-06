package studio.muse.core.edit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Edit sessions (workstream 3): the JSON Patch port against the shared fixture (byte copy of the server's). */
class JsonPatchFixtureTest {
    private val cases = (Fixtures.load("jsonpatch.json") as JsonArray).map { it.jsonObject }

    @Test fun diffGivesTheFixturePatchesExactly() {
        assertTrue(cases.size >= 11)
        for (c in cases) {
            val name = (c["name"] as JsonPrimitive).content
            val patch = JsonPatch.diff(c["a"]!!, c["b"]!!)
            assertTrue("$name patch", JsonPatch.jsonEqual(c["patch"], JsonPatch.encode(patch)))
            assertEquals("$name patch order", (c["patch"] as JsonArray).map { ((it as JsonObject)["path"] as JsonPrimitive).content }, patch.map { it.path })
            assertTrue("$name inverse", JsonPatch.jsonEqual(c["inverse"], JsonPatch.encode(JsonPatch.diff(c["b"]!!, c["a"]!!))))
        }
    }

    @Test fun applyAndInverseRoundTrip() {
        for (c in cases) {
            val name = (c["name"] as JsonPrimitive).content
            assertTrue("$name apply", JsonPatch.jsonEqual(JsonPatch.apply(c["a"]!!, PatchOp.listOf(c["patch"])), c["b"]))
            assertTrue("$name inverse", JsonPatch.jsonEqual(JsonPatch.apply(c["b"]!!, PatchOp.listOf(c["inverse"])), c["a"]))
        }
    }

    @Test fun badPathsAndEqualityRules() {
        val doc = buildJsonObject { put("l", JsonArray(listOf(JsonPrimitive(1)))) }
        assertThrows(PatchException::class.java) { JsonPatch.apply(doc, listOf(PatchOp("replace", "/nope", JsonPrimitive(1)))) }
        assertThrows(PatchException::class.java) { JsonPatch.apply(doc, listOf(PatchOp("remove", "/l/1"))) }
        assertThrows(PatchException::class.java) { JsonPatch.apply(doc, listOf(PatchOp("remove", ""))) }
        val added = JsonPatch.apply(doc, listOf(PatchOp("add", "/l/-", JsonPrimitive(2))))
        assertEquals(2, (added.jsonObject["l"] as JsonArray).size)
        assertEquals(1, (doc.jsonObject["l"] as JsonArray).size) // the input is never changed
        assertTrue(JsonPatch.jsonEqual(JsonPrimitive(1), JsonPrimitive(1.0)))
        assertFalse(JsonPatch.jsonEqual(JsonPrimitive(1), JsonPrimitive("1")))
        // Keys sort by UTF-16 code units (uppercase before lowercase), like JS.
        val a = buildJsonObject { }
        val b = buildJsonObject { put("b", JsonPrimitive(1)); put("B", JsonPrimitive(1)); put("a", JsonPrimitive(1)) }
        assertEquals(listOf("/B", "/a", "/b"), JsonPatch.diff(a, b).map { it.path })
    }
}
