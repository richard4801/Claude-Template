import XCTest
@testable import MuseCore

/// The edit content library (WS8 84df583 / 929bcf2): the catalog decodes, its refs resolve, stickers and sound effects go
/// into an edit as valid library assets, and every in-house look, caption template and transition preset is valid.
final class EditContentTests: XCTestCase {
    typealias E = EditV2

    private func probe() -> E.Project { E.kitProbe }

    /// The server's own catalog, when this checkout has it (the Mac CI does): every preset item reads and is valid.
    private func serverCatalog() throws -> ContentCatalog? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../server/api/assets/content/catalog.json").standardized
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(ContentCatalog.self, from: d)
    }

    func testRefs() {
        XCTAssertEqual(ContentCatalog.ref(pack: "twemoji", item: "1f600"), "content:twemoji/1f600")
        XCTAssertEqual(ContentCatalog.parse("content:twemoji/1f600")?.0, "twemoji")
        XCTAssertEqual(ContentCatalog.parse("content:uisfx/glass-select")?.1, "glass-select")
        XCTAssertNil(ContentCatalog.parse("content:Twemoji/1f600"))
        XCTAssertNil(ContentCatalog.parse("content:twemoji"))
        XCTAssertNil(ContentCatalog.parse("music:calm"))
        let c = FakeMuseAPI.demoContent
        XCTAssertEqual(c.item(ref: "content:twemoji/1f600")?.item.name, "grinning face")
        XCTAssertNil(c.item(ref: "content:twemoji/nope"))
        XCTAssertEqual(c.fontFile(.inter, weight: 800), "fonts/inter_700.ttf")
        XCTAssertEqual(c.fontFile(.inter, weight: 950), "fonts/inter_900.ttf")
        XCTAssertEqual(c.fontFile(.inter, weight: 400), "fonts/inter_400.ttf")
        XCTAssertNil(c.fontFile(.sans, weight: 400))
        XCTAssertEqual(c.attributions.map(\.id), ["twemoji", "uisfx", "fonts"])
    }

    func testSearch() {
        let it = FakeMuseAPI.demoContent.packs(.stickers)[0].items[0]
        XCTAssertTrue(it.matches(""))
        XCTAssertTrue(it.matches("Happy grin"))
        XCTAssertTrue(it.matches("smileys"))
        XCTAssertFalse(it.matches("cat"))
    }

    func testCatalogRoundTrip() throws {
        let c = FakeMuseAPI.demoContent
        let back = try JSONDecoder().decode(ContentCatalog.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        // An unknown pack kind and an unreadable preset don't lose the catalog.
        let odd = #"{"version":"v","packs":[{"id":"x","kind":"shapes","title":"X","licence":"MUSE","items":[{"id":"a","name":"A","look":{"lut":5}}]}]}"#
        let o = try JSONDecoder().decode(ContentCatalog.self, from: Data(odd.utf8))
        XCTAssertEqual(o.packs[0].kind.rawValue, "shapes")
        XCTAssertNil(o.packs[0].items[0].lookValue)
    }

    func testStickerAndSoundAreValidLibraryAssets() throws {
        let c = FakeMuseAPI.demoContent
        var s = EditSuiteState(probe())
        s.playhead = 1
        let stickers = c.packs(.stickers)[0], sounds = c.packs(.sfx)[0]
        XCTAssertTrue(s.addContentSticker(stickers, stickers.items[0]))
        XCTAssertTrue(s.addContentSound(sounds, sounds.items[0]))
        // The same sticker again reuses its asset.
        XCTAssertTrue(s.addContentSticker(stickers, stickers.items[0]))
        let lib = s.project.assets.filter { $0.contentRef != nil }
        XCTAssertEqual(lib.map(\.library), ["content:twemoji/1f600", "content:uisfx/glass-select"])
        XCTAssertEqual(lib.map(\.kind), [.image, .audio])
        XCTAssertNil(E.problem(s.project))
        XCTAssertEqual(s.project.tracks.first { $0.kind == .sfx }?.items.count, 1)
        // Not a sticker or sound: no asset.
        XCTAssertNil(ContentCatalog.asset(pack: c.packs(.fonts)[0], item: c.packs(.fonts)[0].items[0], id: "f1"))
    }

    func testContentRefValidation() {
        var p = probe()
        p.assets.append(E.Asset(id: "s1", kind: .video, library: "content:twemoji/1f600", durationSec: 2))
        XCTAssertEqual(E.problem(p)?.field, "edits.assets.1.library")
        p.assets[1] = E.Asset(id: "s1", kind: .image, library: "content:Twemoji/1f600")
        XCTAssertEqual(E.problem(p)?.field, "edits.assets.1.library")
        p.assets[1] = E.Asset(id: "s1", kind: .image, library: "content:twemoji/1f600")
        XCTAssertNil(E.problem(p))
    }

    func testContentFonts() {
        var p = probe()
        XCTAssertTrue(p.contentFonts.isEmpty)
        let ti = p.tracks.firstIndex { $0.kind == .text }!
        if case .text(var tx) = p.tracks[ti].items[0] { tx.style.font = .montserrat; tx.style.weight = 900; p.tracks[ti].items[0] = .text(tx) }
        let ci = p.tracks.firstIndex { $0.kind == .caption }!
        p.tracks[ci].caption?.style.font = .caveat
        XCTAssertEqual(p.contentFonts, [.init(font: .montserrat, weight: 900), .init(font: .caveat, weight: ContentCatalog.fontWeight(p.tracks[ci].caption!.style.weight))])
        XCTAssertEqual(E.Font.montserrat.fallback, .sans)
        XCTAssertNil(E.problem(p))
    }

    func testPresetsAreValid() throws {
        var cats = [FakeMuseAPI.demoContent]
        if let server = try serverCatalog() { cats.append(server) }
        for c in cats {
            for pack in c.packs(.looks) {
                for it in pack.items {
                    let look = try XCTUnwrap(it.lookValue, "\(pack.id)/\(it.id)")
                    var p = probe()
                    if case .video(var v) = p.tracks[0].items[0] { v.look = look; p.tracks[0].items[0] = .video(v) }
                    XCTAssertNil(E.problem(p), "look \(it.id): \(E.problem(p).map { "\($0.field) \($0.message)" } ?? "")")
                }
            }
            for pack in c.packs(.captions) {
                for it in pack.items {
                    let st = try XCTUnwrap(it.captionStyle, "\(pack.id)/\(it.id)")
                    var s = EditSuiteState(probe())
                    XCTAssertTrue(s.applyCaptionTemplate(st), it.id)
                    XCTAssertEqual(s.captionStyle, st)
                }
            }
            for pack in c.packs(.transitions) {
                for it in pack.items {
                    let tr = try XCTUnwrap(it.transitionValue, "\(pack.id)/\(it.id)")
                    var s = EditSuiteState(probe())
                    s.selection = s.project.mainClips[1].id
                    XCTAssertTrue(s.setTransition(tr.kind, duration: tr.durationSec), it.id)
                    XCTAssertEqual(s.project.mainClips[1].transitionIn?.kind, tr.kind)
                }
            }
        }
    }

    func testServerCatalogShape() throws {
        guard let c = try serverCatalog() else { throw XCTSkip("no server catalog in this checkout") }
        XCTAssertFalse(c.packs(.stickers).isEmpty)
        XCTAssertFalse(c.packs(.sfx).isEmpty)
        // Every content font family of the contract is in the catalog, with its three weights.
        for f in E.Font.allCases where f.isContent {
            for w in [400, 700, 900] { XCTAssertNotNil(c.fontFile(f, weight: w), "\(f) \(w)") }
        }
        for pack in c.packs(.stickers) + c.packs(.sfx) {
            for it in pack.items.prefix(50) {
                XCTAssertNotNil(ContentCatalog.asset(pack: pack, item: it, id: "x"), "\(pack.id)/\(it.id)")
                XCTAssertNoThrow(try ContentFiles.local(it.file ?? "", version: c.version))
            }
        }
    }

    func testDemoFiles() async throws {
        let api = FakeMuseAPI()
        let c = FakeMuseAPI.demoContent
        let png = try await api.editorContentFile(c.packs(.stickers)[0].items[0].file!, version: c.version)
        XCTAssertEqual(try Data(contentsOf: png).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        let wav = try await api.editorContentFile(c.packs(.sfx)[0].items[0].file!, version: c.version)
        XCTAssertEqual(String(decoding: try Data(contentsOf: wav).prefix(4), as: UTF8.self), "RIFF")
        do { _ = try await api.editorContentFile("stickers/twemoji/nope.png", version: c.version); XCTFail("unknown file") } catch {}
        XCTAssertThrowsError(try ContentFiles.local("../etc/passwd", version: "v"))
    }
}
