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
        // WS12's Import: a bare Clip with its source fields; the poster becomes the thumb.
        let imp = #"{"id":"imp_1","name":"Reel","durationSec":12,"width":720,"height":1280,"fps":30,"checks":[],"source":"import","sourceUrl":"https://www.instagram.com/reel/x/","platform":"instagram","bytes":1000,"posterUrl":"https://cdn/p.jpg","videoUrl":"https://cdn/v.mp4","videoKey":"imports/v.mp4","uploadId":"up_1","createdBy":"u1","createdAt":1,"cached":true}"#
        let i = try JSONDecoder().decode(LinkImportResult.self, from: Data(imp.utf8))
        XCTAssertEqual(i.clip?.id, "imp_1")
        XCTAssertEqual(i.clip?.thumb?.url, "https://cdn/p.jpg")
        XCTAssertEqual(i.videoKey, "imports/v.mp4")
        XCTAssertTrue(i.cached)
        let check = try JSONDecoder().decode(LinkImportCheck.self, from: Data(#"{"allowed":true,"url":"https://www.instagram.com/reel/x/","platform":"instagram","purpose":"import","cached":\#(imp)}"#.utf8))
        XCTAssertEqual(check.cached?.clip?.id, "imp_1")
        let no = try JSONDecoder().decode(LinkImportCheck.self, from: Data(#"{"allowed":false,"code":"too_long","reason":"Imports can be up to 30 s (this one is 42 s)"}"#.utf8))
        XCTAssertEqual(no.problem?.code, "too_long")
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
