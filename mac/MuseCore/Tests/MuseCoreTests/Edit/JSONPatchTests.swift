import XCTest
@testable import MuseCore

/// The JSON Patch port against the shared fixture (editor/jsonpatch.json): the same patches as the server, and both the patch
/// and its inverse round-trip.
final class JSONPatchTests: XCTestCase {
    private struct Case: Decodable {
        var name: String
        var a: JSONValue
        var b: JSONValue
        var patch: [EditPatchOp]
        var inverse: [EditPatchOp]
    }

    private func cases() throws -> [Case] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "jsonpatch", withExtension: "json", subdirectory: "Fixtures/editor"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testFixtureDiffApplyInverse() throws {
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 11)
        for c in all {
            XCTAssertEqual(JSONPatch.diff(c.a, c.b), c.patch, c.name)
            XCTAssertEqual(JSONPatch.diff(c.b, c.a), c.inverse, "\(c.name) (inverse)")
            XCTAssertTrue(JSONPatch.jsonEqual(try JSONPatch.apply(c.a, c.patch), c.b), c.name)
            XCTAssertTrue(JSONPatch.jsonEqual(try JSONPatch.apply(c.b, c.inverse), c.a), "\(c.name) (inverse)")
        }
    }

    func testPatchesEncodeLikeTheServer() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let s = String(decoding: try enc.encode([EditPatchOp.remove("/a"), .replace("/b", .null)]), as: UTF8.self)
        XCTAssertEqual(s, #"[{"op":"remove","path":"\/a"},{"op":"replace","path":"\/b","value":null}]"#)
        let back = try JSONDecoder().decode([EditPatchOp].self, from: Data(s.utf8))
        XCTAssertEqual(back[1].value, .null)
        XCTAssertNil(back[0].value)
    }

    func testKeysSortByUTF16AndBadPathsThrow() throws {
        // "\u{FF5E}" (BMP, high) sorts after "\u{1F600}" (a surrogate pair starting 0xD83D) in UTF-16 order.
        let a: JSONValue = .object([:])
        let b: JSONValue = .object(["\u{FF5E}": .number(1), "\u{1F600}": .number(2), "Z": .number(3), "a": .number(4)])
        XCTAssertEqual(JSONPatch.diff(a, b).map(\.path), ["/Z", "/a", "/\u{1F600}", "/\u{FF5E}"])
        XCTAssertThrowsError(try JSONPatch.apply(.object([:]), [.remove("/nope/x")]))
        XCTAssertThrowsError(try JSONPatch.apply(.array([.number(1)]), [.replace("/1", .null)]))
        XCTAssertThrowsError(try JSONPatch.apply(.object([:]), [.remove("")]))
        XCTAssertEqual(try JSONPatch.apply(.array([.number(1)]), [.add("/-", .number(2))]), .array([.number(1), .number(2)]))
    }
}
