import XCTest
@testable import MuseCore

/// New Swap (beta, plans/new-swap.md): the panel's draft → the request's `remix` object (only what is on, each toggle
/// with only its own field, as the server's strict schema wants), what is missing, the kept line, Claude's changes from
/// the shared draft, and the server's estimate and model-pill views.
final class NewSwapTests: XCTestCase {
    private func json(_ r: ShotRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    }

    func testNothingOnAsksForAChangeAndEachToggleSaysWhatItNeeds() {
        var d = RemixDraft()
        XCTAssertEqual(d.missing, "Turn on a change: Background, Outfit, Character or Look & light")
        d.backgroundOn = true
        XCTAssertEqual(d.missing, "Background · Describe: write the new place")
        d.backgroundWords = "  a rooftop at golden hour "
        XCTAssertNil(d.missing)
        d.backgroundMode = .photo
        XCTAssertEqual(d.missing, "Background · New photo: pick a location or upload a picture")
        d.backgroundImage = ImageRef(url: "/uploads/u/img_1.jpg")
        d.outfitOn = true
        XCTAssertEqual(d.missing, "Outfit: pick one of her outfits")
        d.outfitKind = .words
        XCTAssertEqual(d.missing, "Outfit · Words: write what they wear")
        d.outfitWords = "a black linen two-piece"
        d.characterOn = true
        XCTAssertEqual(d.missing, "Character: pick her")
        d.characterKind = .face
        XCTAssertEqual(d.missing, "Face swap: add a photo of the face")
        d.faceImage = ImageRef(asset: "a_face")
        d.lookOn = true
        XCTAssertEqual(d.missing, "Look & light: write the time of day, light or colour grade")
        d.lookWords = "night, neon"
        XCTAssertNil(d.missing)
    }

    func testTheRequestSendsOnlyTheTogglesThatAreOnEachWithOnlyItsField() throws {
        var d = RemixDraft()
        d.backgroundOn = true
        d.backgroundWords = " a rooftop "
        d.backgroundImage = ImageRef(url: "/uploads/u/old.jpg") // left over from New photo: not sent with Describe
        d.characterOn = true
        d.modelId = "m_mia"
        d.faceImage = ImageRef(asset: "a_face") // the face swap's photo stays unsent while Character is her
        d.range = RemixRange(from: 1.5, to: 9)
        let o = try json(.remix(clipId: "clip_1", draft: d))
        XCTAssertEqual(o["mode"] as? String, "remix")
        XCTAssertEqual(o["clipId"] as? String, "clip_1")
        XCTAssertEqual(o["keepAudio"] as? Bool, true)
        XCTAssertEqual(o["range"] as? [Double], [1.5, 9])
        XCTAssertNil(o["engineModel"], "Auto: no model sent")
        let x = try XCTUnwrap(o["remix"] as? [String: Any])
        XCTAssertEqual(Set(x.keys), ["background", "character"])
        XCTAssertEqual(x["background"] as? [String: String], ["mode": "describe", "words": "a rooftop"])
        XCTAssertEqual(x["character"] as? [String: String], ["kind": "model", "modelId": "m_mia"])
        d.engineModel = "kling-o1"
        d.keepAudio = false
        d.outfitOn = true
        d.outfitKind = .product
        d.productImage = ImageRef(url: "/uploads/u/p.jpg")
        d.productName = "Linen shirt"
        let o2 = try json(.remix(clipId: "clip_1", draft: d))
        XCTAssertEqual(o2["engineModel"] as? String, "kling-o1")
        XCTAssertEqual(o2["keepAudio"] as? Bool, false)
        let out = try XCTUnwrap((o2["remix"] as? [String: Any])?["outfit"] as? [String: Any])
        XCTAssertEqual(out["kind"] as? String, "product")
        XCTAssertEqual(out["name"] as? String, "Linen shirt")
        XCTAssertEqual((out["image"] as? [String: String])?["url"], "/uploads/u/p.jpg")
        XCTAssertNil(out["words"])
    }

    func testTheKeptLineNamesWhatIsOff() {
        var d = RemixDraft()
        d.lookOn = true
        XCTAssertEqual(d.keptLine, "Kept from the clip: motion, camera, sound, the person, the outfit, the place")
        d.keepAudio = false
        d.characterOn = true
        XCTAssertEqual(d.keptLine, "Kept from the clip: motion, camera, the outfit, the place")
    }

    func testClaudesChangesComeFromTheSharedDraftAndRoundTrip() {
        var d = RemixDraft()
        d.lookOn = true
        d.lookWords = "warm"
        let raw: [String: JSONValue] = [
            "tool": .string("remix"), "clipId": .string("clip_9"), "engineModel": .string("wan-2.7-edit"),
            "range": .array([.number(0), .number(10)]),
            "remix": .object([
                "background": .object(["mode": .string("photo"), "image": .object(["asset": .string("loc_1")]), "name": .string("Lisbon street")]),
                "character": .object(["kind": .string("model"), "modelId": .string("m_mia")]),
            ]),
        ]
        let r = RemixDraftSync.apply(raw, to: d)
        XCTAssertTrue(r.draft.backgroundOn)
        XCTAssertEqual(r.draft.backgroundMode, .photo)
        XCTAssertEqual(r.draft.backgroundImage, ImageRef(asset: "loc_1"))
        XCTAssertEqual(r.draft.backgroundName, "Lisbon street")
        XCTAssertEqual(r.draft.modelId, "m_mia")
        XCTAssertFalse(r.draft.lookOn, "a toggle Claude left out is switched off")
        XCTAssertEqual(r.draft.range, RemixRange(from: 0, to: 10))
        XCTAssertEqual(r.draft.engineModel, "wan-2.7-edit")
        XCTAssertEqual(r.changed, ["Background", "Character", "Look & light", "Trim", "Model"])
        // The panel's own fields go back as the same JSON.
        let f = RemixDraftSync.fields(r.draft, clipId: "clip_9")
        XCTAssertEqual(f["tool"], .string("remix"))
        XCTAssertEqual(f["clipId"], .string("clip_9"))
        XCTAssertEqual(f["range"], .array([.number(0), .number(10)]))
        XCTAssertEqual(RemixDraftSync.apply(f, to: r.draft).changed, [])
    }

    func testTheEstimateAndTheModelPillDecode() throws {
        let e = try JSONDecoder().decode(ShotEstimate.self, from: Data("""
        {"mode":"remix","label":"Swap · Draft · 1080p","seconds":10,"estimate":1,"buttonLabel":"Generate · 10 s · $1.00","warnings":[],
         "remix":{"toggles":["background"],"why":"Background only: Wan 2.7 Edit (keeps the sound, up to 10 s, 1080p)","tested":false,"keepAudio":true,
                  "uses":{"from":0,"to":10,"of":24},"trim":{"needed":true,"tooShort":false,"minSeconds":2,"maxSeconds":10},
                  "billedSeconds":{"output":10,"input":0,"inRate":false}}}
        """.utf8))
        XCTAssertEqual(e.remix?.trim.needed, true)
        XCTAssertEqual(e.remix?.uses.of, 24)
        XCTAssertEqual(e.remix?.why, "Background only: Wan 2.7 Edit (keeps the sound, up to 10 s, 1080p)")
        let m = try JSONDecoder().decode(RemixModels.self, from: Data("""
        {"toggles":["background"],"auto":{"model":"wan-2.7-edit","why":"Background only"},"models":[
          {"model":"wan-2.7-edit","label":"Wan 2.7 Edit · Replicate","support":"yes","reason":null,"unavailable":null,"tested":false,"auto":true,"why":"Background only",
           "limits":{"minSeconds":2,"maxSeconds":10,"resolutions":["720p","1080p"],"maxImages":1,"keepsAudio":true,"soundNote":"keeps the clip’s sound"},
           "price":{"resolution":"1080p","perSec":0.1,"seconds":10,"trimNeeded":true,"usd":1,"inputBilled":"only the new video is billed"}},
          {"model":"genjutsu-light","label":"Genjutsu Light · Higgsfield","support":"adapted","route":"edit","reason":"Genjutsu Light puts a person from pictures into the clip: MUSE sends a still of the person from your clip so they stay themselves (their look may drift)","notes":["Genjutsu Light puts a person from pictures into the clip: MUSE sends a still of the person from your clip so they stay themselves (their look may drift)"],"unavailable":null,"tested":true,"auto":false,
           "limits":{"minSeconds":4,"maxSeconds":15,"resolutions":["480p","720p","1080p"],"maxImages":8,"keepsAudio":false,"soundNote":"MUSE puts the clip’s sound back"},
           "price":{"resolution":"720p","perSec":0.2,"inputBilled":"the clip’s seconds are billed too (in the rate)"}}]}
        """.utf8))
        XCTAssertEqual(m.auto?.model, "wan-2.7-edit")
        XCTAssertEqual(m.models[0].detail, "up to 10 s, 720p/1080p, keeps the clip’s sound, not tested yet")
        XCTAssertTrue(m.models[0].pickable)
        // Every model can be picked (owner 2026-11-12); an adapted one says what MUSE does with it.
        XCTAssertTrue(m.models[1].pickable)
        XCTAssertEqual(m.models[1].adaptedLine, "Genjutsu Light puts a person from pictures into the clip: MUSE sends a still of the person from your clip so they stay themselves (their look may drift)")
        XCTAssertNil(m.models[0].adaptedLine)
    }

    func testEveryModelOfAKindIsOfferedForEveryPurposeDefaultFirstThenNativeThenAdapted() throws {
        let cat = try JSONDecoder().decode(EngineCatalog.self, from: Data("""
        {"purposes":[{"id":"talking","label":"Talking","kind":"video","default":"h3-lite"}],"engines":[
          {"model":"kling-v4","name":"Kling 4.0","kind":"video","purposes":["shot","recast"],"label":"Kling 4.0 · Replicate"},
          {"model":"wan-2.7-edit","name":"Wan 2.7 Edit","kind":"video","purposes":[]},
          {"model":"h3","name":"MiniMax H3","kind":"video","purposes":["shot","talking"]},
          {"model":"h3-lite","name":"MiniMax H3 Lite","kind":"video","purposes":["shot","talking"]},
          {"model":"wan-3.0","name":"Wan 3.0","kind":"video","purposes":["shot"],"livePrice":true},
          {"model":"flux","name":"FLUX","kind":"image","purposes":["photo"]},
          {"model":"rvm","name":"RVM","kind":"tool","purposes":["matte"]}]}
        """.utf8))
        XCTAssertEqual(cat.engines(for: .talking).map(\.model), ["h3-lite", "h3", "kling-v4", "wan-2.7-edit", "wan-3.0"])
        XCTAssertNil(cat.engines(for: .talking)[1].adaptedNote(.talking))
        XCTAssertEqual(cat.engines(for: .talking)[2].adaptedNote(.talking), "Not made for this: MUSE adapts what it can’t take and says what it changed")
        XCTAssertTrue(cat.engines(for: .talking)[4].livePrice)
        XCTAssertEqual(cat.engines(for: .photo).map(\.model), ["flux"])
        XCTAssertEqual(cat.engines(for: .matte).map(\.model), ["rvm"])
    }

    func testRemixIsADraftToolTheServerAccepts() {
        XCTAssertTrue(SuiteDraft.tools.contains("remix"))
    }

    func testDemoModePricesANewSwapLikeASwapOfTheClip() async throws {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        let clip = await a.uploadClip(ClipMeta(name: "walk", durationSec: 8, width: 1080, height: 1920, fps: 30), file: nil, progress: nil)
        var d = RemixDraft()
        d.lookOn = true
        d.lookWords = "night"
        let e = try await a.suiteEstimate(.remix(clipId: clip.id, draft: d))
        XCTAssertEqual(e.mode, "remix")
        XCTAssertEqual(e.keepAudio, true)
        XCTAssertTrue(e.label.hasPrefix("Swap"))
    }
}
