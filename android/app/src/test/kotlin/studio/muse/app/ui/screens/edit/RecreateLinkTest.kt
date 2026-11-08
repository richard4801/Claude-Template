package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MuseApi
import studio.muse.app.platform.DeviceFetch
import studio.muse.app.platform.LinkFetcher
import studio.muse.app.platform.PhoneLinkFetcher
import java.io.File

/** Shared links: the phone fetches first, then the server, then the saved file (owner's decision, Release 1 test). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RecreateLinkTest {
    @get:Rule val tmp = TemporaryFolder()
    private val url = "https://www.tiktok.com/@cafe/video/7301"

    private class Recording(private val answer: (File) -> DeviceFetch) : LinkFetcher {
        var strict: Boolean? = null
        override suspend fun fetch(url: String, strict: Boolean, dir: File): DeviceFetch { this.strict = strict; dir.mkdirs(); return answer(dir) }
    }

    /** Records which way the reference was made. */
    private class Spy(val api: FakeMuseApi) : MuseApi by api {
        var uploads = 0; var sourceUrl: String? = null; var serverFetches = 0
        override suspend fun uploadEditorFile(file: File, contentType: String, purpose: String?, onProgress: (Float) -> Unit): String { uploads++; return api.uploadEditorFile(file, contentType, purpose, onProgress) }
        override suspend fun createReference(uploadId: String, name: String?, sourceUrl: String?) = api.createReference(uploadId, name, sourceUrl).also { this.sourceUrl = sourceUrl }
        override suspend fun createReferenceFromLink(url: String, name: String?) = api.createReferenceFromLink(url, name).also { serverFetches++ }
    }

    private fun spy() = Spy(FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0))

    @Test fun thePhonesVideoIsUploadedWithItsLink() = runBlocking {
        val api = spy()
        val phone = Recording { d -> DeviceFetch.Got(File(d, "link_1.mp4").apply { writeBytes(ByteArray(32)) }, "Café morning", 14.2) }
        val ref = referenceFromLink(api, phone, url, null, strict = true, cacheDir = tmp.root)
        assertEquals("analyzing", ref.state)
        assertEquals("Café morning", ref.name)
        assertEquals(1, api.uploads); assertEquals(url, api.sourceUrl); assertEquals(0, api.serverFetches)
        assertEquals(true, phone.strict)
        assertFalse(File(tmp.root, "links/link_1.mp4").exists()) // the downloaded copy is removed after upload
    }

    @Test fun whenThePhoneCantTheServerTries() = runBlocking {
        val api = spy()
        referenceFromLink(api, Recording { DeviceFetch.Failed("blocked") }, url, "Café", strict = false, cacheDir = tmp.root)
        assertEquals(0, api.uploads); assertEquals(1, api.serverFetches)
        referenceFromLink(api, null, url, "Café", strict = true, cacheDir = tmp.root) // no phone fetcher (tests, demo)
        assertEquals(2, api.serverFetches)
    }

    @Test fun aBrokenRuleIsSaidWithNoOtherAttempt() = runBlocking {
        val api = spy()
        try {
            referenceFromLink(api, Recording { DeviceFetch.Refused("too_long", "This video is longer than 60 seconds · pick a shorter one") }, url, null, true, tmp.root)
            fail("expected too_long")
        } catch (e: ApiException) { assertEquals("too_long", e.code) }
        assertEquals(0, api.serverFetches)
    }

    @Test fun whenTheServerFailsTooItsMessageOffersTheFile() = runBlocking {
        val api = spy()
        try { referenceFromLink(api, Recording { DeviceFetch.Failed("x") }, "https://www.tiktok.com/@a/video/private", null, true, tmp.root); fail() }
        catch (e: ApiException) { assertEquals("link_private", e.code) }
    }

    @Test fun readsThePythonAnswer() {
        val got = PhoneLinkFetcher.parse("""{"ok": true, "path": "/c/links/link_1.mp4", "title": "Café", "id": "1", "durationSec": 14.2}""")
        assertTrue(got is DeviceFetch.Got); got as DeviceFetch.Got
        assertEquals(14.2, got.durationSec, 1e-9); assertEquals("Café", got.title)
        assertEquals(DeviceFetch.Refused("link_private", "This video isn't public, so it can't be used"),
            PhoneLinkFetcher.parse("""{"ok": false, "code": "link_private", "message": "This video isn't public, so it can't be used"}"""))
        assertTrue(PhoneLinkFetcher.parse("""{"ok": false, "code": "fetch_failed", "message": "x"}""") is DeviceFetch.Failed)
    }

    @Test fun aServerWithoutSourceUrlStillGetsTheVideo() = runBlocking {
        val fake = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
        var plain = 0
        val old = object : MuseApi by fake {
            override suspend fun createReference(uploadId: String, name: String?, sourceUrl: String?) =
                if (sourceUrl != null) throw ApiException("bad_request", "Invalid request: sourceUrl") else fake.createReference(uploadId, name).also { plain++ }
        }
        val phone = Recording { d -> DeviceFetch.Got(File(d, "link_2.mp4").apply { writeBytes(ByteArray(8)) }, "Night walk", 9.0) }
        assertEquals("analyzing", referenceFromLink(old, phone, url, null, true, tmp.root).state)
        assertEquals(1, plain)
    }
}
