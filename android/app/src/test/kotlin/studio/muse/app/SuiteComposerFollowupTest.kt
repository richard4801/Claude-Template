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
}
