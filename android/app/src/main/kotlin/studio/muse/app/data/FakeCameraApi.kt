package studio.muse.app.data

// Workstream 2: camera sessions in the demo studio (no server). A seeded "Café walk-and-talk" session blocked with the
// studio's own characters, a Direct with Claude turn that plays back tool steps, MCP tokens and Connections.

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.math.cos
import kotlin.math.sin

class FakeCameraApi(
    private val now: () -> Long = System::currentTimeMillis,
    /** The studio's characters (id → name), for the cast. */
    private val cast: () -> List<Pair<String, String>> = { listOf(SampleData.DEMO to "Demo model", SampleData.NOOR to "Noor Ellis") },
    /** Live events (`camera` / `blender`) go out on the fake's event stream. */
    private val emit: (ApiEvent) -> Unit = {},
    /** Pause between the chat turn's steps. */
    private val stepDelayMs: Long = 700,
) : CameraApi {
    private val lock = Mutex()
    private var seq = 0
    private fun uid(p: String) = p + (now().toString(36).takeLast(4) + (++seq).toString(36)).padStart(6, '0')

    /** Whether the server has ANTHROPIC_API_KEY (false → director_unavailable). */
    @Volatile var inAppChat = true
    @Volatile var relay = RelayStatus(online = true, blender = true, addonVersion = "1.8")
    @Volatile var appLastSeenAt: Long? = now() - 2 * 60_000

    private val sessions = mutableListOf<CameraSession>()
    private val messages = mutableMapOf<String, MutableList<CameraMessage>>()
    private val busy = mutableSetOf<String>()
    private val tokens = mutableListOf(McpToken("tok_1", "Claude Code · MacBook", "muse_pat_7f3a", now() - 3 * 86_400_000L, lastUsedAt = now() - 3 * 60_000))

    init { seed() }

    private fun name(id: String) = cast().firstOrNull { it.first == id }?.second ?: "Unknown model"
    private fun first(id: String) = name(id).substringBefore(' ')

    private fun seed() {
        val t0 = now()
        val demo = cast().getOrNull(0)?.first ?: SampleData.DEMO
        val noor = cast().getOrNull(1)?.first ?: SampleData.NOOR
        val id = SEED_ID
        val target = listOf(0.6, 1.5, 1.5)
        val p45 = listOf(-0.5, -1.0, 1.5)
        // Orbit 90° around the target from the 4.5 s key.
        val dx = p45[0] - target[0]; val dy = p45[1] - target[1]
        val p6 = listOf(target[0] + (dx * cos(Math.PI / 2) - dy * sin(Math.PI / 2)), target[1] + (dx * sin(Math.PI / 2) + dy * cos(Math.PI / 2)), 1.5)
        val path = CameraPath(listOf(
            CamKey(0.0, listOf(-0.6, -1.4, 1.5), target, 35.0, ease = "in_out"),
            CamKey(4.5, p45, target, 35.0, ease = "in_out"),
            CamKey(6.0, p6.map { Math.round(it * 100) / 100.0 }, target, 35.0, ease = "out"),
        ), cuts = emptyList(), sensorMm = 36.0)
        val blocking = Blocking(listOf(
            CharacterTrack(demo, listOf(
                CharKey(0.0, listOf(-2.6, 1.9, 0.0), 90.0, "walk → counter · 1.1 m/s"),
                CharKey(1.2, listOf(-1.3, 1.7, 0.0), 90.0),
                CharKey(2.4, listOf(0.0, 1.55, 0.0), 90.0),
                CharKey(3.5, listOf(1.2, 1.5, 0.0), 0.0, "turn · smile to camera"),
            )),
            CharacterTrack(noor, listOf(
                CharKey(0.0, listOf(-0.2, 3.3, 0.0), 0.0, "waits by window"),
                CharKey(3.0, listOf(-0.2, 3.3, 0.0), -60.0, "looks at ${first(demo)}"),
            )),
        ))
        val mins = 60_000L
        fun asset(k: String, type: String, bytes: Long, ago: Long, src: String = "relay") =
            CameraAsset("ca_${k.take(6)}", k, null, "ready", type, bytes, src, null, t0 - ago * mins)
        val assets = listOf(
            asset("greybox", "video/mp4", 4_200_000, 3), asset("depth", "video/mp4", 3_100_000, 3), asset("pose", "video/mp4", 2_600_000, 3),
            asset("keyframe_start", "image/png", 410_000, 3), asset("keyframe_mid", "image/png", 398_000, 3), asset("keyframe_end", "image/png", 402_000, 3),
            asset("camera_json", "application/json", 38_000, 3), asset("characters_json", "application/json", 52_000, 3),
            asset("blend", "application/octet-stream", 18_400_000, 2, "mcp"),
        )
        val s = CameraSession(
            id, "Café walk-and-talk", "A 6 s walk-and-talk in the café: ${first(demo)} enters left and turns to camera at the counter; ${first(noor)} waits by the window.",
            "ready", "9:16", 24, 6.0, "kling-v4.0", null,
            listOf(CameraCast(demo, name(demo), "lead", 1.72), CameraCast(noor, name(noor), "second", 1.68)),
            path, blocking, assets, draft(id, demo, 6.0, 1.92, t0 - 2 * mins), null, 4, relay, ClaudeStatus(false, appLastSeenAt), t0 - 40 * mins, t0 - 2 * mins,
        )
        val m = mutableListOf(
            CameraMessage("cm_1", "user", "app", "Block a 6 s walk-and-talk: ${first(demo)} enters left, turns to camera at the counter at 3.5 s. ${first(noor)} waits by the window. Push in, then orbit 90°.", null, t0 - 9 * mins),
            tool("cm_2", "blender_setup_scene", "café 6 × 4 m · 24 fps · 6.0 s", t0 - 8 * mins),
            tool("cm_3", "blender_place_character", "${name(demo)} · 1.72 m", t0 - 8 * mins),
            tool("cm_4", "blender_place_character", "${name(noor)} · 1.68 m", t0 - 8 * mins),
            tool("cm_5", "blender_set_camera", "35 mm · push 0.4 m · orbit 90°", t0 - 7 * mins),
            tool("cm_6", "blender_render_guides", "greybox · keyframes · camera.json · characters.json", t0 - 4 * mins),
            CameraMessage("cm_7", "assistant", "chat", "Built the café (6 × 4 m) and placed ${first(demo)} (1.72 m) and ${first(noor)} (1.68 m) from their sheets. 35 mm, eye level; push 0.4 m, then orbit 90°.", null, t0 - 3 * mins),
        )
        sessions += s
        messages[id] = m
        val s2 = CameraSession(
            "cs_k8d1tz3qv0wq", "Kitchen dance · intro", "", "blocking", "9:16", 24, 5.0, null, null, listOf(CameraCast(demo, name(demo), "lead", 1.72)),
            CameraPath(listOf(CamKey(0.0, listOf(0.0, -2.0, 1.4), listOf(0.0, 0.5, 1.3), 28.0))), Blocking(listOf(CharacterTrack(demo, listOf(CharKey(0.0, listOf(0.0, 0.5, 0.0), 0.0, "dance in place"))))),
            emptyList(), null, null, 2, relay, ClaudeStatus(false, appLastSeenAt), t0 - 26 * 60 * mins, t0 - 25 * 60 * mins,
        )
        sessions += s2
        messages[s2.id] = mutableListOf()
    }

    private fun tool(id: String, name: String, summary: String, at: Long, ok: Boolean = true) =
        CameraMessage(id, "tool", "chat", summary, CameraTool(name, ok, summary), at)

    private fun draft(sessionId: String, modelId: String, seconds: Double, usd: Double, at: Long): ShotDraft {
        val camera = buildJsonObject {
            put("mode", "directed")
            put("guide", buildJsonObject {
                put("video", buildJsonObject { put("key", "cam/$sessionId/ca_greybo.mp4"); put("seconds", seconds) })
                put("use", "blocking")
                put("cameraSessionId", sessionId)
                put("keyframes", buildJsonObject {
                    put("start", "/uploads/cam/$sessionId/ca_keyfra.png")
                    put("middle", JsonArray(listOf(JsonPrimitive("/uploads/cam/$sessionId/ca_keyfrb.png"))))
                    put("end", "/uploads/cam/$sessionId/ca_keyfrc.png")
                })
            })
        }
        val request = buildJsonObject {
            put("quality", "hd"); put("prompt", "Café walk-and-talk"); put("duration", seconds.toInt()); put("aspectRatio", "9:16"); put("modelId", modelId)
            put("camera", camera)
        }
        return ShotDraft("sd_" + sessionId.takeLast(6), "draft", "suite", "Café walk-and-talk", "kling-v4.0", seconds, "9:16", DraftEstimate(usd, usd * 100), camera, at, request)
    }

    private fun view(s: CameraSession, withMessages: Boolean) =
        s.copy(relay = relay, claude = ClaudeStatus(s.id in busy, appLastSeenAt), messages = if (withMessages) messages[s.id].orEmpty().takeLast(50) else null)

    private fun find(id: String) = sessions.firstOrNull { it.id == id } ?: throw ApiException("not_found", "No such camera session")

    private fun put(s: CameraSession): CameraSession {
        val i = sessions.indexOfFirst { it.id == s.id }
        if (i >= 0) sessions[i] = s else sessions.add(0, s)
        val v = view(s, false)
        emit(ApiEvent("camera", op = "upsert", session = v))
        return v
    }

    private fun bump(s: CameraSession, f: (CameraSession) -> CameraSession) = put(f(s).copy(revision = s.revision + 1, updatedAt = now()))

    private fun post(sessionId: String, m: CameraMessage): CameraMessage {
        messages.getOrPut(sessionId) { mutableListOf() }.add(m)
        emit(ApiEvent("camera", op = "message", sessionId = sessionId, message = m))
        return m
    }

    override suspend fun sessions() = lock.withLock { sessions.sortedByDescending { it.updatedAt }.map { view(it, false) } }
    override suspend fun session(id: String) = lock.withLock { view(find(id), true) }

    override suspend fun createSession(req: NewCameraSession): CameraSession = lock.withLock {
        val ids = cast().map { it.first }.toSet()
        req.characters?.forEach { if (it.modelId !in ids) throw ApiException("bad_request", "characters: not a character of this studio") }
        val s = CameraSession(
            "cs_" + uid("").lowercase().padEnd(12, 'x').take(12), req.title?.ifBlank { null } ?: "New camera session", req.brief.orEmpty(), "drafting",
            req.aspect ?: "9:16", req.fps ?: 24, req.durationSec ?: 6.0, characters = req.characters.orEmpty().map { CameraCast(it.modelId, name(it.modelId), it.role, it.heightM ?: 1.68) },
            revision = 1, createdAt = now(), updatedAt = now(),
        )
        messages[s.id] = mutableListOf()
        put(s).copy(messages = emptyList())
    }

    override suspend fun patchSession(id: String, patch: CameraSessionPatch): CameraSession = lock.withLock {
        val s = find(id)
        if (patch.revision != null && patch.revision != s.revision) throw ApiException("stale_revision", "This session changed since you opened it")
        bump(s) { it.copy(title = patch.title ?: it.title, brief = patch.brief ?: it.brief, status = patch.status ?: it.status, aspect = patch.aspect ?: it.aspect,
            fps = patch.fps ?: it.fps, durationSec = patch.durationSec ?: it.durationSec, targetModel = patch.targetModel ?: it.targetModel) }
    }

    override suspend fun deleteSession(id: String) = lock.withLock {
        find(id)
        sessions.removeAll { it.id == id }
        messages.remove(id)
        emit(ApiEvent("camera", op = "delete", id = id))
    }

    override suspend fun putPath(id: String, req: PathUpdate): CameraSession = lock.withLock {
        val s = find(id)
        val ids = s.characters.map { it.modelId }.toSet()
        req.characters?.forEach { if (it.modelId !in ids) throw ApiException("bad_request", "characters: ${it.modelId} is not in the cast") }
        bump(s) { it.copy(cameraPath = req.camera ?: it.cameraPath, blocking = req.characters?.let { c -> Blocking(c) } ?: it.blocking,
            status = if (it.status == "drafting") "blocking" else it.status) }
    }

    override suspend fun postNote(id: String, text: String) = lock.withLock {
        find(id)
        post(id, CameraMessage(uid("cm_"), "user", "app", text.take(4000), null, now()))
    }

    override suspend fun shotDraft(id: String, req: ShotDraftRequest): ShotDraft = lock.withLock {
        val s = find(id)
        val sec = req.durationSec ?: s.durationSec
        val d = draft(s.id, s.characters.firstOrNull()?.modelId ?: SampleData.DEMO, sec, Math.round(sec * 0.32 * 100) / 100.0, now())
            .let { if (s.assets.none { a -> a.kind == "greybox" && a.ready }) it.copy(request = it.request?.let { r -> JsonObject(r + ("camera" to buildJsonObject { put("mode", "directed") })) }, camera = null) else it }
        bump(s) { it.copy(shotDraft = d) }
        d
    }

    override suspend fun linkJob(id: String, jobId: String) = lock.withLock {
        val s = find(id)
        val d = s.shotDraft ?: throw ApiException("no_draft", "Make a Shot draft first")
        bump(s) { it.copy(shotDraft = d.copy(jobId = jobId, linkedAt = now()), status = "generating") }
    }

    override fun chat(id: String, message: String): Flow<ChatEvent> = flow {
        val start = lock.withLock {
            val s = find(id)
            when {
                !inAppChat -> ChatEvent("error", code = "director_unavailable", error = "Direct with Claude isn't set up on the server yet")
                id in busy -> ChatEvent("error", code = "chat_busy", error = "Claude is still working on this shot · wait for the reply")
                message.isBlank() -> ChatEvent("error", code = "bad_request", error = "message: required")
                else -> { busy += id; put(s); null }
            }
        }
        if (start != null) { emit(start); return@flow }
        try {
            emit(ChatEvent("message", message = lock.withLock { post(id, CameraMessage(uid("cm_"), "user", "chat", message, null, now())) }))
            val focus = cast().getOrNull(1)?.second?.substringBefore(' ') ?: "the cast"
            delay(stepDelayMs)
            emit(ChatEvent("text", delta = "Easing the orbit to 45°/s and pivoting around $focus…"))
            suspend fun step(name: String, summary: String, waitMac: Boolean) {
                val tid = uid("tu_")
                emit(ChatEvent("tool", id = tid, name = name, status = "running"))
                if (waitMac) emit(ChatEvent("waiting", reason = "blender"))
                delay(stepDelayMs)
                lock.withLock { post(id, tool(uid("cm_"), name, summary, now())) }
                emit(ChatEvent("tool", id = tid, name = name, status = "done", summary = summary))
            }
            step("blender_set_camera", "orbit 90° · 4.5–6.0 s · ease out", true)
            lock.withLock { bump(find(id)) { s -> s.copy(cameraPath = s.cameraPath?.let { p -> p.copy(keyframes = p.keyframes.map { k -> if (k.t == 4.5) k.copy(t = 4.0) else k }) }) } }
            step("blender_render_guides", "greybox · keyframes · camera.json · characters.json", true)
            val text = "Slowed the orbit (90° over 2.0 s, ease out) and kept $focus's face in frame at the end. New guides are ready."
            emit(ChatEvent("text", delta = "\n$text"))
            emit(ChatEvent("message", message = lock.withLock { post(id, CameraMessage(uid("cm_"), "assistant", "chat", text, null, now())) }))
            emit(ChatEvent("done", stopReason = "end_turn"))
        } finally {
            lock.withLock { busy -= id; sessions.firstOrNull { it.id == id }?.let { put(it) } }
        }
    }

    override suspend fun connections() = Connections(relay, ClaudeAppStatus(appLastSeenAt, tokens.size), "https://demo.muse.studio/mcp", inAppChat,
        "https://github.com/richard4801/claude-template/blob/main/plans/mcp-bridge.md")

    override suspend fun tokens() = lock.withLock { tokens.toList() }

    override suspend fun createToken(name: String, expiresDays: Int?): McpToken = lock.withLock {
        if (name.isBlank()) throw ApiException("bad_request", "name: required")
        val secret = "muse_pat_" + (1..32).map { "abcdefghijklmnopqrstuvwxyz0123456789"[(now() / (it + 1) + it * 7 + seq).mod(36).toInt()] }.joinToString("")
        val t = McpToken(uid("tok_"), name.trim().take(60), secret.take(13), now(), null, expiresDays?.let { now() + it * 86_400_000L })
        tokens.add(0, t)
        t.copy(token = secret)
    }

    override suspend fun revokeToken(id: String) = lock.withLock { tokens.removeAll { it.id == id }; Unit }

    /** Tests: a relay change as the Mac would report it. */
    fun setRelay(r: RelayStatus) {
        relay = r
        emit(ApiEvent("blender", op = "relay", online = r.online, blender = r.blender, addonVersion = r.addonVersion))
    }

    companion object {
        const val SEED_ID = "cs_7q2m4x9kfb2a"
    }
}
