package studio.muse.app.claude

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ClaudeEffort
import studio.muse.app.data.ClaudeModelChoice
import studio.muse.app.data.ClaudeModelInfo
import studio.muse.app.data.ClaudeModelList
import studio.muse.app.data.ClaudeThread
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.FakeClaudeApi
import studio.muse.app.data.HttpClaudeApi
import studio.muse.app.ui.screens.claude.ClaudeChatStore

/** Effort beside the model in the Claude chat (owner, 2026-11-13): the same rules as the Mac and the server. */
@OptIn(ExperimentalCoroutinesApi::class)
class ClaudeEffortTest {
    private val opus = ClaudeModelInfo("claude-opus-5-5", "Claude Opus 5.5", efforts = ClaudeEffort.ALL, defaultEffort = "medium")
    private val none = ClaudeModelInfo("claude-x", "Claude X")

    @Test fun resolvesChatThenLastChoiceThenModelDefault() {
        assertEquals("medium", ClaudeEffort.resolve(opus, null, null))
        assertEquals("max", ClaudeEffort.resolve(opus, null, "max"))
        assertEquals("low", ClaudeEffort.resolve(opus, "low", "max"))
        val some = ClaudeModelInfo("m", "M", efforts = listOf("max", "low", "bogus"), defaultEffort = "low")
        assertEquals(listOf("low", "max"), ClaudeEffort.levels(some))
        assertEquals("low", ClaudeEffort.resolve(some, "high", null))
        assertNull(ClaudeEffort.resolve(none, "high", "high"))
        assertEquals(listOf("Low", "Medium", "High", "Extra high", "Max"), ClaudeEffort.ALL.map(ClaudeEffort::name))
        assertEquals("Opus 5.5", ClaudeEffort.shortModel("Claude Opus 5.5"))
    }

    @Test fun choiceFollowsTheChatsModel() {
        val list = ClaudeModelList(listOf(opus, none), default = null, studioDefault = "claude-opus-5-5", defaultEffort = "high")
        val t = ClaudeThread("ct_1", contextKind = "chat")
        assertEquals("high", ClaudeModelChoice.of(list, t).effort)
        assertEquals("xhigh", ClaudeModelChoice.of(list, t.copy(effort = "xhigh")).effort)
        val onNone = ClaudeModelChoice.of(list, t.copy(model = "claude-x", effort = "xhigh"))
        assertTrue(onNone.levels.isEmpty())
        assertNull(onNone.effort)
        // An older server: no efforts in the list, so no picker.
        val old = Json { ignoreUnknownKeys = true }.decodeFromString(ClaudeModelList.serializer(),
            """{"models":[{"id":"claude-opus-5-5","name":"Claude Opus 5.5","speed":"Steady","cost":"x","good":"y"}],"default":null,"studioDefault":"claude-opus-5-5"}""")
        assertNull(ClaudeModelChoice.of(old, t).effort)
    }

    @Test fun picksReachTheChatAndBecomeTheLastChoice() = runTest {
        lateinit var store: ClaudeChatStore
        val api = FakeClaudeApi(this, { 0L }, { store.onLive(it) }, stepDelayMs = 0)
        store = ClaudeChatStore({ api }, this, "camera", FakeCameraApi.SEED_ID)
        store.load(); advanceUntilIdle()
        assertEquals("medium", store.ui.value.choice.effort)
        store.pickEffort("high"); advanceUntilIdle()
        assertEquals("high", store.ui.value.thread?.effort)
        assertEquals("high", store.ui.value.choice.effort)
        assertEquals("high", api.claudeModels().defaultEffort)
        store.pickModel("claude-sonnet-5-5"); advanceUntilIdle()
        assertEquals("claude-sonnet-5-5", store.ui.value.choice.model?.id)
        assertEquals("high", store.ui.value.choice.effort)
        assertEquals("claude-sonnet-5-5", api.getThread(store.ui.value.thread!!.id).model)
    }

    @Test fun httpSendsTheLevelAndNullClears() {
        val bodies = mutableListOf<Pair<String, String>>()
        val client = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val r = chain.request()
            val b = Buffer().also { r.body?.writeTo(it) }.readUtf8()
            bodies += "${r.method} ${r.url.encodedPath}" to b
            Response.Builder().request(r).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("""{"id":"ct_1"}""".toResponseBody("application/json".toMediaType())).build()
        }).build()
        val api = HttpClaudeApi("https://muse.test/", client, Json { ignoreUnknownKeys = true })
        runBlocking { api.setChatEffort("ct_1", "xhigh"); api.setChatEffort("ct_1", null); api.setChatModel("ct_1", "claude-haiku-5-5") }
        assertEquals(listOf(
            "PATCH /v1/claude/chats/ct_1" to """{"effort":"xhigh"}""",
            "PATCH /v1/claude/chats/ct_1" to """{"effort":null}""",
            "PATCH /v1/claude/chats/ct_1" to """{"model":"claude-haiku-5-5"}""",
        ), bodies)
    }
}
