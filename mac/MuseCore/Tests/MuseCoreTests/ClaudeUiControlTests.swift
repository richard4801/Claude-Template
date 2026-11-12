import XCTest
@testable import MuseCore

/// Claude operating the MUSE window: the control list, finding a control again, the refusal list, action mapping, calls.
final class ClaudeUiControlTests: XCTestCase {
    private var tree: UiElement {
        UiElement(role: .group, children: [
            UiElement(identifier: "suite.composer", role: .group, children: [
                UiElement(role: .textArea, label: "Prompt", value: "a beach at dusk"),
                UiElement(role: .button, label: "Shuffle", enabled: false),
                UiElement(role: .button, label: "Add to queue"),
                UiElement(role: .button, label: "Add to queue"),
                UiElement(role: .slider, label: "Length", value: "5"),
                UiElement(role: .toggle, label: "Audio", value: "1"),
                UiElement(role: .group, children: [UiElement(role: .text)]), // unlabelled: not listed
            ]),
            UiElement(identifier: "settings.providers.apiKey", role: .secureField, label: "Replicate key", value: "r8_secret"),
            UiElement(role: .button, label: "Sign out"),
            UiElement(role: .text, label: "Library"),
            UiElement(identifier: "claude.chat.composer", role: .group, children: [UiElement(role: .button, label: "Send")]),
        ])
    }

    func testFlattenGivesStableIdsAndMarksProtected() {
        let f = UiTree.flatten(tree)
        XCTAssertEqual(f.controls.map(\.id), [
            "suite.composer", "suite.composer/textArea:prompt", "suite.composer/button:shuffle",
            "suite.composer/button:add-to-queue", "suite.composer/button:add-to-queue#2",
            "suite.composer/slider:length", "suite.composer/toggle:audio",
            "settings.providers.apiKey", "button:sign-out", "text:library",
            "claude.chat.composer", "claude.chat.composer/button:send",
        ])
        XCTAssertEqual(f.controls.last?.protected, true) // Claude never sends in its own chat box
        XCTAssertEqual(f.paths["suite.composer/button:add-to-queue#2"], [0, 3])
        let key = f.controls.first { $0.id == "settings.providers.apiKey" }!
        XCTAssertEqual(key.protected, true)
        XCTAssertNil(key.value) // a password field's text never goes to Claude
        XCTAssertEqual(f.controls.first { $0.id == "button:sign-out" }?.protected, true)
        XCTAssertNil(f.controls.first { $0.label == "Shuffle" }?.protected)
        XCTAssertEqual(UiTree.element(tree, at: f.paths["suite.composer/slider:length"]!)?.label, "Length")
        XCTAssertFalse(f.truncated)
    }

    func testWithinAndLimit() {
        let inside = UiTree.flatten(tree, within: "suite.composer")
        XCTAssertTrue(inside.controls.allSatisfy { $0.id.hasPrefix("suite.composer") })
        XCTAssertEqual(inside.controls.count, 7)
        let few = UiTree.flatten(tree, limit: 3)
        XCTAssertEqual(few.controls.count, 3)
        XCTAssertTrue(few.truncated)
    }

    func testResolve() throws {
        let c = UiTree.flatten(tree).controls
        XCTAssertEqual(try UiTree.resolve("suite.composer/slider:length", in: c).label, "Length")
        XCTAssertEqual(try UiTree.resolve("shuffle", in: c).id, "suite.composer/button:shuffle")
        XCTAssertEqual(try UiTree.resolve("Prompt", in: c).role, .textArea)
        XCTAssertThrowsError(try UiTree.resolve("Add to queue", in: c)) { e in
            XCTAssertEqual((e as? UiError)?.code, .notFound)
            XCTAssertTrue((e as? UiError)?.message.contains("add-to-queue#2") ?? false)
        }
        XCTAssertThrowsError(try UiTree.resolve("Export", in: c))
        XCTAssertTrue(UiTree.met(.appears, target: "Shuffle", controls: c).met)
        XCTAssertFalse(UiTree.met(.enabled, target: "Shuffle", controls: c).met)
        XCTAssertTrue(UiTree.met(.disappears, target: "Export", controls: c).met)
    }

    func testRefusalListMatchesTheServer() {
        for t in ["API key", "settings.engines.token", "Log out", "Buy credits", "Payment", "Discard", "edit.clip.delete", "Show provider names", "Delete account", "Markup", "Generate", "Generate · $0.40", "Run queue", "Approve", "Allow once", "Post now", "Upscale", "Spend 12 credits"] {
            XCTAssertNotNil(UiRefusal.reason(text: t), t)
        }
        for t in ["library.search", "Remove from collection", "Export", "suite.prompt", "Deliver", "Add to queue", "Posts", "Deny", "Shuffle"] {
            XCTAssertNil(UiRefusal.reason(text: t), t)
        }
        XCTAssertNotNil(UiRefusal.menuReason(["MUSE", "Quit MUSE"]))
        XCTAssertNotNil(UiRefusal.menuReason(["File", "Close Window"]))
        XCTAssertNil(UiRefusal.menuReason(["File", "Export…"]))
    }

    func testActionMapping() throws {
        let c = UiTree.flatten(tree).controls
        func ctl(_ id: String) -> UiControl { c.first { $0.id == id }! }
        XCTAssertEqual(try UiActionPlan.plan(.setText, value: "rain", target: nil, control: ctl("suite.composer/textArea:prompt")), .setText("rain"))
        XCTAssertEqual(try UiActionPlan.plan(.setValue, value: "7,5", target: nil, control: ctl("suite.composer/slider:length")), .setValue(7.5))
        XCTAssertEqual(try UiActionPlan.plan(.toggle, value: "off", target: nil, control: ctl("suite.composer/toggle:audio")), .toggle(false))
        XCTAssertEqual(try UiActionPlan.plan(.toggle, value: nil, target: nil, control: ctl("suite.composer/toggle:audio")), .toggle(nil))
        XCTAssertEqual(try UiActionPlan.plan(.press, value: nil, target: nil, control: ctl("suite.composer/button:add-to-queue")), .press)
        XCTAssertEqual(try UiActionPlan.plan(.scroll, value: nil, target: nil, control: ctl("suite.composer")), .scroll(.down))
        XCTAssertEqual(try UiActionPlan.plan(.menu, value: nil, target: "File > Export…", control: nil), .menu(["File", "Export…"]))
        XCTAssertEqual(try UiActionPlan.plan(.key, value: "Cmd+Z", target: nil, control: nil), .key(UiKey.table["cmd+z"]!))
        XCTAssertEqual(UiActionPlan.isOn(ctl("suite.composer/toggle:audio")), true)

        func fails(_ a: UiAction, _ v: String?, _ id: String?, _ target: String? = nil, code: UiErrorCode = .failed) {
            XCTAssertThrowsError(try UiActionPlan.plan(a, value: v, target: target, control: id.map(ctl))) { XCTAssertEqual(($0 as? UiError)?.code, code, "\(a) \(id ?? "")") }
        }
        fails(.press, nil, "suite.composer/button:shuffle") // greyed out
        fails(.press, nil, "suite.composer/textArea:prompt") // use set_text
        fails(.setText, "x", "suite.composer/slider:length")
        fails(.setValue, "loud", "suite.composer/slider:length")
        fails(.toggle, "maybe", "suite.composer/toggle:audio")
        fails(.setText, "x", "settings.providers.apiKey", code: .protected)
        fails(.press, nil, "button:sign-out", code: .protected)
        fails(.menu, nil, nil, "MUSE > Quit MUSE", code: .protected)
        fails(.menu, nil, nil, "Export")
        fails(.key, "cmd+q", nil)
        XCTAssertThrowsError(try UiActionPlan.plan(.press, value: nil, target: nil, control: UiControl(id: "p", role: .picker, label: "Model"))) {
            XCTAssertTrue(($0 as? UiError)?.message.contains("use select") ?? false)
        }
    }

    func testCallsEventsAndAnswers() throws {
        let ev = ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"uiCall","call":{"id":"ui_1","kind":"act","args":{"action":"set_text","target":"library.search","value":"beach"},"createdAt":1,"expiresAt":2}}"#.utf8))
        guard case .uiCall(let call)? = ev else { return XCTFail("no uiCall") }
        XCTAssertEqual(try UiRequest.parse(call), .act(action: .setText, target: "library.search", value: "beach"))
        XCTAssertEqual(ClaudeLiveEventFilter.parse(Data(#"{"type":"claude","op":"uiCallEnd","id":"ui_1"}"#.utf8)), .uiCallEnd(id: "ui_1"))
        XCTAssertEqual(try UiRequest.parse(UiCall(id: "u", kind: "snapshot", args: .object(["screenshot": .bool(true)]))), .snapshot(screenshot: true, within: nil))
        XCTAssertEqual(try UiRequest.parse(UiCall(id: "u", kind: "wait", args: .object(["for": .string("idle"), "timeout": .number(99)]))), .wait(for: .idle, target: nil, timeout: 30))
        XCTAssertThrowsError(try UiRequest.parse(UiCall(id: "u", kind: "drag")))

        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        XCTAssertEqual(String(data: try enc.encode(UiAnswer(error: .stopped)), encoding: .utf8)!.prefix(30), #"{"code":"stopped","error":"The"#)
        XCTAssertEqual(String(data: try enc.encode(UiAnswer(result: .object(["done": .bool(true)]))), encoding: .utf8), #"{"result":{"done":true}}"#)
        XCTAssertTrue(UiShot.size(width: 2560, height: 1600) == (1280, 800))
        XCTAssertTrue(UiShot.size(width: 800, height: 600) == (800, 600))

        var s = ClaudeFileSettings()
        XCTAssertTrue(s.uiOn)
        s.uiControl = false
        XCTAssertFalse(try JSONDecoder().decode(ClaudeFileSettings.self, from: enc.encode(s)).uiOn)
        XCTAssertTrue(try JSONDecoder().decode(ClaudeFileSettings.self, from: Data(#"{"mode":"ask","folders":[]}"#.utf8)).uiOn)
    }
}
