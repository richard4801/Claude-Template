package studio.muse.app

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditListDto
import studio.muse.app.data.EditedVideo
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.Take
import studio.muse.app.data.editTargetFor
import studio.muse.app.data.editable
import studio.muse.app.platform.SourceInfo
import studio.muse.app.platform.exportPlan
import studio.muse.core.EditSegment
import studio.muse.core.VideoEdit
import java.io.File
import java.net.ServerSocket
import java.util.Collections

/** The video editor's data side: the export plan, the edit-list JSON (plans/video-editor.md) and the save call. */
class VideoEditorTest {
    private val info2k = SourceInfo(10.0, 1440, 2560, 30.0, hasAudio = true, bitrate = 18_000_000)

    @Test fun exportPlanKeepsQualityAndMapsEverySegment() {
        val e = VideoEdit.untouched(10.0).split(3.0)!!.split(4.0)!!.delete(1)!!.speed(1, 2.0)!!.muteSegment(0, true)!!
        val p = exportPlan(e, info2k)
        assertTrue(p.withAudio)
        assertEquals(2, p.items.size)
        assertEquals(0L, p.items[0].startMs); assertEquals(3000L, p.items[0].endMs)
        assertEquals(1f, p.items[0].speed); assertTrue("muted part gets silence", p.items[0].removeAudio); assertNull(p.items[0].dropToFps)
        assertEquals(4000L, p.items[1].startMs); assertEquals(10_000L, p.items[1].endMs)
        assertEquals(2f, p.items[1].speed); assertFalse(p.items[1].removeAudio)
        assertEquals("faster parts are thinned back to the source fps", 30f, p.items[1].dropToFps)
        assertEquals(18_000_000, p.bitrate)
        assertEquals(3.0 + 3.0, p.expectedSec, 1e-9)
    }

    @Test fun exportPlanWithoutSound() {
        val muted = exportPlan(VideoEdit.untouched(5.0).muteAll(true)!!, info2k)
        assertFalse(muted.withAudio); assertTrue(muted.items.all { it.removeAudio })
        val silentSource = exportPlan(VideoEdit.untouched(5.0), info2k.copy(hasAudio = false))
        assertFalse(silentSource.withAudio)
        // Slow parts keep every frame (no drop effect); bitrate is clamped.
        val slow = exportPlan(VideoEdit.untouched(5.0).speed(null, 0.5)!!, info2k.copy(bitrate = 500_000))
        assertNull(slow.items[0].dropToFps); assertEquals(2_000_000, slow.bitrate); assertEquals(10.0, slow.expectedSec, 1e-9)
    }

    @Test fun editListJsonMatchesTheContract() {
        val e = VideoEdit(10.0, listOf(EditSegment(0.5, 3.0), EditSegment(4.0, 9.8, 0.75, muted = true)), mute = false)
        val dto = EditListDto.of("take_1", e)
        val json = Json { encodeDefaults = true; explicitNulls = false }.encodeToString(EditListDto.serializer(), dto)
        val o = Json.parseToJsonElement(json).jsonObject
        assertEquals(setOf("version", "sourceTakeId", "sourceDurationSec", "segments", "mute"), o.keys)
        assertEquals("1", o["version"]!!.jsonPrimitive.content)
        val s1 = o["segments"]!!.jsonArray[1].jsonObject
        assertEquals(setOf("inSec", "outSec", "speed", "muted"), s1.keys)
        assertEquals(setOf("inSec", "outSec", "speed"), o["segments"]!!.jsonArray[0].jsonObject.keys)
        // Round trip
        assertEquals(e, Json.decodeFromString(EditListDto.serializer(), json).toEdit())
    }

    @Test fun reopeningAnEditedVersionLoadsItsCutsOnTheSource() {
        val src = Take("t_src", "take", "j1", 1, 1, "Beach", "HD", videoUrl = "https://x/uploads/c/a.mp4", durationSec = 10.0)
        val dto = EditListDto.of("t_src", VideoEdit.untouched(10.0).split(5.0)!!.delete(1)!!)
        val ver = Take("t_ver", "edit", null, 1, 1, "Beach", "Edited", videoUrl = "https://x/uploads/c/b.mp4", parentTakeId = "t_src", edits = dto)
        val shot = Take("t_shot", "shot", null, 1, 1, "Still", "Photo")
        assertTrue(src.editable); assertTrue(ver.editable); assertFalse(shot.editable)
        val t = editTargetFor(ver, listOf(src, ver))!!
        assertEquals("t_src", t.source.id); assertEquals(dto, t.initial)
        // Source deleted: the version's own video, fresh.
        val alone = editTargetFor(ver, listOf(ver))!!
        assertEquals("t_ver", alone.source.id); assertNull(alone.initial)
        assertNull(editTargetFor(shot, listOf(shot)))
    }

    @Test fun saveTakeVersionUploadsThenCreatesTheVersion() = runBlocking {
        val calls = Collections.synchronizedList(mutableListOf<String>())
        val bodies = Collections.synchronizedMap(mutableMapOf<String, String>())
        var n = 0
        lateinit var base: String
        val srv = MiniHttp { method, path, headers, body ->
            calls += "$method $path"
            when {
                path == "/v1/uploads/presign" -> {
                    val kind = Json.parseToJsonElement(String(body)).jsonObject["kind"]!!.jsonPrimitive.content
                    val id = "up_${kind}_${n++}"
                    """{"uploadId":"$id","method":"PUT","url":"$base/put/$id","headers":{"content-type":"${if (kind == "clip") "video/mp4" else "image/jpeg"}"}}"""
                }
                path.startsWith("/put/") -> { bodies[path] = "${body.size}:${headers["authorization"] ?: "no-auth"}"; "" }
                path == "/v1/takes/t_src/versions" -> {
                    bodies["version"] = String(body)
                    """{"id":"t_new","kind":"edit","title":"Beach","label":"Edited","parentTakeId":"t_src","videoUrl":"/uploads/c/up_clip_0.mp4","thumb":{"url":"/uploads/u/up_image_1.jpg"},"durationSec":6.0,"width":1440,"height":2560,"edits":${Json.parseToJsonElement(String(body)).jsonObject["edits"]}}"""
                }
                else -> null
            }
        }
        base = "http://127.0.0.1:${srv.port}"
        try {
            val api = HttpMuseApi(base)
            api.setToken("secret-token")
            val f = File.createTempFile("edit", ".mp4").apply { writeBytes(ByteArray(300_000) { 1 }); deleteOnExit() }
            val edit = VideoEdit.untouched(10.0).split(3.0)!!.split(4.0)!!.delete(1)!!.speed(1, 2.0)!!
            val progress = mutableListOf<Float>()
            val t = api.saveTakeVersion("t_src", EditedVideo(f, byteArrayOf(9, 9, 9), 6.0, 1440, 2560, 30.0), EditListDto.of("t_src", edit)) { progress += it }
            assertEquals(listOf("POST /v1/uploads/presign", "PUT /put/up_clip_0", "POST /v1/uploads/presign", "PUT /put/up_image_1", "POST /v1/takes/t_src/versions"), calls)
            assertEquals("300000:no-auth", bodies["/put/up_clip_0"]) // streamed, and never our token to storage
            assertEquals("3:no-auth", bodies["/put/up_image_1"])
            val sent = Json.parseToJsonElement(bodies["version"]!!).jsonObject
            assertEquals("up_clip_0", sent["uploadId"]!!.jsonPrimitive.content)
            assertEquals("up_image_1", sent["thumbUploadId"]!!.jsonPrimitive.content)
            assertEquals("6.0", sent["durationSec"]!!.jsonPrimitive.content)
            assertEquals(2, (sent["edits"] as JsonObject)["segments"]!!.jsonArray.size)
            assertEquals("edit", t.kind); assertEquals("t_src", t.parentTakeId)
            assertEquals("$base/uploads/c/up_clip_0.mp4", t.videoUrl)
            assertEquals(edit, t.edits!!.toEdit())
            assertEquals(1f, progress.last()); assertTrue(progress.zipWithNext().all { (a, b) -> b >= a })
        } finally { srv.close() }
    }
}

/** A tiny HTTP/1.1 server for client tests (one request per connection). [handle] returns the JSON body, or null for 404. */
private class MiniHttp(private val handle: (String, String, Map<String, String>, ByteArray) -> String?) : AutoCloseable {
    private val sock = ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
    val port get() = sock.localPort
    private val thread = Thread {
        while (!sock.isClosed) {
            val c = runCatching { sock.accept() }.getOrNull() ?: break
            c.use { s ->
                val input = java.io.BufferedInputStream(s.getInputStream())
                fun line(): String { val b = StringBuilder(); while (true) { val ch = input.read(); if (ch < 0 || ch == '\n'.code) break; if (ch != '\r'.code) b.append(ch.toChar()) }; return b.toString() }
                val (method, path) = line().split(" ").let { it[0] to it[1].substringBefore('?') }
                val headers = mutableMapOf<String, String>()
                while (true) { val l = line(); if (l.isEmpty()) break; headers[l.substringBefore(':').trim().lowercase()] = l.substringAfter(':').trim() }
                val len = headers["content-length"]?.toInt() ?: 0
                val body = ByteArray(len); var off = 0
                while (off < len) { val r = input.read(body, off, len - off); if (r < 0) break; off += r }
                val out = handle(method, path, headers, body)
                val bytes = (out ?: "").toByteArray()
                val status = if (out == null) "404 Not Found" else "200 OK"
                s.getOutputStream().apply {
                    write("HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    write(bytes); flush()
                }
            }
        }
    }.apply { isDaemon = true; start() }
    override fun close() { sock.close() }
}
