import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AI suite (workstream 1): the composer's first run over HTTP against the real API (`server/api`, mock suite mode, no
/// money): the catalog with its new fields, the requests the composer builds (UGC ad, Talking, @locations, the owner's
/// engine pin) as the strict server accepts them, the locations library, and a member's view. Skipped unless
/// MUSE_API_URL points at a LOCAL dev server.
final class SuiteComposerApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("SuiteComposerApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func client() -> HTTPMuseAPI { HTTPMuseAPI(baseURL: base) }

    private func owner() async throws -> (HTTPMuseAPI, SuiteCatalog) {
        let api = client()
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        try await api.ensureStudioFunds()
        do {
            let c = try await api.suiteCatalog()
            if !c.enabled { throw XCTSkip("SUITE_MODE is off on this server") }
            return (api, c)
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("This server has no /v1/suite")
        }
    }

    private func member(_ boss: HTTPMuseAPI) async throws -> HTTPMuseAPI {
        let email = "composer+\(UUID().uuidString.prefix(8).lowercased())@test.muse"
        let invite = try await boss.createInvite(InviteRequest(email: email))
        let api = client()
        let auth = try await api.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code,
                                                      attestAdultRightsOriginal: true, attestLabelAi: true))
        await api.setToken(auth.token)
        return api
    }

    private func character(_ api: HTTPMuseAPI) async throws -> MuseModel {
        let list = try await api.listModels()
        return try XCTUnwrap(list.first { $0.slots.contains { $0.image != nil } }, "no character with a sheet")
    }

    /// A small real PNG (8×8, mid grey).
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAD0lEQVR4nGNowAEYhpYEAILzYAGc7g8kAAAAAElFTkSuQmCC")!

    private func upload(_ api: HTTPMuseAPI, _ name: String) async throws -> ImageRef {
        try await api.uploadImage(name: name, data: Self.png, mime: "image/png")
    }

    private func encoded(_ r: ShotRequest) throws -> String { String(data: try JSONEncoder().encode(r), encoding: .utf8) ?? "" }

    func testTheCatalogDecodesTheComposerFields() async throws {
        let (_, c) = try await owner()
        XCTAssertEqual(c.camera.ugcFormats.map(\.id), ["unboxing", "review", "try_on", "before_after", "grwm", "haul", "tutorial", "testimonial"])
        XCTAssertFalse(c.camera.focals.isEmpty)
        XCTAssertFalse(c.camera.eras.isEmpty)
        if !c.tools.isEmpty {
            XCTAssertEqual(c.tools.map(\.id), ["shot", "swap", "recast", "storyboard", "talking", "ugc_ad", "extend", "photo"])
            let extend = try XCTUnwrap(c.tools.first { $0.id == "extend" })
            XCTAssertEqual(ComposerTool.extend.isComingSoon(in: c), !extend.available, "Extend follows catalog.tools")
            XCTAssertTrue(extend.available, "mock mode can extend")
            XCTAssertFalse(ComposerTool.shot.isComingSoon(in: c))
        }
        // The bundled demo copy matches the server's lists.
        XCTAssertEqual(SuiteDemoCatalog.catalog.camera.ugcFormats.map(\.id), c.camera.ugcFormats.map(\.id))
        XCTAssertEqual(SuiteDemoCatalog.catalog.camera.bodies.map(\.id), c.camera.bodies.map(\.id))
    }

    func testComposerRequestsTheServerAccepts() async throws {
        let (boss, c) = try await owner()
        let ch = try await character(boss)
        let who = PromptTokens.text(" opens the parcel").addMention(kind: "character", id: ch.id, label: ch.shortName, at: Caret(0, 0)).0
        let draftInputs = c.tier("draft")?.slots ?? .none

        // UGC ad: the product reference and the format.
        let product = try await upload(boss, "product.png")
        let slots = InputSlots().put(SlotId(.image), SlotValue(name: "product.png", image: product))
        let ugc = ComposerDraft(tool: .ugc, tokens: who, settings: ComposerSettings(genre: "ugc", tempo: "steady", format: "unboxing"), duration: 6)
        let ur = ugc.request(slots, draftInputs)
        XCTAssertFalse(try encoded(ur).contains("null"), "no explicit nulls")
        XCTAssertEqual(ur.camera?.style?.format, "unboxing")
        let ue = try await boss.suiteEstimate(ur)
        XCTAssertTrue(ue.ok, ue.message ?? "")
        XCTAssertGreaterThan(ue.estimate, 0)

        // Talking (no audio yet: she speaks the prompt's lines), with a location image.
        let talk = ComposerDraft(tool: .talking, tokens: who, settings: ComposerSettings(lighting: c.camera.lighting.first?.id), duration: 6)
        let tr = talk.request(slots, draftInputs)
        XCTAssertEqual(tr.speaking, true)
        XCTAssertEqual(tr.references?.images?.first?.role, "location")
        _ = try await boss.suiteEstimate(tr)

        // Every chip set at once still passes the strict camera schema.
        let cam = c.camera
        let all = ComposerSettings(body: ComposerCatalog.visible(cam.bodies).first?.id, lens: ComposerCatalog.visible(cam.lenses).first?.id,
                                   focalMm: ComposerCatalog.focalSteps(cam).first, aperture: ComposerCatalog.visible(cam.apertures).first?.id,
                                   height: cam.heights.first?.id, shotSize: cam.shotSizes.first?.id, genre: cam.genres.first?.id,
                                   era: ComposerEras.era(at: 3, cam), tempo: cam.tempos.first?.id, palette: cam.palettes.first?.id,
                                   stock: cam.looks.first?.id, gradeLook: false, lighting: cam.lighting.first?.id)
        var tokens = who
        if let m = cam.moves.first(where: { $0.id == "dolly_in" }) { tokens = tokens.addMove(m, catalog: cam).0 }
        let full = ComposerDraft(tokens: tokens, settings: all, duration: 6).request(InputSlots(), draftInputs)
        XCTAssertFalse(try encoded(full).contains("null"))
        _ = try await boss.suiteEstimate(full)

        // The owner's engine pin: the estimate runs on that engine.
        if let tier = c.tier("draft"), let pin = ComposerEngines.options(tier).first {
            let pinned = ComposerEngines.pin(ComposerDraft(tokens: who, duration: 6), pin)
            let pe = try await boss.suiteEstimate(pinned.request(InputSlots(), pinned.inputs(c)))
            XCTAssertEqual(pe.engine?.model, pin.model)
        }
    }

    func testLocationsLibraryAndLocationReferences() async throws {
        let (boss, c) = try await owner()
        let image = try await upload(boss, "rooftop.png")
        let made: SuiteLocation
        do {
            made = try await boss.createSuiteLocation(NewSuiteLocation(name: "Rooftop test \(UUID().uuidString.prefix(4))", image: image))
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("This server has no locations yet")
        }
        XCTAssertTrue(made.name.hasPrefix("Rooftop test"))
        XCTAssertNotNil(made.image.url)
        let list = try await boss.suiteLocations()
        XCTAssertTrue(list.contains { $0.id == made.id })

        // A location token goes out as a location reference.
        let ch = try await character(boss)
        var t = PromptTokens.text("She waits on the ").addMention(kind: "character", id: ch.id, label: ch.shortName, at: Caret(0, 0)).0
        let inputs = c.tier("draft")?.slots ?? .none
        let (withPlace, note) = ComposerLocations.add(made, to: t, slots: InputSlots(), inputs: inputs)
        XCTAssertNil(note)
        t = withPlace
        let r = ComposerDraft(tokens: t, duration: 6).request(InputSlots(), inputs, locations: list)
        XCTAssertEqual(r.references?.images?.map(\.role), ["location"])
        XCTAssertTrue(r.prompt.contains(made.name))
        _ = try await boss.suiteEstimate(r)

        // A member sees the studio's places; deleting someone else's is refused.
        let m = try await member(boss)
        let theirs = try await m.suiteLocations()
        XCTAssertTrue(theirs.contains { $0.id == made.id })
        do {
            try await m.deleteSuiteLocation(id: made.id)
            XCTFail("a member can't delete the owner's location")
        } catch let e as ApiError { XCTAssertTrue(["forbidden", "owner_only", "not_found"].contains(e.code), e.code) }

        try await boss.deleteSuiteLocation(id: made.id)
        let after = try await boss.suiteLocations()
        XCTAssertFalse(after.contains { $0.id == made.id })
    }

    func testAMembersComposer() async throws {
        let (boss, _) = try await owner()
        let ch = try await character(boss)
        let m = try await member(boss)
        let c = try await m.suiteCatalog()
        XCTAssertTrue(c.tiers.allSatisfy { $0.models == nil })
        XCTAssertTrue(ComposerEngines.options(c.tier("draft")).isEmpty, "members get no engines to pin")
        // 4c: members get the engines to pick (catalog.engines, member-safe: no `members` rules, no costs or keys).
        XCTAssertFalse((c.engines ?? []).isEmpty, "4c: members see the models they may pick")
        let d = ComposerDraft(tokens: PromptTokens.text(" waves").addMention(kind: "character", id: ch.id, label: ch.shortName, at: Caret(0, 0)).0, duration: 6)
        let e = try await m.suiteEstimate(d.request(InputSlots(), d.inputs(c)))
        XCTAssertNil(e.engine)
        XCTAssertTrue(SuiteText.isMemberSafe(e.label + e.buttonLabel + e.priceLine))
        // 4c (owner, 2026-11-11): model choice is for everyone, so a member's chosen model is no longer refused as owner-only.
        do {
            var pinned = d.request(InputSlots(), d.inputs(c))
            pinned.engineModel = "h3"
            _ = try await m.suiteEstimate(pinned)
        } catch let e as ApiError { XCTAssertNotEqual(e.code, "owner_only", "members may pick a model (4c)") }
    }

    // MARK: Extend and Upscale

    func testAnExtendEstimateOnAnUploadedVideo() async throws {
        let (boss, c) = try await owner()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("extend-\(UUID().uuidString.prefix(6)).mp4")
        try Data(repeating: 0x2A, count: 4096).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = try await boss.uploadSuiteMedia(file, contentType: "video/mp4", progress: nil)
        let src = try XCTUnwrap(ExtendSource.upload(ref, seconds: 4, name: "upload"), "the upload has a stored key: \(ref)")
        var d = ComposerDraft(tool: .extend, quality: "draft", duration: 5).extending(src)
        d.extend.prompt = "She turns away."
        let r = try XCTUnwrap(d.extendRequest())
        XCTAssertFalse(try encoded(r).contains("null"), "no explicit nulls")
        let e = try await boss.suiteEstimate(r)
        XCTAssertEqual(e.mode, "extend")
        XCTAssertTrue(e.label.hasPrefix("Extend · Draft · "), e.label)
        XCTAssertEqual(e.seconds, 5)
        XCTAssertTrue(e.ok, e.message ?? "")
        XCTAssertTrue(GeneratePrice.of(e).canGenerate)

        // Before, on each quality: an estimate, or the server's own nothing_fits.
        d.extend.direction = .before
        for q in c.tiers.filter(\.available).map(\.id) {
            d.quality = q
            d.duration = ComposerBar.clampLength(5, c.tier(q))
            do {
                let eb = try await boss.suiteEstimate(try XCTUnwrap(d.extendRequest()))
                XCTAssertTrue(eb.label.hasPrefix("Extend · "), eb.label)
            } catch let e as ApiError { XCTAssertEqual(e.code, "nothing_fits", e.message) }
        }

        // A member's estimate names no engine; a video that isn't the studio's is refused.
        let m = try await member(boss)
        let me = try await m.suiteEstimate(try XCTUnwrap(ComposerDraft(tool: .extend, quality: "draft", duration: 5).extending(src).extendRequest()))
        XCTAssertNil(me.engine)
        XCTAssertTrue(SuiteText.isMemberSafe(me.label + me.buttonLabel + me.priceLine))
        do {
            _ = try await boss.suiteEstimate(.extendShot(SuiteVideoRef(key: "c/not_here.mp4", seconds: 4), duration: 5, quality: "draft"))
            XCTFail("not in this studio")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
    }

    func testUpscaleIsRefusedWithA409OnAFreshServer() async throws {
        let (boss, _) = try await owner()
        // No UPSCALE_PRICES on the test server: every size is greyed and the add-on is coming soon.
        let settings = try await boss.studioSettings()
        let f = try XCTUnwrap(settings.features.video)
        XCTAssertFalse(UpscaleOffer.isLive(f))
        XCTAssertEqual(f.upscale?.sizes.map(\.id), ["1080p", "2k", "4k"])
        XCTAssertTrue(f.upscale?.sizes.allSatisfy { !$0.available && $0.price == nil } ?? false)
        XCTAssertEqual(UpscaleOffer.choices(f, seconds: 8).map(\.priceText), ["Soon", "Soon", "Soon"])
        let takes = try await boss.listTakes()
        let take = try XCTUnwrap(takes.first { $0.kind == "take" }, "the dev seed has render takes")
        do {
            _ = try await boss.upscale(takeId: take.id, UpscaleRequest(size: "2k"))
            XCTFail("Upscale isn't priced here")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "upscale_unavailable")
            XCTAssertNotNil(UpscaleOffer.refusal(e))
        }
    }
}
