import XCTest
@testable import MuseCore

/// Claude chat on the Mac (plans/claude-chat-mac.md): markdown is drawn, never shown raw, including mid-stream.
final class ChatMarkdownTests: XCTestCase {
    private func runs(_ s: String, streaming: Bool = false) -> [ChatRun] { ChatMarkdown.inline(s, streaming: streaming) }
    private func text(_ r: [ChatRun]) -> String { r.map(\.text).joined() }

    /// No markup character survives in the drawn words (outside code, where it belongs).
    private func assertNoMarkup(_ blocks: [ChatBlock], file: StaticString = #filePath, line: UInt = #line) {
        func check(_ r: [ChatRun]) {
            for run in r where !run.code {
                XCTAssertFalse(run.text.contains("**"), "raw ** in \(run.text)", file: file, line: line)
                XCTAssertFalse(run.text.contains("`"), "raw backtick in \(run.text)", file: file, line: line)
                XCTAssertFalse(run.text.contains("__"), "raw __ in \(run.text)", file: file, line: line)
                XCTAssertFalse(run.text.contains("~~"), "raw ~~ in \(run.text)", file: file, line: line)
            }
        }
        for b in blocks {
            switch b {
            case .paragraph(let r), .heading(_, let r), .listItem(_, _, _, _, let r):
                check(r)
                if case .paragraph(let r) = b { XCTAssertFalse(text(r).hasPrefix("#"), "raw heading in \(text(r))", file: file, line: line) }
            case .quote(let inner): assertNoMarkup(inner, file: file, line: line)
            case .table(let h, let rows, _): (h + rows.flatMap { $0 }).forEach(check)
            case .code, .rule: break
            }
        }
    }

    // MARK: Inline

    func testBoldItalicCodeAndStrike() {
        let r = runs("Use **bold**, *italic*, `code` and ~~gone~~ here.")
        XCTAssertEqual(text(r), "Use bold, italic, code and gone here.")
        XCTAssertTrue(r.contains(ChatRun("bold", bold: true)))
        XCTAssertTrue(r.contains(ChatRun("italic", italic: true)))
        XCTAssertTrue(r.contains(ChatRun("code", code: true)))
        XCTAssertTrue(r.contains(ChatRun("gone", strike: true)))
    }

    func testUnderscoresAndNesting() {
        let r = runs("__strong__ and _soft_ and ***both*** and **bold with *italic* inside**")
        XCTAssertEqual(text(r), "strong and soft and both and bold with italic inside")
        XCTAssertTrue(r.contains(ChatRun("strong", bold: true)))
        XCTAssertTrue(r.contains(ChatRun("soft", italic: true)))
        XCTAssertTrue(r.contains(ChatRun("both", bold: true, italic: true)))
        XCTAssertTrue(r.contains(ChatRun("italic", bold: true, italic: true)))
    }

    func testLoneMarkersThatAreNotMarkupStay() {
        XCTAssertEqual(text(runs("2 * 3 = 6 and a ~ b")), "2 * 3 = 6 and a ~ b")
        XCTAssertEqual(text(runs("snake_case_name stays")), "snake_case_name stays")
        XCTAssertEqual(text(runs("Shot with a #Dolly in")), "Shot with a #Dolly in")
        XCTAssertEqual(text(runs(#"An escaped \*star\* and \`tick\`"#)), "An escaped *star* and `tick`")
    }

    func testUnclosedMarkersInFinalTextAreDropped() {
        XCTAssertEqual(text(runs("this is **not closed")), "this is not closed")
        XCTAssertEqual(text(runs("and `dangling")), "and dangling")
    }

    func testDoubleBacktickCodeHoldsABacktick() {
        let r = runs("Type `` a`b `` here")
        XCTAssertEqual(text(r), "Type a`b here")
        XCTAssertTrue(r.contains(ChatRun("a`b", code: true)))
    }

    func testCodeSpanKeepsMarkupInside() {
        let r = runs("Run `**not bold**` now")
        XCTAssertTrue(r.contains(ChatRun("**not bold**", code: true)))
    }

    func testLinks() {
        let r = runs("See [the guide](https://muse.studio/guide \"Guide\") or <https://muse.studio> or https://muse.studio/docs.")
        XCTAssertEqual(text(r), "See the guide or https://muse.studio or https://muse.studio/docs.")
        XCTAssertTrue(r.contains(ChatRun("the guide", link: "https://muse.studio/guide")))
        XCTAssertTrue(r.contains(ChatRun("https://muse.studio/docs", link: "https://muse.studio/docs")))
        XCTAssertEqual(r.last?.text, ".")
        let b = runs("[**Bold** link](https://a.b)")
        XCTAssertEqual(b.first, ChatRun("Bold", bold: true, link: "https://a.b"))
    }

    func testEntitiesDecode() {
        XCTAssertEqual(text(runs("Tom &amp; Jerry &lt;3")), "Tom & Jerry <3")
    }

    // MARK: Streaming

    func testStreamingBoldStylesToTheEnd() {
        let r = runs("Now **bolder te", streaming: true)
        XCTAssertEqual(text(r), "Now bolder te")
        XCTAssertEqual(r.last, ChatRun("bolder te", bold: true))
    }

    func testStreamingHidesAMarkerThatHasJustBegun() {
        for s in ["Hello **", "Hello *", "Hello `", "Hello ``", "Hello ~~", "Hello \\", "Hello [", "Hello **bold*"] {
            let r = runs(s, streaming: true)
            XCTAssertFalse(text(r).contains("*"), s)
            XCTAssertFalse(text(r).contains("`"), s)
            XCTAssertFalse(text(r).contains("~"), s)
            XCTAssertFalse(text(r).contains("["), s)
            XCTAssertTrue(text(r).hasPrefix("Hello"), s)
        }
        XCTAssertEqual(runs("Hello **bold*", streaming: true).last, ChatRun("bold", bold: true))
    }

    func testStreamingCodeAndLinks() {
        XCTAssertEqual(runs("Run `npm te", streaming: true).last, ChatRun("npm te", code: true))
        XCTAssertEqual(text(runs("Open [the gui", streaming: true)), "Open the gui")
        XCTAssertEqual(text(runs("Open [the guide](https://mu", streaming: true)), "Open the guide")
    }

    func testEveryPrefixOfATrickyReplyHasNoRawMarkup() {
        let reply = """
        ## Plan for **shot 2**

        1. Trim the *intro* to `0:03`
        2. Apply the **Golden warmth** look
           - keep ~~grain~~ low
        > **Note:** nothing is spent until you approve.

        | Shot | Length | Price |
        |:-----|:------:|------:|
        | **1** | 4 s | $0.32 |
        | 2 | 8 s | $0.64 |

        ```swift
        let price = "**$0.64**"
        ```
        ---
        Done. See [pricing](https://muse.studio/pricing).
        """
        var prefix = ""
        for c in reply {
            prefix.append(c)
            assertNoMarkup(ChatMarkdown.parse(prefix, streaming: true))
        }
        assertNoMarkup(ChatMarkdown.parse(reply))
    }

    // MARK: Blocks

    func testHeadingsListsQuotesRulesAndCode() {
        let b = ChatMarkdown.parse("""
        # Title
        ### Small ###
        Text with
        a soft break.

        - one
        - two
          - nested
        * three
        3. third
        4) fourth
        - [ ] todo
        - [x] done

        > quoted **line**
        > second

        ***

        ```python
        print("hi")
        ```
        """)
        XCTAssertEqual(b[0], .heading(level: 1, [ChatRun("Title")]))
        XCTAssertEqual(b[1], .heading(level: 3, [ChatRun("Small")]))
        XCTAssertEqual(b[2], .paragraph([ChatRun("Text with\na soft break.")]))
        XCTAssertEqual(b[3], .listItem(ordered: false, number: 0, depth: 0, checked: nil, [ChatRun("one")]))
        XCTAssertEqual(b[5], .listItem(ordered: false, number: 0, depth: 1, checked: nil, [ChatRun("nested")]))
        XCTAssertEqual(b[7], .listItem(ordered: true, number: 3, depth: 0, checked: nil, [ChatRun("third")]))
        XCTAssertEqual(b[8], .listItem(ordered: true, number: 4, depth: 0, checked: nil, [ChatRun("fourth")]))
        XCTAssertEqual(b[9], .listItem(ordered: false, number: 0, depth: 0, checked: false, [ChatRun("todo")]))
        XCTAssertEqual(b[10], .listItem(ordered: false, number: 0, depth: 0, checked: true, [ChatRun("done")]))
        XCTAssertEqual(b[11], .quote([.paragraph([ChatRun("quoted "), ChatRun("line", bold: true), ChatRun("\nsecond")])]))
        XCTAssertEqual(b[12], .rule)
        XCTAssertEqual(b[13], .code(language: "python", text: "print(\"hi\")", closed: true))
        XCTAssertEqual(b.count, 14)
    }

    func testSetextHeadings() {
        XCTAssertEqual(ChatMarkdown.parse("Big\n===\nSmall\n---"), [.heading(level: 1, [ChatRun("Big")]), .heading(level: 2, [ChatRun("Small")])])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(ChatMarkdown.parse("#Dolly in on her"), [.paragraph([ChatRun("#Dolly in on her")])])
    }

    func testTable() {
        let b = ChatMarkdown.parse("""
        | Shot | Len | Price |
        |:--|:-:|--:|
        | `1` | 4 s | $0.32 |
        | 2 | 8 s |
        """)
        guard case .table(let h, let rows, let align)? = b.first else { return XCTFail("no table: \(b)") }
        XCTAssertEqual(h.map { text($0) }, ["Shot", "Len", "Price"])
        XCTAssertEqual(align, [.leading, .center, .trailing])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], [ChatRun("1", code: true)])
        XCTAssertEqual(rows[1].map { text($0) }, ["2", "8 s", ""])   // a short row is padded
    }

    func testTableCellWithEscapedPipeAndCodePipe() {
        guard case .table(_, let rows, _)? = ChatMarkdown.parse("| a | b |\n|---|---|\n| x \\| y | `p|q` |").first else { return XCTFail() }
        XCTAssertEqual(text(rows[0][0]), "x | y")
        XCTAssertEqual(rows[0][1], [ChatRun("p|q", code: true)])
    }

    func testStreamingTableWaitsForItsDelimiterRow() {
        XCTAssertEqual(ChatMarkdown.parse("Here:\n| Shot | Len |", streaming: true), [.paragraph([ChatRun("Here:")])])
        XCTAssertEqual(ChatMarkdown.parse("Here:\n| Shot | Len |\n|---|-", streaming: true), [.paragraph([ChatRun("Here:")])])
        guard case .table(_, let rows, _)? = ChatMarkdown.parse("| Shot | Len |\n|---|---|\n| 1 | 4", streaming: true).first else { return XCTFail() }
        XCTAssertTrue(rows.isEmpty)   // the row still arriving waits
    }

    func testStreamingCodeFence() {
        XCTAssertEqual(ChatMarkdown.parse("Try:\n```bash\nnpm i", streaming: true),
                       [.paragraph([ChatRun("Try:")]), .code(language: "bash", text: "npm i", closed: false)])
        XCTAssertEqual(ChatMarkdown.parse("```bash\nnpm i\n``", streaming: true), [.code(language: "bash", text: "npm i", closed: false)])
        XCTAssertEqual(ChatMarkdown.parse("```\nx", streaming: false), [.code(language: nil, text: "x", closed: true)])
    }

    func testStreamingHeadingMarkerAloneShowsNothing() {
        XCTAssertEqual(ChatMarkdown.parse("Intro\n\n##", streaming: true), [.paragraph([ChatRun("Intro")])])
        XCTAssertEqual(ChatMarkdown.parse("Intro\n\n## Pl", streaming: true), [.paragraph([ChatRun("Intro")]), .heading(level: 2, [ChatRun("Pl")])])
    }

    func testCodeBlockKeepsIndentAndMarkup() {
        let b = ChatMarkdown.parse("~~~\n  **x**\n# not a heading\n~~~")
        XCTAssertEqual(b, [.code(language: nil, text: "  **x**\n# not a heading", closed: true)])
    }

    func testPlainText() {
        let b = ChatMarkdown.parse("**Hi** there\n\n- one\n1. two")
        XCTAssertEqual(ChatMarkdown.plainText(b), "Hi there\n\n• one\n\n1. two")
    }

    func testBrTagsBecomeBreaks() {
        XCTAssertEqual(ChatMarkdown.parse("one<br>two"), [.paragraph([ChatRun("one\ntwo")])])
    }
}
