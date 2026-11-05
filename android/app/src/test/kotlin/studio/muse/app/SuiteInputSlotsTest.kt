package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.SuiteTier
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SlotValue

/** The Shot's input slots (AI suite, workstream 1): which show for a tier, filling and clearing, and what is sent. */
class SuiteInputSlotsTest {
    private val all = SuiteInputs(start = true, end = true, middle = 8, images = 6, videos = 3, audio = true, framesWithRefs = true)
    private val framesOnly = SuiteInputs(start = true, end = true)
    private fun img(n: String) = SlotValue(name = "$n.jpg", image = ImageRef(url = "https://x/$n.jpg"))
    private fun vid(n: String) = SlotValue(name = "$n.mp4", media = SuiteMediaRef(key = "c/$n.mp4"))

    @Test fun `a slot shows only when the tier takes it`() {
        val s = InputSlots()
        assertEquals(emptyList<SlotId>(), s.visible(SuiteInputs.NONE))
        assertEquals(listOf(SlotId(SlotKind.START), SlotId(SlotKind.END)), s.visible(framesOnly))
        // Many-of kinds show one empty "add" slot each.
        assertEquals(SlotKind.entries.toList(), s.visible(all).map { it.kind })
    }

    @Test fun `many-of kinds fill from the front and stop at the tier's count`() {
        var s = InputSlots()
        s = s.put(SlotId(SlotKind.IMAGE, 4), img("a")) // lands first
        assertEquals(img("a"), s[SlotId(SlotKind.IMAGE, 0)])
        s = s.put(SlotId(SlotKind.IMAGE, 1), img("b"))
        assertEquals(listOf(0, 1, 2), s.visible(all).filter { it.kind == SlotKind.IMAGE }.map { it.index })
        val two = all.copy(images = 2)
        assertEquals(listOf(0, 1), s.visible(two).filter { it.kind == SlotKind.IMAGE }.map { it.index })
        assertEquals(emptyList<SlotId>(), s.hidden(two))
        assertEquals(listOf(SlotId(SlotKind.IMAGE, 1)), s.hidden(all.copy(images = 1)))
    }

    @Test fun `clearing closes the gap and uploads find their value by token`() {
        var s = InputSlots().put(SlotId(SlotKind.IMAGE), img("a")).put(SlotId(SlotKind.IMAGE, 1), img("b").copy(progress = .3f, token = 7))
        s = s.clear(SlotId(SlotKind.IMAGE, 0))
        assertEquals("b.jpg", s[SlotId(SlotKind.IMAGE, 0)]?.name)
        s = s.updateToken(7) { it.copy(progress = null) }
        assertTrue(s[SlotId(SlotKind.IMAGE, 0)]!!.ready)
        assertEquals(s, s.updateToken(99) { it.copy(name = "x") })
    }

    @Test fun `the request carries only ready slots the tier takes`() {
        val s = InputSlots()
            .put(SlotId(SlotKind.START), img("start"))
            .put(SlotId(SlotKind.MIDDLE), img("mid"))
            .put(SlotId(SlotKind.IMAGE), img("bottle").copy(role = "product"))
            .put(SlotId(SlotKind.IMAGE, 1), img("busy").copy(progress = .5f))
            .put(SlotId(SlotKind.VIDEO), vid("walk").copy(use = "camera"))
            .put(SlotId(SlotKind.AUDIO), vid("beat"))
        val r = s.applyTo(SuiteShotRequest(prompt = "x"), all)
        assertEquals("https://x/start.jpg", r.frames?.start?.url)
        assertEquals(1, r.frames?.middle?.size)
        assertNull(r.frames?.end)
        assertEquals(listOf("bottle"), r.references?.images?.map { it.label })
        assertEquals("camera", r.references?.videos?.single()?.use)
        assertEquals("c/beat.mp4", r.references?.audio?.audio?.key)
        val f = s.applyTo(SuiteShotRequest(prompt = "x"), framesOnly)
        assertNull(f.references)
        assertNull(f.frames?.middle)
        assertEquals(null, InputSlots().applyTo(SuiteShotRequest(prompt = "x"), all).frames)
        // Wire: nulls are left out, so a request without slots is unchanged.
        val json = Json { explicitNulls = false; encodeDefaults = false }
        assertFalse(json.encodeToString(SuiteShotRequest.serializer(), InputSlots().applyTo(SuiteShotRequest(prompt = "x"), all)).contains("frames"))
    }

    @Test fun `notes for frames that can't combine with references and for unused inputs`() {
        val s = InputSlots().put(SlotId(SlotKind.START), img("s")).put(SlotId(SlotKind.IMAGE), img("r"))
        assertNull(s.note(all))
        assertEquals("On this quality the frames carry the look · references aren't used", s.note(all.copy(framesWithRefs = false)))
        assertEquals("1 input not used on this quality", s.note(framesOnly))
    }

    @Test fun `the catalog's inputs decode, older servers fall back to the flags, the owner's engine has its own`() {
        val json = Json { ignoreUnknownKeys = true }
        val t = json.decodeFromString(SuiteTier.serializer(), """{"id":"hd","inputs":{"start":true,"end":false,"middle":8,"images":6,"videos":3,"audio":true,"framesWithRefs":true},
            "models":[{"model":"veo-3.1-lite","inputs":{"start":true,"end":true,"middle":0,"images":0,"videos":0,"audio":false,"framesWithRefs":false}}]}""")
        assertEquals(8, t.slots.middle)
        assertFalse(t.slots.end)
        assertEquals(0, t.slotsFor("veo-3.1-lite").images)
        assertEquals(t.slots, t.slotsFor("unknown"))
        val old = json.decodeFromString(SuiteTier.serializer(), """{"id":"draft","canKeyframes":true,"canReferences":false}""")
        assertEquals(SuiteInputs(start = true, end = true), old.slots)
    }

    @Test fun `demo mode's catalog has inputs per tier and uploads media without a server`() = runBlocking {
        val fake = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val cat: SuiteCatalog = fake.suiteCatalog()
        assertTrue(cat.tiers.all { it.inputs != null && it.slots.start })
        assertEquals(8, cat.tier("standard")!!.slots.middle)
        val ref = fake.uploadSuiteMedia("walk.mp4", ByteArray(4), "video/mp4")
        assertTrue(ref.key!!.startsWith("c/") && ref.key!!.endsWith(".mp4"))
    }
}
