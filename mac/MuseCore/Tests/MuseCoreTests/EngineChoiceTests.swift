import XCTest
@testable import MuseCore

/// "Pick the model everywhere" (WS6, 2026-11-08): WS13's engine catalog, defaults and the demo.
final class EngineChoiceTests: XCTestCase {
    func testCatalogDecodesTheServersShape() throws {
        let json = #"{"purposes":[{"id":"swap","label":"Character swap","kind":"video","default":"h3-lite","studioDefault":null}],"engines":[{"model":"h3-lite","name":"MiniMax H3 Lite","kind":"video","purposes":["swap","shot"],"custom":false,"default":true,"provider":"replicate","notice":null,"limits":{"minSeconds":4,"maxSeconds":15,"allowedSeconds":null,"aspectRatios":["9:16","16:9"],"resolutions":[{"id":"480P","label":"480P"},{"id":"768P","label":"768P"}],"maxInputSeconds":30},"resolution":"768P","price":{"basis":"per_second","usd":0.02},"inputs":{"start":true}},{"model":"seedvr2","name":"SeedVR2","kind":"tool","purposes":["upscale"],"limits":{},"price":{"basis":"per_output_second","usd":0.03}}]}"#
        let c = try JSONDecoder().decode(EngineCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(c.purpose(.swap)?.default, "h3-lite")
        XCTAssertEqual(c.engines(for: .swap).map(\.model), ["h3-lite"])
        XCTAssertEqual(c.label(.swap, model: nil), "Auto (MiniMax H3 Lite)")
        XCTAssertEqual(c.label(.swap, model: "h3-lite", resolution: "768P"), "MiniMax H3 Lite, 768P")
        let o = c.engines[0].option
        XCTAssertEqual(o.perSec, 0.02)
        XCTAssertEqual(o.resolutions.first { $0.id == "768P" }?.perSec, 0.02)
        XCTAssertEqual(ComposerModelPicker.limits(o), "4–15 s, 9:16 and 16:9")
        XCTAssertEqual(ComposerModelPicker.price(c.engines[1].option), "$0.030/s")
    }

    func testDefaultsDecodeNulls() throws {
        let d = try JSONDecoder().decode(EngineDefaults.self, from: Data(#"{"defaults":{"swap":"h3","photo":null},"builtin":{"swap":"h3-lite"}}"#.utf8))
        XCTAssertEqual(d.studioDefault(.swap), "h3")
        XCTAssertNil(d.studioDefault(.photo))
        XCTAssertEqual(d.builtin["swap"], "h3-lite")
    }

    func testDemoListsEveryPurposeAndSetsDefaults() async throws {
        let api = FakeMuseAPI()
        let all = try await api.engines(purpose: nil)
        for p in EnginePurpose.allCases {
            XCTAssertFalse(all.engines(for: p).isEmpty, "\(p) has models")
            XCTAssertNotNil(all.purpose(p)?.default, "\(p) has an Auto")
        }
        let swap = try await api.engines(purpose: .swap)
        XCTAssertTrue(swap.engines.allSatisfy { $0.purposes.contains("swap") })
        XCTAssertEqual(swap.engines.filter(\.isDefault).map(\.model), ["h3-lite"])
        let d = try await api.setEngineDefault(.swap, model: "kling-v4")
        XCTAssertEqual(d.studioDefault(.swap), "kling-v4")
        let after = try await api.engines(purpose: .swap)
        XCTAssertEqual(after.purpose(.swap)?.default, "kling-v4")
        XCTAssertEqual(after.purpose(.swap)?.studioDefault, "kling-v4")
        _ = try await api.setEngineDefault(.swap, model: nil)
        let back = try await api.engines(purpose: .swap)
        XCTAssertEqual(back.purpose(.swap)?.default, "h3-lite")
        do {
            _ = try await api.setEngineDefault(.captions, model: "kling-v4")
            XCTFail("a video model can't caption")
        } catch let e as ApiError { XCTAssertEqual(e.code, "engine_not_allowed") }
    }

    func testPurposesFollowTools() {
        XCTAssertEqual(EnginePurpose(tool: .swap), .swap)
        XCTAssertEqual(EnginePurpose(tool: .photo), .photo)
        XCTAssertTrue(EnginePurpose.outfit.isImage)
        XCTAssertFalse(EnginePurpose.upscale.isImage)
    }
}
