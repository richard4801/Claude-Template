import Foundation
import XCTest
@testable import MuseCore

/// ci_7972a1d67e72: several takes downloaded from the Library each get their own readable file; nothing is overwritten.
final class SaveFileNameTests: XCTestCase {
    func take(_ id: String, index: Int, title: String = "Mia · Living-room dance", prompt: String = "") -> Take {
        Take(id: id, kind: "take", index: index, of: 2, title: title, label: "Draft", thumb: ImageRef(), prompt: prompt, createdAt: 1_763_000_000_000)
    }

    func testSlugAndShortId() {
        XCTAssertEqual(SaveFileName.slug("Mia · Living-room dance!"), "mia-living-room-dance")
        XCTAssertEqual(SaveFileName.slug(String(repeating: "a", count: 50)), String(repeating: "a", count: 40))
        XCTAssertEqual(SaveFileName.slug("  "), "")
        XCTAssertEqual(SaveFileName.shortId("s_9381c89cde04"), "s9381c89c")
    }

    func testTakesOfOneShotGetDifferentReadableNames() {
        let a = SaveFileName.forTake(take("take_v1", index: 1), ext: "mp4")
        let b = SaveFileName.forTake(take("take_v2", index: 2), ext: "mp4")
        XCTAssertEqual(a, "mia-living-room-dance-takev1-1.mp4") // the server's save_to_mac names it the same way
        XCTAssertEqual(b, "mia-living-room-dance-takev2-2.mp4")
        XCTAssertNotEqual(a, b)
        // No title: the prompt; neither: "muse".
        XCTAssertEqual(SaveFileName.base(title: "", prompt: "Waves on a pier", id: "s_1"), "waves-on-a-pier-s1")
        XCTAssertEqual(SaveFileName.base(title: "", prompt: "", id: "s_1"), "muse-s1")
        XCTAssertEqual(SaveFileName.base(title: "Pier", id: "", index: 3, date: 0), "pier-3")
    }

    func testSanitizedNeverEscapesTheFolder() {
        XCTAssertEqual(SaveFileName.sanitized("a/b:c.mp4"), "a-b-c.mp4")
        XCTAssertEqual(SaveFileName.sanitized("..hidden.mp4"), "hidden.mp4")
        XCTAssertEqual(SaveFileName.sanitized(""), "muse")
        XCTAssertEqual(SaveFileName.sanitized(String(repeating: "x", count: 300) + ".mp4").count, 124)
    }

    func testUniqueAddsANumberAndNeverReturnsAnExistingFile() {
        var disk: Set<String> = []
        let first = SaveFileName.unique("clip.mp4", in: "/Users/me/Downloads/MUSE/", exists: { disk.contains($0) })
        XCTAssertEqual(first, "/Users/me/Downloads/MUSE/clip.mp4")
        disk.insert(first)
        XCTAssertEqual(SaveFileName.unique("clip.mp4", in: "/Users/me/Downloads/MUSE", exists: { disk.contains($0) }), "/Users/me/Downloads/MUSE/clip (2).mp4")
        disk.insert("/Users/me/Downloads/MUSE/clip (2).mp4")
        XCTAssertEqual(SaveFileName.unique("clip.mp4", in: "/Users/me/Downloads/MUSE", exists: { disk.contains($0) }), "/Users/me/Downloads/MUSE/clip (3).mp4")
        XCTAssertEqual(SaveFileName.unique("notes", in: "/d", exists: { $0 == "/d/notes" }), "/d/notes (2)")
    }

    func testMoveUniqueKeepsEveryDownload() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("muse-save-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        var saved: [URL] = []
        for n in 1...3 {
            let tmp = fm.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Data("take \(n)".utf8).write(to: tmp)
            saved.append(try SaveFileName.moveUnique(tmp, named: "mia-take.mp4", into: dir))
        }
        XCTAssertEqual(saved.map(\.lastPathComponent), ["mia-take.mp4", "mia-take (2).mp4", "mia-take (3).mp4"])
        XCTAssertEqual(try saved.map { try String(contentsOf: $0, encoding: .utf8) }, ["take 1", "take 2", "take 3"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).count, 3)
    }
}
