package studio.muse.app


import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteLocation
import studio.muse.app.data.SuiteLocationCreate
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.UploadMode
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.ToolSlots


/**
 * The composer's first run against a real server over HTTP (HttpMuseApi on a local server that answers with the real
 * JSON): catalogs old and new decode, every tool's estimate body has only the keys the server's `.strict()` schemas take
 * (plans/api.md "AI suite", server/api/src/suite/plan.ts and camera.ts), and locations work or are quietly absent.
 */
class SuiteHttpFirstRunTest {
    private lateinit var server: java.net.ServerSocket
    private lateinit var api: HttpMuseApi
    private val bodies = mutableMapOf<String, String>()
    private var catalogBody = ""
    private var locationsOn = true
    private var estimateRes = "suite_estimate_member"
    private var rigCheckOn = true
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()

    @Before fun start() {
        // A tiny HTTP/1.1 server on a socket (the JDK's HttpServer isn't on the Android unit-test classpath).
        server = java.net.ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
        Thread {
            while (!server.isClosed) {
                val s = runCatching { server.accept() }.getOrNull() ?: break
                runCatching {
                    s.use { sock ->
                        val input = java.io.BufferedInputStream(sock.getInputStream())
                        fun line(): String { val b = StringBuilder(); while (true) { val c = input.read(); if (c < 0 || c == '\n'.code) break; if (c != '\r'.code) b.append(c.toChar()) }; return b.toString() }
                        val (method, target) = line().split(" ").let { it[0] to it[1] }
                        var len = 0
                        while (true) { val h = line(); if (h.isEmpty()) break; if (h.lowercase().startsWith("content-length:")) len = h.substringAfter(':').trim().toInt() }
                        val body = ByteArray(len).also { var r = 0; while (r < len) { val n = input.read(it, r, len - r); if (n < 0) break; r += n } }.decodeToString()
                        val path = target.substringBefore('?')
                        synchronized(bodies) { bodies["$method $path"] = body }
                        val (code, out) = when {
                            path == "/v1/suite/catalog" -> 200 to catalogBody
                            path == "/v1/suite/shots/estimate" -> 200 to res(estimateRes)
                            path == "/v1/suite/rig-check" && rigCheckOn -> 200 to res("suite_rigcheck_member")
                            path.startsWith("/v1/suite/locations") && !locationsOn -> 404 to """{"error":"Not found","code":"not_found"}"""
                            path == "/v1/suite/locations" && method == "GET" ->
                                200 to """[{"id":"loc_1","name":"Sunlit loft","image":{"url":"/uploads/loft.jpg"},"createdAt":1762300000000}]"""
                            path == "/v1/suite/locations" -> 200 to """{"id":"loc_2","name":"Rooftop","image":{"url":"/uploads/roof.jpg"},"createdAt":1762300000001}"""
                            path.startsWith("/v1/suite/locations/") -> 200 to """{"ok":true}"""
                            else -> 404 to """{"error":"Not found","code":"not_found"}"""
                        }
                        val bytes = out.toByteArray()
                        val head = "HTTP/1.1 $code ${if (code == 200) "OK" else "Not Found"}\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
                        sock.getOutputStream().apply { write(head.toByteArray()); write(bytes); flush() }
                    }
                }
            }
        }.apply { isDaemon = true }.start()
        api = HttpMuseApi("http://127.0.0.1:${server.localPort}", UploadMode.MULTIPART).also { it.setToken("t") }
    }

    @After fun stop() = server.close()

    @Test fun `the rig check comes with the estimate and alone from rig-check, an older server has none`() = runBlocking {
        val req = SuiteShotRequest(prompt = "x", camera = Json.parseToJsonElement("""{"mode":"preset","rig":{"body":"phone","aperture":"f1.4"}}"""))
        // An estimate without `rig` (an older server) decodes to no warnings.
        assertTrue(api.suiteEstimate(req).rig.isEmpty())
        estimateRes = "suite_estimate_rig_member"
        val e = api.suiteEstimate(req)
        assertEquals(listOf("deep_focus", "look_clash"), e.rig.map { it.id })
        assertEquals("tip", e.rig[1].severity); assertTrue(e.rig[1].tip)
        assertEquals("Use Cinema camera", e.rig[0].fix.label)
        // rig-check: the same strict body, the same list shape; `mix: null` stays a null to remove.
        val r = api.suiteRigCheck(req).rig
        checkStrict(bodies["POST /v1/suite/rig-check"]!!)
        assertEquals(listOf("deep_focus", "talk_move"), r.map { it.id })
        assertEquals(JsonNull, r[1].fix.patch["camera"]!!.jsonObject["mix"])
        assertNull(r[1].alt)
        rigCheckOn = false
        try { api.suiteRigCheck(req); throw AssertionError("expected not_found") } catch (x: ApiException) { assertEquals("not_found", x.code) }
    }

    @Test fun `catalogs decode over HTTP, with and without the new fields`() = runBlocking {
        catalogBody = res("suite_catalog_member")
        val cat = api.suiteCatalog()
        assertTrue(cat.enabled)
        assertTrue(ComposerTool.UGC.isLive(cat)); assertFalse(ComposerTool.EXTEND.isLive(cat))
        assertEquals(8, cat.camera.ugcFormats.size)
        assertTrue(cat.camera.focals.isNotEmpty())
        // A server from before tools, ugcFormats and focals: today's behaviour.
        catalogBody = """{"enabled":true,"test":true,"defaultQuality":"draft","tiers":[{"id":"draft","label":"Draft","available":true,"canKeyframes":true,"canReferences":true}],
            "camera":{"bodies":[{"id":"film_35","label":"35mm film"}],"focalLengths":[24,35,50],"eras":[{"id":"1990s","label":"1990s"}],"limits":{"x":1}}}"""
        val old = api.suiteCatalog()
        assertNull(old.tools)
        assertTrue(old.camera.ugcFormats.isEmpty() && old.camera.focals.isEmpty())
        assertTrue(ComposerTool.SHOT.isLive(old)); assertFalse(ComposerTool.UGC.isLive(old))
        assertEquals(listOf(24, 35, 50), studio.muse.app.ui.screens.suite.composer.ComposerCatalog.focalSteps(old.camera))
        assertEquals(6, old.tier("draft")!!.slots.images)
        // Suite off and a member's copy.
        catalogBody = res("suite_catalog_off_owner")
        val off = api.suiteCatalog()
        assertFalse(off.enabled); assertFalse(ComposerTool.SHOT.isLive(off))
        assertTrue(SuiteRules.memberSafe(cat).tiers.all { it.models == null })
    }

    // The keys the server's strict schemas take (plan.ts ShotRequestSchema / CastSchema, camera.ts CameraSpecSchema).
    private val shotKeys = setOf("mode", "cast", "title", "modelId", "outfitId", "prompt", "frames", "references", "duration", "aspectRatio", "quality", "takes",
        "audio", "speaking", "camera", "gradeLook", "seed", "engineModel", "resolution", "clipId", "keepAudio", "direction", "dryRun")
    private val castKeys = setOf("personIndex", "personHint", "personNote", "faceCrop", "characterId", "outfitId", "speaking")
    private val cameraKeys = setOf("mode", "preset", "rig", "lighting", "palette", "move", "mix", "angle", "style", "performance", "guide")
    private val styleKeys = setOf("genre", "era", "tempo", "format")

    private fun checkStrict(body: String) {
        val o = Json.parseToJsonElement(body).jsonObject
        assertTrue("unknown keys ${o.keys - shotKeys}", (o.keys - shotKeys).isEmpty())
        fun noNulls(e: JsonElement) {
            when (e) {
                JsonNull -> throw AssertionError("a null in $body")
                is JsonObject -> e.values.forEach(::noNulls)
                is JsonArray -> e.forEach(::noNulls)
                else -> Unit
            }
        }
        noNulls(o)
        (o["cast"] as? JsonArray)?.forEach { c -> assertTrue((c.jsonObject.keys - castKeys).isEmpty()) }
        (o["camera"] as? JsonObject)?.let { c ->
            assertTrue("camera keys ${c.keys - cameraKeys}", (c.keys - cameraKeys).isEmpty())
            (c["style"] as? JsonObject)?.let { s -> assertTrue((s.keys - styleKeys).isEmpty()) }
        }
        (o["references"] as? JsonObject)?.let { r -> assertTrue((r.keys - setOf("images", "videos", "audio")).isEmpty()) }
    }

    private suspend fun estimateBody(r: SuiteShotRequest): String {
        api.suiteEstimate(r)
        return bodies["POST /v1/suite/shots/estimate"]!!
    }

    @Test fun `every tool's estimate body is what the server's strict schema accepts`() = runBlocking {
        val cat = studio.muse.app.data.FakeSuite().camera
        val inputs = studio.muse.app.data.SuiteInputs(start = true, end = true, images = 6, videos = 3, audio = true, framesWithRefs = true)
        var t = PromptTokens().withText("She walks in ")
        t = t.addMention("character", SampleData.DEMO, "Demo").first
        t = t.addMention("location", "loc_1", "Sunlit loft").first
        t = t.addMove(cat.move("dolly_in")!!).first
        val all = ComposerSettings(body = "film_35", lens = "anamorphic", focalMm = 50, aperture = "f2.8", genre = "ugc", era = "1990s", tempo = "calm", format = "review",
            palette = "golden_warmth", stock = null, lighting = "window", height = "eye", shotSize = "mcu", gradeLook = false)
        val shot = ComposerDraft(tokens = t, settings = all, modelId = SampleData.DEMO, quality = "hd", sound = false, speaking = true)
        val slots = InputSlots().put(SlotId(SlotKind.START), SlotValue("a.jpg", image = ImageRef(url = "/uploads/a.jpg")))
        val locs = listOf(SuiteLocation("loc_1", "Sunlit loft", ImageRef(url = "http://x/uploads/loft.jpg")))
        val b1 = estimateBody(shot.request(slots, inputs, RecastDraft(), locations = locs))
        checkStrict(b1)
        assertTrue(b1.contains("\"role\":\"location\"")); assertTrue(b1.contains("\"format\":\"review\""))
        // Talking and UGC ad.
        val talkOwn = InputSlots().put(ToolSlots.TALK_AUDIO, SlotValue("v.m4a", media = SuiteMediaRef(key = "c/v.m4a")))
        checkStrict(estimateBody(shot.copy(tool = ComposerTool.TALKING).request(slots, inputs, RecastDraft(), talkOwn, locs)))
        val ugcOwn = InputSlots().put(ToolSlots.UGC_PRODUCT, SlotValue("p.jpg", image = ImageRef(url = "/uploads/p.jpg")))
            .put(ToolSlots.UGC_REFAD, SlotValue("ad.mp4", media = SuiteMediaRef(key = "c/ad.mp4")))
        checkStrict(estimateBody(shot.copy(tool = ComposerTool.UGC).request(slots, inputs, RecastDraft(), ugcOwn, locs)))
        // Character swap and Recast with a face crop.
        val recast = RecastDraft(clipId = "clip_1").tapFace(.2f, .3f, 4, 9).first.setCrop(9, ImageRef(url = "/uploads/face.jpg")).update(0) { it.copy(characterId = SampleData.DEMO) }
        checkStrict(estimateBody(shot.copy(tool = ComposerTool.SWAP).request(slots, inputs, RecastDraft(clipId = "clip_1"))))
        val rb = estimateBody(shot.copy(tool = ComposerTool.RECAST).request(slots, inputs, recast))
        checkStrict(rb)
        assertTrue(rb.contains("\"faceCrop\":{\"url\":\"/uploads/face.jpg\"}"))
        // An empty composer (all Auto): no camera at all.
        val empty = estimateBody(ComposerDraft(modelId = SampleData.DEMO).request(InputSlots(), inputs, RecastDraft()))
        checkStrict(empty)
        assertFalse(empty.contains("\"camera\""))
    }

    @Test fun `locations over HTTP, and a server without them`() = runBlocking {
        val list = api.suiteLocations()
        assertEquals("Sunlit loft", list.single().name)
        assertTrue(list.single().image.url!!.startsWith("http://127.0.0.1"))
        val made = api.createSuiteLocation(SuiteLocationCreate("Rooftop", ImageRef(url = "http://x/uploads/roof.jpg")))
        assertEquals("loc_2", made.id)
        assertEquals("""{"name":"Rooftop","image":{"url":"http://x/uploads/roof.jpg"}}""", bodies["POST /v1/suite/locations"])
        api.deleteSuiteLocation("loc_2")
        assertTrue("DELETE /v1/suite/locations/loc_2" in bodies)
        locationsOn = false
        val e = runCatching { api.suiteLocations() }.exceptionOrNull() as ApiException
        assertEquals("not_found", e.code)
    }

    @Test fun `the bundled camera catalog decodes with every visible render id the composer draws`() {
        val cam = Json { ignoreUnknownKeys = true }.decodeFromString(CameraCatalog.serializer(), res("suite_camera"))
        assertEquals(10, cam.bodies.count { it.visible })
        assertTrue(cam.bodies.filter { it.visible }.all { !it.render.isNullOrBlank() })
    }
}
