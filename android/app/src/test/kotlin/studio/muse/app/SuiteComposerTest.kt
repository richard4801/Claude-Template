package studio.muse.app

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.suite.composer.Caret
import studio.muse.app.ui.screens.suite.composer.ComposerCatalog
import studio.muse.app.ui.screens.suite.composer.ComposerChip
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.PromptPart
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.composerRequest

/** The video composer's pure rules (AI suite, workstream 1): chip summaries, the catalogue's visible lists, prompt tokens. */
class SuiteComposerTest {
    private val cat: CameraCatalog = FakeSuite().camera
    private fun move(id: String) = cat.moves.first { it.id == id }

    @Test fun `the demo catalogue is the server's composer catalogue`() {
        assertEquals(listOf("Phone", "Creator camera", "Cinema camera", "35mm film", "16mm film", "Super 8", "Large format 65mm", "DV camcorder", "Webcam", "CCTV"),
            ComposerCatalog.visible(cat.bodies).map { it.label })
        assertEquals(9, ComposerCatalog.visible(cat.lenses).size)
        assertEquals(listOf(14, 24, 35, 50, 85, 135), ComposerCatalog.focalSteps(cat))
        assertEquals(listOf("f1.4", "f2.8", "f5.6", "f11"), ComposerCatalog.visible(cat.apertures).map { it.id })
        assertTrue(ComposerCatalog.visible(cat.frameRates).isEmpty())
        assertEquals("cinema_digital", cat.bodies.first { it.id == "super35" }.mergedInto)
        assertTrue(cat.palettes.all { it.swatches.size == 5 && it.lut != null })
        assertEquals("special", move("motion_blur").group)
        assertEquals("Featured", cat.moveGroups.first().label)
    }

    @Test fun `a chip shows only the non-Auto values, through merges, cut with an ellipsis`() {
        val s0 = ComposerSettings()
        assertEquals(listOf("Auto", "Auto", "Auto", "Auto"), ComposerCatalog.summaries(s0, cat).drop(1).map { it.value })
        assertEquals("0/9", ComposerCatalog.summary(ComposerChip.REFERENCES, s0, cat, 0, 9).value)
        val s = s0.copy(body = "film_35", lens = "anamorphic")
        assertEquals("Camera · 35mm film, Anamorphic", ComposerCatalog.summary(ComposerChip.CAMERA, s, cat).text())
        // A merged id shows as its survivor.
        assertEquals("Cinema camera", ComposerCatalog.summary(ComposerChip.CAMERA, s0.copy(body = "super35"), cat).value)
        val long = s.copy(focalMm = 50, aperture = "f1.4", height = "low", shotSize = "mcu")
        val t = ComposerCatalog.summary(ComposerChip.CAMERA, long, cat).text(32)
        assertTrue(t.length <= 32)
        assertTrue(t.endsWith("…"))
        assertEquals("Look · Teal & orange", ComposerCatalog.summary(ComposerChip.LOOK, s0.copy(palette = "teal_orange"), cat).text())
        assertTrue(long.isSet(ComposerChip.CAMERA))
        assertFalse(long.reset(ComposerChip.CAMERA).isSet(ComposerChip.CAMERA))
    }

    @Test fun `a preset fills the chips with visible values`() {
        val s = ComposerSettings().fromPreset(cat, "phone_ugc")
        assertEquals("phone", s.body)
        assertEquals(24, s.focalMm) // 26 mm → nearest visible step
        assertEquals("f11", s.aperture) // f/8 → f/11
        assertEquals("phone_ugc", s.preset)
        assertEquals("warm_vintage", ComposerSettings().fromPreset(cat, "documentary").lens) // vintage → merged survivor
    }

    @Test fun `the camera spec carries only non-Auto values and the moves`() {
        assertNull(ComposerSettings().cameraJson())
        var p = PromptTokens().withText("She smiles ")
        p = p.addMove(move("dolly_in")).first.addMove(move("rack_focus")).first
        val j = ComposerSettings(body = "film_35", palette = "teal_orange").cameraJson(p.moves)!!
        assertEquals("film_35", j["rig"]!!.jsonObject["body"]!!.jsonPrimitive.content)
        assertEquals("dolly_in", j["move"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals("rack_focus", j["mix"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertNull(j["angle"])
    }

    @Test fun `at most two moves, only pairs the server can mix`() {
        var p = PromptTokens().withText("Walks in")
        p = p.addMove(move("dolly_in")).first
        val (same, why) = p.addMove(move("dolly_out"))
        assertEquals(p, same)
        assertEquals("Dolly out reveal can't be combined with Dolly in", why)
        p = p.addMove(move("rack_focus")).first
        assertEquals(2, p.moves.size)
        assertEquals("Up to 2 moves · remove one first", p.addMove(move("pan_left")).second)
        assertNotNull(PromptTokens().addMove(move("static")).first.addMove(move("dolly_in")).second) // static is solo
    }

    @Test fun `mentions, removal, reordering and the text the server gets`() {
        var p = PromptTokens().withText("walks into the café, then smiles.")
        p = p.addMention("character", "m_maya", "Maya", Caret(0, 0)).first
        assertEquals("@Mayawalks into the café, then smiles.", p.display())
        p = PromptTokens().withText(" walks into the café, then smiles.").addMention("character", "m_maya", "Maya", Caret(0, 0)).first
        assertEquals("Pick a character first", PromptTokens().addMention("outfit", "o1", "Green set").second)
        p = p.addMention("outfit", "o_green", "Green set").first
        p = p.addMove(move("dolly_in"), Caret(1, 9)).first // inside the text: " walks in|to the café…"
        assertEquals("@Maya walks in#Dolly into the café, then smiles.@Green set", p.display())
        assertEquals("Maya walks in to the café, then smiles. Green set", p.promptText())
        val (r, msg) = p.addMention("character", "m_ivy", "Ivy")
        assertEquals("Maya replaced by Ivy", msg)
        assertEquals("m_ivy", r.character?.id)
        // Removing the character takes the outfit with it; texts join up again.
        val noChar = p.remove(p.character!!.key)
        assertNull(noChar.character)
        assertNull(noChar.outfit)
        assertTrue(noChar.parts.zipWithNext().none { (a, b) -> a is PromptPart.Text && b is PromptPart.Text })
        val mv = p.moves.single()
        assertEquals(0, p.reorder(mv.key, 0).parts.indexOfFirst { it.key == mv.key })
        assertEquals(80, p.setIntensity(mv.key, 80).moves.single().intensity)
    }

    @Test fun `the trigger being typed`() {
        assertEquals('#', PromptTokens.activeTrigger("She walks #dol", 14)?.char)
        assertEquals("dol", PromptTokens.activeTrigger("She walks #dol", 14)?.query)
        assertEquals("Ma", PromptTokens.activeTrigger("@Ma", 3)?.query)
        assertNull(PromptTokens.activeTrigger("email me@home", 13))
        assertNull(PromptTokens.activeTrigger("#dolly in", 9))
        assertEquals("dolly_in", PromptTokens.searchMoves(cat, "dolly").first().id)
    }

    @Test fun `the request, and the Look demo mode reports`() {
        val p = PromptTokens().withText(" waves").addMention("character", "m_maya", "Maya", Caret(0, 0)).first
        val r = composerRequest(p, ComposerSettings(palette = "hyper_neon"), quality = "hd")
        assertEquals("m_maya", r.modelId)
        assertEquals("Maya waves", r.prompt)
        assertNull(r.gradeLook)
        assertEquals(false, composerRequest(p, ComposerSettings(palette = "hyper_neon", gradeLook = false)).gradeLook)
        val fake = FakeSuite()
        assertEquals("palette:hyper_neon", fake.lookFor(r)?.lut)
        assertEquals("pack:cine-noir", fake.lookFor(SuiteShotRequest(camera = Json.parseToJsonElement("""{"preset":"noir"}""") as JsonObject))?.lut)
        assertNull(fake.lookFor(r.copy(gradeLook = false)))
    }
}
