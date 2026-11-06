import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stand-in for the SSE connection: counts opens and lets a test push events to the open one.
final class FakeSSE: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (@Sendable (String) -> Void)?
    private var _opens = 0
    private var _refuse = false
    var opens: Int { lock.lock(); defer { lock.unlock() }; return _opens }
    var connected: Bool { lock.lock(); defer { lock.unlock() }; return current != nil }
    func refuse(_ on: Bool) { lock.lock(); _refuse = on; lock.unlock() }

    var transport: LiveEventHub.Transport {
        { [self] _, request, onOpen, onLine in
            XCTAssertEqual(request.url?.path, "/v1/events")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            if lock.withLock({ _refuse }) { throw ApiError("http_503", "refused") }
            lock.withLock { _opens += 1; current = onLine }
            onOpen()
            defer { lock.withLock { current = nil } }
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
    }

    /// One SSE event (data line + blank line); also a keep-alive comment.
    func send(_ json: String) {
        let sink = lock.withLock { current }
        sink?(": keep-alive")
        sink?("data: \(json)")
        sink?("")
    }
}

/// Collects a stream's elements in the background.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<T>) {
        task = Task { [weak self] in
            for await x in stream { self?.lock.withLock { self?.items.append(x) } }
        }
    }
    var all: [T] { lock.withLock { items } }
    func cancel() { task?.cancel() }
}

func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
}

final class PerfHubTests: XCTestCase {
    let base = URL(string: "http://hub.test")!

    /// Before the pass the app's store, the Edit suite, camera sessions, Claude Code and the Blender relay each opened
    /// GET /v1/events (5 connections). Now they share one, and each still gets its own events.
    func testFiveListenersShareOneConnection() async throws {
        let sse = FakeSSE()
        let hub = LiveEventHub(transport: sse.transport, retryDelay: { _ in 10_000_000 })
        let muse = HTTPMuseAPI(baseURL: base, hub: hub)
        await muse.setToken("tok")
        let edit = HTTPMuseAPI(baseURL: base, hub: hub)
        await edit.setToken("tok")
        let camera = HTTPCameraAPI(baseURL: base, hub: hub) { "tok" }
        let claude = HTTPClaudeAPI(baseURL: base, hub: hub) { "tok" }
        let blender = HTTPBlenderRelayAPI(baseURL: base, hub: hub) { "tok" }

        let a = Collector(muse.events()), b = Collector(edit.events()), c = Collector(camera.events())
        let d = Collector(claude.events()), e = Collector(blender.events())
        await waitUntil { hub.subscriberCount == 5 && sse.connected && a.all.count == 1 && c.all.count == 1 && d.all.count == 1 }
        XCTAssertEqual(sse.opens, 1, "one GET /v1/events for five listeners")
        XCTAssertEqual(hub.openConnections, 1)

        sse.send(#"{"type":"job","op":"delete","id":"j1"}"#)
        sse.send(#"{"type":"camera","op":"delete","id":"s1"}"#)
        sse.send(#"{"type":"claude","op":"stop","turnId":"u1"}"#)
        sse.send(#"{"type":"blender","op":"cancel","id":"c1"}"#)
        await waitUntil { a.all.count >= 5 && b.all.count >= 5 && c.all.count >= 2 && d.all.count >= 2 && e.all.count >= 1 }

        XCTAssertEqual(a.all.first?.type, ApiEvent.connected)
        XCTAssertTrue(a.all.contains { $0.type == "job" && $0.id == "j1" })
        XCTAssertTrue(b.all.contains { $0.type == "job" && $0.id == "j1" }, "the Edit suite hears the same stream")
        XCTAssertTrue(c.all.contains { if case .delete("s1") = $0 { return true }; return false })
        XCTAssertFalse(c.all.contains { if case .delete = $0 { return false }; if case .connected = $0 { return false }; return true }, "camera gets camera events only")
        XCTAssertTrue(d.all.contains { if case .stop(turnId: "u1") = $0 { return true }; return false })
        XCTAssertEqual(e.all.count, 1)
        if case .cancel("c1")? = e.all.first {} else { XCTFail("blender cancel") }
        XCTAssertTrue(hub.isHealthy(baseURL: base))
        XCTAssertFalse(hub.isHealthy(baseURL: base, now: Date().addingTimeInterval(60)), "silent for a minute: not healthy")

        // A sixth listener joining the open stream hears `connected` at once, without a new connection.
        let f = Collector(camera.events())
        await waitUntil { f.all.count == 1 }
        if case .connected? = f.all.first {} else { XCTFail("late joiner gets connected") }
        XCTAssertEqual(sse.opens, 1)

        // Restart on demand (network change / wake): one new connection, everyone hears it.
        hub.reconnect(baseURL: base)
        await waitUntil { sse.opens == 2 && a.all.filter { $0.type == ApiEvent.connected }.count == 2 }
        XCTAssertEqual(sse.opens, 2)
        XCTAssertEqual(a.all.filter { $0.type == ApiEvent.connected }.count, 2)

        // The last listener leaving closes it.
        a.cancel(); b.cancel(); c.cancel(); d.cancel(); e.cancel(); f.cancel()
        await waitUntil { hub.openConnections == 0 }
        XCTAssertEqual(hub.openConnections, 0)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testDifferentSessionsGetTheirOwnStream() async {
        let sse = FakeSSE()
        let hub = LiveEventHub(transport: sse.transport, retryDelay: { _ in 10_000_000 })
        let a = Collector(HTTPCameraAPI(baseURL: base, hub: hub) { "one" }.events())
        let b = Collector(HTTPCameraAPI(baseURL: base, hub: hub) { "two" }.events())
        await waitUntil { sse.opens == 2 }
        XCTAssertEqual(sse.opens, 2, "a different sign-in never shares a stream")
        a.cancel(); b.cancel()
        await waitUntil { hub.openConnections == 0 }
    }

    func testRefusedStreamRetriesAndReportsDisconnected() async {
        let sse = FakeSSE()
        sse.refuse(true)
        let hub = LiveEventHub(transport: sse.transport, retryDelay: { _ in 5_000_000 })
        let c = Collector(HTTPCameraAPI(baseURL: base, hub: hub) { "t" }.events())
        await waitUntil { c.all.count >= 2 }
        XCTAssertTrue(c.all.allSatisfy { if case .disconnected = $0 { return true }; return false })
        sse.refuse(false)
        await waitUntil { sse.connected }
        await waitUntil { c.all.contains { if case .connected = $0 { return true }; return false } }
        XCTAssertTrue(c.all.contains { if case .connected = $0 { return true }; return false })
        c.cancel()
        await waitUntil { hub.openConnections == 0 }
    }

    func testLinuxBuildsKeepPollingWithoutATransport() {
        #if canImport(FoundationNetworking)
        XCTAssertFalse(LiveEventHub.shared.canStream)
        #else
        XCTAssertTrue(LiveEventHub.shared.canStream)
        #endif
    }

    /// The catalog cache: a second read is free; a `settings` event, a write or a reconnect makes it fetch again.
    func testCatalogCacheInvalidatedByEventsAndWrites() async throws {
        CountingURLProtocol.reset()
        let sse = FakeSSE()
        let hub = LiveEventHub(transport: sse.transport, retryDelay: { _ in 10_000_000 })
        let api = HTTPMuseAPI(baseURL: base, session: CountingURLProtocol.session(), cacheCatalogs: true, hub: hub)
        await api.setToken("tok")
        let live = Collector(api.events())
        await waitUntil { live.all.count == 1 }
        let settings = "GET /v1/settings/studio"
        _ = try? await api.studioSettings()
        _ = try? await api.studioSettings()
        _ = try? await api.imageModels()
        _ = try? await api.imageModels()
        XCTAssertEqual(CountingURLProtocol.count(settings), 1)
        XCTAssertEqual(CountingURLProtocol.count("GET /v1/image-models"), 1)
        sse.send(#"{"type":"job","op":"delete","id":"j1"}"#) // unrelated: cache kept
        await waitUntil { live.all.count == 2 }
        _ = try? await api.studioSettings()
        XCTAssertEqual(CountingURLProtocol.count(settings), 1)
        sse.send(#"{"type":"settings"}"#)
        await waitUntil { live.all.count == 3 }
        _ = try? await api.studioSettings()
        XCTAssertEqual(CountingURLProtocol.count(settings), 2, "a settings event drops it")
        _ = try? await api.updateStudioSettings(StudioSettingsPatch())
        _ = try? await api.studioSettings()
        XCTAssertEqual(CountingURLProtocol.count(settings), 3, "a write drops it")
        hub.reconnect(baseURL: base)
        await waitUntil { live.all.filter { $0.type == ApiEvent.connected }.count == 2 }
        _ = try? await api.studioSettings()
        XCTAssertEqual(CountingURLProtocol.count(settings), 4, "a reconnect drops it")
        // Lists are never cached.
        _ = try? await api.listJobs()
        _ = try? await api.listJobs()
        XCTAssertEqual(CountingURLProtocol.count("GET /v1/jobs"), 2)
        XCTAssertGreaterThan(api.requestStats.cacheHits, 0)
        live.cancel()
    }

    func testCacheIsOffByDefault() async {
        CountingURLProtocol.reset()
        let api = HTTPMuseAPI(baseURL: base, session: CountingURLProtocol.session())
        _ = try? await api.studioSettings()
        _ = try? await api.studioSettings()
        XCTAssertEqual(CountingURLProtocol.count("GET /v1/settings/studio"), 2)
    }

    func testCoalescerSharesOneRequestAndForgetsAfter() async throws {
        let c = RequestCoalescer<Int>()
        let calls = LockedCounter()
        async let a = c.run("k") { calls.bump(); try await Task.sleep(nanoseconds: 30_000_000); return 7 }
        async let b = c.run("k") { calls.bump(); return 8 }
        async let d = c.run("other") { calls.bump(); return 9 }
        let (x, y, z) = try await (a, b, d)
        XCTAssertEqual(x, 7)
        XCTAssertEqual(z, 9)
        XCTAssertTrue(y == 7 || y == 8)
        XCTAssertLessThanOrEqual(calls.value, 3)
        XCTAssertEqual(c.inflightCount, 0)
        let again = try await c.run("k") { calls.bump(); return 1 }
        XCTAssertEqual(again, 1, "nothing is kept once the work ends")
    }

    func testCoalescerSharesErrors() async {
        let c = RequestCoalescer<Int>()
        let calls = LockedCounter()
        async let a: Int? = try? c.run("k") { calls.bump(); try await Task.sleep(nanoseconds: 30_000_000); throw ApiError("offline", "x") }
        try? await Task.sleep(nanoseconds: 5_000_000)
        async let b: Int? = try? c.run("k") { calls.bump(); return 1 }
        let (x, y) = await (a, b)
        XCTAssertNil(x)
        XCTAssertNil(y, "the joiner gets the same error")
        XCTAssertEqual(calls.value, 1)
    }

    func testTTLCacheExpiresAndRespectsVersion() {
        let now = LockedClock()
        let c = TTLCache<Int>(limit: 2, clock: { now.value })
        c.put("a", 1, ttl: 10)
        XCTAssertEqual(c.get("a"), 1)
        now.advance(11)
        XCTAssertNil(c.get("a"))
        let v = c.version
        c.invalidate(["zzz"])
        c.put("b", 2, ttl: 10, ifVersion: v)
        XCTAssertNil(c.get("b"), "fetched before an invalidation: not stored")
        c.put("b", 2, ttl: 10)
        c.put("c", 3, ttl: 20)
        c.put("d", 4, ttl: 30)
        XCTAssertEqual(c.count, 2, "bounded")
        XCTAssertNil(c.get("b"), "the soonest to expire went first")
        c.invalidate(["c"])
        XCTAssertNil(c.get("c"))
        XCTAssertEqual(c.get("d"), 4)
    }

    func testFreshness() {
        var f = Freshness()
        let t0 = Date()
        XCTAssertFalse(f.isFresh("posts", maxAge: 60, now: t0))
        f.mark("posts", now: t0)
        XCTAssertTrue(f.isFresh("posts", maxAge: 60, now: t0.addingTimeInterval(59)))
        XCTAssertFalse(f.isFresh("posts", maxAge: 60, now: t0.addingTimeInterval(61)))
        f.invalidateAll()
        XCTAssertFalse(f.isFresh("posts", maxAge: 60, now: t0))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var value: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}
