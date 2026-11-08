package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.importFromLink
import studio.muse.app.platform.DeviceFetch
import studio.muse.app.platform.LinkCheck
import studio.muse.app.platform.LinkFetcher
import studio.muse.app.platform.LinkRules
import studio.muse.app.platform.LinkSteps
import studio.muse.app.platform.fetchLink
import java.io.File

/** WS7: the shared link flow (check → phone fetch → upload → finish, else the server) and the import built on it. */
class LinkPipelineTest {
    @get:Rule val tmp = TemporaryFolder()

    private val calls = mutableListOf<String>()

    private fun steps(check: LinkCheck<String> = LinkCheck(true, "https://www.tiktok.com/@a/video/1", "tiktok")) = LinkSteps(
        check = { calls += "check"; check },
        rules = { calls += "rules"; LinkRules(strict = true, maxSec = 30) },
        upload = { f, p -> calls += "upload:${f.name}"; p(1f); "up1" },
        finish = { id, u, t -> calls += "finish:$id:$t"; "made:$id" },
        serverFetch = { u, t -> calls += "server"; "server:$u" },
    )

    private fun fetcher(result: (File) -> DeviceFetch) = object : LinkFetcher {
        var seen: LinkRules? = null
        override suspend fun fetch(url: String, rules: LinkRules, dir: File): DeviceFetch { seen = rules; calls += "fetch"; dir.mkdirs(); return result(dir) }
    }

    @Test fun refusedAtCheckSaysWhyAndStops() = runBlocking {
        try {
            fetchLink("x", null, fetcher { DeviceFetch.Failed("no") }, tmp.root, steps(LinkCheck(false, "x", code = "link_unsupported", reason = "Paste a TikTok link")))
            fail()
        } catch (e: ApiException) { assertEquals("link_unsupported", e.code); assertEquals("Paste a TikTok link", e.message) }
        assertEquals(listOf("check"), calls)
    }

    @Test fun alreadyKnownNeedsNoDownload() = runBlocking {
        assertEquals("old", fetchLink("u", null, fetcher { DeviceFetch.Failed("no") }, tmp.root, steps(LinkCheck(true, "u", known = "old"))))
        assertEquals(listOf("check"), calls)
    }

    @Test fun phoneGetsItUploadsAndFinishesThenDeletesTheFile() = runBlocking {
        var file: File? = null
        val f = fetcher { dir -> File(dir, "v.mp4").also { it.writeText("x"); file = it }.let { DeviceFetch.Got(it, "Dance on the roof", 9.0) } }
        val steps = mutableListOf<String>()
        val out = fetchLink("https://www.tiktok.com/@a/video/1", null, f, tmp.root, steps(), onStep = { _, s -> steps += s })
        assertEquals("made:up1", out)
        assertEquals(listOf("check", "rules", "fetch", "upload:v.mp4", "finish:up1:Dance on the roof"), calls)
        assertEquals("tiktok", f.seen?.platform); assertEquals(30, f.seen?.maxSec)
        assertFalse(file!!.exists())
        assertEquals(listOf("Checking the link", "Getting the video from the link", "Uploading the video"), steps.distinct())
    }

    @Test fun aRuleTheLinkBreaksIsSaidWithNoOtherAttempt() = runBlocking {
        try { fetchLink("u", null, fetcher { DeviceFetch.Refused("link_too_long", "This video is over 60 seconds") }, tmp.root, steps()); fail() }
        catch (e: ApiException) { assertEquals("link_too_long", e.code) }
        assertFalse("server" in calls)
    }

    @Test fun phoneFailsThenTheServerFetches() = runBlocking {
        assertEquals("server:u", fetchLink("u", null, fetcher { DeviceFetch.Failed("blocked") }, tmp.root, steps()))
        assertEquals(listOf("check", "rules", "fetch", "server"), calls)
    }

    @Test fun noPhoneFetcherGoesStraightToTheServer() = runBlocking {
        assertEquals("server:u", fetchLink("u", null, null, tmp.root, steps()))
        assertEquals(listOf("check", "server"), calls)
    }

    @Test fun importFromLinkOnTheDemoStudio() = runBlocking {
        val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        val url = "https://www.instagram.com/reel/abc"
        val v = importFromLink(api, null, url, "Rooftop dance", tmp.root)
        assertEquals("Rooftop dance", v.name); assertEquals(url, v.sourceUrl); assertEquals(v.id, v.asClip().id)
        // The same link again: already imported, nothing fetched.
        importFromLink(api, null, url, null, tmp.root).let { again -> assertEquals(v.id, again.id); assertTrue(again.cached) }
        // Strict link rules: another site is refused with the reason.
        try { importFromLink(api, null, "https://example.com/v.mp4", null, tmp.root); fail() } catch (e: ApiException) { assertEquals("link_unsupported", e.code) }
        // The server can't get it either: the error says to pick the saved video.
        try { importFromLink(api, null, "https://www.tiktok.com/@blocked/video/2", null, tmp.root); fail() } catch (e: ApiException) { assertEquals("link_blocked", e.code) }
    }

    @Test fun decodesWs12Import() {
        val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }
        val v = json.decodeFromString(studio.muse.app.data.ImportedVideo.serializer(), """{"id":"clip_9","name":"Roof","durationSec":8.2,"width":1080,"height":1920,"fps":30,"checks":[],"source":"import","sourceUrl":"https://www.tiktok.com/@a/video/1","platform":"tiktok","bytes":4200000,"thumb":{"url":"https://cdn/x.jpg"},"posterUrl":"https://cdn/x.jpg","videoUrl":"https://cdn/x.mp4","videoKey":"clips/x.mp4","uploadId":"up_1","createdBy":"u1","createdAt":1,"cached":true}""")
        assertEquals("clip_9", v.clipId); assertEquals("https://cdn/x.jpg", v.thumb?.url); assertEquals("clips/x.mp4", v.videoKey); assertTrue(v.cached)
        assertEquals(1080, v.asClip().width)
    }
}
