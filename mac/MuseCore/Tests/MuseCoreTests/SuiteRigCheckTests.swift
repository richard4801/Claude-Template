import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AI suite · the rig check (workstream 3, plans/video-composer.md "Rig check"): decoding `rig` on the estimate and the
/// rig-check reply, every merge-patch shape applied to the composer's choices like a picker tap, dismissals, and demo
/// mode's port of the server rules (each fix, applied, clears its rule).
final class SuiteRigCheckTests: XCTestCase {
    private let cat = SuiteDemoCatalog.catalog.camera

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    private func json(_ s: String) throws -> JSONValue { try decode(JSONValue.self, s) }
    private func ids(_ w: [RigWarning]) -> [String] { w.map(\.id) }

    /// A composer draft with these chips and #moves (first = move, second = mix).
    private func draft(_ s: ComposerSettings = ComposerSettings(), moves: [String] = [], prompt: String = "She turns to the window.",
                       speaking: ComposerSpeaking = .auto) -> ComposerDraft {
        let t = PromptTokens.text(prompt).settingMoves(moves.map { SuiteMove(id: $0, intensity: 0.4) }, catalog: cat)
        return ComposerDraft(tokens: t, settings: s, speaking: speaking)
    }

    private func request(_ d: ComposerDraft) -> ShotRequest { d.request(InputSlots(), .none) }
    private func check(_ d: ComposerDraft) -> [RigWarning] {
        let r = request(d)
        return FakeRigCheck.check(prompt: r.prompt, camera: r.camera, speaking: r.speaking ?? false)
    }
    private func moveIds(_ d: ComposerDraft) -> [String] { d.tokens.moves.compactMap { $0.move?.id } }

    // MARK: Decoding

    func testEstimateDecodesRigAndDefaultsToEmpty() throws {
        let e = try decode(ShotEstimate.self, """
        {"quality":"hd","label":"Shot · HD · 2K","ok":true,"rig":[
          {"id":"deep_focus","severity":"warn","reason":"DV camcorder keeps everything in focus, so the rack focus won’t show",
           "fix":{"label":"Use Cinema camera","patch":{"camera":{"rig":{"body":"cinema_digital"}}}},
           "alt":{"label":"Drop the rack focus","patch":{"camera":{"mix":null}}}},
          {"id":"look_clash","severity":"tip","reason":"Tungsten cinema stock and Golden warmth pull the colour opposite ways",
           "fix":{"label":"Keep Tungsten cinema stock","patch":{"camera":{"palette":{"preset":"naturalistic"}}}}},
          {"id":"broken","severity":"warn"},
          {"id":"future_rule","severity":"note","reason":"Something new","fix":{"label":"Do it","patch":{"camera":{"angle":{"height":"low"}}}}}
        ]}
        """)
        XCTAssertTrue(e.ok)
        XCTAssertEqual(ids(e.rig), ["deep_focus", "look_clash", "future_rule"], "an entry it can't read is skipped, the rest stay")
        XCTAssertFalse(e.rig[0].isTip)
        XCTAssertTrue(e.rig[1].isTip)
        XCTAssertFalse(e.rig[2].isTip, "an unknown severity reads as a warning")
        XCTAssertEqual(e.rig[0].fix.patch, try json(#"{"camera":{"rig":{"body":"cinema_digital"}}}"#))
        XCTAssertEqual(e.rig[0].alt?.patch, try json(#"{"camera":{"mix":null}}"#), "null survives decoding (it means remove)")
        XCTAssertNil(e.rig[1].alt)

        XCTAssertEqual(try decode(ShotEstimate.self, #"{"quality":"draft","ok":true}"#).rig, [])
        XCTAssertEqual(try decode(ShotEstimate.self, #"{"quality":"draft","rig":"nope"}"#).rig, [])
        XCTAssertEqual(ids(try decode(RigCheckResult.self, #"{"rig":[{"id":"wide_close","severity":"warn","reason":"A 18mm lens this close stretches the face","fix":{"label":"Use 85mm","patch":{"camera":{"rig":{"focalMm":85}}}}}]}"#).rig), ["wide_close"])
        XCTAssertEqual(try decode(RigCheckResult.self, "{}").rig, [])

        // Round trip (the app caches estimates as values).
        let back = try JSONDecoder().decode(ShotEstimate.self, from: try JSONEncoder().encode(e))
        XCTAssertEqual(back.rig, e.rig)
    }

    // MARK: Merge patch

    func testMergePatchFollowsRFC7386() throws {
        let target = try json(#"{"a":"b","c":{"d":"e","f":"g"},"k":[1,2]}"#)
        XCTAssertEqual(target.mergePatched(try json(#"{"a":"z","c":{"f":null},"k":[3]}"#)), try json(#"{"a":"z","c":{"d":"e"},"k":[3]}"#))
        XCTAssertEqual(JSONValue.null.mergePatched(try json(#"{"x":{"y":1}}"#)), try json(#"{"x":{"y":1}}"#))
        XCTAssertEqual(target.mergePatched(.string("all")), .string("all"))
        XCTAssertEqual(try json(#"{"a":1}"#).mergePatched(try json(#"{"b":null}"#)), try json(#"{"a":1}"#))
    }

    // MARK: Every patch shape, like a picker tap

    func testRigPatchesSetTheChips() throws {
        var d = draft(ComposerSettings(body: "camcorder", focalMm: 14, aperture: "f1.4", stock: "bw_film"))
        d = RigFixes.apply(try json(#"{"camera":{"rig":{"body":"cinema_digital"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.body, "cinema_digital")
        XCTAssertEqual(d.settings.aperture, "f1.4", "objects merge: the rest of the rig stays")
        d = RigFixes.apply(try json(#"{"camera":{"rig":{"aperture":"f11"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.aperture, "f11")
        d = RigFixes.apply(try json(#"{"camera":{"rig":{"focalMm":85}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.focalMm, 85)
        d = RigFixes.apply(try json(#"{"camera":{"rig":{"look":"digital_clean"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.stock, "digital_clean", "rig.look is the Look picker's film stock")
        d = RigFixes.apply(try json(#"{"camera":{"rig":{"aperture":null}}}"#), to: d, catalog: cat)
        XCTAssertNil(d.settings.aperture, "null is Auto")
        XCTAssertEqual(d.settings.body, "cinema_digital")
        XCTAssertEqual(request(d).camera?.rig, CameraRig(body: "cinema_digital", focalMm: 85, look: "digital_clean"))
    }

    func testAnglePaletteAndOtherPatches() throws {
        var d = draft(ComposerSettings(height: "worm", shotSize: "cu", palette: "hyper_neon", lighting: "natural"))
        d = RigFixes.apply(try json(#"{"camera":{"angle":{"height":"low"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.height, "low")
        XCTAssertEqual(d.settings.shotSize, "cu")
        d = RigFixes.apply(try json(#"{"camera":{"angle":{"shotSize":"ms"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.shotSize, "ms")
        d = RigFixes.apply(try json(#"{"camera":{"palette":{"preset":"naturalistic"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(d.settings.palette, "naturalistic")
        XCTAssertEqual(d.settings.lighting, "natural", "untouched keys stay")
        d = RigFixes.apply(try json(#"{"camera":{"lighting":null,"style":{"tempo":"calm"}},"speaking":false,"aspectRatio":"16:9"}"#), to: d, catalog: cat)
        XCTAssertNil(d.settings.lighting)
        XCTAssertEqual(d.settings.tempo, "calm")
        XCTAssertEqual(d.speaking, .off)
        XCTAssertEqual(d.aspect, "16:9")
        XCTAssertEqual(RigFixes.apply(try json(#"{"speaking":null}"#), to: d, catalog: cat).speaking, .auto)
        XCTAssertEqual(RigFixes.apply(.string("nonsense"), to: d, catalog: cat), d, "a patch that isn't an object changes nothing")
        XCTAssertEqual(RigFixes.apply(try json(#"{"camera":{"rig":{"body":7}},"unknown":1}"#), to: d, catalog: cat), d, "wrong types and unknown keys are ignored")
    }

    func testMovePatchReplacesTheMoveChipInPlace() throws {
        let d = draft(moves: ["orbit_left"], prompt: "She turns.")
        let key = d.tokens.moves.first?.key
        let fixed = RigFixes.apply(try json(#"{"camera":{"move":{"id":"static"}}}"#), to: d, catalog: cat)
        XCTAssertEqual(moveIds(fixed), ["static"])
        XCTAssertEqual(fixed.tokens.moves.first?.key, key, "the chip keeps its place and key")
        XCTAssertEqual(fixed.tokens.moves.first?.move?.intensity, 0.4, "objects merge: the intensity stays")
        XCTAssertEqual(fixed.tokens.display(), "She turns.#Static")
        XCTAssertEqual(fixed.tokens.promptText(), "She turns.")

        // No move yet: the patch adds a chip at the end, like the Movement picker.
        let added = RigFixes.apply(try json(#"{"camera":{"move":{"id":"dolly_out","intensity":0.7}}}"#), to: draft(), catalog: cat)
        XCTAssertEqual(moveIds(added), ["dolly_out"])
        XCTAssertEqual(added.tokens.moves.first?.move?.intensity, 0.7)
        XCTAssertEqual(request(added).camera?.move?.id, "dolly_out")

        // The move changes, the mix stays.
        let two = draft(moves: ["dolly_in", "rack_focus"])
        XCTAssertEqual(moveIds(RigFixes.apply(try json(#"{"camera":{"move":{"id":"handheld"}}}"#), to: two, catalog: cat)), ["handheld", "rack_focus"])
    }

    func testMixNullRemovesTheSecondChipAndPromotionKeepsTheOrder() throws {
        let two = draft(moves: ["handheld", "dolly_in"], prompt: "She talks to camera.")
        let dropped = RigFixes.apply(try json(#"{"camera":{"mix":null}}"#), to: two, catalog: cat)
        XCTAssertEqual(moveIds(dropped), ["handheld"])
        XCTAssertNil(request(dropped).camera?.mix)
        XCTAssertEqual(dropped.tokens.promptText(), "She talks to camera.", "the text around the chip joins up")

        // "Drop the rack focus" when the rack is the move: the mix becomes the move.
        let rackFirst = draft(moves: ["rack_focus", "dolly_in"])
        let promoted = RigFixes.apply(try json(#"{"camera":{"move":{"id":"dolly_in","intensity":0.4},"mix":null}}"#), to: rackFirst, catalog: cat)
        XCTAssertEqual(moveIds(promoted), ["dolly_in"])
        XCTAssertEqual(request(promoted).camera?.move?.id, "dolly_in")

        // Removing a mix that isn't there, or a move: nothing breaks.
        XCTAssertEqual(moveIds(RigFixes.apply(try json(#"{"camera":{"mix":null}}"#), to: draft(moves: ["static"]), catalog: cat)), ["static"])
        XCTAssertEqual(moveIds(RigFixes.apply(try json(#"{"camera":{"move":null,"mix":null}}"#), to: two, catalog: cat)), [])

        // A patch that swaps which is first follows the patch's order.
        let swapped = RigFixes.apply(try json(#"{"camera":{"move":{"id":"dolly_in"},"mix":{"id":"handheld"}}}"#), to: two, catalog: cat)
        XCTAssertEqual(moveIds(swapped), ["dolly_in", "handheld"])
    }

    func testDirectedCameraTakesThePatch() throws {
        var d = draft(ComposerSettings(body: "phone"), moves: ["static"])
        d.directed = CameraSpec(mode: "directed", rig: CameraRig(body: "camcorder", aperture: "f1.4"), move: SuiteMove(id: "rack_focus"), mix: SuiteMove(id: "dolly_in"))
        let fixed = RigFixes.apply(try json(#"{"camera":{"rig":{"body":"cinema_digital"},"mix":null}}"#), to: d, catalog: cat)
        XCTAssertEqual(fixed.directed?.rig?.body, "cinema_digital")
        XCTAssertEqual(fixed.directed?.rig?.aperture, "f1.4")
        XCTAssertNil(fixed.directed?.mix)
        XCTAssertEqual(fixed.directed?.mode, "directed")
        XCTAssertEqual(fixed.settings.body, "phone", "the chips aren't what's sent while Directed is on")
        XCTAssertEqual(moveIds(fixed), ["static"])
    }

    // MARK: Dismissing

    func testDismissedWarningStaysHiddenUntilTheChoicesChange() throws {
        let d = draft(ComposerSettings(body: "phone", focalMm: 14, aperture: "f1.4", shotSize: "cu"))
        let w = check(d)
        XCTAssertEqual(ids(w), ["deep_focus", "wide_close"])
        let choices = RigChoices(request(d))
        var dm = RigDismissals()
        dm.sync(choices)
        XCTAssertEqual(dm.visible(w, at: choices), w)
        dm.dismiss(w[0], at: choices)
        XCTAssertEqual(ids(dm.visible(w, at: choices)), ["wide_close"])

        // Typing in the prompt isn't a change of choices.
        var typed = d
        typed.tokens = PromptTokens.text("She turns and smiles.")
        XCTAssertEqual(RigChoices(request(typed)), choices)
        XCTAssertEqual(ids(dm.visible(check(typed), at: RigChoices(request(typed)))), ["wide_close"])

        // A changed choice brings it back (and the store's sync forgets the dismissal).
        var changed = d
        changed.settings.lighting = "golden_hour"
        let now = RigChoices(request(changed))
        XCTAssertEqual(ids(dm.visible(check(changed), at: now)), ["deep_focus", "wide_close"])
        dm.sync(now)
        XCTAssertTrue(dm.hidden.isEmpty)
        dm.sync(choices)
        XCTAssertEqual(ids(dm.visible(w, at: choices)), ["deep_focus", "wide_close"], "going back doesn't bring the dismissal back")

        // Same choices, but the warning now says something else: it shows again.
        var dm2 = RigDismissals()
        let other = RigWarning(id: "deep_focus", reason: "Phone keeps everything in focus, so the rack focus won’t show", fix: w[0].fix)
        dm2.dismiss(w[0], at: choices)
        XCTAssertEqual(dm2.visible([other], at: choices), [other])
        XCTAssertEqual(dm2.visible([w[0]], at: RigChoices(speaking: true)), [w[0]])
    }

    // MARK: The fake's rules (port of server/api/src/suite/rigcheck.ts)

    func testDeepFocusWideCloseAndWormClose() {
        let rack = FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(body: "camcorder"), move: SuiteMove(id: "rack_focus")), speaking: false)
        XCTAssertEqual(rack.first?.reason, "DV camcorder keeps everything in focus, so the rack focus won’t show")
        XCTAssertEqual(rack.first?.fix.label, "Use Cinema camera")
        XCTAssertEqual(rack.first?.alt?.label, "Drop the rack focus")
        let shallow = FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(body: "phone", aperture: "f1.4")), speaking: false)
        XCTAssertEqual(shallow.first?.reason, "Phone keeps everything in focus, so f/1.4 won’t blur the background")
        XCTAssertEqual(shallow.first?.alt?.label, "Use f/11")
        XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(body: "webcam"), move: SuiteMove(id: "handheld"), mix: SuiteMove(id: "rack_focus")),
                                          speaking: false).first?.alt?.patch, .object(["camera": .object(["mix": .null])]))
        XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(body: "cinema_digital", aperture: "f1.4"), move: SuiteMove(id: "rack_focus")),
                                          speaking: false), [])
        XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(focalMm: 18), angle: CameraAngle(shotSize: "cu")), speaking: false).first?.reason,
                       "A 18mm lens this close stretches the face")
        XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(lens: "fisheye", focalMm: 14), angle: CameraAngle(shotSize: "cu")), speaking: false), [])
        XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(angle: CameraAngle(height: "worm", shotSize: "mcu")), speaking: false).first?.reason,
                       "Worm’s-eye from the ground can’t frame a medium close-up")
    }

    func testLooksPromptRevealAndTalk() {
        let c = { (s: CameraSpec, p: String?, speaking: Bool) in FakeRigCheck.check(prompt: p, camera: s, speaking: speaking) }
        XCTAssertEqual(c(CameraSpec(rig: CameraRig(look: "bw_film"), palette: CameraPalette(preset: "hyper_neon")), nil, false).first?.reason,
                       "Black & white film is black and white, so Hyper neon won’t show")
        XCTAssertEqual(c(CameraSpec(rig: CameraRig(look: "tungsten_stock"), palette: CameraPalette(preset: "golden_warmth")), nil, false).first?.severity, "tip")
        XCTAssertEqual(c(CameraSpec(rig: CameraRig(look: "bw_film"), palette: CameraPalette(preset: "classic_bw")), nil, false), [])

        let pm = c(CameraSpec(move: SuiteMove(id: "orbit_right")), "The camera pushes in on her face as she turns.", false)
        XCTAssertEqual(pm.first?.reason, "The prompt says “pushes in” but the move is Orbit right")
        XCTAssertEqual(pm.first?.fix.label, "Use Dolly in")
        XCTAssertEqual(c(CameraSpec(move: SuiteMove(id: "static")), "No zoom, no pan left, she just smiles.", false), [], "negations don't count")
        XCTAssertEqual(c(CameraSpec(move: SuiteMove(id: "static")), "#Dolly in She smiles.", false), [], "the composer's own #tokens don't count")
        XCTAssertEqual(c(CameraSpec(angle: CameraAngle(height: "high")), "Low angle, looking up at her on the stairs.", false).first?.reason,
                       "The prompt says “low angle” but the angle is High angle")
        XCTAssertEqual(c(CameraSpec(angle: CameraAngle(shotSize: "ls")), "A tight close-up of her hands.", false).first?.severity, "tip")

        let reveal = c(CameraSpec(move: SuiteMove(id: "crane_up")), "Open on the street and pull back to reveal the city.", false)
        XCTAssertEqual(ids(reveal), ["no_reveal"], "one 'use this move' line, not two")
        XCTAssertEqual(reveal.first?.reason, "The prompt opens on something else, but Crane up starts at the subject")
        XCTAssertEqual(c(CameraSpec(move: SuiteMove(id: "static")), "Reveal the empty room.", false).first?.fix.label, "Use Dolly out reveal")

        let talk = c(CameraSpec(move: SuiteMove(id: "orbit_left")), nil, true)
        XCTAssertEqual(talk.first?.reason, "Orbit left can fight lip sync on a speaking shot")
        XCTAssertEqual(talk.first?.fix.label, "Lock it off")
        XCTAssertEqual(talk.first?.alt?.label, "Handheld UGC")
        let mixed = c(CameraSpec(move: SuiteMove(id: "handheld"), mix: SuiteMove(id: "dolly_in")), nil, true)
        XCTAssertEqual(mixed.first?.fix, RigFix(label: "Drop Dolly in", patch: .object(["camera": .object(["mix": .null])])))
        XCTAssertNil(mixed.first?.alt)
        XCTAssertEqual(c(CameraSpec(move: SuiteMove(id: "orbit_left")), nil, false), [])
    }

    func testPresetsUnderneathMergedIdsAndCleanRigs() {
        XCTAssertEqual(ids(FakeRigCheck.check(prompt: nil, camera: CameraSpec(preset: "phone_ugc", rig: CameraRig(aperture: "f1.4")), speaking: false)), ["deep_focus"])
        XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(rig: CameraRig(body: "creator_cine", aperture: "f1.4")), speaking: false), [])
        for p in cat.presets { XCTAssertEqual(FakeRigCheck.check(prompt: nil, camera: CameraSpec(preset: p.id), speaking: false), [], p.id) }
        XCTAssertEqual(FakeRigCheck.check(prompt: "She smiles.", camera: nil, speaking: true), [])
    }

    /// Each rule's fix (and alt), applied to the composer like a tap, clears that rule; every line is short and member-safe.
    func testEveryFixAppliedToTheComposerClearsItsRule() {
        let cases: [(String, ComposerDraft)] = [
            ("deep_focus", draft(ComposerSettings(body: "camcorder"), moves: ["rack_focus"])),
            ("deep_focus", draft(ComposerSettings(body: "webcam"), moves: ["handheld", "rack_focus"])),
            ("deep_focus", draft(ComposerSettings(body: "webcam"), moves: ["rack_focus", "dolly_in"])),
            ("deep_focus", draft(ComposerSettings(body: "phone", aperture: "f2.8"))),
            ("wide_close", draft(ComposerSettings(focalMm: 14, shotSize: "ecu"))),
            ("worm_close", draft(ComposerSettings(height: "worm", shotSize: "cu"))),
            ("look_clash", draft(ComposerSettings(palette: "hyper_neon", stock: "bw_film"))),
            ("look_clash", draft(ComposerSettings(palette: "golden_warmth", stock: "tungsten_stock"))),
            ("prompt_move", draft(moves: ["orbit_right"], prompt: "The camera pushes in on her face.")),
            ("prompt_angle", draft(ComposerSettings(height: "high"), prompt: "Low angle, looking up at her.")),
            ("prompt_size", draft(ComposerSettings(shotSize: "ls"), prompt: "A tight close-up of her hands.")),
            ("no_reveal", draft(moves: ["crane_up"], prompt: "Open on the traffic, then find her.")),
            ("no_reveal", draft(moves: ["static"], prompt: "Reveal the empty room.")),
            ("talk_move", draft(moves: ["orbit_left"], speaking: .on)),
            ("talk_move", draft(moves: ["handheld", "dolly_in"], speaking: .on)),
        ]
        for (id, d) in cases {
            guard let w = check(d).first(where: { $0.id == id }) else { XCTFail("\(id) didn't fire for \(d.tokens.display())"); continue }
            XCTAssertLessThanOrEqual(w.reason.count, 90, w.reason)
            XCTAssertTrue(SuiteText.isMemberSafe(w.reason + w.fix.label + (w.alt?.label ?? "")), w.reason)
            for fix in [w.fix, w.alt].compactMap({ $0 }) {
                let after = d.applying(fix, catalog: cat)
                XCTAssertFalse(ids(check(after)).contains(id), "\(id) still fires after “\(fix.label)”")
            }
        }
    }

    // MARK: Demo mode's API

    func testFakeEstimateAndRigCheckCarryTheWarnings() async throws {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        let req = ShotRequest(modelId: SampleData.demo, prompt: "Open on the traffic, then find her.", duration: 6, quality: "hd", speaking: true,
                              camera: CameraSpec(rig: CameraRig(body: "phone", aperture: "f1.4"), move: SuiteMove(id: "crane_up")))
        let e = try await a.suiteEstimate(req)
        XCTAssertTrue(e.ok, "the rig check never blocks Generate")
        XCTAssertEqual(ids(e.rig), ["deep_focus", "no_reveal", "talk_move"])
        XCTAssertEqual(e.rig.first?.fix.patch, .object(["camera": .object(["rig": .object(["body": .string("cinema_digital")])])]))
        let alone = try await a.suiteRigCheck(req)
        XCTAssertEqual(alone, e.rig)

        // Without planning: no character, and a length no tier makes (the estimate fails) still gets its warnings.
        var bad = ShotRequest(prompt: "Pan left.", duration: 99, camera: CameraSpec(rig: CameraRig(focalMm: 18), move: SuiteMove(id: "static"), angle: CameraAngle(shotSize: "cu")))
        do {
            _ = try await a.suiteEstimate(bad)
            XCTFail("nothing fits")
        } catch let err as ApiError { XCTAssertEqual(err.code, "nothing_fits") }
        let rig = try await a.suiteRigCheck(bad)
        XCTAssertEqual(ids(rig), ["wide_close", "prompt_move"])
        bad.mode = "recast"
        let none = try await a.suiteRigCheck(bad)
        XCTAssertEqual(none, [])
        let clean = try await a.suiteEstimate(ShotRequest(modelId: SampleData.demo, prompt: "She waves.", duration: 6, camera: CameraSpec(preset: "phone_ugc")))
        XCTAssertEqual(clean.rig, [])
    }
}

/// The rig check over HTTP against the real API (mock suite mode, no money): the estimate and the rig-check route agree
/// with demo mode's port. Skipped unless MUSE_API_URL points at a LOCAL dev server.
final class SuiteRigCheckApiTests: XCTestCase {
    func testRigCheckRouteMatchesTheDemoPort() async throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let base = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = base.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else { throw XCTSkip("local servers only (got \(host))") }
        let api = HTTPMuseAPI(baseURL: base)
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        let rig: [RigWarning]
        do {
            rig = try await api.suiteRigCheck(ShotRequest(prompt: "Pan left.", camera: CameraSpec(rig: CameraRig(focalMm: 18), move: SuiteMove(id: "static"),
                                                                                                    angle: CameraAngle(shotSize: "cu"))))
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" || e.code == "engine_unavailable" {
            throw XCTSkip("This server has no rig check")
        }
        XCTAssertEqual(rig.map(\.id), ["wide_close", "prompt_move"])
        let port = FakeRigCheck.check(prompt: "Pan left.", camera: CameraSpec(rig: CameraRig(focalMm: 18), move: SuiteMove(id: "static"), angle: CameraAngle(shotSize: "cu")),
                                      speaking: false)
        XCTAssertEqual(rig, port, "demo mode words and patches match the server's")
        let none = try await api.suiteRigCheck(ShotRequest(prompt: "She smiles."))
        XCTAssertEqual(none, [])

        // Every rule, as the composer sends it: same ids, lines, labels and patches.
        let cases: [(String?, CameraSpec, Bool?)] = [
            (nil, CameraSpec(mode: "preset", rig: CameraRig(body: "camcorder"), move: SuiteMove(id: "rack_focus", intensity: 0.5)), nil),
            (nil, CameraSpec(mode: "preset", rig: CameraRig(body: "webcam"), move: SuiteMove(id: "rack_focus"), mix: SuiteMove(id: "dolly_in", intensity: 0.4)), nil),
            (nil, CameraSpec(mode: "preset", rig: CameraRig(body: "phone", aperture: "f2.8")), nil),
            (nil, CameraSpec(mode: "preset", rig: CameraRig(focalMm: 14), angle: CameraAngle(shotSize: "ecu")), nil),
            (nil, CameraSpec(mode: "preset", angle: CameraAngle(height: "worm", shotSize: "mcu")), nil),
            (nil, CameraSpec(mode: "preset", rig: CameraRig(look: "bw_film"), palette: CameraPalette(preset: "hyper_neon")), nil),
            (nil, CameraSpec(mode: "preset", rig: CameraRig(look: "tungsten_stock"), palette: CameraPalette(preset: "golden_warmth")), nil),
            ("The camera pushes in on her face as she turns.", CameraSpec(mode: "preset", move: SuiteMove(id: "orbit_right")), nil),
            ("Low angle, looking up at her on the stairs.", CameraSpec(mode: "preset", angle: CameraAngle(height: "high")), nil),
            ("A tight close-up of her hands.", CameraSpec(mode: "preset", angle: CameraAngle(shotSize: "ls")), nil),
            ("Open on the street and pull back to reveal the city.", CameraSpec(mode: "preset", move: SuiteMove(id: "crane_up")), nil),
            ("No zoom, no pan left, she just smiles.", CameraSpec(mode: "preset", move: SuiteMove(id: "static")), nil),
            (nil, CameraSpec(mode: "preset", move: SuiteMove(id: "orbit_left")), true),
            (nil, CameraSpec(mode: "preset", move: SuiteMove(id: "handheld"), mix: SuiteMove(id: "dolly_in")), true),
            (nil, CameraSpec(mode: "preset", preset: "phone_ugc", rig: CameraRig(aperture: "f1.4")), nil),
        ]
        for (prompt, camera, speaking) in cases {
            let server = try await api.suiteRigCheck(ShotRequest(prompt: prompt ?? "", speaking: speaking, camera: camera))
            if prompt?.hasPrefix("No zoom") != true { XCTAssertFalse(server.isEmpty, "\(camera)") }
            XCTAssertEqual(server, FakeRigCheck.check(prompt: prompt, camera: camera, speaking: speaking ?? false), "\(prompt ?? "") \(camera)")
        }
    }
}
