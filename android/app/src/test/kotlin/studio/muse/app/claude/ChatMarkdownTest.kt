package studio.muse.app.claude

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.ui.screens.claude.Align
import studio.muse.app.ui.screens.claude.ChatMarkdown
import studio.muse.app.ui.screens.claude.Md
import studio.muse.app.ui.screens.claude.MdBlock

/** Claude's replies as Markdown (plans/claude-chat-android.md): tricky input, and never a raw marker on screen. */
class ChatMarkdownTest {
    private fun parse(s: String, streaming: Boolean = false) = ChatMarkdown.parse(s, streaming)

    /** The prose a reader sees (code excluded) has no raw `*`, `` ` `` or leading `#`. */
    private fun assertClean(s: String, streaming: Boolean = false) {
        val prose = ChatMarkdown.prose(parse(s, streaming))
        assertFalse("raw ** in: $prose", prose.contains("**"))
        assertFalse("raw ` in: $prose", prose.contains('`'))
        assertFalse("raw heading # in: $prose", prose.lines().any { it.trimStart().startsWith("#") })
        assertFalse("raw __ in: $prose", prose.contains("__"))
        assertFalse("raw ~~ in: $prose", prose.contains("~~"))
    }

    @Test fun boldItalicCodeAndStrike() {
        val b = parse("A **bold** and *italic* and `code` and ~~gone~~ and ***both***.")
        val p = (b.single() as MdBlock.Paragraph).inline
        assertEquals(Md.Text("A "), p[0])
        assertEquals(Md.Bold(listOf(Md.Text("bold"))), p[1])
        assertEquals(Md.Italic(listOf(Md.Text("italic"))), p[3])
        assertEquals(Md.Code("code"), p[5])
        assertEquals(Md.Strike(listOf(Md.Text("gone"))), p[7])
        assertEquals(Md.Bold(listOf(Md.Italic(listOf(Md.Text("both"))))), p[9])
        assertEquals("A bold and italic and code and gone and both.", ChatMarkdown.plain(b))
    }

    @Test fun underscoresInsideWordsStayLiteral() {
        val p = (parse("use snake_case_name here").single() as MdBlock.Paragraph).inline
        assertEquals(listOf(Md.Text("use snake_case_name here")), p)
        val q = (parse("_quiet_ word").single() as MdBlock.Paragraph).inline
        assertEquals(Md.Italic(listOf(Md.Text("quiet"))), q[0])
    }

    @Test fun mathAsterisksStay() {
        assertEquals("5 * 3 = 15", ChatMarkdown.plain(parse("5 * 3 = 15")))
    }

    @Test fun nestedEmphasis() {
        val p = (parse("**bold with *italic* inside**").single() as MdBlock.Paragraph).inline
        assertEquals(Md.Bold(listOf(Md.Text("bold with "), Md.Italic(listOf(Md.Text("italic"))), Md.Text(" inside"))), p.single())
    }

    @Test fun headings() {
        val b = parse("# Title\n## Shot list ##\n### Third\n#hashtag stays text")
        assertEquals(1, (b[0] as MdBlock.Heading).level)
        assertEquals("Shot list", ChatMarkdown.plain((b[1] as MdBlock.Heading).inline))
        assertEquals(3, (b[2] as MdBlock.Heading).level)
        assertTrue(b[3] is MdBlock.Paragraph)
    }

    @Test fun fencedCodeKeepsMarkersAndIndent() {
        val b = parse("Run this:\n\n```kotlin\nval x = **not bold**\n  # not a heading\n```\nAfter.")
        val code = b[1] as MdBlock.CodeBlock
        assertEquals("kotlin", code.language)
        assertEquals("val x = **not bold**\n  # not a heading", code.code)
        assertFalse(code.open)
        assertEquals("After.", ChatMarkdown.plain(listOf(b[2])))
    }

    @Test fun tildeFenceAndLongerBacktickFence() {
        val b = parse("~~~\nplain\n~~~\n````md\n```inner```\n````")
        assertEquals("plain", (b[0] as MdBlock.CodeBlock).code)
        assertEquals("```inner```", (b[1] as MdBlock.CodeBlock).code)
    }

    @Test fun inlineCodeWithDoubleBackticks() {
        val p = (parse("Use ``a ` b`` here").single() as MdBlock.Paragraph).inline
        assertEquals(Md.Code("a ` b"), p[1])
    }

    @Test fun lists() {
        val b = parse("- one\n- two\n  - nested\n* three\n\n1. first\n2. second\n10) tenth\n\n- [x] done\n- [ ] todo")
        val ul = b[0] as MdBlock.ListBlock
        assertFalse(ul.ordered)
        assertEquals(listOf(0, 0, 1, 0), ul.items.map { it.level })
        assertEquals("nested", ChatMarkdown.plain(ul.items[2].inline))
        val ol = b[1] as MdBlock.ListBlock
        assertTrue(ol.ordered)
        assertEquals(listOf(1, 2, 10), ol.items.map { it.number })
        val tasks = b[2] as MdBlock.ListBlock
        assertEquals(listOf(true, false), tasks.items.map { it.checked })
        assertEquals("done", ChatMarkdown.plain(tasks.items[0].inline))
    }

    @Test fun listItemContinuationAndBoldInside() {
        val ul = parse("- **Camera:** slow push\n  keeps both faces\n- Light") .single() as MdBlock.ListBlock
        assertEquals(2, ul.items.size)
        assertEquals("Camera: slow push\nkeeps both faces", ChatMarkdown.plain(ul.items[0].inline))
    }

    @Test fun blockquoteWithInnerMarkdown() {
        val q = parse("> **Note:** the price\n> is an estimate").single() as MdBlock.Quote
        assertEquals("Note: the price\nis an estimate", ChatMarkdown.plain(q.blocks))
    }

    @Test fun table() {
        val t = parse("| Shot | Cost | Note |\n|:---|---:|:---:|\n| 1 | \$1.92 | `fast` |\n| 2 | \$0.64 |").single() as MdBlock.Table
        assertEquals(listOf("Shot", "Cost", "Note"), t.header.map { ChatMarkdown.plain(it) })
        assertEquals(listOf(Align.START, Align.END, Align.CENTER), t.align)
        assertEquals(2, t.rows.size)
        assertEquals("fast", ChatMarkdown.plain(t.rows[0][2]))
        assertEquals(3, t.rows[1].size) // short rows are padded
    }

    @Test fun tableWithoutOuterPipes() {
        val t = parse("Shot | Cost\n--- | ---\n1 | \$1").single() as MdBlock.Table
        assertEquals(listOf("Shot", "Cost"), t.header.map { ChatMarkdown.plain(it) })
        assertEquals("1", ChatMarkdown.plain(t.rows[0][0]))
    }

    @Test fun rules() {
        val b = parse("Above\n\n---\n\nBelow\n\n***\n\n_ _ _")
        assertEquals(listOf(MdBlock.Rule, MdBlock.Rule, MdBlock.Rule), b.filterIsInstance<MdBlock.Rule>())
    }

    @Test fun links() {
        val p = (parse("See [the docs](https://muse.studio/docs \"t\") or https://claude.ai/new. Not [this](javascript:alert(1)).").single() as MdBlock.Paragraph).inline
        val l1 = p[1] as Md.Link
        assertEquals("https://muse.studio/docs", l1.url)
        assertEquals("the docs", ChatMarkdown.plain(l1.children))
        val l2 = p.filterIsInstance<Md.Link>()[1]
        assertEquals("https://claude.ai/new", l2.url) // the full stop stays outside
        val bad = p.filterIsInstance<Md.Link>().last()
        assertFalse(ChatMarkdown.openable(bad.url))
    }

    @Test fun escapes() {
        assertEquals("*not italic* and # and `x`", ChatMarkdown.plain(parse("\\*not italic\\* and \\# and \\`x\\`")))
    }

    @Test fun unclosedMarkersWhenFinishedAreDropped() {
        assertClean("This is **bold without an end")
        assertClean("Use `code without an end")
        assertClean("An *open italic")
        assertEquals("This is bold without an end", ChatMarkdown.plain(parse("This is **bold without an end")))
    }

    @Test fun midStreamNeverShowsMarkers() {
        val full = "## Plan\n\nHere is **the shot**: a `dolly` move.\n\n- one\n- **two**\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nconst a = 1\n```\n\n> quote *here*\n\nDone [link](https://x.io)."
        // Every prefix of the reply, as it streams in, renders without raw markers.
        for (n in 1..full.length) assertClean(full.substring(0, n), streaming = true)
    }

    @Test fun streamingBoldStylesTheRest() {
        val p = (parse("Pushing **in slow", streaming = true).single() as MdBlock.Paragraph).inline
        assertEquals(Md.Bold(listOf(Md.Text("in slow"))), p.last())
    }

    @Test fun streamingOpenFenceIsCode() {
        val b = parse("Here:\n```py\nprint(1)", streaming = true)
        val c = b.last() as MdBlock.CodeBlock
        assertTrue(c.open)
        assertEquals("print(1)", c.code)
    }

    @Test fun streamingLinkHoldsBackTheUrl() {
        val p = (parse("Open [the guide](https://mu", streaming = true).single() as MdBlock.Paragraph).inline
        assertEquals("Open the guide", ChatMarkdown.plain(p))
    }

    @Test fun streamingBareMarkerLineIsHidden() {
        assertEquals("Intro", ChatMarkdown.plain(parse("Intro\n\n##", streaming = true)))
        assertEquals("Intro", ChatMarkdown.plain(parse("Intro\n-", streaming = true)))
        assertEquals("Intro", ChatMarkdown.plain(parse("Intro\n1.", streaming = true)))
    }

    @Test fun windowsLineEndingsAndEmpty() {
        assertEquals(2, parse("a\r\n\r\nb").size)
        assertTrue(parse("").isEmpty())
        assertTrue(parse("   \n\n").isEmpty())
    }

    @Test fun messyRealReply() {
        val s = """
            **Shot 1** — *slow push*:
            1. Camera: `35 mm`, f/2.8
            2. Light: soft key, **warm**

            Cost | Time
            ---|---
            ${'$'}1.92 | 8 s

            > Tip: say "go" and I'll ask you to approve.
        """.trimIndent()
        assertClean(s)
        val b = parse(s)
        assertTrue(b[0] is MdBlock.Paragraph)
        assertTrue(b[1] is MdBlock.ListBlock)
        assertTrue(b[2] is MdBlock.Table)
        assertTrue(b[3] is MdBlock.Quote)
    }
}
