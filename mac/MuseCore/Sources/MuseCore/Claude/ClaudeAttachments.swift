import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux (MuseCore builds and tests there too)
#endif

/// An image saved on this Mac for a Claude Code turn: its path and the upload id Claude passes to the suite tools.
public struct ClaudeAttachmentFile: Hashable, Sendable {
    public var path: String
    public var uploadId: String
    public init(path: String, uploadId: String) {
        self.path = path
        self.uploadId = uploadId
    }
}

/// The lines added to Claude Code's prompt for a turn's images. The upload id stays in the text: Claude passes it to
/// `suite_add_reference`.
public enum ClaudeAttachmentPrompt {
    public static func text(_ text: String, _ files: [ClaudeAttachmentFile]) -> String {
        guard !files.isEmpty else { return text }
        // An image attached only on this Mac (Edit, Recreate, Camera) has no upload id: just its path.
        let list = files.map { $0.uploadId.isEmpty ? "- \($0.path)" : "- \($0.path) (uploadId \($0.uploadId))" }.joined(separator: "\n")
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text + "\n\n"
        return head + "Attached images (Read each one):\n" + list
    }
}

/// `Caches/MUSE/claude/<threadId>/<id>.<ext>`: where a turn's images are kept for Claude Code to Read.
public enum ClaudeAttachmentCache {
    public static func directory(threadId: String, caches: URL? = nil) -> URL {
        var base = FileManager.default.temporaryDirectory
        if let c = caches {
            base = c
        } else if let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = c
        }
        return base.appendingPathComponent("MUSE/claude/\(safe(threadId))", isDirectory: true)
    }

    /// The file name: the attachment's id with the extension of its type (or its link's), jpg when neither says.
    public static func fileName(_ a: ClaudeAttachment) -> String {
        "\(safe(a.id.isEmpty ? a.uploadId : a.id)).\(ext(mime: a.mimeType, url: a.url))"
    }

    public static func ext(mime: String?, url: String?) -> String {
        switch mime?.lowercased() {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/jpeg", "image/jpg": return "jpg"
        default:
            let path = url.flatMap { URL(string: $0)?.path } ?? ""
            let e = (path as NSString).pathExtension.lowercased()
            switch e {
            case "png", "webp", "heic": return e
            case "heif": return "heic"
            default: return "jpg"
            }
        }
    }

    /// Ids and thread ids as file names: letters, digits, "-" and "_" only.
    static func safe(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            let keep = (u.isASCII && CharacterSet.alphanumerics.contains(u)) || u == "-" || u == "_"
            out.append(keep ? Character(u) : "_")
        }
        return out.isEmpty ? "image" : out
    }

    /// Writes an image the owner attached on this Mac (already uploaded) next to the turn.
    public static func save(_ data: Data, attachment a: ClaudeAttachment, threadId: String) -> ClaudeAttachmentFile? {
        let dir = directory(threadId: threadId)
        let file = dir.appendingPathComponent(fileName(a))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return ClaudeAttachmentFile(path: file.path, uploadId: a.uploadId)
        } catch {
            return nil
        }
    }

    /// Downloads a phone turn's image (its signed link; a relative one against `base`). nil when it can't be fetched.
    public static func download(_ a: ClaudeAttachment, threadId: String, base: URL?) async -> ClaudeAttachmentFile? {
        guard let raw = a.url, !raw.isEmpty else { return nil }
        let url: URL? = raw.hasPrefix("/") ? base.flatMap { URL(string: raw, relativeTo: $0)?.absoluteURL } : URL(string: raw)
        guard let url, let result = try? await URLSession.shared.data(from: url) else { return nil }
        let (data, resp) = result
        let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        guard ok, !data.isEmpty else { return nil }
        return save(data, attachment: a, threadId: threadId)
    }
}
