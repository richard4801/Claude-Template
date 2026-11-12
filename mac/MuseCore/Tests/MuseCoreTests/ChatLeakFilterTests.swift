import XCTest
@testable import MuseCore

/// Claude chat on the Mac (plans/claude-chat-mac.md "No leaks"): nothing internal reaches the chat.
final class ChatLeakFilterTests: XCTestCase {
    func testSystemBriefsAndThinkingAreRemoved() {
        let s = ChatLeakFilter.reply("<system-reminder>You are MUSE's editor. Tools: …</system-reminder>Trimmed the intro.\n<thinking>plan</thinking>Done.")
        XCTAssertEqual(s, "Trimmed the intro.\nDone.")
        // Mid-stream: an opening tag with no close hides what follows.
        XCTAssertEqual(ChatLeakFilter.reply("Okay. <system-reminder>secret bri"), "Okay.")
        // Not a tag: kept.
        XCTAssertEqual(ChatLeakFilter.reply("a <systematic> b"), "a <systematic> b")
    }

    func testContextLinesGo() {
        XCTAssertEqual(ChatLeakFilter.reply("[Suite composer: draft 3 · tool shot]\nSet it up."), "Set it up.")
        XCTAssertEqual(ChatLeakFilter.userText("[Recreate reference rr_12 · edit session es_9]\nExplain shot 2"), "Explain shot 2")
    }

    func testRawToolJSONGoes() {
        let s = ChatLeakFilter.reply("""
        Here is what I sent:
        {"tool":"apply_edit_ops","input":{"ops":[{"op":"trim","start":3}]}}
        ```json
        {"ok": true}
        ```
        ```swift
        let a = 1
        ```
        Trimmed.
        """)
        XCTAssertEqual(s, "Here is what I sent:\n```swift\nlet a = 1\n```\nTrimmed.")
        XCTAssertEqual(ChatLeakFilter.reply("Working.\n{\"tool\":\"suite_set_dr"), "Working.")
    }

    func testStackTracesGo() {
        let s = ChatLeakFilter.reply("""
        That failed.
        TypeError: Cannot read properties of undefined (reading 'id') at run (/app/dist/tools.js:42:7)
            at async handler (/app/dist/server.js:10:3)
        Traceback (most recent call last):
          File "/opt/render.py", line 12, in <module>
            main()
        I'll try another way.
        """)
        XCTAssertEqual(s, "That failed.\nI'll try another way.")
    }

    func testIdsAndPathsGo() {
        XCTAssertEqual(ChatLeakFilter.reply("Saved take tk_8f3a2c to /Users/ann/Library/Caches/MUSE/claude/ct_1/ca_1.png for you."),
                       "Saved take to a file on this Mac for you.")
        XCTAssertEqual(ChatLeakFilter.reply("Exported to ~/Movies/final_cut.mp4, ready."), "Exported to ~/Movies/final_cut.mp4, ready.")
        XCTAssertEqual(ChatLeakFilter.reply("Wrote /Users/ann/Desktop/trailer.mp4."), "Wrote /Users/ann/Desktop/trailer.mp4.")
        // The person's own files show as real paths; MUSE's own folders, id-named files and keys don't.
        XCTAssertEqual(ChatLeakFilter.reply("Found /Volumes/Shoot/layout_A_house.png here."), "Found /Volumes/Shoot/layout_A_house.png here.")
        XCTAssertEqual(ChatLeakFilter.reply("Config in /Users/ann/MUSE/Claude/ct_1/.mcp-ab12.json."), "Config in a file on this Mac.")
        XCTAssertEqual(ChatLeakFilter.reply("Key at /Users/ann/.ssh/id_ed25519 now."), "Key at a file on this Mac now.")
        XCTAssertEqual(ChatLeakFilter.reply("Thread 3f2b8c1e-1d2a-4c5b-9e8f-0a1b2c3d4e5f is open (id: es_42)."), "Thread is open.")
        XCTAssertEqual(ChatLeakFilter.reply("Used mcp__muse__apply_edit_ops."), "Used apply edit ops.")
        // A link keeps its path; words like "turn left" stay.
        XCTAssertEqual(ChatLeakFilter.reply("See https://muse.studio/app/docs (turn left at the door)."), "See https://muse.studio/app/docs (turn left at the door).")
        // Paths inside a code block are kept: a script needs them.
        XCTAssertEqual(ChatLeakFilter.reply("```\ncd /Users/ann/Movies\n```"), "```\ncd /Users/ann/Movies\n```")
        XCTAssertEqual(ChatLeakFilter.reply("Keep golden_warmth and `render()`."), "Keep golden_warmth and `render()`.")
    }

    func testMembersNeverSeeProvidersOrModels() {
        let s = ChatLeakFilter.reply("I rendered it with seedance-1-pro on Replicate's H100.", audience: .member)
        XCTAssertFalse(s.lowercased().contains("seedance"))
        XCTAssertFalse(s.lowercased().contains("replicate"))
        XCTAssertFalse(s.lowercased().contains("h100"))
        XCTAssertTrue(MemberText.isSafe(s), s)
        // The owner may see them.
        XCTAssertEqual(ChatLeakFilter.reply("Rendered with seedance-1-pro.", audience: .owner), "Rendered with seedance-1-pro.")
    }

    func testUserTextDropsSuggestionInstructionsAndImagePaths() {
        XCTAssertEqual(ChatLeakFilter.userText("Explain shot 2 of this reference: what happens and the camera. Use get_recipe."),
                       "Explain shot 2 of this reference: what happens and the camera.")
        XCTAssertEqual(ChatLeakFilter.userText("Use this pose\n\nAttached images (Read each one):\n- /c/MUSE/claude/ct_1/ca_1.png (uploadId up_1)"), "Use this pose")
        XCTAssertEqual(ChatLeakFilter.userText("Make it warmer"), "Make it warmer")
    }

    func testToolSummaryAndDetail() {
        XCTAssertEqual(ChatLeakFilter.toolSummary("Trimmed 0:03–0:05", name: "mcp__muse__apply_edit_ops"), "Trimmed 0:03–0:05")
        XCTAssertEqual(ChatLeakFilter.toolSummary("{\"ok\":true}", name: "mcp__muse__get_frame"), "Get frame")
        XCTAssertEqual(ChatLeakFilter.toolSummary("Read es_12", name: "get_edit"), "Read")
        XCTAssertEqual(ChatLeakFilter.toolDetail(name: "mcp__muse__get_frame", summary: "Get frame", status: .done), "Get frame. Finished.")
        XCTAssertEqual(ChatLeakFilter.toolDetail(name: "mcp__muse__apply_edit_ops", summary: "Trimmed 0:03–0:05", status: .running),
                       "Apply edit ops: Trimmed 0:03–0:05. Still running.")
        XCTAssertTrue(ChatLeakFilter.toolDetail(name: "x", summary: "y", status: .error).contains("didn't work"))
    }

    func testErrorsInPlainWords() {
        XCTAssertEqual(ChatLeakFilter.errorWords(nil), "Claude couldn't finish this reply. Try again.")
        XCTAssertEqual(ChatLeakFilter.errorWords("Error: 429 rate_limit_error"), "Your Claude plan has reached its limit for now. Try again in a little while.")
        XCTAssertEqual(ChatLeakFilter.errorWords("NSURLErrorDomain -1009"), "Couldn't reach the server. Check your connection, then try again.")
        XCTAssertEqual(ChatLeakFilter.errorWords("Claude Code isn't ready on this Mac"), "Claude Code isn't ready on this Mac. Open Settings to set it up, then try again.")
        XCTAssertEqual(ChatLeakFilter.errorWords("Stopped by the owner"), "Stopped. Send a message to carry on.")
        XCTAssertEqual(ChatLeakFilter.errorWords("Your Mac stopped answering"), "Claude on this Mac stopped answering. Try again.")
        XCTAssertEqual(ChatLeakFilter.errorWords("TypeError: x is undefined\n    at run (/app/a.js:1:2)"), "Claude couldn't finish this reply. Try again.")
        XCTAssertEqual(ChatLeakFilter.errorWords("The take is still rendering"), "The take is still rendering.")
        for raw in ["exit code 1", "{\"error\":\"boom\"}", "spawn /usr/local/bin/claude ENOENT", "The GPU disconnected"] {
            let w = ChatLeakFilter.errorWords(raw)
            XCTAssertFalse(w.contains("/"), w)
            XCTAssertFalse(w.contains("{"), w)
            XCTAssertTrue(MemberText.isSafe(w), w)
        }
    }

    func testRepliesWithTheFilterThenMarkdownShowNoMarkupOrPlumbing() {
        let raw = "<system-reminder>brief</system-reminder>**Done.** Trimmed take `tk_9a8b7c` in /Users/ann/x/es_1.json"
        let blocks = ChatMarkdown.parse(ChatLeakFilter.reply(raw))
        let shown = ChatMarkdown.plainText(blocks)
        XCTAssertFalse(shown.contains("brief"))
        XCTAssertFalse(shown.contains("tk_"))
        XCTAssertFalse(shown.contains("/Users"))
        XCTAssertTrue(shown.hasPrefix("Done."), shown)
    }

    /// The review sample, as the chat draws it: none of its plumbing shows, and no markup survives.
    func testTheSampleThreadShowsNoPlumbing() {
        for kind in ["camera", "edit", "suite", "recreate"] {
            var tr = ClaudeTranscript()
            tr.load(ClaudeChatSample.messages(threadId: "t", kind: kind))
            for e in ClaudeChatSample.liveEvents { tr.apply(e) }
            var shown: [String] = []
            for item in tr.items {
                switch item {
                case .user(_, let text, _): shown.append(ChatLeakFilter.userText(text))
                case .assistant(_, let text, let streaming):
                    shown.append(ChatMarkdown.plainText(ChatMarkdown.parse(ChatLeakFilter.reply(text), streaming: streaming)))
                case .tool(_, let name, let summary, _): shown.append(ChatLeakFilter.toolSummary(summary, name: name))
                case .image: break
                case .card: break
                }
            }
            let all = shown.joined(separator: "\n")
            for bad in ["[Suite", "[Recreate", "get_recipe", "tk_8f3a2c", "/Users", "system-reminder", "You are MUSE", "mcp__", "**", "rr_12"] {
                XCTAssertFalse(all.contains(bad), "\(kind): \(bad) shown")
            }
            XCTAssertTrue(all.contains("Golden war"), kind)   // the streaming text, styled, not dropped
        }
    }

    func testLocalImagesHaveNoUploadIdInThePrompt() {
        let files = [ClaudeAttachmentFile(path: "/c/MUSE/claude/ct_1/local-1.png", uploadId: "")]
        XCTAssertEqual(ClaudeAttachmentPrompt.text("Match this", files), "Match this\n\nAttached images (Read each one):\n- /c/MUSE/claude/ct_1/local-1.png")
    }
}
