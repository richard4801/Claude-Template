package studio.muse.app.data

// Workstream 2: Claude on the owner's plan in the demo studio (no server, no Mac). It plays the server and the owner's Mac:
// a phone message is queued, the "Mac" claims it, streams text, runs a tool (a chip), stores the messages and finishes, all
// as live `claude` events. Switches put the Mac offline, turn Claude Code off or sign it out, and set the API fallback.

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class FakeClaudeApi(
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    /** Live events (type "claude") go out on the fake's event stream. */
    private val emit: (ApiEvent) -> Unit = {},
    /** Pause between the Mac's steps (0: as fast as the dispatcher runs them). */
    private val stepDelayMs: Long = 700,
) : ClaudeApi {
    private val lock = Mutex()
    private var seq = 0
    private fun uid(p: String) = p + (now().toString(36).takeLast(4) + (++seq).toString(36)).padStart(6, '0')

    @Volatile var mac = MacClaudeStatus(online = true, claudeCode = ClaudeCodeStatus(installed = true, signedIn = true, version = "2.4.1", model = "claude-opus-5-5"))
        private set
    @Volatile var fallback = ApiFallbackStatus(available = true, enabled = false)
        private set
    /** Tests: hold queued turns (the Mac never claims them) to see the "Waiting for your Mac…" state. */
    @Volatile var macClaims = true

    private val threads = mutableListOf<ClaudeThread>()
    private val messages = mutableMapOf<String, MutableList<ClaudeMessage>>()
    private val turns = mutableMapOf<String, ClaudeTurn>()
    private val jobs = mutableMapOf<String, Job>()

    private fun statusNow() = ClaudePlanStatus(mac, fallback, CONNECTOR_URL, OPEN_IN_CLAUDE_URL)
    private fun live(l: ClaudeLive) = emit(ApiEvent("claude", op = l.op, claude = l))
    private fun pushStatus() = live(ClaudeLive("status", status = statusNow()))

    /** Tests and the demo: the Mac app going online or offline, Claude Code installed / signed in. */
    fun setMac(online: Boolean, installed: Boolean = true, signedIn: Boolean = true) {
        mac = mac.copy(online = online, claudeCode = mac.claudeCode.copy(installed = installed, signedIn = signedIn))
        pushStatus()
    }

    /** Tests: the server's ANTHROPIC_API_KEY. */
    fun setKey(available: Boolean) { fallback = fallback.copy(available = available); pushStatus() }

    override suspend fun status() = statusNow()

    override suspend fun setApiFallback(on: Boolean): ClaudePlanStatus { fallback = fallback.copy(enabled = on); pushStatus(); return statusNow() }

    override suspend fun thread(contextKind: String, contextId: String): ClaudeThread = lock.withLock {
        // WS4: "recreate" (WS1 d7233b8): Claude on a Recreate reference, as on the server.
        if (contextKind != "camera" && contextKind != "edit" && contextKind != "recreate") throw ApiException("bad_request", "contextKind: camera, edit or recreate")
        threads.firstOrNull { it.contextKind == contextKind && it.contextId == contextId } ?: run {
            val t = ClaudeThread(uid("ct_"), contextKind, contextId, null, now(), now())
            threads += t
            messages[t.id] = seed(t)
            live(ClaudeLive("thread", thread = t))
            t
        }
    }

    override suspend fun getThread(id: String): ClaudeThread = lock.withLock {
        val t = threads.firstOrNull { it.id == id } ?: throw ApiException("not_found", "No such thread")
        t.copy(messages = messages[id].orEmpty().takeLast(100), activeTurn = turns.values.firstOrNull { it.threadId == id && it.active })
    }

    override suspend fun post(threadId: String, text: String): ClaudeSend {
        val (m, turn) = lock.withLock {
            threads.firstOrNull { it.id == threadId } ?: throw ApiException("not_found", "No such thread")
            if (text.isBlank()) throw ApiException("bad_request", "text: required")
            if (!mac.ready) return ClaudeSend.MacOffline(ClaudeFallback(OPEN_IN_CLAUDE_URL, fallback.usable))
            if (turns.values.any { it.threadId == threadId && it.active }) return ClaudeSend.Busy
            val turn = ClaudeTurn(uid("tu_"), threadId, text.take(8000), "phone", "queued", createdAt = now())
            turns[turn.id] = turn
            val m = ClaudeMessage(uid("cmsg_"), threadId, "user", "phone", turn.text, turn.id, createdAt = now())
            messages.getOrPut(threadId) { mutableListOf() } += m
            m to turn
        }
        live(ClaudeLive("message", threadId = threadId, message = m))
        live(ClaudeLive("turn", turn = turn))
        if (macClaims) jobs[turn.id] = scope.launch { runOnMac(turn) }
        return ClaudeSend.Sent(m, turn)
    }

    override suspend fun stop(turnId: String) {
        val t = lock.withLock { turns[turnId] } ?: throw ApiException("not_found", "No such turn")
        if (!t.active) return
        live(ClaudeLive("stop", turnId = turnId))
        jobs.remove(turnId)?.cancel()
        finish(t, "stopped", null)
        live(ClaudeLive("event", threadId = t.threadId, turnId = turnId, event = ClaudeEvent("done", ok = false, error = "Stopped")))
    }

    override fun apiTurn(threadId: String, text: String): Flow<ChatEvent> = flow {
        val refusal = lock.withLock {
            val t = threads.firstOrNull { it.id == threadId }
            when {
                t == null -> ChatEvent("error", code = "not_found", error = "No such thread")
                !fallback.usable -> ChatEvent("error", code = "fallback_off", error = "Turn on the API fallback in Settings → Connections")
                t.contextKind != "camera" -> ChatEvent("error", code = "bad_request", error = "The API fallback works in Camera stage for now")
                turns.values.any { it.threadId == threadId && it.active } -> ChatEvent("error", code = "claude_busy", error = "Claude is still answering")
                text.isBlank() -> ChatEvent("error", code = "bad_request", error = "text: required")
                else -> null
            }
        }
        if (refusal != null) { emit(refusal); return@flow }
        store(ClaudeMessage(uid("cmsg_"), threadId, "user", "api", text, createdAt = now()))
        delay(stepDelayMs)
        emit(ChatEvent("text", delta = "On the studio key: "))
        val tid = uid("tool_")
        emit(ChatEvent("tool", id = tid, name = "set_camera_path", status = "running"))
        delay(stepDelayMs)
        store(ClaudeMessage(uid("cmsg_"), threadId, "tool", "api", "", tool = ClaudeToolRef(tid, "set_camera_path", true, "Saved camera path"), createdAt = now()))
        emit(ChatEvent("tool", id = tid, name = "set_camera_path", status = "done", summary = "Saved camera path"))
        val answer = "lowered the camera to 1.2 m and kept the 50 mm lens. The path is saved."
        emit(ChatEvent("text", delta = answer))
        store(ClaudeMessage(uid("cmsg_"), threadId, "assistant", "api", "On the studio key: $answer", createdAt = now()))
        emit(ChatEvent("done", stopReason = "end_turn"))
    }

    // ---------------------------------------------------------------- the simulated Mac

    private suspend fun store(m: ClaudeMessage): ClaudeMessage {
        lock.withLock { messages.getOrPut(m.threadId) { mutableListOf() } += m }
        live(ClaudeLive("message", threadId = m.threadId, message = m))
        return m
    }

    private suspend fun finish(t: ClaudeTurn, state: String, error: String?) {
        val done = lock.withLock { (turns[t.id] ?: t).copy(state = state, error = error, finishedAt = now()).also { turns[t.id] = it } }
        live(ClaudeLive("turn", turn = done))
    }

    private suspend fun runOnMac(t0: ClaudeTurn) {
        delay(stepDelayMs)
        val t = lock.withLock { t0.copy(state = "running", claimedAt = now()).also { turns[it.id] = it } }
        live(ClaudeLive("turn", turn = t))
        val th = t.threadId
        fun ev(e: ClaudeEvent) = live(ClaudeLive("event", threadId = th, turnId = t.id, event = e))
        val kind = lock.withLock { threads.firstOrNull { it.id == th }?.contextKind } ?: "camera"
        val (first, tool, summary, last) = when (kind) { "edit" -> REPLY_EDIT; "recreate" -> REPLY_RECREATE; else -> REPLY_CAMERA }
        for (w in first.split(" ")) { delay(stepDelayMs / 6); ev(ClaudeEvent("text", delta = "$w ")) }
        store(ClaudeMessage(uid("cmsg_"), th, "assistant", "mac", first, t.id, createdAt = now()))
        val toolId = uid("toolu_")
        ev(ClaudeEvent("tool", id = toolId, name = "mcp__muse__$tool", status = "running"))
        delay(stepDelayMs)
        ev(ClaudeEvent("tool", id = toolId, name = "mcp__muse__$tool", status = "done", summary = summary))
        store(ClaudeMessage(uid("cmsg_"), th, "tool", "mac", "", t.id, ClaudeToolRef(toolId, "mcp__muse__$tool", true, summary), createdAt = now()))
        if (kind == "edit") {
            // Claude checks its edit: the frame it grabbed.
            store(ClaudeMessage(uid("cmsg_"), th, "tool", "mac", "", t.id, image = ClaudeImageRef("https://demo.muse.studio/uploads/frames/demo.png"), createdAt = now()))
        }
        for (w in last.split(" ")) { delay(stepDelayMs / 6); ev(ClaudeEvent("text", delta = "$w ")) }
        store(ClaudeMessage(uid("cmsg_"), th, "assistant", "mac", last, t.id, createdAt = now()))
        ev(ClaudeEvent("done", ok = true, model = mac.claudeCode.model))
        finish(t, "done", null)
        jobs.remove(t.id)
    }

    private fun seed(t: ClaudeThread): MutableList<ClaudeMessage> {
        if (t.contextKind != "camera" || t.contextId != FakeCameraApi.SEED_ID) return mutableListOf()
        val t0 = now()
        val min = 60_000L
        return mutableListOf(
            ClaudeMessage("cmsg_s1", t.id, "user", "mac", "Lower the camera to chest height and switch to a 50 mm lens.", "tu_s1", createdAt = t0 - 30 * min),
            ClaudeMessage("cmsg_s2", t.id, "tool", "mac", "", "tu_s1", ClaudeToolRef("toolu_s1", "mcp__muse__set_camera_path", true, null), createdAt = t0 - 29 * min),
            ClaudeMessage("cmsg_s3", t.id, "tool", "mac", "", "tu_s1", ClaudeToolRef("toolu_s2", "mcp__muse__create_shot_draft", true, "Shot draft · \$1.92"), createdAt = t0 - 29 * min),
            ClaudeMessage("cmsg_s4", t.id, "assistant", "mac", "Done: the camera sits at 1.2 m with a 50 mm lens, and the Shot draft is ready to generate when you are.", "tu_s1", createdAt = t0 - 28 * min),
        )
    }

    private data class Reply(val first: String, val tool: String, val summary: String, val last: String)

    companion object {
        const val CONNECTOR_URL = "https://demo.muse.studio/mcp"
        const val OPEN_IN_CLAUDE_URL = "https://claude.ai/new"
        private val REPLY_CAMERA = Reply(
            "Pushing in slower over the first 3 s and keeping both faces in frame.", "set_camera_path", "Saved camera path",
            "Saved. The push ends at 3.5 s, just as she turns to camera.",
        )
        /** WS4: Claude on a Recreate reference (demo): it reads the recipe and matches takes; it never spends. */
        private val REPLY_RECREATE = Reply(
            "Reading the recipe and your takes.", "match_slots", "Matched 3 of 7 shots to your takes",
            "Three shots come from your takes; the other four would be made new, about \$0.64 each. Say the word and I'll price them for you to approve.",
        )
        private val REPLY_EDIT = Reply(
            "Trimming the pause before the hook.", "apply_edit_ops", "Trimmed 0:03–0:05",
            "Trimmed 2 s; the hook now lands at 0:01. I checked the frame at 0:01.",
        )
    }
}
