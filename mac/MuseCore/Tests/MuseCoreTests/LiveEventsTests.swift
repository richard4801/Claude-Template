import Foundation
import XCTest
@testable import MuseCore

/// Live events from another device (the phone, a member's app) land in the right list.
final class LiveEventsTests: XCTestCase {
    private func shot(_ id: String, at: Int64 = 10, status: String = "test") -> Take {
        Take(id: id, kind: "shot", title: "Shoot · Beach", label: "Beach · 1", status: status, thumb: ImageRef(asset: "g_front"), createdAt: at)
    }

    func testAPhotoshootOnThePhoneAppearsFirstThenChangesInPlaceAndGoes() {
        var takes = [shot("old", at: 1)]
        XCTAssertEqual(LiveEvents.applyTakes(&takes, ApiEvent(type: "take", take: shot("s_new"))), ["s_new"])
        XCTAssertEqual(takes.map(\.id), ["s_new", "old"])
        // The same take again (our own shoot's response, or a reconnect) never doubles it.
        XCTAssertEqual(LiveEvents.applyTakes(&takes, ApiEvent(type: "take", take: shot("s_new", status: "final"))), [])
        XCTAssertEqual(takes.map(\.id), ["s_new", "old"])
        XCTAssertEqual(takes[0].status, "final")
        LiveEvents.applyTakes(&takes, ApiEvent(type: "take", op: "delete", id: "s_new"))
        XCTAssertEqual(takes.map(\.id), ["old"])
    }

    func testAFinishedJobsTakesGoFirstNewestOnTop() {
        var takes = [shot("old", at: 1)]
        let added = LiveEvents.applyTakes(&takes, ApiEvent(type: "job", takes: [shot("t_1", at: 5), shot("t_2", at: 6)]))
        XCTAssertEqual(Set(added), ["t_1", "t_2"])
        XCTAssertEqual(takes.map(\.id), ["t_2", "t_1", "old"])
    }

    func testJobsUpsertAndDelete() {
        let j = SampleData.jobs(now: 1_700_000_000_000).first!
        var jobs: [Job] = []
        LiveEvents.applyJobs(&jobs, ApiEvent(type: "job", job: j))
        XCTAssertEqual(jobs.map(\.id), [j.id])
        var done = j
        done.state = "done"
        LiveEvents.applyJobs(&jobs, ApiEvent(type: "job", job: done))
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].state, "done")
        LiveEvents.applyJobs(&jobs, ApiEvent(type: "job", op: "delete", id: j.id))
        XCTAssertTrue(jobs.isEmpty)
    }

    func testTemplatesKeepRecentAndGoWhenDeletedOrMadePrivate() {
        var list = [MuseTemplate(id: "tpl", name: "Laundrette", recent: [])]
        LiveEvents.applyTemplates(&list, ApiEvent(type: "template", template: MuseTemplate(id: "tpl", name: "Laundrette", uses: 3)))
        XCTAssertEqual(list[0].uses, 3)
        XCTAssertEqual(list[0].recent?.count, 0)
        LiveEvents.applyTemplates(&list, ApiEvent(type: "template", template: MuseTemplate(id: "tpl_2", name: "New")))
        XCTAssertEqual(list.map(\.id), ["tpl_2", "tpl"])
        LiveEvents.applyTemplates(&list, ApiEvent(type: "template", op: "delete", id: "tpl"))
        XCTAssertEqual(list.map(\.id), ["tpl_2"])
    }

    func testSavedOutfitJoinsItsModel() {
        var models = [MuseModel(id: "m", name: "Demo", niche: "Fashion")]
        var outfits: [Outfit] = []
        LiveEvents.applyOutfit(&outfits, &models, Outfit(id: "o", modelId: "m", name: "Red", state: "generating"))
        XCTAssertEqual(models[0].outfitIds, [])
        LiveEvents.applyOutfit(&outfits, &models, Outfit(id: "o", modelId: "m", name: "Red", state: "ready"))
        XCTAssertEqual(outfits.count, 1)
        XCTAssertEqual(models[0].outfitIds, ["o"])
    }

    func testMembersAccountsAndModelDelete() {
        var members = [Member(id: "u1", email: "a@x.dev", tokens: 0)]
        LiveEvents.applyMembers(&members, ApiEvent(type: "member", member: Member(id: "u1", email: "a@x.dev", tokens: 500)))
        LiveEvents.applyMembers(&members, ApiEvent(type: "member", member: Member(id: "u2", email: "b@x.dev")))
        XCTAssertEqual(members.map(\.tokens), [500, 0])
        var accounts: [String: [Account]] = [:]
        LiveEvents.applyAccounts(&accounts, ApiEvent(type: "account", account: Account(modelId: "m", platform: .tiktok, handle: "@m"), modelId: "m"))
        XCTAssertEqual(accounts["m"]?.map(\.handle), ["@m"])
        LiveEvents.applyAccounts(&accounts, ApiEvent(type: "account", op: "delete", modelId: "m", platform: "tiktok"))
        XCTAssertEqual(accounts["m"]?.count, 0)
        XCTAssertEqual(LiveEvents.isModelDelete(ApiEvent(type: "model", op: "delete", id: "m")), "m")
        XCTAssertNil(LiveEvents.isModelDelete(ApiEvent(type: "model", model: MuseModel(id: "m", name: "x", niche: "y"))))
    }

    func testNewEventFieldsDecode() throws {
        let json = #"{"type":"studio","studioBalance":{"balanceUsd":125,"toppedUpUsd":125,"topUps":[]}}"#
        let e = try JSONDecoder().decode(ApiEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.studioBalance?.balanceUsd, 125)
        let d = try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"take","op":"delete","id":"s_1"}"#.utf8))
        XCTAssertEqual(d.op, "delete")
        XCTAssertEqual(d.id, "s_1")
        let t = try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"template","template":{"id":"tpl","name":"A","uses":2}}"#.utf8))
        XCTAssertEqual(t.template?.uses, 2)
    }
}
