package studio.muse.app.ui.screens.claude

// Claude's replies as Markdown (plans/claude-chat-android.md). A small, forgiving parser with no Compose in it: blocks
// (paragraphs, headings, lists, quotes, fenced code, tables, rules) and inline spans (bold, italic, strike, code, links).
// It never lets a marker through as raw text: a marker that never closes styles the rest while the reply streams, and is
// dropped once the reply is finished. ChatMarkdownView.kt draws the result.

/** An inline run of a paragraph, heading, list item, quote line or table cell. */
sealed interface Md {
    data class Text(val text: String) : Md
    data class Bold(val children: List<Md>) : Md
    data class Italic(val children: List<Md>) : Md
    data class Strike(val children: List<Md>) : Md
    data class Code(val text: String) : Md
    data class Link(val children: List<Md>, val url: String) : Md
    /** A hard line break inside a block. */
    data object Break : Md
}

/** One block of a reply. */
sealed interface MdBlock {
    data class Paragraph(val inline: List<Md>) : MdBlock
    data class Heading(val level: Int, val inline: List<Md>) : MdBlock
    /** [open]: the closing fence hasn't arrived yet (streaming). */
    data class CodeBlock(val code: String, val language: String?, val open: Boolean = false) : MdBlock
    data class Quote(val blocks: List<MdBlock>) : MdBlock
    data class ListBlock(val ordered: Boolean, val items: List<ListItem>) : MdBlock
    data class Table(val header: List<List<Md>>, val rows: List<List<List<Md>>>, val align: List<Align>) : MdBlock
    data object Rule : MdBlock
}

/** A list item: its marker number (ordered lists), its nesting [level] (0 = top), its text, and a task box if any. */
data class ListItem(val number: Int?, val level: Int, val inline: List<Md>, val checked: Boolean? = null)

enum class Align { START, CENTER, END }

object ChatMarkdown {
    private val FENCE = Regex("""^ {0,3}(`{3,}|~{3,})\s*([\w+#.-]*)\s*$""")
    private val HEADING = Regex("""^ {0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*$""")
    private val RULE = Regex("""^ {0,3}([-*_])(\s*\1){2,}\s*$""")
    private val BULLET = Regex("""^(\s*)([-*+])\s+(.*)$""")
    private val ORDERED = Regex("""^(\s*)(\d{1,9})[.)]\s+(.*)$""")
    private val TASK = Regex("""^\[([ xX])]\s+(.*)$""")
    private val QUOTE = Regex("""^ {0,3}>\s?(.*)$""")
    private val TABLE_SEP = Regex("""^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$""")
    /** A line that is nothing but the start of a marker ("#", "-", "*", ">", "`", "|", "1."): hidden while it streams. */
    private val BARE_MARKER = Regex("""^\s*(#{1,6}|[-*+>|]|`{1,2}|~{1,2}|\d{1,9}[.)]?)\s*$""")

    /** [text] as blocks. [streaming]: the reply is still arriving, so an unfinished last line or marker is held back. */
    fun parse(text: String, streaming: Boolean = false): List<MdBlock> {
        val lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n').toMutableList()
        if (streaming && lines.isNotEmpty() && BARE_MARKER.matches(lines.last())) lines[lines.lastIndex] = ""
        return blocks(lines, streaming)
    }

    private fun blocks(lines: List<String>, streaming: Boolean): List<MdBlock> {
        val out = mutableListOf<MdBlock>()
        var i = 0
        val para = mutableListOf<String>()
        fun flush() {
            if (para.isNotEmpty()) {
                val joined = para.joinToString("\n")
                if (joined.isNotBlank()) out += MdBlock.Paragraph(inline(joined, streaming))
                para.clear()
            }
        }
        while (i < lines.size) {
            val line = lines[i]
            val fence = FENCE.find(line)
            if (fence != null) {
                flush()
                val mark = fence.groupValues[1]
                val lang = fence.groupValues[2].ifBlank { null }
                val body = mutableListOf<String>()
                var j = i + 1
                var closed = false
                while (j < lines.size) {
                    val l = lines[j].trim()
                    if (l.startsWith(mark[0].toString().repeat(mark.length)) && l.all { it == mark[0] }) { closed = true; break }
                    body += lines[j]
                    j++
                }
                out += MdBlock.CodeBlock(body.joinToString("\n").trimEnd('\n'), lang, open = !closed)
                i = if (closed) j + 1 else j
                continue
            }
            if (line.isBlank()) { flush(); i++; continue }
            val h = HEADING.find(line)
            if (h != null) {
                flush()
                val body = h.groupValues[2]
                if (body.isNotBlank()) out += MdBlock.Heading(h.groupValues[1].length, inline(body, streaming))
                i++
                continue
            }
            if (RULE.matches(line)) { flush(); out += MdBlock.Rule; i++; continue }
            if (QUOTE.matches(line)) {
                flush()
                val inner = mutableListOf<String>()
                while (i < lines.size && QUOTE.matches(lines[i])) { inner += QUOTE.find(lines[i])!!.groupValues[1]; i++ }
                val qb = blocks(inner, streaming)
                if (qb.isNotEmpty()) out += MdBlock.Quote(qb)
                continue
            }
            if (isTableStart(lines, i)) {
                flush()
                val rows = mutableListOf<String>()
                while (i < lines.size && lines[i].isNotBlank() && (lines[i].contains('|'))) { rows += lines[i]; i++ }
                out += table(rows, streaming)
                continue
            }
            if (BULLET.matches(line) || ORDERED.matches(line)) {
                flush()
                val ordered = ORDERED.matches(line) && !BULLET.matches(line)
                val items = mutableListOf<ListItem>()
                val indents = mutableListOf<Int>()
                while (i < lines.size) {
                    val l = lines[i]
                    val b = BULLET.find(l)?.takeUnless { RULE.matches(l) }
                    val o = ORDERED.find(l)
                    val m = b ?: o
                    if (m != null) {
                        val indent = m.groupValues[1].replace("\t", "    ").length
                        // Nesting: each deeper indent is one level in.
                        while (indents.isNotEmpty() && indent < indents.last()) indents.removeAt(indents.lastIndex)
                        if (indents.isEmpty() || indent > indents.last()) indents += indent
                        val level = indents.size - 1
                        if (level == 0 && items.isNotEmpty() && (o != null && b == null) != ordered) break
                        var body = m.groupValues[3]
                        var checked: Boolean? = null
                        TASK.find(body)?.let { t -> checked = t.groupValues[1] != " "; body = t.groupValues[2] }
                        items += ListItem(if (b == null) o!!.groupValues[2].toIntOrNull() else null, level, inline(body, streaming), checked)
                        i++
                        continue
                    }
                    // A continuation line (indented, or lazy text right after an item) joins the item.
                    if (l.isNotBlank() && items.isNotEmpty() && (l.startsWith("  ") || l.startsWith("\t")) && !FENCE.matches(l)) {
                        val last = items.removeAt(items.lastIndex)
                        items += last.copy(inline = last.inline + Md.Break + inline(l.trim(), streaming))
                        i++
                        continue
                    }
                    // A blank line between items keeps the list going.
                    if (l.isBlank() && i + 1 < lines.size && (BULLET.matches(lines[i + 1]) || ORDERED.matches(lines[i + 1]))) { i++; continue }
                    break
                }
                out += MdBlock.ListBlock(ordered, items)
                continue
            }
            para += line
            i++
        }
        flush()
        return out
    }

    /** A table: a row of pipes followed by a `|---|` separator, or (while it streams) a line that starts with a pipe. */
    private fun isTableStart(lines: List<String>, i: Int): Boolean {
        val l = lines[i]
        if (!l.contains('|')) return false
        if (i + 1 < lines.size && TABLE_SEP.matches(lines[i + 1]) && lines[i + 1].contains('-')) return true
        return l.trimStart().startsWith("|") && l.count { it == '|' } >= 2
    }

    private fun cells(row: String): List<String> {
        var r = row.trim()
        if (r.startsWith("|")) r = r.substring(1)
        if (r.endsWith("|") && !r.endsWith("\\|")) r = r.dropLast(1)
        val out = mutableListOf<String>()
        val cur = StringBuilder()
        var k = 0
        var inCode = false
        while (k < r.length) {
            val ch = r[k]
            when {
                ch == '\\' && k + 1 < r.length && r[k + 1] == '|' -> { cur.append('|'); k++ }
                ch == '`' -> { inCode = !inCode; cur.append(ch) }
                ch == '|' && !inCode -> { out += cur.toString().trim(); cur.clear() }
                else -> cur.append(ch)
            }
            k++
        }
        out += cur.toString().trim()
        return out
    }

    private fun table(rows: List<String>, streaming: Boolean): MdBlock.Table {
        val sepAt = rows.indexOfFirst { TABLE_SEP.matches(it) && it.contains('-') }
        val align = if (sepAt >= 0) cells(rows[sepAt]).map { c ->
            val s = c.trim()
            when { s.startsWith(":") && s.endsWith(":") -> Align.CENTER; s.endsWith(":") -> Align.END; else -> Align.START }
        } else emptyList()
        val data = rows.filterIndexed { k, _ -> k != sepAt }.filterNot { TABLE_SEP.matches(it) && it.contains('-') }
        val parsed = data.map { r -> cells(r).map { inline(it, streaming) } }
        val header = parsed.firstOrNull().orEmpty()
        val width = parsed.maxOfOrNull { it.size } ?: 0
        fun pad(r: List<List<Md>>) = r + List((width - r.size).coerceAtLeast(0)) { emptyList() }
        return MdBlock.Table(pad(header), parsed.drop(1).map(::pad), List(width) { align.getOrElse(it) { Align.START } })
    }

    // ---------------------------------------------------------------- inline

    private val AUTOLINK = Regex("""https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"*_~`]""")

    /** Inline spans of one block's text. */
    fun inline(s: String, streaming: Boolean = false): List<Md> = merge(Inline(s, streaming).run(0, s.length))

    private class Inline(val s: String, val streaming: Boolean) {
        fun run(from: Int, to: Int): List<Md> {
            val out = mutableListOf<Md>()
            val buf = StringBuilder()
            fun text() { if (buf.isNotEmpty()) { out += Md.Text(buf.toString()); buf.clear() } }
            var i = from
            while (i < to) {
                val c = s[i]
                // Escapes: \* \_ \` \# \[ … are literal characters.
                if (c == '\\' && i + 1 < to && s[i + 1] in "\\`*_{}[]()#+-.!|~>") { buf.append(s[i + 1]); i += 2; continue }
                if (c == '\n') { text(); out += Md.Break; i++; continue }
                if (c == '`') {
                    val run = countRun(i, to, '`')
                    val close = s.indexOf("`".repeat(run), i + run).takeIf { it in 0 until to && (it + run >= to || s[it + run] != '`') }
                    if (close != null) {
                        text()
                        out += Md.Code(s.substring(i + run, close).let { if (it.length > 2 && it.startsWith(' ') && it.endsWith(' ')) it.substring(1, it.length - 1) else it })
                        i = close + run; continue
                    }
                    // Never closed: code to the end while it streams; dropped once finished.
                    text()
                    if (streaming) { out += Md.Code(s.substring(i + run, to)); return out }
                    i += run; continue
                }
                if (c == '[') {
                    val link = link(i, to)
                    if (link != null) { text(); out += Md.Link(run(i + 1, link.first), link.second); i = link.third; continue }
                    // "[text](" still streaming: show the text, hold back the url.
                    if (streaming) {
                        val rb = s.indexOf("](", i)
                        if (rb in i until to && s.indexOf(')', rb) !in rb until to) { text(); out += run(i + 1, rb); return out }
                    }
                }
                if (c == '<') {
                    val gt = s.indexOf('>', i)
                    if (gt in i until to && s.substring(i + 1, gt).let { it.startsWith("http://") || it.startsWith("https://") } && !s.substring(i + 1, gt).contains(' ')) {
                        text(); val u = s.substring(i + 1, gt); out += Md.Link(listOf(Md.Text(u)), u); i = gt + 1; continue
                    }
                }
                if (c == 'h' && (i == from || !s[i - 1].isLetterOrDigit()) && (s.startsWith("http://", i) || s.startsWith("https://", i))) {
                    val m = AUTOLINK.matchAt(s, i)
                    if (m != null && m.range.last < to) { text(); out += Md.Link(listOf(Md.Text(m.value)), m.value); i = m.range.last + 1; continue }
                }
                if (c == '*' || c == '_' || c == '~') {
                    val run = countRun(i, to, c)
                    val handled = emphasis(i, to, c, run, out, ::text)
                    if (handled >= 0) { i = handled; continue }
                    // Not a marker: literal (math "5 * 3", snake_case words).
                    buf.append(s, i, i + run); i += run; continue
                }
                buf.append(c); i++
            }
            text()
            return out
        }

        private fun countRun(i: Int, to: Int, c: Char): Int { var k = i; while (k < to && s[k] == c) k++; return k - i }

        private fun prev(i: Int) = if (i > 0) s[i - 1] else ' '

        /** `*a*`, `**a**`, `***a***`, `_a_`, `__a__`, `~~a~~`. Returns the index after, or -1 when [i] isn't a marker. */
        private fun emphasis(i: Int, to: Int, c: Char, run: Int, out: MutableList<Md>, text: () -> Unit): Int {
            if (c == '~' && run < 2) return -1
            val after = if (i + run < to) s[i + run] else ' '
            // Opens only when followed by a non-space (left-flanking); `_` also not inside a word.
            if (after.isWhitespace() || i + run >= to) {
                // A lone trailing marker while streaming ("**" just arrived): hide it.
                return if (streaming && i + run >= to) { text(); to } else -1
            }
            if (c == '_' && prev(i).isLetterOrDigit()) return -1
            val want = if (c == '~') 2 else minOf(run, 3)
            val marker = c.toString().repeat(want)
            // The closing marker: right-flanking (no space before), and for `_` not followed by a letter.
            var k = i + want
            while (k < to) {
                val at = s.indexOf(marker, k)
                if (at < 0 || at >= to) break
                val closeRun = countRun(at, to, c)
                val okBefore = !s[at - 1].isWhitespace() && at > i + want
                val okAfter = c != '_' || at + closeRun >= to || !s[at + closeRun].isLetterOrDigit()
                if (okBefore && okAfter && (s[at - 1] != '\\')) {
                    text()
                    // A longer closing run (`**a***`): the extra markers are parsed after it.
                    out += wrap(c, want, run(i + want, at))
                    return at + want
                }
                k = at + closeRun
            }
            // Never closed. While streaming the rest is styled; once finished, the marker is dropped.
            text()
            if (streaming) { out += wrap(c, want, run(i + want, to)); return to }
            return i + want
        }

        private fun wrap(c: Char, n: Int, inner: List<Md>): Md = when {
            c == '~' -> Md.Strike(inner)
            n >= 3 -> Md.Bold(listOf(Md.Italic(inner)))
            n == 2 -> Md.Bold(inner)
            else -> Md.Italic(inner)
        }

        /** `[text](url)` starting at [i]: (end of text, url, index after). Only http(s) and mailto links are kept. */
        private fun link(i: Int, to: Int): Triple<Int, String, Int>? {
            var depth = 0
            var k = i
            while (k < to) {
                when (s[k]) { '[' -> depth++; ']' -> { depth--; if (depth == 0) break } }
                k++
            }
            if (k >= to || k + 1 >= to || s[k + 1] != '(') return null
            val close = s.indexOf(')', k + 2)
            if (close < 0 || close >= to) return null
            val url = s.substring(k + 2, close).trim().substringBefore(' ').removeSurrounding("<", ">")
            return Triple(k, url, close + 1)
        }
    }

    /** Joins neighbouring text runs. */
    private fun merge(xs: List<Md>): List<Md> {
        val out = mutableListOf<Md>()
        for (x in xs) {
            val last = out.lastOrNull()
            if (x is Md.Text && last is Md.Text) out[out.lastIndex] = Md.Text(last.text + x.text)
            else if (x is Md.Text && x.text.isEmpty()) continue
            else out += x
        }
        return out
    }

    /** Is this link safe to open (http, https, mailto)? Others render as plain text. */
    fun openable(url: String): Boolean = url.startsWith("https://") || url.startsWith("http://") || url.startsWith("mailto:")

    /** What a reader sees, as plain text (tests, TalkBack): no markers. */
    fun plain(blocks: List<MdBlock>): String = blocks.joinToString("\n") { b ->
        when (b) {
            is MdBlock.Paragraph -> plain(b.inline)
            is MdBlock.Heading -> plain(b.inline)
            is MdBlock.CodeBlock -> b.code
            is MdBlock.Quote -> plain(b.blocks)
            is MdBlock.ListBlock -> b.items.joinToString("\n") { it.number?.let { n -> "$n. " }.orEmpty() + plain(it.inline) }
            is MdBlock.Table -> (listOf(b.header) + b.rows).joinToString("\n") { r -> r.joinToString("  ") { plain(it) } }
            MdBlock.Rule -> ""
        }
    }

    @JvmName("plainInline")
    fun plain(xs: List<Md>): String = xs.joinToString("") { x ->
        when (x) {
            is Md.Text -> x.text
            is Md.Bold -> plain(x.children)
            is Md.Italic -> plain(x.children)
            is Md.Strike -> plain(x.children)
            is Md.Code -> x.text
            is Md.Link -> plain(x.children)
            Md.Break -> "\n"
        }
    }

    /** Plain text outside code: what must never contain a raw marker. */
    fun prose(blocks: List<MdBlock>): String = blocks.joinToString("\n") { b ->
        when (b) {
            is MdBlock.Paragraph -> prose(b.inline)
            is MdBlock.Heading -> prose(b.inline)
            is MdBlock.CodeBlock -> ""
            is MdBlock.Quote -> prose(b.blocks)
            is MdBlock.ListBlock -> b.items.joinToString("\n") { prose(it.inline) }
            is MdBlock.Table -> (listOf(b.header) + b.rows).joinToString("\n") { r -> r.joinToString(" ") { prose(it) } }
            MdBlock.Rule -> ""
        }
    }

    @JvmName("proseInline")
    private fun prose(xs: List<Md>): String = xs.joinToString("") { x ->
        when (x) {
            is Md.Text -> x.text
            is Md.Bold -> prose(x.children)
            is Md.Italic -> prose(x.children)
            is Md.Strike -> prose(x.children)
            is Md.Code -> ""
            is Md.Link -> prose(x.children)
            Md.Break -> "\n"
        }
    }
}
