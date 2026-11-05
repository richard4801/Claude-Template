import Foundation

/// An in-process CameraAPI for demo mode, previews and tests: one seeded session with the demo studio's two characters,
/// blocking, guides and a draft; the chat answers with a short scripted turn and changes the session like the real one.
public final class FakeCameraAPI: CameraAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [CameraSession] = []
    private var tokenList: [McpToken] = []
    private var listeners: [UUID: AsyncStream<CameraLiveEvent>.Continuation] = [:]
    private var busy: Set<String> = []
    private var counter = 0
    /// Seconds between chat events (0 in tests).
    public var stepDelay: Double
    public var inAppChat: Bool
    public var relay: CameraRelayPresence
    public var now: () -> Double

    public static let seedId = "cs_7q2mxkd4f9a2"

    public init(stepDelay: Double = 0.35, inAppChat: Bool = true, relay: CameraRelayPresence = CameraRelayPresence(online: true, blender: true, addonVersion: "1.8"),
                seed: Bool = true, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.stepDelay = stepDelay
        self.inAppChat = inAppChat
        self.relay = relay
        self.now = now
        if seed { sessions = [Self.seedSession(now: now(), relay: relay)] }
    }

    /// "Café walk-and-talk": the demo model walks to the counter and turns to camera; the second waits by the window; push in, then orbit.
    public static func seedSession(now: Double, relay: CameraRelayPresence? = nil) -> CameraSession {
        let a = SampleData.demo, b = SampleData.demoB
        let path = CameraPath(keyframes: [
            CamKey(t: 0, position: Vec3(0.2, -3.2, 1.5), target: Vec3(0.4, 0.6, 1.4), focalMm: 35, ease: "in_out"),
            CamKey(t: 4.5, position: Vec3(0.2, -2.8, 1.5), target: Vec3(0.4, 0.6, 1.4), focalMm: 35),
            CamKey(t: 6, position: Vec3(3.6, 0.4, 1.5), target: Vec3(0.4, 0.6, 1.4), focalMm: 35),
        ], cuts: [])
        let blocking = CameraBlocking(characters: [
            CameraBlockingTrack(modelId: a, keyframes: [
                CharKey(t: 0, position: Vec3(-2.6, 0.2), facingDeg: -90, action: "walk → counter · 1.1 m/s"),
                CharKey(t: 1.2, position: Vec3(-1.4, 0.1), facingDeg: -90),
                CharKey(t: 3.5, position: Vec3(1.4, 0.2), facingDeg: 0, action: "turn · smile to camera"),
            ]),
            CameraBlockingTrack(modelId: b, keyframes: [
                CharKey(t: 3, position: Vec3(0.2, 1.6), facingDeg: 180, action: "looks at \(SampleData.demoName)"),
            ], note: "waits by window"),
        ])
        let t0 = now - 8 * 60_000
        let assets = [
            CameraAsset(id: "ca_grey1", kind: "greybox", label: "greybox.mp4", state: "ready", contentType: "video/mp4", bytes: 4_200_000, source: "relay", createdAt: t0 + 60_000),
            CameraAsset(id: "ca_depth1", kind: "depth", label: "depth.mp4", state: "ready", contentType: "video/mp4", bytes: 3_100_000, source: "relay", createdAt: t0 + 61_000),
            CameraAsset(id: "ca_ks1", kind: "keyframe_start", label: "keyframe_start.png", state: "ready", contentType: "image/png", bytes: 820_000, source: "relay", createdAt: t0 + 62_000),
            CameraAsset(id: "ca_km1", kind: "keyframe_mid", label: "keyframe_mid.png", state: "ready", contentType: "image/png", bytes: 790_000, source: "relay", createdAt: t0 + 62_500),
            CameraAsset(id: "ca_ke1", kind: "keyframe_end", label: "keyframe_end.png", state: "ready", contentType: "image/png", bytes: 805_000, source: "relay", createdAt: t0 + 63_000),
            CameraAsset(id: "ca_cj1", kind: "camera_json", label: "camera.json", state: "ready", contentType: "application/json", bytes: 18_000, source: "relay", createdAt: t0 + 63_500),
        ]
        let messages = [
            CameraMessage(id: "cm_1", role: "user", source: "chat", text: "Block a 6 s walk-and-talk: \(SampleData.demoName) enters left, turns to camera at the counter at 3.5 s. \(SampleData.demoBName) waits by the window. Push in, then orbit 90°.", createdAt: t0),
            CameraMessage(id: "cm_2", role: "tool", source: "chat", text: "", tool: CameraToolStep(name: "blender_setup_scene", ok: true, summary: "café 6 × 4 m"), createdAt: t0 + 10_000),
            CameraMessage(id: "cm_3", role: "tool", source: "chat", text: "", tool: CameraToolStep(name: "blender_place_character", ok: true), createdAt: t0 + 20_000),
            CameraMessage(id: "cm_4", role: "tool", source: "chat", text: "", tool: CameraToolStep(name: "blender_place_character", ok: true), createdAt: t0 + 21_000),
            CameraMessage(id: "cm_5", role: "tool", source: "chat", text: "", tool: CameraToolStep(name: "blender_render_guides", ok: true), createdAt: t0 + 59_000),
            CameraMessage(id: "cm_6", role: "assistant", source: "chat", text: "Built the café (6 × 4 m) and placed \(SampleData.demoName) (1.72 m) and \(SampleData.demoBName) (1.68 m) from their sheets. 35 mm, eye level; push 0.4 m, then orbit 90°.", createdAt: t0 + 64_000),
        ]
        let draft = CameraShotDraft(id: "sd_seed1", state: "draft", source: "camera", prompt: "Café walk-and-talk", targetModel: "kling-v4.0", durationSec: 6, aspect: "9:16",
                                    estimate: CameraEstimate(usd: 1.92, tokens: 192), request: handoffRequest(sessionId: seedId), createdAt: t0 + 65_000)
        return CameraSession(id: seedId, title: "Café walk-and-talk", brief: "6 s walk-and-talk in a café", status: "ready", aspect: "9:16", fps: 24, durationSec: 6,
                             targetModel: "kling-v4.0", characters: [CameraCast(modelId: a, name: SampleData.demoName, heightM: 1.72), CameraCast(modelId: b, name: SampleData.demoBName, heightM: 1.68)],
                             cameraPath: path, blocking: blocking, assets: assets, shotDraft: draft, revision: 4, relay: relay,
                             claude: CameraClaudePresence(chatBusy: false), createdAt: t0, updatedAt: t0 + 65_000, messages: messages)
    }

    static func handoffRequest(sessionId: String, quality: String = "hd") -> JSONValue {
        .object([
            "quality": .string(quality), "prompt": .string("Café walk-and-talk"), "duration": .number(6), "aspectRatio": .string("9:16"),
            "camera": .object([
                "mode": .string("directed"),
                "guide": .object([
                    "video": .object(["key": .string("cam/\(sessionId)/ca_grey1.mp4"), "seconds": .number(6)]),
                    "use": .string("blocking"), "cameraSessionId": .string(sessionId),
                    "keyframes": .object(["start": .string("/uploads/cam/\(sessionId)/ca_ks1.png"), "middle": .array([.string("/uploads/cam/\(sessionId)/ca_km1.png")]),
                                          "end": .string("/uploads/cam/\(sessionId)/ca_ke1.png")]),
                ]),
            ]),
        ])
    }

    // MARK: Helpers

    private func locked<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try f()
    }

    private func nextId(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_fake\(counter)"
    }

    private func index(_ id: String) throws -> Int {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Camera session not found") }
        return i
    }

    private func emit(_ e: CameraLiveEvent) {
        let ls = locked { Array(listeners.values) }
        for l in ls { l.yield(e) }
    }

    /// Saves a change: revision +1, updatedAt now, an upsert event without messages.
    private func touch(_ i: Int) -> CameraSession {
        sessions[i].revision += 1
        sessions[i].updatedAt = now()
        sessions[i].claude = CameraClaudePresence(chatBusy: busy.contains(sessions[i].id), appLastSeenAt: sessions[i].claude?.appLastSeenAt)
        return sessions[i]
    }

    private func upsert(_ s: CameraSession) {
        var lite = s
        lite.messages = nil
        emit(.upsert(lite))
    }

    // MARK: CameraAPI

    public func listSessions() async throws -> [CameraSession] {
        locked { sessions.sorted { $0.updatedAt > $1.updatedAt }.map { var s = $0; s.messages = nil; return s } }
    }

    public func session(_ id: String) async throws -> CameraSession {
        try locked {
            var s = sessions[try index(id)]
            s.messages = Array((s.messages ?? []).suffix(50))
            return s
        }
    }

    public func createSession(_ req: CameraSessionCreate) async throws -> CameraSession {
        let s: CameraSession = locked {
            let names = [SampleData.demo: SampleData.demoName, SampleData.demoB: SampleData.demoBName]
            let cast = (req.characters ?? []).map { CameraCast(modelId: $0.modelId, name: names[$0.modelId] ?? "Unknown model", role: $0.role, heightM: $0.heightM ?? 1.68) }
            let t = now()
            let s = CameraSession(id: "cs_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12), title: req.title ?? "New camera session", brief: req.brief ?? "",
                                  status: "drafting", aspect: req.aspect ?? "9:16", fps: req.fps ?? 24, durationSec: req.durationSec ?? 6, characters: cast, revision: 1, relay: relay,
                                  claude: CameraClaudePresence(chatBusy: false), createdAt: t, updatedAt: t, messages: [])
            sessions.insert(s, at: 0)
            return s
        }
        upsert(s)
        return s
    }

    public func patchSession(_ id: String, _ patch: CameraSessionPatch) async throws -> CameraSession {
        let s: CameraSession = try locked {
            let i = try index(id)
            if let r = patch.revision, r != sessions[i].revision { throw ApiError("stale_revision", "The session changed · reload it") }
            if let v = patch.title { sessions[i].title = v }
            if let v = patch.brief { sessions[i].brief = v }
            if let v = patch.aspect { sessions[i].aspect = v }
            if let v = patch.fps { sessions[i].fps = v }
            if let v = patch.durationSec { sessions[i].durationSec = v }
            return touch(i)
        }
        upsert(s)
        return s
    }

    public func deleteSession(_ id: String) async throws {
        _ = try locked { sessions.remove(at: try index(id)) }
        emit(.delete(id))
    }

    @discardableResult
    private func addMessage(_ id: String, role: String, source: String, text: String, tool: CameraToolStep? = nil) throws -> CameraMessage {
        let m: CameraMessage = try locked {
            let i = try index(id)
            let m = CameraMessage(id: nextId("cm"), role: role, source: source, text: text, tool: tool, createdAt: now())
            sessions[i].messages = (sessions[i].messages ?? []) + [m]
            return m
        }
        emit(.message(sessionId: id, m))
        return m
    }

    public func postNote(_ id: String, text: String) async throws -> CameraMessage {
        try addMessage(id, role: "user", source: "app", text: text)
    }

    public func setPath(_ id: String, _ update: CameraPathUpdate) async throws -> CameraSession {
        let s: CameraSession = try locked {
            let i = try index(id)
            for c in update.characters ?? [] where !sessions[i].characters.contains(where: { $0.modelId == c.modelId }) {
                throw ApiError("bad_request", "characters: \(c.modelId) is not in the cast")
            }
            sessions[i] = CameraDrag.applying(update, to: sessions[i])
            if sessions[i].status == "drafting" { sessions[i].status = "blocking" }
            return touch(i)
        }
        upsert(s)
        return s
    }

    public func createShotDraft(_ id: String, _ req: CameraShotDraftRequest) async throws -> CameraShotDraft {
        let (s, d): (CameraSession, CameraShotDraft) = try locked {
            let i = try index(id)
            let dur = req.durationSec ?? sessions[i].durationSec
            let hasGuide = CameraGuides.greyboxReady(sessions[i])
            var request = Self.handoffRequest(sessionId: id)
            if !hasGuide, case .object(var o) = request {
                o["camera"] = .object(["mode": .string("directed")])
                request = .object(o)
            }
            let d = CameraShotDraft(id: nextId("sd"), state: "draft", source: "camera", prompt: req.prompt ?? sessions[i].title, targetModel: req.targetModel ?? "kling-v4.0",
                                    durationSec: dur, aspect: sessions[i].aspect, estimate: CameraEstimate(usd: (0.32 * dur * 100).rounded() / 100), request: request, createdAt: now())
            sessions[i].shotDraft = d
            return (touch(i), d)
        }
        upsert(s)
        return d
    }

    public func linkJob(_ id: String, jobId: String) async throws -> CameraSession {
        let s: CameraSession = try locked {
            let i = try index(id)
            guard sessions[i].shotDraft != nil else { throw ApiError("no_draft", "Make a Shot draft first") }
            sessions[i].shotDraft?.jobId = jobId
            sessions[i].shotDraft?.linkedAt = now()
            sessions[i].status = "generating"
            return touch(i)
        }
        upsert(s)
        return s
    }

    /// A scripted turn: the user message, two tool steps (a Blender wait between), an answer, done. It nudges the camera
    /// path so the plan visibly changes.
    public func chat(_ id: String, message: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [self] in
                do {
                    guard inAppChat else { throw ApiError("director_unavailable", "Direct with Claude isn't set up on the server") }
                    try locked {
                        _ = try index(id)
                        if busy.contains(id) { throw ApiError("chat_busy", "Claude is still working on this shot") }
                        busy.insert(id)
                    }
                    defer { _ = locked { busy.remove(id) } }
                    let pause = { [stepDelay] in if stepDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(stepDelay * 1e9)) } }
                    cont.yield(.message(try addMessage(id, role: "user", source: "chat", text: message)))
                    await pause()
                    cont.yield(.text("On it — "))
                    cont.yield(.tool(id: "tu_1", name: "set_camera_path", status: "running", summary: nil))
                    await pause()
                    var s = try await session(id)
                    if var path = s.cameraPath, let last = path.keyframes.indices.last {
                        path.keyframes[last].position.z = max(0.6, path.keyframes[last].position.z - 0.2)
                        s = try await setPath(id, CameraPathUpdate(camera: path))
                    }
                    try addMessage(id, role: "tool", source: "chat", text: "", tool: CameraToolStep(name: "set_camera_path", ok: true, summary: "lowered the camera 0.2 m"))
                    cont.yield(.tool(id: "tu_1", name: "set_camera_path", status: "done", summary: "lowered the camera 0.2 m"))
                    cont.yield(.tool(id: "tu_2", name: "blender_render_guides", status: "running", summary: "rendering the greybox"))
                    cont.yield(.waiting(reason: "blender"))
                    await pause()
                    try addMessage(id, role: "tool", source: "chat", text: "", tool: CameraToolStep(name: "blender_render_guides", ok: relay.blender))
                    cont.yield(.tool(id: "tu_2", name: "blender_render_guides", status: relay.blender ? "done" : "error", summary: relay.blender ? "greybox and keyframes" : "Blender isn't connected"))
                    let answer = "Lowered the camera 0.2 m for rev \(s.revision) and re-rendered the guides."
                    cont.yield(.text(answer))
                    cont.yield(.message(try addMessage(id, role: "assistant", source: "chat", text: "On it — " + answer)))
                    cont.yield(.done(stopReason: "end_turn", usage: ChatUsage(inputTokens: 1200, outputTokens: 180)))
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func connections() async throws -> CameraConnections {
        locked {
            CameraConnections(relay: relay, claudeApp: .init(lastSeenAt: tokenList.compactMap(\.lastUsedAt).max(), tokens: tokenList.count),
                              mcpUrl: "https://muse.example/mcp", inAppChat: inAppChat, docsUrl: "https://github.com/richard4801/claude-template/blob/main/plans/mcp-bridge.md")
        }
    }

    public func tokens() async throws -> [McpToken] { locked { tokenList } }

    public func createToken(name: String, expiresDays: Int?) async throws -> McpTokenCreated {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 60 else { throw ApiError("bad_request", "name: 1–60 characters") }
        return try locked {
            guard tokenList.count < 20 else { throw ApiError("too_many_tokens", "You have 20 tokens · revoke one first") }
            let secret = "muse_pat_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let t = now()
            let c = McpTokenCreated(id: nextId("pat"), name: n, prefix: String(secret.prefix(13)), token: secret, createdAt: t,
                                    expiresAt: expiresDays.map { t + Double($0) * 86_400_000 })
            tokenList.insert(c.listed, at: 0)
            return c
        }
    }

    public func revokeToken(_ id: String) async throws {
        try locked {
            guard let i = tokenList.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Token not found") }
            tokenList.remove(at: i)
        }
    }

    public func events() -> AsyncStream<CameraLiveEvent> {
        AsyncStream { cont in
            let key = UUID()
            locked { listeners[key] = cont }
            cont.yield(.connected)
            cont.onTermination = { [weak self] _ in self?.locked { _ = self?.listeners.removeValue(forKey: key) } }
        }
    }

    /// Tests and demos: a relay heartbeat changed.
    public func setRelay(_ r: CameraRelayPresence) {
        locked {
            relay = r
            for i in sessions.indices { sessions[i].relay = r }
        }
        emit(.relay(r))
    }
}
