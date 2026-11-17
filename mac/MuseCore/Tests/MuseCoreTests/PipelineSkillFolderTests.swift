import XCTest
@testable import MuseCore

/// The Edit pipeline skill written as a Claude Code project skill in MUSE's own turn folder (never ~/.claude).
final class PipelineSkillFolderTests: XCTestCase {
    func testOnlySkillAndReferencePagesAreWritten() throws {
        XCTAssertTrue(PipelineSkillFolder.safe("SKILL.md"))
        XCTAssertTrue(PipelineSkillFolder.safe("reference/whip-pan.md"))
        for bad in ["../SKILL.md", "/etc/passwd", "reference/../../x.md", "reference/Up.md", "reference/a/b.md", "reference/.md", "notes.md"] {
            XCTAssertFalse(PipelineSkillFolder.safe(bad), bad)
        }
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let v1 = PipelineSkillFiles(version: 1, files: [PipelineSkillFile(path: "SKILL.md", text: "---\nname: muse-edit-pipeline\n---\ncore"),
                                                         PipelineSkillFile(path: "reference/old.md", text: "old"),
                                                         PipelineSkillFile(path: "../escape.md", text: "no")])
        let folder = try PipelineSkillFolder.write(v1, into: cwd)
        XCTAssertEqual(folder.path, cwd.appendingPathComponent(".claude/skills/muse-edit-pipeline").path)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "---\nname: muse-edit-pipeline\n---\ncore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent(".claude/skills/escape.md").path))
        // The next version replaces the folder: a retired page goes away.
        try PipelineSkillFolder.write(PipelineSkillFiles(version: 2, files: [PipelineSkillFile(path: "SKILL.md", text: "v2"), PipelineSkillFile(path: "reference/new.md", text: "n")]), into: cwd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference/old.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference/new.md").path))
        // Without a SKILL.md nothing is touched.
        try PipelineSkillFolder.write(PipelineSkillFiles(version: 3, files: [PipelineSkillFile(path: "reference/x.md", text: "x")]), into: cwd)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), "v2")
    }
}
