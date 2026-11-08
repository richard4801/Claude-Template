import Foundation

// Claude in the AI Suite: reference images attached to a chat message (attach button, drag and drop, ⌘V) and the
// references Claude puts into the shared draft (a pose, style, location or outfit), which the composer shows in its
// References slots. Rules only; the app uploads with its usual image upload.

public enum SuiteClaudeAttachments {
    public static let maxCount = 4
    /// The one refusal for a wrong type or too many.
    public static let refusal = "Up to 4 images (JPEG, PNG, WebP or HEIC)"

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

    /// Which of the picked files to take, in order, given how many are already attached: the allowed types while there is
    /// room. `refusal` when anything was left out.
    public static func check(existing: Int, picked: [(name: String, mime: String?)]) -> (take: [Int], refusal: String?) {
        var take: [Int] = []
        var refused = false
        for (i, p) in picked.enumerated() {
            guard mime(name: p.name, mime: p.mime) != nil, existing + take.count < maxCount else { refused = true; continue }
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

/// A reference image Claude put into the draft (`references[]`: `{image | url, uploadId?, role, label?}`).
public struct SuiteDraftReference: Hashable, Sendable {
    public var image: ImageRef
    /// pose | style | location | outfit
    public var role: String
    public var uploadId: String?
    public var label: String?

    public init(image: ImageRef, role: String, uploadId: String? = nil, label: String? = nil) {
        self.image = image
        self.role = role
        self.uploadId = uploadId
        self.label = label
    }

    public static let roles = ["pose", "style", "location", "outfit"]

    /// The composer's reference role (SlotValue.role: product | location | style | prop | person) for Claude's role.
    public var slotRole: String {
        switch role {
        case "style": return "style"
        case "location": return "location"
        default: return "person" // pose and outfit: about the person in the shot
        }
    }

    /// "Pose from Claude".
    public var slotName: String { (role.prefix(1).uppercased() + role.dropFirst()) + " from Claude" }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["role": .string(role)]
        var img: [String: JSONValue] = [:]
        if let u = image.url { img["url"] = .string(u) }
        if let a = image.asset { img["asset"] = .string(a) }
        o["image"] = .object(img)
        if let u = uploadId { o["uploadId"] = .string(u) }
        if let l = label { o["label"] = .string(l) }
        return .object(o)
    }
}

public extension SuiteAssistDraft {
    /// The draft's `references`, read leniently (an entry without an image or role is skipped).
    static func references(_ d: SuiteDraft) -> [SuiteDraftReference] {
        guard case .array(let list)? = d.raw["references"] else { return [] }
        return list.compactMap { v in
            guard case .object(let o) = v else { return nil }
            func str(_ k: String, in x: [String: JSONValue]) -> String? { if case .string(let s)? = x[k], !s.isEmpty { return s }; return nil }
            var image: ImageRef?
            if case .object(let i)? = o["image"] {
                let u = str("url", in: i), a = str("asset", in: i)
                if u != nil || a != nil { image = ImageRef(asset: a, url: u) }
            } else if let u = str("url", in: o) {
                image = ImageRef(url: u)
            }
            guard let image, let role = str("role", in: o) else { return nil }
            return SuiteDraftReference(image: image, role: role.lowercased(), uploadId: str("uploadId", in: o), label: str("label", in: o))
        }
    }

    /// The draft with these references (demo mode's stand-in for Claude adding them).
    static func with(_ refs: [SuiteDraftReference], in d: SuiteDraft) -> SuiteDraft {
        var n = d
        n.raw["references"] = .array(refs.map(\.json))
        return n
    }

    /// Claude's references into the composer's References slots: a known role, not already there, while the quality takes
    /// more. Anything else is refused with the reason.
    static func place(_ refs: [SuiteDraftReference], into slots: InputSlots, capacity: Int) -> (slots: InputSlots, added: Int, rejected: [SuiteDraftRejection]) {
        var out = slots
        var added = 0
        var rejected: [SuiteDraftRejection] = []
        for r in refs {
            let name = r.label ?? r.role
            guard SuiteDraftReference.roles.contains(r.role) else {
                rejected.append(SuiteDraftRejection(field: "Reference", value: name, reason: "isn't a pose, style, location or outfit reference"))
                continue
            }
            let images = out.values.filter { $0.key.kind == .image }
            if images.contains(where: { $0.value.image == r.image }) { continue }
            guard images.count < capacity else {
                rejected.append(SuiteDraftRejection(field: "Reference", value: name,
                                                    reason: capacity == 0 ? "isn't taken by this quality" : "has no room: this quality takes \(capacity)"))
                continue
            }
            out = out.put(SlotId(.image, images.count), SlotValue(name: r.slotName, image: r.image, role: r.slotRole))
            added += 1
        }
        return (out, added, rejected)
    }
}
