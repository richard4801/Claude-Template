package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.ImageRef
import studio.muse.app.data.PhotoEstimate
import studio.muse.app.data.PhotoRequest
import studio.muse.app.data.PhotoRules
import studio.muse.app.data.SampleData
import studio.muse.app.data.ShootRef
import studio.muse.app.data.ShootRequest
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.composer.ComposerChip
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerPrice
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PhotoComposer
import studio.muse.app.ui.screens.suite.composer.PhotoDraft
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.ToolSlots
import studio.muse.app.ui.screens.suite.composer.cameraTabs

/**
 * The Photo tool (workstream 3, plans/video-composer.md "Photo tool"): Photoshoot on the composer. The request built from the
 * composer (the rig for a still, no movement or tempo, the preset), the estimate's wire shape, demo mode's estimate and run,
 * the catalog's `photo` tool, the redirect of Photoshoot's old route and the outfit set generator's link.
 */
class SuitePhotoTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private val cat: CameraCatalog = FakeSuite().camera
    private fun ref(a: String, vararg g: String) = ShootRef(ImageRef.asset(a), g.toList())

    private fun draft(settings: ComposerSettings = ComposerSettings(), moves: List<String> = emptyList(), text: String = "Laughing on a rooftop at golden hour "): ComposerDraft {
        var t = PromptTokens().withText(text)
        moves.forEach { id -> t = t.addMove(cat.move(id)!!, t.caretAtEnd, 70).first }
        return ComposerDraft(tool = ComposerTool.PHOTO, tokens = t, settings = settings, modelId = SampleData.DEMO, outfitId = SampleData.GREEN)
    }

    // ---------------------------------------------------------------- the tool on the shell

    @Test fun `Photo is a live tool with its own card, chips and sentence-case slots`() {
        val t = ComposerTool.of("photo")
        assertEquals(ComposerTool.PHOTO, t)
        assertEquals("Photo", t.title)
        assertEquals("Stills of your character", t.tagline)
        assertTrue(t.live)
        assertEquals(listOf(ComposerChip.STYLE, ComposerChip.CAMERA, ComposerChip.LOOK, ComposerChip.LIGHTING), t.chips)
        assertFalse("no # moves on a still", t.placeholder.contains("#"))
        val slots = ToolSlots.of(ComposerTool.PHOTO, studio.muse.app.data.SuiteInputs.NONE, studio.muse.app.ui.screens.suite.InputSlots())
        assertEquals(listOf("Character", "Outfit", "Product", "References"), slots.map { it.label })
        assertEquals(listOf(true, true, true, true), slots.map { it.optional }) // a character OR an image (owner 2026-11-11)
        // Camera: Setup and Angle only (no Movement, no Directed even for the owner); Style: no Tempo.
        val tabs = cameraTabs(ComposerSettings(), owner = true, directed = false).filter { it.key in PhotoComposer.CAMERA_TABS }
        assertEquals(listOf("setup", "angle"), tabs.map { it.key })
        assertEquals(setOf("genre", "era"), PhotoComposer.STYLE_TABS)
        // Generate needs a character, an image or words (owner 2026-11-11); a preset still needs a character.
        assertNull(draft().copy(modelId = null).problem(studio.muse.app.ui.screens.suite.InputSlots(), studio.muse.app.ui.screens.suite.RecastDraft()))
        val noOne = draft(text = "").copy(modelId = null)
        val img = listOf(ShootRef(ImageRef.asset("a"), listOf("look")))
        assertEquals("Describe the photo or add an image", PhotoComposer.problem(noOne, PhotoDraft()))
        assertNull(PhotoComposer.request(noOne, PhotoDraft()))
        val wordsOnly = draft().copy(modelId = null) // words alone: text-to-image
        assertNull(PhotoComposer.problem(wordsOnly, PhotoDraft()))
        val w = PhotoComposer.request(wordsOnly, PhotoDraft())!!
        assertNull(w.modelId)
        assertNull(w.references)
        assertNull(PhotoComposer.problem(noOne, PhotoDraft(refs = img)))
        assertEquals("Presets need a character · pick one with @", PhotoComposer.problem(noOne, PhotoDraft(presetId = "t", refs = img)))
        val free = PhotoComposer.request(noOne, PhotoDraft(refs = img, product = ImageRef.asset("p")))!!
        assertNull(free.modelId)
        assertNull(free.outfitId)
        assertNull(free.productImage)
        assertNull(PhotoComposer.request(noOne, PhotoDraft(presetId = "t", refs = img)))
        assertEquals("Waiting for the upload", PhotoComposer.problem(draft(), PhotoDraft(uploading = "ref")))
        assertEquals("Making the photos…", PhotoComposer.problem(draft(), PhotoDraft(), busy = true))
        assertNull(PhotoComposer.problem(draft(), PhotoDraft()))
    }

    // ---------------------------------------------------------------- the request

    @Test fun `the rig maps to a still's camera, with movement and tempo dropped`() {
        val pal = cat.palettes.first { it.visible }.id
        val light = cat.lighting.first { it.visible }.id
        val s = ComposerSettings(body = "cinema_digital", lens = "anamorphic", focalMm = 85, aperture = "f2.8", height = "low", shotSize = "cu",
            genre = cat.genres.first().id, era = cat.eras.first().id, tempo = "slow_motion", palette = pal, stock = cat.looks.first().id, lighting = light)
        val d = draft(s, moves = listOf("dolly_in", "orbit_left"))
        val r = PhotoComposer.request(d, PhotoDraft(count = 2))!!
        assertEquals(SampleData.DEMO, r.modelId)
        assertEquals(SampleData.GREEN, r.outfitId)
        assertEquals(2, r.count)
        assertNull(r.presetId)
        val cam = r.camera!!.jsonObject
        assertNull("no move", cam["move"]); assertNull("no mix", cam["mix"])
        val rig = cam["rig"]!!.jsonObject
        assertEquals("cinema_digital", (rig["body"] as JsonPrimitive).content)
        assertEquals("anamorphic", (rig["lens"] as JsonPrimitive).content)
        assertEquals("85", (rig["focalMm"] as JsonPrimitive).content)
        assertEquals("f2.8", (rig["aperture"] as JsonPrimitive).content)
        assertEquals(cat.looks.first().id, (rig["look"] as JsonPrimitive).content)
        assertEquals("low", (cam["angle"]!!.jsonObject["height"] as JsonPrimitive).content)
        assertEquals("cu", (cam["angle"]!!.jsonObject["shotSize"] as JsonPrimitive).content)
        val style = cam["style"]!!.jsonObject
        assertNull("no tempo on a still", style["tempo"])
        assertEquals(cat.genres.first().id, (style["genre"] as JsonPrimitive).content)
        assertEquals(pal, (cam["palette"]!!.jsonObject["preset"] as JsonPrimitive).content)
        assertEquals(light, (cam["lighting"]!!.jsonObject["preset"] as JsonPrimitive).content)
        // The prompt has the words only: #move tokens never reach a photo.
        assertEquals("Laughing on a rooftop at golden hour", r.prompt)
        cat.moves.forEach { m -> assertFalse(r.prompt.contains(m.label)) }
        // Everything Auto and no moves: no camera at all; grading off is sent only with a look to grade.
        assertNull(PhotoComposer.request(draft(moves = listOf("dolly_in")), PhotoDraft())!!.camera)
        assertEquals(false, PhotoComposer.request(draft(ComposerSettings(palette = pal, gradeLook = false)), PhotoDraft())!!.gradeLook)
        assertNull(PhotoComposer.request(draft(ComposerSettings(gradeLook = false)), PhotoDraft())!!.gradeLook)
        // No character, no image and no words: no request (words alone are enough, owner 2026-11-11).
        assertNull(PhotoComposer.request(draft(text = "").copy(modelId = null), PhotoDraft()))
    }

    @Test fun `a preset sends presetId and its own camera, the product and the references go as they are`() {
        val refs = listOf(ref("c_front", "pose"), ref("c_tq", "look", "scene"), ref("g_side", "scene"), ref("face", "pose"))
        val d = draft(ComposerSettings(body = "phone", lighting = cat.lighting.first().id))
        val r = PhotoComposer.request(d, PhotoDraft(count = 3, presetId = "tpl_mirror-selfie", refs = refs, product = ImageRef.asset("hero")))!!
        assertEquals("tpl_mirror-selfie", r.presetId)
        assertNull("the preset carries its own camera and light", r.camera)
        assertEquals(3, r.references!!.size)
        assertEquals(listOf("look", "scene"), r.references!![1].guides)
        assertEquals(ImageRef.asset("hero"), r.productImage)
        assertNull(PhotoComposer.request(d, PhotoDraft())!!.references)
        // An @character in the prompt wins over the slot.
        val t = PromptTokens().withText("On the steps ").addMention("character", SampleData.NOOR, "Noor").first
        assertEquals(SampleData.NOOR, PhotoComposer.request(d.copy(tokens = t), PhotoDraft())!!.modelId)
    }

    // ---------------------------------------------------------------- the Photo tab (owner 2026-11-14)

    @Test fun `the size is sent only when picked, and the estimate's shapes and model decode`() {
        val d = draft()
        assertNull(PhotoComposer.request(d, PhotoDraft())!!.aspect)
        assertEquals("9:16", PhotoDraft().shownAspect)
        assertEquals("4:5", PhotoComposer.request(d, PhotoDraft(aspect = "4:5"))!!.aspect)
        val o = json.encodeToJsonElement(PhotoRequest.serializer(), PhotoComposer.request(d, PhotoDraft())!!).jsonObject
        assertFalse("9:16 is the server's default: an older server never sees aspect", "aspect" in o.keys)
        assertEquals(listOf("9:16", "4:5", "3:4", "2:3", "1:1", "3:2", "4:3", "16:9"), PhotoRules.ASPECTS) // server PHOTO_ASPECTS
        val body = """{"count":2,"perPhoto":0.1,"aspect":"4:5","makes":"3:4","aspects":[{"id":"9:16","makes":"9:16"},{"id":"4:5","makes":"3:4"},{"id":"1:1","makes":null}],
            "model":{"id":"black-forest-labs/flux-2-pro","name":"FLUX.2 [pro]","auto":true}}"""
        val e = json.decodeFromString(PhotoEstimate.serializer(), body)
        assertEquals(listOf("9:16", "4:5 · makes 3:4", "1:1 · model's size"), e.aspects.map { it.label })
        assertEquals("FLUX.2 [pro]", e.model?.name)
        val old = json.decodeFromString(PhotoEstimate.serializer(), """{"count":2,"perPhoto":0.1}""")
        assertTrue(old.aspects.isEmpty())
        assertNull(old.model)
        assertFalse(ComposerTool.PHOTO.placeholder.contains("she"))
    }

    @Test fun `demo mode's estimate lists the shapes and names Auto's model`(): Unit = runBlocking {
        val api = FakeMuseApi(kotlinx.coroutines.MainScope(), null, speed = 0.0, genDelayMs = 0)
        val e = api.photoEstimate(PhotoComposer.request(draft(), PhotoDraft(aspect = "1:1"))!!)
        assertEquals("1:1", e.aspect)
        assertEquals(PhotoRules.ASPECTS, e.aspects.map { it.id })
        assertEquals(true, e.model?.auto)
        assertTrue(e.model?.name?.isNotBlank() == true)
    }

    @Test fun `the request's JSON carries only fields the strict server knows`() {
        val r = PhotoComposer.request(draft(ComposerSettings(body = "phone"), moves = listOf("dolly_in")), PhotoDraft(presetId = null, refs = listOf(ref("c_front", "pose"))))!!
        val o = json.encodeToJsonElement(PhotoRequest.serializer(), r).jsonObject
        val allowed = setOf("modelId", "outfitId", "prompt", "camera", "gradeLook", "count", "presetId", "productImage", "references", "seed", "lockSeed", "shuffleSeed", "title", "draft")
        assertTrue(o.keys.toString(), allowed.containsAll(o.keys))
        assertEquals(setOf("modelId", "outfitId", "prompt", "camera", "count", "references", "draft"), o.keys) // draft: Reuse settings
        assertEquals(setOf("image", "guides"), (o["references"] as kotlinx.serialization.json.JsonArray)[0].jsonObject.keys)
    }

    // ---------------------------------------------------------------- the estimate

    @Test fun `the estimate decodes and drives the Generate button and the rig row`() {
        val body = """{"tool":"photo","count":4,"perPhoto":0.1161,"estimate":0.4644,"priceLine":"about $0.46 · 4 photos","buttonLabel":"Generate · 4 photos · $0.46",
            "ok":true,"warnings":["Movement doesn’t apply to photos"],"rig":[{"id":"deep_focus","severity":"warn","reason":"Phone keeps everything in focus, so the f/1.4 blur won’t show",
            "fix":{"label":"Use Cinema camera","patch":{"camera":{"rig":{"body":"cinema_digital"}}}},"alt":{"label":"f/11","patch":{"camera":{"rig":{"aperture":"f11"}}}}}],
            "look":{"id":"teal_orange","kind":"palette","label":"Teal & orange","lut":"pack:teal_orange"},"prompt":"Demo: …","futureField":1}"""
        val e = json.decodeFromString(PhotoEstimate.serializer(), body)
        assertEquals(4, e.count); assertEquals(.4644, e.estimate, 1e-9); assertEquals(.1161, e.perPhoto, 1e-9)
        assertEquals("deep_focus", e.rig.single().id); assertEquals("f/11", e.rig.single().alt!!.label)
        assertEquals("pack:teal_orange", e.look!!.lut)
        assertNull(e.preset)
        val s = PhotoComposer.asEstimate(e)
        assertEquals("Generate · 4 photos · $0.46", ComposerPrice.button(s))
        assertEquals("$0.46", ComposerPrice.short(s))
        assertEquals("about $0.46 · 4 photos", ComposerPrice.line(s))
        assertEquals(e.rig, s.rig)
        // A preset run: the preset instead of the prompt. Missing fields default.
        val p = json.decodeFromString(PhotoEstimate.serializer(), """{"count":1,"estimate":0.12,"preset":{"id":"tpl_a","name":"Mirror selfie"}}""")
        assertEquals("Mirror selfie", p.preset!!.name); assertTrue(p.rig.isEmpty()); assertTrue(p.ok)
        assertEquals("Generate · 1 photo · $0.12", ComposerPrice.button(PhotoComposer.asEstimate(p)))
        // Members: no prompt and no model words.
        val m = PhotoComposer.memberSafe(e.copy(warnings = e.warnings + "Ran on flux kling"))
        assertNull(m.prompt); assertEquals(listOf("Movement doesn’t apply to photos"), m.warnings)
        assertEquals(listOf("1 photo", "2 photos", "3 photos", "4 photos"), PhotoComposer.countItems(4).map { it.first })
        assertEquals(listOf(false, false, false, true), PhotoComposer.countItems(4).map { it.second })
    }

    @Test fun `demo mode prices a photo like its shoot preview and keeps the still rules only`(): Unit = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val refs = listOf(ref("c_front", "pose"))
        val d = draft(ComposerSettings(body = "phone", aperture = "f1.4", focalMm = 14, shotSize = "cu", tempo = "slow_motion"), moves = listOf("orbit_left"))
        val req = PhotoComposer.request(d, PhotoDraft(count = 2, refs = refs))!!
        // The camera as the composer would send it for a video, so the demo sees the move and tempo and drops them with a note.
        assertNull("the composer never sends tempo on a still", req.camera!!.jsonObject["style"])
        val withMoves = req.copy(camera = JsonObject(req.camera!!.jsonObject + ("move" to json.parseToJsonElement("""{"id":"orbit_left"}""")) +
            ("style" to json.parseToJsonElement("""{"tempo":"slow_motion"}"""))))
        val e = api.photoEstimate(withMoves)
        val shoot = api.previewShoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, scene = req.prompt, count = 2, refs = refs))
        assertEquals(shoot.estimate, e.estimate, 1e-9)
        assertEquals(e.estimate / 2, e.perPhoto, 1e-9)
        assertEquals("Generate · 2 photos · ${studio.muse.core.Pricing.money(e.estimate)}", e.buttonLabel)
        assertTrue(e.priceLine.endsWith(" · 2 photos"))
        assertEquals(listOf(PhotoRules.NO_MOVEMENT, PhotoRules.NO_TEMPO), e.warnings)
        assertEquals(listOf("deep_focus", "wide_close"), e.rig.map { it.id })
        assertTrue(e.rig.all { it.id in PhotoRules.STILL_RULES })
        // A preset: its own camera and light (a note when chips were set), no prompt back.
        val tpl = api.listTemplates("all", null, null).first()
        val p = api.photoEstimate(req.copy(presetId = tpl.id))
        assertEquals(tpl.name, p.preset!!.name); assertNull(p.prompt)
        assertTrue(PhotoRules.PRESET_RIG in p.warnings)
        // Bad requests.
        fun code(block: suspend () -> Unit) = try { runBlocking { block() }; null } catch (x: ApiException) { x.code }
        assertEquals("bad_request", code { api.photoEstimate(req.copy(count = 5)) })
        assertEquals("bad_request", code { api.photoEstimate(req.copy(references = List(4) { ref("c_front", "pose") })) })
        assertEquals("not_found", code { api.photoEstimate(req.copy(modelId = "nobody")) })
    }

    @Test fun `demo Generate makes Photo takes in the library, charged as estimated, and old shoots stay`(): Unit = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val old = api.shoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, scene = "Café window", count = 1)).single()
        val req = PhotoComposer.request(draft(), PhotoDraft(count = 3))!!
        val e = api.photoEstimate(req)
        val before = api.balance().balance
        val r = api.createPhotos(req)
        assertEquals("photo", r.tool)
        assertEquals(3, r.takes.size)
        assertTrue(r.takes.all { it.kind == "shot" && it.title.startsWith("Photo · ") })
        assertEquals(before - e.estimate, api.balance().balance, 1e-9)
        val library = api.listTakes()
        assertTrue(library.any { it.id == old.id && it.title.startsWith("Photo · ") })
        assertTrue(r.takes.all { t -> library.any { it.id == t.id } })
        // The composer's recent strip lists both, newest first.
        assertTrue(PhotoComposer.recent(library).map { it.id }.containsAll(r.takes.map { it.id } + old.id))
    }

    @Test fun `the catalog's tools include photo`(): Unit = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val c = api.suiteCatalog()
        assertNotNull(c.tools!!.firstOrNull { it.id == "photo" })
        assertTrue(ComposerTool.PHOTO.isLive(c))
        assertTrue(ComposerTool.PHOTO.isLive(c.copy(tools = c.tools!!.filter { it.id != "photo" } + studio.muse.app.data.SuiteToolInfo("photo", true))))
        assertFalse(ComposerTool.PHOTO.isLive(c.copy(tools = c.tools!!.map { if (it.id == "photo") it.copy(available = false) else it })))
    }

    // ---------------------------------------------------------------- links

    @Test fun `Photoshoot's old route redirects to Suite, Photo`() {
        assertEquals("suite/compose/photo", Routes.SUITE_PHOTO)
        assertEquals(Routes.SUITE_PHOTO, Routes.redirect(Routes.SHOOT))
        assertEquals(Routes.SUITE_PHOTO, Routes.redirect("shoot/outfit"))
        assertEquals(Routes.SUITE_PHOTO, Routes.redirect("shoot?tool=outfit"))
        listOf(Routes.HOME, Routes.GALLERY, "shooting", Routes.result("s_1"), Routes.TEMPLATES, Routes.SUITE_SHOT).forEach { assertEquals(it, Routes.redirect(it)) }
    }

    @Test fun `the outfit set generator's link opens Photo with that character and outfit`() {
        val t = PromptTokens().withText("At the café ").addMention("character", SampleData.NOOR, "Noor").first
        val from = ComposerDraft(tool = ComposerTool.SHOT, tokens = t, modelId = SampleData.NOOR, settings = ComposerSettings(preset = "cinematic", body = "phone"))
        val d = PhotoComposer.open(from, SampleData.DEMO, SampleData.GREEN)
        assertEquals(ComposerTool.PHOTO, d.tool)
        assertEquals(SampleData.DEMO, d.characterId)
        assertEquals(SampleData.GREEN, d.characterOutfit)
        assertNull("a video preset doesn't carry over", d.settings.preset)
        assertEquals("phone", d.settings.body)
        assertEquals(SampleData.DEMO, PhotoComposer.request(d, PhotoDraft())!!.modelId)
        assertEquals(SampleData.GREEN, PhotoComposer.request(d, PhotoDraft())!!.outfitId)
        // No character given (a redirected link): the composer's own pick stays.
        assertEquals(SampleData.NOOR, PhotoComposer.open(from, null, null).characterId)
    }
}
