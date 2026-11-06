package studio.muse.app

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SampleData
import studio.muse.app.ui.screens.suite.FaceCrop
import studio.muse.app.ui.screens.suite.FaceMath
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.RecastPerson
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.ToolSlots
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.data.SuiteShotRequest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import studio.muse.app.data.VideoDraft
import studio.muse.app.data.VideoFeatures
import studio.muse.app.ui.screens.suite.composer.SwapAddon
import studio.muse.app.ui.screens.suite.composer.SwapAddons
import studio.muse.core.Pricing
import studio.muse.core.VideoOption
import studio.muse.app.ui.screens.suite.composer.EraScale
import studio.muse.app.ui.screens.suite.composer.ComposerCatalog
import studio.muse.app.ui.screens.suite.composer.ComposerChip
import studio.muse.app.ui.screens.suite.composer.CameraWheels
import studio.muse.app.data.SuiteLocation
import studio.muse.app.data.SuiteLocationCreate
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.Suggestion
import studio.muse.app.ui.screens.suite.composer.suggestions
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.screens.suite.composer.PromptCodec

/** The composer's follow-ups (AI suite, workstream 1): tap a face, swap add-ons, the era slider, UGC formats, @location, reorder, the engine pin. */
class SuiteComposerFollowupTest {
    private val fake = FakeSuite()
    private val json = Json { explicitNulls = false }

    // ---------------------------------------------------------------- 1. Recast: tap a face

    @Test fun `a tap reads as the left, centre or right third`() {
        assertEquals("left", FaceMath.hint(0f))
        assertEquals("left", FaceMath.hint(.33f))
        assertEquals("center", FaceMath.hint(.34f))
        assertEquals("center", FaceMath.hint(.5f))
        assertEquals("center", FaceMath.hint(.66f))
        assertEquals("right", FaceMath.hint(.67f))
        assertEquals("right", FaceMath.hint(1f))
    }

    @Test fun `the crop is a square of 28 percent of the short side, centred on the tap and kept inside the frame`() {
        // 1080 × 1920: short side 1080 → 302 px.
        assertEquals(FaceCrop(389, 809, 302), FaceMath.crop(1080, 1920, .5f, .5f))
        // At the top-left corner it is pushed inside.
        assertEquals(FaceCrop(0, 0, 302), FaceMath.crop(1080, 1920, 0f, 0f))
        // At the bottom-right corner too.
        assertEquals(FaceCrop(1080 - 302, 1920 - 302, 302), FaceMath.crop(1080, 1920, 1f, 1f))
        // A landscape frame: the height is the short side.
        val c = FaceMath.crop(1920, 1080, .9f, .2f)
        assertEquals(302, c.side)
        assertEquals(1728 - 151, c.left); assertEquals(216 - 151, c.top)
        // Never outside, never bigger than the frame.
        for (x in listOf(-1f, 0f, .1f, .5f, .99f, 2f)) for (y in listOf(-1f, 0f, .5f, 1f, 3f)) {
            val k = FaceMath.crop(640, 360, x, y)
            assertTrue(k.left >= 0 && k.top >= 0 && k.left + k.side <= 640 && k.top + k.side <= 360)
        }
        assertEquals(FaceCrop(0, 0, 1), FaceMath.crop(1, 1, .5f, .5f))
    }

    @Test fun `tapping faces fills people, sets their position from the third and stops at the catalog's max`() {
        var d = RecastDraft(clipId = SampleData.SAMPLE_CLIP)
        val (a, i0) = d.tapFace(.8f, .3f, max = 4, id = 1)
        assertEquals(0, i0)
        assertEquals("right", a.people[0].hint)
        assertTrue(a.people[0].cropping)
        d = a
        // Near the marker: the same person, nothing changes.
        val (same, iSame) = d.tapFace(.82f, .31f, 4, 2)
        assertSame(d, same); assertEquals(0, iSame)
        // Elsewhere: a new person with the tapped third.
        val (b, i1) = d.tapFace(.1f, .4f, 4, 3)
        assertEquals(1, i1); assertEquals("left", b.people[1].hint)
        d = b.tapFace(.5f, .5f, 4, 4).first.tapFace(.5f, .9f, 4, 5).first
        assertEquals(4, d.people.size)
        val (full, none) = d.tapFace(.2f, .9f, 4, 6)
        assertNull(none); assertSame(d, full)
        // A smaller max from the catalog is honoured.
        assertNull(RecastDraft().tapFace(.1f, .1f, 1, 1).first.tapFace(.9f, .9f, 1, 2).second)
    }

    @Test fun `a picked position chip wins over the tap, and the crop goes out as faceCrop`() {
        var d = RecastDraft(clipId = "clip_1").pickHint(0, "background")
        d = d.tapFace(.1f, .5f, 4, 7).first
        assertEquals("background", d.people[0].hint)
        assertEquals("Pick who each person becomes", d.problem())
        d = d.update(0) { it.copy(characterId = SampleData.DEMO) }
        assertEquals("Waiting for the face upload", d.problem())
        d = d.setCrop(7, ImageRef(url = "/uploads/face-1.jpg"))
        assertNull(d.problem())
        val cast = d.request().cast!!.single()
        assertEquals("background", cast.personHint)
        assertEquals("/uploads/face-1.jpg", cast.faceCrop!!.url)
        assertTrue(json.encodeToString(studio.muse.app.data.SuiteShotRequest.serializer(), d.request()).contains("\"faceCrop\":{\"url\":\"/uploads/face-1.jpg\"}"))
        // Clearing the face forgets the crop; the chip's position stays.
        val cleared = d.clearTap(0)
        assertNull(cleared.people[0].tap); assertNull(cleared.request().cast!!.single().faceCrop); assertEquals("background", cleared.people[0].hint)
    }

    @Test fun `two people tapped in the same third are fine with crops, not without`() {
        var d = RecastDraft(clipId = "c", people = listOf(RecastPerson("center", SampleData.DEMO), RecastPerson("left", SampleData.NOOR)))
        d = d.tapFace(.1f, .2f, 4, 1).first.tapFace(.2f, .8f, 4, 2).first
        assertEquals(listOf("left", "left"), d.people.map { it.hint })
        d = d.setCrop(1, null).setCrop(2, null)
        assertEquals("Two people point at the same spot", d.problem())
        d = d.setCrop(1, ImageRef(url = "a")).copy(people = d.people.map { if (it.tap?.id == 1L) it.copy(faceCrop = ImageRef(url = "a")) else it.copy(faceCrop = ImageRef(url = "b")) })
        assertNull(d.problem())
        // Without a face picker the old rule holds.
        assertFalse(RecastDraft().add().people.map { it.hint }.toSet().size != 2)
        assertNotNull(RecastDraft(clipId = "c", people = listOf(RecastPerson("left", "x"), RecastPerson("left", "y"))).problem())
    }

    // ---------------------------------------------------------------- catalog tools, Talking and UGC ad requests

    private val decoder = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()

    @Test fun `the catalog's tools drive Coming soon, and an older catalog keeps the built-in list`() {
        val cat = decoder.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_member"))
        assertEquals(listOf("shot", "swap", "recast", "storyboard", "talking", "ugc_ad", "extend"), cat.tools!!.map { it.id })
        assertTrue(ComposerTool.TALKING.isLive(cat)); assertTrue(ComposerTool.UGC.isLive(cat)); assertFalse(ComposerTool.EXTEND.isLive(cat))
        assertTrue(cat.tools!!.last().comingSoon)
        val off = decoder.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_off_owner"))
        assertFalse(ComposerTool.SHOT.isLive(off))
        val old = decoder.decodeFromString(SuiteCatalog.serializer(), """{"enabled":true,"tiers":[]}""")
        assertNull(old.tools)
        assertTrue(ComposerTool.SHOT.isLive(old)); assertFalse(ComposerTool.UGC.isLive(old)); assertFalse(ComposerTool.TALKING.isLive(old))
        assertTrue(ComposerTool.SHOT.isLive(null))
        assertEquals(ComposerTool.UGC, ComposerTool.of("ugc_ad"))
        // The demo catalog says the same as the server's mock mode.
        assertTrue(ComposerTool.UGC.isLive(fake.catalog(owner = false)))
    }

    @Test fun `Talking sends the audio as a reference, the speaking switch and an optional location photo`() {
        val d = ComposerDraft(tool = ComposerTool.TALKING, modelId = SampleData.DEMO, quality = "standard")
        val none = InputSlots()
        assertEquals("Add the audio", d.problem(none, RecastDraft(), none))
        assertEquals("Pick who talks", d.copy(modelId = null).problem(none, RecastDraft(), none))
        val own = none.put(ToolSlots.TALK_AUDIO, SlotValue("line.m4a", media = SuiteMediaRef(key = "u/line.m4a")))
        assertEquals("Waiting for the upload", d.problem(none, RecastDraft(), own.put(ToolSlots.TALK_LOCATION, SlotValue("cafe.jpg", progress = .4f))))
        assertNull(d.problem(none, RecastDraft(), own))
        val r = d.request(none, SuiteInputs(), RecastDraft(), own)
        assertEquals(SampleData.DEMO, r.modelId)
        assertEquals("u/line.m4a", r.references!!.audio!!.audio.key)
        assertNull(r.references!!.images)
        assertEquals(true, r.speaking)
        assertEquals(false, d.copy(speaking = false).request(none, SuiteInputs(), RecastDraft(), own).speaking)
        val withPlace = d.request(none, SuiteInputs(), RecastDraft(), own.put(ToolSlots.TALK_LOCATION, SlotValue("cafe.jpg", image = ImageRef(url = "/uploads/cafe.jpg"))))
        val img = withPlace.references!!.images!!.single()
        assertEquals("location", img.role); assertEquals("cafe", img.label); assertEquals("/uploads/cafe.jpg", img.image.url)
        assertTrue(json.encodeToString(SuiteShotRequest.serializer(), r).contains("\"audio\":{\"audio\":{\"key\":\"u/line.m4a\"}}"))
    }

    @Test fun `UGC ad sends the product photo, an optional reference ad and the format`() {
        val d = ComposerDraft(tool = ComposerTool.UGC, modelId = SampleData.DEMO, settings = ComposerSettings(format = "unboxing"))
        val none = InputSlots()
        assertEquals("Add the product photo", d.problem(none, RecastDraft(), none))
        val own = none.put(ToolSlots.UGC_PRODUCT, SlotValue("serum.png", image = ImageRef(url = "/uploads/serum.png")))
        assertNull(d.problem(none, RecastDraft(), own))
        val r = d.request(none, SuiteInputs(), RecastDraft(), own)
        val img = r.references!!.images!!.single()
        assertEquals("product", img.role); assertEquals("serum", img.label)
        assertNull(r.references!!.videos)
        assertEquals("unboxing", (r.camera as JsonObject)["style"]!!.jsonObject["format"]!!.jsonPrimitive.content)
        val ad = d.request(none, SuiteInputs(), RecastDraft(), own.put(ToolSlots.UGC_REFAD, SlotValue("ad.mp4", media = SuiteMediaRef(key = "u/ad.mp4"))))
        val v = ad.references!!.videos!!.single()
        assertEquals("u/ad.mp4", v.video.key); assertEquals("style", v.use)
        assertNull(ad.speaking)
    }

    // ---------------------------------------------------------------- 2. Character swap add-ons

    @Test fun `swap add-ons are pills with their own prices, beside the quality ladder`() {
        val vf = VideoFeatures.DEFAULT
        val pills = SwapAddons.pills(vf, fastBeta = true, takes = 1, clipSeconds = 9.4)
        assertEquals(listOf(SwapAddon.EDIT, SwapAddon.FAST, SwapAddon.UPSCALE), pills.map { it.addon })
        // The prices are the add-on estimate's (the same formula as the video studio and the server).
        val edit = VideoDraft(takes = 1).pick(VideoOption.EDIT).spec().copy(clipSeconds = 9.4)
        assertEquals(Pricing.money(Pricing.totalCost(edit)), pills[0].price)
        val fast = VideoDraft(takes = 1).pick(VideoOption.FAST).spec().copy(clipSeconds = 9.4)
        assertEquals(Pricing.money(Pricing.totalCost(fast)), pills[1].price)
        assertFalse(pills[2].available); assertEquals("Soon", pills[2].price)
        // Fast · beta only with its switch on; no clip yet = no price.
        assertEquals(listOf(SwapAddon.EDIT, SwapAddon.UPSCALE), SwapAddons.pills(vf, false, 1, 9.4).map { it.addon })
        assertEquals("—", SwapAddons.pills(vf, true, 1, null)[0].price)
        // Two takes cost twice.
        val e2 = SwapAddons.estimate(SwapAddon.EDIT, 2, 9.4)
        assertEquals(Pricing.totalCost(edit) * 2, e2.estimate, 1e-9)
        assertEquals(Pricing.genLabel(edit.copy(takes = 2)), e2.buttonLabel)
        assertTrue(e2.buttonLabel.startsWith("Generate · "))
    }

    @Test fun `an add-on sends a video job on its own engine, and the ladder stays the default`() {
        val d = ComposerDraft(tool = ComposerTool.SWAP, modelId = SampleData.DEMO, outfitId = SampleData.GREEN, quality = "hd", takes = 2, speaking = true)
        assertNull(d.swapAddon)
        val recast = RecastDraft(clipId = SampleData.SAMPLE_CLIP, keepAudio = false)
        // Without an add-on: the suite's swap at the picked quality.
        assertEquals("hd", d.request(InputSlots(), SuiteInputs(), recast).quality)
        val e = d.copy(addon = "edit")
        assertEquals(SwapAddon.EDIT, e.swapAddon)
        val r = SwapAddons.request(e, recast, SwapAddon.EDIT, 9.4)
        assertEquals("h3", r.engine); assertEquals("full", r.use); assertEquals(Pricing.STEPS_DEFAULT, r.steps)
        assertEquals(SampleData.DEMO, r.modelId); assertEquals(SampleData.GREEN, r.outfitId); assertEquals(SampleData.SAMPLE_CLIP, r.clipId)
        assertEquals(2, r.takes); assertFalse(r.keepAudio); assertEquals(true, r.speaking); assertNull(r.quality)
        val f = SwapAddons.request(d.copy(addon = "fast"), recast, SwapAddon.FAST, 9.4)
        assertEquals("viggle", f.engine)
        // Upscale is never a render choice, and add-ons are Character swap's only.
        assertNull(d.copy(addon = "upscale").swapAddon)
        assertNull(d.copy(tool = ComposerTool.SHOT, addon = "edit").swapAddon)
    }

    // ---------------------------------------------------------------- 3. Era as a decade slider · 4. UGC formats

    @Test fun `the era slider snaps to the catalog's eras in order, with Auto off the left end`() {
        val cat = fake.camera
        val stops = EraScale.stops(cat)
        assertEquals(listOf(null, "1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s", "future"), stops)
        assertNull(EraScale.snap(cat, 0f))
        assertNull(EraScale.snap(cat, .06f))
        assertEquals("1960s", EraScale.snap(cat, .07f))
        assertEquals("1990s", EraScale.snap(cat, .5f))
        assertEquals("future", EraScale.snap(cat, 1f))
        assertEquals("future", EraScale.snap(cat, 7f))
        assertNull(EraScale.snap(cat, -1f))
        assertEquals(4, EraScale.index(cat, "1990s")); assertEquals(0, EraScale.index(cat, null)); assertEquals(0, EraScale.index(cat, "1850s"))
        assertEquals("2020s", EraScale.at(cat, 7)); assertEquals("future", EraScale.at(cat, 99))
        assertEquals(listOf("Auto", "60s", "70s", "80s", "90s", "00s", "10s", "20s", "Future"), stops.map { EraScale.tick(cat, it) })
        // Hidden eras are not stops.
        val fewer = cat.copy(eras = cat.eras.map { if (it.id == "1970s") it.copy(visible = false) else it })
        assertFalse("1970s" in EraScale.stops(fewer))
        // An empty catalog: only Auto.
        assertEquals(listOf(null), EraScale.stops(studio.muse.app.data.CameraCatalog()))
        assertNull(EraScale.snap(studio.muse.app.data.CameraCatalog(), .7f))
    }

    @Test fun `the UGC format goes in camera style and leads the Style chip`() {
        val cat = fake.camera
        assertEquals(listOf("unboxing", "review", "try_on", "before_after", "grwm", "haul", "tutorial", "testimonial"), cat.ugcFormats.map { it.id })
        val s = ComposerSettings(format = "try_on", era = "1990s")
        val style = s.cameraJson()!!["style"]!!.jsonObject
        assertEquals("try_on", style["format"]!!.jsonPrimitive.content); assertEquals("1990s", style["era"]!!.jsonPrimitive.content)
        val sum = ComposerCatalog.summary(ComposerChip.STYLE, s, cat)
        assertEquals("Try-on, 1990s", sum.value)
        assertEquals("Style · Try-on, 1990s", sum.text())
        assertTrue(s.isSet(ComposerChip.STYLE)); assertNull(s.reset(ComposerChip.STYLE).format)
        assertNull(ComposerSettings().cameraJson())
        // The format wheel: Auto first, then each format.
        val wheel = CameraWheels.formats(cat)
        assertEquals(listOf(null) + cat.ugcFormats.map { it.id }, wheel.map { it.id })
        assertEquals(3, CameraWheels.index(wheel, "try_on", cat.ugcFormats))
        // An older catalog without ugcFormats still decodes; the label falls back to the id.
        val old = decoder.decodeFromString(studio.muse.app.data.CameraCatalog.serializer(), """{"eras":[]}""")
        assertTrue(old.ugcFormats.isEmpty())
        assertEquals("review", ComposerCatalog.summary(ComposerChip.STYLE, ComposerSettings(format = "review"), old).value)
        // The request sends it (UGC ad).
        val r = ComposerDraft(tool = ComposerTool.UGC, settings = ComposerSettings(format = "grwm")).request(InputSlots(), SuiteInputs(), RecastDraft())
        assertEquals("grwm", (r.camera as JsonObject)["style"]!!.jsonObject["format"]!!.jsonPrimitive.content)
    }

    // ---------------------------------------------------------------- 5. @location

    private val loft = SuiteLocation("loc_loft", "Sunlit loft", ImageRef(url = "/uploads/loft.jpg"))
    private val street = SuiteLocation("loc_street", "Night street", ImageRef(url = "/uploads/street.jpg"))

    @Test fun `a location token reads as its name and goes out as a location reference`() {
        var t = PromptTokens().withText("She dances in ")
        t = t.addMention("location", loft.id, loft.name).first
        val d = ComposerDraft(tokens = t, modelId = SampleData.DEMO)
        val inputs = SuiteInputs(images = 3)
        val r = d.request(InputSlots(), inputs, RecastDraft(), locations = listOf(loft, street))
        assertEquals("She dances in Sunlit loft", r.prompt)
        val img = r.references!!.images!!.single()
        assertEquals("location", img.role); assertEquals("Sunlit loft", img.label); assertEquals("/uploads/loft.jpg", img.image.url)
        // After the slots' own images.
        val slots = InputSlots().put(SlotId(SlotKind.IMAGE), SlotValue("bag.jpg", image = ImageRef(url = "/uploads/bag.jpg")))
        val both = d.request(slots, inputs, RecastDraft(), locations = listOf(loft))
        assertEquals(listOf("product", "location"), both.references!!.images!!.map { it.role })
        // A location the library no longer has is left out.
        assertNull(d.request(InputSlots(), inputs, RecastDraft(), locations = emptyList()).references)
        // UGC ad and Talking take them too; Character swap doesn't.
        assertEquals("location", d.copy(tool = ComposerTool.UGC).request(InputSlots(), inputs, RecastDraft(), locations = listOf(loft)).references!!.images!!.single().role)
        assertNull(d.copy(tool = ComposerTool.SWAP).request(InputSlots(), inputs, RecastDraft(clipId = "c"), locations = listOf(loft)).references)
    }

    @Test fun `locations count against the References limit and are refused when it is full`() {
        val one = SuiteInputs(images = 1)
        val d = ComposerDraft(quality = "draft")
        assertNull(d.locationProblem(InputSlots(), one))
        assertEquals("Draft doesn't take reference images · try another quality", d.locationProblem(InputSlots(), SuiteInputs()))
        val withLoft = d.copy(tokens = d.tokens.addMention("location", loft.id, loft.name).first)
        assertEquals(1, withLoft.referencesUsed(InputSlots(), one))
        assertEquals("References are full · up to 1 on Draft", withLoft.locationProblem(InputSlots(), one))
        // The same place again is not a new reference.
        assertNull(withLoft.locationProblem(InputSlots(), one, id = loft.id))
        // A filled image slot counts too.
        val slots = InputSlots().put(SlotId(SlotKind.IMAGE), SlotValue("bag.jpg", image = ImageRef(url = "b")))
        assertEquals("References are full · up to 1 on Draft", d.locationProblem(slots, one))
        // If the quality drops, the request never carries more than the limit.
        val two = withLoft.copy(tokens = withLoft.tokens.addMention("location", street.id, street.name).first)
        assertEquals(1, two.request(InputSlots(), one, RecastDraft(), locations = listOf(loft, street)).references!!.images!!.size)
    }

    @Test fun `@ offers characters, outfits and locations, ending with New location`() {
        val models = SampleData.models()
        val tr = PromptTokens.activeTrigger("in the @", 8)
        val list = suggestions(tr, models, emptyList(), fake.camera, false, listOf(loft, street))
        assertTrue(list.first() is Suggestion.Character)
        assertEquals(listOf(Suggestion.Place(loft), Suggestion.Place(street), Suggestion.NewPlace), list.takeLast(3))
        val q = suggestions(PromptTokens.activeTrigger("@night", 6), models, emptyList(), fake.camera, false, listOf(loft, street))
        assertEquals(listOf(Suggestion.Place(street), Suggestion.NewPlace), q)
        // # never offers places.
        assertTrue(suggestions(PromptTokens.activeTrigger("#", 1), models, emptyList(), fake.camera, false, listOf(loft)).none { it is Suggestion.Place })
    }

    @Test fun `demo mode has two locations and adds, lists and deletes them`() = kotlinx.coroutines.runBlocking {
        val api = studio.muse.app.data.FakeMuseApi(kotlinx.coroutines.MainScope(), null, speed = 0.0, genDelayMs = 0)
        val list = api.suiteLocations()
        assertEquals(2, list.size)
        assertTrue(list.all { it.image.asset != null && it.name.isNotBlank() })
        val made = api.createSuiteLocation(SuiteLocationCreate("Rooftop", ImageRef(url = "file:///x.jpg")))
        assertEquals("Rooftop", api.suiteLocations().first().name)
        api.deleteSuiteLocation(made.id)
        assertEquals(2, api.suiteLocations().size)
        // A server without locations says so (the composer then simply has none).
        val old = object : studio.muse.app.data.MuseApi by api {
            override suspend fun suiteLocations(): List<SuiteLocation> = super<studio.muse.app.data.MuseApi>.suiteLocations()
        }
        assertEquals("not_found", runCatching { old.suiteLocations() }.exceptionOrNull().let { (it as studio.muse.app.data.ApiException).code })
    }

    // ---------------------------------------------------------------- 7. The owner's engine pin

    @Test fun `the owner's engine pin decides the slots and goes out with the shot, and members never have one`() {
        val owner = decoder.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_owner"))
        var d = ComposerDraft(quality = "standard", modelId = SampleData.DEMO)
        assertEquals("Auto", d.engineLabel(owner))
        assertEquals(8, d.inputsFor(owner).middle)
        val ltx = owner.tier("standard")!!.models!!.first { it.model == "ltx-2.3" }
        d = d.pin(ltx)
        assertEquals("ltx-2.3", d.engineModel); assertEquals("1080p", d.resolution)
        // The slots follow the engine: this one takes no references and no middle frames.
        assertEquals(0, d.inputsFor(owner).images); assertEquals(0, d.inputsFor(owner).middle)
        assertEquals(owner.tier("standard")!!.slotsFor("ltx-2.3"), d.inputsFor(owner))
        val shown = ToolSlots.of(ComposerTool.SHOT, d.inputsFor(owner), InputSlots())
        assertEquals(listOf("character", "start", "end"), shown.map { it.kind })
        assertTrue(d.engineLabel(owner).endsWith("· 1080p"))
        val r = d.request(InputSlots(), d.inputsFor(owner), RecastDraft())
        assertEquals("ltx-2.3", r.engineModel); assertEquals("1080p", r.resolution)
        // A quality whose engines don't include it goes back to Auto; so does a member's catalog (no engines).
        assertNull(d.copy(quality = "cinema").fit(owner).engineModel)
        assertEquals("ltx-2.3", d.copy(quality = "standard").fit(owner).engineModel)
        val member = SuiteRules.memberSafe(owner)
        assertNull(d.fit(member).engineModel)
        assertEquals(member.tier("standard")!!.slots, ComposerDraft(quality = "standard").inputsFor(member))
        // Auto sends no engine.
        val auto = d.pin(null).request(InputSlots(), owner.tier("standard")!!.slots, RecastDraft())
        assertNull(auto.engineModel); assertNull(auto.resolution)
        // Character swap and Recast never carry a shot engine.
        assertNull(d.copy(tool = ComposerTool.RECAST).request(InputSlots(), SuiteInputs(), RecastDraft(clipId = "c")).engineModel)
    }

    // ---------------------------------------------------------------- 6. Drag to reorder tokens

    @Test fun `a dragged token lands where it is dropped, and Move left or right nudges it one place`() {
        val cat = fake.camera
        var t = PromptTokens().withText("walks in slowly")
        t = t.addMention("character", SampleData.DEMO, "Demo", studio.muse.app.ui.screens.suite.composer.Caret(0, 0)).first
        t = t.addMove(cat.move("dolly_in")!!).first
        assertEquals("@Demowalks in slowly#Dolly in", t.display())
        val dolly = t.moves.single()
        val demo = t.character!!
        // Drop the move between "walks" and " in" (field offset 1 + 5 = after "walks").
        val moved = PromptCodec.moveToken(t, dolly.key, 6)
        assertEquals("@Demowalks#Dolly in in slowly", moved.display())
        assertEquals(listOf("dolly_in"), moved.moves.map { it.id })
        // Drop the character at the very end.
        val end = PromptCodec.moveToken(t, demo.key, PromptCodec.encode(t).length)
        assertEquals("walks in slowly#Dolly in@Demo", end.display())
        // Dropped where it is: unchanged.
        assertSame(t, PromptCodec.moveToken(t, demo.key, 0))
        assertSame(t, PromptCodec.moveToken(t, demo.key, 1))
        // An unknown key: unchanged.
        assertSame(t, PromptCodec.moveToken(t, 999, 3))
        // TalkBack: Move left / Move right is reorder by one part; at the ends nothing happens.
        assertEquals("walks in slowly@Demo#Dolly in", PromptCodec.nudge(t, demo.key, 1).display())
        assertEquals("@Demowalks in slowly#Dolly in", PromptCodec.nudge(t, demo.key, -1).display())
        assertEquals(t.reorder(dolly.key, 1), PromptCodec.nudge(t, dolly.key, -1))
        assertSame(t, PromptCodec.nudge(t, dolly.key, 1))
        // The prompt text follows the order; the moves stay in camera.move.
        assertEquals("walks in slowly Demo", end.promptText())
    }

    // ---------------------------------------------------------------- composer previews (design/previews → assets/previews)

    @Test fun `moves, lighting and angles carry bundled previews, and every file exists`() {
        val cam = fake.camera
        val moves = cam.moves.filter { it.preview != null }
        assertTrue(moves.size >= 39)
        assertNull(cam.move("motion_blur")?.preview)
        val dolly = cam.move("dolly_in")!!.preview!!
        assertEquals("moves/dolly_in.mp4", dolly.video); assertEquals("moves/dolly_in.webp", dolly.poster)
        assertEquals("lighting/auto.webp", cam.autoPreviews.lighting!!.poster)
        assertTrue(cam.lighting.all { it.preview?.poster?.startsWith("lighting/") == true })
        assertTrue((cam.heights + cam.shotSizes).all { it.preview?.poster?.startsWith("angles/") == true })
        // The files the tiles open (the Gradle copy bundles design/previews as assets/previews).
        val root = listOf(java.io.File("../../design/previews"), java.io.File("../design/previews")).first { it.isDirectory }
        val paths = moves.flatMap { listOfNotNull(it.preview!!.video, it.preview!!.poster) } + cam.lighting.mapNotNull { it.preview?.poster } +
            (cam.heights + cam.shotSizes).mapNotNull { it.preview?.poster } + listOfNotNull(cam.autoPreviews.lighting?.poster)
        val missing = paths.filterNot { java.io.File(root, it).isFile }
        assertTrue("missing previews: $missing", missing.isEmpty())
        // An older catalog: no previews, the drawn stills stay.
        val old = decoder.decodeFromString(studio.muse.app.data.CameraCatalog.serializer(), """{"moves":[{"id":"dolly_in","label":"Dolly in"}],"lighting":[{"id":"window"}]}""")
        assertNull(old.moves.single().preview); assertNull(old.lighting.single().preview); assertNull(old.autoPreviews.lighting)
    }
}
