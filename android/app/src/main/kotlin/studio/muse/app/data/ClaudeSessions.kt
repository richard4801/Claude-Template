package studio.muse.app.data

import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * Claude chat sessions (WS18): each place keeps its own list of chats on the server, so the owner can start a new one,
 * switch, rename and delete, and pick up where they left off on any device. The AI Suite keeps one list per composer
 * tool; Recreate, Edit and Camera one per reference, editor session or camera. The same rules as the server
 * (camera/claude.ts) and the Mac (MuseCore ClaudeSessions).
 */
object ClaudeSessions {
    fun suiteKey(tool: String): String = "suite:" + (if (tool.isNotEmpty() && tool.length <= 20 && tool.all { it in 'a'..'z' }) tool else "shot")
    fun contextKey(kind: String, id: String) = "$kind:$id"

    /** The list a thread belongs to. */
    fun keyOf(t: ClaudeThread): String? = t.contextKey ?: if (t.contextKind == "suite") null else contextKey(t.contextKind, t.contextId)

    fun displayTitle(t: ClaudeThread): String = t.title?.trim()?.takeIf { it.isNotEmpty() } ?: "New chat"

    private val CONTEXT = Regex("""^\s*\[.*]\s*$""")
    fun isContextLine(line: String) = CONTEXT.matches(line)

    /** What the owner typed, without the app's context line(s) in front: how user messages are matched. */
    fun typedText(text: String): String {
        var lines = text.split("\n")
        while (lines.size > 1 && isContextLine(lines.first())) lines = lines.drop(1)
        return lines.joinToString("\n").trim()
    }

    /** A chat's automatic title from its first message (no context line, ids or paths; ≤ 60 characters, cut at a word). */
    fun autoTitle(text: String): String? {
        var lines = text.split("\n")
        while (lines.isNotEmpty() && isContextLine(lines.first())) lines = lines.drop(1)
        var s = lines.joinToString(" ")
            .replace(Regex("<[^>]{0,200}>"), " ")
            .replace(Regex("""\b(?:sa|ct|cm|tu|es|cs|tk|up|img)_[A-Za-z0-9]{4,}\b"""), " ")
            .replace(Regex("""\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"""), " ")
            .replace(Regex("""(?:~|/)[\w.-]*/[\w./-]+"""), " ")
            .replace(Regex("""\s+"""), " ").trim()
        if (s.isEmpty()) return null
        if (s.length > 60) {
            val cut = s.take(60)
            val sp = cut.lastIndexOf(' ')
            s = (if (sp > 30) cut.take(sp) else cut).replace(Regex("""[\s,.;:–-]+$"""), "") + "…"
        }
        return s
    }

    /** When a chat was last used: "Just now", "5 min ago", "3 h ago", "Yesterday", "4 days ago", then the date. */
    fun lastUsed(ms: Long, now: Long = System.currentTimeMillis(), zone: TimeZone = TimeZone.getDefault()): String {
        val s = ((now - ms) / 1000).coerceAtLeast(0)
        if (s < 60) return "Just now"
        if (s < 3600) return "${s / 60} min ago"
        fun day(t: Long) = Calendar.getInstance(zone).apply { timeInMillis = t; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
        val days = ((day(now) - day(ms)) / 86_400_000L).toInt()
        if (days == 0) return "${s / 3600} h ago"
        if (days == 1) return "Yesterday"
        if (days < 7) return "$days days ago"
        val then = Calendar.getInstance(zone).apply { timeInMillis = ms }
        val year = Calendar.getInstance(zone).apply { timeInMillis = now }.get(Calendar.YEAR) == then.get(Calendar.YEAR)
        val f = java.text.SimpleDateFormat(if (year) "d MMM" else "d MMM yyyy", Locale.US).apply { timeZone = zone }
        return f.format(then.time)
    }

    /** The chat to open: the one picked before (if still there), else the newest. */
    fun pick(list: List<ClaudeThread>, preferred: String?): ClaudeThread? =
        list.firstOrNull { it.id == preferred } ?: list.maxWithOrNull(compareBy<ClaudeThread> { it.updatedAt }.thenBy { it.id })

    /** After a delete: the newest chat left. */
    fun after(deleting: String, list: List<ClaudeThread>): ClaudeThread? = pick(list.filter { it.id != deleting }, null)

    /** A thread's change merged into a list, newest first. */
    fun upsert(t: ClaudeThread, list: List<ClaudeThread>): List<ClaudeThread> {
        val clean = t.copy(messages = null, activeTurn = null)
        val old = list.firstOrNull { it.id == t.id }
        val merged = if (old != null) list.map { if (it.id == t.id) clean.copy(messageCount = clean.messageCount ?: old.messageCount) else it } else list + clean
        return merged.sortedWith(compareByDescending<ClaudeThread> { it.updatedAt }.thenByDescending { it.id })
    }

    /** The chat open last in each place, on this device (the server's newest is the fallback on another device). */
    private val remembered = java.util.concurrent.ConcurrentHashMap<String, String>()
    @Volatile var prefs: android.content.SharedPreferences? = null
    fun remembered(key: String): String? = remembered[key] ?: prefs?.getString("claude.chat.$key", null)
    fun remember(key: String, threadId: String) { remembered[key] = threadId; prefs?.edit()?.putString("claude.chat.$key", threadId)?.apply() }
}
