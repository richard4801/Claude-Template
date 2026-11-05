package studio.muse.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Since 2026-11-05 the SERVER builds the photoshoot prompt from the owner's prompt library. The app's own engine is only
 * the demo/offline fallback; it must still match what the server builds with the default library
 * (shoot_prompt_fixture.json, written by server/api/scripts/gen-shoot-fixture.ts): Presets on/off and reference lines.
 */
class ShootPromptFixtureTest {
    private fun JsonObject.str(k: String) = this[k]?.jsonPrimitive?.content

    @Test fun fallbackMatchesTheServer() {
        val fx = Json.parseToJsonElement(javaClass.getResource("/shoot_prompt_fixture.json")!!.readText()).jsonObject
        val idj = fx["identity"]!!.jsonObject
        val id = Identity(idj.str("name")!!, idj.str("look")!!, idj["referenceCount"]!!.jsonPrimitive.int, idj["neverAdd"]!!.jsonArray.map { it.jsonPrimitive.content })
        val rows = fx["rows"]!!.jsonArray
        assertEquals(6, rows.size)
        for (row in rows) {
            val i = row.jsonObject["input"]!!.jsonObject
            val refs = i["refs"]?.jsonArray?.map { r -> SentRef(r.jsonObject["index"]!!.jsonPrimitive.int, r.jsonObject["guides"]!!.jsonArray.map { it.jsonPrimitive.content }) }.orEmpty()
            val spec = ShootSpec(
                identity = id, outfit = OutfitSpec(i.str("outfit")!!), scene = i.str("scene"),
                camera = CameraSpec(i.str("shot")!!, i["lens"]!!.jsonPrimitive.int, i.str("aperture")!!),
                light = i.str("light") ?: "Golden hour", grade = i.str("grade"), direction = i.str("direction"),
                lockSeed = i["lockSeed"]?.jsonPrimitive?.booleanOrNull ?: false, presets = i["presets"]?.jsonPrimitive?.booleanOrNull ?: true, refs = refs,
            )
            val p = PromptEngine.photoshoot(spec)
            assertEquals(row.jsonObject.str("text"), p.text)
            assertEquals(row.jsonObject["slots"]!!.jsonArray.map { it.jsonObject.str("layer") }, p.slots.map { it.layer.key })
            assertEquals(row.jsonObject["seed"]?.jsonPrimitive?.longOrNull, p.seed)
        }
    }
}
