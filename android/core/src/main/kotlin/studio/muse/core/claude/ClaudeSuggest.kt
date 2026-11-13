package studio.muse.core.claude

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

// Live suggestion chips (owner 2026-11-12; the Mac's MuseCore/Claude/ClaudeSuggest.swift): the chips over Claude's input
// follow what is on screen and what just happened. The server holds the rules (server/api/src/claude/suggest.ts,
// GET v1/claude/suggestions); the app says where it is and keeps the chips' order steady while they change.

/** What the app tells the server: the page, its open ids and the chat (Claude's last reply gives follow-ups). */
data class ClaudeSuggestQuery(val page: String?, val tool: String? = null, val ids: Map<String, String> = emptyMap(), val chatId: String? = null) {
    /** The query parameters, sorted (the same facts always make the same request); ids that aren't plain are left out. */
    fun params(): Map<String, String> {
        val q = sortedMapOf<String, String>()
        fun add(k: String, v: String?) { if (v != null && plain(v)) q[k] = v }
        add("page", page); add("tool", tool)
        ids.filterKeys { it in IDS }.forEach { (k, v) -> add(k, v) }
        add("chatId", chatId)
        return q
    }

    fun queryString(): String = params().entries.joinToString("&") { "${it.key}=${it.value}" }

    companion object {
        private val IDS = setOf("sessionId", "assistId", "takeId", "referenceId")
        fun plain(s: String) = s.isNotEmpty() && s.length <= 80 && s.all { it.isLetterOrDigit() && it.code < 128 || it == '_' || it == '-' }
    }
}

object ClaudeSuggest {
    /** `{chips: [{label, prompt, icon}]}` → chips (empty for anything else). */
    fun parse(json: JsonElement?): List<ClaudeChip> {
        val arr = ((json as? JsonObject)?.get("chips") as? kotlinx.serialization.json.JsonArray) ?: return emptyList()
        return arr.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            fun s(k: String) = (o[k] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
            val label = s("label") ?: return@mapNotNull null
            ClaudeChip(label, s("prompt") ?: label, s("icon") ?: "chat-circle")
        }
    }

    /**
     * Steady chips: a chip that stays keeps its place, new ones take the freed places in the server's order, so the row
     * doesn't jump about when one chip changes.
     */
    fun steady(old: List<ClaudeChip>, new: List<ClaudeChip>): List<ClaudeChip> {
        if (old.isEmpty()) return new
        val rest = new.filter { n -> old.none { it.label == n.label } }.toMutableList()
        val out = mutableListOf<ClaudeChip>()
        for (o in old) {
            val n = new.firstOrNull { it.label == o.label }
            if (n != null) out += n else if (rest.isNotEmpty()) out += rest.removeAt(0)
        }
        out += rest
        return out.take(new.size)
    }
}
