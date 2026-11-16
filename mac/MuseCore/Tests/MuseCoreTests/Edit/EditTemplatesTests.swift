import XCTest
@testable import MuseCore

/// Edit templates (plans/edit-templates.md §5): the server's library decodes leniently, the panel's sections and filters,
/// where Apply goes (the selected clip, the cut before it, the cut nearest the playhead), the button titles with the price,
/// the apply request's JSON, and the demo library.
final class EditTemplatesTests: XCTestCase {
    typealias E = EditV2

    private let libraryJSON = """
    {"templates":[
      {"id":"window-open-next","name":"Window opens the next shot","description":"The next shot opens early.","kind":"transition","target":"cut","level":"live","state":"ready",
       "requires":[],"timing":"0.3 s before the cut","each":null,"params":[{"key":"shape","label":"Shape","type":"enum","options":["box","band","column","slats"],"default":"box"},
       {"key":"lead","label":"Opens before the cut","type":"number","unit":"s","min":0.1,"max":1,"default":0.3}],"paid":false,"preview":{"uploadId":"up_prev"},"reference":null,
       "by":"seed","source":{"pack":"icon-storyboard"},"version":1,"updatedAt":1},
      {"id":"glass-shatter","name":"Glass shatter","description":"Breaks like glass.","kind":"transition","target":"cut","level":"reference","state":"not_ready",
       "reason":"Ask Claude on the Mac to make it for this cut","params":[],"paid":false,"preview":null,"reference":{"uploadId":"up_ref"},"by":"seed","version":1,"updatedAt":1,"futureField":{"x":1}},
      {"id":"punch-in","name":"Punch-in","kind":"effect","target":"clip","level":"live","state":"ready","params":[],"by":"seed"},
      {"id":"quick-punch","name":"Quick punch","kind":"effect","target":"clip","level":"live","state":"ready","params":[],"by":"claude"}],
     "captionStyles":[{"id":"pop","name":"Word pop"},{"id":"karaoke","name":"Karaoke"}],"note":"…"}
    """

    private func project() throws -> E.Project {
        let json = """
        {"version":2,"sourceTakeId":"t1","canvas":{"width":1080,"height":1920,"fps":30},
         "assets":[{"id":"a","kind":"video","take":"t1","durationSec":20}],
         "tracks":[{"id":"main","kind":"main","items":[
           {"id":"c1","asset":"a","inSec":0,"outSec":2,"speed":1},{"id":"c2","asset":"a","inSec":4,"outSec":6,"speed":1},{"id":"c3","asset":"a","inSec":8,"outSec":10,"speed":1}]}]}
        """
        return try JSONDecoder().decode(E.Project.self, from: Data(json.utf8))
    }

    func testLibraryDecodesLenientlyWithPreviewsAndBadges() throws {
        let lib = try JSONDecoder().decode(EditTemplateLibrary.self, from: Data(libraryJSON.utf8))
        XCTAssertEqual(lib.templates.count, 4)
        let w = try XCTUnwrap(lib.templates.first)
        XCTAssertEqual(w.previewUpload, "up_prev")
        XCTAssertEqual(w.params.map(\.control), [.segmented, .slider])
        XCTAssertEqual(w.params[1].valueLabel(0.3), "0.3 s")
        XCTAssertNil(w.badge)
        let g = lib.templates[1]
        XCTAssertEqual(g.badge, "Not ready")
        XCTAssertEqual(g.referenceUpload, "up_ref")
        XCTAssertFalse(g.isReady)
        XCTAssertEqual(lib.captionStyles.map(\.name), ["Word pop", "Karaoke"])
        XCTAssertEqual(EditTemplateParam.optionLabel("easeOut"), "Ease out")
    }

    func testSectionsFilterAndSearch() throws {
        let lib = try JSONDecoder().decode(EditTemplateLibrary.self, from: Data(libraryJSON.utf8))
        let all = lib.sections(filter: .all, query: "")
        XCTAssertEqual(all.map(\.title), ["Yours", "Made by Claude"])
        XCTAssertEqual(all[1].items.map(\.id), ["punch-in", "window-open-next", "glass-shatter"]) // ready first, then by name
        XCTAssertEqual(lib.sections(filter: .transitions, query: "").flatMap(\.items).map(\.id), ["window-open-next", "glass-shatter"])
        XCTAssertEqual(lib.sections(filter: .effects, query: "punch").flatMap(\.items).count, 2)
        XCTAssertTrue(lib.sections(filter: .captions, query: "").isEmpty)
        XCTAssertEqual(lib.captionStyles(filter: .captions, query: "kara").map(\.id), ["karaoke"])
        XCTAssertTrue(lib.captionStyles(filter: .effects, query: "").isEmpty)
    }

    func testWhereApplyGoesAndItsTitle() throws {
        let p = try project()
        let cut = EditTemplate(id: "x", name: "X", target: "cut")
        // The selected clip: the cut before it.
        let a = try XCTUnwrap(EditTemplateTarget.current(for: cut, project: p, selection: "c3", playhead: 0))
        XCTAssertEqual(a.target, .cutAfter("c2"))
        XCTAssertEqual(a.title, "Cut at 0:04.0")
        XCTAssertEqual(a.detail, "Between clip 2 and clip 3")
        // Nothing selected: the cut nearest the playhead.
        XCTAssertEqual(EditTemplateTarget.current(for: cut, project: p, selection: nil, playhead: 2.4)?.target, .cutAfter("c1"))
        // A clip template: the selection, else the clip under the playhead.
        let clip = EditTemplate(id: "y", name: "Y", kind: "effect", target: "clip")
        XCTAssertEqual(EditTemplateTarget.current(for: clip, project: p, selection: nil, playhead: 5)?.target, .item("c3"))
        XCTAssertEqual(EditTemplateTarget.current(for: clip, project: p, selection: "c1", playhead: 5)?.title, "Clip 1")
        XCTAssertEqual(EditTemplateTarget.applyTitle("Cut at 0:21.7", priceUsd: nil), "Apply to cut at 0:21.7")
        XCTAssertEqual(EditTemplateTarget.applyTitle("Cut at 0:21.7", priceUsd: 0.82), "Apply to cut at 0:21.7 · $0.82")
        XCTAssertEqual(EditTemplateTarget.everyTitle(EditTemplate(id: "z", name: "Z", target: "cut", each: "note-cut"))?.title, "Apply to every cut on a note")
    }

    func testApplyRequestJSON() throws {
        let r = EditTemplateApplyRequest(sessionId: "es_1", target: .cutAfter("c2"), params: ["shape": .string("slats")], dryRun: true, device: "mac-1")
        let o = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(o, .object(["sessionId": .string("es_1"), "target": .object(["cutAfter": .string("c2")]), "params": .object(["shape": .string("slats")]),
                                   "dryRun": .bool(true), "device": .string("mac-1")]))
        let edit = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(EditTemplateApplyRequest(sessionId: "es_1", target: .edit, confirm: true)))
        XCTAssertEqual(edit, .object(["sessionId": .string("es_1"), "confirm": .bool(true)]))
        let res = try JSONDecoder().decode(EditTemplateApplyResult.self, from: Data(#"{"needsConfirmation":true,"estimateUsd":0.82,"cutOuts":1}"#.utf8))
        XCTAssertTrue(res.needsConfirmation)
        XCTAssertEqual(res.priceUsd, 0.82)
        XCTAssertThrowsError(try EditTemplateIds.check("../x"))
    }

    func testDemoLibraryAppliesAndRefusesNotReady() async throws {
        let api = FakeEditTemplateAPI()
        let lib = try await api.editTemplates()
        XCTAssertTrue(lib.templates.contains { !$0.isReady })
        let ok = try await api.applyEditTemplate("punch-in", EditTemplateApplyRequest(sessionId: "es_1", target: .item("c1")))
        XCTAssertTrue(ok.applied)
        let paid = try await api.applyEditTemplate("band-behind-subject", EditTemplateApplyRequest(sessionId: "es_1", target: .cutAfter("c1")))
        XCTAssertTrue(paid.needsConfirmation)
        do { _ = try await api.applyEditTemplate("glass-shatter", EditTemplateApplyRequest(sessionId: "es_1", target: .cutAfter("c1"))); XCTFail("applied a not-ready template") }
        catch let e as ApiError { XCTAssertEqual(e.code, "not_ready") }
        let saved = try await api.saveEditTemplate(EditTemplateSaveRequest(name: "My punch", kind: "effect", target: "clip", sessionId: "es_1", itemIds: ["c1"]))
        XCTAssertEqual(saved.template.by, "owner")
    }
}
