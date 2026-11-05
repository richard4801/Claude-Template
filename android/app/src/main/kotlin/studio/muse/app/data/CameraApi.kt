package studio.muse.app.data

// Workstream 2: camera sessions (plans/api.md "MCP & camera sessions"). Owner only: every endpoint answers owner_only to a member.
// The types, the API (REST + the Direct with Claude SSE stream) and its HTTP implementation. The demo studio's version is
// FakeCameraApi. MuseApi exposes it as `api.camera`.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
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

/** One camera keyframe. Positions are metres in Blender world space (Z up; a character faces -Y at facingDeg 0). */
@Serializable
data class CamKey(
    val t: Double, val position: List<Double>, val target: List<Double>? = null, val focalMm: Double? = null,
    val rollDeg: Double? = null, val ease: String? = null,
)

@Serializable
data class CharKey(val t: Double, val position: List<Double>, val facingDeg: Double? = null, val action: String? = null)

@Serializable
data class CameraPath(val keyframes: List<CamKey> = emptyList(), val cuts: List<Double>? = null, val sensorMm: Double? = null)

@Serializable
data class CharacterTrack(val modelId: String, val keyframes: List<CharKey> = emptyList(), val note: String? = null)

@Serializable
data class Blocking(val characters: List<CharacterTrack> = emptyList())

/** A cast member of a camera session (the studio's own characters). */
@Serializable
data class CameraCast(val modelId: String, val name: String = "", val role: String? = null, val heightM: Double? = null)

@Serializable
data class CameraAsset(
    val id: String, val kind: String, val label: String? = null, val state: String = "pending", val contentType: String = "",
    val bytes: Long? = null, val source: String = "app", val url: String? = null, val createdAt: Long = 0,
) {
    val ready get() = state == "ready"
}

@Serializable
data class DraftEstimate(val usd: Double = 0.0, val tokens: Double = 0.0)

/** A Shot draft: an estimate only. `request` is the suite's ShotRequest the app POSTs to /v1/suite/shots on Generate. */
@Serializable
data class ShotDraft(
    val id: String, val state: String = "draft", val source: String = "camera", val prompt: String = "", val targetModel: String = "",
    val durationSec: Double = 0.0, val aspect: String = "9:16", val estimate: DraftEstimate = DraftEstimate(), val camera: JsonObject? = null,
    val createdAt: Long = 0, val request: JsonObject? = null, val warnings: List<String> = emptyList(), val jobId: String? = null, val linkedAt: Long? = null,
)

@Serializable
data class CameraTool(val name: String, val ok: Boolean = true, val summary: String = "")

@Serializable
data class CameraMessage(
    val id: String, val role: String, val source: String = "app", val text: String = "", val tool: CameraTool? = null, val createdAt: Long = 0,
)

@Serializable
data class RelayStatus(val online: Boolean = false, val blender: Boolean = false, val addonVersion: String? = null)

@Serializable
data class ClaudeStatus(val chatBusy: Boolean = false, val appLastSeenAt: Long? = null)

@Serializable
data class CameraSession(
    val id: String, val title: String = "", val brief: String = "", val status: String = "drafting", val aspect: String = "9:16",
    val fps: Int = 24, val durationSec: Double = 6.0, val targetModel: String? = null, val presets: JsonObject? = null,
    val characters: List<CameraCast> = emptyList(), val cameraPath: CameraPath? = null, val blocking: Blocking? = null,
    val assets: List<CameraAsset> = emptyList(), val shotDraft: ShotDraft? = null, val camera: JsonObject? = null,
    val revision: Int = 0, val relay: RelayStatus = RelayStatus(), val claude: ClaudeStatus = ClaudeStatus(),
    val createdAt: Long = 0, val updatedAt: Long = 0, val messages: List<CameraMessage>? = null,
)

/** GET /v1/connections (owner Settings → Connections). */
@Serializable
data class ClaudeAppStatus(val lastSeenAt: Long? = null, val tokens: Int = 0)

@Serializable
data class Connections(
    val relay: RelayStatus = RelayStatus(), val claudeApp: ClaudeAppStatus = ClaudeAppStatus(), val mcpUrl: String = "",
    val inAppChat: Boolean = false, val docsUrl: String = "",
)

/** An owner personal access token for the MUSE MCP server. `token` is only in the create answer (shown once). */
@Serializable
data class McpToken(
    val id: String, val name: String, val prefix: String = "", val createdAt: Long = 0, val lastUsedAt: Long? = null,
    val expiresAt: Long? = null, val token: String? = null,
)

/** One `data:` line of POST /v1/camera-sessions/{id}/chat. */
@Serializable
data class ChatEvent(
    val type: String, val delta: String? = null, val id: String? = null, val name: String? = null, val status: String? = null,
    val summary: String? = null, val reason: String? = null, val message: CameraMessage? = null, val stopReason: String? = null,
    val usage: JsonObject? = null, val code: String? = null, val error: String? = null,
)

@Serializable
data class NewCameraSession(
    val title: String? = null, val brief: String? = null, val aspect: String? = null, val fps: Int? = null, val durationSec: Double? = null,
    val characters: List<NewCast>? = null,
)

@Serializable
data class NewCast(val modelId: String, val role: String? = null, val heightM: Double? = null)

@Serializable
data class CameraSessionPatch(
    val title: String? = null, val brief: String? = null, val status: String? = null, val aspect: String? = null, val fps: Int? = null,
    val durationSec: Double? = null, val targetModel: String? = null, val revision: Int? = null,
)

@Serializable
data class PathUpdate(val camera: CameraPath? = null, val characters: List<CharacterTrack>? = null)

@Serializable
data class ShotDraftRequest(val prompt: String? = null, val targetModel: String? = null, val durationSec: Double? = null)

@Serializable
private data class ChatBody(val message: String)

@Serializable
private data class NoteBody(val text: String)

@Serializable
private data class TokenBody(val name: String, val expiresDays: Int? = null)

@Serializable
private data class LinkBody(val jobId: String)

// ---------------------------------------------------------------- API

interface CameraApi {
    suspend fun sessions(): List<CameraSession>
    /** With the last 50 messages. */
    suspend fun session(id: String): CameraSession
    suspend fun createSession(req: NewCameraSession): CameraSession
    /** `stale_revision` (409) when [CameraSessionPatch.revision] is old. */
    suspend fun patchSession(id: String, patch: CameraSessionPatch): CameraSession
    suspend fun deleteSession(id: String)
    /** The camera path and/or the blocking; drafting → blocking. */
    suspend fun putPath(id: String, req: PathUpdate): CameraSession
    suspend fun postNote(id: String, text: String): CameraMessage
    /** An estimate only: no hold, no ledger row, no provider call. */
    suspend fun shotDraft(id: String, req: ShotDraftRequest = ShotDraftRequest()): ShotDraft
    suspend fun linkJob(id: String, jobId: String): CameraSession
    /** Direct with Claude: one turn as a stream. HTTP refusals (chat_busy, director_unavailable) arrive as one `error` event. */
    fun chat(id: String, message: String): Flow<ChatEvent>
    suspend fun connections(): Connections
    suspend fun tokens(): List<McpToken>
    suspend fun createToken(name: String, expiresDays: Int? = null): McpToken
    suspend fun revokeToken(id: String)

    /** Servers and builds without camera sessions. */
    object Unsupported : CameraApi {
        private fun no(): Nothing = throw ApiException("unsupported", "Camera sessions need the studio server")
        override suspend fun sessions() = no()
        override suspend fun session(id: String) = no()
        override suspend fun createSession(req: NewCameraSession) = no()
        override suspend fun patchSession(id: String, patch: CameraSessionPatch) = no()
        override suspend fun deleteSession(id: String) = no()
        override suspend fun putPath(id: String, req: PathUpdate) = no()
        override suspend fun postNote(id: String, text: String) = no()
        override suspend fun shotDraft(id: String, req: ShotDraftRequest) = no()
        override suspend fun linkJob(id: String, jobId: String) = no()
        override fun chat(id: String, message: String): Flow<ChatEvent> = flowOf(ChatEvent("error", code = "unsupported", error = "Camera sessions need the studio server"))
        override suspend fun connections() = no()
        override suspend fun tokens() = no()
        override suspend fun createToken(name: String, expiresDays: Int?) = no()
        override suspend fun revokeToken(id: String) = no()
    }
}

/** [CameraApi] over HTTP with [client] (which adds the session's bearer token). */
class HttpCameraApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : CameraApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    private val jsonType = "application/json".toMediaType()

    private suspend fun <T> send(method: String, path: String, body: String?, out: KSerializer<T>?): T? = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody(jsonType) ?: if (method == "POST" || method == "PUT" || method == "PATCH") "{}".toRequestBody(jsonType) else null
        val req = Request.Builder().url(base + path).method(method, rb).build()
        val res = try { client.newCall(req).execute() } catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r ->
            val text = r.body.string()
            if (!r.isSuccessful) throw errorOf(r.code, text)
            if (out == null || r.code == 204) null
            else try { json.decodeFromString(out, text) } catch (e: kotlinx.serialization.SerializationException) {
                throw ApiException("bad_response", "The server sent something this app version can't read")
            }
        }
    }

    private fun errorOf(code: Int, text: String?): ApiException {
        val err = runCatching { json.decodeFromString(ErrorBody.serializer(), text ?: "") }.getOrNull()
        val c = err?.code ?: when (code) { 401 -> "unauthorized"; 429 -> "rate_limited"; else -> "http_$code" }
        return ApiException(c, err?.error ?: "Server error $code")
    }

    private suspend fun <T> get(path: String, out: KSerializer<T>): T = send("GET", path, null, out)!!
    private suspend fun <T> post(path: String, body: String?, out: KSerializer<T>): T = send("POST", path, body, out)!!
    private fun s(id: String) = "v1/camera-sessions/" + java.net.URLEncoder.encode(id, "UTF-8")

    override suspend fun sessions() = get("v1/camera-sessions", ListSerializer(CameraSession.serializer()))
    override suspend fun session(id: String) = get(s(id), CameraSession.serializer())
    override suspend fun createSession(req: NewCameraSession) = post("v1/camera-sessions", json.encodeToString(NewCameraSession.serializer(), req), CameraSession.serializer())
    override suspend fun patchSession(id: String, patch: CameraSessionPatch) =
        send("PATCH", s(id), json.encodeToString(CameraSessionPatch.serializer(), patch), CameraSession.serializer())!!
    override suspend fun deleteSession(id: String) { send("DELETE", s(id), null, null as KSerializer<Unit>?) }
    override suspend fun putPath(id: String, req: PathUpdate) = send("PUT", s(id) + "/path", json.encodeToString(PathUpdate.serializer(), req), CameraSession.serializer())!!
    override suspend fun postNote(id: String, text: String) = post(s(id) + "/messages", json.encodeToString(NoteBody.serializer(), NoteBody(text)), CameraMessage.serializer())
    override suspend fun shotDraft(id: String, req: ShotDraftRequest) = post(s(id) + "/shot-draft", json.encodeToString(ShotDraftRequest.serializer(), req), ShotDraft.serializer())
    override suspend fun linkJob(id: String, jobId: String) = post(s(id) + "/shot-draft/job", json.encodeToString(LinkBody.serializer(), LinkBody(jobId)), CameraSession.serializer())
    override suspend fun connections() = get("v1/connections", Connections.serializer())
    override suspend fun tokens() = get("v1/mcp/tokens", ListSerializer(McpToken.serializer()))
    override suspend fun createToken(name: String, expiresDays: Int?) = post("v1/mcp/tokens", json.encodeToString(TokenBody.serializer(), TokenBody(name, expiresDays)), McpToken.serializer())
    override suspend fun revokeToken(id: String) { send("DELETE", "v1/mcp/tokens/" + java.net.URLEncoder.encode(id, "UTF-8"), null, null as KSerializer<Unit>?) }

    override fun chat(id: String, message: String): Flow<ChatEvent> = callbackFlow {
        val req = Request.Builder().url(base + s(id) + "/chat")
            .post(json.encodeToString(ChatBody.serializer(), ChatBody(message)).toRequestBody(jsonType)).build()
        // The server sends a keep-alive comment every 10 s while Claude (or the Mac) works.
        val sse = client.newBuilder().readTimeout(60, TimeUnit.SECONDS).build()
        val source = EventSources.createFactory(sse).newEventSource(req, object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                runCatching { json.decodeFromString(ChatEvent.serializer(), data) }.onSuccess { trySend(it) }
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                val e = if (response != null && !response.isSuccessful) errorOf(response.code, runCatching { response.body.string() }.getOrNull())
                else ApiException("offline", "The connection to Claude dropped · the turn keeps running on the server")
                trySend(ChatEvent("error", code = e.code, error = e.message))
                close()
            }
            override fun onClosed(eventSource: EventSource) { close() }
        })
        awaitClose { source.cancel() }
    }
}
