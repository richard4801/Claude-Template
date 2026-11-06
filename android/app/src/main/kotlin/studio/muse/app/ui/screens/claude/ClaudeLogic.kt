package studio.muse.app.ui.screens.claude

// Pure logic of the Claude chat (plans/claude-editing.md parts D and E): the transcript reducer (stored messages + live
// `claude` events), the status line, tool chip words, and what to offer when the Mac is offline. No Compose here.

import studio.muse.app.data.ChatEvent
import studio.muse.app.data.ClaudeEvent
import studio.muse.app.data.ClaudeFallback
import studio.muse.app.data.ClaudeLive
import studio.muse.app.data.ClaudeMessage
import studio.muse.app.data.ClaudePlanStatus
import studio.muse.app.data.ClaudeThread
import studio.muse.app.data.ClaudeTurn
import java.util.Locale

// ---------------------------------------------------------------- chips

object ChipText {
    /** `mcp__muse__set_camera_path` → `set_camera_path` (any MCP server prefix). */
    fun bare(name: String): String = if (name.startsWith("mcp__")) name.removePrefix("mcp__").substringAfter("__") else name

    private val USD = Regex("""\$\s?(\d+(?:\.\d+)?)""")

    /** "$1.92" from a summary like "Shot draft · estimate $1.92", or null. */
    fun usd(summary: String?): String? = summary?.let { USD.find(it) }?.groupValues?.get(1)?.toDoubleOrNull()?.let { String.format(Locale.US, "$%.2f", it) }

    /** Tool name in words: `cut_silences` → "Cut silences". */
    fun words(name: String): String = bare(name).removePrefix("blender_").replace('_', ' ').trim().replaceFirstChar { it.uppercase() }.ifEmpty { "Tool" }

    /**
     * The chip's words, the same mapping as the Mac: `set_camera_path` → "Saved camera path", `create_shot_draft` →
     * "Shot draft · $1.92", other tools → the summary the Mac sent ("Trimmed 0:03–0:05"), else the name in words.
     */
    fun of(name: String, summary: String? = null, running: Boolean = false): String {
        val n = bare(name)
        val s = summary?.trim()?.takeIf { it.isNotEmpty() }
        if (running) return when (n) {
            "set_camera_path" -> "Saving camera path…"
            "create_shot_draft" -> "Making a shot draft…"
            "get_frame" -> "Grabbing a frame…"
            else -> words(n) + "…"
        }
        return when (n) {
            "set_camera_path" -> "Saved camera path"
            "create_shot_draft" -> "Shot draft" + (usd(s)?.let { " · $it" } ?: "")
            "attach_guide_media" -> "Upload link ready"
            "blender_render_guides" -> "Rendered guides"
            "get_frame" -> s ?: "Grabbed a frame"
            "save_version" -> s ?: "Saved a version"
            else -> s ?: words(n)
        }
    }
}

// ---------------------------------------------------------------- the transcript

/** What streams in before it is stored: text, a tool chip, a frame (base64). */
sealed interface LivePart {
    data class Text(val text: String) : LivePart
    data class Tool(val id: String, val name: String, val status: String, val summary: String? = null) : LivePart
    data class Image(val data: String, val mimeType: String) : LivePart
}

/** The turn in flight on this thread: relayed to the Mac (a [ClaudeTurn]) or on the studio API key ([api]). */
data class LiveTurn(
    val id: String?, val state: String = "queued", val from: String = "phone", val text: String = "",
    val parts: List<LivePart> = emptyList(), val stopping: Boolean = false, val api: Boolean = false, val error: String? = null,
) {
    val active get() = state == "queued" || state == "running"
}

/** One row of the transcript. */
sealed interface ChatItem {
    val key: String
    data class User(override val key: String, val text: String, val source: String) : ChatItem
    data class Assistant(override val key: String, val text: String, val streaming: Boolean = false) : ChatItem
    data class Tool(override val key: String, val text: String, val ok: Boolean, val running: Boolean = false) : ChatItem
    /** A frame Claude grabbed: [url] when stored, [data] (base64) while it streams. */
    data class Image(override val key: String, val url: String? = null, val data: String? = null, val mimeType: String? = null) : ChatItem
}

/** The chat's state for one thread. */
data class ClaudeChatUi(
    val contextKind: String = "camera",
    val contextId: String = "",
    val thread: ClaudeThread? = null,
    val messages: List<ClaudeMessage> = emptyList(),
    val turn: LiveTurn? = null,
    val status: ClaudePlanStatus? = null,
    /** The last `mac_offline` refusal (cleared once the Mac is back). */
    val refusal: ClaudeFallback? = null,
    /** The text the Mac couldn't take, for "Use the studio API key". */
    val refusedText: String? = null,
    val draft: String = "",
    val notice: String? = null,
    val loaded: Boolean = false,
    val error: String? = null,
) {
    val busy get() = turn?.active == true
    val items get() = ChatReducer.items(this)
}

object ChatReducer {
    fun loaded(ui: ClaudeChatUi, t: ClaudeThread): ClaudeChatUi {
        val active = t.activeTurn
        val turn = when {
            active != null && ui.turn?.id == active.id -> ui.turn.copy(state = active.state)
            active != null -> LiveTurn(active.id, active.state, active.from, active.text)
            // Stored now: the live parts are in the messages.
            ui.turn?.api == true && ui.turn.active -> ui.turn
            // Keep "Stopped" / the failure under the transcript; the parts are stored now.
            else -> ui.turn?.takeIf { it.state == "stopped" || it.state == "failed" }?.copy(parts = emptyList())
        }
        return ui.copy(thread = t.copy(messages = null, activeTurn = null), messages = t.messages ?: ui.messages, turn = turn, loaded = true, error = null)
    }

    /** One live `claude` event. Events of other threads are ignored. */
    fun live(ui: ClaudeChatUi, l: ClaudeLive): ClaudeChatUi {
        val tid = ui.thread?.id
        return when (l.op) {
            "status" -> l.status?.let { s -> ui.copy(status = s, refusal = if (s.mac.ready) null else ui.refusal) } ?: ui
            "thread" -> l.thread?.let { t -> if (t.id == tid) ui.copy(thread = t.copy(messages = null, activeTurn = null)) else ui } ?: ui
            "message" -> { val m = l.message; if (m == null || tid == null || (l.threadId ?: m.threadId) != tid) ui else message(ui, m) }
            "event" -> { val e = l.event; if (e == null || tid == null || l.threadId != tid) ui else event(ui, l.turnId, e) }
            "turn" -> l.turn?.let { t -> if (t.threadId != tid) ui else turn(ui, t) } ?: ui
            "stop" -> if (l.turnId != null && ui.turn?.id == l.turnId) ui.copy(turn = ui.turn.copy(stopping = true)) else ui
            else -> ui
        }
    }

    /** A stored message: added once (by id); it replaces the live part it stands for. */
    fun message(ui: ClaudeChatUi, m: ClaudeMessage): ClaudeChatUi {
        if (ui.messages.any { it.id == m.id }) return ui
        val t = ui.turn
        val parts = t?.parts.orEmpty().let { ps ->
            when {
                m.role == "assistant" && m.text.isNotBlank() -> ps.filterNot { it is LivePart.Text && it.text.trim().let { x -> x.isEmpty() || m.text.contains(x) } }
                m.image != null -> { val i = ps.indexOfFirst { it is LivePart.Image }; if (i >= 0) ps.filterIndexed { j, _ -> j != i } else ps }
                m.tool != null -> ps.filterNot { it is LivePart.Tool && it.id == m.tool.id }
                else -> ps
            }
        }
        return ui.copy(messages = ui.messages + m, turn = t?.copy(parts = parts))
    }

    fun event(ui: ClaudeChatUi, turnId: String?, e: ClaudeEvent): ClaudeChatUi {
        val t0 = ui.turn
        // The Mac's own turn (no turnId) or one this device didn't start: follow it.
        val t = when {
            t0 != null && ((turnId != null && t0.id == turnId) || (t0.active && (turnId == null || t0.id == null))) -> t0.copy(id = t0.id ?: turnId)
            e.type == "done" -> return ui
            else -> LiveTurn(turnId, "running", if (turnId == null) "mac" else "phone")
        }
        val running = if (t.state == "queued") t.copy(state = "running") else t
        return when (e.type) {
            "text" -> ui.copy(turn = running.copy(parts = appendText(running.parts, e.delta.orEmpty())))
            "tool" -> {
                val id = e.id ?: return ui
                if (ui.messages.any { it.tool?.id == id }) return ui.copy(turn = running)
                val part = LivePart.Tool(id, e.name ?: "tool", e.status ?: "running", e.summary)
                val i = running.parts.indexOfFirst { it is LivePart.Tool && it.id == id }
                ui.copy(turn = running.copy(parts = if (i >= 0) running.parts.toMutableList().also { it[i] = part } else running.parts + part))
            }
            "image" -> e.data?.let { d -> ui.copy(turn = running.copy(parts = running.parts + LivePart.Image(d, e.mimeType ?: "image/png"))) } ?: ui
            "done" -> ui.copy(turn = running.copy(state = if (e.ok == false) (if (running.stopping) "stopped" else "failed") else "done", error = e.error))
            // user / assistant arrive as stored messages.
            else -> ui.copy(turn = running)
        }
    }

    fun turn(ui: ClaudeChatUi, t: ClaudeTurn): ClaudeChatUi {
        val cur = ui.turn
        return when {
            cur != null && cur.id == t.id -> ui.copy(turn = cur.copy(state = t.state, error = t.error ?: cur.error))
            t.active -> ui.copy(turn = LiveTurn(t.id, t.state, t.from, t.text))
            else -> ui
        }
    }

    private fun appendText(parts: List<LivePart>, delta: String): List<LivePart> {
        if (delta.isEmpty()) return parts
        val last = parts.lastOrNull()
        return if (last is LivePart.Text) parts.dropLast(1) + LivePart.Text(last.text + delta) else parts + LivePart.Text(delta)
    }

    /** The studio-API fallback's stream (camera chat ChatEvents) applied to the live turn. */
    fun api(ui: ClaudeChatUi, ev: ChatEvent): ClaudeChatUi {
        val t = ui.turn ?: return ui
        return when (ev.type) {
            "text" -> ui.copy(turn = t.copy(state = "running", parts = appendText(t.parts, ev.delta.orEmpty())))
            "tool" -> {
                val id = ev.id ?: return ui
                val part = LivePart.Tool(id, ev.name ?: "tool", if (ev.status == "running") "running" else if (ev.status == "error") "error" else "done", ev.summary)
                val i = t.parts.indexOfFirst { it is LivePart.Tool && it.id == id }
                ui.copy(turn = t.copy(state = "running", parts = if (i >= 0) t.parts.toMutableList().also { it[i] = part } else t.parts + part))
            }
            "error" -> ui.copy(turn = t.copy(state = "failed", error = ev.error), notice = ev.error ?: "Claude couldn't finish")
            "done" -> ui.copy(turn = t.copy(state = "done"))
            else -> ui
        }
    }

    /** Stored messages, then (while a turn runs, or until the stored messages replace them) the live parts. */
    fun items(ui: ClaudeChatUi): List<ChatItem> {
        val out = mutableListOf<ChatItem>()
        for (m in ui.messages) when {
            m.role == "user" -> out += ChatItem.User(m.id, m.text, m.source)
            m.image != null -> out += ChatItem.Image(m.id, url = m.image.url)
            m.role == "tool" || m.tool != null -> m.tool?.let { tl -> out += ChatItem.Tool(m.id, ChipText.of(tl.name, tl.summary ?: m.text.takeIf { it.isNotBlank() }), tl.ok != false) }
            m.text.isNotBlank() -> out += ChatItem.Assistant(m.id, m.text)
        }
        val t = ui.turn ?: return out
        // The phone's message before it is stored (the API fallback stores it with the turn).
        if (t.text.isNotBlank() && ui.messages.none { it.role == "user" && (it.turnId == t.id && t.id != null || it.text == t.text) }) out += ChatItem.User("live-user", t.text, if (t.api) "api" else "phone")
        t.parts.forEachIndexed { i, p ->
            out += when (p) {
                is LivePart.Text -> ChatItem.Assistant("live-$i", p.text.trimEnd(), streaming = t.active && i == t.parts.lastIndex)
                is LivePart.Tool -> ChatItem.Tool("live-${p.id}", ChipText.of(p.name, p.summary, running = p.status == "running"), p.status != "error", running = p.status == "running")
                is LivePart.Image -> ChatItem.Image("live-img-$i", data = p.data, mimeType = p.mimeType)
            }
        }
        return out.filterNot { it is ChatItem.Assistant && it.text.isBlank() }
    }
}

// ---------------------------------------------------------------- the status line

enum class Tone { GOOD, WAIT, OFF }

data class StatusLineText(val text: String, val tone: Tone)

object ClaudeText {
    const val MODE = "On your Claude plan · answered by your Mac"
    const val ANSWERING = "Your Mac is answering · On your Claude plan"
    const val WAITING = "Waiting for your Mac…"
    const val OFFLINE = "Your Mac is offline"
    const val API = "Answering on the studio API key · billed per use"
    const val STOPPING = "Stopping…"
    const val CONNECTOR_NOTE = "MUSE has to be added to Claude as a connector first."
    const val FALLBACK_NOTE = "Turn on the API fallback in Settings → Connections"
    const val NO_KEY_NOTE = "The API fallback needs ANTHROPIC_API_KEY on the server"
    const val EDIT_NO_API = "The studio API key works in Camera stage for now"

    fun status(ui: ClaudeChatUi): StatusLineText {
        val t = ui.turn
        val mac = ui.status?.mac
        return when {
            t != null && t.active && t.stopping -> StatusLineText(STOPPING, Tone.WAIT)
            t != null && t.active && t.api -> StatusLineText(API, Tone.WAIT)
            t != null && t.state == "queued" -> StatusLineText(WAITING, Tone.WAIT)
            t != null && t.state == "running" -> StatusLineText(ANSWERING, Tone.GOOD)
            ui.refusal != null -> StatusLineText(OFFLINE, Tone.OFF)
            mac == null -> StatusLineText(MODE, Tone.GOOD)
            !mac.online -> StatusLineText(OFFLINE, Tone.OFF)
            !mac.claudeCode.installed -> StatusLineText("Claude Code isn't installed on your Mac", Tone.OFF)
            !mac.claudeCode.signedIn -> StatusLineText("Sign in to Claude Code on your Mac", Tone.OFF)
            else -> StatusLineText(MODE, Tone.GOOD)
        }
    }

    /** A finished turn's line under the transcript ("Stopped", "Your Mac didn't pick this up"), or null. */
    fun ended(t: LiveTurn?): String? = when (t?.state) {
        "stopped" -> "Stopped"
        "failed" -> t.error?.takeIf { it.isNotBlank() } ?: "Claude couldn't finish this turn"
        else -> null
    }

    /** "YOU · PHONE" / "YOU · MAC" / "YOU · API KEY". */
    fun youLabel(source: String) = when (source) { "mac" -> "You · Mac"; "api" -> "You · API key"; else -> "You · Phone" }
}

// ---------------------------------------------------------------- Mac offline: what to offer

/** What the "Mac offline" card shows. [openInClaude] null hides the card. */
data class FallbackChoice(val openInClaude: String?, val useApiKey: Boolean, val note: String?)

object Fallback {
    /**
     * Nothing while the Mac with Claude Code is ready and nothing was refused. Otherwise Open in Claude (the refusal's URL,
     * else the status's), plus "Use the studio API key" only when the fallback is on and the key is set (camera threads only
     * for now), else a quiet note.
     */
    fun decide(status: ClaudePlanStatus?, refusal: ClaudeFallback?, contextKind: String): FallbackChoice? {
        if (refusal == null && (status == null || status.mac.ready)) return null
        val url = refusal?.openInClaudeUrl?.takeIf { it.isNotBlank() } ?: status?.openInClaudeUrl?.takeIf { it.isNotBlank() } ?: "https://claude.ai/new"
        val api = refusal?.apiFallback ?: (status?.apiFallback?.usable == true)
        return when {
            contextKind != "camera" -> FallbackChoice(url, false, EDIT_NOTE)
            api -> FallbackChoice(url, true, null)
            status != null && !status.apiFallback.available -> FallbackChoice(url, false, ClaudeText.NO_KEY_NOTE)
            else -> FallbackChoice(url, false, ClaudeText.FALLBACK_NOTE)
        }
    }

    private const val EDIT_NOTE = ClaudeText.EDIT_NO_API
}
