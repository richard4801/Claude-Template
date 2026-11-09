package studio.muse.app.data

// Workstream 2: Claude on the owner's plan (plans/api.md "Claude on the owner's plan: OAuth, chat threads, Mac runner";
// plans/claude-editing.md parts D and E). One chat thread per camera or edit session. The Mac runs each turn with the
// owner's own Claude Code; the phone posts messages that the server queues for the Mac and follows the reply over the live
// `claude` events. When the Mac is offline the phone can open the Claude app, or (owner switch, billed per use) run the
// turn on the studio API key. Owner only. MuseApi exposes it as `api.claude`; the demo studio's version is FakeClaudeApi.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import java.util.concurrent.TimeUnit

// ---------------------------------------------------------------- types

@Serializable
data class ClaudeToolRef(val id: String = "", val name: String = "", val ok: Boolean? = null, val summary: String? = null)

@Serializable
data class ClaudeImageRef(val url: String = "")

/** An image the owner attached to a message (a copy stored on the thread; [url] is a private link, valid 1 h). */
@Serializable
data class ClaudeAttachment(val id: String = "", val uploadId: String = "", val mimeType: String = "image/jpeg", val bytes: Long = 0,
    val width: Int? = null, val height: Int? = null, val url: String = "")

/** role: user | assistant | tool; source: mac | phone | api. */
@Serializable
data class ClaudeMessage(
    val id: String, val threadId: String = "", val role: String = "assistant", val source: String = "mac", val text: String = "",
    val turnId: String? = null, val tool: ClaudeToolRef? = null, val image: ClaudeImageRef? = null, val createdAt: Long = 0,
    /** Up to 4 images the owner attached (Recreate, Edit and Suite threads). */
    val attachments: List<ClaudeAttachment> = emptyList(),
)

/** state: queued | running | done | failed | stopped; from: phone | mac. */
@Serializable
data class ClaudeTurn(
    val id: String, val threadId: String = "", val text: String = "", val from: String = "phone", val state: String = "queued",
    val error: String? = null, val createdAt: Long = 0, val claimedAt: Long? = null, val finishedAt: Long? = null,
) {
    val active get() = state == "queued" || state == "running"
}

/** GET /v1/claude/threads/{id} adds [messages] (the last 100, oldest first) and [activeTurn]. */
@Serializable
data class ClaudeThread(
    val id: String, val contextKind: String = "camera", val contextId: String = "", val claudeSessionId: String? = null,
    val createdAt: Long = 0, val updatedAt: Long = 0, val messages: List<ClaudeMessage>? = null, val activeTurn: ClaudeTurn? = null,
    /** WS18: the list of chats it belongs to (`suite:photo`, `recreate:rx_1`…), its name (the owner's or its first words) and, in a list, its message count. */
    val contextKey: String? = null, val title: String? = null, val messageCount: Int? = null,
)

/** GET /v1/claude/threads?key= (WS18): one place's chats, newest first. */
@Serializable
data class ClaudeThreadList(val key: String = "", val threads: List<ClaudeThread> = emptyList())

/**
 * One event of the Mac's Claude Code stream, relayed live. type: user (text) | text (delta) | assistant (text) |
 * tool (id, name, status running|done|error, summary?, input?) | image (data base64, mimeType) | done (ok, error?, model?).
 */
@Serializable
data class ClaudeEvent(
    val type: String, val text: String? = null, val delta: String? = null, val id: String? = null, val name: String? = null,
    val status: String? = null, val summary: String? = null, val input: JsonElement? = null, val data: String? = null,
    val mimeType: String? = null, val ok: Boolean? = null, val error: String? = null, val model: String? = null,
)

@Serializable
data class ClaudeCodeStatus(val installed: Boolean = false, val signedIn: Boolean = false, val version: String? = null, val model: String? = null)

@Serializable
data class MacClaudeStatus(val online: Boolean = false, val claudeCode: ClaudeCodeStatus = ClaudeCodeStatus(), val answeringTurn: String? = null) {
    /** The Mac can take a turn: online, with Claude Code installed and signed in. */
    val ready get() = online && claudeCode.installed && claudeCode.signedIn
}

/** available: the server has ANTHROPIC_API_KEY; enabled: the owner switched the fallback on (off by default, billed per use). */
@Serializable
data class ApiFallbackStatus(val available: Boolean = false, val enabled: Boolean = false) {
    val usable get() = available && enabled
}

/** GET /v1/claude/status (the contract's `ClaudeStatus`; named apart from the camera session's ClaudeStatus). */
@Serializable
data class ClaudePlanStatus(
    val mac: MacClaudeStatus = MacClaudeStatus(), val apiFallback: ApiFallbackStatus = ApiFallbackStatus(),
    val connectorUrl: String = "", val openInClaudeUrl: String = "",
)

/** What a `mac_offline` refusal carries. */
@Serializable
data class ClaudeFallback(val openInClaudeUrl: String = "", val apiFallback: Boolean = false)

/**
 * The live `claude` event (owners' devices). op: thread (thread) | message (threadId, message) | event (threadId, turnId?, event)
 * | turn (turn) | stop (turnId) | status (status). It rides on [ApiEvent.claude] (type "claude").
 */
@Serializable
data class ClaudeLive(
    val op: String = "", val thread: ClaudeThread? = null, val threadId: String? = null, val message: ClaudeMessage? = null,
    val turnId: String? = null, val event: ClaudeEvent? = null, val turn: ClaudeTurn? = null, val status: ClaudePlanStatus? = null,
)

/** The answer to a phone message. */
sealed interface ClaudeSend {
    /** 202: queued for the Mac. */
    data class Sent(val message: ClaudeMessage, val turn: ClaudeTurn) : ClaudeSend
    /** `mac_offline` (409). */
    data class MacOffline(val fallback: ClaudeFallback) : ClaudeSend
    /** `claude_busy` (409): a turn on this thread is queued or running. */
    data object Busy : ClaudeSend
}

@Serializable private data class ThreadBody(val contextKind: String, val contextId: String, val new: Boolean? = null)
@Serializable private data class TitleBody(val title: String)
@Serializable private data class TextBody(val text: String, val attachments: List<UploadRef>? = null)
@Serializable private data class UploadRef(val uploadId: String)
@Serializable private data class FallbackBody(val apiFallback: Boolean)
@Serializable private data class SentBody(val message: ClaudeMessage, val turn: ClaudeTurn)
@Serializable private data class RefusalBody(val error: String = "", val code: String? = null, val fallback: ClaudeFallback? = null)

// ---------------------------------------------------------------- API

interface ClaudeApi {
    suspend fun status(): ClaudePlanStatus
    /** PATCH /v1/claude/settings. */
    suspend fun setApiFallback(on: Boolean): ClaudePlanStatus
    /** Get or create the thread of a camera or edit session. */
    suspend fun thread(contextKind: String, contextId: String): ClaudeThread
    /** With the last 100 messages and the active turn. */
    suspend fun getThread(id: String): ClaudeThread
    /** A message from the phone: queued for the Mac, or refused (Mac offline, busy). Other errors throw [ApiException]. */
    suspend fun post(threadId: String, text: String, attachments: List<String> = emptyList()): ClaudeSend
    /** The phone's Stop: the Mac interrupts the turn and sends `done`. */
    suspend fun stop(turnId: String)
    /** The fallback on the studio API key (camera threads for now). Refusals (`fallback_off`) arrive as one `error` event. */
    fun apiTurn(threadId: String, text: String, attachments: List<String> = emptyList()): Flow<ChatEvent>

    // WS18: each place keeps a list of chats on the server. An older server has none (`not_found`): one chat per place.
    /** The place's chats, newest first. */
    suspend fun threads(key: String): List<ClaudeThread> = throw ApiException("not_found", "This server keeps one chat per place")
    /** A new chat about the same context. */
    suspend fun newThread(contextKind: String, contextId: String): ClaudeThread = throw ApiException("not_found", "This server keeps one chat per place")
    /** "" goes back to the chat's first words. */
    suspend fun renameThread(id: String, title: String): ClaudeThread = throw ApiException("not_found", "This server keeps one chat per place")
    suspend fun deleteThread(id: String): Unit = throw ApiException("not_found", "This server keeps one chat per place")

    object Unsupported : ClaudeApi {
        private fun no(): Nothing = throw ApiException("unsupported", "Claude chat needs the studio server")
        override suspend fun status() = no()
        override suspend fun setApiFallback(on: Boolean) = no()
        override suspend fun thread(contextKind: String, contextId: String) = no()
        override suspend fun getThread(id: String) = no()
        override suspend fun post(threadId: String, text: String, attachments: List<String>) = no()
        override suspend fun stop(turnId: String) = no()
        override fun apiTurn(threadId: String, text: String, attachments: List<String>): Flow<ChatEvent> = flowOf(ChatEvent("error", code = "unsupported", error = "Claude chat needs the studio server"))
    }
}

/** Relative upload URLs ("/uploads/…") made absolute against [base]. */
fun ClaudeMessage.absolute(base: String): ClaudeMessage {
    fun abs(u: String) = if (u.startsWith("/")) base.trimEnd('/') + u else u
    val m = if (image?.url?.startsWith("/") == true) copy(image = ClaudeImageRef(abs(image.url))) else this
    return if (m.attachments.any { it.url.startsWith("/") }) m.copy(attachments = m.attachments.map { it.copy(url = abs(it.url)) }) else m
}

fun ClaudeThread.absolute(base: String) = copy(messages = messages?.map { it.absolute(base) })

fun ClaudeLive.absolute(base: String) = copy(message = message?.absolute(base), thread = thread?.absolute(base))

/** Reads a `claude` live event out of a raw `/v1/events` data line, or null when it is another type. */
fun claudeLiveOf(json: Json, data: String): ClaudeLive? {
    if (!data.contains("\"claude\"")) return null
    val o = runCatching { json.parseToJsonElement(data) as? JsonObject }.getOrNull() ?: return null
    if ((o["type"] as? JsonPrimitive)?.contentOrNull != "claude") return null
    return runCatching { json.decodeFromJsonElement(ClaudeLive.serializer(), o) }.getOrNull()
}

/** [ClaudeApi] over HTTP with [client] (which adds the session's bearer token). */
class HttpClaudeApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : ClaudeApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    private val jsonType = "application/json".toMediaType()

    private class Answer(val code: Int, val text: String)

    private suspend fun raw(method: String, path: String, body: String?): Answer = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody(jsonType) ?: if (method != "GET") "{}".toRequestBody(jsonType) else null
        val req = Request.Builder().url(base + path).method(method, rb).build()
        val res = try { client.newCall(req).execute() } catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r -> Answer(r.code, r.body.string()) }
    }

    private fun errorOf(code: Int, text: String?): ApiException {
        val err = runCatching { json.decodeFromString(RefusalBody.serializer(), text ?: "") }.getOrNull()
        val c = err?.code ?: ErrorText.codeOf(code)
        return ApiException(c, err?.error?.takeIf { it.isNotBlank() } ?: ErrorText.http(code))
    }

    private fun <T> decode(out: KSerializer<T>, text: String): T = try { json.decodeFromString(out, text) } catch (e: kotlinx.serialization.SerializationException) {
        throw ApiException("bad_response", "The server sent something this app version can't read")
    }

    private suspend fun <T> call(method: String, path: String, body: String?, out: KSerializer<T>): T {
        val a = raw(method, path, body)
        if (a.code !in 200..299) throw errorOf(a.code, a.text)
        return decode(out, a.text)
    }

    private fun enc(id: String) = java.net.URLEncoder.encode(id, "UTF-8")
    private val origin get() = base.trimEnd('/')

    override suspend fun status() = call("GET", "v1/claude/status", null, ClaudePlanStatus.serializer())
    override suspend fun setApiFallback(on: Boolean) =
        call("PATCH", "v1/claude/settings", json.encodeToString(FallbackBody.serializer(), FallbackBody(on)), ClaudePlanStatus.serializer())
    override suspend fun thread(contextKind: String, contextId: String) =
        call("POST", "v1/claude/threads", json.encodeToString(ThreadBody.serializer(), ThreadBody(contextKind, contextId)), ClaudeThread.serializer()).absolute(origin)
    override suspend fun getThread(id: String) = call("GET", "v1/claude/threads/${enc(id)}", null, ClaudeThread.serializer()).absolute(origin)
    override suspend fun threads(key: String) = call("GET", "v1/claude/threads?key=${enc(key)}", null, ClaudeThreadList.serializer()).threads
    override suspend fun newThread(contextKind: String, contextId: String) =
        call("POST", "v1/claude/threads", json.encodeToString(ThreadBody.serializer(), ThreadBody(contextKind, contextId, true)), ClaudeThread.serializer()).absolute(origin)
    override suspend fun renameThread(id: String, title: String) =
        call("PATCH", "v1/claude/threads/${enc(id)}", json.encodeToString(TitleBody.serializer(), TitleBody(title)), ClaudeThread.serializer())
    override suspend fun deleteThread(id: String) {
        val a = raw("DELETE", "v1/claude/threads/${enc(id)}", null)
        if (a.code !in 200..299) throw errorOf(a.code, a.text)
    }

    override suspend fun post(threadId: String, text: String, attachments: List<String>): ClaudeSend {
        val a = raw("POST", "v1/claude/threads/${enc(threadId)}/messages", json.encodeToString(TextBody.serializer(), body(text, attachments)))
        if (a.code in 200..299) return decode(SentBody.serializer(), a.text).let { ClaudeSend.Sent(it.message.absolute(origin), it.turn) }
        val r = runCatching { json.decodeFromString(RefusalBody.serializer(), a.text) }.getOrNull()
        return when (r?.code) {
            "mac_offline" -> ClaudeSend.MacOffline(r.fallback ?: ClaudeFallback())
            "claude_busy" -> ClaudeSend.Busy
            else -> throw errorOf(a.code, a.text)
        }
    }

    override suspend fun stop(turnId: String) {
        val a = raw("POST", "v1/claude/turns/${enc(turnId)}/stop", null)
        if (a.code !in 200..299) throw errorOf(a.code, a.text)
    }

    private fun body(text: String, attachments: List<String>) = TextBody(text, attachments.takeIf { it.isNotEmpty() }?.map { UploadRef(it) })

    override fun apiTurn(threadId: String, text: String, attachments: List<String>): Flow<ChatEvent> = callbackFlow {
        val req = Request.Builder().url(base + "v1/claude/threads/${enc(threadId)}/api-turn")
            .post(json.encodeToString(TextBody.serializer(), body(text, attachments)).toRequestBody(jsonType)).build()
        val sse = client.newBuilder().readTimeout(60, TimeUnit.SECONDS).build()
        val source = EventSources.createFactory(sse).newEventSource(req, object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                runCatching { json.decodeFromString(ChatEvent.serializer(), data) }.onSuccess { trySend(it) }
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                val e = if (response != null && !response.isSuccessful) errorOf(response.code, runCatching { response.body.string() }.getOrNull())
                else ApiException("offline", "The connection to Claude dropped")
                trySend(ChatEvent("error", code = e.code, error = e.message))
                close()
            }
            override fun onClosed(eventSource: EventSource) { close() }
        })
        awaitClose { source.cancel() }
    }
}
