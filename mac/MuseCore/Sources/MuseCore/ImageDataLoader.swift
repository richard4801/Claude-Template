import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Performance pass (plans/perf-audit.md "Mac"): image bytes for the app's image views. One download per URL however many
/// tiles ask at once (the old loader answered a second asker with nothing, so that tile stayed a placeholder), over a
/// dedicated URLCache big enough to keep images on disk (the shared cache is 512 KB / 10 MB and skips anything over
/// about 5 % of that). The server's `cache-control: max-age` decides how long a file is reused. Decoding and downsampling
/// to the display size happen in the app (ImageIO), off the main thread.
public final class ImageDataLoader: @unchecked Sendable {
    public static let shared = ImageDataLoader()

    public let session: URLSession
    private let coalescer = RequestCoalescer<Data>()
    private let lock = NSLock()
    private var _downloads = 0

    public init(session: URLSession? = nil, memoryBytes: Int = 16 << 20, diskBytes: Int = 512 << 20) {
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.default
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("MUSE/images", isDirectory: true)
            #if canImport(FoundationNetworking)
            c.urlCache = URLCache(memoryCapacity: memoryBytes, diskCapacity: diskBytes, diskPath: dir?.path)
            #else
            c.urlCache = URLCache(memoryCapacity: memoryBytes, diskCapacity: diskBytes, directory: dir)
            #endif
            c.requestCachePolicy = .useProtocolCachePolicy
            c.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: c)
        }
    }

    /// Downloads started (not counting callers that joined one in flight).
    public var downloads: Int { lock.lock(); defer { lock.unlock() }; return _downloads }
    /// Callers answered by a download already in flight.
    public var joined: Int { coalescer.joined }

    public func data(for url: URL) async throws -> Data {
        try await coalescer.run(url.absoluteString) { [self] in
            countDownload()
            let req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)
            let (data, resp): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
                session.dataTask(with: req) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
                }.resume()
            }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ApiError("http_\(http.statusCode)", "Image not available") }
            return data
        }
    }

    private func countDownload() {
        lock.lock()
        _downloads += 1
        lock.unlock()
    }

    /// The display-size bucket (longest side, in pixels) an image is decoded at: a few fixed steps so a tile that grows by
    /// a few points reuses its decode, and a 200 pt tile on a 2× screen gets a 512 px image instead of a 2–4K original.
    public static func pixelBucket(width: Double, height: Double, scale: Double) -> Int {
        let need = Int((max(width, height) * max(1, scale)).rounded(.up))
        guard need > 0 else { return 0 }
        for b in buckets where b >= need { return b }
        return buckets.last!
    }

    public static let buckets = [128, 256, 384, 512, 768, 1024, 1536, 2048, 3072]
}
