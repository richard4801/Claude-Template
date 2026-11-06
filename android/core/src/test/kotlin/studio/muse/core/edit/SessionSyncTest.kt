package studio.muse.core.edit

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Edit sessions (workstream 3): rebasing a local change on the server's project, Claude's export preset, tagged undo steps. */
class SessionSyncTest {
    private fun o(vararg kv: Pair<String, Int>) = buildJsonObject { kv.forEach { (k, v) -> put(k, JsonPrimitive(v)) } }

    @Test fun rebaseKeepsTheLocalChangeWhenItStillApplies() {
        val synced = o("a" to 1, "b" to 1)
        val local = o("a" to 2, "b" to 1)
        val server = o("a" to 1, "b" to 3)
        val (merged, kept) = SessionSync.rebase(synced, local, server)
        assertTrue(kept)
        assertTrue(JsonPatch.jsonEqual(o("a" to 2, "b" to 3), merged))
    }

    @Test fun rebaseFallsBackToTheServerWhenTheChangeNoLongerFits() {
        val synced = buildJsonObject { put("x", buildJsonObject { put("y", JsonPrimitive(1)) }) }
        val local = buildJsonObject { put("x", buildJsonObject { put("y", JsonPrimitive(2)) }) }
        val server = buildJsonObject { put("z", JsonPrimitive(1)) } // x is gone
        val (merged, kept) = SessionSync.rebase(synced, local, server)
        assertFalse(kept); assertEquals(server, merged)
        // …and when the result would break a rule.
        val (m2, k2) = SessionSync.rebase(o("a" to 1), o("a" to 2), o("a" to 1, "b" to 1)) { false }
        assertFalse(k2); assertEquals(o("a" to 1, "b" to 1), m2)
        // No local change: the server's.
        assertFalse(SessionSync.rebase(o("a" to 1), o("a" to 1), o("a" to 5)).second)
    }

    @Test fun exportPresetNeverTouchesTheDisclosureSwitches() {
        val p = JsonObject(mapOf("ratio" to JsonPrimitive("1:1"), "resolution" to JsonPrimitive("4k"), "fps" to JsonPrimitive(60), "codec" to JsonPrimitive("hevc"),
            "captions" to JsonPrimitive("srt"), "aiLabel" to JsonPrimitive(true), "c2pa" to JsonPrimitive(true)))
        val s = SessionSync.applyExportPreset(ExportSettings(), p)
        assertEquals(ExportShape.SQUARE, s.shape); assertEquals(ExportResolution.UHD, s.resolution); assertEquals(60, s.fps)
        assertEquals(ExportCodec.HEVC, s.codec); assertEquals(CaptionExport.SRT, s.captions)
        assertFalse(s.aiLabel); assertFalse(s.contentCredentials)
        val owners = ExportSettings(aiLabel = true)
        assertTrue(SessionSync.applyExportPreset(owners, JsonObject(mapOf("aiLabel" to JsonPrimitive(false)))).aiLabel)
        assertEquals(owners, SessionSync.applyExportPreset(owners, null))
    }

    @Test fun aRemoteChangeIsCarriedThroughTheUndoStatesNotUndone() {
        val a = EditProject(2, "t", Canvas(1080, 1920, 30.0, "#000000"),
            listOf(Asset("src", AssetKind.VIDEO, take = "t", durationSec = 10.0)), listOf(Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "src", 0.0, 10.0, 1.0)))))
        val h = ProjectHistory(a)
        val split = a.splitAt(4.0)!!
        h.apply(split)
        // Elsewhere: the background changed. Every state gets it; undo takes back only the split.
        val bg: (EditProject) -> EditProject? = { it.copy(canvas = it.canvas.copy(background = "#111111")) }
        assertTrue(h.rebase(bg(split)!!, bg))
        h.undo()
        assertEquals(bg(a), h.current)
        h.redo()
        assertEquals(bg(split), h.current)
        // A state the change doesn't fit is dropped with everything older.
        h.rebase(h.current.copy(canvas = h.current.canvas.copy(fps = 25.0))) { null }
        assertFalse(h.canUndo)
    }

    @Test fun historyStepsCarryTheirTagsThroughUndoAndRedo() {
        val a = EditProject(2, "t", Canvas(1080, 1920, 30.0, "#000000"),
            listOf(Asset("src", AssetKind.VIDEO, take = "t", durationSec = 10.0)), listOf(Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "src", 0.0, 10.0, 1.0)))))
        val h = ProjectHistory(a)
        val b = a.copy(canvas = a.canvas.copy(background = "#111111"))
        val c = b.copy(canvas = b.canvas.copy(background = "#222222"))
        h.apply(b, tag = 7L); h.apply(c)
        assertNull(h.currentTag)
        h.undo(); assertEquals(7L, h.currentTag); assertEquals(b, h.current)
        h.undo(); assertNull(h.currentTag); assertEquals(a, h.current)
        h.redo(); assertEquals(7L, h.currentTag)
        h.redo(); assertNull(h.currentTag); assertEquals(c, h.current)
    }
}
