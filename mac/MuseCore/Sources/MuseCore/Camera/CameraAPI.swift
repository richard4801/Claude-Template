import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The camera-session endpoints the Directed mode, Direct with Claude and Settings → Connections use (plans/api.md
/// "MCP & camera sessions"). Owner only. Kept apart from MuseAPI so the shared client files stay untouched.
public protocol CameraAPI: Sendable {
    func listSessions() async throws -> [CameraSession]
    func session(_ id: String) async throws -> CameraSession
    func createSession(_ req: CameraSessionCreate) async throws -> CameraSession
    func patchSession(_ id: String, _ patch: CameraSessionPatch) async throws -> CameraSession
    func deleteSession(_ id: String) async throws
    func postNote(_ id: String, text: String) async throws -> CameraMessage
    func setPath(_ id: String, _ update: CameraPathUpdate) async throws -> CameraSession
    func createShotDraft(_ id: String, _ req: CameraShotDraftRequest) async throws -> CameraShotDraft
    func linkJob(_ id: String, jobId: String) async throws -> CameraSession
    /// POST …/chat: the turn's events. Errors before the stream opens (`chat_busy`, `director_unavailable`) are thrown as ApiError.
    func chat(_ id: String, message: String) -> AsyncThrowingStream<ChatEvent, Error>
    func connections() async throws -> CameraConnections
    func tokens() async throws -> [McpToken]
    func createToken(name: String, expiresDays: Int?) async throws -> McpTokenCreated
    func revokeToken(_ id: String) async throws
    /// `camera` live events and the relay presence; `.connected` each time the stream (re)opens.
    func events() -> AsyncStream<CameraLiveEvent>
}

/// Session ids go into paths: only the id alphabet.
enum CameraIds {
    static func check(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 80, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw ApiError("bad_request", "Bad id")
        }
        return id
    }
}

/// CameraAPI over HTTP. The token is read per request from a closure, like the Blender relay (works with "Remember me" off):
///     HTTPCameraAPI(baseURL: http.baseURL) { [http] in http.sessionToken }
public final class HTTPCameraAPI: CameraAPI, @unchecked Sendable {
    public let baseURL: URL
    private let token: @Sendable () -> String?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The app's one shared GET /v1/events connection (performance pass).
    private let hub: LiveEventHub

    public init(baseURL: URL, session: URLSession = .shared, hub: LiveEventHub = .shared, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.hub = hub
        self.token = token
    }

    // MARK: Plumbing

    func url(_ path: String) -> URL {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s + path)!
    }

    func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
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
        try Self.check(resp, data, decoder)
        return data
    }

    static func check(_ resp: URLResponse?, _ data: Data, _ decoder: JSONDecoder = JSONDecoder()) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let err = try? decoder.decode(ErrorBody.self, from: data)
        throw ApiError(err?.code ?? "http_\(http.statusCode)", err?.error ?? ApiError.plainHTTP(http.statusCode))
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

    private struct Note: Encodable { var text: String }
    private struct Job: Encodable { var jobId: String }
    private struct Chat: Encodable { var message: String }
    private struct NewToken: Encodable { var name: String; var expiresDays: Int? }
    private struct NoBody: Codable {}

    // MARK: Sessions

    public func listSessions() async throws -> [CameraSession] { try await call("GET", "v1/camera-sessions") }
    public func session(_ id: String) async throws -> CameraSession { try await call("GET", "v1/camera-sessions/\(try CameraIds.check(id))") }
    public func createSession(_ req: CameraSessionCreate) async throws -> CameraSession { try await call("POST", "v1/camera-sessions", req) }
    public func patchSession(_ id: String, _ patch: CameraSessionPatch) async throws -> CameraSession {
        try await call("PATCH", "v1/camera-sessions/\(try CameraIds.check(id))", patch)
    }
    public func deleteSession(_ id: String) async throws { _ = try await send(request("DELETE", "v1/camera-sessions/\(try CameraIds.check(id))")) }
    public func postNote(_ id: String, text: String) async throws -> CameraMessage {
        try await call("POST", "v1/camera-sessions/\(try CameraIds.check(id))/messages", Note(text: text))
    }
    public func setPath(_ id: String, _ update: CameraPathUpdate) async throws -> CameraSession {
        try await call("PUT", "v1/camera-sessions/\(try CameraIds.check(id))/path", update)
    }
    public func createShotDraft(_ id: String, _ req: CameraShotDraftRequest) async throws -> CameraShotDraft {
        try await call("POST", "v1/camera-sessions/\(try CameraIds.check(id))/shot-draft", req)
    }
    public func linkJob(_ id: String, jobId: String) async throws -> CameraSession {
        try await call("POST", "v1/camera-sessions/\(try CameraIds.check(id))/shot-draft/job", Job(jobId: jobId))
    }

    // MARK: Chat

    public func chat(_ id: String, message: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [weak self] in
                guard let self else { cont.finish(); return }
                do {
                    var r = self.request("POST", "v1/camera-sessions/\(try CameraIds.check(id))/chat", body: try self.encoder.encode(Chat(message: message)), timeout: 600)
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    #if canImport(FoundationNetworking)
                    // Linux has no byte stream: the whole turn arrives at once.
                    let data = try await self.send(r)
                    for e in ChatStreamParser.parseAll(String(decoding: data, as: UTF8.self)) { cont.yield(e) }
                    #else
                    let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, resp) = try await self.session.bytes(for: r) } catch {
                        throw ApiError("offline", "Can't reach the server at \(self.baseURL.absoluteString)")
                    }
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        try Self.check(resp, body, self.decoder)
                    }
                    var parser = ChatStreamParser()
                    var line = [UInt8]()
                    for try await b in bytes {
                        if Task.isCancelled { break }
                        if b == 0x0A {
                            if let e = parser.feed(String(decoding: line, as: UTF8.self)) { cont.yield(e) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(b)
                        }
                    }
                    if let e = parser.feed(String(decoding: line, as: UTF8.self)) { cont.yield(e) }
                    if let e = parser.feed("") { cont.yield(e) }
                    #endif
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Connections and tokens

    public func connections() async throws -> CameraConnections { try await call("GET", "v1/connections") }
    public func tokens() async throws -> [McpToken] { try await call("GET", "v1/mcp/tokens") }
    public func createToken(name: String, expiresDays: Int?) async throws -> McpTokenCreated {
        try await call("POST", "v1/mcp/tokens", NewToken(name: name, expiresDays: expiresDays))
    }
    public func revokeToken(_ id: String) async throws { _ = try await send(request("DELETE", "v1/mcp/tokens/\(try CameraIds.check(id))")) }

    // MARK: Live events

    /// GET /v1/events filtered to camera sessions and the relay. Reconnects with back-off while someone listens.
    /// (Linux builds have no streaming bytes API: they poll the list every 5 s instead.)
    public func events() -> AsyncStream<CameraLiveEvent> {
        // Apple platforms: the app's shared stream (LiveEventHub), mapped to these events. Linux: the polling fallback below.
        if hub.canStream {
            return hub.events(baseURL: baseURL, token: token(), session: session, buffer: 256) { f -> CameraLiveEvent? in
                switch f {
                case .connected: return .connected
                case .disconnected: return .disconnected
                case .payload(let p): return CameraLiveEvent.parse(Data(p.utf8))
                }
            }
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont in
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
                    cont.yield(.disconnected)
                    try? await Task.sleep(nanoseconds: UInt64(min(10, attempt + 1)) * 1_000_000_000)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ yield: @escaping (CameraLiveEvent) -> Void) async throws {
        #if canImport(FoundationNetworking)
        var first = true
        while !Task.isCancelled {
            let list = try await listSessions()
            if first { yield(.connected); first = false }
            for s in list { yield(.upsert(s)) }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        #else
        // Apple platforms stream through the shared hub (`events()`); this fallback is never reached there.
        throw ApiError("offline", "Live updates aren't available")
        #endif
    }
}
