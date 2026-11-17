import XCTest
@testable import MuseCore

/// Her world, phase 1 (plans/model-world.md §1, §5): places on her page, the @ list's order, priced place photos.
final class PlacesTests: XCTestCase {
    private func loc(_ id: String, _ name: String, model: String?, at: Double) -> SuiteLocation {
        SuiteLocation(id: id, name: name, image: ImageRef(url: "https://x/\(id).jpg"), createdAt: at, modelId: model)
    }

    func testTagsAsTheServerMakesThem() {
        XCTAssertEqual(Places.tag(from: "Café by the gym"), "cafe-by-the-gym")
        XCTAssertEqual(Places.tag(from: "  !!! "), "place")
        XCTAssertEqual(Places.tag(from: "Her  Apartment 2"), "her-apartment-2")
        XCTAssertEqual(Places.cleanTag("@Cafe "), "cafe")
        XCTAssertNil(Places.cleanTag("-cafe"))
        XCTAssertNil(Places.cleanTag("ca fe"))
        XCTAssertNil(Places.cleanTag(String(repeating: "a", count: 31)))
    }

    func testTheAtListShowsHerPlacesThenTheStudios() {
        let all = [loc("1", "Rooftop", model: nil, at: 3), loc("2", "Café by the gym", model: "m1", at: 1), loc("3", "Gym", model: "m2", at: 5), loc("4", "Apartment", model: "m1", at: 4)]
        let (hers, studio) = Places.forModel("m1", all)
        XCTAssertEqual(hers.map(\.name), ["Apartment", "Café by the gym"])
        XCTAssertEqual(studio.map(\.name), ["Rooftop"])
        XCTAssertEqual(Places.suggestions("m1", all, query: "").map(\.name), ["Apartment", "Café by the gym", "Rooftop"], "another model's Gym is left out")
        XCTAssertEqual(Places.suggestions("m1", all, query: "cafe").map(\.name), ["Café by the gym"], "matched on the tag too")
        XCTAssertEqual(Places.suggestions(nil, all, query: "").map(\.name), ["Rooftop"], "with no character only the studio's")
        XCTAssertEqual(Places.summary(hers), "Apartment, Café by the gym")
        XCTAssertEqual(Places.summary([]), "None yet")
    }

    func testDecodesAPlaceAndAnOlderLocation() throws {
        let json = #"{"id":"loc_1","name":"Café by the gym","tag":"cafe","modelId":"m1","description":"Striped awning","cover":1,"image":{"asset":"b"},"images":[{"asset":"a","source":"upload"},{"url":"https://x/b.jpg","source":"description"}],"createdAt":7}"#
        let p = try JSONDecoder().decode(SuiteLocation.self, from: Data(json.utf8))
        XCTAssertEqual(p.tag, "cafe")
        XCTAssertEqual(p.modelId, "m1")
        XCTAssertFalse(p.isStudio)
        XCTAssertEqual(p.images.map(\.source), [.upload, .description])
        XCTAssertEqual(p.coverImage, ImageRef(url: "https://x/b.jpg"))
        XCTAssertEqual(p.images[1].source.caption, "Generated from a description")
        let old = try JSONDecoder().decode(SuiteLocation.self, from: Data(#"{"id":"l2","name":"Rooftop bar","image":{"asset":"r"},"createdAt":5}"#.utf8))
        XCTAssertTrue(old.isStudio)
        XCTAssertEqual(old.tag, "rooftop-bar")
        XCTAssertEqual(old.images, [PlaceImage(image: .asset("r"), source: .upload)])
        XCTAssertEqual(old.coverImage, .asset("r"))
        // A photo goes back as {asset|url, source}.
        let enc = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PlaceImage(image: .asset("a"), source: .random))) as? [String: String]
        XCTAssertEqual(enc, ["asset": "a", "source": "random"])
    }

    func testThePhotoRequestSendsTheAtPlace() {
        var d = ComposerDraft()
        d.tokens = PromptTokens.text("Coffee at ").addMention(kind: "location", id: "loc_9", label: "Café").0
        d.tokens = d.tokens.addMention(kind: "character", id: "m1", label: "Zel").0
        XCTAssertEqual(d.photoRequest(PhotoDraft())?.placeId, "loc_9")
        var none = ComposerDraft()
        none.tokens = PromptTokens.text("A portrait").addMention(kind: "character", id: "m1", label: "Zel").0
        XCTAssertNil(none.photoRequest(PhotoDraft())?.placeId)
    }

    func testDemoPlacesRoundTrip() async throws {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        let models = try await a.listModels()
        guard models.count >= 2 else { return XCTFail("the demo has two models") }
        let her = models[0].id, other = models[1].id
        // Her place may start with no photo; a studio place can't.
        var cafe = try await a.createPlace(NewPlace(name: "corner café", modelId: her, tag: "@corner", description: "Striped awning"))
        XCTAssertEqual(cafe.tag, "corner")
        XCTAssertTrue(cafe.images.isEmpty)
        do { _ = try await a.createPlace(NewPlace(name: "Bare", modelId: nil)); XCTFail("a studio place needs a photo") } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        do { _ = try await a.createPlace(NewPlace(name: "Other", modelId: her, tag: "corner")); XCTFail("tag taken") } catch let e as ApiError { XCTAssertEqual(e.code, "tag_taken") }
        // Random needs a photo; a description is priced first, then made, never above the price approved.
        do { _ = try await a.placePhotoEstimate(id: cafe.id, PlacePhotoRequest(mode: .random)); XCTFail("needs a photo") } catch let e as ApiError { XCTAssertEqual(e.code, "needs_a_photo") }
        let e = try await a.placePhotoEstimate(id: cafe.id, PlacePhotoRequest(mode: .description))
        XCTAssertEqual(e.buttonLabel, "Generate · $0.03")
        do { _ = try await a.makePlacePhoto(id: cafe.id, PlacePhotoRequest(mode: .description, maxUsd: 0.01)); XCTFail("above the approved price") } catch let e as ApiError { XCTAssertEqual(e.code, "price_changed") }
        let made = try await a.makePlacePhoto(id: cafe.id, PlacePhotoRequest(mode: .description, maxUsd: e.estimate))
        XCTAssertEqual(made.place.images.map(\.source), [.description])
        XCTAssertLessThanOrEqual(made.chargedUsd, e.estimate)
        cafe = try await a.addPlaceImage(id: cafe.id, image: .asset("g_front"))
        cafe = try await a.updatePlace(id: cafe.id, PlacePatch(name: "Café downstairs", cover: 1))
        XCTAssertEqual(cafe.name, "Café downstairs")
        XCTAssertEqual(cafe.image, .asset("g_front"))
        cafe = try await a.removePlaceImage(id: cafe.id, index: 0)
        XCTAssertEqual(cafe.cover, 0)
        XCTAssertEqual(cafe.images.count, 1)
        // Copy to another model keeps the tag when it's free.
        let copy = try await a.copyPlace(id: cafe.id, toModel: other)
        XCTAssertEqual(copy.modelId, other)
        XCTAssertEqual(copy.tag, "corner")
        let again = try await a.copyPlace(id: cafe.id, toModel: other)
        XCTAssertNotEqual(again.tag, "corner")
        let list = try await a.suiteLocations()
        XCTAssertTrue(Places.forModel(her, list).hers.map(\.id).contains(cafe.id))
        XCTAssertFalse(Places.forModel(her, list).hers.contains { $0.id == copy.id }, "the copy is the other model's")
    }

    func testAShotSendsThePlaceAndSkipsAPhotoLessOne() {
        let bare = SuiteLocation(id: "loc_b", name: "Park bench", image: ImageRef(), modelId: "m1", description: "Green bench")
        var t = PromptTokens.text("Reading on ")
        t = t.addMention(kind: "location", id: bare.id, label: bare.name).0
        let r = ComposerDraft(tokens: t).request(InputSlots(), SuiteInputs(images: 4), locations: [bare])
        XCTAssertEqual(r.placeId, "loc_b")
        XCTAssertNil(r.references?.images, "no photo yet: the server words it")
        let enc = String(data: try! JSONEncoder().encode(ComposerDraft(tokens: .text("x")).request(InputSlots(), .none, locations: [])), encoding: .utf8)!
        XCTAssertFalse(enc.contains("placeId"), "left out without a place")
    }
}

