import XCTest
@testable import MuseCore

/// Style kits (Swift port of kit.ts, WS8 81fa2f3): kitOf, applyKit and validateKit give the reference's answers
/// (functions.json → kits).
final class EditV2KitTests: XCTestCase {
    typealias E = EditV2
    private var k: JV { (try? editorFixture("functions"))?["kits"] ?? .null }
    private var projects: [JV] { (try? editorFixture("projects"))?.array ?? [] }

    func testKitOfEveryProject() throws {
        let cases = k["kitOf"].array
        XCTAssertEqual(cases.count, projects.count)
        for c in cases {
            let entry = try XCTUnwrap(projects.first { $0["name"] == c["name"] }, "\(c["name"])")
            let p = try entry["project"].decode(E.Project.self)
            let d = jsonDiff(try JV.of(E.kitOf(p)), c["kit"])
            XCTAssert(d.isEmpty, "kitOf \(c["name"]): " + d.prefix(5).joined(separator: "; "))
        }
    }

    func testApplyKit() throws {
        let kits = try k["kits"].array.map { try $0.decode(E.StyleKit.self) }
        XCTAssertEqual(kits.count, 3)
        let cases = k["apply"].array
        XCTAssertGreaterThanOrEqual(cases.count, 9)
        for c in cases {
            let pi = Int(c["project"].double!), ki = Int(c["kit"].double!)
            let p = try projects[pi]["project"].decode(E.Project.self)
            let d = jsonDiff(try JV.of(E.applyKit(p, kits[ki])), c["result"])
            XCTAssert(d.isEmpty, "applyKit project \(pi) × kit \(ki): " + d.prefix(5).joined(separator: "; "))
        }
    }

    func testValidateKit() throws {
        let cases = k["validate"].array
        XCTAssertEqual(cases.count, 15)
        for c in cases {
            let json = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(c["kit"]))
            do {
                _ = try E.validateKit(json)
                XCTAssertTrue(c["field"].isNull, "\(c["kit"]) should be refused at \(c["field"])")
            } catch let e as E.EditProblem {
                XCTAssertEqual(e.field, c["field"].string, "\(c["kit"]): \(e)")
            }
        }
    }

    func testPartsLabel() {
        XCTAssertEqual(E.StyleKit(look: E.Look(lift: 0.1), adjust: E.Adjust(tint: 0.1), transition: E.Transition(kind: .fade, durationSec: 0.5)).partsLabel,
                       "Look, colour, transition")
        XCTAssertEqual(E.StyleKit().partsLabel, "Nothing yet")
    }

    func testFakeKitsRoundTrip() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0)
        let kit = E.StyleKit(adjust: E.Adjust(contrast: 0.2), transition: E.Transition(kind: .fade, durationSec: 0.5))
        let a = try await api.saveEditKit(name: "  Warm reels  ", kit: kit)
        XCTAssertEqual(a.name, "Warm reels")
        let b = try await api.saveEditKit(name: "Second", kit: E.StyleKit(fill: .blur))
        let list = try await api.editKits()
        XCTAssertEqual(list.map(\.id), [b.id, a.id], "newest first")
        let renamed = try await api.updateEditKit(id: a.id, name: "Warm", kit: nil)
        XCTAssertEqual(renamed.name, "Warm")
        XCTAssertEqual(renamed.kit, kit)
        do { _ = try await api.saveEditKit(name: "", kit: kit); XCTFail("empty name") } catch {}
        do { _ = try await api.saveEditKit(name: "Bad", kit: E.StyleKit(version: 2)); XCTFail("version 2") } catch {}
        try await api.deleteEditKit(id: a.id)
        let left = try await api.editKits()
        XCTAssertEqual(left.map(\.id), [b.id])
    }
}
