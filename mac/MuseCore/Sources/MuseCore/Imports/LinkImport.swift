import Foundation

// "Import a video from a link" (owner-approved 2026-11-08, WS6 Mac; server contract from WS12): a general-purpose import,
// mainly for the AI Suite's Swap source and Edit. The Mac fetches the public video itself with the same pinned yt-dlp
// and Strict link rules as Recreate (RecreateDeviceFetch / DeviceLinkFetcher), uploads it, and the server keeps it as an
// imported clip. When the Mac can't fetch it, the server tries. Refusals use Recreate's words (RecreateLinks).
//
// Contract (as forwarded; build against its shape, every field read leniently):
//   GET  /v1/links/settings                   → the same shape as /v1/recreate/settings (RecreateLinkSettings)
//   POST /v1/links/check {url, purpose:'import'} → {allowed, url, platform} | {allowed:false, code, reason}
//   POST /v1/uploads/presign {kind:'clip'} + PUT (no /confirm) → uploadId
//   POST /v1/imports {uploadId, sourceUrl, name?} → the imported clip ({clip, take?} or a bare Clip)
//   POST /v1/imports {sourceUrl, name?}          → the server fetches it (fallback)

/// Where an import was started from: it decides what happens with the clip afterwards.
public enum LinkImportPurpose: String, Sendable, CaseIterable {
    /// The Suite's Swap: the clip becomes the swap source, selected.
    case swap
    /// The Library: the clip is added and shown.
    case library
    /// Edit's media bin: the clip is added to the bin.
    case edit
}

/// POST /v1/imports: what came back.
public struct LinkImportResult: Decodable, Sendable {
    public var clip: Clip?
    /// The Library's item for it, when the server makes one.
    public var take: Take?

    public init(clip: Clip?, take: Take? = nil) {
        self.clip = clip
        self.take = take
    }

    enum CodingKeys: String, CodingKey { case clip, take }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if c.contains(.clip) || c.contains(.take) {
            clip = c.o(.clip)
            take = c.o(.take)
        } else {
            // A bare Clip.
            clip = try? Clip(from: d)
            take = nil
        }
    }
}

public protocol LinkImportAPI: Sendable {
    /// The studio's link rules for imports (nil fields fall back to Recreate's defaults: strict, 60 s, 80 MB).
    func linkImportSettings() async throws -> RecreateLinkSettings
    /// The server's verdict on a link before this Mac downloads it.
    func checkImportLink(_ url: String) async throws -> RecreateLinkCheck
    /// A video this Mac fetched, uploaded and kept as an imported clip with its source link.
    func importVideo(file: URL, contentType: String, sourceUrl: String, name: String?, progress: UploadProgress?) async throws -> LinkImportResult
    /// The server fetches the link itself (when this Mac couldn't).
    func importLink(_ sourceUrl: String, name: String?) async throws -> LinkImportResult
}

public enum LinkImport {
    /// A link someone pasted or dropped: trimmed, and only http(s). Strict rules allow TikTok, Instagram and YouTube;
    /// otherwise any web link may be tried (the server has the final word).
    public static func link(_ raw: String, strict: Bool) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = RecreateLinks.detect(t) { return d }
        guard !strict, let u = URL(string: t), let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host != nil else { return nil }
        return t
    }

    /// The first line under the field while nothing has happened yet.
    public static func hint(strict: Bool, limits: RecreateDeviceFetch.Limits) -> String {
        (strict ? "A public TikTok, Instagram or YouTube video" : "A public video link")
            + ", up to \(limits.maxSec) s and \(limits.maxMb) MB. It's fetched on this Mac."
    }

    /// The import's name: the video's title, else the platform's.
    public static func name(title: String?, platform: String?) -> String? {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return String(t.prefix(80)) }
        return platform.map { "\($0.prefix(1).uppercased())\($0.dropFirst()) video" }
    }
}

// MARK: HTTP

extension HTTPMuseAPI: LinkImportAPI {
    private struct CheckBody: Encodable { var url: String; var purpose = "import" }
    private struct ImportBody: Encodable { var uploadId: String?; var sourceUrl: String; var name: String? }

    public func linkImportSettings() async throws -> RecreateLinkSettings { try await suiteCall("GET", "v1/links/settings") }

    public func checkImportLink(_ url: String) async throws -> RecreateLinkCheck {
        try await suiteCall("POST", "v1/links/check", body: try JSONEncoder().encode(CheckBody(url: url)))
    }

    public func importVideo(file: URL, contentType: String, sourceUrl: String, name: String?, progress: UploadProgress?) async throws -> LinkImportResult {
        progress?(0)
        guard let uploadId = try await presignAndPut(kind: "clip", contentType: contentType, body: .file(file), progress: progress) else {
            throw ApiError("not_found", "This server can't take imported videos yet")
        }
        progress?(1)
        return try await suiteCall("POST", "v1/imports", body: try JSONEncoder().encode(ImportBody(uploadId: uploadId, sourceUrl: sourceUrl, name: name)))
    }

    public func importLink(_ sourceUrl: String, name: String?) async throws -> LinkImportResult {
        try await suiteCall("POST", "v1/imports", body: try JSONEncoder().encode(ImportBody(uploadId: nil, sourceUrl: sourceUrl, name: name)))
    }
}

// MARK: Demo mode

extension FakeMuseAPI: LinkImportAPI {
    public func linkImportSettings() async throws -> RecreateLinkSettings { RecreateLinkSettings(strictLinks: true, canEdit: true) }

    public func checkImportLink(_ url: String) async throws -> RecreateLinkCheck {
        guard let link = LinkImport.link(url, strict: true) else {
            return RecreateLinkCheck(allowed: false, code: "link_unsupported", reason: RecreateLinks.message(code: "link_unsupported", message: nil))
        }
        return RecreateLinkCheck(allowed: true, url: link, platform: RecreateLinks.platform(link)?.lowercased())
    }

    public func importVideo(file: URL, contentType: String, sourceUrl: String, name: String?, progress: UploadProgress?) async throws -> LinkImportResult {
        try await importLink(sourceUrl, name: name)
    }

    /// Demo mode never downloads: the link becomes the sample performer clip under the link's name.
    public func importLink(_ sourceUrl: String, name: String?) async throws -> LinkImportResult {
        let check = try await checkImportLink(sourceUrl)
        guard check.allowed else { throw ApiError(check.code ?? "link_unsupported", check.reason ?? RecreateLinks.fallback) }
        var c = uploadClip(SampleData.sampleMeta, file: nil, progress: nil)
        c.name = name ?? LinkImport.name(title: nil, platform: check.platform) ?? c.name
        return LinkImportResult(clip: c)
    }
}
