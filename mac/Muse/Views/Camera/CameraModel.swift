import AppKit
import Foundation
import MuseCore
import Observation
import SystemConfiguration

/// State for the Directed (Blender) mode, Direct with Claude and Settings → Connections (plans/mcp-bridge.md "Phase 2 · UI").
/// Owner only. It talks to the camera-session API itself (HTTPCameraAPI on the signed-in server, FakeCameraAPI in demo mode)
/// and listens to the `camera`/`blender` live events, so AppStore stays untouched: it only reads `store.api` and `store.isOwner`.
@MainActor
@Observable
final class CameraModel {
    enum Tab: String, CaseIterable { case blocking = "Blocking", guides = "Guides", history = "History" }
    enum ViewMode: String, CaseIterable { case plan = "Plan", camera = "Camera view", side = "Side", orbit = "3D" }

    /// Demo mode shares one fake so the stage and the Shot builder see the same sessions.
    static let demoAPI = FakeCameraAPI()

    @ObservationIgnored private(set) var api: (any CameraAPI)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pathTask: Task<Void, Never>?
    @ObservationIgnored private var chatTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var apiKey: String?

    var sessions: [CameraSession] = []
    var selectedId: String?
    var loading = false
    var loadError: String?
    /// The live event stream is open (● LIVE).
    var live = false
    var connections: CameraConnections?
    var tokens: [McpToken] = []
    /// The token just made: shown once.
    var newToken: McpTokenCreated?
    var tokenError: String?

    var tab: Tab = .blocking
    var viewMode: ViewMode = .plan
    var playhead: Double = 0

    // Chat
    var composer = ""
    var turn: ChatTurn?
    var chatError: String?
    var chatErrorCode: String?
    /// Messages sent from this Mac (the transcript labels them "YOU · MAC APP").
    var sentHere: [String: String] = [:]
    var applying = false
    var applyError: String?
    /// Re-read every 30 s so "2 min ago" and the Claude app's 5-minute window move.
    var now = Date().timeIntervalSince1970 * 1000

    /// This Mac's name for "Mac Studio · localhost". The computer name from System Configuration: a local read. (It was
    /// `Host.current().localizedName`, which resolves the Mac's network names synchronously and could stall the main
    /// thread for seconds the first time the Camera stage drew its status rows.)
    var machine: String? { Self.machineName }
    private static let machineName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    init() {}

    // MARK: Wiring

    /// Called from the views' `.task`: the signed-in server's API, or the demo fake. A different server restarts everything.
    func attach(_ store: AppStore) {
        let key: String
        let api: any CameraAPI
        if let http = store.api as? HTTPMuseAPI {
            key = http.baseURL.absoluteString
            api = HTTPCameraAPI(baseURL: http.baseURL) { [http] in http.sessionToken }
        } else {
            key = "demo"
            api = Self.demoAPI
        }
        guard key != apiKey else { return }
        stop()
        apiKey = key
        self.api = api
        start()
    }

    func stop() {
        apiKey = nil
        eventsTask?.cancel()
        eventsTask = nil
        clockTask?.cancel()
        clockTask = nil
        chatTask?.cancel()
        chatTask = nil
        live = false
    }

    private func start() {
        guard let api else { return }
        eventsTask = Task { [weak self] in
            for await e in api.events() {
                guard let self, !Task.isCancelled else { break }
                self.handle(e)
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.now = Date().timeIntervalSince1970 * 1000
            }
        }
        Task { await reload() }
    }

    private func handle(_ e: CameraLiveEvent) {
        switch e {
        case .connected:
            live = true
            Task { await reload(quiet: true) }
        case .disconnected:
            live = false
        case .relay(let r):
            CameraSessions.apply(&sessions, e)
            connections?.relay = r
        default:
            CameraSessions.apply(&sessions, e)
        }
    }

    // MARK: Loading

    var selected: CameraSession? { sessions.first { $0.id == selectedId } }

    func reload(quiet: Bool = false) async {
        guard let api else { return }
        if !quiet { loading = true }
        defer { loading = false }
        do {
            let list = try await api.listSessions()
            var merged = list
            for i in merged.indices { merged[i].messages = sessions.first { $0.id == merged[i].id }?.messages }
            sessions = merged
            loadError = nil
            if selectedId == nil || !sessions.contains(where: { $0.id == selectedId }) { selectedId = sessions.first?.id }
            if let id = selectedId { await loadDetail(id) }
        } catch {
            if !quiet { loadError = message(error) }
        }
        if let c = try? await api.connections() { connections = c }
    }

    func loadDetail(_ id: String) async {
        guard let api, let s = try? await api.session(id) else { return }
        upsert(s)
    }

    func select(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        playhead = 0
        turn = nil
        chatError = nil
        Task { await loadDetail(id) }
    }

    private func upsert(_ s: CameraSession) {
        var s = s
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            if s.messages == nil { s.messages = sessions[i].messages }
            sessions[i] = s
        } else {
            sessions.insert(s, at: 0)
        }
    }

    func create(title: String, durationSec: Double, aspect: String, cast: [String]) async -> CameraSession? {
        guard let api else { return nil }
        do {
            let s = try await api.createSession(CameraSessionCreate(title: title.isEmpty ? nil : title, aspect: aspect, durationSec: durationSec,
                                                                    characters: cast.map { .init(modelId: $0) }))
            upsert(s)
            selectedId = s.id
            playhead = 0
            return s
        } catch {
            loadError = message(error)
            return nil
        }
    }

    func delete(_ id: String) async {
        guard let api else { return }
        do {
            try await api.deleteSession(id)
            sessions.removeAll { $0.id == id }
            if selectedId == id { selectedId = sessions.first?.id }
        } catch { loadError = message(error) }
    }

    // MARK: Plan editing

    /// A drag on the plan: shown at once, saved 400 ms after the last move (PUT …/path).
    func drag(_ handle: PlanHandle, to plan: CGPoint) {
        guard let s = selected, let u = CameraDrag.update(s, handle: handle, at: playhead, to: plan) else { return }
        upsert(CameraDrag.applying(u, to: s))
        pathTask?.cancel()
        let id = s.id
        pathTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, let api = self.api, let cur = self.selected, cur.id == id else { return }
            // Send the latest local state of what was dragged.
            let body = handle == .camera ? CameraPathUpdate(camera: cur.cameraPath) : CameraPathUpdate(characters: cur.blocking?.characters)
            do { self.upsert(try await api.setPath(id, body)) } catch {
                self.applyError = self.message(error)
                await self.loadDetail(id)
            }
        }
    }

    // MARK: Chat

    var busy: Bool { turn.map { !$0.finished } ?? false }

    func send(_ text: String? = nil) {
        let msg = (text ?? composer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, let api, let s = selected else { return }
        if busy || s.claude?.chatBusy == true {
            chatError = CameraText.chatBusy
            chatErrorCode = "chat_busy"
            return
        }
        if text == nil { composer = "" }
        chatError = nil
        chatErrorCode = nil
        turn = ChatTurn(startRevision: s.revision)
        let id = s.id
        chatTask = Task { [weak self] in
            do {
                for try await e in api.chat(id, message: msg) {
                    guard let self else { return }
                    self.turn?.apply(e)
                    if case .message(let m) = e {
                        if m.role == "user" { self.sentHere[m.id] = "Mac app" }
                        CameraSessions.apply(&self.sessions, .message(sessionId: id, m))
                    }
                    if case .error = e {
                        self.chatError = self.turn?.error
                        self.chatErrorCode = self.turn?.errorCode
                    }
                }
            } catch {
                guard let self else { return }
                let code = (error as? ApiError)?.code ?? "error"
                self.chatErrorCode = code
                self.chatError = CameraText.chatError(code: code, message: self.message(error))
                if code == "director_unavailable" { self.connections?.inAppChat = false }
                if text == nil, self.composer.isEmpty { self.composer = msg }
            }
            guard let self else { return }
            self.turn = nil
            await self.loadDetail(id)
        }
    }

    func rerender() { send(CameraText.rerenderMessage) }

    // MARK: Apply to the shot

    /// The JSON CameraSpec for the Shot builder: the draft's `request.camera`; makes a draft first when there is none,
    /// or when the newest greybox came after it.
    func handoff(prompt: String?) async -> String? {
        guard let api, let s = selected else { return nil }
        applying = true
        applyError = nil
        defer { applying = false }
        var draft = s.shotDraft
        let stale = draft.map { d in
            let newest = s.assets.filter { $0.kind == "greybox" && $0.state == "ready" }.compactMap(\.createdAt).max() ?? 0
            return newest > (d.createdAt ?? 0) || (!CameraSessions.handoffHasGuide(d) && CameraGuides.greyboxReady(s))
        } ?? true
        if stale || draft?.jobId != nil {
            do { draft = try await api.createShotDraft(s.id, CameraShotDraftRequest(prompt: prompt)) } catch {
                applyError = message(error)
                return nil
            }
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i].shotDraft = draft }
        }
        guard let json = CameraSessions.handoff(draft) else {
            applyError = "The draft has no camera yet · try again in a moment"
            return nil
        }
        return json
    }

    // MARK: Connections

    func loadConnections() async {
        guard let api else { return }
        async let c = try? api.connections()
        async let t = try? api.tokens()
        if let c = await c { connections = c }
        if let t = await t { tokens = t }
    }

    func createToken(name: String) async {
        guard let api else { return }
        tokenError = nil
        do {
            let t = try await api.createToken(name: name, expiresDays: nil)
            newToken = t
            tokens.insert(t.listed, at: 0)
        } catch { tokenError = message(error) }
    }

    func revoke(_ id: String) async {
        guard let api else { return }
        do {
            try await api.revokeToken(id)
            tokens.removeAll { $0.id == id }
            if newToken?.id == id { newToken = nil }
        } catch { tokenError = message(error) }
    }

    // MARK: Helpers

    func message(_ error: Error) -> String { (error as? ApiError)?.message ?? error.localizedDescription }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
