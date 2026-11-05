package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakePromptLibrary
import studio.muse.app.data.ImageRef
import studio.muse.app.data.PromptPreviewRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.ShootDraft
import studio.muse.app.data.ShootRef
import studio.muse.app.data.ShootRequest
import studio.muse.core.PhotoPricing
import studio.muse.core.PromptEngine

/** Reference images in a photoshoot and the owner's prompt library, in demo mode (the server's rules, plans/api.md 2026-11-05). */
class ShootReferencesTest {
    private val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
    private fun ref(a: String, vararg g: String) = ShootRef(ImageRef.asset(a), g.toList())

    @Test fun draftBecomesTheServersShootRequest() {
        val d = ShootDraft(scene = "Café window", lens = 85, direction = "  ", presets = false, refs = listOf(ref("c_front", "pose")))
        val r = d.request(SampleData.DEMO, SampleData.GREEN)
        assertNull(r.prompt)
        assertNull(r.direction)
        assertEquals("Café window", r.scene)
        assertEquals(85, r.camera!!.lens)
        assertEquals(false, r.presets)
        assertEquals("Phone-natural", r.grade)
        assertEquals(1, r.refs!!.size)
        // Edit as text is sent exactly as written; a blank one isn't sent.
        assertEquals(" My words ", d.copy(promptText = " My words ").request("m", "o").prompt)
        assertNull(d.copy(promptText = "  ").request("m", "o").prompt)
        assertNull(ShootDraft().request("m", "o").refs)
        assertEquals("Rooftop · golden hour", ShootDraft().request("m", "o").scene)
        assertEquals(500, ShootDraft(direction = "x".repeat(900)).request("m", "o").direction!!.length)
    }

    @Test fun guidesStartOnTheFirstUnusedOneAndOneStaysOn() {
        assertEquals("pose", ShootRef.defaultGuide(emptyList()))
        assertEquals("look", ShootRef.defaultGuide(listOf(ref("c_front", "pose"))))
        assertEquals("scene", ShootRef.defaultGuide(listOf(ref("c_front", "pose", "look"))))
        assertEquals("pose", ShootRef.defaultGuide(listOf(ref("c_front", "pose", "look", "scene"))))
        val r = ref("c_front", "scene")
        assertEquals(listOf("pose", "scene"), r.toggled("pose")!!.guides)
        assertEquals(listOf("pose", "look", "scene"), r.toggled("pose")!!.toggled("look")!!.guides)
        assertNull(r.toggled("scene"))
        assertNull(ShootRef.problem(null))
        assertNull(ShootRef.problem(listOf(r)))
        assertEquals("Up to 3 reference images", ShootRef.problem(List(4) { r }))
        assertTrue(ShootRef.problem(listOf(ref("c_front")))!!.contains("at least one guide"))
        assertTrue(ShootRef.problem(listOf(ref("c_front", "outfit"))) != null)
        assertTrue(ShootRef.problem(listOf(ShootRef(ImageRef(), listOf("pose")))) != null)
        assertEquals("Image 7", studio.muse.app.data.ShootPreviewRef(7, listOf("pose")).badge)
        assertEquals("Not sent", studio.muse.app.data.ShootPreviewRef(null, listOf("pose"), dropped = true).badge)
    }

    @Test fun previewPlacesReferencesAfterHerOwnPhotosWithinEight(): Unit = runBlocking {
        val three = listOf(ref("c_front", "pose"), ref("c_tq", "look", "scene"), ref("c_face", "scene"))
        val p = api.previewShoot(ShootDraft(refs = three).request(SampleData.DEMO, SampleData.GREEN))
        assertEquals(8, p.images)
        assertEquals(listOf(6, 7, 8), p.refs.map { it.index })
        assertTrue(p.text.contains("Copy the pose and framing from image 6. Do not take the face, body, hair or clothes from image 6.\n"))
        assertTrue(p.text.contains("Copy the light, colour grade and camera feel from image 7. Use the place and background from image 7."))
        assertEquals(listOf("identity", "outfit", "scene", "camera", "light", "reference", "reference", "reference", "style", "negative", "seed"), p.slots.map { it.layer })
        assertTrue(p.estimateLabel.startsWith("about $"))
        // A model that takes 2 images: the face front and the first reference only.
        val two = FakePromptLibrary.shootPreview(FakeMuseApi.identity(SampleData.models().first()), "Green set", ShootDraft(refs = three).request("m", "o"), studio.muse.core.PhotoPrices(), maxInputs = 2)
        assertEquals(2, two.images)
        assertEquals(listOf(2, null, null), two.refs.map { it.index })
        assertTrue(two.refs.drop(1).all { it.dropped })
        // Presets off keeps her, the outfit, the direction, the references and the seed.
        val off = api.previewShoot(ShootDraft(presets = false, direction = "laughing", refs = three.take(1)).request(SampleData.DEMO, SampleData.GREEN))
        assertEquals(listOf("identity", "outfit", "direction", "reference", "seed"), off.slots.map { it.layer })
        // Edit as text: exactly the user's words.
        val mine = api.previewShoot(ShootDraft(promptText = "My own prompt").request(SampleData.DEMO, SampleData.GREEN))
        assertTrue(mine.edited); assertEquals("My own prompt", mine.text)
        val shot = api.shoot(ShootDraft(refs = three.take(1)).request(SampleData.DEMO, SampleData.GREEN, count = 1)).first()
        assertTrue(shot.prompt.contains("from image 7."))
        assertEquals(three.take(1), shot.refs)
        // More than 3, or a reference without a guide: bad_request, nothing charged.
        fun code(block: suspend () -> Unit) = try { runBlocking { block() }; null } catch (e: ApiException) { e.code }
        assertEquals("bad_request", code { api.previewShoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, refs = three + three.take(1))) })
        assertEquals(3, ShootDraft(refs = three + three.take(1)).request(SampleData.DEMO, SampleData.GREEN).refs!!.size)
        assertEquals("bad_request", code { api.shoot(ShootDraft(refs = listOf(ref("c_front"))).request(SampleData.DEMO, SampleData.GREEN)) })
    }

    @Test fun theShootCostsWhatThePreviewSays(): Unit = runBlocking {
        val req = ShootDraft(refs = listOf(ref("c_front", "pose"), ref("c_tq", "look"))).request(SampleData.DEMO, SampleData.GREEN, count = 2)
        val p = api.previewShoot(req)
        val plain = api.previewShoot(ShootDraft().request(SampleData.DEMO, SampleData.GREEN, count = 2))
        assertTrue("two more images cost more", p.estimate > plain.estimate)
        assertEquals(PhotoPricing.about(p.estimate), p.estimateLabel)
        val before = api.balance().balance
        val shots = api.shoot(req)
        assertEquals(2, shots.size)
        assertEquals(before - p.estimate, api.balance().balance, 1e-9)
    }

    @Test fun templateShootsTakeReferencesToo(): Unit = runBlocking {
        val tpl = api.listTemplates("all", null, null).first()
        val req = ShootRequest(SampleData.DEMO, SampleData.GREEN, templateId = tpl.id, shuffleSeed = 3, refs = listOf(ref("c_front", "pose", "scene")))
        val p = api.previewShoot(req)
        assertEquals(listOf(7), p.refs.map { it.index })
        val refLine = p.slots.single { it.layer == "reference" }
        assertEquals("Copy the pose and framing from image 7. Use the place and background from image 7. Do not take the face, body, hair or clothes from image 7.", refLine.text)
        // After the direction, before style / never-add / seed.
        val layers = p.slots.map { it.layer }
        assertTrue(layers.toString(), layers.indexOf("reference") < layers.indexOf("negative") && layers.indexOf("reference") < layers.indexOf("seed"))
        val shot = api.shoot(req.copy(count = 1)).first()
        assertTrue(shot.prompt, shot.prompt.contains("Use the place and background from image 7."))
        assertEquals(req.refs, shot.refs)
        // Without references: no reference line, the plain template estimate.
        assertTrue(api.previewShoot(req.copy(refs = null)).slots.none { it.layer == "reference" })
    }

    @Test fun theDemoPreviewUsesTheStudiosPromptLibrary(): Unit = runBlocking {
        val req = ShootDraft(refs = listOf(ref("c_front", "look"))).request(SampleData.DEMO, SampleData.GREEN)
        val before = api.previewShoot(req).text
        assertTrue(before.contains("Style: ${PromptEngine.HOUSE_STYLE}."))
        api.savePrompt("style.house", "HOUSE X")
        api.savePrompt("refs.look", "Match the colours of image {refIndex}.")
        api.savePrompt("never.base", "logos, stickers")
        val after = api.previewShoot(req)
        assertTrue(after.text, after.text.contains("Style: HOUSE X."))
        assertEquals("Match the colours of image 7. Do not take the face, body, hair or clothes from image 7.", after.slots.single { it.layer == "reference" }.text)
        assertTrue(after.text, after.text.contains("Never add: ") && after.text.contains("logos, stickers.") && !after.text.contains("warped jewellery"))
        // The editor's preview: this entry with sample values, and the whole prompt it's part of.
        val pv = api.previewPrompt(PromptPreviewRequest("refs.pose", "Pose like image {refIndex}."))
        assertEquals("Pose like image 8.", pv.text)
        assertTrue(pv.example, pv.example.startsWith("Demo model: ") && pv.example.contains("Pose like image 8. Match the colours of image 8."))
        assertTrue(api.previewPrompt(PromptPreviewRequest("shoot.scene", "Somewhere: {scene}.")).example.contains("\nSomewhere: rooftop · golden hour.\n"))
        // Defaults again: the same text as the app's own engine.
        listOf("style.house", "refs.look", "never.base").forEach { api.resetPrompt(it) }
        assertEquals(FakePromptLibrary.shootPreview(FakeMuseApi.identity(SampleData.models().first()), "Green set", req, studio.muse.core.PhotoPrices()).text,
            api.previewShoot(req).text)
    }

    @Test fun promptLibraryRulesMatchTheServer(): Unit = runBlocking {
        val lib = api.prompts()
        assertEquals(FakePromptLibrary.DEFAULTS.prompts.size, lib.prompts.size)
        assertTrue(lib.prompts.size >= 52)
        assertEquals(listOf("Photoshoot", "References", "Character sheet", "Outfits", "Enhance", "Dress up", "Templates", "Video", "LoRA"), lib.groups.map { it.label })
        val pose = lib.prompts.first { it.key == "refs.pose" }
        assertEquals("Copy the pose and framing from image {refIndex}.", pose.current)
        assertTrue(pose.placeholders.single().required)
        fun code(block: suspend () -> Unit) = try { runBlocking { block() }; null } catch (e: ApiException) { e.code to e.message }
        assertEquals("prompt_invalid" to "Keep {refIndex} · this prompt needs it", code { api.savePrompt("refs.pose", "Copy the pose.") })
        assertEquals("prompt_invalid" to "Unknown placeholder {where} · this prompt can use {scene}", code { api.savePrompt("shoot.scene", "At {where}.") })
        assertEquals("not_found", code { api.savePrompt("nope", "x") }?.first)
        val saved = api.savePrompt("shoot.scene", "Location: {scene}!")
        assertTrue(saved.overridden); assertEquals("Location: {scene}!", saved.current)
        assertEquals("Location: rooftop · golden hour!", api.previewPrompt(PromptPreviewRequest("shoot.scene")).text)
        assertFalse(api.resetPrompt("shoot.scene").overridden)
        assertFalse(api.savePrompt("style.house", lib.prompts.first { it.key == "style.house" }.default).overridden)
    }
}
