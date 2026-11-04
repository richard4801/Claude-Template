import XCTest
@testable import MuseCore

/// Photo prices are estimates that settle to the exact engine cost (plans/api.md "App clean-up" §3). The shared fixture
/// `photo_pricing_fixture.json` is a byte-for-byte copy of android/core/src/test/resources/photo_pricing_fixture.json.
final class PhotoPricingTests: XCTestCase {
    func testContractEstimates() {
        let p = PhotoPricing.standard
        XCTAssertEqual(p.shoot(), 0.4644, accuracy: 1e-12)
        XCTAssertEqual(p.outfitSet(), 0.1911, accuracy: 1e-12)
        XCTAssertEqual(p.sheetAngles(1), 0.1011, accuracy: 1e-12)
        XCTAssertEqual(p.loraSet(), 3.033, accuracy: 1e-12)
        XCTAssertEqual(PhotoPricing.label(p.shoot()), "about $0.46")
        XCTAssertEqual(PhotoPricing.label(p.outfitSet()), "about $0.19")
        XCTAssertEqual(PhotoPricing.label(p.sheetAngles(1)), "about $0.10")
        XCTAssertEqual(PhotoPricing.label(p.loraSet()), "about $3.03")
        // References are capped at maxRefs; fewer references cost less.
        XCTAssertEqual(p.newShot(outMp: 2, refs: 9), p.newShot(outMp: 2, refs: 6))
        XCTAssertLessThan(p.shoot(count: 4, refs: 1), p.shoot())
        XCTAssertEqual(p.shoot(count: 1), p.newShot(outMp: 2, refs: 6), accuracy: 1e-12)
    }

    func testDecodesFeaturesPhoto() throws {
        let p = try JSONDecoder().decode(PhotoPricing.self, from: Data(#"{"perRun":0.02,"maxRefs":4,"estimates":{"shoot":0.5}}"#.utf8))
        XCTAssertEqual(p.perRun, 0.02)
        XCTAssertEqual(p.perInputMp, 0.015, "missing fields take the contract's prices")
        XCTAssertEqual(p.maxRefs, 4)
        XCTAssertEqual(p.estimates?.shoot, 0.5)
        XCTAssertNil(p.estimates?.loraSet)
    }

    func testEveryPhotoFixtureRowMatches() throws {
        let root = try XCTUnwrap(fixture("photo_pricing_fixture") as? [String: Any])
        let paramsData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(root["params"]))
        let p = try JSONDecoder().decode(PhotoPricing.self, from: paramsData)
        let rows = try XCTUnwrap(root["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 94)
        XCTAssertEqual(Set(rows.compactMap { $0["kind"] as? String }), ["shoot", "outfitSet", "sheetAngles", "loraSet"])
        // The fixture's params are the contract's defaults.
        XCTAssertEqual(p, PhotoPricing.standard)
        for o in rows {
            let kind = try XCTUnwrap(o["kind"] as? String)
            let refs = (o["refs"] as? Int) ?? p.maxRefs
            let count = (o["count"] as? Int) ?? 1
            let ctx = "\(kind) count \(count) refs \(refs)"
            let v: Double
            switch kind {
            case "shoot": v = p.shoot(count: count, refs: refs)
            case "outfitSet": v = p.outfitSet(refs: refs)
            case "sheetAngles": v = p.sheetAngles(count, refs: refs)
            case "loraSet": v = p.loraSet(refs: refs)
            default:
                XCTFail("unknown kind \(ctx)")
                continue
            }
            if let outMp = o["outMp"] as? Double {
                XCTAssertEqual(outMp, kind == "shoot" ? PhotoPricing.shootOutMp : PhotoPricing.otherOutMp, ctx)
            }
            XCTAssertEqual(v, try XCTUnwrap(o["estimate"] as? Double), accuracy: 1e-12, ctx)
            if let label = o["label"] as? String { XCTAssertEqual(PhotoPricing.label(v), label, ctx) }
        }
    }
}

/// Member-facing wording: no GPUs, warm-ups, steps, start-up or provider names (plans/app-cleanup.md).
final class MemberTextTests: XCTestCase {
    func testFlagsTechnicalWords() {
        for bad in ["The GPU disconnected at step 3.", "Rendering on Replicate", "Waiting for a GPU", "GPU warm-up $0.04", "Paused: the studio's GPU credit is low",
                    "Top up RunPod", "H3 Lite", "Starting GPU · ~4 min left", "step 5/10 · ~6 min left", "Exact edit · 10 steps", "SeedVR2 on the pod",
                    "Replicate's safety filter refused this clip", "start-up"] {
            XCTAssertFalse(MemberText.isSafe(bad), bad)
        }
        for ok in ["Rendering · about 2 min · $0.14", "Waiting to start", "#2 in line · starts in ~3 min", "Something went wrong · you weren't charged",
                   "Draft · 768P", "Edit", "Fast · beta", "Upscale · 2K", "Preparing the clip", "Finishing", "Getting ready · ~4 min left", "Lip sync · ~2 min left"] {
            XCTAssertTrue(MemberText.isSafe(ok), ok)
        }
        XCTAssertEqual(MemberText.safe("The GPU disconnected", or: "x"), "x")
        XCTAssertEqual(MemberText.safe("  Done ", or: "x"), "Done")
        XCTAssertEqual(MemberText.safe(nil, or: "x"), "x")
    }

    func testShownPromptHasNoSteps() {
        let p = PromptEngine.video(VideoPromptInput(identity: SampleData.models()[0].promptIdentity, outfitName: "Green set"))
        XCTAssertTrue(p.contains("steps: 10 · clip:"), p)
        let shown = PromptEngine.memberView(p)
        XCTAssertFalse(shown.contains("steps"), shown)
        XCTAssertTrue(shown.contains("  clip: 5.2s · takes: 1") || shown.contains("clip: "), shown)
        XCTAssertEqual(shown.components(separatedBy: "\n").count, p.components(separatedBy: "\n").count)
    }
}
