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
     * The chip's words: the summary the Mac sent, as is ("Trimmed to 0:00.5–0:06.0", "Shot draft · estimate $1.92"); without
     * one, the same mapping as the Mac (`set_camera_path` → "Saved camera path", editing tools in words), else the name in words.
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
        // The Mac (and the server) fill the summary from the tool result's label: shown as is.
        if (s != null) return s
        return when (n) {
            "set_camera_path" -> "Saved camera path"
            "create_shot_draft" -> "Shot draft"
            "attach_guide_media" -> "Upload link ready"
            "blender_render_guides" -> "Rendered guides"
            "list_takes" -> "Looked at your takes"
            "open_edit" -> "Opened the edit"
            "get_edit" -> "Read the edit"
            "apply_edit_ops" -> "Edited"
            "undo_edit" -> "Undid an edit"
            "list_looks" -> "Looked at the Looks"
            "list_caption_styles" -> "Looked at caption styles"
            "auto_captions" -> "Added captions"
            "cut_silences" -> "Cut silences"
            "cut_fillers" -> "Cut filler words"
            "remove_background" -> "Removed the background"
            "detect_beats" -> "Found the beats"
            "denoise" -> "Cleaned up the audio"
            "get_frame" -> "Grabbed a frame"
            "get_contact_sheet" -> "Checked a contact sheet"
            "save_version" -> "Saved a version"
            "export_video" -> "Started an export"
            else -> words(n)
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
    /** [images]: the attached images' links (thumbnails). */
    data class User(override val key: String, val text: String, val source: String, val images: List<String> = emptyList(), val at: Long = 0) : ChatItem
    data class Assistant(override val key: String, val text: String, val streaming: Boolean = false, val at: Long = 0) : ChatItem
    /** [detail]: the short line a tap shows ("Set camera path, done"). */
    data class Tool(override val key: String, val text: String, val ok: Boolean, val running: Boolean = false, val detail: String = "") : ChatItem
    /** A frame Claude grabbed: [url] when stored, [data] (base64) while it streams. */
    data class Image(override val key: String, val url: String? = null, val data: String? = null, val mimeType: String? = null) : ChatItem
}

/** The chat's state for one thread. */
/** An image picked for the next message: its local [preview] and, once uploaded, its [uploadId]. */
/** [unsupported]: the server refused the format (415 unsupported_image), so the chip offers "Send as JPEG". */
data class ChatAttachment(val key: String, val preview: String, val uploadId: String? = null, val error: String? = null, val unsupported: Boolean = false)

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
    /** Images picked for the next message (Recreate, Edit and Suite threads; ≤ 4): uploading until [ChatAttachment.uploadId]. */
    val attachments: List<ChatAttachment> = emptyList(),
) {
    val busy get() = turn?.active == true
    /** Attaching images: not in Camera stage yet (the server refuses them there). */
    val canAttach get() = contextKind != "camera"
    val uploading get() = attachments.any { it.uploadId == null && it.error == null }
    val canSend get() = loaded && thread != null && !busy && !uploading && (draft.isNotBlank() || attachments.any { it.uploadId != null && it.error == null })
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
            m.role == "user" -> out += ChatItem.User(m.id, ChatClean.userText(m.text), m.source, m.attachments.map { it.url }, m.createdAt)
            m.image != null -> out += ChatItem.Image(m.id, url = m.image.url)
            m.role == "tool" || m.tool != null -> m.tool?.let { tl -> out += tool(m.id, tl.name, ChatClean.summary(tl.summary ?: m.text), if (tl.ok == false) "error" else "done") }
            m.text.isNotBlank() -> out += ChatItem.Assistant(m.id, ChatClean.assistantText(m.text), at = m.createdAt)
        }
        val t = ui.turn ?: return out
        // The phone's message before it is stored (the API fallback stores it with the turn).
        if (t.text.isNotBlank() && ui.messages.none { it.role == "user" && (it.turnId == t.id && t.id != null || it.text == t.text) })
            out += ChatItem.User("live-user", ChatClean.userText(t.text), if (t.api) "api" else "phone")
        t.parts.forEachIndexed { i, p ->
            out += when (p) {
                is LivePart.Text -> ChatItem.Assistant("live-$i", ChatClean.assistantText(p.text).trimEnd(), streaming = t.active && i == t.parts.lastIndex)
                is LivePart.Tool -> tool("live-${p.id}", p.name, ChatClean.summary(p.summary), p.status)
                is LivePart.Image -> ChatItem.Image("live-img-$i", data = p.data, mimeType = p.mimeType)
            }
        }
        return out.filterNot { it is ChatItem.Assistant && it.text.isBlank() || it is ChatItem.User && it.text.isBlank() && it.images.isEmpty() }
    }

    /** A tool row: its words, and the line a tap shows. Never the raw name, input or output. */
    private fun tool(key: String, name: String, summary: String?, status: String): ChatItem.Tool {
        val running = status == "running"
        val ok = status != "error"
        val text = ChipText.of(name, summary, running)
        val what = ChipText.of(name, null, false)
        val detail = when {
            running -> "$what, in progress"
            !ok -> "$what didn't work. Claude can try another way."
            summary != null && summary != what -> "$what: $summary"
            else -> "$what, done"
        }
        return ChatItem.Tool(key, if (!ok) "$what didn't work" else text, ok, running, detail)
    }

    /** The owner's last message (for Retry): the live turn's, else the newest stored one. */
    fun lastUserText(ui: ClaudeChatUi): String? =
        ui.turn?.text?.takeIf { it.isNotBlank() } ?: ui.messages.lastOrNull { it.role == "user" && it.text.isNotBlank() }?.text?.let(ChatClean::userText)
}

// ---------------------------------------------------------------- the status line

enum class Tone { GOOD, WAIT, OFF }

data class StatusLineText(val text: String, val tone: Tone)

object ClaudeText {
    const val MODE = "On your Claude plan, answered by your Mac"
    const val ANSWERING = "Your Mac is answering"
    const val WAITING = "Waiting for your Mac…"
    const val OFFLINE = "Claude on your Mac is offline"
    const val API = "Answering on the studio API key, billed per use"
    const val STOPPING = "Stopping…"
    const val CONNECTOR_NOTE = "MUSE has to be added to Claude as a connector first."
    const val FALLBACK_NOTE = "Turn on the API fallback in Settings → Connections"
    const val NO_KEY_NOTE = "The API fallback isn't set up on the server yet"
    const val EDIT_NO_API = "The studio API key works in Camera stage and the Suite for now"

    /** The empty chat's line, per context. */
    fun empty(contextKind: String) = when (contextKind) {
        "edit" -> "Tell Claude what to change: trims, captions, the look, the music. Every change can be undone."
        "recreate" -> "Ask Claude about this reference: which takes fit, what each new shot would cost, how to write the briefs."
        "suite" -> "Describe the shot you want. Claude sets up the composer: the model, the prompt and the rig. You approve the price before anything is made."
        else -> "Tell Claude what happens in the shot: who moves where, when, and how the camera moves."
    }

    fun placeholder(contextKind: String) = when (contextKind) {
        "edit" -> "Ask Claude to edit…"
        "suite" -> "Describe the shot…"
        "camera" -> "Direct the shot…"
        else -> "Message Claude…"
    }

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
        "failed" -> ChatClean.error(t.error)
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
            // The studio API key answers Camera stage and Claude in the Suite (WS1 1eda187: api-turn with the Suite tools).
            contextKind != "camera" && contextKind != "suite" -> FallbackChoice(url, false, EDIT_NOTE)
            api -> FallbackChoice(url, true, null)
            status != null && !status.apiFallback.available -> FallbackChoice(url, false, ClaudeText.NO_KEY_NOTE)
            else -> FallbackChoice(url, false, ClaudeText.FALLBACK_NOTE)
        }
    }

    private const val EDIT_NOTE = ClaudeText.EDIT_NO_API
}

// ---------------------------------------------------------------- what the chat may show (plans/claude-chat-android.md)

/**
 * Keeps internal content out of the chat: the context line the Mac puts before a typed message ("[Suite · Shot …]"),
 * system-brief tags, raw JSON, stack traces, file paths and internal ids. What's left is plain language.
 */
object ChatClean {
    /** "[Suite · Shot · draft 3]", "[Camera session cs_1 · revision 4 …]": a bracketed first line the Mac adds. */
    private val CONTEXT_LINE = Regex("""^\[[A-Z][^\]\n]{0,2000}]\s*(\n|$)""")
    private val BRIEF_TAG = Regex("""<(system|system-reminder|muse[-_][a-z_-]+|context|brief)\b[^>]*>[\s\S]*?</\1>\s*""", RegexOption.IGNORE_CASE)
    private val PATH = Regex("""(?<![\w.])(?:/(?:Users|home|var|tmp|private|data|opt|srv|app)/[^\s'"),]+|[A-Z]:\\[^\s'"),]+)""")
    /** An internal id: a short prefix, an underscore, and 6+ characters with a digit in them ("tk_8a7sdf9a", "toolu_01AB…"). */
    private val ID = Regex("""\b[a-z]{1,8}_(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{6,}\b""")
    /** Low-level error codes and words that mean nothing to a person. */
    private val TECH = Regex("""\bE[A-Z]{4,}\b|\b(?:errno|undefined|null pointer|NaN|stderr|stdout|exit code|status code|HTTP \d{3})\b""", RegexOption.IGNORE_CASE)
    private val STACK = Regex("""(?m)^\s*(at [\w.$]+\(|File ".*", line \d+|Traceback \(most recent call last\)|\w+(Exception|Error):\s)""")
    private val TOOL_NAME = Regex("""\bmcp__\w+""")

    /** What the owner typed, without the context line or any brief the Mac wrapped around it. */
    fun userText(text: String): String {
        var t = text
        repeat(3) { t = t.replace(BRIEF_TAG, "") }
        while (true) { val m = CONTEXT_LINE.find(t.trimStart()) ?: break; t = t.trimStart().substring(m.range.last + 1) }
        return t.trim()
    }

    /** Claude's reply, without system-brief tags it may have echoed. Markdown stays (the view renders it). */
    fun assistantText(text: String): String = text.replace(BRIEF_TAG, "")

    /**
     * A tool's summary as a short line, or null when it's internal (JSON, a path, an id, a long dump): the chip then uses
     * the tool's name in words.
     */
    fun summary(s: String?): String? {
        val t = s?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (t.startsWith("{") || t.startsWith("[") || t.contains("\":") || STACK.containsMatchIn(t) || TOOL_NAME.containsMatchIn(t)) return null
        val line = t.lineSequence().first().replace(PATH, "a file").replace(ID, "").replace(Regex("""\s{2,}"""), " ").trim()
        if (line.isEmpty()) return null
        return if (line.length > 80) line.take(77).trimEnd() + "…" else line
    }

    /**
     * An error as one plain sentence: a timeout, the network, or the fallback. Stack traces, JSON, paths and ids never
     * reach the screen. [fallback] when there's nothing usable.
     */
    fun error(raw: String?, fallback: String = FAILED): String {
        val t = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return fallback
        val low = t.lowercase()
        return when {
            "timed out" in low || "timeout" in low -> "Claude took too long to answer. Try again."
            "unable to resolve host" in low || "failed to connect" in low || "econnrefused" in low || "econnreset" in low || "connection reset" in low ||
                "network" in low && "error" in low -> "Couldn't reach the studio. Check your connection and try again."
            "rate limit" in low || "429" in low || "overloaded" in low -> "Claude is busy right now. Try again in a minute."
            STACK.containsMatchIn(t) || t.startsWith("{") || t.startsWith("[") || t.contains("\":") || TOOL_NAME.containsMatchIn(t) ||
                PATH.containsMatchIn(t) || TECH.containsMatchIn(t) || t.startsWith("Error:") -> fallback
            else -> {
                val line = t.lineSequence().first().replace(PATH, "a file").replace(ID, "").replace(Regex("""\s{2,}"""), " ").trim()
                when {
                    line.isEmpty() -> fallback
                    line.length > 140 -> fallback
                    else -> line
                }
            }
        }
    }

    const val FAILED = "Claude couldn't finish this reply."
}

/** Time labels between messages: "Today 14:05", "Yesterday 09:12", "Mon 3 Nov, 18:40" (24 h, the phone's zone). */
object ChatTime {
    /** A label goes above a message when it's the first, or more than [GAP_MS] after the one before. */
    const val GAP_MS = 30 * 60 * 1000L

    fun needsLabel(prevAt: Long, at: Long): Boolean = at > 0 && (prevAt <= 0 || at - prevAt >= GAP_MS)

    fun label(at: Long, now: Long, zone: java.util.TimeZone = java.util.TimeZone.getDefault()): String {
        val c = java.util.Calendar.getInstance(zone, Locale.UK).apply { timeInMillis = at }
        val n = java.util.Calendar.getInstance(zone, Locale.UK).apply { timeInMillis = now }
        val time = String.format(Locale.UK, "%02d:%02d", c.get(java.util.Calendar.HOUR_OF_DAY), c.get(java.util.Calendar.MINUTE))
        fun dayIndex(x: java.util.Calendar) = x.get(java.util.Calendar.YEAR) * 400 + x.get(java.util.Calendar.DAY_OF_YEAR)
        val diff = dayIndex(n) - dayIndex(c)
        return when {
            diff == 0 -> "Today $time"
            diff == 1 -> "Yesterday $time"
            c.get(java.util.Calendar.YEAR) == n.get(java.util.Calendar.YEAR) ->
                java.text.SimpleDateFormat("EEE d MMM", Locale.UK).apply { timeZone = zone }.format(java.util.Date(at)) + ", $time"
            else -> java.text.SimpleDateFormat("d MMM yyyy", Locale.UK).apply { timeZone = zone }.format(java.util.Date(at)) + ", $time"
        }
    }
}
