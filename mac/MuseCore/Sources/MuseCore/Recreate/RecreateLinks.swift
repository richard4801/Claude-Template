import Foundation

/// A reference from a public link (plans/api.md "From a link"): which pasted text is a link MUSE can fetch, and what each
/// refusal says. The server decides; this only recognises a link (to fill the field on ⌘V and enable "Fetch") and words
/// the refusals. Every `link_*` refusal offers the file drop right where it is shown.
public enum RecreateLinks {
    /// The server's words when a link can't be fetched (`link_blocked`).
    public static let fallback = "Couldn’t fetch this link — save the video and drop the file in"

    /// The platforms MUSE can fetch from, by host (www. and m. dropped).
    static let hosts: [String: String] = [
        "tiktok.com": "TikTok", "vm.tiktok.com": "TikTok", "vt.tiktok.com": "TikTok",
        "instagram.com": "Instagram", "youtube.com": "YouTube", "youtu.be": "YouTube",
    ]

    /// "TikTok", "Instagram" or "YouTube" for a link MUSE can try; nil for anything else.
    public static func platform(_ link: String) -> String? {
        guard let u = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = u.host?.lowercased() else { return nil }
        for p in ["www.", "m."] where host.hasPrefix(p) { host.removeFirst(p.count) }
        return hosts[host]
    }

    /// The first link in pasted text (a share sheet often adds words around it), if it is one MUSE can try.
    public static func detect(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" })
        for w in words {
            var s = String(w)
            while let first = s.first, "([{'".contains(first) { s.removeFirst() }
            while let last = s.last, ".,;:!?)]}'".contains(last) { s.removeLast() }
            if s.lowercased().hasPrefix("http"), platform(s) != nil { return s }
        }
        return nil
    }

    /// A refusal (or a failed reference) whose code means "drop the file in instead": every `link_*` code.
    public static func offersFile(_ code: String?) -> Bool { code?.hasPrefix("link_") == true }

    /// The line shown for a refusal: the server's own words when it sent some, else plain words for the code.
    public static func message(code: String, message: String?) -> String {
        if let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty, !m.hasPrefix("Server error") { return m }
        switch code {
        case "link_unsupported": return "MUSE can fetch TikTok, Instagram Reel and YouTube Shorts links. For anything else, save the video and drop the file in"
        case "link_private": return "This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in"
        case "link_downloads_off": return "The creator turned downloads off for this video, so MUSE won’t fetch it. Use another video, or ask the creator"
        case "link_too_big": return "This video is too big to fetch"
        case "too_long": return "References can be up to 60 s for now"
        default: return fallback
        }
    }

    /// The codes `POST /v1/recreate/references {url}` refuses with.
    public static let refusalCodes: Set<String> = ["link_unsupported", "link_private", "link_downloads_off", "link_too_big", "link_blocked", "too_long"]
}

/// A link refusal as the start page shows it: the words, and whether the file drop is offered with them.
public struct RecreateLinkProblem: Hashable, Sendable {
    public var code: String
    public var message: String
    public var offersFile: Bool { RecreateLinks.offersFile(code) || code == "too_long" }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// From an error the link call threw; nil for errors that aren't about the link (offline, signed out).
    public init?(_ error: Error) {
        guard let e = error as? ApiError, RecreateLinks.refusalCodes.contains(e.code) else { return nil }
        self.init(code: e.code, message: RecreateLinks.message(code: e.code, message: e.message))
    }
}
