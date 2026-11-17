import XCTest
@testable import MuseCore

/// Build 704 "it lags": the chat's streamed text is joined before it reaches the screen, the orb skips pulses no one can
/// see, and the chat's per-message text work is kept by text.
final class IdlePerfTests: XCTestCase {
    func testDeltasAreHeldAndJoined() {
        var c = ClaudeDeltaCoalescer()
        XCTAssertEqual(c.add(.text(delta: "Hel")), [])
        XCTAssertEqual(c.add(.text(delta: "lo ")), [])
        XCTAssertEqual(c.add(.text(delta: "there")), [])
        XCTAssertFalse(c.isEmpty)
        XCTAssertEqual(c.flush(), .text(delta: "Hello there"))
        XCTAssertTrue(c.isEmpty)
        XCTAssertNil(c.flush())
    }

    func testOtherEventsLetTheTextOutFirstInOrder() {
        var c = ClaudeDeltaCoalescer()
        _ = c.add(.text(delta: "Looking"))
        let tool = ClaudeEvent.tool(id: "t1", name: "Read", status: .running, summary: nil, input: nil)
        XCTAssertEqual(c.add(tool), [.text(delta: "Looking"), tool])
        let done = ClaudeEvent.done(ok: true, error: nil, model: nil)
        XCTAssertEqual(c.add(done), [done])
        XCTAssertTrue(c.isEmpty)
    }

    func testJoinedDeltasBuildTheSameTranscript() {
        let parts = ["The ", "**café** ", "shot ", "is ", "ready."]
        var a = ClaudeTranscript(), b = ClaudeTranscript()
        a.apply(.user(text: "go"))
        b.apply(.user(text: "go"))
        for p in parts { a.apply(.text(delta: p)) }
        var c = ClaudeDeltaCoalescer()
        for p in parts { for e in c.add(.text(delta: p)) { b.apply(e) } }
        if let t = c.flush() { b.apply(t) }
        a.apply(.done(ok: true, error: nil, model: nil))
        for e in c.add(.done(ok: true, error: nil, model: nil)) { b.apply(e) }
        XCTAssertEqual(a.items, b.items)
    }

    func testResetDropsWaitingText() {
        var c = ClaudeDeltaCoalescer()
        _ = c.add(.text(delta: "old chat"))
        c.reset()
        XCTAssertNil(c.flush())
    }

    func testOrbSkipsChunksTooCloseTogether() {
        var o = ClaudeOrb()
        XCTAssertTrue(o.chunkChangesAnything(at: 100)) // not running yet: the first chunk starts thinking
        o.chunk(at: 100)
        XCTAssertFalse(o.chunkChangesAnything(at: 100.1))
        XCTAssertFalse(o.chunkChangesAnything(at: 100.24))
        XCTAssertTrue(o.chunkChangesAnything(at: 100.25))
        o.turnEnded(ok: true, at: 101)
        XCTAssertTrue(o.chunkChangesAnything(at: 101.01)) // a new turn's first chunk always counts
    }

    func testBoundedMemoKeepsAndCaps() {
        let m = BoundedMemo<String, Int>(limit: 3)
        var made = 0
        XCTAssertEqual(m.value("a") { made += 1; return 1 }, 1)
        XCTAssertEqual(m.value("a") { made += 1; return 9 }, 1)
        XCTAssertEqual(made, 1)
        XCTAssertEqual(m.hits, 1)
        _ = m.value("b") { 2 }
        _ = m.value("c") { 3 }
        XCTAssertEqual(m.count, 3)
        _ = m.value("d") { 4 } // full: starts again
        XCTAssertLessThanOrEqual(m.count, 3)
    }

    func testChatTextCacheMatchesTheFilterAndParser() {
        let reply = "Here is **bold** and `code`.\n\n- one\n- two"
        XCTAssertEqual(ChatTextCache.reply(reply, audience: .owner), ChatLeakFilter.reply(reply, audience: .owner))
        XCTAssertEqual(ChatTextCache.reply(reply, audience: .owner), ChatLeakFilter.reply(reply, audience: .owner)) // cached
        XCTAssertEqual(ChatTextCache.reply(reply, audience: .member), ChatLeakFilter.reply(reply, audience: .member))
        XCTAssertEqual(ChatTextCache.markdown(reply, streaming: false), ChatMarkdown.parse(reply))
        XCTAssertEqual(ChatTextCache.markdown("**half", streaming: true), ChatMarkdown.parse("**half", streaming: true))
        XCTAssertEqual(ChatTextCache.userText("hi"), ChatLeakFilter.userText("hi"))
        XCTAssertEqual(ChatTextCache.toolSummary("ls", name: "Bash"), ChatLeakFilter.toolSummary("ls", name: "Bash"))
    }
}
