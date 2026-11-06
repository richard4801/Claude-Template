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
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.RecastPerson
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.screens.suite.composer.ComposerChip
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerLayout
import studio.muse.app.ui.screens.suite.composer.ComposerPrice
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PromptCodec
import studio.muse.app.ui.screens.suite.composer.PromptPart
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.ToolSlots
import studio.muse.app.ui.screens.suite.composer.movesFor

/** The video composer shell (AI suite, workstream 1): tools and their slots, the END FRAME rule, presets, prices, requests, the prompt field. */
class SuiteComposerShellTest {
    private val fake = FakeSuite()
    private val catalog = fake.catalog(owner = false)
    private val cat = catalog.camera
    private val all = SuiteInputs(start = true, end = true, middle = 8, images = 6, videos = 3, audio = true, framesWithRefs = true)
    private fun img(n: String) = SlotValue(name = "$n.jpg", image = ImageRef(url = "https://x/$n.jpg"))
    private val json = Json { explicitNulls = false }

    @Test fun `END FRAME is greyed until a start frame exists, and is not sent without one`() {
        val empty = InputSlots()
        assertFalse(empty.enabled(SlotId(SlotKind.END)))
        assertTrue(empty.enabled(SlotId(SlotKind.START)))
        assertTrue(empty.enabled(SlotId(SlotKind.IMAGE)))
        val end = ToolSlots.of(ComposerTool.SHOT, all, empty).first { it.kind == "end" }
        assertFalse(end.enabled); assertTrue(end.optional); assertEquals("After a start frame", end.caption)
        val withStart = empty.put(SlotId(SlotKind.START), img("a"))
        assertTrue(withStart.enabled(SlotId(SlotKind.END)))
        assertEquals("Where it lands", ToolSlots.of(ComposerTool.SHOT, all, withStart).first { it.kind == "end" }.caption)
        // An end frame left behind when the start is cleared stays (so it can be cleared) but isn't sent.
        val orphan = withStart.put(SlotId(SlotKind.END), img("b")).clear(SlotId(SlotKind.START))
        assertTrue(orphan.enabled(SlotId(SlotKind.END)))
        assertNull(orphan.applyTo(SuiteShotRequest(prompt = "x"), all).frames)
        val both = withStart.put(SlotId(SlotKind.END), img("b")).applyTo(SuiteShotRequest(prompt = "x"), all).frames!!
        assertEquals("https://x/a.jpg", both.start!!.url); assertEquals("https://x/b.jpg", both.end!!.url)
    }

    @Test fun `slot captions state their limits`() {
        assertEquals("Up to 6 images", SlotKind.IMAGE.caption(all))
        assertEquals("Up to 3 clips", SlotKind.VIDEO.caption(all))
        assertEquals("One track", SlotKind.AUDIO.caption(all))
        assertEquals("Sets the shape", SlotKind.START.caption(all))
        assertEquals("One image", SlotKind.IMAGE.caption(SuiteInputs(images = 1)))
    }

    @Test fun `each tool has its slots and chips, and only the tier frames show`() {
        val s = InputSlots()
        assertEquals(listOf("character", "start", "end"), ToolSlots.of(ComposerTool.SHOT, all, s).map { it.kind })
        assertEquals(listOf("character"), ToolSlots.of(ComposerTool.SHOT, SuiteInputs.NONE, s).map { it.kind })
        assertEquals(listOf("character", "start"), ToolSlots.of(ComposerTool.SHOT, SuiteInputs(start = true), s).map { it.kind })
        assertEquals(listOf("clip", "character"), ToolSlots.of(ComposerTool.SWAP, all, s).map { it.kind })
        assertEquals("Clip 3–30 s", ToolSlots.of(ComposerTool.SWAP, all, s).first().caption)
        assertEquals(listOf("clip", "people"), ToolSlots.of(ComposerTool.RECAST, all, s).map { it.kind })
        assertEquals("1–4 people", ToolSlots.of(ComposerTool.RECAST, all, s)[1].caption)
        assertEquals(listOf("character", "audio", "location"), ToolSlots.of(ComposerTool.TALKING, all, s).map { it.kind })
        assertEquals(listOf("character", "product", "refad"), ToolSlots.of(ComposerTool.UGC, all, s).map { it.kind })
        assertEquals(listOf("video"), ToolSlots.of(ComposerTool.EXTEND, all, s).map { it.kind })
        assertEquals(ComposerChip.entries.toList(), ComposerTool.SHOT.chips)
        assertEquals(listOf(ComposerChip.LOOK), ComposerTool.SWAP.chips)
        assertTrue(ComposerTool.RECAST.chips.isEmpty())
        assertEquals(listOf(ComposerChip.CAMERA, ComposerChip.LOOK, ComposerChip.LIGHTING), ComposerTool.TALKING.chips)
        // Without the catalog's `tools`, Talking, UGC ad and Extend keep their card but have no Generate.
        assertEquals(setOf(ComposerTool.TALKING, ComposerTool.UGC, ComposerTool.EXTEND), ComposerTool.entries.filter { !it.live }.toSet())
        assertEquals("Coming soon", ComposerDraft(tool = ComposerTool.EXTEND).problem(s, RecastDraft()))
        assertEquals(ComposerTool.SHOT, ComposerTool.of("nope")); assertEquals(ComposerTool.SWAP, ComposerTool.of("swap"))
        // Talking's Movement shows talk-safe moves only.
        assertTrue(movesFor(cat, "featured", "", talkOnly = true).all { it.talkSafe })
        assertTrue(movesFor(cat, "featured", "", talkOnly = false).any { !it.talkSafe })
        assertEquals("Locked-off", movesFor(cat, "featured", "", false).first().label) // Featured = the library, its labels
        assertTrue(movesFor(cat, "aerial", "", false).all { it.group == "aerial" })
    }

    @Test fun `a preset collapses the composer and Edit settings shows its values`() {
        val d = ComposerDraft().pickPreset(cat, "cinematic")
        assertTrue(d.collapsed)
        assertEquals("Cinematic", d.cardTitle(cat)); assertEquals("Film look, shallow focus, slow push", d.cardTagline(cat))
        assertEquals("character", d.collapsedSlot().kind)
        assertNull(d.modelId)
        assertEquals(SampleData.DEMO, ComposerDraft().pickPreset(cat, "cinematic", SampleData.DEMO).modelId) // one tap: the studio's first character
        assertNull(ComposerDraft().pickPreset(cat, "product_hero", SampleData.DEMO).modelId)
        assertEquals(SampleData.NOOR, ComposerDraft(modelId = SampleData.NOOR).pickPreset(cat, "cinematic", SampleData.DEMO).modelId)
        assertEquals("film_35", d.settings.body); assertEquals("teal_orange", d.settings.palette); assertEquals("cinematic", d.settings.preset)
        assertEquals("f2.8", d.settings.aperture) // f/2 isn't offered to members: the nearest visible step
        val mv = d.tokens.moves.single()
        assertEquals("dolly_in", mv.id); assertEquals(50, mv.intensity)
        val cam = d.request(InputSlots(), all, RecastDraft()).camera as JsonObject
        assertEquals("film_35", cam["rig"]!!.jsonObject["body"]!!.jsonPrimitive.content)
        assertEquals("dolly_in", cam["move"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        val open = d.expand()
        assertFalse(open.collapsed); assertEquals("cinematic", open.settings.preset)
        // Picking another preset replaces the move; a product preset asks for a photo.
        val p = d.pickPreset(cat, "product_hero")
        assertEquals("start", p.collapsedSlot().kind); assertEquals("Photo", p.collapsedSlot().label)
        assertTrue(p.tokens.moves.size <= 1)
        val cleared = open.clearPreset()
        assertNull(cleared.settings.preset); assertNull(cleared.settings.body); assertEquals("Shot", cleared.cardTitle(cat))
        // Switching tool leaves the preset.
        assertNull(d.withTool(ComposerTool.SWAP).settings.preset)
    }

    @Test fun `the price reads dash until known, Free for test renders, else the estimate's`() {
        assertEquals("—", ComposerPrice.short(null))
        assertEquals("Generate · —", ComposerPrice.button(null))
        assertNull(ComposerPrice.line(null))
        val e = SuiteEstimate(estimate = .16, priceLine = "about $0.16 · 8 s", buttonLabel = "Generate · 8 s · $0.16")
        assertEquals("$0.16", ComposerPrice.short(e))
        assertEquals("Generate · 8 s · $0.16", ComposerPrice.button(e))
        assertEquals("about $0.16 · 8 s", ComposerPrice.line(e))
        val t = e.copy(test = true)
        assertEquals("Free", ComposerPrice.short(t)); assertEquals("Generate · Free", ComposerPrice.button(t)); assertEquals("Test render · free", ComposerPrice.line(t))
        // A cap problem shows the estimate's message and stops Generate.
        val cap = e.copy(ok = false, message = "Over the studio's $5.00 per-shot limit")
        assertEquals("Over the studio's $5.00 per-shot limit", ComposerPrice.blocker(null, cap, null))
        assertEquals("Pick a character or describe the shot", ComposerPrice.blocker("Pick a character or describe the shot", e, null))
        assertEquals("Offline", ComposerPrice.blocker(null, null, "Offline"))
        assertNull(ComposerPrice.blocker(null, e, null))
    }

    @Test fun `the Shot request carries the prompt, character, chips, bar values and slots`() {
        val s = InputSlots()
        assertEquals("Pick a character or describe the shot", ComposerDraft().problem(s, RecastDraft()))
        var d = ComposerDraft(modelId = SampleData.DEMO, outfitId = SampleData.GREEN, quality = "hd", aspect = "1:1", duration = 6, takes = 2, speaking = false, sound = false)
        assertNull(d.problem(s, RecastDraft()))
        d = d.copy(tokens = PromptTokens().withText("She walks in ").addMove(cat.move("dolly_in")!!).first)
        val r = d.request(s.put(SlotId(SlotKind.START), img("a")), all, RecastDraft())
        assertEquals(SampleData.DEMO, r.modelId); assertEquals(SampleData.GREEN, r.outfitId); assertEquals("She walks in", r.prompt)
        assertEquals("hd", r.quality); assertEquals("1:1", r.aspectRatio); assertEquals(6, r.duration); assertEquals(2, r.takes); assertEquals(false, r.speaking)
        assertEquals(false, r.audio)
        assertEquals("dolly_in", (r.camera as JsonObject)["move"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals("https://x/a.jpg", r.frames!!.start!!.url)
        // Sound on is the server's default: not sent. An @character in the prompt wins over the slot.
        val wire = json.encodeToJsonElement(SuiteShotRequest.serializer(), d.copy(sound = true).request(s, all, RecastDraft())).jsonObject
        assertFalse("audio" in wire); assertFalse("mode" in wire)
        val noor = d.copy(tokens = d.tokens.addMention("character", SampleData.NOOR, "Noor").first)
        assertEquals(SampleData.NOOR, noor.request(s, all, RecastDraft()).modelId)
        assertNull(noor.request(s, all, RecastDraft()).outfitId) // the slot's outfit was for another character
        // Directed mode's camera JSON replaces the chips' camera.
        val dir = d.copy(directed = """{"mode":"directed","guide":{"video":{"key":"cam/g.mp4"}}}""").request(s, all, RecastDraft())
        assertEquals("directed", (dir.camera as JsonObject)["mode"]!!.jsonPrimitive.content)
    }

    @Test fun `Character swap and Recast send the clip and cast with the composer's quality`() {
        val recast = RecastDraft(SampleData.SAMPLE_CLIP, listOf(RecastPerson("left", SampleData.DEMO), RecastPerson("right", SampleData.NOOR)))
        val swap = ComposerDraft(tool = ComposerTool.SWAP, modelId = SampleData.DEMO, quality = "hd", speaking = true,
            settings = studio.muse.app.ui.screens.suite.composer.ComposerSettings(body = "film_35", palette = "golden_warmth"))
        assertEquals("Choose the source clip", swap.problem(InputSlots(), RecastDraft()))
        assertEquals("Pick who she becomes", swap.copy(modelId = null).problem(InputSlots(), recast))
        val r = swap.request(InputSlots(), all, recast)
        assertEquals("recast", r.mode); assertEquals(SampleData.SAMPLE_CLIP, r.clipId); assertEquals("hd", r.quality)
        assertEquals(1, r.cast!!.size); assertEquals(SampleData.DEMO, r.cast!![0].characterId); assertEquals(true, r.cast!![0].speaking)
        assertEquals("", r.prompt) // the prompt is behind a toggle, off by default
        val cam = r.camera as JsonObject
        assertEquals("golden_warmth", cam["palette"]!!.jsonObject["preset"]!!.jsonPrimitive.content)
        assertFalse("rig" in cam) // camera and light come from the clip: only the Look is sent
        val rc = ComposerDraft(tool = ComposerTool.RECAST, quality = "cinema", takes = 2).request(InputSlots(), all, recast)
        assertEquals(listOf(SampleData.DEMO, SampleData.NOOR), rc.cast!!.map { it.characterId })
        assertEquals("cinema", rc.quality); assertEquals(2, rc.takes)
        assertNull(ComposerDraft(tool = ComposerTool.RECAST).problem(InputSlots(), recast))
    }

    @Test fun `Length follows the tier range and tablet width uses the desktop layout`() {
        assertEquals(2..15, ComposerDraft(quality = "draft").lengthRange(catalog))
        assertEquals(3..30, ComposerDraft(quality = "hd").lengthRange(catalog))
        assertEquals(15, ComposerDraft(quality = "hd", duration = 20).copy(quality = "draft").fit(catalog).duration)
        assertEquals(3, ComposerDraft(quality = "draft", duration = 2).copy(quality = "cinema").fit(catalog).duration)
        assertEquals(2..15, ComposerDraft().lengthRange(null))
        assertEquals("8 s · 9:16" to "1 take", ComposerDraft().barSummary)
        assertFalse(ComposerLayout.wide(390)); assertTrue(ComposerLayout.wide(600)); assertTrue(ComposerLayout.wide(840))
    }

    @Test fun `the prompt field round-trips tokens as single characters`() {
        val t0 = PromptTokens().withText("walks in ")
        val (t1, _) = t0.addMention("character", "m_noor", "Noor", t0.caretAtEnd.copy(part = 0, offset = 0))
        val (t2, _) = t1.addMove(cat.move("dolly_in")!!)
        val s = PromptCodec.encode(t2)
        assertEquals(1 + "walks in ".length + 1, s.length)
        assertEquals(t2.parts.map { it::class }, PromptCodec.decode(t2, s).parts.map { it::class })
        assertEquals(t2.display(), PromptCodec.decode(t2, s).display())
        // Backspace over a chip removes the token.
        val gone = PromptCodec.decode(t2, s.dropLast(1))
        assertTrue(gone.moves.isEmpty()); assertEquals("Noor", gone.character!!.label)
        // Typing between keeps the tokens.
        val typed = PromptCodec.decode(t2, s.substring(0, 1) + "Now " + s.substring(1))
        assertEquals("Noor Now walks in", typed.promptText())
        // The display shows chips; offsets map both ways and never land inside a chip.
        val disp = PromptCodec.display(t2, s)
        assertTrue(disp.text.contains("@Noor")); assertTrue(disp.text.contains("#Dolly in"))
        assertEquals(2, disp.chips.size)
        assertEquals(0, disp.fieldToDisplay(0))
        val afterNoor = disp.fieldToDisplay(1)
        assertEquals(1, disp.displayToField(afterNoor))
        assertEquals(1, disp.displayToField(2)) // inside "@Noor" → after the token
        assertEquals(s.length, disp.displayToField(disp.text.length))
        assertEquals(t2.mentions.first(), PromptCodec.tokenAt(t2, s, 0))
        assertNull(PromptCodec.tokenAt(t2, s, 2))
        // Triggers: "@no" right after a chip or a space; inserting at a field offset.
        val s2 = s + " #dol"
        val tr = PromptCodec.triggerAt(s2, s2.length)!!
        assertEquals('#', tr.char); assertEquals("dol", tr.query)
        val (dropped, caret) = PromptCodec.dropTrigger(s2, tr, s2.length)
        assertEquals(s + " ", dropped); assertEquals(dropped.length, caret)
        assertNull(PromptCodec.triggerAt("email@x", 7))
        val base = PromptCodec.decode(t2, dropped)
        val at = PromptCodec.caretAt(base, caret)
        val (t3, msg) = base.addMove(cat.move("orbit_left")!!, at)
        assertNull(msg); assertEquals(listOf("dolly_in", "orbit_left"), t3.moves.map { it.id })
        assertTrue(t3.parts.last() is PromptPart.Move)
        assertNotNull(PromptCodec.caretAt(base, 0))
    }
}
