import XCTest
@testable import MuseCore

/// The learning editor (plans/api.md "Learning editor"): the Mac's models decoded from JSON shaped exactly as workstream 3's
/// server answers (server/api/src/editor/learn.ts `ruleView`, `view`, `lessons`, `corrections`, `gaps`, and the cases in
/// server/api/test/learn.test.ts), the plain words the screens show, the id checks and the demo flows.
final class LearnTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Decoding the server's shapes

    func testDecodesRulesAsTheServerSendsThem() throws {
        // learn.test.ts: a rule with a correction whose id is a number, and Claude's unpinned rule.
        let rules = try decode([LearnRule].self, """
        [{"id":"rule_0a1b2c3d4e5f","text":"First cut by 0.8 s at most","area":"pacing","source":"claude","pinned":true,"evidence":[],"createdAt":1767225600000,"updatedAt":1767225700000},
         {"id":"rule_9f8e7d6c5b4a","text":"Captions above the chin","area":"captions","source":"owner","pinned":false,
          "evidence":[{"kind":"correction","id":1,"note":"moved 3 times","at":1767225600000},{"kind":"post","id":"p_1","note":"1.2k views","at":1767225600000}],
          "createdAt":1767225600000,"updatedAt":1767225600000}]
        """)
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules[0].pinned)
        XCTAssertEqual(rules[0].source, "claude")
        XCTAssertEqual(rules[1].evidence.first?.id, "1")
        XCTAssertEqual(rules[1].evidence.last?.id, "p_1")
        XCTAssertEqual(rules[1].evidence.first?.at, 1_767_225_600_000)
    }

    func testRulesDecodeLeniently() throws {
        let r = try decode(LearnRule.self, #"{"id":"rule_x","text":"No glitch transitions.","extra":true}"#)
        XCTAssertEqual(r.area, "other")
        XCTAssertEqual(r.source, "owner")
        XCTAssertFalse(r.pinned)
        XCTAssertTrue(r.evidence.isEmpty)
    }

    func testDecodesLessonsCorrectionsAndGaps() throws {
        let lessons = try decode([LearnLesson].self, """
        [{"area":"look","claudeChange":"Look","count":4,"undos":1,"last":1767225600000,"examples":["Changed the look after Claude's “Look Film”"],"ids":[4,3,2,1]},
         {"area":"text","claudeChange":"Add hook","count":1,"undos":1,"last":1767225500000,"examples":["Undid Claude's “Add hook”"],"ids":[5]}]
        """)
        XCTAssertEqual(lessons.map(\.count), [4, 1])
        XCTAssertEqual(lessons[0].ids, [4, 3, 2, 1])
        let corrections = try decode([LearnCorrection].self, """
        [{"id":7,"sessionId":"es_1","takeId":"take_1","opId":12,"claudeOpId":11,"kind":"undo","area":"text","what":"Undid Claude's “Add hook”",
          "context":{"claudeLabel":"Add hook “POV”","itemId":"h1"},"createdAt":1767225600000}]
        """)
        XCTAssertEqual(corrections.first?.id, 7)
        XCTAssertEqual(corrections.first?.kind, "undo")
        XCTAssertEqual(corrections.first?.takeId, "take_1")
        let gaps = try decode([LearnGap].self, """
        [{"key":"transition:unknown","kind":"transition","what":"Unknown transition","count":2,
          "examples":[{"recipeId":"rcp_1","referenceId":"rx_1","atSec":2.4,"note":"a spin","at":1},{"recipeId":"rcp_2","atSec":5.1,"note":"","at":2}],"firstAt":1,"lastAt":2},
         {"key":"effect:lens-flare","kind":"effect","what":"Lens flare","count":1,"examples":[{"recipeId":"ask_1767225600000","note":"when she turns","at":3}],"firstAt":3,"lastAt":3}]
        """)
        XCTAssertEqual(gaps.map(\.count), [2, 1])
        XCTAssertEqual(gaps[0].examples.map(\.atSec), [2.4, 5.1])
        XCTAssertEqual(LearnText.gap(gaps[0]), "Unknown transition · 2 references")
        XCTAssertEqual(LearnText.gap(gaps[1]), "Lens flare · asked once")
    }

    func testDecodesARecipeEntryWithPerformanceAndItsBody() throws {
        // learn.ts `view`: performance from Posts (learn.test.ts: 1200 views, 80 likes, 4 comments, 12 saves, 6.5 s, 42%).
        let e = try decode(LearnRecipe.self, """
        {"id":"rcp_5d4c3b2a1f0e","origin":"edit","referenceId":null,"takeId":"take_edit1","name":"Café cut","summary":"","tags":["own-edit","short","text"],
         "features":{"durationSec":8,"shots":3,"cutsPerMin":15,"avgShotSec":2.7,"bpm":120,"energy":0.5,"text":1,"fancyTransitions":1,"warmth":0.3,"saturation":0.5,"contrast":0.5},
         "performance":{"posts":1,"views":1200,"likes":80,"comments":4,"saves":12,"avgWatchSec":6.5,"completion":0.42},"createdAt":1767225600000,"updatedAt":1767225600000}
        """)
        XCTAssertFalse(e.isReference)
        XCTAssertNil(e.recipe)
        XCTAssertEqual(e.performance?.views, 1200)
        XCTAssertEqual(e.performance?.saves, 12)
        XCTAssertEqual(e.durationSec, 8)
        XCTAssertEqual(e.cuts, 2)
        XCTAssertEqual(LearnText.badge(e), "8 s · 2 cuts")
        XCTAssertEqual(LearnText.tileCaption(e), "1.2k views · 42% completion")
        XCTAssertEqual(LearnText.performance(e.performance!).map { "\($0.0) \($0.1)" },
                       ["Views 1.2k", "Likes 80", "Saves 12", "Avg watch 6.5 s", "Completion 42%", "Posts 1"])

        // The detail carries the `muse.recipe/1` body; a reference's performance is null.
        let ref = try decode(RecreateReference.self, RecreateDemo.referenceJSON)
        let body = try XCTUnwrap(ref.recipe)
        let bodyJSON = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        let detail = try decode(LearnRecipe.self, """
        {"id":"rcp_ref","origin":"reference","referenceId":"rx_demo","takeId":null,"name":"Summer cut","summary":"Three beats","tags":["reference"],
         "features":{},"performance":null,"createdAt":1,"updatedAt":1,"recipe":\(bodyJSON)}
        """)
        XCTAssertTrue(detail.isReference)
        XCTAssertNil(detail.performance)
        XCTAssertEqual(detail.recipe?.slots.count, 3)
        XCTAssertEqual(LearnText.shape(try XCTUnwrap(detail.recipe)), "3 shots · 27 cuts/min · 120 bpm · 1 text item")
        XCTAssertEqual(detail.cuts, 2)
    }

    func testDecodesNearest() throws {
        let n = try decode(LearnNearest.self, """
        {"recipeId":"rcp_a","nearest":[{"id":"rcp_b","origin":"reference","name":"Outfit flip","tags":[],"features":{},"performance":null,"createdAt":2,"updatedAt":2,"distance":0.21},
                                      {"id":"rcp_c","origin":"edit","name":"Café cut","tags":[],"features":{},"performance":null,"createdAt":1,"updatedAt":1,"distance":0.74}]}
        """)
        XCTAssertEqual(n.nearest.map(\.name), ["Outfit flip", "Café cut"])
        XCTAssertEqual(n.nearest.map { LearnText.closeness($0.distance) }, ["Very close", "Different"])
        XCTAssertEqual(LearnText.closeness(0.45), "Close")
    }

    // MARK: Plain words

    func testLessonSentenceIsPlain() {
        XCTAssertEqual(LearnText.sentence(LearnLesson(area: "look", claudeChange: "Look", count: 4, undos: 1)), "You changed Claude's look 4 times")
        XCTAssertEqual(LearnText.sentence(LearnLesson(area: "transition", claudeChange: "Add transition", count: 2, undos: 2)), "You undid Claude's transitions twice")
        XCTAssertEqual(LearnText.sentence(LearnLesson(area: "captions", count: 1)), "You changed Claude's captions once")
        XCTAssertEqual(LearnText.sentence(LearnLesson(area: "motion", count: 3)), "You changed Claude's camera moves 3 times")
        XCTAssertEqual(LearnText.sentence(LearnLesson(area: "audio", count: 5)), "You changed Claude's sound 5 times")
    }

    func testBylinesAndEvidenceLines() {
        let now: Int64 = 10 * LearnDemo.day
        XCTAssertEqual(LearnText.byline(LearnRule(id: "rule_a", text: "x")), "Yours")
        let claude = LearnRule(id: "rule_b", text: "x", source: "claude", evidence: (0..<3).map { LearnEvidence(kind: "correction", id: "\($0)", note: "n") })
        XCTAssertEqual(LearnText.byline(claude), "From Claude · 3 corrections")
        let learned = LearnRule(id: "rule_c", text: "x", source: "learned", evidence: [LearnEvidence(kind: "post", note: "a"), LearnEvidence(kind: "post", note: "b")])
        XCTAssertEqual(LearnText.byline(learned), "Learned · 2 posts")
        XCTAssertEqual(LearnText.byline(LearnRule(id: "rule_d", text: "x", source: "claude", evidence: [LearnEvidence(kind: "correction", note: "a")])), "From Claude · 1 correction")
        let e = LearnEvidence(kind: "correction", id: "31", note: "Changed the look after Claude's “Look Film”", at: now - 2 * LearnDemo.day)
        XCTAssertEqual(LearnText.evidence(e, now: now), "Correction · Changed the look after Claude's “Look Film” · 2 days ago")
        XCTAssertEqual(LearnText.evidence(LearnEvidence(kind: "note", note: "Keeps her face clear", at: now - LearnDemo.hour), now: now), "Note · Keeps her face clear · 1 h ago")
        XCTAssertEqual(LearnText.relative(now - 30 * LearnDemo.hour, now: now), "Yesterday")
        XCTAssertEqual(LearnText.relative(now, now: now), "Just now")
        XCTAssertEqual(LearnText.area("audio"), "Sound")
        XCTAssertEqual(LearnText.area("ratio"), "Shape")
        XCTAssertEqual(LearnText.area("transition"), "Transitions")
    }

    func testCounterAppearsFrom250Characters() {
        XCTAssertNil(LearnText.counter(String(repeating: "a", count: 249)))
        XCTAssertEqual(LearnText.counter(String(repeating: "a", count: 280)), "280 / 300")
    }

    func testCompactNumbers() {
        XCTAssertEqual(LearnText.compact(860), "860")
        XCTAssertEqual(LearnText.compact(1200), "1.2k")
        XCTAssertEqual(LearnText.compact(1000), "1k")
        XCTAssertEqual(LearnText.compact(12_400), "12k")
        XCTAssertEqual(LearnText.compact(1_400_000), "1.4M")
    }

    func testTransitionIcons() {
        XCTAssertNil(LearnText.transitionIcon("cut"))
        XCTAssertEqual(LearnText.transitionIcon("whip"), "wind")
        XCTAssertEqual(LearnText.transitionIcon("crossfade"), "intersect")
        XCTAssertEqual(LearnText.transitionIcon("something new"), "question")
    }

    // MARK: Filtering and grouping

    func testFilterMatchesTheServer() async throws {
        let all = try await FakeLearnAPI().recipes(limit: 200)
        XCTAssertEqual(all.map(\.createdAt), all.map(\.createdAt).sorted(by: >))
        XCTAssertEqual(LearnFilter.apply(all, query: "outfit", origin: .all, tags: [], sort: .newest).map(\.name).sorted(), ["Café counter", "Living room dance", "Mirror outfit swap"])
        XCTAssertEqual(LearnFilter.apply(all, query: "", origin: .reference, tags: [], sort: .newest).map(\.origin).allSatisfy { $0 == "reference" }, true)
        XCTAssertEqual(LearnFilter.apply(all, query: "", origin: .all, tags: ["dance", "FAST-CUTS"], sort: .newest).map(\.name).sorted(), ["Living room dance", "Summer cut"])
        let viewed = LearnFilter.apply(all, query: "", origin: .edit, tags: [], sort: .mostViewed)
        XCTAssertEqual(viewed.first?.name, "Café counter")
        XCTAssertTrue(LearnFilter.apply(all, query: "dance zebra", origin: .all, tags: [], sort: .newest).isEmpty)
        let top = LearnFilter.topTags(all)
        XCTAssertLessThanOrEqual(top.count, 8)
        XCTAssertFalse(top.contains("reference"))
        XCTAssertFalse(top.contains("own-edit"))
        XCTAssertEqual(LearnFilter.cleanTag("  Golden Hour "), "golden hour")
        XCTAssertNil(LearnFilter.cleanTag("   "))
    }

    func testPlaybookGroupsInTheScreensOrder() async throws {
        let rules = try await FakeLearnAPI().playbook()
        let groups = LearnFilter.grouped(rules)
        XCTAssertEqual(groups.map(\.area), ["captions", "pacing", "transition", "look", "audio"])
        for g in groups { XCTAssertEqual(g.rules.map(\.pinned), g.rules.map(\.pinned).sorted { $0 && !$1 }) }
        // Several areas, pinned rules, Claude's and learned ones.
        XCTAssertTrue(rules.contains { $0.pinned })
        XCTAssertTrue(rules.contains { $0.source == "claude" && !$0.pinned })
        XCTAssertTrue(rules.contains { $0.source == "learned" })
        XCTAssertTrue(rules.contains { $0.text.count > Learn.counterFrom })
    }

    // MARK: Ids

    func testIdsAreCheckedBeforeURLs() {
        XCTAssertNoThrow(try LearnIds.rule("rule_0a1b2c3d4e5f"))
        XCTAssertNoThrow(try LearnIds.recipe("rcp_5d4c3b2a1f0e"))
        for bad in ["", "rule_", "rule_../x", "rcp_1", "rule_a/b", "rule_a?x=1", "RULE_a"] { XCTAssertThrowsError(try LearnIds.rule(bad), bad) }
        for bad in ["", "rcp_", "rcp_a b", "rule_1", "rcp_x/../../v1"] { XCTAssertThrowsError(try LearnIds.recipe(bad), bad) }
        XCTAssertEqual(LearnIds.posterPath(referenceId: "rx_demo"), "/v1/recreate/references/rx_demo/poster")
        XCTAssertNil(LearnIds.posterPath(referenceId: "../etc"))
    }

    func testFakeRefusesBadIds() async {
        let api = FakeLearnAPI()
        do { _ = try await api.recipe("rcp_../x"); XCTFail("accepted a bad id") } catch {}
        do { try await api.deleteRule("nope"); XCTFail("accepted a bad id") } catch {}
    }

    // MARK: Demo flows

    func testRuleFlow() async throws {
        let api = FakeLearnAPI()
        let before = try await api.playbook().count
        let r = try await api.addRule(LearnRuleRequest(text: "  Never cut on the vocal.  ", area: "pacing",
                                                       evidence: [LearnEvidence(kind: "correction", id: "41", note: "Trimmed the first shot")]))
        XCTAssertEqual(r.text, "Never cut on the vocal.")
        XCTAssertEqual(r.source, "owner")
        XCTAssertFalse(r.pinned)
        XCTAssertNotNil(r.evidence.first?.at)
        let pinned = try await api.patchRule(r.id, LearnRuleRequest(pinned: true))
        XCTAssertTrue(pinned.pinned)
        XCTAssertEqual(pinned.text, r.text)
        let list = try await api.playbook()
        XCTAssertEqual(list.count, before + 1)
        XCTAssertEqual(list.prefix { $0.pinned }.count, list.filter(\.pinned).count, "pinned first")
        try await api.deleteRule(r.id)
        let after = try await api.playbook()
        XCTAssertEqual(after.count, before)
        do { _ = try await api.addRule(LearnRuleRequest(text: "   ")); XCTFail("empty rule saved") } catch {}
        do { _ = try await api.addRule(LearnRuleRequest(text: String(repeating: "a", count: 301))); XCTFail("301 characters saved") } catch {}
        do { _ = try await api.addRule(LearnRuleRequest(text: "x", area: "vibes")); XCTFail("unknown area saved") } catch {}
    }

    func testPlaybookHoldsAtMost200Rules() async throws {
        let api = FakeLearnAPI()
        api.fillPlaybook()
        let rules = try await api.playbook()
        XCTAssertEqual(rules.count, Learn.maxRules)
        do { _ = try await api.addRule(LearnRuleRequest(text: "One more")); XCTFail("201st rule saved") } catch {}
    }

    func testRecipeFlow() async throws {
        let api = FakeLearnAPI()
        let all = try await api.recipes(limit: 200)
        XCTAssertTrue(all.allSatisfy { $0.recipe == nil }, "the list carries no body")
        XCTAssertTrue(all.contains { $0.name == "Summer cut" && $0.referenceId == "rx_demo" }, "Recreate's demo reference is in the library")
        XCTAssertTrue(all.contains { $0.isReference })
        XCTAssertTrue(all.contains { !$0.isReference && $0.performance != nil })
        let dance = try XCTUnwrap(all.first { $0.name == "Living room dance" })
        let full = try await api.recipe(dance.id)
        XCTAssertEqual(full.recipe?.slots.count, 9)
        XCTAssertEqual(full.recipe?.grade?.swatches?.count, 5)
        let renamed = try await api.patchRecipe(dance.id, LearnRecipePatch(name: "Living room dance v2", tags: ["Dance", "dance", "  hook "]))
        XCTAssertEqual(renamed.name, "Living room dance v2")
        XCTAssertEqual(renamed.tags, ["dance", "hook"])
        let near = try await api.nearest(recipeId: dance.id, k: 3)
        XCTAssertEqual(near.nearest.count, 3)
        XCTAssertFalse(near.nearest.contains { $0.id == dance.id })
        XCTAssertEqual(near.nearest.compactMap(\.distance), near.nearest.compactMap(\.distance).sorted())
        try await api.deleteRecipe(dance.id)
        let left = try await api.recipes(limit: 200)
        XCTAssertEqual(left.count, all.count - 1)
        let gaps = try await api.gaps(limit: 10)
        XCTAssertFalse(gaps.isEmpty)
        XCTAssertEqual(gaps.map(\.count), gaps.map(\.count).sorted(by: >), "most requested first")
    }

    func testFakeEmptyAndOffline() async throws {
        let empty = FakeLearnAPI(empty: true)
        let rules = try await empty.playbook()
        let recipes = try await empty.recipes(limit: 50)
        XCTAssertTrue(rules.isEmpty)
        XCTAssertTrue(recipes.isEmpty)
        let api = FakeLearnAPI()
        api.failNext = true
        do { _ = try await api.playbook(); XCTFail("no error") } catch {}
        let back = try await api.playbook()
        XCTAssertFalse(back.isEmpty, "only the next call fails")
    }

    func testRequestsSendOnlyWhatIsSet() throws {
        let pin = String(decoding: try JSONEncoder().encode(LearnRuleRequest(pinned: true)), as: UTF8.self)
        XCTAssertEqual(pin, #"{"pinned":true}"#)
        let patch = String(decoding: try JSONEncoder().encode(LearnRecipePatch(name: "A")), as: UTF8.self)
        XCTAssertEqual(patch, #"{"name":"A"}"#)
    }
}
