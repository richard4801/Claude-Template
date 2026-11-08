import Foundation

// Claude in the AI Suite: reference images attached to a chat message (attach button, drag and drop, ⌘V) and the
// references Claude puts into the shared draft (`draft.references`, set with its `suite_add_reference` tool). Rules only;
// the app uploads with the normal image upload (presign → PUT → confirm).

public enum SuiteClaudeAttachments {
    public static let maxCount = 4
    /// The server's limit per image.
    public static let maxBytes = 10 * 1024 * 1024
    /// The one refusal for a wrong type, too many or too big.
    public static let refusal = "Up to 4 images (JPEG, PNG, WebP or HEIC), 10 MB each"

    /// Allowed file extensions and their types.
    public static let extensions: [String: String] = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp",
                                                      "heic": "image/heic", "heif": "image/heic"]
    public static let mimes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"]

    /// The type of an allowed image: from its mime type when known, else its file name. nil: not one we take.
    public static func mime(name: String, mime: String? = nil) -> String? {
        if let m = mime?.lowercased(), !m.isEmpty {
            if m == "image/jpg" { return "image/jpeg" }
            if m == "image/heif" { return "image/heic" }
            return mimes.contains(m) ? m : nil
        }
        let ext = (name as NSString).pathExtension.lowercased()
        return extensions[ext]
    }

    /// Which of the picked files to take, in order, given how many are already attached: allowed types up to 10 MB, while
    /// there is room. `refusal` when anything was left out. `bytes` nil: not known yet.
    public static func check(existing: Int, picked: [(name: String, mime: String?, bytes: Int?)]) -> (take: [Int], refusal: String?) {
        var take: [Int] = []
        var refused = false
        for (i, p) in picked.enumerated() {
            var fits = true
            if let b = p.bytes { fits = b > 0 && b <= maxBytes }
            guard mime(name: p.name, mime: p.mime) != nil, fits, existing + take.count < maxCount else { refused = true; continue }
            take.append(i)
        }
        return (take, refused ? refusal : nil)
    }

    /// The images part of a message's context line: "images: <url> (upload <id>), …".
    public static func contextPart(_ items: [(uploadId: String?, url: String)]) -> String? {
        guard !items.isEmpty else { return nil }
        return "images: " + items.map { i in i.uploadId.map { "\(i.url) (upload \($0))" } ?? i.url }.joined(separator: ", ")
    }

    /// The image URLs a sent message carried (read back from its context line, for the thumbnails in the thread).
    public static func images(in text: String) -> [String] {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard first.hasPrefix("[Suite"), let r = first.range(of: "images: ") else { return [] }
        var rest = String(first[r.upperBound...])
        if let end = rest.range(of: " · ") { rest = String(rest[..<end.lowerBound]) }
        if rest.hasSuffix("]") { rest.removeLast() }
        return rest.components(separatedBy: ", ").compactMap { part in
            let url = part.components(separatedBy: " (upload ").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return url.isEmpty ? nil : url
        }
    }
}

/// A reference image in the shared draft: `draft.references[]` = `{uploadId, url, use: pose | style | location | outfit,
/// label?}`, at most 3. Claude adds them (`suite_add_reference`); the owner removes one by sending the draft without it.
public struct SuiteDraftReference: Hashable, Sendable, Identifiable {
    public var uploadId: String
    /// A normal /uploads image address.
    public var url: String
    public var use: String
    public var label: String?

    public init(uploadId: String, url: String, use: String, label: String? = nil) {
        self.uploadId = uploadId
        self.url = url
        self.use = use
        self.label = label
    }

    public var id: String { uploadId.isEmpty ? url : uploadId }
    public static let uses = ["pose", "style", "location", "outfit"]
    public static let maxCount = 3

    /// The chip's name: "Pose", "Style", "Location" or "Outfit".
    public var title: String { use.prefix(1).uppercased() + use.dropFirst() }

    /// The reference role a shot request uses for it: the server takes pose, style, location and outfit as they are.
    public var requestRole: String { use }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["uploadId": .string(uploadId), "url": .string(url), "use": .string(use)]
        if let l = label { o["label"] = .string(l) }
        return .object(o)
    }
}

public extension SuiteAssistDraft {
    /// The draft's `references`, read leniently: an entry needs an upload id or a link and a known use (also read from
    /// `role`, and the link from `image.url`). At most 3.
    static func references(_ d: SuiteDraft) -> [SuiteDraftReference] {
        guard case .array(let list)? = d.raw["references"] else { return [] }
        var out: [SuiteDraftReference] = []
        for v in list {
            guard case .object(let o) = v else { continue }
            func str(_ k: String, _ x: [String: JSONValue]) -> String? {
                if case .string(let s)? = x[k], !s.isEmpty { return s }
                return nil
            }
            var url = str("url", o)
            if url == nil, case .object(let img)? = o["image"] { url = str("url", img) }
            let up = str("uploadId", o) ?? ""
            guard let use = (str("use", o) ?? str("role", o))?.lowercased(), SuiteDraftReference.uses.contains(use), url != nil || !up.isEmpty else { continue }
            out.append(SuiteDraftReference(uploadId: up, url: url ?? "", use: use, label: str("label", o)))
        }
        return Array(out.prefix(SuiteDraftReference.maxCount))
    }

    /// The draft with these references (none: the key is left out).
    static func with(_ refs: [SuiteDraftReference], in d: SuiteDraft) -> SuiteDraft {
        var n = d
        n.raw["references"] = refs.isEmpty ? nil : .array(refs.prefix(SuiteDraftReference.maxCount).map(\.json))
        return n
    }

    /// The shot request with the references as reference images (for the composer's own Generate).
    static func request(_ r: ShotRequest, with refs: [SuiteDraftReference]) -> ShotRequest {
        let images = refs.filter { !$0.url.isEmpty }.map { SuiteRefImage(image: ImageRef(url: $0.url), role: $0.requestRole, label: $0.label ?? $0.title) }
        guard !images.isEmpty else { return r }
        var out = r
        var refsOut = out.references ?? SuiteReferences()
        refsOut.images = (refsOut.images ?? []) + images
        out.references = refsOut
        return out
    }
}
