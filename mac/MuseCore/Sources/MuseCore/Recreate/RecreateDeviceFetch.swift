import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// "Paste a link" fetched on this Mac (Release 1 owner decision; plans/api.md "Fetching on the device, and Strict link
/// rules"): TikTok, Instagram and YouTube refuse our cloud server ("Sign in to confirm you're not a bot"), so the Mac
/// downloads the public video itself with the official standalone yt-dlp_macos binary and uploads it like a dropped
/// file (with `sourceUrl`). The server's link endpoint is the fallback.
/// This file is the pure part (tested in CI): the pinned binary, the arguments, the checks on the video's metadata (the
/// server's own rules and words, server/api/src/recreate/links.ts `checkInfo` and `tiktokDownloadsOff`), the progress
/// parser and the refusal mapping. The process itself runs in the app (DeviceLinkFetcher); demo mode and CI never run it.
public enum RecreateDeviceFetch {
    /// The pinned release: the same yt-dlp version the server's Dockerfile pins. The hash is the `yt-dlp_macos` line of
    /// that release's SHA2-256SUMS asset. A downloaded file whose hash differs is deleted and never run.
    public static let version = "2026.10.26"
    public static let sha256 = "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa"
    public static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/yt-dlp_macos")!
    /// The file name under ~/Library/Application Support/MUSE/bin/ (versioned, so a new pin downloads a new file).
    public static let binaryName = "yt-dlp_macos-\(version)"
    /// The whole fetch (metadata, the TikTok page and the download) stops after this.
    public static let timeoutSec: Double = 120

    /// The caps the server sets (`GET /v1/recreate/settings` maxSec and maxMb; 60 s and 80 MB by default).
    public struct Limits: Equatable, Sendable {
        public var maxSec: Int
        public var maxBytes: Int
        public init(maxSec: Int = 60, maxMb: Int = 80) {
            self.maxSec = max(1, maxSec)
            self.maxBytes = max(1, maxMb) * 1_048_576
        }
        public init(_ s: RecreateLinkSettings) { self.init(maxSec: s.maxSec, maxMb: s.maxMb) }
        public var maxMb: Int { maxBytes / 1_048_576 }
    }

    /// What happened when the Mac couldn't make the file.
    public enum Failure: Equatable, Sendable {
        /// The video itself is refused (private, too long, too big, downloads off, a list, a live stream): the server
        /// would refuse it too, so this is shown at once, without the server fallback.
        case refused(RecreateLinkProblem)
        /// The Mac couldn't fetch it (no binary, blocked, sign-in wall, timeout, anything else): the server tries next.
        case unavailable(String)
    }

    // MARK: Arguments

    /// Flags that keep yt-dlp to one public video: no config files, no cookies (not even from a browser), no cache, no
    /// lists, no code fetched at run time, one line per progress update. A JavaScript runtime is passed when the Mac has
    /// one (YouTube needs it; deno is yt-dlp's default).
    public static func baseArgs(jsRuntime: String? = nil) -> [String] {
        var a = ["--ignore-config", "--no-cookies", "--no-cookies-from-browser", "--no-cache-dir", "--no-playlist", "--no-warnings",
                 "--socket-timeout", "20", "--no-remote-components", "--newline"]
        if let js = jsRuntime, !js.isEmpty {
            let name = (js as NSString).lastPathComponent
            a += ["--js-runtimes", "\(name):\(js)"]
        }
        return a
    }

    /// The format: one mp4 file with sound when the Mac has no ffmpeg to merge with (the standalone yt-dlp has none),
    /// else the best mp4 up to 1080p, merged into mp4.
    public static func format(ffmpeg: String?) -> String {
        ffmpeg == nil
            ? "b[ext=mp4][height<=1080]/b[ext=mp4]/b[height<=1080]/b"
            : "b[ext=mp4][height<=1080]/bv*[ext=mp4][height<=1080]+ba[ext=m4a]/bv*[height<=1080]+ba/b[height<=1080]/b"
    }

    /// The download's match filters (a backstop: the metadata is checked first). Filters joined with & must all pass;
    /// separate `--match-filter` flags pass if any one does. `?` lets a missing field pass (TikTok and Instagram don't
    /// report `availability`; without cookies a private video can't be fetched anyway). Public only (or unlisted:
    /// anyone with the link), as the server refuses anything else whatever the strict setting.
    public static func matchFilters(_ limits: Limits = Limits()) -> [String] {
        let d = "duration<=?\(limits.maxSec)"
        return ["\(d) & availability=?public", "\(d) & availability=?unlisted"]
    }

    /// Step 1: the video's metadata (one request to the platform), with the same format choice as the download so the
    /// reported size is the file's.
    public static func infoArgs(url: String, ffmpeg: String? = nil, jsRuntime: String? = nil) -> [String] {
        baseArgs(jsRuntime: jsRuntime) + ["-f", format(ffmpeg: ffmpeg), "--skip-download", "--dump-single-json", "--", url]
    }

    /// Step 2: the download from the metadata already read (`--load-info-json`: the page isn't fetched again), capped
    /// at the duration and the size limit, into `dir/video.<ext>`.
    public static func downloadArgs(infoFile: String, dir: String, limits: Limits = Limits(), ffmpeg: String? = nil, jsRuntime: String? = nil) -> [String] {
        var a = baseArgs(jsRuntime: jsRuntime) + ["--no-part", "--no-mtime"]
        for f in matchFilters(limits) { a += ["--match-filter", f] }
        a += ["--max-filesize", String(limits.maxBytes), "-f", format(ffmpeg: ffmpeg)]
        if let ffmpeg { a += ["--ffmpeg-location", ffmpeg, "--merge-output-format", "mp4"] }
        a += ["-o", (dir as NSString).appendingPathComponent("video.%(ext)s"), "--load-info-json", infoFile]
        return a
    }

    // MARK: The metadata

    /// The fields of yt-dlp's info JSON the check reads.
    public struct Info: Decodable, Equatable, Sendable {
        public var type: String?
        public var title: String?
        public var webpageUrl: String?
        public var duration: Double?
        public var availability: String?
        public var ageLimit: Int?
        public var isLive: Bool?
        public var liveStatus: String?
        public var filesize: Double?
        public var filesizeApprox: Double?
        public var requestedFormats: [Format]?

        public struct Format: Decodable, Equatable, Sendable {
            public var filesize: Double?
            public var filesizeApprox: Double?
            enum CodingKeys: String, CodingKey { case filesize, filesizeApprox = "filesize_approx" }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                filesize = try? c.decodeIfPresent(Double.self, forKey: .filesize)
                filesizeApprox = try? c.decodeIfPresent(Double.self, forKey: .filesizeApprox)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type = "_type", title, webpageUrl = "webpage_url", duration, availability, ageLimit = "age_limit", isLive = "is_live", liveStatus = "live_status"
            case filesize, filesizeApprox = "filesize_approx", requestedFormats = "requested_formats"
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            webpageUrl = try? c.decodeIfPresent(String.self, forKey: .webpageUrl)
            duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
            availability = try? c.decodeIfPresent(String.self, forKey: .availability)
            ageLimit = try? c.decodeIfPresent(Int.self, forKey: .ageLimit)
            isLive = try? c.decodeIfPresent(Bool.self, forKey: .isLive)
            liveStatus = try? c.decodeIfPresent(String.self, forKey: .liveStatus)
            filesize = try? c.decodeIfPresent(Double.self, forKey: .filesize)
            filesizeApprox = try? c.decodeIfPresent(Double.self, forKey: .filesizeApprox)
            requestedFormats = try? c.decodeIfPresent([Format].self, forKey: .requestedFormats)
        }

        /// From yt-dlp's stdout (`--dump-single-json`); nil when it isn't the JSON.
        public static func parse(_ stdout: Data) -> Info? { try? JSONDecoder().decode(Info.self, from: stdout) }

        /// The file's size as the metadata reports it (one file, or the video and sound added), if it says.
        public var size: Double? {
            if let s = filesize ?? filesizeApprox { return s }
            guard let f = requestedFormats, !f.isEmpty else { return nil }
            let total = f.reduce(0) { $0 + ($1.filesize ?? $1.filesizeApprox ?? 0) }
            return total > 0 ? total : nil
        }
    }

    /// The server's words (links.ts), so a refusal reads the same whichever side made it.
    public static let privateMessage = "This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in"
    public static let ageMessage = "This video is age-restricted, so MUSE won’t fetch it. Save it yourself and drop the file in"
    public static let tooBigMessage = "This video is too big to fetch"
    public static let downloadsOffMessage = "The creator turned downloads off for this video, so MUSE won’t fetch it. Use another video, or ask the creator"
    static func tooLong(_ sec: Double?, _ limits: Limits) -> String {
        sec.map { "References can be up to \(limits.maxSec) s for now (this one is \(Int($0.rounded())) s)" } ?? "References can be up to \(limits.maxSec) s for now"
    }

    /// What the metadata alone refuses (the server's `checkInfo`, the same whatever the strict setting): lists, live
    /// streams, anything not public (or unlisted), age-gated, too long, too big. nil = go ahead and download.
    public static func check(_ info: Info, limits: Limits = Limits()) -> RecreateLinkProblem? {
        if info.type == "playlist" || info.type == "multi_video" {
            return RecreateLinkProblem(code: "link_unsupported", message: "That link is a list of videos: paste the link of one video")
        }
        if info.isLive == true || ["is_live", "is_upcoming", "post_live"].contains(info.liveStatus ?? "") {
            return RecreateLinkProblem(code: "link_unsupported", message: "MUSE can’t fetch a live stream")
        }
        if let a = info.availability, a != "public", a != "unlisted" { return RecreateLinkProblem(code: "link_private", message: privateMessage) }
        if (info.ageLimit ?? 0) > 0 { return RecreateLinkProblem(code: "link_private", message: ageMessage) }
        if let d = info.duration, d > Double(limits.maxSec) + 0.5 { return RecreateLinkProblem(code: "too_long", message: tooLong(d, limits)) }
        if let s = info.size, s > Double(limits.maxBytes) {
            return RecreateLinkProblem(code: "link_too_big", message: "\(tooBigMessage) (\(Int((s / 1_048_576).rounded())) MB; the limit is \(limits.maxMb) MB)")
        }
        return nil
    }

    // MARK: TikTok's "downloads off"

    /// Whether this fetch must read TikTok's page first: strict rules with `tiktokDownloadsOff: "refuse"` (the server
    /// can't see a device's download, so the Mac honours the creator's setting itself).
    public static func needsTikTokPage(platform: String?, link: String, settings: RecreateLinkSettings) -> Bool {
        let tiktok = platform.map { $0 == "tiktok" } ?? (RecreateLinks.platform(link) == "TikTok")
        return tiktok && settings.strictLinks && settings.refusesTikTokDownloadsOff
    }

    /// TikTok's downloads setting from the video's public page (the server's `tiktokDownloadsOff`): true = the creator
    /// turned downloads off; false = on; nil = the page doesn't say (allowed, as on the server). 0 is "everyone"; any
    /// other number or an explicit false counts as off.
    public static func tiktokDownloadsOff(html: String) -> Bool? {
        guard let open = html.range(of: #"<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>"#, options: .regularExpression),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        let body = html[open.upperBound..<close.lowerBound]
        guard let data = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)) else { return nil }
        func at(_ v: JSONValue?, _ key: String) -> JSONValue? {
            if case .object(let o)? = v { return o[key] }
            return nil
        }
        let item = at(at(at(at(data, "__DEFAULT_SCOPE__"), "webapp.video-detail"), "itemInfo"), "itemStruct")
        guard case .object = item else { return nil }
        let flags = [at(item, "downloadSetting"), at(at(item, "author"), "downloadSetting"), at(at(item, "itemControl"), "can_download"),
                     at(at(item, "video_control"), "allow_download"), at(item, "allowDownload")]
        let known = flags.compactMap { f -> JSONValue? in
            guard let f, f != .null else { return nil }
            return f
        }
        guard !known.isEmpty else { return nil }
        return known.contains { f in
            switch f {
            case .bool(let b): return !b
            case .number(let n): return n != 0
            default: return false
            }
        }
    }

    /// The page couldn't be read: TikTok links are refused rather than risk a creator's "downloads off".
    public static let pageUnreadable = RecreateLinkProblem(code: "link_blocked", message: RecreateLinks.fallback)

    // MARK: yt-dlp's output

    /// yt-dlp's error text (stderr and stdout together) → a refusal the server would make too, or `unavailable` (the
    /// server tries next). A bot check ("Sign in to confirm you're not a bot"), a 403, a rate limit or a timeout is the
    /// Mac being refused, not the video.
    public static func failure(output: String) -> Failure {
        let s = output.lowercased()
        if s.contains("unsupported url") {
            return .refused(RecreateLinkProblem(code: "link_unsupported", message: "MUSE can’t fetch from that link. Save the video and drop the file in"))
        }
        if s.range(of: #"age[- ]restricted|confirm your age|inappropriate for some users|age limit"#, options: .regularExpression) != nil {
            return .refused(RecreateLinkProblem(code: "link_private", message: ageMessage))
        }
        if s.range(of: #"private video|video is private|members[- ]only|join this channel|subscriber"#, options: .regularExpression) != nil {
            return .refused(RecreateLinkProblem(code: "link_private", message: privateMessage))
        }
        if s.range(of: #"larger than max-filesize|max[- ]?filesize"#, options: .regularExpression) != nil {
            return .refused(RecreateLinkProblem(code: "link_too_big", message: tooBigMessage))
        }
        if s.contains("not a bot") || s.contains("sign in") || s.contains("login required") || s.contains("log in") { return .unavailable("sign-in wall") }
        if s.contains("does not pass filter") { return .unavailable("filtered") }
        if s.contains("timed out") { return .unavailable("timed out") }
        return .unavailable("fetch failed")
    }

    /// The download's progress (0…1) from one line of yt-dlp's output ("[download]  42.3% of 12.34MiB at …"); nil for
    /// any other line.
    public static func progress(_ line: String) -> Double? {
        guard line.contains("[download]"),
              let r = line.range(of: #"([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression),
              let v = Double(line[r].dropLast()) else { return nil }
        return min(1, max(0, v / 100))
    }

    /// The line under the link field: "Fetching the video…", with the percentage once the download reports one.
    public static func statusLine(fetched: Double?) -> String {
        guard let f = fetched else { return "Fetching the video…" }
        return "Fetching the video… \(Int((f * 100).rounded()))%"
    }

    /// The content type to upload a downloaded file with, by its extension.
    public static func contentType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }

    // MARK: The binary's checksum

    /// The file's SHA-256 as lowercase hex; nil if it can't be read (or hashed on this platform).
    public static func sha256Hex(of file: URL) -> String? {
        #if canImport(CryptoKit)
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        // read(upToCount:) answers nil (or empty data) at the end of the file; a read error gives no hash.
        while true {
            let chunk: Data?
            do { chunk = try h.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// True when the file's hash is the expected one. A file that fails is deleted, so it is never run.
    @discardableResult
    public static func verify(_ file: URL, expected: String = sha256) -> Bool {
        if let h = sha256Hex(of: file), h == expected.lowercased() { return true }
        try? FileManager.default.removeItem(at: file)
        return false
    }
}

/// `GET /v1/recreate/settings`: the studio's link rules, applied on the device too. Decoded leniently; a server without
/// the call gets the defaults (strict, 60 s, 80 MB, no cookies).
public struct RecreateLinkSettings: Codable, Hashable, Sendable {
    public var strictLinks: Bool
    /// ["tiktok","instagram","youtube"] (strict) or ["any"].
    public var platforms: [String]
    /// "refuse" | "allow".
    public var tiktokDownloadsOff: String
    public var maxSec: Int
    public var maxMb: Int
    public var serverFetch: Bool
    public var cookies: Bool
    /// The owner may change `strictLinks` (the Settings toggle shows only then).
    public var canEdit: Bool

    public init(strictLinks: Bool = true, platforms: [String]? = nil, tiktokDownloadsOff: String? = nil, maxSec: Int = 60, maxMb: Int = 80,
                serverFetch: Bool = true, cookies: Bool = false, canEdit: Bool = false) {
        self.strictLinks = strictLinks
        self.platforms = platforms ?? (strictLinks ? ["tiktok", "instagram", "youtube"] : ["any"])
        self.tiktokDownloadsOff = tiktokDownloadsOff ?? (strictLinks ? "refuse" : "allow")
        self.maxSec = maxSec
        self.maxMb = maxMb
        self.serverFetch = serverFetch
        self.cookies = cookies
        self.canEdit = canEdit
    }

    enum CodingKeys: String, CodingKey { case strictLinks, platforms, tiktokDownloadsOff, maxSec, maxMb, serverFetch, cookies, canEdit }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let strict: Bool = c.v(.strictLinks, true)
        self.init(strictLinks: strict, platforms: c.o(.platforms), tiktokDownloadsOff: c.o(.tiktokDownloadsOff), maxSec: c.v(.maxSec, 60),
                  maxMb: c.v(.maxMb, 80), serverFetch: c.v(.serverFetch, true), cookies: c.v(.cookies, false), canEdit: c.v(.canEdit, false))
    }

    /// TikTok's "downloads off" is refused (anything but an explicit "allow").
    public var refusesTikTokDownloadsOff: Bool { tiktokDownloadsOff != "allow" }
}

/// `POST /v1/recreate/links/check {url}`: the link under the studio's rules before a device downloads it.
public struct RecreateLinkCheck: Decodable, Sendable {
    public var allowed: Bool
    /// The normalized link (allowed).
    public var url: String?
    /// "tiktok" | "instagram" | "youtube" | "other".
    public var platform: String?
    /// This member's live reference from the link: opened instead of downloading again.
    public var cached: RecreateReference?
    public var code: String?
    public var reason: String?

    public init(allowed: Bool, url: String? = nil, platform: String? = nil, cached: RecreateReference? = nil, code: String? = nil, reason: String? = nil) {
        self.allowed = allowed
        self.url = url
        self.platform = platform
        self.cached = cached
        self.code = code
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case allowed, url, platform, cached, code, reason }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        allowed = c.v(.allowed, false)
        url = c.o(.url)
        platform = c.o(.platform)
        cached = c.o(.cached)
        code = c.o(.code)
        reason = c.o(.reason)
    }

    /// A refusal as the start page shows it (the reason, with the file offered for every link_* code).
    public var problem: RecreateLinkProblem? {
        guard !allowed else { return nil }
        let code = code ?? "link_unsupported"
        return RecreateLinkProblem(code: code, message: RecreateLinks.message(code: code, message: reason))
    }
}
