import XCTest
@testable import MuseCore

/// Contract tests for shoot references, the server-built photoshoot prompt and the prompt library against a LOCAL real API
/// (`server/api`, plans/api.md "Shoot references and the prompt library"). Skipped unless MUSE_API_URL is set, and skipped
/// on a server from before them. Simulated engines only; never point them at a hosted server.
///
///   cd server/api && PORT=8798 PUBLIC_URL=http://127.0.0.1:8798 node --import tsx scripts/test-server.ts &
///   cd mac/MuseCore && MUSE_API_URL=http://127.0.0.1:8798 swift test --filter ShootPromptApiTests
final class ShootPromptApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("ShootPromptApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func expect(_ code: String, _ line: UInt = #line, _ work: () async throws -> Void) async -> ApiError? {
        do {
            try await work()
            XCTFail("expected \(code)", line: line)
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code, e.message, line: line)
            return e
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
        return nil
    }

    func testReferencesPreviewAndPromptLibrary() async throws {
        let boss = HTTPMuseAPI(baseURL: base)
        let auth = try await boss.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await boss.setToken(auth.token)
        try await boss.ensureStudioFunds()
        let lib: PromptLibrary
        do {
            lib = try await boss.prompts()
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("this server has no prompt library yet")
        }
        XCTAssertEqual(lib.sections.first?.group.id, "photoshoot")
        let refsPose = try XCTUnwrap(lib.entry("refs.pose"))
        XCTAssertTrue(refsPose.placeholders.contains { $0.name == "refIndex" && $0.required })
        XCTAssertEqual(lib.entry("style.realism")?.defaultText, PromptEngine.realism)
        XCTAssertEqual(lib.entry("style.camera")?.defaultText, PromptEngine.cameraFeel)

        let all = try await boss.listModels()
        let m = try XCTUnwrap(all.first { !$0.outfitIds.isEmpty })
        let outfit = m.outfitIds[0]
        var s = ShootSettings()
        s.direction = "laughing mid-step"
        let plain = try await boss.shootPreview(.built(modelId: m.id, outfitId: outfit, settings: s, presets: true, refs: []))
        XCTAssertFalse(plain.edited)
        XCTAssertTrue(plain.slots.contains { $0.layer == "direction" })
        XCTAssertFalse(plain.slots.contains { $0.layer == "reference" })
        XCTAssertEqual(plain.text, plain.slots.map(\.text).joined(separator: "\n"))
        XCTAssertTrue(plain.estimateLabel.hasPrefix("about $"))

        // Two references: one line each, after the direction, numbered after her own references; more images cost more.
        let refs = [ShootRef(image: .asset("g_front"), guides: [.pose]), ShootRef(image: .asset("hero"), guides: [.look, .scene])]
        let req = ShootRequest.built(modelId: m.id, outfitId: outfit, settings: s, presets: true, refs: refs)
        let p = try await boss.shootPreview(req)
        let lines = p.slots.filter { $0.layer == "reference" }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(p.refs.count, 2)
        let firstIndex = try XCTUnwrap(p.refs.first?.index)
        XCTAssertEqual(lines.first?.text, PromptEngine.referenceSlot([.pose], index: firstIndex).text)
        XCTAssertEqual(p.slots.firstIndex { $0.layer == "reference" }, (p.slots.firstIndex { $0.layer == "direction" } ?? -1) + 1)
        XCTAssertGreaterThanOrEqual(p.estimate, plain.estimate)
        // Presets off keeps the reference lines.
        let off = try await boss.shootPreview(.built(modelId: m.id, outfitId: outfit, settings: s, presets: false, refs: refs))
        XCTAssertEqual(Set(off.slots.map(\.layer)), ["identity", "outfit", "direction", "reference", "seed"])
        // Edit as text: the text exactly.
        let edited = try await boss.shootPreview(.built(modelId: m.id, outfitId: outfit, settings: s, presets: true, refs: refs, prompt: "My own prompt"))
        XCTAssertTrue(edited.edited)
        XCTAssertEqual(edited.text, "My own prompt")
        // More than 3 references, or a reference without a guide.
        var bad = req
        bad.refs = refs + refs
        _ = await expect("bad_request") { _ = try await boss.shootPreview(bad) }
        bad.refs = [ShootRef(image: .asset("hero"), guides: [])]
        _ = await expect("bad_request") { _ = try await boss.shootPreview(bad) }

        // A shoot sends the choices; the stills carry their refs and the previewed prompt.
        let shots = try await boss.shoot(req)
        XCTAssertFalse(shots.isEmpty)
        XCTAssertEqual(shots.first?.prompt, p.text)
        // Take.refs (contract) when the server sends it.
        if let got = shots.first?.refs { XCTAssertEqual(got.map(\.guides), refs.map(\.guides)) }

        // The library: placeholder errors, save, the preview picks it up, reset.
        let e1 = await expect("prompt_invalid") { _ = try await boss.setPrompt(key: "refs.pose", text: "Copy the pose.") }
        XCTAssertTrue(e1?.message.contains("{refIndex}") ?? false, e1?.message ?? "")
        _ = await expect("prompt_invalid") { _ = try await boss.previewPrompt(PromptPreviewRequest(key: "refs.pose", text: "Pose from {image}")) }
        _ = await expect("not_found") { _ = try await boss.setPrompt(key: "no.such.key", text: "x") }
        let pv = try await boss.previewPrompt(PromptPreviewRequest(key: "refs.pose", text: "Match the pose in image {refIndex}."))
        XCTAssertFalse(pv.text.contains("{refIndex}"))
        XCTAssertFalse(pv.example.isEmpty)
        let saved = try await boss.setPrompt(key: "refs.pose", text: "Match the pose in image {refIndex}.")
        XCTAssertTrue(saved.overridden)
        let p2 = try await boss.shootPreview(req)
        XCTAssertTrue(p2.slots.first { $0.layer == "reference" }?.text.hasPrefix("Match the pose in image \(firstIndex).") ?? false,
                      p2.slots.first { $0.layer == "reference" }?.text ?? "")
        let back = try await boss.resetPrompt(key: "refs.pose")
        XCTAssertFalse(back.overridden)
        XCTAssertEqual(back.current, refsPose.defaultText)

        // Members: the same references and preview, but never the library.
        let email = "refs+\(UUID().uuidString.prefix(8).lowercased())@test.muse"
        let invite = try await boss.createInvite(InviteRequest(email: email))
        let member = HTTPMuseAPI(baseURL: base)
        let mAuth = try await member.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code,
                                                          attestAdultRightsOriginal: true, attestLabelAi: true))
        await member.setToken(mAuth.token)
        let mp = try await member.shootPreview(req)
        XCTAssertEqual(mp.slots.filter { $0.layer == "reference" }.count, 2)
        _ = await expect("owner_only") { _ = try await member.prompts() }
        _ = await expect("owner_only") { _ = try await member.setPrompt(key: "refs.pose", text: "x {refIndex}") }
        _ = await expect("owner_only") { _ = try await member.previewPrompt(PromptPreviewRequest(key: "refs.pose")) }
    }
}
