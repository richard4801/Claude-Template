package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.Clip
import studio.muse.app.data.ClipAudio
import studio.muse.app.data.ClipMeta
import studio.muse.app.data.ClipRules
import studio.muse.app.data.Cond
import studio.muse.app.data.Drafts
import studio.muse.app.data.ErrorText
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakePromptLibrary
import studio.muse.app.data.FakePromptScripts
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.UploadMode
import studio.muse.app.data.VideoDraft
import studio.muse.app.ui.screens.ScriptText
import java.net.ServerSocket

/** Prompt scripts (plans/api.md "Prompt scripts"): the HTTP client's JSON, the demo fake, the wording and the speaking switch. */
@OptIn(ExperimentalCoroutinesApi::class)
class PromptScriptsTest {
    private val shipped = javaClass.getResource("/prompt_scripts.json")!!.readText()
    private val titles = FakePromptLibrary.DEFAULTS.prompts.associate { it.key to it.title }

    // ---------------------------------------------------------------- HTTP client against canned server answers
    private lateinit var server: ServerSocket
    private val bodies = java.util.concurrent.ConcurrentHashMap<String, String>()
    private val routes = mutableListOf<Pair<String, (String, String) -> Pair<Int, String>>>()
    private lateinit var api: HttpMuseApi

    /** A tiny HTTP/1.1 server (one request per connection) with canned answers by exact path. */
    private fun serve(sock: java.net.Socket) = sock.use { so ->
        val input = java.io.BufferedInputStream(so.getInputStream())
        fun line(): String { val b = StringBuilder(); while (true) { val c = input.read(); if (c < 0 || c == '\n'.code) break; if (c != '\r'.code) b.append(c.toChar()) }; return b.toString() }
        val (method, path) = line().split(" ").let { it[0] to it[1].substringBefore('?') }
        var len = 0
        while (true) { val h = line(); if (h.isEmpty()) break; if (h.lowercase().startsWith("content-length:")) len = h.substringAfter(':').trim().toInt() }
        val body = ByteArray(len).also { var off = 0; while (off < len) { val n = input.read(it, off, len - off); if (n < 0) break; off += n } }.decodeToString()
        bodies["$method $path"] = body
        val (code, out) = routes.firstOrNull { it.first == path }?.second?.invoke(method, body) ?: (404 to """{"error":"no","code":"not_found"}""")
        val bytes = out.toByteArray()
        so.getOutputStream().apply {
            write("HTTP/1.1 $code X\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray()); write(bytes); flush()
        }
    }

    @Before fun start() {
        server = ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
        val replicate = Json.parseToJsonElement(shipped).jsonObject["scripts"]!!.jsonArray.first { it.jsonObject["id"]!!.jsonPrimitive.content == "video.replicate" }.toString()
        fun route(path: String, answer: (method: String, body: String) -> Pair<Int, String>) { routes += path to answer }
        route("/v1/prompt-scripts") { method, _ -> if (method == "GET") 200 to shipped else 404 to "{}" }
        route("/v1/prompt-scripts/video.replicate") { _, _ -> 200 to replicate }
        route("/v1/prompt-scripts/video.edit") { method, _ ->
            if (method == "PUT") 400 to """{"error":"\"Who is who\" is locked: only its text can be changed (Settings → Prompts → its block)","code":"script_invalid"}"""
            else 200 to replicate
        }
        route("/v1/prompt-scripts/preview") { _, _ ->
            200 to """{"id":"video.replicate","text":"summary:\nNo lip-sync\n","parts":[{"section":"summary","layer":"summary","kind":"system","text":"No lip-sync","rules":["summary.silent"]}],"fired":["subjects","summary.silent"],"inputs":{"speaking":false,"audioSent":true},"extra":1}"""
        }
        route("/v1/uploads/clips") { _, _ ->
            200 to """{"id":"c1","name":"Talk","durationSec":7.5,"width":1080,"height":1920,"fps":30,"checks":[{"label":"Performer talking","value":"Yes","status":"info"}],"audio":{"kind":"speech","speaking":true,"detected":true}}"""
        }
        route("/v1/jobs") { _, _ -> 500 to """{"error":"stop","code":"stop"}""" }
        Thread { while (!server.isClosed) runCatching { val so = server.accept(); Thread { runCatching { serve(so) } }.start() } }.apply { isDaemon = true }.start()
        api = HttpMuseApi("http://127.0.0.1:${server.localPort}/", UploadMode.MULTIPART)
    }
    @After fun stop() = server.close()

    @Test fun httpParsesTheScriptsListGetSaveResetAndPreview() = runBlocking {
        val list = api.listPromptScripts()
        assertEquals(14, list.scripts.size) // 11 (dressup removed) + the AI suite's suite.shot, suite.camera and suite.recast (workstream 1)
        assertTrue(list.ops.first { it.id == "in" }.types == listOf("enum"))
        assertEquals("Video", list.groups.first { it.id == "video" }.label)
        val v = list.scripts.first { it.id == "video.replicate" }
        assertEquals("sections", v.format)
        assertEquals("bool", v.inputs.first { it.name == "speaking" }.type)
        val silent = v.rules.first { it.id == "summary.silent" }
        assertEquals(listOf(Cond("speaking", "is", JsonPrimitive(false))), silent.conds)
        assertTrue(v.rules.first { it.id == "subjects" }.isLocked)
        assertFalse(v.overridden)
        val photo = list.scripts.first { it.id == "photoshoot" }
        assertEquals("refs", photo.sections.first { it.id == "reference" }.each)
        assertEquals(listOf("refIndex", "guides"), photo.inputs.first { it.name == "refs" }.fields.map { it.name })

        assertEquals("video.replicate", api.getPromptScript("video.edit").id)
        // PUT sends the whole list with "when" and only the flags that are set.
        api.savePromptScript("video.replicate", v.rules.map { if (it.id == "summary") it.copy(enabled = false) else it })
        val sent = Json.parseToJsonElement(bodies["PUT /v1/prompt-scripts/video.replicate"]!!).jsonObject["rules"]!!.jsonArray
        val summary = sent.first { it.jsonObject["id"]!!.jsonPrimitive.content == "summary" }.jsonObject
        assertEquals("false", summary["enabled"].toString())
        assertNull(summary["locked"])
        assertEquals("""[{"input":"speaking","op":"is","value":false}]""", sent.first { it.jsonObject["id"]!!.jsonPrimitive.content == "summary.silent" }.jsonObject["when"].toString())
        assertEquals("true", sent.first { it.jsonObject["id"]!!.jsonPrimitive.content == "subjects" }.jsonObject["locked"].toString())
        // script_invalid: the server's words, shown as-is.
        try { api.savePromptScript("video.edit", emptyList()); fail() } catch (e: ApiException) {
            assertEquals("script_invalid", e.code)
            assertEquals("\"Who is who\" is locked: only its text can be changed (Settings → Prompts → its block)", ErrorText.of(e))
        }
        assertEquals("video.replicate", api.resetPromptScript("video.replicate").id)
        val p = api.previewPromptScript("video.replicate", JsonObject(mapOf("speaking" to JsonPrimitive(false))))
        assertEquals(listOf("subjects", "summary.silent"), p.fired)
        assertEquals("summary.silent", p.parts.single().rules.single())
        assertEquals("""{"id":"video.replicate","inputs":{"speaking":false}}""", bodies["POST /v1/prompt-scripts/preview"])
    }

    @Test fun httpParsesClipAudioAndSendsSpeaking() = runBlocking {
        val clip = api.uploadClip(ClipMeta("Talk", 7.5, 1080, 1920, 30, talking = true), null)
        assertEquals(ClipAudio("speech", true, true), clip.audio)
        try { api.createJob(JobRequest("t", "m", "o", "c1", speaking = false)) } catch (_: ApiException) {}
        assertEquals("false", Json.parseToJsonElement(bodies["POST /v1/jobs"]!!).jsonObject["speaking"].toString())
        try { api.createJob(JobRequest("t", "m", "o", "c1")) } catch (_: ApiException) {}
        assertNull(Json.parseToJsonElement(bodies["POST /v1/jobs"]!!).jsonObject["speaking"])
    }

    // ---------------------------------------------------------------- the demo fake
    @Test fun fakeServesTheServerDefaultsAndSavesResetsValidates() = runTest {
        val api = FakeMuseApi(backgroundScope)
        val list = api.listPromptScripts()
        assertEquals(FakePromptScripts.DEFAULTS.scripts.map { it.id }, list.scripts.map { it.id })
        val s = api.getPromptScript("video.replicate")
        val event = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) { api.events().first { it.type == "promptScript" } }
        val off = api.savePromptScript(s.id, s.rules.map { if (it.id == "summary") it.copy(enabled = false) else it })
        assertTrue(off.overridden)
        assertFalse(off.rules.first { it.id == "summary" }.isOn)
        assertEquals(off, event.await().script)
        // Saving the defaults again clears the override; reset too.
        assertFalse(api.savePromptScript(s.id, s.defaultRules).overridden)
        api.savePromptScript(s.id, s.rules.reversed())
        assertFalse(api.resetPromptScript(s.id).overridden)
        // The server's messages.
        suspend fun invalid(rules: List<studio.muse.app.data.Rule>): String? = try { api.savePromptScript(s.id, rules); null } catch (e: ApiException) { assertEquals("script_invalid", e.code); e.message }
        assertEquals("\"Who is who\" is required and can't be removed", invalid(s.rules.filterNot { it.id == "subjects" }))
        assertEquals("\"Who is who\" is locked: only its text can be changed (Settings → Prompts → its block)", invalid(s.rules.map { if (it.id == "subjects") it.copy(enabled = false) else it }))
        assertEquals("Rule \"Details\": Unknown input \"nope\"", invalid(s.rules.map { if (it.id == "detailed") it.copy(conds = listOf(Cond("nope", "is", JsonPrimitive(true)))) else it }))
        assertEquals("Rule \"Details\": \"Performer is speaking\" is yes or no", invalid(s.rules.map { if (it.id == "detailed") it.copy(conds = listOf(Cond("speaking", "is", JsonPrimitive("x")))) else it }))
        assertEquals("Two rules are called \"summary\"", invalid(s.rules + s.rules.first { it.id == "summary" }))
        try { api.getPromptScript("nope"); fail() } catch (e: ApiException) { assertEquals("not_found", e.code) }
    }

    @Test fun fakePreviewFollowsTheSpeakingInput() = runTest {
        val api = FakeMuseApi(backgroundScope)
        val quiet = api.previewPromptScript("video.replicate", JsonObject(mapOf("speaking" to JsonPrimitive(false))))
        assertTrue("summary.silent" in quiet.fired)
        assertTrue("mouth.silent" in quiet.fired)
        assertFalse("summary" in quiet.fired)
        assertTrue(quiet.text.startsWith("subject_definitions:\n"))
        assertTrue(quiet.text.contains("summary:\n"))
        assertTrue(quiet.text.trimEnd().endsWith("smiling, glancing at the camera"))
        val talking = api.previewPromptScript("video.replicate", JsonObject(mapOf("speaking" to JsonPrimitive(true))))
        assertTrue("summary" in talking.fired && "mouth.speaking" in talking.fired)
        assertFalse("summary.silent" in talking.fired)
        // Unsaved rules: the switched-off rule is left out; invalid ones answer script_invalid.
        val s = api.getPromptScript("video.replicate")
        val noSummary = api.previewPromptScript(s.id, JsonObject(mapOf("speaking" to JsonPrimitive(true))), s.rules.map { if (it.id == "summary") it.copy(enabled = false) else it })
        assertFalse("summary" in noSummary.fired)
        try { api.previewPromptScript(s.id, null, emptyList()); fail() } catch (e: ApiException) { assertEquals("script_invalid", e.code) }
        // Photoshoot: one reference line per sample item.
        assertTrue(api.previewPromptScript("photoshoot", null).fired.contains("refs.guard"))
    }

    @Test fun fakePreviewRepeatsAPerItemValueSlot() = runTest {
        val api = FakeMuseApi(backgroundScope)
        // refs.collage: one piece per panel (first matching rule each), after "; ", as the server assembles it.
        val p = api.previewPromptScript("refs.collage", null)
        assertEquals(listOf("panel.outfit", "panel.ref", "sheet"), p.fired)
        assertEquals("The input image is a reference sheet of numbered panels (\"image N\" below means panel N): panels 1–3 show the person (use her face, hair " +
            "and body exactly); panel 4 shows the outfit to wear; panel 5 guides the pose & framing only; create one new photo, not a collage.", p.text)
        // Item fields are offered (and validated) for a rule in a per-item value slot.
        val s = api.getPromptScript("refs.collage")
        assertTrue(ScriptText.inputsFor(s, "@panels").any { it.first == "item.role" })
        val bad = s.rules.map { if (it.id == "panel.ref") it.copy(conds = listOf(Cond("item.role", "is", JsonPrimitive("nope")))) else it }
        try { api.savePromptScript(s.id, bad); fail() } catch (e: ApiException) { assertEquals("Rule \"Reference panel\": Pick one of person, outfit, product, ref for \"Shows\"", e.message) }
    }

    @Test fun lateClipEventUpdatesTheSelectedClip() {
        val checks = ClipRules.checks(SampleData.sampleMeta)
        val pending = Clip("c1", "Talk", 6.0, 1080, 1920, 30, checks, thumb = studio.muse.app.data.ImageRef(url = "file:///t.jpg"))
        val detected = pending.copy(thumb = null, audio = ClipAudio("speech", true, true))
        val d = VideoDraft().withClip(pending)
        assertFalse(d.speaking)
        val after = d.onClipEvent(detected)
        assertTrue(after.speaking)
        assertEquals(ClipAudio("speech", true, true), after.clip?.audio)
        assertEquals("file:///t.jpg", after.clip?.thumb?.url)
        // The user's own choice wins; another clip's event is ignored.
        val touched = d.toggleSpeaking().toggleSpeaking()
        assertFalse(touched.onClipEvent(detected).speaking)
        assertEquals(ClipAudio("speech", true, true), touched.onClipEvent(detected).clip?.audio)
        assertEquals(d, d.onClipEvent(detected.copy(id = "other")))
        // Picking a clip again clears the touch.
        assertFalse(touched.withClip(pending).speakingTouched)
    }

    @Test fun fakeClipUploadClassifiesTheAudio() = runTest {
        val api = FakeMuseApi(backgroundScope)
        assertEquals(ClipAudio("speech", true, true), api.uploadClip(ClipMeta("Talk", 6.0, 1080, 1920, 30, talking = true), null).audio)
        assertEquals(ClipAudio("music", false, true), api.uploadClip(SampleData.sampleMeta, null).audio)
    }

    // ---------------------------------------------------------------- wording
    @Test fun rulesReadAsSentences() {
        val list = FakePromptScripts.DEFAULTS
        val v = list.scripts.first { it.id == "video.replicate" }
        val t = { k: String -> titles[k] ?: k }
        assertEquals("When Performer is speaking is no → Summary: Draft/Standard/HD · summary (not speaking)",
            ScriptText.sentence(v, list.ops, v.rules.first { it.id == "summary.silent" }, t))
        assertEquals("Always → Subjects: Draft/Standard/HD · subjects", ScriptText.sentence(v, list.ops, v.rules.first { it.id == "subjects" }, t))
        val photo = list.scripts.first { it.id == "photoshoot" }
        assertEquals("When Guides includes Scene → Reference images: ${t("refs.scene")}", ScriptText.sentence(photo, list.ops, photo.rules.first { it.id == "refs.scene" }, t))
        // Item fields only in the place that repeats per item; tests filtered by type.
        assertTrue(ScriptText.inputsFor(photo, "reference").any { it.first == "item.guides" })
        assertFalse(ScriptText.inputsFor(photo, "outfit").any { it.first.startsWith("item.") })
        assertEquals(listOf("is", "isNot", "in", "notIn"), ScriptText.opsFor(list.ops, photo.inputs.first { it.name == "outfitSource" }).map { it.id })
        assertEquals(Cond("lens", "is", JsonPrimitive(0)), ScriptText.newCond(photo, list.ops, "lens", "camera"))
        assertEquals("rule.1", ScriptText.newId(photo.rules))
        // Move within a place: other places keep their order.
        val moved = ScriptText.move(v.rules, "summary", -1)
        assertEquals(listOf("subjects", "summary", "summary.silent"), moved.take(3).map { it.id })
        assertEquals(v.rules, ScriptText.move(v.rules, "subjects", -1))
    }

    // ---------------------------------------------------------------- the "Performer is speaking" switch
    @Test fun speakingSwitchFollowsTheClip() {
        val checks = ClipRules.checks(SampleData.sampleMeta)
        val talking = Clip("c1", "Talk", 6.0, 1080, 1920, 30, checks, audio = ClipAudio("speech", true, true))
        val music = Clip("c2", "Dance", 6.0, 1080, 1920, 30, checks, audio = ClipAudio("music", false, true))
        val unknown = Clip("c3", "Still checking", 6.0, 1080, 1920, 30, checks)
        assertTrue(VideoDraft().withClip(talking).speaking)
        assertFalse(VideoDraft().withClip(unknown).speaking)
        // The user's choice holds until the clip changes, then the new clip's detection wins.
        val switched = VideoDraft().withClip(talking).copy(speaking = false)
        assertFalse(switched.speaking)
        assertTrue(switched.withClip(talking).speaking)
        assertFalse(VideoDraft(speaking = true).withClip(music).speaking)
        assertEquals(false, switched.request("t", "m", "o", "c1", 6.0).speaking)
        assertEquals(true, VideoDraft().withClip(talking).request("t", "m", "o", "c1", 6.0).speaking)
        assertEquals("She talks or sings: her lips follow the clip's sound", VideoDraft.speakingHint(true))
        assertEquals("Her mouth follows the clip; she won't lip-sync to the music", VideoDraft.speakingHint(false))
        // Reset to recommended and Run again.
        val d = Drafts()
        d.video.value = VideoDraft().withClip(talking).copy(speaking = false)
        d.resetVideo()
        assertTrue(d.video.value.speaking)
        val job = Job("j", "t", "m", "Demo", "o", JobRequest("t", "m", "o", "c1", speaking = false), "done", 100.0)
        d.loadJob(job)
        assertFalse(d.video.value.speaking)
        assertNotNull(d.video.value.clip)
    }
}
