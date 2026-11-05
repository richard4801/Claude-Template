// Wiring (the parent adds one line at the end of AppStore.connect()):
//     BlenderRelayService.shared.configure(baseURL: (api as? HTTPMuseAPI)?.baseURL, isOwner: isOwner) { [serverKey] in Keychain.token(for: serverKey) }
// and BlenderRelayService.shared.stop() in endSession(). Demo mode (no HTTP API) or a member never runs it.
// The debug switch: BlenderRelayDebugView(service: .shared) in Settings → Developer (owner only).

import Combine
import Foundation
import MuseCore

/// The Mac end of the Blender relay (plans/api.md "MCP & camera sessions"): owner only and off by default (debug switch).
/// While on: heartbeat every 20 s, catch up on waiting calls, take `blender` live events, run calls one at a time through
/// BlenderRelay against the MCP for Blender add-on on 127.0.0.1:9876, and upload finished files that Claude Desktop / Code
/// runs drop into ~/MUSE/CameraSessions/<id>/out/.
@MainActor
final class BlenderRelayService: ObservableObject {
    static let shared = BlenderRelayService()
    static let enabledKey = "blenderRelayEnabled"

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            refresh()
        }
    }
    @Published private(set) var running = false
    @Published private(set) var blenderConnected = false
    @Published private(set) var addonVersion: String?
    @Published private(set) var lastCall: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpload: String?

    private let defaults: UserDefaults
    private var baseURL: URL?
    private var token: (@Sendable () -> String?)?
    private var isOwner = false

    private var api: HTTPBlenderRelayAPI?
    private var relay: BlenderRelay?
    private var loops: [Task<Void, Never>] = []
    private var queue: [BlenderCall] = []
    private var worker: Task<Void, Never>?
    /// A call is running: the heartbeat doesn't ping Blender meanwhile (it answers one command at a time).
    private var busy = false
    /// Folder watcher: each file's size at the last poll, and files whose upload failed (by modification time).
    private var lastSizes: [String: Int64] = [:]
    private var failedAt: [String: Double] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _enabled = Published(initialValue: defaults.bool(forKey: Self.enabledKey))
    }

    /// After sign-in / reconnect. A different server restarts the relay; a member, demo mode or no token stops it.
    func configure(baseURL: URL?, isOwner: Bool, token: @escaping @Sendable () -> String?) {
        if baseURL != self.baseURL { stop() }
        self.baseURL = baseURL
        self.isOwner = isOwner
        self.token = token
        refresh()
    }

    private func refresh() {
        let shouldRun = enabled && isOwner && baseURL != nil && token != nil
        if shouldRun, !running { start() } else if !shouldRun, running { stop() }
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        worker?.cancel()
        worker = nil
        queue = []
        busy = false
        if running, let api {
            Task { _ = try? await api.heartbeat(BlenderRelayStatus(online: false, blender: BlenderLink(connected: false))) }
        }
        api = nil
        relay = nil
        running = false
        blenderConnected = false
    }

    private func start() {
        guard let baseURL, let token else { return }
        let transport: BlenderSocket
        do { transport = try BlenderSocket() } catch {
            lastError = error.localizedDescription
            return
        }
        let api = HTTPBlenderRelayAPI(baseURL: baseURL, token: token)
        // A greybox playblast can take a few minutes; calls expire on the server after 5.
        let relay = BlenderRelay(transport: transport, api: api, root: BlenderRelay.defaultRoot, renderTimeout: 280)
        self.api = api
        self.relay = relay
        running = true
        lastError = nil
        loops = [
            Task { [weak self] in await self?.heartbeatLoop(api, relay) },
            Task { [weak self] in await self?.listen(api, relay) },
            Task { [weak self] in await self?.watchLoop(relay) },
            Task { [weak self] in
                if let calls = try? await api.pendingCalls() { self?.enqueue(calls) }
            },
        ]
    }

    // MARK: Heartbeat and calls

    private func heartbeatLoop(_ api: HTTPBlenderRelayAPI, _ relay: BlenderRelay) async {
        while !Task.isCancelled {
            var link = BlenderLink(connected: blenderConnected, addonVersion: addonVersion)
            if !busy {
                link = await relay.link()
                blenderConnected = link.connected
                addonVersion = link.addonVersion
            }
            do {
                enqueue(try await api.heartbeat(BlenderRelayStatus(online: true, blender: link)).pending)
            } catch {
                if !Task.isCancelled { lastError = "Heartbeat: \(error.localizedDescription)" }
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    private func listen(_ api: HTTPBlenderRelayAPI, _ relay: BlenderRelay) async {
        for await e in api.events() {
            if Task.isCancelled { break }
            switch e {
            case .call(let c):
                enqueue([c])
            case .cancel(let id):
                queue.removeAll { $0.id == id }
                await relay.cancel(id)
            case .relay:
                break
            }
        }
    }

    private func enqueue(_ calls: [BlenderCall]) {
        guard running else { return }
        for c in calls where !queue.contains(where: { $0.id == c.id }) { queue.append(c) }
        pump()
    }

    /// One call at a time.
    private func pump() {
        guard worker == nil, let relay, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let call = self.queue.removeFirst()
                self.busy = true
                let outcome = await relay.handle(call)
                self.busy = false
                self.record(call, outcome)
            }
            self?.worker = nil
        }
    }

    private func record(_ call: BlenderCall, _ outcome: BlenderRelay.Outcome) {
        switch outcome {
        case .posted(let r):
            lastCall = "\(call.tool) · \(r.ok ? "ok" : "failed")"
            if !r.ok { lastError = r.error }
            if r.ok, call.knownTool != .status { blenderConnected = true }
        case .unposted(_, let message):
            lastCall = "\(call.tool) · result not sent"
            lastError = message
        case .skipped(let why):
            if why != "duplicate" { lastCall = "\(call.tool) · skipped (\(why))" }
        }
    }

    // MARK: Session folders (files from Claude Desktop / Code)

    private func watchLoop(_ relay: BlenderRelay) async {
        while !Task.isCancelled {
            await scan(relay)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// New finished files in ~/MUSE/CameraSessions/*/out/ become assets of that session. Finished = the same size on two polls
    /// in a row; already uploaded = in the folder's .muse-uploaded.json with the same size and time. Files older than a day
    /// (from before the relay was on) are left alone, and a failed upload waits until the file changes.
    private func scan(_ relay: BlenderRelay) async {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(atPath: relay.sessionsDir.path) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        for sid in sessions.sorted() where BlenderArgs.isSessionId(sid) {
            guard !Task.isCancelled, let out = relay.outDir(sessionId: sid), let names = try? fm.contentsOfDirectory(atPath: out.path) else { continue }
            // The relay is writing (and uploading) this session's files right now.
            if await relay.busySessionId == sid { continue }
            for name in names.sorted() {
                guard let kind = BlenderAssetKinds.kind(forFile: name), !BlenderUploadManifest.load(out).isUploaded(name, in: out) else { continue }
                let file = out.appendingPathComponent(name)
                guard let stamp = BlenderUploadManifest.stamp(file), stamp.size > 0, stamp.mtime >= cutoff else { continue }
                let key = file.path
                if failedAt[key] == stamp.mtime { continue }
                guard lastSizes[key] == stamp.size else {
                    lastSizes[key] = stamp.size
                    continue
                }
                do {
                    let id = try await relay.upload(sessionId: sid, file: file, kind: kind, label: name)
                    var manifest = BlenderUploadManifest.load(out)
                    manifest.mark(name, in: out, assetId: id)
                    manifest.save(out)
                    lastSizes[key] = nil
                    lastUpload = "\(name) → \(sid)"
                } catch {
                    failedAt[key] = stamp.mtime
                    lastError = "Couldn't upload \(name): \(error.localizedDescription)"
                }
            }
        }
    }
}
