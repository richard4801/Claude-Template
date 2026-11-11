import XCTest
@testable import MuseCore

/// Owner bug 2026-11-11: typing in Claude chat inside Edit triggered editor shortcuts. While typing, no key acts.
final class EditShortcutsTests: XCTestCase {
    typealias S = EditShortcuts

    func testShortcutsWorkWhenNotTyping() {
        XCTAssertEqual(S.action(for: .space, typing: false, timeline: true), .togglePlay)
        XCTAssertEqual(S.action(for: .left, typing: false, timeline: true), .step(-1))
        XCTAssertEqual(S.action(for: .right, typing: false, timeline: true), .step(1))
        XCTAssertEqual(S.action(for: .delete, typing: false, timeline: true), .deleteSelected)
        XCTAssertEqual(S.action(for: .deleteForward, typing: false, timeline: true), .deleteSelected)
        XCTAssertEqual(S.action(for: .character("S"), typing: false, timeline: true), .split)
        XCTAssertEqual(S.action(for: .character("j"), typing: false, timeline: true), .shuttle(-1))
        XCTAssertEqual(S.action(for: .character("k"), typing: false, timeline: true), .shuttle(0))
        XCTAssertEqual(S.action(for: .character("L"), typing: false, timeline: true), .shuttle(1))
        XCTAssertEqual(S.action(for: .undo, typing: false, timeline: true), .undo)
        XCTAssertEqual(S.action(for: .redo, typing: false, timeline: true), .redo)
    }

    func testNothingFiresWhileTyping() {
        let keys: [S.Key] = [.space, .left, .right, .delete, .deleteForward, .undo, .redo]
            + "sSjJkKlLa ".map { .character(String($0)) }
        for k in keys {
            XCTAssertNil(S.action(for: k, typing: true, timeline: true), "\(k) fired while typing")
            XCTAssertNil(S.action(for: k, typing: true, timeline: false), "\(k) fired while typing")
        }
    }

    func testDeleteOnlyInTimelineAndLettersOnlyBare() {
        XCTAssertNil(S.action(for: .delete, typing: false, timeline: false))
        XCTAssertNil(S.action(for: .character("s"), typing: false, timeline: true, plainModifiers: false))
        XCTAssertNil(S.action(for: .character("x"), typing: false, timeline: true))
    }
}
