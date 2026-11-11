package studio.muse.app

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.CreateOutfitRequest
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Outfit
import studio.muse.app.data.OutfitPictures
import studio.muse.app.data.SampleData
import studio.muse.core.PhotoPrices
import studio.muse.core.PhotoPricing

/** Outfits with their own face close-ups (plans/outfit-faces.md): the 7 pictures, the viewer's order, prices, the demo. */
class OutfitFacesTest {
    private fun ref(n: String) = ImageRef.asset(n)

    @Test fun sevenPicturesInOrderBodyThenFaces() {
        val o = Outfit("o", "m", "Linen shirt", angles = listOf(ref("f"), ref("t"), ref("s"), ref("b")), faces = listOf(ref("ff"), ref("ft"), ref("fs")))
        assertEquals(listOf("f", "t", "s", "b", "ff", "ft", "fs"), OutfitPictures.all(o).map { it?.asset })
        assertEquals(listOf("Front", "¾", "Side", "Back", "Face front", "Face ¾", "Face side"), OutfitPictures.LABELS)
        assertEquals(listOf("front", "tq", "side", "back", "face", "faceTq", "profile"), OutfitPictures.KEYS)
        assertEquals((0 until 7).toList(), OutfitPictures.shown(OutfitPictures.all(o)).map { it.first })
        assertEquals(6, OutfitPictures.pageOf(OutfitPictures.all(o), 6)) // "Face side · 7 of 7"
    }

    @Test fun viewerSkipsMissingPictures() {
        // An older outfit: no faces at all, and its side came back empty.
        val old = Outfit("o", "m", "Green set", angles = listOf(ref("f"), ref("t"), null, ref("b")))
        val all = OutfitPictures.all(old)
        assertEquals(7, all.size)
        assertEquals(listOf(0, 1, 3), OutfitPictures.shown(all).map { it.first })
        assertEquals(2, OutfitPictures.pageOf(all, 3)) // the back is the 3rd page
        assertTrue(OutfitPictures.noFaces(old))
        // A face ¾ that failed: the face side is 6 of 6.
        val partial = old.copy(angles = listOf(ref("f"), ref("t"), ref("s"), ref("b")), faces = listOf(ref("ff"), null, ref("fs")))
        assertEquals(listOf(0, 1, 2, 3, 4, 6), OutfitPictures.shown(OutfitPictures.all(partial)).map { it.first })
        assertEquals(5, OutfitPictures.pageOf(OutfitPictures.all(partial), 6))
        assertEquals(2, OutfitPictures.madeFaces(partial))
    }

    @Test fun pricesIncludeTheFaces() {
        val p = PhotoPrices()
        assertEquals(PhotoPricing.outfitSet(p) + 3 * p.perEdit, OutfitPictures.createEstimate(p, "describe", keeping = false), 1e-9)
        assertEquals(PhotoPricing.outfitSet(p) + 3 * p.perEdit, OutfitPictures.createEstimate(p, "photo", keeping = false), 1e-9)
        assertEquals(7 * p.perEdit, OutfitPictures.createEstimate(p, "describe", keeping = true), 1e-9)
        assertEquals(3 * p.perEdit, OutfitPictures.createEstimate(p, "own", keeping = false), 1e-9)
        assertEquals(0.09, OutfitPictures.facesEstimate(p, Outfit("o", "m", "x")), 1e-9)
        assertEquals(p.perEdit, OutfitPictures.redoEstimate(p, 5), 1e-9)
        assertEquals(PhotoPricing.newShot(p, 1.0, p.maxRefs), OutfitPictures.redoEstimate(p, 0), 1e-9)
    }

    @Test fun demoMakesFacesAddsThemAndRedoes() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 0)
        // A new outfit comes with its 3 face close-ups.
        val o = api.createOutfit(CreateOutfitRequest(SampleData.DEMO, "Linen shirt", "describe", "White linen shirt"))
        testScheduler.advanceTimeBy(1_000); testScheduler.runCurrent()
        val made = api.listOutfits().first { it.id == o.id }
        assertEquals(7, OutfitPictures.shown(OutfitPictures.all(made)).size)
        // An older outfit: Add face close-ups makes the 3 for 3 edits.
        val r = api.addOutfitFaces(SampleData.CRYSTAL)
        assertEquals(3 * PhotoPrices().perEdit, r.cost, 1e-9)
        testScheduler.advanceTimeBy(1_000); testScheduler.runCurrent()
        assertEquals(3, OutfitPictures.madeFaces(api.listOutfits().first { it.id == SampleData.CRYSTAL }))
        // Redo one face: one edit.
        assertEquals(PhotoPrices().perEdit, api.redoOutfit(SampleData.CRYSTAL, "faceTq").cost, 1e-9)
    }
}
