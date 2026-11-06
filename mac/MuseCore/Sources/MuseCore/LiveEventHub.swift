import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One frame of the shared GET /v1/events stream, before each consumer picks out its own events.
public enum LiveFrame: Sendable, Equatable {
    /// The stream opened (sent again after every reconnect, and at once to a subscriber that joins an open stream).
    case connected
    /// One SSE event's `data` payload (JSON).
    case payload(String)
    /// The stream dropped or couldn't connect; the hub retries with back-off.
    case disconnected
}

/// Performance pass (plans/perf-audit.md "Mac"): ONE GET /v1/events per server and session, fanned out to every listener.
/// The app's store, the Edit suite, the camera sessions, Claude Code and the Blender relay each used to open their own
/// stream (up to five long-lived connections, each parsing every event). Now each `events()` subscribes here and maps the
/// shared frames to its own event type. The connection opens with the first subscriber, closes with the last, reconnects
/// with back-off (1 s after a drop, up to 10 s while it can't connect), and `reconnect(baseURL:)` restarts it on demand
/// (network change, wake from sleep).
public final class LiveEventHub: @unchecked Sendable {
    /// Opens one SSE request; calls `onOpen` once the server accepted it and `onLine` for each line (without its line end),
    /// and returns when the stream ends. Throws when it can't connect or the server refuses.
    public typealias Transport = @Sendable (_ session: URLSession, _ request: URLRequest, _ onOpen: @escaping @Sendable () -> Void,
                                            _ onLine: @escaping @Sendable (String) -> Void) async throws -> Void

    public static let shared = LiveEventHub()

    private struct Key: Hashable {
        var base: String
        var token: String
        var session: ObjectIdentifier
    }

    private final class Channel {
        var subscribers: [UUID: @Sendable (LiveFrame) -> Void] = [:]
        var task: Task<Void, Never>?
        var generation = 0
        var open = false
        var lastActivity = Date.distantPast
        let request: URLRequest
        let session: URLSession
        init(request: URLRequest, session: URLSession) {
            self.request = request
            self.session = session
        }
    }

    private let lock = NSLock()
    private var channels: [Key: Channel] = [:]
    private let transport: Transport?
    private let retryDelay: @Sendable (Int) -> UInt64
    /// Connections opened over the hub's life (for tests and the debug readout).
    public private(set) var opens = 0

    /// `transport` nil: URLSession's streaming bytes (Apple platforms). Linux has none, so there `canStream` is false and
    /// the API clients keep their polling fallback.
    public init(transport: Transport? = nil, retryDelay: @escaping @Sendable (Int) -> UInt64 = { attempt in UInt64(min(10, attempt + 1)) * 1_000_000_000 }) {
        self.transport = transport ?? LiveEventHub.urlSessionTransport
        self.retryDelay = retryDelay
    }

    public var canStream: Bool { transport != nil }

    /// Open connections right now.
    public var openConnections: Int { lock.lock(); defer { lock.unlock() }; return channels.values.filter { $0.task != nil }.count }
    /// Listeners across all connections.
    public var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return channels.values.reduce(0) { $0 + $1.subscribers.count } }

    /// The stream for `baseURL` is open and sent something (an event or the server's 10 s keep-alive) within `within` seconds.
    public func isHealthy(baseURL: URL, within: TimeInterval = 25, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return channels.contains { $0.key.base == baseURL.absoluteString && $0.value.open && now.timeIntervalSince($0.value.lastActivity) < within }
    }

    /// Frames mapped to a consumer's own events. `map` runs off the main thread, on the hub's reader.
    public func events<T: Sendable>(baseURL: URL, token: String?, session: URLSession = .shared, buffer: Int = 256,
                                    _ map: @escaping @Sendable (LiveFrame) -> T?) -> AsyncStream<T> {
        AsyncStream(bufferingPolicy: .bufferingNewest(buffer)) { cont in
            let id = self.subscribe(baseURL: baseURL, token: token, session: session) { f in
                if let v = map(f) { cont.yield(v) }
            }
            cont.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        }
    }

    /// Restarts every connection to `baseURL` (its listeners stay subscribed and get `.disconnected` then `.connected`).
    public func reconnect(baseURL: URL) {
        lock.lock()
        let keys = channels.keys.filter { $0.base == baseURL.absoluteString }
        for k in keys { start(k) }
        lock.unlock()
    }

    // MARK: Subscriptions

    private var owners: [UUID: Key] = [:]
    private var nextGeneration = 0

    private func subscribe(baseURL: URL, token: String?, session: URLSession, _ sink: @escaping @Sendable (LiveFrame) -> Void) -> UUID {
        let key = Key(base: baseURL.absoluteString, token: token ?? "", session: ObjectIdentifier(session))
        let id = UUID()
        lock.lock()
        let ch: Channel
        if let c = channels[key] {
            ch = c
        } else {
            ch = Channel(request: Self.request(baseURL: baseURL, token: token), session: session)
            channels[key] = ch
        }
        ch.subscribers[id] = sink
        owners[id] = key
        let joinOpen = ch.open
        if ch.task == nil { start(key) }
        lock.unlock()
        if joinOpen { sink(.connected) }
        return id
    }

    private func unsubscribe(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let key = owners.removeValue(forKey: id), let ch = channels[key] else { return }
        ch.subscribers[id] = nil
        if ch.subscribers.isEmpty {
            ch.generation = -1
            ch.task?.cancel()
            ch.task = nil
            ch.open = false
            channels[key] = nil
            parsers[key] = nil
        }
    }

    // MARK: The connection (lock held by callers of `start`)

    private func start(_ key: Key) {
        guard let ch = channels[key], let transport else { return }
        ch.task?.cancel()
        nextGeneration += 1
        ch.generation = nextGeneration // hub-wide, so a cancelled reader never matches a newer channel for the same key
        ch.open = false
        let gen = ch.generation
        let request = ch.request, session = ch.session
        ch.task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let opened = OpenFlag()
                do {
                    try await transport(session, request, {
                        opened.set()
                        self.update(key, gen) { $0.open = true; $0.lastActivity = Date() }
                        self.countOpen()
                        self.broadcast(key, gen, .connected)
                    }, { line in
                        self.feed(key, gen, line)
                    })
                    attempt = 0
                } catch {
                    attempt = opened.value ? 0 : attempt + 1
                }
                if Task.isCancelled || !self.isCurrent(key, gen) { return }
                self.update(key, gen) { $0.open = false }
                self.broadcast(key, gen, .disconnected)
                try? await Task.sleep(nanoseconds: self.retryDelay(attempt))
            }
        }
    }

    private func countOpen() {
        lock.lock()
        opens += 1
        lock.unlock()
    }

    private func isCurrent(_ key: Key, _ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return channels[key]?.generation == gen
    }

    private func update(_ key: Key, _ gen: Int, _ change: (Channel) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let ch = channels[key], ch.generation == gen else { return }
        change(ch)
    }

    /// Per-connection SSE parsers, touched only from that connection's reader task.
    private var parsers: [Key: SSEParser] = [:]

    private func feed(_ key: Key, _ gen: Int, _ line: String) {
        lock.lock()
        guard let ch = channels[key], ch.generation == gen else { lock.unlock(); return }
        ch.lastActivity = Date()
        var p = parsers[key] ?? SSEParser()
        let payload = p.feed(line)
        parsers[key] = p
        lock.unlock()
        if let payload { broadcast(key, gen, .payload(payload)) }
    }

    private func broadcast(_ key: Key, _ gen: Int, _ f: LiveFrame) {
        lock.lock()
        guard let ch = channels[key], ch.generation == gen else { lock.unlock(); return }
        if f == .connected { parsers[key] = SSEParser() }
        let sinks = Array(ch.subscribers.values)
        lock.unlock()
        for s in sinks { s(f) }
    }

    static func request(baseURL: URL, token: String?) -> URLRequest {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        var r = URLRequest(url: URL(string: s + "v1/events")!)
        r.httpMethod = "GET"
        // The server sends a comment every 10 s: 40 s without a byte means the stream died quietly (sleep, network change).
        r.timeoutInterval = 40
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    #if canImport(FoundationNetworking)
    static let urlSessionTransport: Transport? = nil
    #else
    static let urlSessionTransport: Transport? = { session, request, onOpen, onLine in
        let (bytes, resp) = try await session.bytes(for: request)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ApiError("http_\(http.statusCode)", "Event stream refused") }
        onOpen()
        var line = [UInt8]()
        for try await b in bytes {
            if b == 0x0A {
                onLine(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(b)
            }
        }
    }
    #endif
}
