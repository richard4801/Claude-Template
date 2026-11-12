package studio.muse.app

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Outfit
import studio.muse.app.data.OutfitMove
import studio.muse.app.data.OutfitPictures
import studio.muse.app.data.SampleData

/** Reordering an outfit's 7 pictures (owner, 2026-11-12: "the picture in Side is actually the back"). */
class OutfitReorderTest {
    private fun ref(n: String) = ImageRef.asset(n)

    @Test fun moveMenuListsTheOtherSixSlots() {
        // A set whose face ¾ came back empty.
        val pictures = listOf(ref("f"), ref("t"), ref("s"), ref("b"), ref("ff"), null, ref("fs"))
        val targets = OutfitPictures.moveTargets(pictures, 2)
        assertEquals(listOf(0, 1, 3, 4, 5, 6), targets.map { it.first })
        assertEquals(
            listOf("Swap with Front", "Swap with ¾", "Swap with Back", "Swap with Face front", "Move to Face ¾", "Swap with Face side"),
            targets.map { it.second },
        )
        // An older outfit (no faces): every face slot is a "Move to".
        val old = OutfitPictures.all(Outfit("o", "m", "Green set", angles = listOf(ref("f"), ref("t"), ref("s"), ref("b"))))
        assertEquals(listOf("Move to Face front", "Move to Face ¾", "Move to Face side"), OutfitPictures.moveTargets(old, 0).drop(3).map { it.second })
    }

    @Test fun swapKeepsEveryPicture() {
        val pictures = listOf(ref("f"), ref("t"), ref("s"), ref("b"), null, null, null)
        assertEquals(listOf("f", "t", "b", "s", null, null, null), OutfitPictures.swapped(pictures, 2, 3).map { it?.asset })
        // Into an empty slot: the picture moves and its old slot is empty.
        assertEquals(listOf("f", "t", null, "b", "s", null, null), OutfitPictures.swapped(pictures, 2, 4).map { it?.asset })
        // The same slot or a slot that isn't one of the 7 changes nothing.
        assertEquals(pictures, OutfitPictures.swapped(pictures, 1, 1))
        assertEquals(pictures, OutfitPictures.swapped(pictures, 1, 9))
        assertEquals(OutfitMove("side", "back"), OutfitPictures.move(2, 3))
        assertNull(OutfitPictures.move(2, 2))
        assertNull(OutfitPictures.move(2, 7))
    }

    @Test fun reorderedAppliesMovesInOrder() {
        val o = Outfit("o", "m", "Linen shirt", angles = listOf(ref("f"), ref("t"), ref("s"), ref("b")), faces = listOf(ref("ff"), ref("ft"), ref("fs")))
        val r = OutfitPictures.reordered(o, listOf(OutfitMove("side", "back"), OutfitMove("face", "profile")))
        assertEquals(listOf("f", "t", "b", "s", "fs", "ft", "ff"), OutfitPictures.all(r).map { it?.asset })
        // An older outfit stays without faces until a picture moves into one.
        val old = Outfit("o", "m", "Green set", angles = listOf(ref("f"), ref("t"), ref("s"), ref("b")))
        assertNull(OutfitPictures.reordered(old, listOf(OutfitMove("side", "back"))).faces)
        val moved = OutfitPictures.reordered(old, listOf(OutfitMove("side", "faceTq")))
        assertEquals(listOf(null, "s", null), moved.faces!!.map { it?.asset })
        assertNull(moved.angles[2])
    }

    @Test fun demoReorderSwapsAndSendsTheOutfitEvent() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 0)
        val events = mutableListOf<ApiEvent>()
        backgroundScope.launch { api.events().collect { events += it } }
        testScheduler.runCurrent()
        // Crystal dress: front, ¾, side = c_face, back = c_front, no faces.
        val before = OutfitPictures.all(api.listOutfits().first { it.id == SampleData.CRYSTAL })
        val r = api.reorderOutfit(SampleData.CRYSTAL, listOf(OutfitMove("side", "back")))
        assertEquals(listOf("side", "back"), r.changed)
        assertEquals(before[3], OutfitPictures.all(r.outfit)[2])
        assertEquals(before[2], OutfitPictures.all(r.outfit)[3])
        assertEquals(r.outfit, api.listOutfits().first { it.id == SampleData.CRYSTAL })
        testScheduler.runCurrent()
        assertTrue(events.any { it.type == "outfit" && it.outfit == r.outfit })
        // Moving into an empty face slot: nothing is lost.
        val r2 = api.reorderOutfit(SampleData.CRYSTAL, listOf(OutfitMove("side", "face")))
        assertEquals(listOf("side", "face"), r2.changed)
        assertNull(r2.outfit.angles[2])
        assertEquals(before[3], r2.outfit.faces?.get(0))
        // An unknown slot is refused.
        try {
            api.reorderOutfit(SampleData.CRYSTAL, listOf(OutfitMove("side", "top")))
            fail("expected bad_request")
        } catch (e: ApiException) {
            assertEquals("bad_request", e.code)
        }
    }
}
