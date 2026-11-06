import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/v1/claude/*` endpoints and the Mac's MCP session token (plans/api.md "Claude on the owner's plan"). Owner only.
/// Kept apart from MuseAPI so the shared client files stay untouched.
public protocol ClaudeAPI: Sendable {
    func status() async throws -> ClaudeStatus
    /// PATCH /v1/claude/settings. Off by default; billed per use.
    func setApiFallback(_ on: Bool) async throws -> ClaudeStatus
    func heartbeat(_ info: ClaudeCodeInfo) async throws -> ClaudeHeartbeatReply
    /// Get or create the thread of a camera or edit session.
    func thread(contextKind: String, contextId: String) async throws -> ClaudeThread
    func threadDetail(_ id: String) async throws -> ClaudeThreadDetail
    func setClaudeSession(threadId: String, claudeSessionId: String) async throws -> ClaudeThread
    /// From a device that can't run Claude (the phone; the Mac uses it only in tests). `mac_offline` / `claude_busy` are thrown.
    func postMessage(threadId: String, text: String) async throws -> ClaudeMessagePosted
    func pendingTurns() async throws -> [ClaudeTurn]
    func claim(turnId: String) async throws -> ClaudeTurn
    func stopTurn(_ turnId: String) async throws
    /// POST …/events: the Mac's mirror of its local Claude Code stream (≤ 4 MB a call).
    func postEvents(threadId: String, _ batch: ClaudeEventBatch) async throws
    /// The studio API key fallback (camera threads only for now): ChatEvents like the camera chat. `fallback_off` is thrown.
    func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error>
    func mcpSessionToken(ttlMinutes: Int?) async throws -> McpSessionToken
    /// `claude` live events; `.connected` each time the stream (re)opens.
    func events() -> AsyncStream<ClaudeLiveEvent>
}

enum ClaudeIds {
    static func check(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 120, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw ApiError("bad_request", "Bad id")
        }
        return id
    }
}

/// ClaudeAPI over HTTP. The token is read per request from a closure, like the Blender relay:
///     HTTPClaudeAPI(baseURL: http.baseURL) { [http] in http.sessionToken }
public final class HTTPClaudeAPI: ClaudeAPI, @unchecked Sendable {
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
        try HTTPCameraAPI.check(resp, data, decoder)
        return data
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

    private struct Settings: Encodable { var apiFallback: Bool }
    private struct NewThread: Encodable { var contextKind: String; var contextId: String }
    private struct SessionPatch: Encodable { var claudeSessionId: String }
    private struct Text: Encodable { var text: String }
    private struct TokenReq: Encodable { var ttlMinutes: Int? }

    // MARK: ClaudeAPI

    public func status() async throws -> ClaudeStatus { try await call("GET", "v1/claude/status") }
    public func setApiFallback(_ on: Bool) async throws -> ClaudeStatus { try await call("PATCH", "v1/claude/settings", Settings(apiFallback: on)) }
    public func heartbeat(_ info: ClaudeCodeInfo) async throws -> ClaudeHeartbeatReply { try await call("POST", "v1/claude/mac/heartbeat", ClaudeHeartbeat(claudeCode: info)) }
    public func thread(contextKind: String, contextId: String) async throws -> ClaudeThread {
        try await call("POST", "v1/claude/threads", NewThread(contextKind: contextKind, contextId: contextId))
    }
    public func threadDetail(_ id: String) async throws -> ClaudeThreadDetail { try await call("GET", "v1/claude/threads/\(try ClaudeIds.check(id))") }
    public func setClaudeSession(threadId: String, claudeSessionId: String) async throws -> ClaudeThread {
        try await call("PATCH", "v1/claude/threads/\(try ClaudeIds.check(threadId))", SessionPatch(claudeSessionId: claudeSessionId))
    }
    public func postMessage(threadId: String, text: String) async throws -> ClaudeMessagePosted {
        try await call("POST", "v1/claude/threads/\(try ClaudeIds.check(threadId))/messages", Text(text: text))
    }
    public func pendingTurns() async throws -> [ClaudeTurn] { try await call("GET", "v1/claude/turns") }
    public func claim(turnId: String) async throws -> ClaudeTurn { try await call("POST", "v1/claude/turns/\(try ClaudeIds.check(turnId))/claim", Empty()) }
    public func stopTurn(_ turnId: String) async throws { _ = try await send(request("POST", "v1/claude/turns/\(try ClaudeIds.check(turnId))/stop", body: Data("{}".utf8))) }
    public func postEvents(threadId: String, _ batch: ClaudeEventBatch) async throws {
        _ = try await send(request("POST", "v1/claude/threads/\(try ClaudeIds.check(threadId))/events", body: try encoder.encode(batch), timeout: 60))
    }
    public func mcpSessionToken(ttlMinutes: Int?) async throws -> McpSessionToken { try await call("POST", "v1/mcp/session-token", TokenReq(ttlMinutes: ttlMinutes)) }

    public func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [weak self] in
                guard let self else { cont.finish(); return }
                do {
                    var r = self.request("POST", "v1/claude/threads/\(try ClaudeIds.check(threadId))/api-turn", body: try self.encoder.encode(Text(text: text)), timeout: 600)
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    #if canImport(FoundationNetworking)
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
                        try HTTPCameraAPI.check(resp, body, self.decoder)
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

    // MARK: Live events

    /// GET /v1/events filtered to `claude`. Reconnects with back-off while someone listens.
    /// (Linux builds have no streaming bytes API: they poll the queued turns every 5 s instead.)
    public func events() -> AsyncStream<ClaudeLiveEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont in
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

    private func stream(_ yield: @escaping (ClaudeLiveEvent) -> Void) async throws {
        #if canImport(FoundationNetworking)
        var first = true
        while !Task.isCancelled {
            let turns = try await pendingTurns()
            if first { yield(.connected); first = false }
            for t in turns { yield(.turn(t)) }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        #else
        var r = request("GET", "v1/events", timeout: 40) // the server sends a comment every 10 s
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await session.bytes(for: r)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ApiError("http_\(http.statusCode)", "Event stream refused") }
        yield(.connected)
        var filter = ClaudeLiveEventFilter()
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
