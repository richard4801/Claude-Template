package studio.muse.app.ui.screens.suite.composer

import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteMove
import studio.muse.app.data.SuiteMoveOption
import studio.muse.app.data.SuiteRules

// AI suite (workstream 1): the composer's prompt as text with inline tokens (plans/video-composer.md "Prompt box"):
// `@` inserts a character, outfit or location chip, `#` a camera-move chip. Tokens can be removed and reordered; at most
// two moves, and only pairs the server can mix (suite/camera.ts canMix). Pure, so the rules are unit-tested.

/** One piece of the prompt. Every token has a [key] that stays the same while it is moved around. */
sealed interface PromptPart {
    val key: Long

    data class Text(val text: String, override val key: Long = 0) : PromptPart

    /** A camera move chip: intensity 0–100 (subtle → strong). */
    data class Move(val id: String, val label: String, val category: String, val intensity: Int = 50, override val key: Long) : PromptPart {
        fun wire() = kotlinx.serialization.json.buildJsonObject {
            put("id", kotlinx.serialization.json.JsonPrimitive(id))
            put("intensity", kotlinx.serialization.json.JsonPrimitive(intensity.coerceIn(0, 100) / 100.0))
        }
        fun move() = SuiteMove(id, intensity.coerceIn(0, 100) / 100.0)
    }

    /** kind: character | outfit | location. [label] is what the prompt text says ("Maya"). */
    data class Mention(val kind: String, val id: String, val label: String, override val key: Long) : PromptPart
}

/** Where to insert: a part and a character offset in it (a token's offset is 0 = before it, 1 = after it). */
data class Caret(val part: Int, val offset: Int)

/** The trigger being typed at the caret: `@` or `#`, the word after it (the picker's search) and where it started. */
data class Trigger(val char: Char, val query: String, val start: Int)

data class PromptTokens(val parts: List<PromptPart> = emptyList()) {
    private val nextKey: Long get() = (parts.maxOfOrNull { it.key } ?: 0) + 1

    val moves: List<PromptPart.Move> get() = parts.filterIsInstance<PromptPart.Move>()
    val mentions: List<PromptPart.Mention> get() = parts.filterIsInstance<PromptPart.Mention>()
    val character: PromptPart.Mention? get() = mentions.firstOrNull { it.kind == "character" }
    val outfit: PromptPart.Mention? get() = mentions.firstOrNull { it.kind == "outfit" }
    val isEmpty: Boolean get() = parts.all { it is PromptPart.Text && it.text.isBlank() }
    val caretAtEnd: Caret get() = if (parts.isEmpty()) Caret(0, 0) else parts.last().let { p -> Caret(parts.lastIndex, if (p is PromptPart.Text) p.text.length else 1) }

    /** Replaces the text of the composer (no tokens), e.g. when a preset fills the prompt. */
    fun withText(text: String) = PromptTokens(listOf(PromptPart.Text(text)))

    /** Inserts a token at [at], splitting a text part there. */
    private fun insert(token: PromptPart, at: Caret): PromptTokens {
        if (parts.isEmpty()) return PromptTokens(listOf(token))
        val i = at.part.coerceIn(0, parts.lastIndex)
        val p = parts[i]
        val out = parts.toMutableList()
        when {
            p is PromptPart.Text -> {
                val o = at.offset.coerceIn(0, p.text.length)
                val before = p.text.substring(0, o)
                val after = p.text.substring(o)
                out.removeAt(i)
                out.addAll(i, listOfNotNull(before.takeIf { it.isNotEmpty() }?.let { PromptPart.Text(it, p.key) }, token, after.takeIf { it.isNotEmpty() }?.let { PromptPart.Text(it, nextKey + 1) }))
            }
            at.offset <= 0 -> out.add(i, token)
            else -> out.add(i + 1, token)
        }
        return PromptTokens(out)
    }

    /**
     * Adds a #move chip. Refused (the message says why) at two moves, or when the pair can't be mixed. Returns the new
     * prompt and the message to show (null = added).
     */
    fun addMove(m: SuiteMoveOption, at: Caret = caretAtEnd, intensity: Int = 50): Pair<PromptTokens, String?> {
        if (moves.any { it.id == m.id }) return this to "${m.label} is already in the shot"
        if (moves.size >= SuiteRules.MAX_MOVES) return this to "Up to ${SuiteRules.MAX_MOVES} moves · remove one first"
        moves.firstOrNull()?.let { first -> if (!canMix(first.category, first.id, m.category, m.id)) return this to "${m.label} can't be combined with ${first.label}" }
        return insert(PromptPart.Move(m.id, m.label, m.category, intensity, nextKey), at) to null
    }

    /**
     * Adds an @ chip. One character and one outfit per shot: a new one replaces the old (the message says so). An outfit
     * needs a character first. Locations can repeat.
     */
    fun addMention(kind: String, id: String, label: String, at: Caret = caretAtEnd): Pair<PromptTokens, String?> {
        if (kind == "outfit" && character == null) return this to "Pick a character first"
        val old = mentions.firstOrNull { it.kind == kind && kind != "location" }
        if (old?.id == id) return this to null
        if (old != null) return PromptTokens(parts.map { if (it.key == old.key) PromptPart.Mention(kind, id, label, old.key) else it }) to "${old.label} replaced by $label"
        return insert(PromptPart.Mention(kind, id, label, nextKey), at) to null
    }

    /** Removes a token (removing the character also removes the outfit). Neighbouring text parts join up. */
    fun remove(key: Long): PromptTokens {
        val gone = parts.firstOrNull { it.key == key } ?: return this
        val drop = if (gone is PromptPart.Mention && gone.kind == "character") setOfNotNull(key, outfit?.key) else setOf(key)
        return PromptTokens(parts.filterNot { it.key in drop && it !is PromptPart.Text }).joined()
    }

    /** Moves a token to another place among the parts (drag to reorder). */
    fun reorder(key: Long, toIndex: Int): PromptTokens {
        val i = parts.indexOfFirst { it.key == key && it !is PromptPart.Text }
        if (i < 0) return this
        val out = parts.toMutableList()
        val t = out.removeAt(i)
        out.add(toIndex.coerceIn(0, out.size), t)
        return PromptTokens(out).joined()
    }

    /** The intensity sheet on a #move chip. */
    fun setIntensity(key: Long, intensity: Int): PromptTokens =
        PromptTokens(parts.map { if (it is PromptPart.Move && it.key == key) it.copy(intensity = intensity.coerceIn(0, 100)) else it })

    /** Edits a text part (typing). */
    fun setText(partIndex: Int, text: String): PromptTokens =
        PromptTokens(parts.mapIndexed { i, p -> if (i == partIndex && p is PromptPart.Text) p.copy(text = text) else p })

    private fun joined(): PromptTokens {
        val out = mutableListOf<PromptPart>()
        for (p in parts) {
            val last = out.lastOrNull()
            if (p is PromptPart.Text && last is PromptPart.Text) out[out.lastIndex] = last.copy(text = last.text + p.text) else out += p
        }
        return PromptTokens(out)
    }

    /**
     * The prompt the server gets: the text, with @ mentions as their names and #moves left out (they go in
     * `camera.move` / `camera.mix`). Spaces tidied.
     */
    fun promptText(): String = parts.joinToString("") { p ->
        when (p) {
            is PromptPart.Text -> p.text
            is PromptPart.Mention -> " ${p.label} "
            is PromptPart.Move -> " "
        }
    }.replace(Regex("\\s+"), " ").replace(Regex(" ([,.!?;:])"), "$1").trim()

    /** How the chips read inline ("@Maya walks in #Dolly in"), e.g. for accessibility or a plain-text copy. */
    fun display(): String = parts.joinToString("") { p ->
        when (p) {
            is PromptPart.Text -> p.text
            is PromptPart.Mention -> "@${p.label}"
            is PromptPart.Move -> "#${p.label}"
        }
    }

    companion object {
        /** The server's rule: two moves of different kinds, never with static, time or aerial moves. */
        fun canMix(catA: String, idA: String, catB: String, idB: String): Boolean {
            if (idA == idB || catA == catB) return false
            val solo = setOf("static", "time", "aerial")
            return catA !in solo && catB !in solo
        }

        /**
         * The trigger being typed at [caret] in a text part: the last `@` or `#` before the caret that starts a word, with
         * no space between it and the caret. Null when the caret isn't in one.
         */
        fun activeTrigger(text: String, caret: Int): Trigger? {
            val c = caret.coerceIn(0, text.length)
            var i = c - 1
            while (i >= 0) {
                val ch = text[i]
                if (ch == '@' || ch == '#') return if (i == 0 || text[i - 1].isWhitespace()) Trigger(ch, text.substring(i + 1, c), i) else null
                if (ch.isWhitespace()) return null
                i--
            }
            return null
        }

        /** Moves matching a # query (label or id, case-insensitive), the picker's search; [cat]'s Featured first. */
        fun searchMoves(cat: CameraCatalog, query: String): List<SuiteMoveOption> {
            val featured = cat.library.map { it.id }
            return cat.moves.filter { it.matches(query) }
                .sortedBy { m -> featured.indexOf(m.id).let { if (it < 0) Int.MAX_VALUE else it } }
        }
    }
}
