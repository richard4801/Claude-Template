import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the composer's rendered previews — decoding `preview` / `autoPreviews` (with defaults for
/// older catalogs) and where a `previews/` path lives in the app bundle.
final class SuitePreviewTests: XCTestCase {
    private var cat: CameraCatalog { SuiteDemoCatalog.catalog.camera }

    func testPreviewsDecodeFromTheCatalog() throws {
        let dolly = try XCTUnwrap(cat.move("dolly_in"))
        XCTAssertEqual(dolly.preview, SuitePreview(video: "moves/dolly_in.mp4", poster: "moves/dolly_in.jpg", seconds: 2.5))
        XCTAssertNil(cat.move("motion_blur")?.preview, "no loop yet: the drawn still stays")
        XCTAssertNil(cat.move("rise_reveal")?.preview, "no loop yet: the drawn still stays")
        XCTAssertEqual(cat.moves.filter { $0.preview != nil }.count, cat.moves.count - 2)
        XCTAssertEqual(PromptTokens.searchMoves(cat, "pedestal").first?.id, "rise_reveal")
        XCTAssertTrue(try XCTUnwrap(cat.tempos.first { $0.id == "single_shot" }).matches("single shot"))
        XCTAssertTrue(cat.lighting.allSatisfy { $0.preview?.poster.hasPrefix("lighting/") == true })
        XCTAssertTrue(cat.heights.allSatisfy { $0.preview?.poster.hasPrefix("angles/") == true })
        XCTAssertTrue(cat.shotSizes.allSatisfy { $0.preview?.poster.hasPrefix("angles/") == true })
        XCTAssertEqual(cat.autoPreviews.lighting?.poster, "lighting/auto.jpg")
        // Older catalogs: no previews, no autoPreviews.
        let old = try JSONDecoder().decode(CameraCatalog.self, from: Data(#"{"moves":[{"id":"dolly_in","label":"Dolly in","category":"push"}],"lighting":[{"id":"window","label":"Window"}]}"#.utf8))
        XCTAssertNil(old.moves.first?.preview)
        XCTAssertNil(old.lighting.first?.preview)
        XCTAssertNil(old.autoPreviews.lighting)
        // A preview without a poster decodes to an empty one, which the tiles ignore.
        let bare = try JSONDecoder().decode(SuitePreview.self, from: Data(#"{"video":"moves/x.mp4"}"#.utf8))
        XCTAssertEqual(bare.poster, "")
    }

    func testTilesUseTheirPreviews() throws {
        let dolly = try XCTUnwrap(cat.move("dolly_in"))
        let p = PickerPreview.move(dolly)
        XCTAssertEqual(p.video, "moves/dolly_in.mp4")
        XCTAssertEqual(p.poster, "moves/dolly_in.jpg")
        XCTAssertTrue(p.hasRender)
        let blur = try XCTUnwrap(cat.move("motion_blur"))
        XCTAssertFalse(PickerPreview.move(blur).hasRender)
        XCTAssertEqual(PickerPreview.move(blur).still, PickerPreview.neutralMoveStill)
        let light = try XCTUnwrap(cat.lighting.first)
        XCTAssertEqual(PickerPreview.option(light).poster, light.preview?.poster)
        XCTAssertEqual(PickerPreview.option(light).still, light.render)
        XCTAssertEqual(PickerPreview.auto(cat.autoPreviews.lighting)?.poster, "lighting/auto.jpg")
        XCTAssertNil(PickerPreview.auto(nil))
        XCTAssertNil(PickerPreview.auto(SuitePreview(poster: "")))
    }

    func testBundledPathMapping() throws {
        let m = try XCTUnwrap(PickerPreview.bundled("moves/dolly_in.mp4"))
        XCTAssertEqual(m.subdirectory, "previews/moves")
        XCTAssertEqual(m.name, "dolly_in")
        XCTAssertEqual(m.ext, "mp4")
        let l = try XCTUnwrap(PickerPreview.bundled("lighting/auto.jpg"))
        XCTAssertEqual(l.subdirectory, "previews/lighting")
        XCTAssertEqual(l.name, "auto")
        XCTAssertEqual(PickerPreview.bundled("/previews/angles/eye")?.subdirectory, "previews/angles")
        XCTAssertEqual(PickerPreview.bundled("/previews/angles/eye")?.ext, "jpg")
        XCTAssertEqual(PickerPreview.bundled("eye.jpg")?.subdirectory, "previews")
        XCTAssertNil(PickerPreview.bundled("https://x/moves/a.mp4"))
        XCTAssertNil(PickerPreview.bundled(""))
        XCTAssertNil(PickerPreview.bundled(nil))
    }
}
