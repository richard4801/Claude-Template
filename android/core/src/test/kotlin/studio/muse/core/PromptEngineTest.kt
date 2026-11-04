package studio.muse.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PromptEngineTest {
    private val sienna = Identity(
        name = "Sienna Vale",
        look = "young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin",
        neverAdd = listOf("tattoos", "rings"),
    )
    private val outfits = listOf("Green set", "Crystal dress")

    private fun JsonObject.str(k: String) = this[k]?.jsonPrimitive?.content

    /** The photoshoot prompt must equal what prototype/app/app.js buildPrompt('shoot') produces. */
    @Test fun photoshootMatchesThePrototype() {
        val cases = Json.parseToJsonElement(javaClass.getResource("/prompt_fixture.json")!!.readText()).jsonArray
        for (c in cases) {
            val input = c.jsonObject["input"]!!.jsonObject
            val spec = ShootSpec(
                identity = sienna,
                outfit = OutfitSpec(outfits[input["outfit"]!!.jsonPrimitive.int]),
                scene = input.str("scene"),
                camera = CameraSpec(input.str("shot")!!, input["lens"]!!.jsonPrimitive.int, input.str("aperture")!!),
                light = input.str("light")!!,
                grade = input.str("grade"),
                direction = input.str("direction"),
                lockSeed = input["lockSeed"]?.jsonPrimitive?.booleanOrNull ?: false,
            )
            val built = PromptEngine.photoshoot(spec)
            assertEquals(c.jsonObject.str("text"), built.text)
            val parts = c.jsonObject["parts"]!!.jsonObject
            for (layer in listOf(Layer.IDENTITY, Layer.OUTFIT, Layer.SCENE, Layer.CAMERA, Layer.LIGHT, Layer.DIRECTION, Layer.STYLE, Layer.NEGATIVE, Layer.SEED)) {
                val expected = parts.str(layer.key).orEmpty()
                assertEquals(layer.key, expected, built[layer].orEmpty())
            }
        }
    }

    @Test fun emptySlotsAreDropped() {
        val p = PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Green set"), direction = "   "))
        assertNull(p[Layer.DIRECTION])
        assertFalse(p.text.contains("Direction"))
        assertFalse(p.text.contains("\n\n"))
    }

    @Test fun slotBodyStripsTheLabelLikeThePrototype() {
        val p = PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Green set")))
        assertTrue(p.slots.first().body.startsWith("young woman, long wavy"))
        assertEquals("medium shot, 35mm lens, f/2.8.", p.slots.first { it.layer == Layer.CAMERA }.body)
    }

    @Test fun lensAwareWording() {
        fun cam(mm: Int) = PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Green set"), camera = CameraSpec("Close", mm, "f/1.4")))[Layer.CAMERA]!!
        assertTrue(cam(16).endsWith("slight wide-angle distortion."))
        assertTrue(cam(85).endsWith("compressed background, creamy bokeh."))
        assertEquals("Camera: close shot, 50mm lens, f/1.4.", cam(50))
    }

    @Test fun directionCannotAddNeverAddItems() {
        val (clean, removed) = PromptEngine.sanitizeDirection("laughing mid-step, wearing a gold ring, holding an iced coffee", sienna)
        assertEquals("laughing mid-step, holding an iced coffee", clean)
        assertEquals(listOf("wearing a gold ring"), removed)
        val p = PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Green set"), direction = "small tattoo on her wrist, smiling"))
        assertEquals("Direction: smiling", p[Layer.DIRECTION])
        assertEquals(listOf("small tattoo on her wrist"), p.removed)
    }

    @Test fun directionCannotOverrideIdentity() {
        val (clean, removed) = PromptEngine.sanitizeDirection("blonde hair turned platinum, blue eyes, hair blowing in the wind", sienna)
        assertEquals("hair blowing in the wind", clean)
        assertEquals(2, removed.size)
    }

    @Test fun neverListMergesGlobalDefaultsWithoutDuplicates() {
        val id = sienna.copy(neverAdd = listOf("tattoos", "Logos", "chokers"))
        assertEquals(listOf("tattoos", "Logos", "chokers", "extra fingers", "warped jewellery"), PromptEngine.neverList(id))
    }

    @Test fun outfitSetUsesOneSeedForAllFourAngles() {
        val set = PromptEngine.outfitSet(sienna, OutfitSpec("Cream knit + jeans", "Cream cable-knit sweater, light-wash straight jeans, white sneakers", OutfitSource.DESCRIBED))
        assertEquals(4, set.size)
        assertEquals(1, set.map { it.seed }.toSet().size)
        assertTrue(set[0][Layer.OUTFIT]!!.startsWith("Wearing: Cream cable-knit sweater"))
        assertTrue(set[3][Layer.TASK]!!.contains("back view"))
        assertTrue(set[0][Layer.NEGATIVE]!!.contains("visible brand logos"))
    }

    @Test fun characterSheetShotHasTaskAndNoScene() {
        val p = PromptEngine.characterSheetShot(sienna, SheetAngle.FACE_PROFILE)
        assertEquals(listOf(Layer.IDENTITY, Layer.TASK, Layer.STYLE, Layer.NEGATIVE), p.slots.map { it.layer })
        assertTrue(p[Layer.TASK]!!.contains("plain light-grey studio background"))
        assertTrue(p[Layer.TASK]!!.contains("side profile"))
    }

    @Test fun videoSwapUsesTheStructuredH3FormatAndRemovesPerformerTattoos() {
        val v = PromptEngine.videoSwap(
            VideoSwapSpec(sienna, OutfitSpec("Green set"), SourcePerformer("the young woman with long red hair", tattoos = true, rings = true, setting = "a living room")),
        )
        val t = v.text
        assertTrue(t.startsWith("subject_definitions:\n<Subject 1> is the young woman with long red hair with tattoos and rings in <Video 1>"))
        listOf("summary:", "retention_analysis:", "detailed_description:").forEach { assertTrue(it, t.contains("\n\n$it\n")) }
        assertTrue(t.contains("None of <Subject 1>'s tattoos remain."))
        assertTrue(t.contains("None of <Subject 1>'s rings remain."))
        assertTrue(t.contains("<Audio 1>: fully_copy"))
        assertTrue(t.contains("<Image 6> (body, back)"))
        assertEquals("fully_copy", v.audioMode)
        assertEquals(10, v.steps)
    }

    @Test fun videoSwapWithoutAudioOrBackground() {
        val v = PromptEngine.videoSwap(VideoSwapSpec(sienna.copy(referenceCount = 3), OutfitSpec("Crystal dress"), keepAudio = false, keepBackground = false, backgroundMotion = "subtly alive"))
        assertFalse(v.text.contains("<Audio 1> is the synchronized"))
        assertTrue(v.text.contains("<Audio 1>: replaced"))
        assertTrue(v.text.contains("(subtly alive)"))
        assertTrue(v.text.contains("<Image 1>-<Image 3>"))
        assertEquals("replace", v.audioMode)
    }

    @Test fun lockLookGivesAStableSeed() {
        val a = PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Green set"), lockSeed = true))
        val b = PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Crystal dress"), lockSeed = true))
        assertEquals(a.seed, b.seed)
        assertNull(PromptEngine.photoshoot(ShootSpec(sienna, OutfitSpec("Green set"))).seed)
    }
}
