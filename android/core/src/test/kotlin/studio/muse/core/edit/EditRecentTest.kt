package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset

/** Continue a draft (owner, 2026-11-12): the place's JSON matches the Mac and the server, the recent list, the phone's store, missing media. */
class EditRecentTest {
    private fun project(name: String = "pip text image look"): EditProject =
        EditJson.parse(Fixtures.load("projects.json").arr.first { it.obj["name"]!!.str == name }.obj["project"]!!)

    @Test fun placeRoundTripsAndReadsTheMacAndServerShape() {
        val p = EditPlace(playhead = 2.5, zoom = 120.0, tab = "audio", selection = "c1", safeArea = "reels", title = "Beach walk")
        assertEquals(p, EditPlace.of(Json.parseToJsonElement(p.toJson().toString())))
        // As the server sends it: "off" stored as null, `at` stamped, unknown fields and odd types ignored.
        val server = EditPlace.of(Json.parseToJsonElement("""{"playhead":1.25,"zoom":"x","binTab":"uploads","safeArea":null,"at":1794500000000,"extra":[1]}"""))!!
        assertEquals(1.25, server.playhead!!, 1e-9)
        assertNull(server.zoom)
        assertEquals("uploads", server.binTab)
        assertEquals("off", server.safeArea)
        assertEquals(PreviewView.CLEAN, server.view)
        assertEquals(1794500000000L, server.at)
        assertNull(EditPlace.of(Json.parseToJsonElement("[1]")))
        assertNull(EditPlace(zoom = 1.0).view) // not saved: keep the device's own choice
        assertEquals(PreviewView.TIKTOK, EditPlace(safeArea = "tiktok").view)
        assertTrue(p.copy(at = 5).samePlace(p))
    }

    @Test fun recentListsTheLastWorkedOnFirst() {
        val titles = mapOf("take_a" to "Café review")
        val sessions = listOf(
            RecentSession("es_1", "take_a", updatedAt = 1_000),
            RecentSession("es_2", "take_gone", updatedAt = 500, place = EditPlace(at = 3_000)), // left later than es_1 changed
            RecentSession("es_3", "take_a", status = "closed", updatedAt = 9_000),
            RecentSession("es_4", BLANK_SOURCE, updatedAt = 9_500, emptyBlank = true), // "New" pressed and left
        )
        val items = EditRecent.items(sessions, emptyList()) { titles[it] }
        assertEquals(listOf("es_2", "es_1"), items.map { it.id })
        assertEquals(EditRecent.UNTITLED, items[0].title) // its take is gone: still listed
        assertEquals("Café review", items[1].title)
        assertEquals("es_1", items[1].sessionId)
    }

    @Test fun thePhonesEntriesJoinTheList() {
        val p = EditJson.encode(project())
        val items = EditRecent.items(
            listOf(RecentSession("es_1", "take_a", updatedAt = 1_000)),
            listOf(
                EditRecentEntry("take_a", sessionId = "es_1", place = EditPlace(playhead = 4.0), savedAt = 5_000),
                EditRecentEntry("take_x", sessionId = "es_closed", savedAt = 9_000),
                EditRecentEntry("take_m", project = p, title = "Member cut", savedAt = 4_000),
                EditRecentEntry("take_n", savedAt = 8_000), // nothing to reopen
            ),
        ) { null }
        assertEquals(listOf("es_1", "local:take_m"), items.map { it.id })
        assertEquals(5_000L, items[0].lastEditedAt)
        assertEquals(4.0, items[0].place!!.playhead!!, 1e-9)
        assertEquals(5_000L, items[0].place!!.at)
        assertEquals("Member cut", items[1].title)
        assertNull(items[1].sessionId)
    }

    @Test fun theStoreKeepsTheNewestPerEditAndSurvivesARestart() {
        val p = EditJson.encode(project())
        var list = emptyList<EditRecentEntry>()
        list = EditRecent.saved(list, EditRecentEntry("take_a", project = p, place = EditPlace(playhead = 1.0), title = "A", savedAt = 1))
        list = EditRecent.saved(list, EditRecentEntry("take_b", project = p, title = "B", savedAt = 2))
        list = EditRecent.saved(list, EditRecentEntry("take_a", project = p, place = EditPlace(playhead = 3.0), title = "A", savedAt = 3))
        val again = EditRecent.decode(EditRecent.encode(list)) // the file read back after the app restarted
        assertEquals(listOf("A", "B"), again.map { it.title })
        assertEquals(3.0, again[0].place.playhead!!, 1e-9)
        assertEquals(project(), EditJson.parse(again[0].project as JsonObject))
        repeat(20) { i -> list = EditRecent.saved(list, EditRecentEntry("t$i", savedAt = 10L + i)) }
        assertEquals(EditRecent.KEPT, list.size)
        assertEquals(emptyList<EditRecentEntry>(), EditRecent.decode("not json"))
        assertEquals(emptyList<EditRecentEntry>(), EditRecent.decode(null))
    }

    @Test fun missingMediaIsMarkedNotFatal() {
        val p = project()
        val used = p.tracks.flatMap { it.items }.mapNotNull { when (it) { is VideoClip -> it.asset; is ImageItem -> it.asset; is AudioClip -> it.asset; else -> null } }.toSet()
        val media = p.assets.filter { it.id in used && (it.take != null || it.upload != null) && it.kind != AssetKind.LUT }.map { it.id }
        assertTrue(media.isNotEmpty())
        assertEquals(emptySet<String>(), EditRecent.missingAssets(p, media.toSet()))
        assertEquals(setOf(media.first()), EditRecent.missingAssets(p, media.drop(1).toSet()))
        val extra = p.copy(assets = p.assets + Asset("unused", AssetKind.VIDEO, upload = "u9", durationSec = 3.0))
        assertTrue("unused" !in EditRecent.missingAssets(extra, media.toSet()))
    }

    @Test fun lastEditedText() {
        val now = 1_794_500_000_000L // Thu 12 Nov 2026, 16:13 UTC
        fun ago(s: Long) = EditRecent.lastEditedText(now - s * 1000, now, ZoneOffset.UTC)
        assertEquals("Just now", ago(20))
        assertEquals("5 min ago", ago(300))
        assertEquals("3 h ago", ago(3 * 3600))
        assertEquals("Yesterday", ago(20 * 3600))
        assertEquals("Monday", ago(3 * 86_400))
        assertEquals("13 Oct", ago(30 * 86_400))
        assertEquals("8 Oct 2025", ago(400 * 86_400))
    }
}
