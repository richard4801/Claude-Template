import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux (MuseCore builds and tests there too)
#endif

/// An image saved on this Mac for a Claude Code turn: its path and the upload id Claude passes to the suite tools. A video
/// has no path: it stays on the server as an upload, and Claude watches it there (`watch {id: uploadId}`).
public struct ClaudeAttachmentFile: Hashable, Sendable {
    public var path: String
    public var uploadId: String
    /// A video upload: never handed to Claude Code as a file to Read.
    public var video: Bool
    /// A video's file name and length, for Claude's line.
    public var name: String?
    public var seconds: Double?

    public init(path: String, uploadId: String, video: Bool = false, name: String? = nil, seconds: Double? = nil) {
        self.path = path
        self.uploadId = uploadId
        self.video = video
        self.name = name
        self.seconds = seconds
    }

    /// A video uploaded to the server (plans/claude-video-vision.md).
    public static func video(uploadId: String, name: String? = nil, seconds: Double? = nil) -> ClaudeAttachmentFile {
        ClaudeAttachmentFile(path: "", uploadId: uploadId, video: true, name: name, seconds: seconds)
    }
}

/// The lines added to Claude Code's prompt for a turn's images and videos. The upload id stays in the text: Claude passes
/// an image's to `suite_add_reference`, and a video's to `watch` (a video is never Read as an image).
public enum ClaudeAttachmentPrompt {
    /// How each video line starts (ChatLeakFilter strips from here on).
    public static let videoPrefix = "Attached video: uploadId "
    /// The image list's header.
    public static let imagesHeader = "Attached images (Read each one):"

    public static func text(_ text: String, _ files: [ClaudeAttachmentFile]) -> String {
        let images = files.filter { !$0.video }
        let videos = files.filter { $0.video && !$0.uploadId.isEmpty }
        guard !images.isEmpty || !videos.isEmpty else { return text }
        var blocks: [String] = []
        if !videos.isEmpty { blocks.append(videos.map(videoLine).joined(separator: "\n")) }
        if !images.isEmpty {
            // An image attached only on this Mac (Edit, Recreate, Camera) has no upload id: just its path.
            let list = images.map { $0.uploadId.isEmpty ? "- \($0.path)" : "- \($0.path) (uploadId \($0.uploadId))" }.joined(separator: "\n")
            blocks.append(imagesHeader + "\n" + list)
        }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text + "\n\n"
        return head + blocks.joined(separator: "\n\n")
    }

    /// `Attached video: uploadId up_1 (walk.mov, 0:12). Call watch {id: "up_1"} first to see it.`
    static func videoLine(_ f: ClaudeAttachmentFile) -> String {
        var about: [String] = []
        if let n = f.name?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), !n.isEmpty { about.append(n) }
        if let s = f.seconds, s > 0 { about.append(length(s)) }
        let what = about.isEmpty ? "" : " (\(about.joined(separator: ", ")))"
        return videoPrefix + f.uploadId + what + ". Call watch {id: \"\(f.uploadId)\"} first to see it."
    }

    /// A video's length as people read it: "0:12", "3:05", "1:02:07".
    public static func length(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }
}

/// upload_local_file's big files (ci_5c0e35ee5488, ci_9c7fc3adb445): a PUT that drops or stalls is tried again on the same
/// presigned link (valid an hour), and a failure says why in plain words instead of "Try again".
public enum ClaudeUploadRetry {
    public static let maxAttempts = 3
    /// Confirm reads the whole file back on the server (its fingerprint) and classifies its sound: minutes for a big clip.
    public static let confirmTimeout: TimeInterval = 300
    /// Pause before try n (n ≥ 2), seconds.
    public static func pause(beforeTry n: Int) -> Double { n <= 2 ? 2 : 6 }

    /// A failure worth another try: the connection dropped, stalled or was reset, or the store/server was briefly unwell.
    public static func retryable(_ error: Error) -> Bool {
        if let u = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed, .cannotFindHost].contains(u.code)
        }
        if let a = error as? ApiError { return ["http_500", "http_502", "http_503", "http_504", "http_408", "http_429"].contains(a.code) }
        return (error as NSError).domain == NSPOSIXErrorDomain
    }

    /// Plain words for why the file didn't go up.
    public static func why(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return "the connection stalled (nothing moved for 10 minutes)"
            case .networkConnectionLost: return "the connection dropped"
            case .notConnectedToInternet: return "this Mac is offline"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "the file store couldn't be reached"
            default: return u.localizedDescription
            }
        }
        if let a = error as? ApiError { return a.message }
        return error.localizedDescription
    }

    /// Runs `put` up to `attempts` times while the failure is retryable; the last failure is thrown with why.
    public static func run(attempts: Int = maxAttempts, onRetry: (@Sendable (Int) -> Void)?, sleep: @Sendable (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) },
                           _ put: @Sendable () async throws -> Void) async throws {
        var n = 1
        while true {
            do { try await put(); return } catch {
                guard n < attempts, retryable(error), !Task.isCancelled else {
                    throw ApiError("upload_failed", "The upload didn't finish after \(n) \(n == 1 ? "try" : "tries"): \(why(error)).")
                }
                n += 1
                onRetry?(n)
                await sleep(pause(beforeTry: n))
            }
        }
    }
}

/// Uploads a video for a Claude message: an upload of kind "clip" (presign → PUT → confirm), so the server keeps it and
/// Claude can watch it. → its upload id (the attachment is marked as a video).
public protocol ClaudeVideoUploading: Sendable {
    func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?) async throws -> ClaudeAttachment
    /// With retries of a dropped PUT (`onRetry` hears try n) and a long confirm (upload_local_file).
    func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?, onRetry: (@Sendable (Int) -> Void)?) async throws -> ClaudeAttachment
}
public extension ClaudeVideoUploading {
    func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?, onRetry: (@Sendable (Int) -> Void)?) async throws -> ClaudeAttachment {
        try await uploadClaudeVideo(file, meta: meta, contentType: contentType, progress: progress)
    }
}

/// The Claude chat's own API (the service holds this one): the same upload as HTTPMuseAPI's, signed in with the same token.
extension HTTPClaudeAPI: ClaudeVideoUploading {
    public func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?) async throws -> ClaudeAttachment {
        try await uploadClaudeVideo(file, meta: meta, contentType: contentType, progress: progress, onRetry: nil)
    }
    public func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?, onRetry: (@Sendable (Int) -> Void)?) async throws -> ClaudeAttachment {
        let http = HTTPMuseAPI(baseURL: baseURL)
        if let tok = currentToken { await http.setToken(tok) }
        return try await http.uploadClaudeVideo(file, meta: meta, contentType: contentType, progress: progress, onRetry: onRetry)
    }
}

/// upload_local_file: an image from the Mac, uploaded the chat's way (presign, PUT, confirm; the server strips its metadata).
public protocol ClaudeImageUploading: Sendable {
    func uploadClaudeImage(name: String, data: Data, mime: String) async throws -> ClaudeAttachment
}
extension HTTPClaudeAPI: ClaudeImageUploading {
    public func uploadClaudeImage(name: String, data: Data, mime: String) async throws -> ClaudeAttachment {
        let http = HTTPMuseAPI(baseURL: baseURL)
        if let tok = currentToken { await http.setToken(tok) }
        return try await http.uploadClaudeImage(name: name, data: data, mime: mime)
    }
}
extension FakeClaudeAPI: ClaudeImageUploading {
    public func uploadClaudeImage(name: String, data: Data, mime: String) async throws -> ClaudeAttachment {
        ClaudeAttachment(uploadId: "up_" + shortId(), mimeType: mime, bytes: data.count)
    }
}

/// upload_local_file: a sound from the Mac (ci_de89873ab1de), uploaded as an editor audio upload (POST
/// /v1/editor/uploads/presign + PUT), so Edit and Claude's edit tools take it as an audio asset. → its upload id.
public protocol ClaudeAudioUploading: Sendable {
    func uploadClaudeAudio(_ file: URL, contentType: String) async throws -> String
    /// With progress and retries of a dropped PUT (upload_local_file).
    func uploadClaudeAudio(_ file: URL, contentType: String, progress: UploadProgress?, onRetry: (@Sendable (Int) -> Void)?) async throws -> String
}
public extension ClaudeAudioUploading {
    func uploadClaudeAudio(_ file: URL, contentType: String, progress: UploadProgress?, onRetry: (@Sendable (Int) -> Void)?) async throws -> String {
        try await uploadClaudeAudio(file, contentType: contentType)
    }
}
extension HTTPClaudeAPI: ClaudeAudioUploading {
    public func uploadClaudeAudio(_ file: URL, contentType: String) async throws -> String {
        try await uploadClaudeAudio(file, contentType: contentType, progress: nil, onRetry: nil)
    }
    public func uploadClaudeAudio(_ file: URL, contentType: String, progress: UploadProgress?, onRetry: (@Sendable (Int) -> Void)?) async throws -> String {
        let http = HTTPMuseAPI(baseURL: baseURL)
        if let tok = currentToken { await http.setToken(tok) }
        return try await http.uploadClaudeAudio(file, contentType: contentType, progress: progress, onRetry: onRetry)
    }
}
extension FakeClaudeAPI: ClaudeAudioUploading {
    public func uploadClaudeAudio(_ file: URL, contentType: String) async throws -> String { "up_" + shortId() }
}

/// Demo mode: nothing leaves this Mac; the video gets a made-up upload id.
extension FakeClaudeAPI: ClaudeVideoUploading {
    public func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?) async throws -> ClaudeAttachment {
        progress?(1)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        return ClaudeAttachment(uploadId: "up_" + shortId(), mimeType: contentType, bytes: size, video: true)
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
    /// A video is not downloaded: it goes to Claude as its upload id, to watch.
    public static func download(_ a: ClaudeAttachment, threadId: String, base: URL?) async -> ClaudeAttachmentFile? {
        if a.isVideo { return a.uploadId.isEmpty ? nil : .video(uploadId: a.uploadId) }
        guard let raw = a.url, !raw.isEmpty else { return nil }
        let url: URL? = raw.hasPrefix("/") ? base.flatMap { URL(string: raw, relativeTo: $0)?.absoluteURL } : URL(string: raw)
        guard let url, let result = try? await URLSession.shared.data(from: url) else { return nil }
        let (data, resp) = result
        let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        guard ok, !data.isEmpty else { return nil }
        return save(data, attachment: a, threadId: threadId)
    }
}
