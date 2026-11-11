import XCTest
@testable import MuseCore

/// Settings → Providers (WS6, owner-approved 2026-11-09): WS5's shapes, words and demo mode.
final class ProvidersTests: XCTestCase {
    func testDecodesTheServersShapes() throws {
        let p = try JSONDecoder().decode(ProviderAccountsList.self, from: Data(#"{"providers":[{"id":"p1","kind":"fal","label":"fal","keyLast4":"…4f2a","status":"ok","checkedAt":1,"createdAt":1793952000000,"models":{"added":48,"enabled":9}}],"keysReady":false}"#.utf8))
        XCTAssertFalse(p.keysReady)
        XCTAssertEqual(p.providers[0].models.enabled, 9)
        XCTAssertTrue(ProviderText.line(p.providers[0]).hasPrefix("Key ending 4f2a, added "))
        XCTAssertTrue(ProviderText.line(p.providers[0]).hasSuffix("9 of 48 models on."))
        let page = try JSONDecoder().decode(ProviderCatalogPage.self, from: Data(#"{"models":[{"ref":"a/b","name":"B","description":null,"kind":"video","inputs":{},"missing":[],"ready":true,"price":{"basis":"per_second","costUsd":0.07,"source":"provider"},"added":{"id":"c_1","enabled":true}}],"nextCursor":null}"#.utf8))
        XCTAssertEqual(page.models[0].added?.id, "c_1")
        XCTAssertEqual(ProviderText.price(page.models[0].price), "$0.070/s")
        XCTAssertEqual(ProviderText.price(ProviderPrice(basis: "per_run", costUsd: 0.04)), "$0.040")
        XCTAssertEqual(ProviderText.message(ApiError("provider_keys_unavailable", "x")), "Provider keys aren't set up on the server yet.")
    }

    func testDemoAddKeyBrowseSwitchOnRename() async throws {
        let api = FakeMuseAPI()
        do { _ = try await api.addProvider(kind: "fal", apiKey: "short", label: nil); XCTFail("a bad key is refused") } catch let e as ApiError { XCTAssertEqual(e.code, "invalid_key") }
        let p = try await api.addProvider(kind: "fal", apiKey: "fal_live_1234567890abcdef", label: nil)
        XCTAssertEqual(p.keyLast4, "…cdef")
        let page = try await api.providerModels(p.id, query: "", kind: "video", cursor: nil)
        XCTAssertTrue(page.models.allSatisfy { $0.kind == "video" })
        let m = try await api.addProviderModel(p.id, ref: page.models[0].ref, displayName: nil)
        XCTAssertFalse(m.enabled, "added switched off")
        let on = try await api.updateCustomModel(m.id, enabled: true, displayName: "Kling (fast)")
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.displayName, "Kling (fast)")
        let list = try await api.providers()
        XCTAssertEqual(list.providers[0].models.enabled, 1)
        try await api.removeProvider(p.id)
        let customs = try await api.customModels()
        XCTAssertTrue(customs.isEmpty)
    }

    /// Higgsfield (2026-11-11): a provider the server already has an account for connects with no key pasted.
    func testServerKeyProvider() async throws {
        let kinds = try JSONDecoder().decode(ProviderKindsList.self, from: Data(#"{"kinds":[{"kind":"muapi","label":"Muapi"},{"kind":"higgsfield","label":"Higgsfield","keyHint":"x","keyUrl":"https://console.higgsfield.ai","serverKey":true}],"keysReady":true}"#.utf8))
        XCTAssertEqual(kinds.kinds.map(\.serverKey), [false, true])
        let acc = try JSONDecoder().decode(ProviderAccountsList.self, from: Data(#"{"providers":[{"id":"p1","kind":"higgsfield","label":"Higgsfield (studio account)","keyLast4":"server key","serverKey":true,"status":"ok","createdAt":1793952000000,"models":{"added":2,"enabled":1}}],"keysReady":true}"#.utf8))
        XCTAssertTrue(ProviderText.line(acc.providers[0]).hasPrefix("The studio's account, added "))
        let api = FakeMuseAPI()
        let p = try await api.addProvider(kind: "higgsfield", apiKey: "", label: nil)
        XCTAssertTrue(p.serverKey)
        XCTAssertEqual(p.label, "Higgsfield (studio account)")
        do { _ = try await api.addProvider(kind: "muapi", apiKey: "", label: nil); XCTFail("a key is needed for the others") } catch let e as ApiError { XCTAssertEqual(e.code, "invalid_key") }
    }
}
