import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// BlenderRelayAPI over HTTP: the relay endpoints, camera-session assets and the `blender` live events.
/// The token comes from a closure so the app keeps owning the session (it's read per request, never cached here).
public final class HTTPBlenderRelayAPI: BlenderRelayAPI, @unchecked Sendable {
    public let baseURL: URL
    private let token: @Sendable () -> String?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    // MARK: Plumbing

    func url(_ path: String) -> URL {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s + path)!
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp): (Data, URLResponse?)
        do {
            (data, resp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse?), Error>) in
                session.dataTask(with: r) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
                }.resume()
            }
        } catch {
            throw ApiError("offline", "Can't reach the server at \(baseURL.absoluteString)")
        }
        try check(resp, data)
        return data
    }

    private func check(_ resp: URLResponse?, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let err = try? decoder.decode(ErrorBody.self, from: data)
        throw ApiError(err?.code ?? "http_\(http.statusCode)", err?.error ?? "Server error \(http.statusCode)")
    }

    private func call<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try decode(try await send(request(method, path)))
    }

    private func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B) async throws -> T {
        try decode(try await send(request(method, path, body: try encoder.encode(body))))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw ApiError("bad_response", "Unexpected reply from the server (\(T.self))") }
    }

    /// Ids go into paths: only the id alphabet is allowed.
    private func key(_ id: String) throws -> String {
        guard BlenderArgs.isId(id) else { throw ApiError("bad_request", "Bad id") }
        return id
    }

    // MARK: BlenderRelayAPI

    public func heartbeat(_ status: BlenderRelayStatus) async throws -> BlenderHeartbeatReply { try await call("POST", "v1/blender/relay", status) }

    public func pendingCalls() async throws -> [BlenderCall] { try await call("GET", "v1/blender/calls") }

    public func claim(callId: String) async throws -> BlenderCall { try await call("POST", "v1/blender/calls/\(try key(callId))/claim", Empty()) }

    public func postResult(callId: String, _ result: BlenderCallResult) async throws {
        _ = try await send(request("POST", "v1/blender/calls/\(try key(callId))/result", body: try encoder.encode(result)))
    }

    public func createAsset(sessionId: String, kind: String, contentType: String, bytes: Int64?, label: String?) async throws -> CameraAssetUpload {
        try await call("POST", "v1/camera-sessions/\(try key(sessionId))/assets?source=relay", CameraAssetRequest(kind: kind, contentType: contentType, bytes: bytes, label: label))
    }

    public func confirmAsset(sessionId: String, assetId: String) async throws -> CameraAsset {
        try await call("POST", "v1/camera-sessions/\(try key(sessionId))/assets/\(try key(assetId))/confirm", Empty())
    }

    public func putUpload(url link: String, headers: [String: String], contentType: String, file: URL) async throws {
        // Storage gets the presigned URL's headers only. A relative link (local storage on a dev server) is this API: it gets the token.
        let relative = link.hasPrefix("/")
        guard let target = relative ? url(String(link.dropFirst())) : URL(string: link), ["https", "http"].contains(target.scheme?.lowercased() ?? "") else {
            throw ApiError("bad_response", "Bad upload link")
        }
        var r = URLRequest(url: target)
        r.httpMethod = "PUT"
        r.timeoutInterval = 600
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if r.value(forHTTPHeaderField: "Content-Type") == nil { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if relative, let t = token() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
            session.uploadTask(with: r, fromFile: file) { d, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
            }.resume()
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            _ = data
            throw ApiError("http_\(http.statusCode)", "Upload refused (\(http.statusCode))")
        }
    }

    // MARK: Live events

    /// `blender` events from GET /v1/events. Reconnects with back-off while someone listens.
    /// (Linux builds have no streaming bytes API: they poll GET /v1/blender/calls instead.)
    public func events() -> AsyncStream<BlenderLiveEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(128)) { cont in
            let task = Task { [weak self] in
                var attempt = 0
                while !Task.isCancelled, let self {
                    do {
                        try await self.stream { e in
                            attempt = 0
                            cont.yield(e)
                        }
                    } catch {
                        attempt += 1
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: UInt64(min(10, attempt + 1)) * 1_000_000_000)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ yield: @escaping (BlenderLiveEvent) -> Void) async throws {
        #if canImport(FoundationNetworking)
        while !Task.isCancelled {
            for c in try await pendingCalls() { yield(.call(c)) }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        #else
        var r = request("GET", "v1/events", timeout: 40) // the server sends a comment every 10 s
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await session.bytes(for: r)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ApiError("http_\(http.statusCode)", "Event stream refused") }
        var filter = BlenderLiveEventFilter()
        var line = [UInt8]()
        for try await b in bytes {
            if b == 0x0A {
                if let e = filter.feed(String(decoding: line, as: UTF8.self)) { yield(e) }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(b)
            }
        }
        #endif
    }
}
