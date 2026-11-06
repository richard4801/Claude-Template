package studio.muse.app.ui.screens.suite.composer

// AI suite (workstream 1): how the prompt box edits [PromptTokens] as one text field. Each token is one private-use
// character in the field's text (so the caret, typing and backspace treat it as a single unit), and the display swaps
// each for its chip text ("@Noor", "#Dolly in"). Pure, so the round trip and the offset maps are unit-tested.

object PromptCodec {
    private const val BASE = 0xE000
    private const val SPAN = 0x1800

    fun isToken(c: Char) = c.code in BASE until BASE + SPAN

    private fun tokenChar(key: Long) = (BASE + (key % SPAN).toInt()).toChar()

    /** The field's text: text parts as they are, each token as one character. */
    fun encode(t: PromptTokens): String = buildString {
        t.parts.forEach { p -> if (p is PromptPart.Text) append(p.text) else append(tokenChar(p.key)) }
    }

    /**
     * Reads the field's text back: token characters become the tokens of [old] they stand for (a deleted one is gone),
     * the text between them becomes text parts. Unknown token characters are dropped.
     */
    fun decode(old: PromptTokens, s: String): PromptTokens {
        val byChar = old.parts.filter { it !is PromptPart.Text }.associateBy { tokenChar(it.key) }
        val out = mutableListOf<PromptPart>()
        val sb = StringBuilder()
        fun flush() { if (sb.isNotEmpty()) { out += PromptPart.Text(sb.toString()); sb.clear() } }
        for (c in s) {
            if (isToken(c)) { flush(); byChar[c]?.let { out += it } } else sb.append(c)
        }
        flush()
        return PromptTokens(out)
    }

    /** The chip text a token shows inline, with thin spaces around it. */
    fun chipText(p: PromptPart): String = when (p) {
        is PromptPart.Mention -> "@${p.label}"
        is PromptPart.Move -> "#${p.label}"
        is PromptPart.Text -> p.text
    }

    /** The token a field character stands for (null for text). */
    fun tokenAt(t: PromptTokens, s: String, offset: Int): PromptPart? {
        val c = s.getOrNull(offset) ?: return null
        if (!isToken(c)) return null
        return t.parts.firstOrNull { it !is PromptPart.Text && tokenChar(it.key) == c }
    }

    /** The field offset → a [Caret] among the parts (for inserting a token where the caret is). */
    fun caretAt(t: PromptTokens, offset: Int): Caret {
        var pos = 0
        t.parts.forEachIndexed { i, p ->
            val len = if (p is PromptPart.Text) p.text.length else 1
            if (offset <= pos + len && p is PromptPart.Text) return Caret(i, offset - pos)
            if (offset == pos && p !is PromptPart.Text) return Caret(i, 0)
            pos += len
        }
        return t.caretAtEnd
    }

    /**
     * The display of the field: the text with each token character replaced by its chip text, the chips' ranges in it, and
     * the maps between field and display offsets (a VisualTransformation's OffsetMapping).
     */
    data class Display(val text: String, val chips: List<Pair<IntRange, PromptPart>>, private val toDisplay: IntArray, private val toField: IntArray) {
        fun fieldToDisplay(o: Int) = toDisplay[o.coerceIn(0, toDisplay.lastIndex)]
        fun displayToField(o: Int) = toField[o.coerceIn(0, toField.lastIndex)]
    }

    fun display(t: PromptTokens, s: String): Display {
        val sb = StringBuilder()
        val chips = mutableListOf<Pair<IntRange, PromptPart>>()
        val toDisplay = IntArray(s.length + 1)
        val toFieldList = ArrayList<Int>()
        s.forEachIndexed { i, c ->
            toDisplay[i] = sb.length
            val tok = if (isToken(c)) tokenAt(t, s, i) else null
            if (tok != null) {
                val label = " " + chipText(tok) + " "
                val start = sb.length
                sb.append(label)
                chips += (start until sb.length) to tok
                // Every display offset inside a chip maps to just after the token character (the caret never lands inside it).
                repeat(label.length) { k -> toFieldList += if (k == 0) i else i + 1 }
            } else {
                sb.append(c)
                toFieldList += i
            }
        }
        toDisplay[s.length] = sb.length
        toFieldList += s.length
        return Display(sb.toString(), chips, toDisplay, toFieldList.toIntArray())
    }

    /** Removes the typed trigger ("@no") that ends at [caret] and returns the new field text and caret. */
    fun dropTrigger(s: String, tr: Trigger, caret: Int): Pair<String, Int> = (s.substring(0, tr.start) + s.substring(caret.coerceIn(tr.start, s.length))) to tr.start

    /** The trigger at a field caret: the run of plain text before the caret (tokens end the search). */
    fun triggerAt(s: String, caret: Int): Trigger? {
        val c = caret.coerceIn(0, s.length)
        var from = c
        while (from > 0 && !isToken(s[from - 1])) from--
        val tr = PromptTokens.activeTrigger(s.substring(from, c), c - from) ?: return null
        return tr.copy(start = tr.start + from)
    }
}
