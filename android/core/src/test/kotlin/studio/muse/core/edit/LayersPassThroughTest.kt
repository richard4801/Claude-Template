package studio.muse.core.edit

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Layers (plans/layers-edit.md, Phase 1) are made on the Mac and the server; Android doesn't draw them yet, but a project
 * saved from Android keeps them exactly (layers, layerBase, layerSource on clips, pin on text): the shared layers.json.
 */
class LayersPassThroughTest {
    private val raw = (Fixtures.load("layers.json") as JsonObject)["project"]!!

    @Test fun `a project with layers saves back unchanged`() {
        val p = EditJson.parse(raw)
        Fixtures.assertJson("layers project", raw, EditJson.encode(p))
        val again = EditJson.encode(EditJson.parse(EditJson.encode(p).toString()))
        Fixtures.assertJson("twice", raw, again)
    }

    @Test fun `reverse and steadying drop the layers (their frames no longer line up)`() {
        val c = EditJson.parse(raw).mainClips.first()
        val back = raw.jsonObject["tracks"]!!.jsonArray[0].jsonObject["items"]!!.jsonArray[0].jsonObject
        assertEquals(back["layers"], c.layers)
        val r = reverseClip(c, "rev", 10.0)!!
        assertNull(r.layers); assertNull(r.layerBase); assertNull(r.layerSource)
        assertNull(deriveClip(c, "st", DerivedOp.STABILIZE).layers)
        assertEquals(c.layers, deriveClip(c, "st", null).layers)
    }
}
