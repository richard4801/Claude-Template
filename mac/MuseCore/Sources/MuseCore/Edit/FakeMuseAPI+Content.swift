import Foundation

// The edit content library in demo mode: a small catalog of each kind (the in-house presets as on the server), stickers
// drawn as a dot, sound effects as short tones (WAV), and no font files (text draws in each family's bundled fallback).
extension FakeMuseAPI {
    public func editorContent() throws -> ContentCatalog? { Self.demoContent }

    public func editorContentFile(_ path: String, version: String) throws -> URL {
        guard Self.demoContent.packs.contains(where: { $0.items.contains { $0.file == path } }) else { throw ApiError("not_found", "Content file not found") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("MUSE-demo-content", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = path.replacingOccurrences(of: "/", with: "_")
        if path.hasSuffix(".png") {
            let f = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: f.path) { try Data(base64Encoded: Self.demoStickerPng)!.write(to: f) }
            return f
        }
        let f = dir.appendingPathComponent((name as NSString).deletingPathExtension + ".wav")
        if !fm.fileExists(atPath: f.path) { try Self.tone(seconds: 0.5, hz: 660).write(to: f) }
        return f
    }

    static let demoStickerPng = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAMklEQVR4nGNgoDb4f4ThPz5MkWa8hhCrGashpGrGMGTUgGFhAMUJiSpJmVhD8GomBwAAASTaaDQe0zoAAAAASUVORK5CYII="

    /// A mono 16-bit WAV of a sine tone that fades out.
    static func tone(seconds: Double, hz: Double, rate: Int = 22050) -> Data {
        let n = Int(seconds * Double(rate))
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            var s = Int16(sin(2 * .pi * hz * t) * (1 - t / seconds) * 9000).littleEndian
            d.append(Data(bytes: &s, count: 2))
        }
        return d
    }

    static let demoContent: ContentCatalog = {
        typealias I = ContentItem
        func sticker(_ id: String, _ name: String, _ cat: String, _ tags: [String]) -> I {
            I(id: id, name: name, category: cat, tags: tags, file: "stickers/twemoji/\(id).png", width: 160, height: 160, bytes: 2000)
        }
        func sfx(_ id: String, _ name: String, _ cat: String) -> I {
            I(id: id, name: name, category: cat, tags: [cat], file: "sfx/uisfx/\(id).m4a", durationSec: 0.5, bytes: 9000)
        }
        func json(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }
        let fonts = EditV2.Font.allCases.filter(\.isContent).map { f in
            I(id: f.rawValue, name: f.label, files: ["400": "fonts/\(f.rawValue)_400.ttf", "700": "fonts/\(f.rawValue)_700.ttf", "900": "fonts/\(f.rawValue)_900.ttf"],
              scripts: ["latin", "latin-ext", "cyrillic"])
        }
        return ContentCatalog(version: "demo1", packs: [
            ContentPack(id: "twemoji", kind: .stickers, title: "Emoji", licence: "CC-BY-4.0",
                        attribution: "Twemoji graphics by Twitter, Inc. and other contributors, licensed under CC BY 4.0.",
                        categories: [.init(id: "smileys", label: "Smileys"), .init(id: "animals", label: "Animals"), .init(id: "symbols", label: "Symbols")],
                        items: [sticker("1f600", "grinning face", "smileys", ["happy", "smile"]), sticker("1f602", "face with tears of joy", "smileys", ["laugh"]),
                                sticker("1f60d", "smiling face with heart-eyes", "smileys", ["love"]), sticker("1f431", "cat face", "animals", ["cat", "pet"]),
                                sticker("1f436", "dog face", "animals", ["dog", "pet"]), sticker("2764", "red heart", "symbols", ["love", "heart"]),
                                sticker("2b50", "star", "symbols", ["star"]), sticker("1f525", "fire", "symbols", ["fire", "hot"])]),
            ContentPack(id: "uisfx", kind: .sfx, title: "Sound effects", licence: "CC0-1.0", attribution: "UI SFX by Romain Simon (uisfx), CC0 1.0.",
                        categories: [.init(id: "cinematic", label: "Cinematic"), .init(id: "glass", label: "Glass")],
                        items: [sfx("glass-select", "Select", "glass"), sfx("glass-open", "Open", "glass"), sfx("cine-whoosh", "Whoosh", "cinematic"),
                                sfx("cine-hit", "Hit", "cinematic")]),
            ContentPack(id: "fonts", kind: .fonts, title: "Fonts", licence: "OFL-1.1",
                        attribution: "Fonts from Google Fonts under the SIL Open Font License 1.1.", items: fonts),
            ContentPack(id: "muse-looks", kind: .looks, title: "More looks", licence: "MUSE", categories: [.init(id: "film", label: "Film"), .init(id: "bw", label: "B&W")],
                        items: [I(id: "super8", name: "Super 8", category: "film",
                                  look: json(##"{"lut":"pack:film-gold","strength":0.85,"grain":{"amount":0.55,"size":2},"vignette":{"amount":0.45,"size":0.35,"softness":0.6},"lift":0.25}"##)),
                                I(id: "ink", name: "Ink", category: "bw",
                                  look: json(##"{"lut":"pack:bw-contrast","strength":1,"curves":{"rgb":[[0,0],[0.35,0.22],[0.65,0.8],[1,1]]},"grain":{"amount":0.35,"size":1}}"##))]),
            ContentPack(id: "muse-captions", kind: .captions, title: "Caption templates", licence: "MUSE",
                        items: [I(id: "bold-yellow", name: "Bold yellow",
                                  style: json(##"{"font":"montserrat","weight":900,"sizePct":0.05,"color":"#FFFFFF","align":"center","maxWidthPct":0.85,"lineHeight":1.15,"uppercase":true,"stroke":{"color":"#000000","widthPct":0.14},"preset":"pop","highlightColor":"#FFD400","y":0.7,"wordsPerPage":2,"maxLines":1}"##)),
                                I(id: "clean-white", name: "Clean white",
                                  style: json(##"{"font":"inter","weight":700,"sizePct":0.038,"color":"#FFFFFF","align":"center","maxWidthPct":0.85,"lineHeight":1.15,"shadow":{"color":"#000000","opacity":0.6,"blurPct":0.15,"dyPct":0.04},"preset":"plain","highlightColor":"#FFFFFF","y":0.8,"wordsPerPage":6,"maxLines":2}"##))]),
            ContentPack(id: "muse-transitions", kind: .transitions, title: "Transition presets", licence: "MUSE",
                        items: [I(id: "quick-fade", name: "Quick fade", transition: json(##"{"kind":"fade","durationSec":0.25}"##)),
                                I(id: "zoom-out", name: "Zoom out", transition: json(##"{"kind":"zoomOut","durationSec":0.5}"##)),
                                I(id: "whip-right", name: "Whip right", transition: json(##"{"kind":"whipRight","durationSec":0.35}"##)),
                                I(id: "split-fade", name: "Split fade", transition: json(##"{"kind":"splitFade","durationSec":0.4}"##))]),
        ])
    }()
}
