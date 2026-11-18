import Foundation

/// File names for what MUSE saves on the Mac (Library Download, Export, Claude's save_to_mac): readable, one per take,
/// and never written over an existing file (ci_7972a1d67e72: several takes downloaded at once used to share the caption
/// as their name, so each replaced the last and ~/Downloads/MUSE kept only one).
public enum SaveFileName {
    /// "mia-living-room-dance": lowercase words joined by "-", at most `max` characters, cut at a word.
    public static func slug(_ s: String, max: Int = 40) -> String {
        var words: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { cur.append(ch) } else if !cur.isEmpty { words.append(cur); cur = "" }
        }
        if !cur.isEmpty { words.append(cur) }
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + "-" + w
            if next.count > max { break }
            out = next
        }
        if out.isEmpty, let first = words.first { out = String(first.prefix(max)) }
        return out
    }

    /// The id part: "s_9381c89cde04" → "s9381c89c" (kind letter and the first 8 characters; enough to tell takes apart).
    public static func shortId(_ id: String) -> String {
        let clean = id.filter { $0.isLetter || $0.isNumber }
        return String(clean.prefix(9))
    }

    /// "mia-living-room-dance-s9381c89c-2": who/what (`title`, else the prompt), the take's id and its number. `date` (ms) is
    /// used when there is no id.
    public static func base(title: String, prompt: String = "", id: String, index: Int? = nil, date: Int64? = nil) -> String {
        var s = slug(title)
        if s.isEmpty { s = slug(prompt) }
        if s.isEmpty { s = "muse" }
        var parts = [s]
        let short = shortId(id)
        if !short.isEmpty {
            parts.append(short)
        } else if let date, date > 0 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd-HHmmss"
            parts.append(f.string(from: Date(timeIntervalSince1970: Double(date) / 1000)))
        }
        if let index, index > 0 { parts.append(String(index)) }
        return parts.joined(separator: "-")
    }

    /// The name of a take's file: its title (model and look) or prompt, its id and its number, plus `ext`.
    public static func forTake(_ t: Take, ext: String) -> String {
        base(title: t.title.isEmpty ? t.caption : t.title, prompt: t.prompt, id: t.id, index: t.index, date: t.createdAt) + "." + ext
    }

    /// A place photo's file (Places tab · Save to Mac): "mias-apartment-3f2a1b9c-2.jpg", the place, its id and the photo's
    /// number (1-based).
    public static func forPlacePhoto(place: String, id: String, number: Int, ext: String) -> String {
        base(title: place, id: id, index: number) + "." + (ext.isEmpty ? "jpg" : ext.lowercased())
    }

    /// A name safe to write: no path separators or characters Finder dislikes, not hidden, not empty, at most 120 characters
    /// before the extension.
    public static func sanitized(_ name: String, fallback: String = "muse") -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\0").union(.controlCharacters).union(.newlines)
        var n = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty { n = fallback }
        let ext = (n as NSString).pathExtension
        let stem = (n as NSString).deletingPathExtension
        let short = String(stem.prefix(120))
        return ext.isEmpty ? short : short + "." + ext
    }

    /// `name` in `folder`, or "name (2).ext", "name (3).ext"… the first that doesn't exist yet. Never an existing file.
    public static func unique(_ name: String, in folder: String, exists: (String) -> Bool) -> String {
        let n = sanitized(name)
        let dir = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let first = dir + "/" + n
        if !exists(first) { return first }
        let ext = (n as NSString).pathExtension
        let stem = (n as NSString).deletingPathExtension
        var i = 2
        while true {
            let p = dir + "/" + stem + " (\(i))" + (ext.isEmpty ? "" : "." + ext)
            if !exists(p) { return p }
            i += 1
        }
    }

    /// The same against the disk.
    public static func unique(_ name: String, in folder: URL) -> URL {
        URL(fileURLWithPath: unique(name, in: folder.path) { FileManager.default.fileExists(atPath: $0) })
    }

    public struct SaveError: Error, LocalizedError {
        public var errorDescription: String? { "Couldn't find a free name in that folder" }
    }

    /// Moves a finished file into `folder` under the first free name. The move fails rather than replace, so two files
    /// finishing together still end up as two ("name.mp4", "name (2).mp4").
    public static func moveUnique(_ file: URL, named name: String, into folder: URL) throws -> URL {
        let fm = FileManager.default
        for _ in 0..<100 {
            let dst = unique(name, in: folder)
            do {
                try fm.moveItem(at: file, to: dst)
                return dst
            } catch {
                if fm.fileExists(atPath: dst.path) { continue } // taken in between: the next free name
                throw error
            }
        }
        throw SaveError()
    }
}
