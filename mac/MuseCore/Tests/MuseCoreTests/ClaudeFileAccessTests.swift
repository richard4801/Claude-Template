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
