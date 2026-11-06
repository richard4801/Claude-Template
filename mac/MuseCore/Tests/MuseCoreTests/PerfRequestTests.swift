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
/// `legacy` replays the app as it was before the performance pass.
final class AppLoadScript: @unchecked Sendable {
    let api: HTTPMuseAPI
    let legacy: Bool
    let modelIds = ["m1", "m2"]

    init(api: HTTPMuseAPI, legacy: Bool) {
        self.api = api
        self.legacy = legacy
    }

    func launch() async {
        _ = try? await api.me()
        await reload()
    }

    func reload() async {
        async let m = try? api.listModels()
        async let o = try? api.listOutfits()
        async let j = try? api.listJobs()
        async let t = try? api.listTakes()
        async let b = try? api.balance()
        _ = await (m, o, j, t, b)
        await loadStudio()
        await loadSocial()
        _ = try? await api.listTemplates(TemplateQuery())
        _ = try? await api.warmGpu()
    }

    func loadStudio() async {
        _ = try? await api.wallet()
        _ = try? await api.studioSettings()
        _ = try? await api.listMembers()
        _ = try? await api.studioBalance()
        _ = try? await api.imageEngine()
        _ = try? await api.imageModels()
        _ = try? await api.listArchivedModels()
    }

    func loadSocial() async {
        for id in modelIds {
            _ = try? await api.lora(modelId: id)
            _ = try? await api.listAccounts(modelId: id)
        }
        _ = try? await api.listPosts(state: nil)
    }

    /// Settings → Credit, Templates, Posts and Members, each opened once after launch.
    func openListScreens() async {
        await loadStudio() // Credit's .task
        _ = try? await api.listTemplates(TemplateQuery()) // Templates' .task
        _ = try? await api.listPosts(state: nil) // Posts' .task
        _ = try? await api.listMembers() // Members' .onAppear
        _ = try? await api.wallet()
    }

    /// The app comes back to the front (⌘-Tab) while the live stream is healthy.
    func reactivate() async { await reload() }
}

final class PerfRequestTests: XCTestCase {
    private func api() -> HTTPMuseAPI {
        CountingURLProtocol.reset()
        return HTTPMuseAPI(baseURL: URL(string: "http://perf.test")!, session: CountingURLProtocol.session())
    }

    func testRequestCountsLegacy() async {
        let s = AppLoadScript(api: api(), legacy: true)
        await s.launch()
        let launch = CountingURLProtocol.total
        await s.openListScreens()
        let screens = CountingURLProtocol.total - launch
        await s.reactivate(); await s.reactivate(); await s.reactivate()
        let react = CountingURLProtocol.total - launch - screens
        // Credit opened while the launch's studio load is still running, and a `settings` event without a payload.
        CountingURLProtocol.reset()
        async let a: Void = s.loadStudio()
        async let b: Void = s.loadStudio()
        async let c: Void = s.loadStudio()
        _ = await (a, b, c)
        let concurrent = CountingURLProtocol.total
        print("PERF legacy launch=\(launch) screens=\(screens) reactivate3=\(react) concurrentStudio3=\(concurrent)")
    }
}
