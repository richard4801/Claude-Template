import Foundation
import XCTest
@testable import MuseCore

/// Files on this Mac (owner, 2026-11-11): Claude Code asks before every file or command call; keys are never shared.
final class ClaudeFileAccessTests: XCTestCase {
    let home = "/Users/me"
    let cwd = "/Users/me/MUSE/Claude/ct_1"

    func ask(_ tool: String, _ input: [String: JSONValue]) -> ClaudePermissionAsk {
        ClaudePermissionAsk(id: "perm_1", toolName: tool, input: .object(input), toolUseId: "toolu_1")
    }

    func testFilesOnUsesThePermissionPromptToolAndKeepsTheWebOff() {
        var c = ClaudeCommand(mcpURL: "https://x/mcp", token: "t")
        let off = c.arguments(configPath: "/c.json")
        XCTAssertEqual(off[off.firstIndex(of: "--permission-mode")! + 1], "dontAsk")
        XCTAssertFalse(off.contains("--permission-prompt-tool"))
        XCTAssertTrue(off.contains("Bash") && off.contains("Write") && off.contains("Edit"))

        c.files = true
        let on = c.arguments(configPath: "/c.json")
        XCTAssertEqual(on[on.firstIndex(of: "--permission-mode")! + 1], "default")
        XCTAssertEqual(on[on.firstIndex(of: "--permission-prompt-tool")! + 1], "mcp__muse__permission_prompt")
        let deny = Array(on[(on.firstIndex(of: "--disallowedTools")! + 1)..<on.firstIndex(of: "--permission-mode")!])
        for t in ["WebFetch", "WebSearch", "NotebookEdit", "Read(~/.ssh/**)", "Read(**/.env)", "Read(**/.mcp-*.json)", "Edit(~/Library/Keychains/**)"] {
            XCTAssertTrue(deny.contains(t), t)
        }
        for t in ["Bash", "Read", "Write", "Edit", "Glob", "Grep"] { XCTAssertFalse(deny.contains(t), t) }
        XCTAssertEqual(on[on.firstIndex(of: "--allowedTools")! + 1], "mcp__muse")
        XCTAssertEqual(ClaudeCommand.environment([:], executable: "/bin/claude", home: home)["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"], "3700000")
    }

    func testEveryFileCallAsksWithTheExactPathAndFolder() {
        guard case .ask(let c) = ClaudeFilePolicy.verdict(ask("Read", ["file_path": .string("~/Movies/greybox.mp4")]), mode: .ask, folders: [], cwd: cwd, home: home) else {
            return XCTFail()
        }
        XCTAssertEqual(c.action, "Read a file")
        XCTAssertEqual(c.detail, "/Users/me/Movies/greybox.mp4")
        XCTAssertEqual(c.folder, "/Users/me/Movies")
        guard case .ask(let w) = ClaudeFilePolicy.verdict(ask("Write", ["file_path": .string("notes/a.txt")]), mode: .ask, folders: [], cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(w.detail, "/Users/me/MUSE/Claude/ct_1/notes/a.txt")
        guard case .ask(let g) = ClaudeFilePolicy.verdict(ask("Grep", ["pattern": .string("clip"), "path": .string("/Users/me/Movies")]), mode: .ask, folders: [], cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(g.folder, "/Users/me/Movies")
        XCTAssertEqual(g.detail, "/Users/me/Movies · clip")
    }

    func testAlwaysAllowedFolderCoversItsFilesOnlyAndNoEscapeWithDots() {
        let folders = ["/Users/me/Movies"]
        XCTAssertEqual(ClaudeFilePolicy.verdict(ask("Read", ["file_path": .string("/Users/me/Movies/a/b.mov")]), mode: .ask, folders: folders, cwd: cwd, home: home), .allow)
        if case .allow = ClaudeFilePolicy.verdict(ask("Read", ["file_path": .string("/Users/me/Movies/../Documents/x.txt")]), mode: .ask, folders: folders, cwd: cwd, home: home) { XCTFail("escaped") }
        if case .allow = ClaudeFilePolicy.verdict(ask("Read", ["file_path": .string("/Users/me/MoviesOld/x.mov")]), mode: .ask, folders: folders, cwd: cwd, home: home) { XCTFail("prefix") }
    }

    func testCommandsAlwaysAskAndNeverOfferAlways() {
        for (cmd, why) in [("ls -la ~/Movies", "Commands ask every time"), ("rm -rf out", "Always asks: it deletes"), ("mv a /tmp/b", "Always asks: it moves files"),
                           ("sudo ls", "Always asks: it needs admin rights"), ("curl https://x.y", "Always asks: it can reach the network"), ("/bin/rm x", "Always asks: it deletes")] {
            guard case .ask(let c) = ClaudeFilePolicy.verdict(ask("Bash", ["command": .string(cmd)]), mode: .ask, folders: ["/"], cwd: cwd, home: home) else { return XCTFail(cmd) }
            XCTAssertNil(c.folder, cmd)
            XCTAssertEqual(c.detail, cmd)
            XCTAssertEqual(c.alwaysAsksBecause, why, cmd)
        }
    }

    func testKeysAndTokensAreRefusedEvenInAnAllowedFolder() {
        let refused: [(String, [String: JSONValue])] = [
            ("Read", ["file_path": .string("/Users/me/app/.env")]), ("Read", ["file_path": .string("/Users/me/app/.env.local")]),
            ("Read", ["file_path": .string("~/.ssh/id_ed25519")]), ("Edit", ["file_path": .string("/Users/me/.aws/config")]),
            ("Read", ["file_path": .string("/Users/me/Library/Keychains/login.keychain-db")]), ("Read", ["file_path": .string("/Users/me/certs/server.pem")]),
            ("Read", ["file_path": .string(".mcp-1234.json")]), ("Grep", ["pattern": .string("x"), "path": .string("~/.claude")]),
            ("Glob", ["pattern": .string("**/.env")]), ("Bash", ["command": .string("cat ~/.netrc")]), ("Bash", ["command": .string("grep KEY app/.env")]),
        ]
        for (tool, input) in refused {
            XCTAssertEqual(ClaudeFilePolicy.verdict(ask(tool, input), mode: .ask, folders: ["/"], cwd: cwd, home: home), .deny(ClaudeFilePolicy.credentialRefusal), "\(tool) \(input)")
        }
    }

    func testUploadAsksWithTheFileNameAndTakesOnlyImagesAndVideos() {
        guard case .ask(let c) = ClaudeFilePolicy.verdict(ask("Upload", ["file_path": .string("~/Shoot/layout_A_house.png"), "purpose": .string("reference")]),
                                                          mode: .ask, folders: [], cwd: cwd, home: home) else { return XCTFail() }
        XCTAssertEqual(c.action, "Upload layout_A_house.png to MUSE")
        XCTAssertEqual(c.detail, "/Users/me/Shoot/layout_A_house.png")
        XCTAssertEqual(c.folder, "/Users/me/Shoot")
        XCTAssertEqual(ClaudeFilePolicy.verdict(ask("Upload", ["file_path": .string("/Users/me/Shoot/b.MOV")]), mode: .ask, folders: ["/Users/me/Shoot"], cwd: cwd, home: home), .allow)
        XCTAssertEqual(ClaudeFilePolicy.verdict(ask("Upload", ["file_path": .string("/Users/me/notes.txt")]), mode: .ask, folders: [], cwd: cwd, home: home), .deny(ClaudeFilePolicy.uploadRefusal))
        XCTAssertEqual(ClaudeFilePolicy.verdict(ask("Upload", ["file_path": .string("/Users/me/.ssh/id_rsa.png")]), mode: .ask, folders: ["/"], cwd: cwd, home: home), .deny(ClaudeFilePolicy.credentialRefusal))
        XCTAssertEqual(ClaudeFilePolicy.uploadType("a.heic")?.mime, "image/heic")
        XCTAssertEqual(ClaudeFilePolicy.uploadType("a.mov")?.video, true)
        XCTAssertNil(ClaudeFilePolicy.uploadType("a.txt"))
    }

    func testOffRefusesEverything() {
        XCTAssertEqual(ClaudeFilePolicy.verdict(ask("Read", ["file_path": .string("/Users/me/a.txt")]), mode: .off, folders: ["/"], cwd: cwd, home: home), .deny(ClaudeFilePolicy.offRefusal))
    }

    func testSettingsKeepFoldersPerChat() throws {
        var s = ClaudeFileSettings()
        XCTAssertEqual(s.mode, .ask)
        s.allow("/Users/me/Movies", chatId: "ct_1", chatTitle: "Clip 8")
        s.allow("/Users/me/Movies", chatId: "ct_1", chatTitle: "Clip 8")
        XCTAssertEqual(s.folders(chatId: "ct_1"), ["/Users/me/Movies"])
        XCTAssertEqual(s.folders(chatId: "ct_2"), [])
        let back = try JSONDecoder().decode(ClaudeFileSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        s.remove(s.folders[0].id)
        XCTAssertTrue(s.folders.isEmpty)
    }

    func testPermissionLiveEvents() {
        let e = ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"permission","ask":{"id":"perm_1","toolName":"Read","input":{"file_path":"/a"},"toolUseId":"toolu_1","createdAt":1}}"#.utf8))
        XCTAssertEqual(e, .permission(ClaudePermissionAsk(id: "perm_1", toolName: "Read", input: .object(["file_path": .string("/a")]), toolUseId: "toolu_1", createdAt: 1)))
        XCTAssertEqual(ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"permission_end","id":"perm_1"}"#.utf8)), .permissionEnd(id: "perm_1"))
    }
}

/// Results arrive in the chat: one turn per chat and batch, the person sees one line, Claude gets the details.
final class ClaudeResultsTests: XCTestCase {
    func r(_ chat: String, _ job: String, status: String = "done", kind: String = "shot", title: String = "Shot · Beach walk", takes: [String]? = ["t_1", "t_2"]) -> ClaudeJobResult {
        ClaudeJobResult(chatId: chat, jobId: job, kind: kind, status: status, title: title, takeIds: takes, error: status == "done" ? nil : "Out of credit")
    }

    func testResultsOfAChatWithinFiveSecondsMakeOneTurn() {
        var b = ClaudeResultBatcher(quiet: 5)
        b.add(r("ct_1", "j1"), now: 100)
        b.add(r("ct_1", "j2"), now: 103)
        b.add(r("ct_1", "j2"), now: 103.5) // the same job again: once
        b.add(r("ct_2", "j3"), now: 104)
        XCTAssertTrue(b.due(now: 107).isEmpty)          // ct_1 heard 3.5 s ago
        let first = b.due(now: 108.6)
        XCTAssertEqual(first.map(\.chatId), ["ct_1"])
        XCTAssertEqual(first[0].results.map(\.jobId), ["j1", "j2"])
        XCTAssertEqual(b.due(now: 109.1).map(\.chatId), ["ct_2"])
        XCTAssertTrue(b.isEmpty)
    }

    func testTheMessageShowsOneLineAndHidesTheInstructions() {
        let m = ClaudeResultBatcher.message([r("ct_1", "j1"), r("ct_1", "j2", status: "failed", kind: "photo", title: "Photo · 4 photos", takes: nil)])
        XCTAssertTrue(m.hasPrefix("Result arrived · Shot · Beach walk · 2 takes · Photo · 4 photos · didn't finish\n<instructions>"))
        XCTAssertTrue(m.contains("takes t_1, t_2"))
        XCTAssertTrue(m.contains("failed: Out of credit"))
        XCTAssertTrue(m.contains("Never retry or start anything that costs money on your own"))
        XCTAssertEqual(ChatLeakFilter.userText(m), "Result arrived · Shot · Beach walk · 2 takes · Photo · 4 photos · didn't finish")
        XCTAssertEqual(r("c", "j", kind: "photo", title: "Photo · 4 photos", takes: ["a", "b", "c", "d"]).line, "Photo · 4 photos")
    }

    func testResultLiveEventAndDefaultMode() throws {
        let e = ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"result","result":{"chatId":"ct_1","jobId":"j1","kind":"shot","status":"done","title":"Shot","takeIds":["t_1"]}}"#.utf8))
        XCTAssertEqual(e, .result(ClaudeJobResult(chatId: "ct_1", jobId: "j1", kind: "shot", status: "done", title: "Shot", takeIds: ["t_1"])))
        let old = try JSONDecoder().decode(ClaudeFileSettings.self, from: Data(#"{"mode":"ask","folders":[]}"#.utf8))
        XCTAssertEqual(old.resultMode, .look)
    }
}
