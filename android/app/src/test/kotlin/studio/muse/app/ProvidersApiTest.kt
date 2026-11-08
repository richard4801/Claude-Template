package studio.muse.app

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.AddProviderModel
import studio.muse.app.data.CustomModelPatch
import studio.muse.app.data.FakeProvidersApi
import studio.muse.app.data.NewProvider
import studio.muse.app.data.ProviderCatalogPage
import studio.muse.app.data.ProviderPatch
import studio.muse.app.data.Providers
import studio.muse.app.data.SuiteCatalog

/** WS7: the BYO provider data layer against WS5's contract v1 (the demo fake and decoding the server's JSON). */
class ProvidersApiTest {
    private val api = FakeProvidersApi({ 1_762_700_000_000 })
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

    private inline fun expectCode(code: String, block: () -> Unit) {
        try { block(); fail("expected $code") } catch (e: ApiException) { assertEquals(code, e.code) }
    }

    @Test fun addKeepsOnlyTheLastFour() = runBlocking {
        val p = api.add(NewProvider("replicate", "r8_abcdefghWXYZ"))
        assertEquals("WXYZ", p.keyLast4)
        assertFalse(p.toString().contains("abcdefgh"))
        val rotated = api.patch(p.id, ProviderPatch(apiKey = "r8_zzzzzzzz1234"))
        assertEquals("1234", rotated.keyLast4)
    }

    @Test fun badKeyIsRefusedAndNothingStored() = runBlocking {
        val before = api.providers().providers.size
        expectCode("invalid_key") { runBlocking { api.add(NewProvider("replicate", "not-a-key")) } }
        assertEquals(before, api.providers().providers.size)
    }

    @Test fun searchAddEnableRename() = runBlocking {
        val p = api.providers().providers.first()
        val video = api.catalog(p.id, kind = "video").models
        assertTrue(video.all { it.kind == "video" })
        val wan = api.catalog(p.id, q = "wan").models.single()
        val m = api.addModel(p.id, AddProviderModel(wan.ref))
        assertFalse(m.enabled)
        val on = api.patchModel(m.id, CustomModelPatch(enabled = true, displayName = "Wan quick"))
        assertTrue(on.enabled); assertEquals("Wan quick", on.name)
        assertNotNull(api.catalog(p.id, q = "wan").models.single().added)
        assertEquals(p.models.added + 1, api.providers().providers.first().models.added)
    }

    @Test fun unreadyModelCannotBeSwitchedOn() = runBlocking {
        val p = api.providers().providers.first()
        val odd = api.catalog(p.id, q = "odd").models.single()
        val m = api.addModel(p.id, AddProviderModel(odd.ref))
        expectCode("needs_setup") { runBlocking { api.patchModel(m.id, CustomModelPatch(enabled = true)) } }
    }

    @Test fun keysNotReadyRefusesAdding() = runBlocking {
        val off = FakeProvidersApi({ 1L }, keysReady = false)
        assertFalse(off.providers().keysReady)
        expectCode("provider_keys_unavailable") { runBlocking { off.add(NewProvider("replicate", "r8_abcdefghWXYZ")) } }
    }

    @Test fun decodesTheContractShapes() {
        val ps = json.decodeFromString(Providers.serializer(), """{"keysReady":false,"providers":[{"id":"p1","kind":"fal","label":"fal","keyLast4":"9abc","status":"invalid","checkedAt":1,"createdAt":1,"models":{"added":2,"enabled":1}}]}""")
        assertTrue(ps.providers.single().invalid); assertFalse(ps.keysReady)
        val page = json.decodeFromString(ProviderCatalogPage.serializer(), """{"models":[{"ref":"a/b","name":"B","description":null,"kind":"video","inputs":{"prompt":true,"negativePrompt":false,"startImage":true,"endImage":false,"referenceImages":0,"duration":{"min":5,"max":10,"allowed":[5,10]},"aspectRatios":["9:16"],"resolutions":[],"seed":false},"missing":[],"ready":true,"price":{"basis":"per_second","costUsd":0.07,"source":"provider"},"added":null}],"nextCursor":null}""")
        assertEquals(10, page.models.single().inputs.duration?.max)
        val cat = json.decodeFromString(SuiteCatalog.serializer(), """{"enabled":true,"tiers":[],"custom":[{"id":"c_1","name":"Kling turbo","kind":"video","inputs":{"start":true,"end":false,"middle":0,"images":0,"videos":0,"audio":false,"framesWithRefs":false},"minSeconds":5,"maxSeconds":10,"aspectRatios":["9:16"],"price":{"basis":"per_second","usd":0.08},"members":false,"provider":"replicate"}],"engines":[{"model":"kling-v4","name":"Kling 4.0","kind":"video","custom":false,"tier":"standard","tiers":["standard","hd"],"resolution":"720p","resolutions":[{"id":"720p","label":"720p","perSec":0.157},{"id":"1080p","label":"1080p","perSec":0.235}],"perSec":0.157,"perRun":null,"minSeconds":3,"maxSeconds":15,"allowedSeconds":null,"aspectRatios":["9:16","16:9"],"inputs":{"start":true}},{"model":"google/nano-banana","name":"nano-banana","kind":"image","custom":false,"tier":null,"tiers":[],"resolution":null,"resolutions":[],"perSec":null,"perRun":0.039,"minSeconds":null,"maxSeconds":null,"allowedSeconds":null,"aspectRatios":[],"inputs":{"images":6}}]}""")
        assertEquals("c_1", cat.custom!!.single().id)
        assertTrue(cat.custom!!.single().inputs!!.start)
        assertEquals(listOf("standard", "hd"), cat.engines!!.first().tiers)
        assertEquals(0.235, cat.engines!!.first().resolutions[1].perSec, 1e-9)
        assertEquals(0.039, cat.engines!![1].perRun!!, 1e-9)
    }
}
