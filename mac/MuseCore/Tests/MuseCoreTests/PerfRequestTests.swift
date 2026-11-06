import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Counts every request a URLSession makes and answers each one after a short delay (so concurrent calls overlap), with an
/// empty JSON body. Decoding may fail: these tests count requests, they don't read the replies.
final class CountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var delay: TimeInterval = 0.03

    static func reset() { lock.lock(); counts = [:]; lock.unlock() }
    static var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    static var snapshot: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var key = "\(request.httpMethod ?? "GET") \(url.path)"
        if let q = url.query { key += "?\(q)" }
        Self.lock.lock(); Self.counts[key, default: 0] += 1; Self.lock.unlock()
        let body = url.path.hasSuffix("s") ? "[]" : "{}"
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [CountingURLProtocol.self]
        return URLSession(configuration: c)
    }
}

/// The app's loading, call for call (mac/Muse/App/AppStore.swift `restoreSession` → `reload` → `loadStudio`, `loadSocial`,
/// `loadTemplates`, `loadWarmGpu`; the views' `.task` / `.onAppear` refetches), for an owner with two models.
/// `legacy` replays the app as it was before the performance pass (one call after another, every screen refetching,
/// every ⌘-Tab reloading everything, no request sharing); otherwise it replays the app as it is now (same code shapes:
/// `async let` fan-out with `attempt`, a task group per model, `Freshness` guards, the stream-health check).
@MainActor
final class AppLoadScript {
    let api: HTTPMuseAPI
    let legacy: Bool
    let modelIds = ["m1", "m2"]
    var listFreshness = Freshness()
    /// Stands in for `HTTPMuseAPI.liveStreamHealthy` (the shared stream heard a keep-alive in the last 25 s).
    var streamHealthy = true
    private var reloadTask: Task<Void, Never>?

    init(api: HTTPMuseAPI, legacy: Bool) {
        self.api = api
        self.legacy = legacy
    }

    func launch() async {
        _ = try? await api.me()
        await reload()
    }

    func reload() async {
        if legacy { return await reloadNow() }
        if let running = reloadTask { await running.value; return }
        let t = Task { [weak self] in
            await self?.reloadNow()
            self?.reloadTask = nil
        }
        reloadTask = t
        await t.value
    }

    private func reloadNow() async {
        let api = self.api
        async let m = try? api.listModels()
        async let o = try? api.listOutfits()
        async let j = try? api.listJobs()
        async let t = try? api.listTakes()
        async let b = try? api.balance()
        _ = await (m, o, j, t, b)
        if legacy {
            await loadStudio()
            await loadSocial()
            _ = try? await api.listTemplates(TemplateQuery())
            _ = try? await api.warmGpu()
            return
        }
        async let studio: Void = loadStudio()
        async let social: Void = loadSocial()
        async let tpl: Void = loadTemplates()
        async let warm: Void = loadWarm()
        _ = await (studio, social, tpl, warm)
        for k in ["studio", "templates", "posts", "members", "archived"] { listFreshness.mark(k) }
    }

    func loadTemplates() async { _ = try? await api.listTemplates(TemplateQuery()) }
    func loadWarm() async { _ = try? await api.warmGpu() }

    func loadStudio() async {
        let api = self.api
        if legacy {
            _ = try? await api.wallet()
            _ = try? await api.studioSettings()
            _ = try? await api.listMembers()
            _ = try? await api.studioBalance()
            _ = try? await api.imageEngine()
            _ = try? await api.imageModels()
            _ = try? await api.listArchivedModels()
            return
        }
        let owner = true
        async let w = attempt { try await api.wallet() }
        async let st = attempt { try await api.studioSettings() }
        async let mem = attempt(owner) { try await api.listMembers() }
        async let sb = attempt(owner) { try await api.studioBalance() }
        async let ie = attempt(owner) { try await api.imageEngine() }
        async let sm = attempt(owner) { try await api.imageModels() }
        async let ar = attempt(owner) { try await api.listArchivedModels() }
        _ = await w
        _ = await st
        _ = await (mem, sb, ie, sm, ar)
        listFreshness.mark("studio")
    }

    func loadSocial() async {
        let api = self.api
        if legacy {
            for id in modelIds {
                _ = try? await api.lora(modelId: id)
                _ = try? await api.listAccounts(modelId: id)
            }
            _ = try? await api.listPosts(state: nil)
            return
        }
        let ids = modelIds
        async let postsReply = attempt { try await api.listPosts(state: nil) }
        let perModel = await withTaskGroup(of: (String, Lora?, [Account]?).self) { group in
            for id in ids {
                group.addTask {
                    async let l = attempt { try await api.lora(modelId: id) }
                    async let a = attempt { try await api.listAccounts(modelId: id) }
                    return (id, await l, await a)
                }
            }
            var out: [(String, Lora?, [Account]?)] = []
            for await r in group { out.append(r) }
            return out
        }
        _ = perModel
        _ = await postsReply
        listFreshness.mark("posts")
    }

    private func fresh(_ k: String) -> Bool { !legacy && listFreshness.isFresh(k, maxAge: 60) }

    /// Settings → Credit, Templates, Posts and Members, each opened once after launch.
    func openListScreens() async {
        if !fresh("studio") { await loadStudio() } // Credit's .task
        if !fresh("templates") { await loadTemplates() } // Templates' .task
        if !fresh("posts") { _ = try? await api.listPosts(state: nil) } // Posts' .task
        if !fresh("members") { // Members' .onAppear
            _ = try? await api.listMembers()
            _ = try? await api.wallet()
        }
    }

    /// The app comes back to the front (⌘-Tab) while the live stream is healthy.
    func reactivate() async {
        if !legacy && streamHealthy { return }
        await reload()
    }
}

/// Runs one API call for `async let` fan-out; nil when `on` is false or the call fails (the app's helper of the same name).
func attempt<T: Sendable>(_ on: Bool = true, _ call: @Sendable () async throws -> T) async -> T? {
    guard on else { return nil }
    return try? await call()
}

struct LoadNumbers: CustomStringConvertible {
    var launch = 0, launchMs = 0, screens = 0, reactivate3 = 0, concurrentStudio3 = 0, settingsTwice = 0
    var description: String {
        "launch=\(launch) req / \(launchMs) ms, list screens=\(screens), 3× re-activate=\(reactivate3), 3 concurrent studio loads=\(concurrentStudio3), studio load twice=\(settingsTwice)"
    }
}

final class PerfRequestTests: XCTestCase {
    @MainActor
    private func measure(legacy: Bool) async -> LoadNumbers {
        CountingURLProtocol.reset()
        let api = HTTPMuseAPI(baseURL: URL(string: "http://perf.test")!, session: CountingURLProtocol.session(),
                              cacheCatalogs: !legacy, coalesceGets: !legacy)
        let s = AppLoadScript(api: api, legacy: legacy)
        var n = LoadNumbers()
        let t0 = Date()
        await s.launch()
        n.launchMs = Int(Date().timeIntervalSince(t0) * 1000)
        n.launch = CountingURLProtocol.total
        await s.openListScreens()
        n.screens = CountingURLProtocol.total - n.launch
        let before = CountingURLProtocol.total
        await s.reactivate(); await s.reactivate(); await s.reactivate()
        n.reactivate3 = CountingURLProtocol.total - before
        // Credit opened while the launch's studio load still runs, plus a `settings` event without a payload: three loads at once.
        api.invalidateCache()
        CountingURLProtocol.reset()
        async let a: Void = s.loadStudio()
        async let b: Void = s.loadStudio()
        async let c: Void = s.loadStudio()
        _ = await (a, b, c)
        n.concurrentStudio3 = CountingURLProtocol.total
        // The studio data loaded twice a minute apart (e.g. a tool run finishing): the catalogs come from the cache.
        api.invalidateCache()
        CountingURLProtocol.reset()
        await s.loadStudio()
        await s.loadStudio()
        n.settingsTwice = CountingURLProtocol.total
        return n
    }

    func testRequestCountsBeforeAndAfter() async {
        CountingURLProtocol.delay = 0.03 // one 30 ms round trip per request
        let before = await measure(legacy: true)
        let after = await measure(legacy: false)
        print("PERF before: \(before)")
        print("PERF after:  \(after)")
        XCTAssertEqual(before.launch, 20)
        XCTAssertEqual(after.launch, 20, "a cold launch needs every list once")
        XCTAssertLessThan(after.launchMs * 2, before.launchMs, "the launch's requests go side by side")
        XCTAssertEqual(before.screens, 11)
        XCTAssertEqual(after.screens, 0, "lists the live stream keeps current aren't refetched by a screen appearing")
        XCTAssertEqual(before.reactivate3, 57)
        XCTAssertEqual(after.reactivate3, 0, "⌘-Tab with a healthy stream sends nothing")
        XCTAssertEqual(before.concurrentStudio3, 21)
        XCTAssertEqual(after.concurrentStudio3, 7, "identical GETs in flight share one request")
        XCTAssertEqual(before.settingsTwice, 14)
        XCTAssertEqual(after.settingsTwice, 11, "studio settings, image engine and image models come from the cache the second time")
    }

    func testImageLoaderOneDownloadPerURL() async throws {
        CountingURLProtocol.reset()
        let loader = ImageDataLoader(session: CountingURLProtocol.session())
        let u = URL(string: "http://perf.test/files/take1.jpg")!
        async let a = loader.data(for: u)
        async let b = loader.data(for: u)
        async let c = loader.data(for: u)
        async let d = loader.data(for: URL(string: "http://perf.test/files/take2.jpg")!)
        _ = try await (a, b, c, d)
        XCTAssertEqual(CountingURLProtocol.count("GET /files/take1.jpg"), 1, "three tiles, one download")
        XCTAssertEqual(CountingURLProtocol.count("GET /files/take2.jpg"), 1)
        XCTAssertEqual(loader.downloads, 2)
        XCTAssertEqual(loader.joined, 2)
    }

    func testPixelBuckets() {
        XCTAssertEqual(ImageDataLoader.pixelBucket(width: 0, height: 0, scale: 2), 0)
        XCTAssertEqual(ImageDataLoader.pixelBucket(width: 190, height: 338, scale: 2), 768, "a gallery tile on a Retina screen")
        XCTAssertEqual(ImageDataLoader.pixelBucket(width: 56, height: 75, scale: 2), 256, "an avatar")
        XCTAssertEqual(ImageDataLoader.pixelBucket(width: 2000, height: 3000, scale: 2), 3072, "capped")
        XCTAssertEqual(ImageDataLoader.pixelBucket(width: 100, height: 100, scale: 1), 128)
    }
}
