import Foundation
import XCTest
@testable import MuseCore

/// ci_c64e3cab2c7f (owner, 2026-11-15): "Always allow does not stick". One "Always allow" covers the KIND (shell commands,
/// the project folder's files, temporary files, each MUSE tool), in every chat and after a relaunch, and Settings can take
/// it back. The hard walls stay.
final class ClaudeKindGrantsTests: XCTestCase {
    let home = "/Users/me"
    let project = "/Users/me/Desktop/GRWM"
    func cwd(_ chat: String) -> String { "/Users/me/MUSE/Claude/\(chat)" }

    func ask(_ tool: String, _ input: [String: JSONValue], id: String = "perm_1") -> ClaudePermissionAsk {
        ClaudePermissionAsk(id: id, toolName: tool, input: .object(input), toolUseId: "toolu_\(id)")
    }
    func bash(_ cmd: String) -> ClaudePermissionAsk { ask("Bash", ["command": .string(cmd)]) }

    /// The verdict with a person's saved settings, the way ClaudeCodeService asks for it.
    func verdict(_ a: ClaudePermissionAsk, _ s: ClaudeFileSettings, chat: String = "ct_1", script: String? = nil,
                 dirs: Set<String> = []) -> ClaudeFileVerdict {
        ClaudeFilePolicy.verdict(a, mode: s.mode, folders: s.activeFolders, cwd: cwd(chat), home: home, rules: s.activeRules,
                                 askAll: s.askAll, shell: s.activeShell, tools: s.activeTools,
                                 isDirectory: { dirs.contains($0) }, readScript: { _ in script })
    }

    /// What ClaudeCodeService.answerFile does with "Allow always".
    func always(_ card: ClaudeFileCard, into s: inout ClaudeFileSettings) {
        if card.shell { s.allowShell() }
        if let t = card.tool { s.allowTool(t) }
        if let r = card.rule { s.allowRule(r) }
        for f in card.ruleFolders { s.allowFolder(f) }
        if !card.shell, card.tool == nil, card.rule == nil, let f = card.folder { s.allowFolder(f) }
    }

    func card(_ v: ClaudeFileVerdict, file: StaticString = #filePath, line: UInt = #line) -> ClaudeFileCard? {
        if case .ask(let c) = v { return c }
        XCTFail("expected a card, got \(v)", file: file, line: line)
        return nil
    }

    // MARK: The owner's session (Gamified GRWM): approve once with always, then no more cards

    func testOneAlwaysPerKindThenTheWholeSessionRunsWithoutCardsInANewChatToo() throws {
        var s = ClaudeFileSettings()
        // 1. A read of a still in the project: Allow always saves the PROJECT, not stills/.
        let read = try XCTUnwrap(card(verdict(ask("Read", ["file_path": .string("\(project)/stills/s01.png")]), s)))
        XCTAssertEqual(read.folder, project)
        XCTAssertEqual(read.alwaysLabel, "Allow always")
        always(read, into: &s)
        // 2. A shell command (ffmpeg on the project, writing to /tmp): Allow always: shell commands.
        let first = "ffmpeg -y -i \(project)/clips/c01.mp4 -vf scale=1080:-2 /tmp/grwm/c01.mp4"
        let sh = try XCTUnwrap(card(verdict(bash(first), s)))
        XCTAssertEqual(sh.alwaysLabel, "Allow always: shell commands")
        XCTAssertTrue(sh.ruleFolders.isEmpty, "\(sh.ruleFolders)")
        always(sh, into: &s)
        // 3. A MUSE tool Claude Code asked about: by name.
        let tool = try XCTUnwrap(card(verdict(ask("mcp__muse__suite_add_reference", ["uploadId": .string("up_1")]), s)))
        XCTAssertEqual(tool.alwaysLabel, "Allow always: suite_add_reference")
        XCTAssertEqual(tool.action, "Use suite_add_reference")
        always(tool, into: &s)

        // The settings survive a relaunch (they're stored as JSON in the app's defaults).
        let saved = try JSONDecoder().decode(ClaudeFileSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(saved, s)

        // A NEW chat (another run folder), after the relaunch: everything of those kinds goes through, 0 cards.
        let session: [ClaudePermissionAsk] = [
            bash("mkdir -p /tmp/grwm && cd \(project)/clips && for f in *.mp4; do ffmpeg -y -i \"$f\" -t 3 \"/tmp/grwm/${f%.mp4}_cut.mp4\"; done"),
            bash("ffprobe -v error -show_entries format=duration -of csv=p=0 \(project)/clips/c02.mp4"),
            bash("cd \(project) && python3 tools/make_grid.py stills /tmp/grwm/grid.png 2>&1 | tail -n 20"),
            bash("python3 -c \"from PIL import Image; im = Image.open('/tmp/grwm/grid.png'); print(im.size)\""),
            bash("ffmpeg -y -i /tmp/grwm/c01_cut.mp4 -vf \"drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='Level 1'\" \(project)/out/l1.mp4"),
            ask("Read", ["file_path": .string("\(project)/clips/c02.mp4")]),
            ask("Read", ["file_path": .string("/tmp/grwm/grid.png")]),
            ask("Read", ["file_path": .string("/private/tmp/grwm/frame_0001.png")]),
            ask("Upload", ["file_path": .string("\(project)/stills/s02.png"), "purpose": .string("reference")]),
            ask("Upload", ["file_path": .string("/tmp/grwm/c01_cut.mp4"), "purpose": .string("clip")]),
            ask("Upload", ["file_path": .string("\(project)/out/l1.mp4"), "purpose": .string("clip")]),
            ask("mcp__muse__suite_add_reference", ["uploadId": .string("up_2")]),
        ]
        let script = "import subprocess, sys\nfrom PIL import Image\nsubprocess.run(['ffmpeg', '-y', '-i', sys.argv[1], '/tmp/grwm/x.png'])\n"
        for a in session {
            XCTAssertEqual(verdict(a, saved, chat: "ct_2", script: script), .allow, "\(a.toolName) \(a.input.map { "\($0)" } ?? "")")
        }
    }

    func testFiveMoreOfTheSameKindAfterOneAlwaysAskNothing() throws {
        var s = ClaudeFileSettings()
        let c = try XCTUnwrap(card(verdict(bash("ffmpeg -i \(cwd("ct_1"))/a.mp4 /tmp/a.wav"), s)))
        always(c, into: &s)
        let more = [
            "ffmpeg -y -i /tmp/a.wav -af loudnorm /tmp/b.wav",
            "ls -la /tmp && du -sh /tmp/*.wav",
            "python3 /tmp/beats.py /tmp/b.wav",
            "sips -Z 1080 /tmp/frame.png --out /tmp/frame_small.png",
            "cat /tmp/beats.json | head -n 5",
        ]
        let prompts = more.filter { verdict(bash($0), s, chat: "ct_9", script: "print(1)\n") != .allow }
        XCTAssertEqual(prompts, [], "these asked again")
    }

    // MARK: Kind matching and its walls

    func testTheShellKindStaysInsideTheFoldersAndTempUnlessAnywhere() throws {
        var s = ClaudeFileSettings()
        s.allowFolder(project)
        s.allowShell()
        XCTAssertEqual(verdict(bash("cat \(project)/notes.txt | wc -l"), s), .allow)
        // Outside the folders: a card that also allows the project folder of that place.
        let out = try XCTUnwrap(card(verdict(bash("ffmpeg -i /Users/me/Movies/Old/clips/a.mp4 /tmp/a.mp4"), s)))
        XCTAssertEqual(out.alwaysLabel, "Allow always: shell commands")
        XCTAssertEqual(out.ruleFolders, ["/Users/me/Movies/Old"])
        XCTAssertEqual(out.alwaysCovers(home: home), "Any command inside your folders; also allows ~/Movies/Old, in every chat")
        always(out, into: &s)
        XCTAssertEqual(verdict(bash("ffmpeg -i /Users/me/Movies/Old/b.mp4 /tmp/b.mp4"), s), .allow)
        // Ways out of the folders still ask.
        for cmd in ["cd /etc && cat hosts", "cat /tmp/../etc/hosts", "cp /tmp/a.mp4 $HOME/Documents/", "cp /tmp/a.mp4 \"/Users/me/Documents/${x}.mp4\"",
                    "cd \(project) && cat ../../Documents/notes.txt", "ffmpeg -i /tmp/a.mp4 -o/etc/x", "python3 -c \"open('/Users/me/Documents/a.txt').read()\"",
                    "python3 -c \"import os; print(os.path.expanduser('~'))\"", "cat ~/.zshrc"] {
            if case .allow = verdict(bash(cmd), s) { XCTFail("ran outside the folders: \(cmd)") }
        }
        // "Anywhere": any folder (but never ~/Library, never keys, and the hard kinds still ask).
        s.shellScope = .anywhere
        XCTAssertEqual(verdict(bash("ls /Users/me/Documents/Taxes"), s), .allow)
        for (cmd, why) in [("ls ~/Library/Preferences", "it reaches a folder that can't be always allowed (it's in ~/Library)"),
                           ("rm -rf /tmp/grwm", "it deletes files"),
                           ("sudo ffmpeg -i /tmp/a.mp4 /tmp/b.mp4", "it needs admin rights"),
                           ("curl -sO https://x.example/a.mp4", "it uses the network or installs software"),
                           ("osascript -e 'tell app \"Finder\" to quit'", "it changes system settings or controls other apps")] {
            let c = try XCTUnwrap(card(verdict(bash(cmd), s)), cmd)
            XCTAssertNil(c.alwaysLabel, cmd)
            XCTAssertEqual(c.alwaysAsksBecause, "Always asks: \(why)", cmd)
        }
        // allowShell() never narrows an "Anywhere" already given.
        s.allowShell()
        XCTAssertEqual(s.shellScope, .anywhere)
    }

    func testKeysAreRefusedWhateverIsAllowed() {
        var s = ClaudeFileSettings()
        s.allowFolder(project)
        s.allowShell(.anywhere)
        s.allowFolder("/tmp")
        for a in [bash("cat ~/.ssh/id_ed25519"), bash("cp \(project)/.env /tmp/x"), ask("Read", ["file_path": .string("\(project)/.env")]),
                  ask("Upload", ["file_path": .string("/tmp/.ssh/key.png")])] {
            XCTAssertEqual(verdict(a, s), .deny(ClaudeFilePolicy.credentialRefusal), "\(a.input.map { "\($0)" } ?? "")")
        }
        // A script that reads a key: asks (and never offers Always).
        guard case .ask(let c) = verdict(bash("python3 /tmp/x.py"), s, script: "open('/Users/me/.ssh/id_rsa').read()\n") else { return XCTFail() }
        XCTAssertNil(c.alwaysLabel)
    }

    func testTheProjectFolderIsTheShootNotTheSubfolder() {
        XCTAssertEqual(ClaudeKindGrants.projectFolder("/Users/me/Desktop/GRWM/stills/raw", home: home), project)
        XCTAssertEqual(ClaudeKindGrants.projectFolder("/Users/me/Desktop", home: home), "/Users/me/Desktop")
        XCTAssertEqual(ClaudeKindGrants.projectFolder("/Volumes/Work/Footage/day1/a", home: home), "/Volumes/Work/Footage")
        XCTAssertEqual(ClaudeKindGrants.projectFolder("/tmp/grwm/frames", home: home), "/tmp")
        XCTAssertEqual(ClaudeKindGrants.projectFolder("/var/folders/ab/xyz/T/tmp.1", home: home), "/var/folders/ab/xyz/T")
        // A temp file card offers temporary files.
        let s = ClaudeFileSettings()
        guard case .ask(let c) = verdict(ask("Read", ["file_path": .string("/private/tmp/grwm/a.png")]), s) else { return XCTFail() }
        XCTAssertEqual(c.folder, "/tmp")
        XCTAssertEqual(c.alwaysCovers(home: home), "Allow always covers temporary files (reading, writing and uploading) in every chat")
    }

    func testMuseToolsByNameAndOtherToolsStillAsk() {
        var s = ClaudeFileSettings()
        s.allowTool("mcp__muse__get_frame")
        XCTAssertEqual(verdict(ask("mcp__muse__get_frame", [:]), s), .allow)
        guard case .ask(let other) = verdict(ask("mcp__muse__apply_edit_ops", [:]), s) else { return XCTFail("another tool ran") }
        XCTAssertEqual(other.alwaysLabel, "Allow always: apply_edit_ops")
        guard case .ask(let b) = verdict(ask("mcp__blender__get_scene_info", [:]), s) else { return XCTFail() }
        XCTAssertEqual(b.alwaysLabel, "Allow always: blender get_scene_info")
        // A tool that isn't a server's (Claude Code's own, unknown): asks every time, no Always.
        guard case .ask(let u) = verdict(ask("Task", [:]), s) else { return XCTFail() }
        XCTAssertNil(u.alwaysLabel)
        XCTAssertFalse(ClaudeKindGrants.isServerTool(ClaudeCommand.permissionPromptTool))
    }

    // MARK: Persistence, revoke, pause

    func testOldSettingsStillReadAndNewOnesRoundTrip() throws {
        // Saved by build 661 (no kind fields): reads, with nothing of the new kinds on.
        let old = try JSONDecoder().decode(ClaudeFileSettings.self, from: Data(#"""
        {"mode":"ask","folders":[],"alwaysFolders":["/Users/me/Desktop/GRWM/stills"],"commandRules":[{"program":"ffmpeg"}]}
        """#.utf8))
        XCTAssertNil(old.shellScope)
        XCTAssertTrue(old.tools.isEmpty)
        XCTAssertEqual(old.rules, [ClaudeCommandRule(program: "ffmpeg")])
        // Its old ffmpeg rule still works where it did.
        XCTAssertEqual(verdict(bash("ffmpeg -i /Users/me/Desktop/GRWM/stills/a.png /Users/me/Desktop/GRWM/stills/b.jpg"), old), .allow)
        var s = old
        s.allowShell(); s.allowTool("mcp__muse__watch"); s.allowTool("mcp__muse__watch")
        s.allowFolder(project)   // the wider folder replaces stills/
        XCTAssertEqual(s.allowedFolders, [project])
        XCTAssertEqual(s.tools, ["mcp__muse__watch"])
        let back = try JSONDecoder().decode(ClaudeFileSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.shellScope, .folders)
    }

    func testRevokeAndAskBeforeAnything() {
        var s = ClaudeFileSettings()
        s.allowShell(); s.allowTool("mcp__muse__watch"); s.allowFolder(project)
        let cmd = bash("ffmpeg -i \(project)/a.mp4 /tmp/a.mp4")
        XCTAssertEqual(verdict(cmd, s), .allow)
        // "Ask before anything" pauses every kind (kept on the list).
        s.askEverything = true
        for a in [cmd, ask("mcp__muse__watch", [:]), ask("Read", ["file_path": .string("\(project)/a.mp4")]), ask("Read", ["file_path": .string("/tmp/a.mp4")])] {
            guard case .ask(let c) = verdict(a, s) else { return XCTFail("ran while paused: \(a.toolName)") }
            XCTAssertNil(c.alwaysLabel)
        }
        XCTAssertEqual(s.shellScope, .folders)
        s.askEverything = false
        // Remove in Settings: asks again, and offers Always again.
        s.removeShell()
        guard case .ask(let c) = verdict(cmd, s) else { return XCTFail("ran after Remove") }
        XCTAssertEqual(c.alwaysLabel, "Allow always: shell commands")
        s.removeTool("mcp__muse__watch")
        guard case .ask = verdict(ask("mcp__muse__watch", [:]), s) else { return XCTFail("tool ran after Remove") }
        // Temp files were covered by the shell kind; with it gone they ask too.
        guard case .ask = verdict(ask("Read", ["file_path": .string("/tmp/a.mp4")]), s) else { return XCTFail("temp ran after Remove") }
        s.removeFolder(project)
        guard case .ask = verdict(ask("Upload", ["file_path": .string("\(project)/a.mp4")]), s) else { return XCTFail("upload ran after Remove") }
    }
}
