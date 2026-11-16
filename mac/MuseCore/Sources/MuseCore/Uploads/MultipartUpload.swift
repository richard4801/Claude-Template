import Foundation

/// Large uploads in parts (owner 2026-11-16: edit footage up to 60 minutes and 2 GB, from a file or a link). A file
/// over `threshold` goes up as 64 MB parts to presigned URLs (server/api/src/routes/multipart.ts):
///   POST /v1/uploads/{id}/multipart {bytes} → the parts' URLs; PUT each part, keep its ETag;
///   on a dropped connection GET /v1/uploads/{id}/multipart?multipartId= → what arrived + fresh URLs (resume);
///   POST /v1/uploads/{id}/multipart/complete {multipartId, parts:[{n, etag}]}.
/// A server without the routes (404) gets the single PUT, as before. This file is the pure part (tested on Linux).
public enum MultipartUpload {
    /// Files at least this big go up in parts (smaller ones: one PUT).
    public static let threshold = 100 * 1_048_576
    /// The longest file the apps import or upload: 2 GB (the server says so too).
    public static let maxBytes = 2 * 1024 * 1_048_576
    /// Tries per run of parts before giving up (each retry resumes from what the server has).
    public static let maxAttempts = 4

    public static func usesParts(size: Int?) -> Bool { (size ?? 0) >= threshold }

    /// The byte range of part `n` (1-based) of a `total`-byte file in `partSize` parts.
    public static func range(part n: Int, partSize: Int, total: Int) -> Range<Int> {
        let lo = (n - 1) * partSize
        return lo..<min(total, lo + partSize)
    }

    /// Reads one part from disk (one part in memory at a time, never the whole file).
    public static func read(_ file: URL, _ r: Range<Int>) throws -> Data {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(r.lowerBound))
        let d = try h.read(upToCount: r.count) ?? Data()
        guard d.count == r.count else { throw ApiError("upload_failed", "The file changed while it was uploading · try again") }
        return d
    }

    /// Pauses between attempts: 2 s, 6 s, 15 s.
    public static func pause(attempt: Int) -> Double { [2, 6, 15][min(max(attempt, 1), 3) - 1] }

    /// A failure worth resuming after (the network, the server busy); a refusal is not.
    public static func retryable(_ e: Error) -> Bool {
        if e is URLError { return true }
        if let a = e as? ApiError {
            if ["offline", "still_working"].contains(a.code) { return true }
            if a.code.hasPrefix("http_"), let s = Int(a.code.dropFirst(5)) { return s >= 500 || s == 408 || s == 429 }
        }
        return false
    }

    /// The server's answer to start and resume.
    public struct Ticket: Decodable, Sendable {
        public struct Part: Decodable, Sendable { public var n: Int; public var url: String }
        public struct Done: Decodable, Sendable { public var n: Int; public var etag: String; public var size: Int }
        public var uploadId: String
        public var multipartId: String
        public var partSize: Int
        public var partCount: Int
        public var parts: [Part]
        public var done: [Done]?
    }
    struct StartBody: Encodable { var bytes: Int }
    struct CompleteBody: Encodable { struct P: Encodable { var n: Int; var etag: String }; var multipartId: String; var parts: [P] }
    struct Completed: Decodable { var uploadId: String; var bytes: Int }

    /// The whole upload's progress (0…1) from its parts: finished ones count in full, the one in flight by its share.
    public final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Int
        private var finished: [Int: Int] = [:]
        private var inFlight: [Int: Int] = [:]
        public init(total: Int) { self.total = max(1, total) }
        public func sending(_ n: Int, bytes: Int) { lock.lock(); inFlight[n] = bytes; lock.unlock() }
        public func finish(_ n: Int, bytes: Int) { lock.lock(); finished[n] = bytes; inFlight[n] = nil; lock.unlock() }
        public func drop(_ n: Int) { lock.lock(); inFlight[n] = nil; lock.unlock() }
        public var fraction: Double {
            lock.lock(); defer { lock.unlock() }
            return min(1, Double(finished.values.reduce(0, +) + inFlight.values.reduce(0, +)) / Double(total))
        }
    }
}

/// The import limits in the apps' words (mirrors server/api/src/imports/limits.ts): "Up to 60 minutes and 2 GB".
public enum ImportLimitText {
    public static func length(_ maxSec: Int) -> String { maxSec % 60 == 0 && maxSec >= 120 ? "\(maxSec / 60) minutes" : "\(maxSec) seconds" }
    public static func size(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1024 { return "\(max(1, Int(mb.rounded()))) MB" }
        let gb = (mb / 1024 * 10).rounded() / 10
        return gb.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }
    public static func limit(maxSec: Int, maxMb: Int) -> String { "Up to \(length(maxSec)) and \(size(maxMb * 1_048_576))" }
    /// A file from this Mac over the import limits (60 minutes, 2 GB by default; the server checks again): why, naming
    /// the limit that was hit, else nil.
    public static func problem(durationSec: Double?, bytes: Int?, maxSec: Int = 3600, maxMb: Int = 2048) -> String? {
        let rule = "imports: " + limit(maxSec: maxSec, maxMb: maxMb).replacingOccurrences(of: "Up to", with: "up to")
        if let d = durationSec, d.isFinite, d > Double(maxSec) + 0.5 { return "This video is \(duration(d)) long · the limit is \(length(maxSec)) (\(rule))" }
        if let b = bytes, b > maxMb * 1_048_576 { return "This video is \(size(b)) · the limit is \(size(maxMb * 1_048_576)) (\(rule))" }
        return nil
    }
    /// "42 s", "12 min", "1 h 2 min".
    public static func duration(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        if s < 120 { return "\(s) s" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}
