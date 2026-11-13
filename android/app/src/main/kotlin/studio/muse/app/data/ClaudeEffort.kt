package studio.muse.app.data

/**
 * Effort (Claude Code's `--effort`, the API's output_config.effort): how long Claude thinks. Higher thinks longer and uses
 * more of the Claude plan. The same rules as the Mac (MuseCore ClaudeEffort) and the server (claude/models.ts).
 */
object ClaudeEffort {
    val ALL = listOf("low", "medium", "high", "xhigh", "max")
    private val NAMES = mapOf("low" to "Low", "medium" to "Medium", "high" to "High", "xhigh" to "Extra high", "max" to "Max")
    fun name(e: String) = NAMES[e] ?: e
    fun valid(e: String?) = e != null && e in ALL

    /** The levels a model takes, low to high (unknown words dropped; empty: the model takes no effort setting). */
    fun levels(m: ClaudeModelInfo?): List<String> = ALL.filter { it in m?.efforts.orEmpty() }

    /** The chat's own level, else the person's last choice, else the model's default; null when the model takes none. */
    fun resolve(m: ClaudeModelInfo?, own: String?, last: String?): String? {
        val l = levels(m)
        if (l.isEmpty()) return null
        return listOf(own, last, m?.defaultEffort).firstOrNull { it != null && it in l }
    }

    /** "Claude Opus 5.5" → "Opus 5.5": the chat header already says Claude. */
    fun shortModel(name: String) = name.removePrefix("Claude ")
}

/** The model a chat runs on: its own, else the person's default, else the studio's; and whether it is the chat's own. */
data class ClaudeModelChoice(val model: ClaudeModelInfo?, val ownModel: Boolean, val levels: List<String>, val effort: String?, val ownEffort: Boolean) {
    companion object {
        fun of(list: ClaudeModelList?, thread: ClaudeThread?): ClaudeModelChoice {
            val id = thread?.model ?: list?.default ?: list?.studioDefault
            val m = list?.models?.firstOrNull { it.id == id }
            val levels = ClaudeEffort.levels(m)
            val own = thread?.effort?.takeIf { it in levels }
            return ClaudeModelChoice(m, thread?.model != null, levels, ClaudeEffort.resolve(m, own, list?.defaultEffort), own != null)
        }
    }
}
