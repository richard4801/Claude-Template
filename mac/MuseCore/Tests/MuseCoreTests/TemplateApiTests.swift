import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Contract tests for photo templates against a LOCAL real API (`server/api`, plans/api.md "Photo templates"): the starter
/// pack, private/public, hidden layers for non-owners (checked on the raw JSON too), the locked prompt line, template shoots,
/// Save as template, template_hidden, owner_only, duplicate, favourites and delete. Skipped unless MUSE_API_URL is set, and
/// skipped when that server has no templates yet. They create accounts and move tokens, so never point them at a hosted server.
///
///   cd server/api && PORT=8798 PUBLIC_URL=http://127.0.0.1:8798 node --import tsx scripts/test-server.ts &
///   cd mac/MuseCore && MUSE_API_URL=http://127.0.0.1:8798 swift test --filter TemplateApiTests
final class TemplateApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("TemplateApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func client() -> HTTPMuseAPI { HTTPMuseAPI(baseURL: base) }

    private func expect(_ code: String, _ line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(code)", line: line)
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code, e.message, line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }

    /// The raw JSON body of a GET, to check the server itself never sends hidden layers.
    private func raw(_ path: String, token: String) async throws -> String {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: r) { d, _, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d ?? Data()) }
            }.resume()
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testTemplatesEndToEnd() async throws {
        let boss = client()
        let ownerAuth = try await boss.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await boss.setToken(ownerAuth.token)
        let starters: [MuseTemplate]
        do {
            starters = try await boss.listTemplates(TemplateQuery(scope: .mine))
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("this server has no /v1/templates yet")
        }

        // The starter pack: seven public templates owned by the studio owner, with their layers and pools.
        let slugs = Set(starters.compactMap(\.starter))
        XCTAssertTrue(slugs.isSuperset(of: ["motion-blur-face", "mirror-selfie", "harsh-sun-close-up", "moody-low-light", "reflection", "product-moment", "candid-pov"]), "\(slugs)")
        for s in starters where s.starter != nil {
            XCTAssertTrue(s.isOwner)
            XCTAssertTrue(s.isPublic, s.name)
            XCTAssertNotNil(s.layers, s.name)
            XCTAssertFalse(s.variationPool?.isEmpty ?? true, s.name)
        }
        XCTAssertTrue(starters.first { $0.starter == "product-moment" }?.acceptsProduct ?? false)

        // A member with some credit.
        let email = "tpl+\(UUID().uuidString.prefix(8).lowercased())@test.muse"
        let invite = try await boss.createInvite(InviteRequest(email: email))
        let member = client()
        let auth = try await member.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code,
                                                         attestAdultRightsOriginal: true, attestLabelAi: true))
        await member.setToken(auth.token)
        _ = try await boss.sendTokens(TokenMove(userId: auth.user.id, tokens: 100, note: "Mac template test"))

        // The owner makes a private template from scratch; the member can't see it.
        let secret = TemplateLayers(style: "zz-secret-style", scene: "zz-secret-scene", camera: "zz-secret-camera", light: "zz-secret-light",
                                    negative: "zz-secret-neg", afterEffects: TemplateAfterEffects(grade: "moody-blue", grain: 0.2))
        let created = try await boss.createTemplate(CreateTemplateRequest(name: "Mac test look", tags: ["MacTest"], layers: secret,
                                                                         variationPool: VariationPool(pose: ["zz-secret-pose"], framing: ["zz-secret-frame"])))
        XCTAssertEqual(created.visibility, "private", "private by default")
        XCTAssertTrue(created.isOwner)
        XCTAssertEqual(created.layers?.scene, "zz-secret-scene")
        XCTAssertEqual(created.layers?.afterEffects?.grade, "moody-blue")
        XCTAssertEqual(created.variationPool?[.pose], ["zz-secret-pose"])
        let memberAll0 = try await member.listTemplates(TemplateQuery())
        XCTAssertFalse(memberAll0.contains { $0.id == created.id })
        await expect("not_found") { _ = try await member.template(id: created.id) }

        // Public: the member sees it, but never its layers or pool (not even in the raw JSON).
        let pub = try await boss.updateTemplate(id: created.id, TemplatePatch(visibility: "public"))
        XCTAssertTrue(pub.isPublic)
        let seen = try await member.listTemplates(TemplateQuery(scope: .public, q: "mac test"))
        let mt = try XCTUnwrap(seen.first { $0.id == created.id })
        XCTAssertFalse(mt.isOwner)
        XCTAssertNil(mt.layers)
        let tagged = try await member.listTemplates(TemplateQuery(tag: "mactest"))
        XCTAssertEqual(tagged.map(\.id), [created.id])
        let rawList = try await raw("v1/templates", token: auth.token)
        let rawOne = try await raw("v1/templates/\(created.id)", token: auth.token)
        for body in [rawList, rawOne] { XCTAssertFalse(body.contains("zz-secret"), "hidden layers reached a non-owner") }

        // The member's prompt view shows the template as one locked line.
        let models = try await member.listModels()
        let sienna = try XCTUnwrap(models.first { $0.name == "Sienna Vale" })
        let view = try await member.templatePrompt(id: created.id, TemplatePromptRequest(modelId: sienna.id, outfitId: sienna.outfitIds.first,
                                                                                         direction: "sitting on the steps", shuffleSeed: 42))
        XCTAssertTrue(view.isLocked)
        XCTAssertEqual(view.slots.filter(\.locked).map(\.text), ["Template: Mac test look"])
        XCTAssertFalse(view.text.contains("zz-secret"), view.text)
        XCTAssertTrue(view.text.contains("sitting on the steps"))
        XCTAssertNil(view.variation)
        XCTAssertEqual(view.shuffleSeed, 42)
        // The owner sees every layer and the draws; the same shuffleSeed gives the same prompt.
        let ownerView = try await boss.templatePrompt(id: created.id, TemplatePromptRequest(modelId: sienna.id, outfitId: sienna.outfitIds.first, shuffleSeed: 42))
        XCTAssertTrue(ownerView.text.contains("zz-secret-scene"), ownerView.text)
        XCTAssertEqual(ownerView.variation?[.pose], "zz-secret-pose")
        let again = try await boss.templatePrompt(id: created.id, TemplatePromptRequest(modelId: sienna.id, outfitId: sienna.outfitIds.first, shuffleSeed: 42))
        XCTAssertEqual(again.variation, ownerView.variation)

        // A member shoots with it: $0.12 from their wallet, template fields on each still, the public prompt only.
        let w0 = try await member.wallet()
        let shots = try await member.shoot(.template(created.id, modelId: sienna.id, outfitId: sienna.outfitIds.first ?? "", direction: "looking back",
                                                     shuffleSeed: 7))
        XCTAssertFalse(shots.isEmpty)
        for s in shots {
            XCTAssertEqual(s.kind, "shot")
            XCTAssertEqual(s.templateId, created.id)
            XCTAssertEqual(s.templateName, "Mac test look")
            XCTAssertFalse(s.prompt.contains("zz-secret"), s.prompt)
            XCTAssertNil(s.variation)
        }
        let w1 = try await member.wallet()
        XCTAssertEqual(w1.usd, w0.usd - Pricing.shootCost, accuracy: 0.011)
        let rawTakes = try await raw("v1/takes", token: auth.token)
        XCTAssertFalse(rawTakes.contains("zz-secret"), "hidden layers reached a non-owner through takes")
        let detail = try await boss.template(id: created.id)
        XCTAssertEqual(detail.uses, 1)
        XCTAssertFalse(detail.recent?.isEmpty ?? true)

        // Rules: the member can't save the look as their own, can't change it, can favourite it.
        await expect("template_hidden") { _ = try await member.templateDraft(fromShotId: shots[0].id) }
        await expect("template_hidden") { _ = try await member.createTemplate(CreateTemplateRequest(name: "Copy", fromShotId: shots[0].id)) }
        await expect("owner_only") { _ = try await member.updateTemplate(id: created.id, TemplatePatch(name: "Mine now")) }
        await expect("owner_only") { _ = try await member.duplicateTemplate(id: created.id) }
        let fav = try await member.setTemplateFavourite(id: created.id, true)
        XCTAssertTrue(fav.favourite)
        let favs = try await member.listTemplates(TemplateQuery(scope: .favourites))
        XCTAssertTrue(favs.contains { $0.id == created.id })
        let unfav = try await member.setTemplateFavourite(id: created.id, false)
        XCTAssertFalse(unfav.favourite)

        // Save as template from a plain photoshoot: the draft shows the layers, then the template is saved from the shot.
        let plain = try await member.shoot(ShootRequest(modelId: sienna.id, outfitId: sienna.outfitIds.first ?? "", scene: "Café window",
                                                        prompt: "Sienna Vale\nScene: café window.\nCamera: medium shot, 35mm lens, f/2.8.", count: 1))
        let draft = try await member.templateDraft(fromShotId: plain[0].id)
        XCTAssertEqual(draft.fromShotId, plain[0].id)
        XCTAssertFalse(draft.variationPool.isEmpty, "the pool is auto-suggested")
        var form = TemplateForm.from(draft: draft)
        form.name = "Member café"
        let mine = try await member.createTemplate(form.createRequest)
        XCTAssertTrue(mine.isOwner)
        XCTAssertEqual(mine.visibility, "private")
        XCTAssertEqual(mine.createdFromShotId, plain[0].id)
        XCTAssertNotNil(mine.cover)
        XCTAssertNotNil(mine.layers)
        let bossSees = try await boss.listTemplates(TemplateQuery())
        XCTAssertFalse(bossSees.contains { $0.id == mine.id }, "a member's private template is theirs alone")

        // Duplicate (a private copy) and delete, owner only.
        let copy = try await boss.duplicateTemplate(id: created.id)
        XCTAssertEqual(copy.name, "Mac test look copy")
        XCTAssertEqual(copy.visibility, "private")
        XCTAssertEqual(copy.layers?.scene, "zz-secret-scene")
        await expect("owner_only") { try await member.deleteTemplate(id: created.id) }
        try await boss.deleteTemplate(id: copy.id)
        try await boss.deleteTemplate(id: created.id)
        try await member.deleteTemplate(id: mine.id)
        let after = try await member.listTemplates(TemplateQuery())
        XCTAssertFalse(after.contains { $0.id == created.id })
    }
}
