import Foundation

// The edit content library (WS8 84df583 / 929bcf2; server/api/src/editor/content.ts): one shared catalog of open-licence
// stickers, sound effects and fonts plus MUSE's own looks, caption and transition presets. GET /v1/editor/content gives the
// catalog (its `version` is also the ETag of every file); GET /v1/editor/content/files/<path> gives a file (public).
// Stickers and sound effects go into an edit as library assets `content:<pack>/<item>`.

/// The content catalog.
public struct ContentCatalog: Codable, Hashable, Sendable {
    public var version: String
    public var packs: [ContentPack]
    public init(version: String, packs: [ContentPack]) { self.version = version; self.packs = packs }

    public func packs(_ kind: ContentPack.Kind) -> [ContentPack] { packs.filter { $0.kind == kind } }

    /// The pack and item a `content:<pack>/<item>` ref names, or nil.
    public func item(ref: String) -> (pack: ContentPack, item: ContentItem)? {
        guard let (p, i) = Self.parse(ref), let pack = packs.first(where: { $0.id == p }), let item = pack.items.first(where: { $0.id == i }) else { return nil }
        return (pack, item)
    }

    /// The file path of a font family at a weight (400/700/900, nearest below; 400 when that weight is missing), or nil.
    public func fontFile(_ font: EditV2.Font, weight: Int) -> String? {
        guard let files = packs(.fonts).lazy.compactMap({ $0.items.first { $0.id == font.rawValue }?.files }).first else { return nil }
        return files[String(Self.fontWeight(weight))] ?? files["400"]
    }

    /// The weight file a style weight draws with (content.ts contentFont).
    public static func fontWeight(_ w: Int) -> Int { w >= 900 ? 900 : w >= 700 ? 700 : 400 }

    public static func ref(pack: String, item: String) -> String { "content:\(pack)/\(item)" }

    /// `content:<pack>/<item>` → (pack, item) when the ref has that shape (validation's own pattern).
    public static func parse(_ ref: String) -> (String, String)? {
        guard ref.range(of: #"^content:[a-z0-9-]+/[a-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        let body = ref.dropFirst("content:".count)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        return (String(body[..<slash]), String(body[body.index(after: slash)...]))
    }

    /// The packs with a licence other than MUSE's own, for Settings → About → Licences.
    public var attributions: [ContentPack] { packs.filter { $0.licence != "MUSE" } }
}

public struct ContentPack: Codable, Hashable, Sendable, Identifiable {
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        public static let stickers = Kind(rawValue: "stickers")
        public static let sfx = Kind(rawValue: "sfx")
        public static let fonts = Kind(rawValue: "fonts")
        public static let looks = Kind(rawValue: "looks")
        public static let captions = Kind(rawValue: "captions")
        public static let transitions = Kind(rawValue: "transitions")
    }
    public struct Category: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var licence: String
    public var attribution: String?
    public var categories: [Category]?
    public var items: [ContentItem]
    public init(id: String, kind: Kind, title: String, licence: String, attribution: String? = nil, categories: [Category]? = nil, items: [ContentItem]) {
        self.id = id; self.kind = kind; self.title = title; self.licence = licence; self.attribution = attribution
        self.categories = categories; self.items = items
    }
}

/// One item of a pack. Which fields it has depends on the pack's kind; the presets stay JSON so one item the app can't read
/// doesn't lose the whole catalog (`lookValue` and friends decode them, nil when they don't).
public struct ContentItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String?
    public var tags: [String]?
    /// Stickers and sound effects.
    public var file: String?
    public var width: Int?
    public var height: Int?
    public var durationSec: Double?
    public var bytes: Int?
    /// Fonts: "400" / "700" / "900" → file.
    public var files: [String: String]?
    public var scripts: [String]?
    public var look: JSONValue?
    public var style: JSONValue?
    public var transition: JSONValue?

    public init(id: String, name: String, category: String? = nil, tags: [String]? = nil, file: String? = nil, width: Int? = nil, height: Int? = nil,
                durationSec: Double? = nil, bytes: Int? = nil, files: [String: String]? = nil, scripts: [String]? = nil,
                look: JSONValue? = nil, style: JSONValue? = nil, transition: JSONValue? = nil) {
        self.id = id; self.name = name; self.category = category; self.tags = tags; self.file = file; self.width = width; self.height = height
        self.durationSec = durationSec; self.bytes = bytes; self.files = files; self.scripts = scripts
        self.look = look; self.style = style; self.transition = transition
    }

    public var lookValue: EditV2.Look? { look.flatMap { try? JSONPatch.decode(EditV2.Look.self, $0) } }
    public var captionStyle: EditV2.CaptionStyle? { style.flatMap { try? JSONPatch.decode(EditV2.CaptionStyle.self, $0) } }
    public var transitionValue: EditV2.Transition? { transition.flatMap { try? JSONPatch.decode(EditV2.Transition.self, $0) } }

    /// Search: every word of `query` in the name, a tag or the category (case-insensitive).
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = ([name, category ?? ""] + (tags ?? [])).joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }
}

extension EditV2.Asset {
    /// The content ref of a sticker or sound effect from the content library, or nil.
    public var contentRef: String? { library.flatMap { $0.hasPrefix("content:") ? $0 : nil } }
}

extension EditV2.Project {
    /// The content fonts this edit's text and captions draw with, by weight file (each needs loading on this Mac).
    public var contentFonts: Set<EditV2.ContentFontKey> {
        var out: Set<EditV2.ContentFontKey> = []
        for t in tracks {
            if let c = t.caption, c.style.font.isContent { out.insert(.init(font: c.style.font, weight: ContentCatalog.fontWeight(c.style.weight))) }
            for it in t.items {
                if case .text(let tx) = it, tx.style.font.isContent { out.insert(.init(font: tx.style.font, weight: ContentCatalog.fontWeight(tx.style.weight))) }
            }
        }
        return out
    }
}

extension EditV2 {
    public struct ContentFontKey: Hashable, Sendable {
        public var font: Font
        public var weight: Int
        public init(font: Font, weight: Int) { self.font = font; self.weight = weight }
    }
}

/// Where content files live on this Mac: Caches/MUSE-content/<version>/<path>. A new catalog version is a new folder (the
/// older ones are removed when a newer one is first used).
public enum ContentFiles {
    static let safe = #"^[a-z0-9-]+(/[A-Za-z0-9_.-]+)+$"#

    public static func root() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MUSE-content", isDirectory: true)
    }

    /// The local file for `path` at `version`; throws for a path the server wouldn't serve.
    public static func local(_ path: String, version: String) throws -> URL {
        guard path.range(of: safe, options: .regularExpression) != nil, !path.contains(".."),
              version.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw ApiError("not_found", "Content file not found")
        }
        return try root().appendingPathComponent(version, isDirectory: true).appendingPathComponent(path)
    }

    public static func store(_ data: Data, at dst: URL) throws {
        let fm = FileManager.default
        let versionDir = dst.deletingLastPathComponent()
        try fm.createDirectory(at: versionDir, withIntermediateDirectories: true)
        // Older catalog versions go once a newer one is used.
        if let root = try? root(), let rel = dst.path.dropFirst(root.path.count + 1).split(separator: "/").first,
           let olds = try? fm.contentsOfDirectory(atPath: root.path) {
            for o in olds where o != String(rel) { try? fm.removeItem(at: root.appendingPathComponent(o)) }
        }
        let tmp = versionDir.appendingPathComponent(".\(UUID().uuidString)")
        try data.write(to: tmp)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
    }
}

extension ContentCatalog {
    /// A sticker (picture) or sound effect as an asset of an edit, `id` new in that edit; nil for any other kind.
    public static func asset(pack: ContentPack, item: ContentItem, id: String) -> EditV2.Asset? {
        let ref = ref(pack: pack.id, item: item.id)
        let name = item.name.isEmpty ? nil : String(item.name.prefix(80))
        switch pack.kind {
        case .stickers: return EditV2.Asset(id: id, kind: .image, library: ref, width: item.width, height: item.height, name: name)
        case .sfx:
            guard let d = item.durationSec, d >= 0.01 else { return nil }
            return EditV2.Asset(id: id, kind: .audio, library: ref, durationSec: d, hasAudio: true, name: name)
        default: return nil
        }
    }
}

extension EditSuiteState {
    /// A content sticker at the playhead (as a picture), reusing the edit's asset when it's already there.
    @discardableResult
    public mutating func addContentSticker(_ pack: ContentPack, _ item: ContentItem) -> Bool {
        let ref = ContentCatalog.ref(pack: pack.id, item: item.id)
        let asset = project.assets.first { $0.library == ref && $0.kind == .image } ?? ContentCatalog.asset(pack: pack, item: item, id: project.newId("p"))
        guard let asset else { return false }
        assetNames[asset.id] = item.name
        return addImage(asset)
    }

    /// A content sound effect at the playhead on the sound effects row.
    @discardableResult
    public mutating func addContentSound(_ pack: ContentPack, _ item: ContentItem) -> Bool {
        let ref = ContentCatalog.ref(pack: pack.id, item: item.id)
        let asset = project.assets.first { $0.library == ref && $0.kind == .audio } ?? ContentCatalog.asset(pack: pack, item: item, id: project.newId("a"))
        guard let asset else { return false }
        assetNames[asset.id] = item.name
        return addAudio(asset, kind: .sfx)
    }

    /// A caption template: the whole style (font, colours, preset, position, words per page).
    @discardableResult
    public mutating func applyCaptionTemplate(_ style: E.CaptionStyle) -> Bool {
        changeCaptionStyle { $0 = style }
    }
}
