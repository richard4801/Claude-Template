import XCTest
@testable import MuseCore

/// Contract test for prompt scripts (plans/api.md "Prompt scripts") against a LOCAL server/api: the list and one script
/// decode, a rule switched off is saved exactly as the Mac encodes it, the preview runs the saved rules, a locked rule is
/// refused with `script_invalid`, and DELETE goes back to the defaults. Skipped unless MUSE_API_URL points at a local server.
final class PromptScriptsApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("PromptScriptsApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func owner() async throws -> HTTPMuseAPI {
        let api = HTTPMuseAPI(baseURL: base)
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        return api
    }

    func testListSaveResetAndPreview() async throws {
        let api = try await owner()
        let list: PromptScriptsList
        do {
            list = try await api.promptScripts()
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("this server has no prompt scripts yet")
        }
        XCTAssertEqual(list.ops.map(\.id), CondOpInfo.defaults.map(\.id))
        let video = try XCTUnwrap(list.script("video.replicate"))
        XCTAssertEqual(video.inputs.first?.name, "speaking")
        defer { Task { _ = try? await api.resetPromptScript(id: "video.replicate") } }
        _ = try await api.resetPromptScript(id: "video.replicate")

        var rules = try await api.promptScript(id: "video.replicate").rules
        let i = try XCTUnwrap(rules.firstIndex { $0.id == "summary.silent" })
        rules[i].isOn = false
        let saved = try await api.savePromptScript(id: "video.replicate", rules: rules)
        XCTAssertTrue(saved.overridden)
        XCTAssertEqual(saved.rules.first { $0.id == "summary.silent" }?.isOn, false)
        XCTAssertEqual(saved.updatedBy, "jen@studio.com")

        let p = try await api.previewPromptScript(ScriptPreviewRequest(id: "video.replicate", inputs: ["speaking": .bool(false)]))
        XCTAssertFalse(p.fired.contains("summary.silent"))
        XCTAssertTrue(p.fired.contains("summary"))
        XCTAssertEqual(p.inputs["speaking"], .bool(false))
        XCTAssertFalse(p.text.isEmpty)

        var bad = saved.rules
        let s = try XCTUnwrap(bad.firstIndex { $0.id == "subjects" })
        bad[s].enabled = false
        do {
            _ = try await api.savePromptScript(id: "video.replicate", rules: bad)
            XCTFail("expected script_invalid")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "script_invalid")
            XCTAssertTrue(e.message.contains("locked"), e.message)
        }

        let reset = try await api.resetPromptScript(id: "video.replicate")
        XCTAssertFalse(reset.overridden)
        XCTAssertEqual(reset.rules, reset.defaultRules)
    }
}
