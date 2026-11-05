import XCTest
@testable import MuseCore

/// AI suite (workstream 1): demo mode's suite (FakeMuseAPI): catalog, estimate, shots on the fake job pipeline with live
/// progress, Recast, settings, and the member view (no engines).
final class SuiteFakeTests: XCTestCase {
    private func api(speed: Double = 0) async throws -> FakeMuseAPI {
        let a = FakeMuseAPI(speed: speed, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        return a
    }

    func testCatalogAndMemberView() async throws {
        let a = try await api()
        let c = try await a.suiteCatalog()
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.test)
        XCTAssertEqual(c.tiers.map(\.id), SuiteText.tierIds)
        XCTAssertNotNil(c.tiers[0].models)
        XCTAssertEqual(c.camera.library.count, 16)
        await a.setRole("member")
        let m = try await a.suiteCatalog()
        XCTAssertTrue(m.tiers.allSatisfy { $0.models == nil })
        let e = try await a.suiteEstimate(ShotRequest(modelId: SampleData.demo, prompt: "She waves.", duration: 6, quality: "hd"))
        XCTAssertNil(e.engine)
        XCTAssertTrue(SuiteText.isMemberSafe(e.label + e.buttonLabel + e.priceLine))
        do {
            _ = try await a.suiteSettings()
            XCTFail("members get owner_only")
        } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
    }

    func testEstimateLabelsCapsAndNothingFits() async throws {
        let a = try await api()
        let e = try await a.suiteEstimate(ShotRequest(modelId: SampleData.demo, prompt: "She waves.", duration: 6, quality: "hd", takes: 2))
        XCTAssertEqual(e.label, "Shot · HD · 2K")
        XCTAssertEqual(e.estimate, 1.56, accuracy: 1e-9)
        XCTAssertEqual(e.buttonLabel, "Generate · 6 s · $1.56 · 2 takes")
        XCTAssertEqual(e.engine?.name, "MiniMax H3")
        let short = try await a.suiteEstimate(ShotRequest(prompt: "x", duration: 2))
        XCTAssertEqual(short.seconds, 4)
        XCTAssertFalse(short.warnings.isEmpty)
        let big = try await a.suiteEstimate(ShotRequest(prompt: "x", duration: 30, quality: "cinema", takes: 4))
        XCTAssertFalse(big.ok)
        XCTAssertEqual(big.code, "suite_over_job_limit")
        XCTAssertNotNil(big.problem)
        do {
            _ = try await a.suiteEstimate(ShotRequest(prompt: "x", duration: 30, quality: "draft"))
            XCTFail("nothing fits")
        } catch let e as ApiError { XCTAssertEqual(e.code, "nothing_fits") }
    }

    func testShotRunsOnTheJobPipeline() async throws {
        let a = try await api(speed: 300)
        let events = a.events()
        let job = try await a.suiteCreateShot(ShotRequest(title: "Café morning", modelId: SampleData.demo, prompt: "She waves.", duration: 5, quality: "standard"))
        XCTAssertEqual(job.request.engine, "suite")
        XCTAssertEqual(job.engineLabel, "Shot · Standard · 768p")
        var sawProgress = false
        var done: ApiEvent?
        for await e in events {
            guard let j = e.job, j.id == job.id else { continue }
            if j.isRunning && j.progress > 0 { sawProgress = true }
            if j.isDone { done = e; break }
        }
        XCTAssertTrue(sawProgress)
        let takes = try XCTUnwrap(done?.takes)
        XCTAssertEqual(takes.first?.label, "Standard")
        let s = try await a.suiteShot(id: job.id)
        XCTAssertTrue(s.job.isDone)
        XCTAssertNotNil(s.engine)
    }

    func testRecastAndSettings() async throws {
        let a = try await api()
        let clip = try await a.uploadClip(SampleData.sampleMeta, file: nil)
        let e = try await a.suiteEstimate(.recast(clipId: clip.id, cast: [CastMember(characterId: SampleData.demo, personHint: "left")], quality: "hd"))
        XCTAssertEqual(e.label, "Recast · HD · 1080p")
        XCTAssertEqual(e.cast?.first?.who, "the person on the left")
        do {
            _ = try await a.suiteEstimate(.recast(clipId: clip.id, cast: [CastMember(characterId: SampleData.demo, personHint: "left"), CastMember(characterId: SampleData.demo, personHint: "left")], quality: "hd"))
            XCTFail("same person twice")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        let j = try await a.suiteCreateShot(.recast(clipId: clip.id, cast: [CastMember(characterId: SampleData.demo)], quality: "draft", title: "Recast"))
        XCTAssertTrue(j.engineLabel.hasPrefix("Recast · Draft"))

        let s = try await a.suiteSettings()
        XCTAssertFalse(s.models.isEmpty)
        let id = try XCTUnwrap(s.models.first { !$0.blocked }?.id)
        let s2 = try await a.updateSuiteSettings(SuiteSettingsPatch(models: [id: SuiteModelPatch(enabled: false)], capPerDay: 40))
        XCTAssertEqual(s2.model(id)?.enabled, false)
        XCTAssertEqual(s2.caps.perDay, 40)
        if let blocked = s.models.first(where: { $0.blocked }) {
            do {
                _ = try await a.updateSuiteSettings(SuiteSettingsPatch(models: [blocked.id: SuiteModelPatch(enabled: true)]))
                XCTFail("blocked")
            } catch let e as ApiError { XCTAssertEqual(e.code, "model_blocked") }
        }
    }
}
