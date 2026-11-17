package studio.muse.app

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Outfit
import studio.muse.app.data.OutfitPictures
import studio.muse.app.data.SampleData

/** Upload picture into an outfit slot (owner, 2026-11-17: "I shouldn't need to generate if I already have it"). */
class OutfitUploadSlotTest {
    private fun ref(n: String) = ImageRef.asset(n)
    private val mine = ImageRef(url = "https://x/uploads/u/outfit_1.jpg")

    @Test fun decodesUploadMarksAndReplacedPictures() {
        val json = Json { ignoreUnknownKeys = true }
        val o = json.decodeFromString(Outfit.serializer(),
            """{"id":"o1","modelId":"m","name":"Linen","angles":[{"asset":"f"},{"asset":"t"},{"url":"https://x/uploads/u/outfit_1.jpg"},{"asset":"b"}],"sources":{"side":"upload"},"replaced":[{"slot":"side","image":{"asset":"s"},"source":"generated","at":1,"by":"u1"}]}""")
        assertTrue(OutfitPictures.isUpload(o, 2))
        assertFalse(OutfitPictures.isUpload(o, 0))
        assertEquals(ref("s"), OutfitPictures.previous(o, 2))
        assertNull(OutfitPictures.previous(o, 3))
        assertEquals("Replace the Face ¾ picture?", OutfitPictures.replaceQuestion(5))
        // An older server sends neither.
        val old = json.decodeFromString(Outfit.serializer(), """{"id":"o2","modelId":"m","name":"Old","angles":[null,null,null,null]}""")
        assertNull(old.sources)
        assertNull(OutfitPictures.previous(old, 0))
    }

    @Test fun withPictureKeepsTheOldOneAndPutsItBack() {
        val o = Outfit("o", "m", "Linen", angles = listOf(ref("f"), ref("t"), ref("s"), ref("b")))
        val up = OutfitPictures.withPicture(o, 2, mine, by = "u1", at = 5)
        assertEquals(mine, up.angles[2])
        assertEquals(mapOf("side" to "upload"), up.sources)
        assertEquals("generated", up.replaced!!.single().source)
        assertNull(up.faces) // a body upload leaves an older outfit without faces
        val back = OutfitPictures.withPicture(up, 2, ref("s"))
        assertEquals(ref("s"), back.angles[2])
        assertNull(back.sources)
        assertEquals(mine, OutfitPictures.previous(back, 2))
        assertEquals("upload", back.replaced!!.single().source)
        // An empty face slot of an older outfit: it gets its faces list.
        val face = OutfitPictures.withPicture(o, 5, mine)
        assertEquals(listOf(null, mine, null), face.faces)
        assertNull(face.replaced)
    }

    @Test fun demoSetsThePictureAndSendsTheOutfitEvent() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 0)
        val events = mutableListOf<ApiEvent>()
        backgroundScope.launch { api.events().collect { events += it } }
        testScheduler.runCurrent()
        val before = OutfitPictures.all(api.listOutfits().first { it.id == SampleData.CRYSTAL })
        val r = api.setOutfitPicture(SampleData.CRYSTAL, "back", mine)
        assertEquals(before[3], r.replaced)
        assertEquals(mine, r.outfit.angles[3])
        assertTrue(OutfitPictures.isUpload(r.outfit, 3))
        assertEquals(r.outfit, api.listOutfits().first { it.id == SampleData.CRYSTAL })
        testScheduler.runCurrent()
        assertTrue(events.any { it.type == "outfit" && it.outfit == r.outfit })
        try {
            api.setOutfitPicture(SampleData.CRYSTAL, "top", mine)
            fail("expected bad_request")
        } catch (e: ApiException) {
            assertEquals("bad_request", e.code)
        }
    }
}
