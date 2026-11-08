import XCTest
@testable import MuseCore

/// "Import a video from a link" (WS6, 2026-11-08): link rules, the result's shapes, and demo mode's import.
final class LinkImportTests: XCTestCase {
    func testLinksFollowTheStrictRules() {
        XCTAssertNotNil(LinkImport.link("  https://www.tiktok.com/@a/video/123  ", strict: true))
        XCTAssertNil(LinkImport.link("https://vimeo.com/123", strict: true), "strict: the three platforms only")
        XCTAssertEqual(LinkImport.link("https://vimeo.com/123", strict: false), "https://vimeo.com/123")
        XCTAssertNil(LinkImport.link("ftp://example.com/a.mp4", strict: false))
        XCTAssertNil(LinkImport.link("not a link", strict: false))
    }

    func testWords() {
        XCTAssertEqual(LinkImport.hint(strict: true, limits: .init(maxSec: 60, maxMb: 80)),
                       "A public TikTok, Instagram or YouTube video, up to 60 s and 80 MB. It's fetched on this Mac.")
        XCTAssertEqual(LinkImport.name(title: "  Morning routine  ", platform: "tiktok"), "Morning routine")
        XCTAssertEqual(LinkImport.name(title: nil, platform: "tiktok"), "Tiktok video")
        XCTAssertNil(LinkImport.name(title: "", platform: nil))
    }

    func testResultDecodesNestedOrBare() throws {
        let clip = #"{"id":"clip_1","name":"Dance","durationSec":8,"width":720,"height":1280,"fps":30,"checks":[]}"#
        let bare = try JSONDecoder().decode(LinkImportResult.self, from: Data(clip.utf8))
        XCTAssertEqual(bare.clip?.id, "clip_1")
        let nested = try JSONDecoder().decode(LinkImportResult.self, from: Data(#"{"clip":\#(clip)}"#.utf8))
        XCTAssertEqual(nested.clip?.name, "Dance")
        XCTAssertNil(nested.take)
    }

    func testDemoImportGivesTheSwapAClip() async throws {
        let api = FakeMuseAPI()
        let r = try await api.importLink("https://www.instagram.com/reel/abc/", name: nil)
        XCTAssertNotNil(r.clip)
        XCTAssertEqual(r.clip?.name, "Instagram video")
        do {
            _ = try await api.importLink("https://example.com/v.mp4", name: nil)
            XCTFail("strict rules refuse other sites")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "link_unsupported")
            XCTAssertNotNil(RecreateLinkProblem(e), "shown with Recreate's words and the file offered")
        }
    }
}
