import Foundation

// Performance pass (plans/perf-audit.md "Mac"): one request for identical concurrent GETs, short-lived caches for
// slow-changing catalogs, and "loaded recently" bookkeeping so a screen appearing doesn't refetch a live-kept list.

/// Runs one piece of work per key at a time: callers asking for a key that's already in flight await the same result
/// (or the same error) instead of starting their own. Nothing is kept once the work finishes.
public final class RequestCoalescer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var inflight: [String: Task<Value, Error>] = [:]
    /// How many callers were answered by a request already in flight (for tests and the debug readout).
    private var _joined = 0
    public var joined: Int { lock.lock(); defer { lock.unlock() }; return _joined }

    public init() {}

    public func run(_ key: String, _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let (task, isNew) = claim(key, work)
        guard isNew else { return try await task.value }
        do {
            let v = try await task.value
            release(key, task)
            return v
        } catch {
            release(key, task)
            throw error
        }
    }

    private func claim(_ key: String, _ work: @escaping @Sendable () async throws -> Value) -> (Task<Value, Error>, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let t = inflight[key] {
            _joined += 1
            return (t, false)
        }
        let t = Task { try await work() }
        inflight[key] = t
        return (t, true)
    }

    private func release(_ key: String, _ task: Task<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if inflight[key] == task { inflight[key] = nil }
    }

    public var inflightCount: Int { lock.lock(); defer { lock.unlock() }; return inflight.count }
}

/// A small time-limited cache (successful replies only). Thread-safe; `clock` is injectable for tests.
public final class TTLCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry { var value: Value; var expires: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: @Sendable () -> Date
    /// At most this many entries; the soonest to expire goes first.
    private let limit: Int

    public init(limit: Int = 64, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.clock = clock
    }

    public func get(_ key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[key] else { return nil }
        if e.expires <= clock() {
            entries[key] = nil
            return nil
        }
        return e.value
    }

    /// Bumped by every `invalidate`: a reply fetched before an invalidation is not stored (`put(…, ifVersion:)`).
    public var version: Int { lock.lock(); defer { lock.unlock() }; return _version }
    private var _version = 0

    public func put(_ key: String, _ value: Value, ttl: TimeInterval, ifVersion: Int? = nil) {
        guard ttl > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let v = ifVersion, v != _version { return }
        if entries.count >= limit, entries[key] == nil, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries[oldest] = nil }
        entries[key] = Entry(value: value, expires: clock().addingTimeInterval(ttl))
    }

    /// Drops every entry whose key contains one of `fragments` (all of them when `fragments` is nil).
    public func invalidate(_ fragments: [String]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        _version += 1
        guard let fragments else { entries = [:]; return }
        for k in entries.keys where fragments.contains(where: { k.contains($0) }) { entries[k] = nil }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

/// "Loaded at" per list, so a screen's `.task` only refetches a list that the live stream keeps current when it's older
/// than `maxAge` (or was invalidated: sign-out, server switch, a stream reconnect).
public struct Freshness: Sendable {
    private var loadedAt: [String: Date] = [:]

    public init() {}

    public func isFresh(_ key: String, maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let t = loadedAt[key] else { return false }
        return now.timeIntervalSince(t) < maxAge
    }

    public mutating func mark(_ key: String, now: Date = Date()) { loadedAt[key] = now }
    public mutating func invalidate(_ key: String) { loadedAt[key] = nil }
    public mutating func invalidateAll() { loadedAt = [:] }
}

/// Which cached GETs a live event makes stale (HTTPMuseAPI's catalog cache).
public enum CatalogCachePolicy {
    /// Paths (prefixes, query excluded) whose replies may be cached, and for how long. Everything else always goes to the server.
    public static func ttl(for path: String) -> TimeInterval? {
        let p = path.split(separator: "?").first.map(String.init) ?? path
        switch p {
        case "v1/settings/studio", "v1/settings/image-engine", "v1/image-models", "v1/image-models/collections", "v1/suite/catalog", "v1/suite/camera":
            return 300
        default:
            return nil
        }
    }

    /// The cached paths an event of `type` can change (nil: all of them).
    public static func stale(forEvent type: String) -> [String]? {
        switch type {
        case ApiEvent.connected: return nil // a (re)connect: whatever changed while the stream was down is unknown
        case "settings", "notice", "studio": return ["v1/settings/", "v1/image-models"]
        case "suite": return ["v1/suite/"]
        default: return []
        }
    }
}
