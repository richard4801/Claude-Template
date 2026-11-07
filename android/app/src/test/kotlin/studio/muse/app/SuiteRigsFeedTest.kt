package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
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
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakeSuiteRigs
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.Model
import studio.muse.app.data.PhotoRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteClock
import studio.muse.app.data.SuiteDraft
import studio.muse.app.data.SuiteDrafts
import studio.muse.app.data.SuiteDraftSerializer
import studio.muse.app.data.SuiteFeedItem
import studio.muse.app.data.SuiteFeedPage
import studio.muse.app.data.SuiteFeedQuery
import studio.muse.app.data.SuiteFeedRules
import studio.muse.app.data.SuiteRig
import studio.muse.app.data.SuiteRigMove
import studio.muse.app.data.SuiteRigView
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.SuiteWireJson
import studio.muse.app.data.Take
import studio.muse.app.data.UploadMode
import studio.muse.app.data.applyDefaultRig
import studio.muse.app.ui.screens.suite.composer.ComposerSettings

/**
 * The new Suite's client pieces (plans/api.md "The new Suite's server pieces", build step 2): saved rigs, a model's
 * default rig, the composer draft per job and photo, and the takes feed. Wire shapes against server-shaped samples, the
 * pure rules, demo mode behaving like server/api (suite-drafts.test.ts), and the HTTP routes on a local stand-in server.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SuiteRigsFeedTest {
    /** Configured like HttpMuseApi's own Json (explicitNulls = false, encodeDefaults = true). */
    private val json = SuiteWireJson

    private val rigJson = """{"body":"film_35","lens":"anamorphic","focalMm":85,"aperture":"f1.4","height":"low","shotSize":"mcu","lighting":"contre_jour","palette":"golden_warmth",
        "gradeLook":true,"genre":"fashion","era":"1990s","tempo":"calm","moves":[{"id":"dolly_in","intensity":0.4}]}"""
    private val draftJson = """{"v":1,"tool":"shot","quality":"draft","aspect":"9:16","duration":5,"takes":2,"sound":true,"speaking":null,"rig":$rigJson,
        "tokens":[{"text":"She walks out to the street "},{"key":3,"move":{"id":"dolly_in","label":"Dolly in"}}],"slots":{"start":null},"futureThing":{"x":[1,2,{"y":"z"}]}}"""

    // ------------------------------------------------------------------ wire shapes

    @Test fun `a rig decodes from the server's shape and encodes without nulls`() {
        val rig = json.decodeFromString(SuiteRig.serializer(), rigJson)
        assertEquals("film_35", rig.body); assertEquals(85.0, rig.focalMm!!, 0.0); assertEquals(true, rig.gradeLook)
        assertEquals(listOf(SuiteRigMove("dolly_in", 0.4)), rig.moves)
        val back = json.encodeToJsonElement(SuiteRig.serializer(), rig).jsonObject
        assertEquals(Json.parseToJsonElement(rigJson).jsonObject.keys, back.keys) // every row, in the server's names
        assertEquals(rig, json.decodeFromJsonElement(SuiteRig.serializer(), back))
        // Auto rows are left out entirely (the server refuses unknown and null fields).
        assertEquals("""{"lighting":"window"}""", json.encodeToString(SuiteRig.serializer(), SuiteRig(lighting = "window")))
        assertEquals("{}", SuiteRig().toJson().toString())
        assertEquals("""{"moves":[{"id":"orbit_left"}]}""", SuiteRig(moves = listOf(SuiteRigMove("orbit_left"))).toJson().toString())
        assertTrue(SuiteRig().isEmpty); assertFalse(SuiteRig(moves = emptyList()).isEmpty)
    }

    @Test fun `rig views, models, jobs and takes decode, absent new fields read as null`() {
        val views = json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(SuiteRigView.serializer()),
            """[{"id":"rig_1","name":"Talking head","rig":{"body":"phone","lighting":"ring_light","moves":[]},"userId":"u1","mine":true,"createdAt":1,"updatedAt":2},
                {"id":"rig_2","name":"Neon night","rig":{"palette":"hyper_neon"},"userId":"u2","mine":false,"createdAt":3,"updatedAt":4}]""")
        assertEquals(listOf("Talking head" to true, "Neon night" to false), views.map { it.name to it.mine })
        assertEquals(emptyList<SuiteRigMove>(), views[0].rig.moves)

        val m = json.decodeFromString(Model.serializer(), """{"id":"m1","name":"Noor Ellis","age":27,"niche":"Beauty","defaultRig":{"body":"film_35","palette":"golden_warmth","moves":[{"id":"orbit_left"}]}}""")
        assertEquals(SuiteRig(body = "film_35", palette = "golden_warmth", moves = listOf(SuiteRigMove("orbit_left"))), m.defaultRig)
        assertNull(json.decodeFromString(Model.serializer(), """{"id":"m1","name":"Noor Ellis","age":27,"niche":"Beauty"}""").defaultRig)

        val job = json.decodeFromString(Job.serializer(), """{"id":"j1","title":"Untitled shot","modelId":"m1","modelName":"Noor Ellis","outfitId":"","state":"running",
            "request":{"engine":"suite","mode":"reference","takes":2,"seconds":5},"draft":$draftJson}""")
        assertEquals("shot", job.draft!!.tool)
        assertEquals(Json.parseToJsonElement(draftJson), job.draft!!.json)
        assertNull(json.decodeFromString(Job.serializer(), """{"id":"j1","title":"x","modelId":"","modelName":"","outfitId":"","state":"done","request":{}}""").draft)

        val take = json.decodeFromString(Take.serializer(), """{"id":"t1","kind":"shot","index":1,"of":4,"title":"Photo · Café","label":"Café · 1","draft":{"tool":"photo","count":4,"aspect":"4:5"}}""")
        assertEquals("photo", take.draft!!.tool); assertEquals(4, take.draft!!.count)
        assertNull(json.decodeFromString(Take.serializer(), """{"id":"t1","title":"x","label":"y"}""").draft)
    }

    @Test fun `a draft with unknown keys round-trips exactly, and its accessors read the bottom bar`() {
        val d = json.decodeFromString(SuiteDraftSerializer, draftJson)
        assertEquals(1, d.v); assertEquals("shot", d.tool); assertEquals("draft", d.quality); assertEquals("9:16", d.aspect)
        assertEquals(5.0, d.duration!!, 0.0); assertEquals(2, d.takes); assertNull(d.count); assertEquals(true, d.sound); assertNull(d.speaking)
        assertEquals("film_35", d.rig!!.body)
        // Encoded with the app's Json (explicitNulls = false): every key, nulls and unknown ones included, comes back.
        val again = json.decodeFromString(SuiteDraftSerializer, json.encodeToString(SuiteDraftSerializer, d))
        assertEquals(d, again)
        assertEquals(Json.parseToJsonElement(draftJson), Json.parseToJsonElement(json.encodeToString(SuiteDraftSerializer, d)))
        assertTrue(json.encodeToString(SuiteDraftSerializer, d).contains("\"speaking\":null"))
        // Sent with a shot: present when set, absent otherwise.
        val withDraft = json.encodeToJsonElement(SuiteShotRequest.serializer(), SuiteShotRequest(prompt = "x", draft = d)).jsonObject
        assertEquals(d.json, withDraft["draft"])
        assertFalse("draft" in json.encodeToJsonElement(SuiteShotRequest.serializer(), SuiteShotRequest(prompt = "x")).jsonObject)
        assertFalse("draft" in json.encodeToJsonElement(PhotoRequest.serializer(), PhotoRequest(SampleData.DEMO)).jsonObject)
        // Built by the composer.
        val made = SuiteDrafts.of("photo", aspect = "4:5", count = 2, rig = SuiteRig(lighting = "window"), extra = mapOf("tokens" to JsonArray(listOf(JsonPrimitive("x")))))
        assertEquals("""{"v":1,"tool":"photo","aspect":"4:5","count":2,"rig":{"lighting":"window"},"tokens":["x"]}""", made.json.toString())
    }

    @Test fun `feed pages decode with every field, and optional ones default`() {
        val page = json.decodeFromString(SuiteFeedPage.serializer(), """{"items":[
            {"id":"j9","kind":"job","status":"running","tool":"shot","jobId":"j9","title":"Untitled shot","modelId":"m1","modelName":"Noor Ellis","createdAt":30,
             "poster":{"url":"/uploads/p.jpg"},"aspect":"9:16","durationSec":5,"takes":2,"price":0.2,"progress":40,"phase":"take 1/2 · Rendering","secondsLeft":31,
             "label":"Shot · Draft · 768p","summary":"9:16, 5 s, 2 takes, sound on"},
            {"id":"j8","kind":"job","status":"failed","tool":"swap","jobId":"j8","title":"Swap","createdAt":20,"price":0.5,"progress":18,"error":"It didn’t finish",
             "errorCode":"provider_failed","refunded":0.5,"takes":1,"summary":"10 s, 1 take"},
            {"id":"t1","kind":"take","status":"done","tool":"shot","jobId":"j7","takeId":"t1","title":"Walk","label":"Draft","createdAt":10,"videoUrl":"/uploads/v.mp4",
             "aspect":"9:16","durationSec":5.04,"index":1,"of":2,"price":0.1,"final":false,"summary":"9:16, 5 s, 2 takes, sound on"},
            {"id":"t2","kind":"photo","status":"done","tool":"photo","takeId":"t2","title":"Photo · Café","label":"Café · 1","createdAt":5,"aspect":"4:5","index":1,"of":4,
             "price":0.03,"final":true,"summary":"4:5, 4 photos"}],"nextCursor":"WzUsInQyIl0"}""")
        assertEquals("WzUsInQyIl0", page.nextCursor)
        val (j, f, t, p) = page.items
        assertTrue(j.isJob); assertEquals(40.0, j.progress!!, 0.0); assertEquals(31.0, j.secondsLeft!!, 0.0); assertEquals(2, j.takes); assertEquals("Shot · Draft · 768p", j.label)
        assertEquals("provider_failed", f.errorCode); assertEquals(0.5, f.refunded!!, 0.0); assertNull(f.modelId); assertNull(f.poster)
        assertEquals("/uploads/v.mp4", t.videoUrl); assertEquals(false, t.final); assertEquals(2, t.of)
        assertTrue(p.isPhoto); assertEquals(true, p.final); assertNull(p.videoUrl); assertNull(p.jobId)
        assertNull(json.decodeFromString(SuiteFeedPage.serializer(), """{"items":[],"nextCursor":null}""").nextCursor)
    }

    @Test fun `the feed query builds comma lists and leaves out what isn't set`() {
        assertEquals(emptyMap<String, String>(), SuiteFeedQuery().params())
        val q = SuiteFeedQuery(tool = listOf("shot", "photo"), status = listOf("done"), model = "m1", cursor = "abc", limit = 20)
        assertEquals(mapOf("tool" to "shot,photo", "status" to "done", "model" to "m1", "cursor" to "abc", "limit" to "20"), q.params())
        assertEquals("tool=shot,photo&status=done&model=m1&cursor=abc&limit=20", q.queryString())
        assertEquals("status=queued,running", SuiteFeedQuery(status = listOf("queued", "running"), model = " ").queryString())
    }

    @Test fun `the summary line and aspect follow the server`() {
        val d = json.decodeFromString(SuiteDraftSerializer, draftJson)
        assertEquals("9:16, 5 s, 2 takes, sound on", SuiteFeedRules.summary(d))
        assertEquals("16:9, 7.5 s, 2 takes, sound off", SuiteFeedRules.summary(SuiteDrafts.of("shot", aspect = "16:9", duration = 7.5, takes = 2, sound = false)))
        assertEquals("4:5, 1 photo", SuiteFeedRules.summary(SuiteDrafts.of("photo", aspect = "4:5", count = 1)))
        assertEquals("9:16, 3 photos", SuiteFeedRules.summary(null, aspect = "9:16", count = 3))
        assertEquals("10 s, 1 take", SuiteFeedRules.summary(null, seconds = 10.0, takes = 1))
        assertEquals("9:16, 10 s, 1 take, sound on", SuiteFeedRules.summary(null, aspect = "9:16", seconds = 10.0, takes = 1, sound = true))
        assertEquals("9:16", SuiteFeedRules.aspectOf(768, 1344))
        assertEquals("16:9", SuiteFeedRules.aspectOf(1920, 1080))
        assertEquals("4:5", SuiteFeedRules.aspectOf(1080, 1350))
        assertNull(SuiteFeedRules.aspectOf(0, 10)); assertNull(SuiteFeedRules.aspectOf(null, 10))
    }

    // ------------------------------------------------------------------ rig ↔ composer, the default-rig rule

    @Test fun `a rig and the composer settings convert both ways, moves aside`() {
        val s = ComposerSettings(body = "film_35", lens = "anamorphic", focalMm = 85, aperture = "f1.4", height = "low", shotSize = "mcu", genre = "fashion", era = "1990s",
            tempo = "calm", format = null, palette = "golden_warmth", stock = null, gradeLook = true, lighting = "contre_jour", preset = "cinematic")
        val rig = SuiteRig.from(s, moves = listOf(SuiteRigMove("dolly_in", 0.4)))
        assertEquals(json.decodeFromString(SuiteRig.serializer(), rigJson), rig)
        assertEquals(s.copy(preset = null), rig.toSettings())
        // All Auto: an empty rig; grading off is kept even without a look.
        assertEquals(SuiteRig(), SuiteRig.from(ComposerSettings()))
        assertEquals(SuiteRig(gradeLook = false), SuiteRig.from(ComposerSettings(gradeLook = false)))
        assertEquals(ComposerSettings(), SuiteRig().toSettings())
        assertEquals(50, SuiteRig(focalMm = 49.6).toSettings().focalMm)
    }

    @Test fun `a default rig fills only the rows still on Auto and never overwrites`() {
        val rig = SuiteRig(body = "film_35", lens = "vintage", lighting = "golden_hour", palette = "golden_warmth", gradeLook = false, era = "1990s", moves = listOf(SuiteRigMove("dolly_in")))
        val user = ComposerSettings(body = "phone", lighting = "window")
        val (s, filled) = applyDefaultRig(rig, user)
        assertEquals("phone", s.body); assertEquals("window", s.lighting) // the user's picks stay
        assertEquals("vintage", s.lens); assertEquals("golden_warmth", s.palette); assertEquals("1990s", s.era); assertEquals(false, s.gradeLook)
        assertEquals(listOf("lens", "palette", "era", "gradeLook"), filled)
        // Nothing left on Auto that the rig sets: nothing applies (no "Applied … · Undo").
        assertEquals(s to emptyList<String>(), applyDefaultRig(rig, s))
        // A look the user picked keeps its grading switch.
        val withLook = ComposerSettings(stock = "bw_film", gradeLook = true)
        assertEquals(true, applyDefaultRig(rig, withLook).first.gradeLook)
        assertEquals("bw_film", applyDefaultRig(rig, withLook).first.stock)
        assertEquals(ComposerSettings() to emptyList<String>(), applyDefaultRig(SuiteRig(), ComposerSettings()))
    }

    // ------------------------------------------------------------------ demo mode (FakeMuseApi) like server/api

    @Test fun `demo rigs - members keep their own, the owner sees all theirs first, edits and deletes any`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        // Demo mode starts with the owner's two rigs and a member's.
        val all0 = api.suiteRigs()
        assertEquals(listOf("Golden film" to true, "Talking head" to true, "Neon night" to false), all0.map { it.name to it.mine })
        api.suiteOwner = false
        assertEquals(listOf("Neon night"), api.suiteRigs().map { it.name })
        val mine = api.createSuiteRig("  Golden 35  ", SuiteRig(body = "film_35", moves = listOf(SuiteRigMove("dolly_in", 0.4))))
        assertEquals("Golden 35", mine.name); assertTrue(mine.mine); assertEquals(FakeSuiteRigs.MEMBER_ID, mine.userId)
        advanceTimeBy(1000)
        val p = api.updateSuiteRig(mine.id, name = "Golden 70s", rig = SuiteRig(era = "1970s"))
        assertEquals("Golden 70s", p.name); assertEquals(SuiteRig(era = "1970s"), p.rig) // rig replaces the whole rig
        assertTrue(p.updatedAt > mine.updatedAt)
        assertEquals(p, api.updateSuiteRig(mine.id)) // nothing sent: unchanged
        assertEquals(listOf("Golden 70s", "Neon night"), api.suiteRigs().map { it.name })
        // Someone else's rig reads as not found to a member…
        expect("not_found") { api.updateSuiteRig("rig_golden", name = "Mine now") }
        expect("not_found") { api.deleteSuiteRig("rig_golden") }
        expect("not_found") { api.updateSuiteRig("rig_nope", name = "x") }
        // …the owner may tidy any rig; their own come first.
        api.suiteOwner = true
        assertEquals("Neon", api.updateSuiteRig("rig_neon", name = "Neon").name)
        assertEquals(listOf(true, true, false, false), api.suiteRigs().map { it.mine })
        api.deleteSuiteRig(mine.id)
        api.suiteOwner = false
        assertEquals(listOf("Neon"), api.suiteRigs().map { it.name })
    }

    @Test fun `demo rigs - names, catalog ids and the 100-per-person cap are checked`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        expect("bad_request", "rig.lens: unknown lens \"fisheye_9000\"") { api.createSuiteRig("x", SuiteRig(lens = "fisheye_9000")) }
        expect("bad_request", "rig.era: unknown era \"2077s\"") { api.createSuiteRig("x", SuiteRig(era = "2077s")) }
        expect("bad_request", "Give the rig a name") { api.createSuiteRig("   ", SuiteRig()) }
        expect("bad_request", "60") { api.createSuiteRig("x".repeat(61), SuiteRig()) }
        expect("bad_request", "focalMm") { api.createSuiteRig("x", SuiteRig(focalMm = 400.0)) }
        expect("bad_request", "moves") { api.createSuiteRig("x", SuiteRig(moves = listOf(SuiteRigMove("dolly_in"), SuiteRigMove("orbit_left"), SuiteRigMove("tilt_up")))) }
        expect("bad_request", "unknown move") { api.createSuiteRig("x", SuiteRig(moves = listOf(SuiteRigMove("moonwalk")))) }
        expect("bad_request", "intensity") { api.createSuiteRig("x", SuiteRig(moves = listOf(SuiteRigMove("dolly_in", 1.5)))) }
        expect("bad_request", "unknown camera body") { api.updateSuiteRig("rig_golden", rig = SuiteRig(body = "vhs_9000")) }
        // Hidden and merged ids are accepted (a member can't pick them, but a rig may carry them).
        api.createSuiteRig("Merged", SuiteRig(body = "super35"))
        assertEquals(60, api.createSuiteRig("y".repeat(60), SuiteRig()).name.length)
        // The cap counts per person: the owner already has 4 here.
        repeat(FakeSuiteRigs.MAX_PER_USER - 4) { api.createSuiteRig("Rig $it", SuiteRig()) }
        expect("too_many_rigs") { api.createSuiteRig("One more", SuiteRig()) }
        api.suiteOwner = false
        api.createSuiteRig("A member's", SuiteRig()) // another person's count
    }

    @Test fun `demo default rig - on the demo model, set, kept by other edits, cleared with null or an all-Auto rig`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val demo = api.listModels().first { it.id == SampleData.DEMO }
        assertEquals(FakeSuiteRigs.DEMO_DEFAULT_RIG, demo.defaultRig)
        assertNull(api.listModels().first { it.id == SampleData.NOOR }.defaultRig)
        val rig = SuiteRig(body = "film_35", palette = "golden_warmth", moves = listOf(SuiteRigMove("orbit_left")))
        api.suiteOwner = false // anyone in the studio may set it
        assertEquals(rig, api.setModelDefaultRig(SampleData.NOOR, rig).defaultRig)
        assertEquals(rig, api.listModels().first { it.id == SampleData.NOOR }.defaultRig)
        expect("bad_request", "defaultRig.body: unknown camera body") { api.setModelDefaultRig(SampleData.NOOR, SuiteRig(body = "vhs_9000")) }
        assertEquals(rig, api.updateModel(SampleData.NOOR, studio.muse.app.data.UpdateModelRequest(name = "Noor")).defaultRig) // untouched
        assertNull(api.setModelDefaultRig(SampleData.NOOR, null).defaultRig)
        api.setModelDefaultRig(SampleData.DEMO, rig)
        assertNull(api.setModelDefaultRig(SampleData.DEMO, SuiteRig()).defaultRig) // all Auto = none
        expect("not_found") { api.setModelDefaultRig("m_nope", rig) }
    }

    @Test fun `demo drafts - kept on the job and every take, on every photo, and a bad one is refused before anything is held`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val draft = json.decodeFromString(SuiteDraftSerializer, draftJson)
        val before = api.balance().balance
        expect("bad_request", "Invalid draft: tool") { api.createSuiteShot(SuiteShotRequest(modelId = SampleData.DEMO, prompt = "x", draft = SuiteDraft(JsonObject(mapOf("tool" to JsonPrimitive("hologram")))))) }
        expect("bad_request", "Invalid draft: tool") { api.createSuiteShot(SuiteShotRequest(modelId = SampleData.DEMO, prompt = "x", draft = SuiteDraft(JsonObject(mapOf("quality" to JsonPrimitive("hd")))))) }
        assertEquals(before, api.balance().balance, 1e-9)
        val job = api.createSuiteShot(SuiteShotRequest(modelId = SampleData.DEMO, prompt = "She walks out to the street.", duration = 5, quality = "draft", takes = 2, draft = draft))
        assertEquals(draft, job.draft)
        assertEquals(draft, api.listJobs().first { it.id == job.id }.draft)
        advanceTimeBy((SuiteClock.total(job.request) / 24 * 1000 * 2).toLong())
        val ts = api.listTakes().filter { it.jobId == job.id }
        assertEquals(2, ts.size)
        ts.forEach { assertEquals(draft, it.draft) }

        val photoDraft = SuiteDrafts.of("photo", aspect = "9:16", count = 2, rig = SuiteRig(lighting = "window"), extra = mapOf("tokens" to JsonArray(listOf(JsonObject(mapOf("text" to JsonPrimitive("A café window seat.")))))))
        val photos = api.createPhotos(PhotoRequest(SampleData.NOOR, prompt = "A café window seat.", count = 2, draft = photoDraft)).takes
        assertEquals(2, photos.size)
        photos.forEach { assertEquals(photoDraft, it.draft) }
        assertNull(api.createPhotos(PhotoRequest(SampleData.NOOR, count = 1)).takes.single().draft)
        expect("bad_request", "Invalid draft: tokens") {
            api.createPhotos(PhotoRequest(SampleData.NOOR, count = 1, draft = SuiteDraft(JsonObject(mapOf("tool" to JsonPrimitive("photo"), "tokens" to JsonPrimitive("nope"))))))
        }
    }

    @Test fun `demo feed - newest first, jobs as one card, each take and photo its own, filters, member-safe`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val draft = json.decodeFromString(SuiteDraftSerializer, draftJson)
        val shot = api.createSuiteShot(SuiteShotRequest(modelId = SampleData.DEMO, prompt = "She walks out.", duration = 5, quality = "draft", takes = 2, draft = draft))
        // While it renders: one running card at the top, with the draft's caption.
        val running = api.suiteFeed().items.first()
        assertEquals(listOf("job", "running", "shot", shot.id), listOf(running.kind, running.status, running.tool, running.jobId))
        assertEquals("9:16, 5 s, 2 takes, sound on", running.summary)
        assertEquals("9:16", running.aspect); assertEquals("Demo model", running.modelName); assertEquals(shot.cost, running.price, 1e-9)
        assertEquals("Shot · Draft · 768p", running.label); assertNotNull(running.secondsLeft)
        advanceTimeBy((SuiteClock.total(shot.request) / 24 * 1000 * 2).toLong())
        advanceTimeBy(1000)
        api.createPhotos(PhotoRequest(SampleData.NOOR, prompt = "A café window seat.", count = 3, draft = SuiteDrafts.of("photo", aspect = "4:5", count = 3)))
        advanceTimeBy(1000)
        val queued = api.createJob(studio.muse.app.data.JobRequest(title = "Queued swap", modelId = SampleData.DEMO, outfitId = SampleData.GREEN, clipId = SampleData.SAMPLE_CLIP, queue = true))

        val page = api.suiteFeed()
        assertNull(page.nextCursor)
        val items = page.items
        val kinds = items.map { "${it.kind}:${it.tool}:${it.status}" }
        assertEquals("job:swap:queued", kinds[0])
        assertEquals(queued.id, items[0].id)
        assertEquals(5, kinds.count { it == "photo:photo:done" }) // 3 new + the demo's 2 older stills
        assertTrue(items.none { it.jobId == shot.id && it.kind == "job" }) // a done job's takes take its place
        val takes = items.filter { it.jobId == shot.id }
        assertEquals(listOf("take", "take"), takes.map { it.kind })
        takes.forEach {
            assertEquals("9:16, 5 s, 2 takes, sound on", it.summary); assertEquals(false, it.final); assertEquals(5.0, it.durationSec!!, 0.0)
            assertEquals("Demo model", it.modelName); assertNotNull(it.poster); assertEquals(it.id, it.takeId)
        }
        val photo = items.first { it.kind == "photo" && it.modelId == SampleData.NOOR }
        assertEquals("4:5, 3 photos", photo.summary); assertEquals("4:5", photo.aspect); assertNull(photo.videoUrl); assertEquals("Noor Ellis", photo.modelName)
        val failed = items.single { it.status == "failed" }
        assertEquals("j0", failed.id); assertNotNull(failed.error); assertEquals(0.19, failed.refunded!!, 1e-9)
        val times = items.map { it.createdAt }
        assertEquals(times.sortedDescending(), times)
        assertFalse(Regex("\\b(replicate|fal|runpod|minimax|kling|seedance|veo|wan-2|ltx|h3)\\b", RegexOption.IGNORE_CASE)
            .containsMatchIn(json.encodeToString(SuiteFeedPage.serializer(), page)))
        // A member sees the same studio-wide feed.
        api.suiteOwner = false
        assertEquals(items, api.suiteFeed().items)
        api.suiteOwner = true

        // Filters: tool, status, model, combined; comma lists.
        suspend fun only(q: SuiteFeedQuery) = api.suiteFeed(q).items.map { "${it.kind}:${it.tool}:${it.status}" }
        assertEquals(setOf("photo:photo:done"), only(SuiteFeedQuery(tool = listOf("photo"))).toSet())
        assertEquals(listOf("job:swap:queued"), only(SuiteFeedQuery(status = listOf("queued"))))
        assertEquals(listOf("job:swap:queued", "job:swap:failed"), only(SuiteFeedQuery(status = listOf("queued", "failed"))))
        assertEquals(setOf("take:shot:done"), only(SuiteFeedQuery(tool = listOf("shot"), status = listOf("done"))).toSet())
        assertEquals(setOf("photo:photo:done"), only(SuiteFeedQuery(model = SampleData.NOOR)).toSet())
        assertEquals(3, only(SuiteFeedQuery(model = SampleData.NOOR)).size)
        expect("bad_request", "status") { api.suiteFeed(SuiteFeedQuery(status = listOf("lost"))) }
        expect("bad_request", "tool") { api.suiteFeed(SuiteFeedQuery(tool = listOf("video"))) }
        // Deleted from Queue: it drops out (and a job's takes with it).
        api.removeJob(queued.id)
        assertEquals(emptyList<String>(), only(SuiteFeedQuery(status = listOf("queued"))))
        api.removeJob(shot.id)
        assertTrue(api.suiteFeed().items.none { it.jobId == shot.id })
    }

    @Test fun `demo feed - a cursor pages through everything exactly once, in order`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        api.createPhotos(PhotoRequest(SampleData.DEMO, count = 4)) // four stills made at the same moment: the id breaks the tie
        val all = api.suiteFeed().items.map { it.id }
        assertTrue(all.size > 6)
        for (limit in listOf(1, 2, 3)) {
            val seen = mutableListOf<String>()
            var cursor: String? = null
            var pages = 0
            do {
                val r = api.suiteFeed(SuiteFeedQuery(limit = limit, cursor = cursor))
                assertTrue(r.items.size <= limit)
                seen += r.items.map { it.id }
                cursor = r.nextCursor
                pages++
            } while (cursor != null && pages < 50)
            assertEquals(all, seen)
            assertEquals((all.size + limit - 1) / limit, pages)
        }
        assertEquals(all.size.coerceAtMost(60), api.suiteFeed(SuiteFeedQuery(limit = 60)).items.size)
        expect("bad_request", "Invalid cursor") { api.suiteFeed(SuiteFeedQuery(cursor = "bm9wZQ")) }
        expect("bad_request", "limit") { api.suiteFeed(SuiteFeedQuery(limit = 500)) }
        expect("bad_request", "limit") { api.suiteFeed(SuiteFeedQuery(limit = 0)) }
    }

    @Test fun `demo feed - the default page is 30 items`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        repeat(8) { api.createPhotos(PhotoRequest(SampleData.DEMO, count = 4)); advanceTimeBy(10) }
        val first = api.suiteFeed()
        assertEquals(30, first.items.size)
        assertNotNull(first.nextCursor)
        val rest = api.suiteFeed(SuiteFeedQuery(cursor = first.nextCursor))
        assertTrue(rest.items.none { it.id in first.items.map(SuiteFeedItem::id) })
    }

    private suspend fun expect(code: String, contains: String? = null, block: suspend () -> Unit) {
        try { block(); fail("expected $code") } catch (e: ApiException) {
            assertEquals(e.message, code, e.code)
            contains?.let { assertTrue("\"${e.message}\" should contain \"$it\"", e.message!!.contains(it)) }
        }
    }
}

/** The new routes over HTTP (HttpMuseApi) against a tiny local server answering with the server's JSON shapes. */
class SuiteRigsFeedHttpTest {
    private lateinit var server: java.net.ServerSocket
    private lateinit var api: HttpMuseApi
    private val bodies = mutableMapOf<String, String>()
    private val targets = mutableListOf<String>()

    private val view = """{"id":"rig_1","name":"Golden","rig":{"body":"film_35","moves":[{"id":"dolly_in","intensity":0.4}]},"userId":"u1","mine":true,"createdAt":1,"updatedAt":2}"""

    @Before fun start() {
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
                        synchronized(bodies) { bodies["$method $path"] = body; targets += "$method $target" }
                        val (code, out) = when {
                            path == "/v1/suite/rigs" && method == "GET" -> 200 to "[$view]"
                            path == "/v1/suite/rigs" && method == "POST" -> 200 to view
                            path == "/v1/suite/rigs/rig_1" && method == "PATCH" -> 200 to view.replace("\"Golden\"", "\"Golden 35\"")
                            path == "/v1/suite/rigs/rig_1" && method == "DELETE" -> 204 to ""
                            path.startsWith("/v1/suite/rigs/") -> 404 to """{"error":"Rig not found","code":"not_found"}"""
                            path == "/v1/models/m_demo" && method == "PATCH" -> 200 to
                                (if (body.contains("null")) """{"id":"m_demo","name":"Demo model","age":24,"niche":"Fashion"}"""
                                else """{"id":"m_demo","name":"Demo model","age":24,"niche":"Fashion","defaultRig":{"body":"film_35"}}""")
                            path == "/v1/suite/feed" -> 200 to """{"items":[{"id":"t1","kind":"take","status":"done","tool":"shot","jobId":"j1","takeId":"t1","title":"Walk",
                                "label":"Draft","createdAt":10,"poster":{"url":"/uploads/p.jpg"},"videoUrl":"/uploads/v.mp4","index":1,"of":1,"price":0.1,"final":false,
                                "summary":"9:16, 5 s, 1 take"}],"nextCursor":"WzEwLCJ0MSJd"}"""
                            path == "/v1/suite/shots" -> 200 to """{"id":"j1","title":"Untitled shot","modelId":"","modelName":"","outfitId":"","state":"running","request":{"engine":"suite"},"draft":{"tool":"shot","x":1}}"""
                            else -> 404 to """{"error":"Not found","code":"not_found"}"""
                        }
                        val bytes = out.toByteArray()
                        val reason = when (code) { 200 -> "OK"; 204 -> "No Content"; else -> "Not Found" }
                        val head = "HTTP/1.1 $code $reason\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
                        sock.getOutputStream().apply { write(head.toByteArray()); write(bytes); flush() }
                    }
                }
            }
        }.apply { isDaemon = true }.start()
        api = HttpMuseApi("http://127.0.0.1:${server.localPort}", UploadMode.MULTIPART).also { it.setToken("t") }
    }

    @After fun stop() = server.close()

    @Test fun `saved rigs over HTTP send only what is set`() = runBlocking {
        assertEquals(listOf("Golden"), api.suiteRigs().map { it.name })
        val made = api.createSuiteRig("Golden", SuiteRig(body = "film_35", moves = listOf(SuiteRigMove("dolly_in", 0.4))))
        assertEquals("rig_1", made.id)
        assertEquals("""{"name":"Golden","rig":{"body":"film_35","moves":[{"id":"dolly_in","intensity":0.4}]}}""", bodies["POST /v1/suite/rigs"])
        assertEquals("Golden 35", api.updateSuiteRig("rig_1", name = "Golden 35").name)
        assertEquals("""{"name":"Golden 35"}""", bodies["PATCH /v1/suite/rigs/rig_1"])
        api.updateSuiteRig("rig_1", rig = SuiteRig(era = "1970s"))
        assertEquals("""{"rig":{"era":"1970s"}}""", bodies["PATCH /v1/suite/rigs/rig_1"])
        api.deleteSuiteRig("rig_1")
        assertTrue("DELETE /v1/suite/rigs/rig_1" in bodies)
        val e = runCatching { api.deleteSuiteRig("rig_x") }.exceptionOrNull() as ApiException
        assertEquals("not_found", e.code)
    }

    @Test fun `a model's default rig is set with the rig and cleared with an explicit null`() = runBlocking {
        assertEquals(SuiteRig(body = "film_35"), api.setModelDefaultRig("m_demo", SuiteRig(body = "film_35")).defaultRig)
        assertEquals("""{"defaultRig":{"body":"film_35"}}""", bodies["PATCH /v1/models/m_demo"])
        assertNull(api.setModelDefaultRig("m_demo", null).defaultRig)
        assertEquals("""{"defaultRig":null}""", bodies["PATCH /v1/models/m_demo"])
    }

    @Test fun `the feed sends its filters as a comma-list query and makes media addresses absolute`() = runBlocking {
        val page = api.suiteFeed(SuiteFeedQuery(tool = listOf("shot", "photo"), status = listOf("done"), model = "m_demo", cursor = "WzEwLCJ0MSJd", limit = 2))
        val target = synchronized(bodies) { targets.last { it.startsWith("GET /v1/suite/feed") } }
        val query = java.net.URLDecoder.decode(target.substringAfter('?'), "UTF-8")
        assertEquals("tool=shot,photo&status=done&model=m_demo&cursor=WzEwLCJ0MSJd&limit=2", query)
        assertEquals("WzEwLCJ0MSJd", page.nextCursor)
        val t = page.items.single()
        assertTrue(t.videoUrl!!.startsWith("http://127.0.0.1"))
        assertTrue(t.poster!!.url!!.startsWith("http://127.0.0.1"))
        api.suiteFeed()
        assertEquals("GET /v1/suite/feed", synchronized(bodies) { targets.last() })
    }

    @Test fun `a shot sends its draft as is and gets it back on the job`() = runBlocking {
        val d = SuiteDraft(Json.parseToJsonElement("""{"tool":"shot","speaking":null,"x":{"y":[1]}}""").jsonObject)
        val j = api.createSuiteShot(SuiteShotRequest(prompt = "x", draft = d))
        assertEquals(Json.parseToJsonElement("""{"prompt":"x","draft":{"tool":"shot","speaking":null,"x":{"y":[1]}}}"""), Json.parseToJsonElement(bodies["POST /v1/suite/shots"]!!))
        assertEquals("shot", j.draft!!.tool)
        assertEquals(JsonPrimitive(1), j.draft!!["x"])
    }
}
