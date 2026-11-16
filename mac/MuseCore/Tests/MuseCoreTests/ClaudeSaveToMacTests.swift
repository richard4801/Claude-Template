import Foundation
import XCTest
@testable import MuseCore

/// save_to_mac (ci_741e03646382, ci_c62906bcd1c1): the Mac saves a studio file only into its save folders or an
/// always-allowed folder, asks first unless that folder is always allowed, and never touches key folders.
final class ClaudeSaveToMacTests: XCTestCase {
    let home = "/Users/me"
    let cwd = "/Users/me/MUSE/Claude/ct_1"

    func save(_ folder: String? = nil, name: String = "mia-living-room-dance-takev1-1.mp4", url: String = "/uploads/s/v1.mp4", bytes: Double? = 48 * 1024 * 1024) -> ClaudePermissionAsk {
        var input: [String: JSONValue] = ["fileName": .string(name), "url": .string(url), "what": .string("the video take_v1 (Mia · Living-room dance)")]
        if let folder { input["folder"] = .string(folder) }
        if let bytes { input["bytes"] = .number(bytes) }
        return ClaudePermissionAsk(id: "perm_save", toolName: "Save", input: .object(input))
    }
    func verdict(_ a: ClaudePermissionAsk, folders: [String] = [], askAll: Bool = false, mode: ClaudeFileMode = .ask) -> ClaudeFileVerdict {
        ClaudeFilePolicy.verdict(a, mode: mode, folders: folders, cwd: cwd, home: home, askAll: askAll)
    }

    func testDefaultFolderAsksWithTheFileAndFolder() {
        guard case .ask(let c) = verdict(save()) else { return XCTFail("\(verdict(save()))") }
        XCTAssertEqual(c.action, "Save mia-living-room-dance-takev1-1.mp4 to ~/Downloads/MUSE")
        XCTAssertEqual(c.detail, "the video take_v1 (Mia · Living-room dance) · original quality · 48 MB")
        XCTAssertEqual(c.folder, "/Users/me/Downloads/MUSE")
        XCTAssertEqual(c.alwaysLabel, "Allow always")
        XCTAssertEqual(ClaudeFilePolicy.saveTarget(save(), cwd: cwd, home: home)?.folder, "/Users/me/Downloads/MUSE")
    }

    func testAnAlwaysAllowedFolderSavesWithoutACard() {
        XCTAssertEqual(verdict(save(), folders: ["/Users/me/Downloads/MUSE"]), .allow)
        XCTAssertEqual(verdict(save("~/Projects/grwm/raw"), folders: ["/Users/me/Projects/grwm"]), .allow)
        // "Ask before anything" still asks.
        if case .ask(let c) = verdict(save(), folders: [], askAll: true) { XCTAssertNil(c.alwaysLabel) } else { XCTFail() }
    }

    /// Build 676: ~/MUSE is inside "Folders + temp", so with shell commands always allowed a save there needs no card; the
    /// save card elsewhere offers Allow always for its folder.
    func testMUSEFolderSavesUnderTheShellGrantAndOtherCardsOfferTheirFolder() {
        let a = save("~/MUSE/Gamified GRWM/exports")
        XCTAssertEqual(ClaudeFilePolicy.verdict(a, mode: .ask, folders: [], cwd: cwd, home: home, shell: .folders), .allow)
        guard case .ask(let c) = verdict(a) else { return XCTFail("saved without the shell grant") }
        XCTAssertEqual(c.alwaysLabel, "Allow always")
        XCTAssertEqual(c.folder, "/Users/me/MUSE/Gamified GRWM/exports")
        guard case .ask(let d) = ClaudeFilePolicy.verdict(save("~/Movies/Shoot"), mode: .ask, folders: [], cwd: cwd, home: home, shell: .folders) else { return XCTFail() }
        XCTAssertEqual(d.folder, "/Users/me/Movies/Shoot")
        if case .ask = ClaudeFilePolicy.verdict(a, mode: .ask, folders: [], cwd: cwd, home: home, askAll: true, shell: .folders) {} else { XCTFail("ran while paused") }
    }

    func testOnlyTheSaveFoldersOrAllowedFolders() {
        for f in ["~/Desktop", "~/Documents/edits", "~/Movies/MUSE", "~/Pictures", "~/Music/stems", "~/MUSE/exports"] {
            if case .ask = verdict(save(f)) {} else { XCTFail(f) }
        }
        for f in ["~/Library/Caches", "~", "/etc", "/Applications/x", "~/Projects/other"] {
            XCTAssertEqual(verdict(save(f)), .deny(ClaudeFilePolicy.saveFolderRefusal), f)
        }
        XCTAssertEqual(verdict(save("~/.ssh")), .deny(ClaudeFilePolicy.credentialRefusal))
        XCTAssertEqual(verdict(save(name: "id_rsa")), .deny(ClaudeFilePolicy.credentialRefusal))
        XCTAssertEqual(verdict(save(), mode: .off), .deny(ClaudeFilePolicy.offRefusal))
    }

    func testOnlyMuseLinksAndSafeNames() {
        XCTAssertTrue(ClaudeFilePolicy.saveLinkOK("/uploads/s/v1.mp4"))
        XCTAssertTrue(ClaudeFilePolicy.saveLinkOK("https://muse.example/uploads/s/v1.mp4"))
        XCTAssertFalse(ClaudeFilePolicy.saveLinkOK("//evil.example/x"))
        XCTAssertFalse(ClaudeFilePolicy.saveLinkOK("file:///etc/passwd"))
        XCTAssertFalse(ClaudeFilePolicy.saveLinkOK("/uploads/../x"))
        XCTAssertEqual(verdict(save(url: "file:///etc/passwd")), .deny(ClaudeFilePolicy.saveLinkRefusal))
        // A name with a path in it stays inside the folder.
        XCTAssertEqual(ClaudeFilePolicy.saveTarget(save(name: "../../evil.mp4"), cwd: cwd, home: home)?.fileName, "evil.mp4")
    }

    func testTheMacSaysItCanSaveAndSendsWhereItSaved() throws {
        XCTAssertTrue(HTTPClaudeAPI.capabilities.split(separator: ",").contains("save"))
        let d = try JSONEncoder().encode(ClaudeLocalSave(path: "/Users/me/Downloads/MUSE/a (2).mp4", bytes: 10, name: "a (2).mp4"))
        let back = try JSONDecoder().decode(ClaudeLocalSave.self, from: d)
        XCTAssertEqual(back.path, "/Users/me/Downloads/MUSE/a (2).mp4")
    }
}
