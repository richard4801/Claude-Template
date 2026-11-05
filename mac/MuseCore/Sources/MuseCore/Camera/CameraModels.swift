import Foundation

// Camera sessions (plans/api.md "MCP & camera sessions"): the Directed (Blender) mode of the Camera control, the
// "Direct with Claude" chat and Settings → Connections. Owner only. Times are server milliseconds.

/// A point in metres, Blender world: Z up, X right, +Y away from the default camera. JSON: `[x, y, z]`.
public struct Vec3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(from d: Decoder) throws {
        var c = try d.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        z = c.isAtEnd ? 0 : try c.decode(Double.self)
    }

    public func encode(to e: Encoder) throws {
        var c = e.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(z)
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    /// Length on the floor (X/Y).
    public var planLength: Double { (x * x + y * y).squareRoot() }
    public static func lerp(_ a: Vec3, _ b: Vec3, _ u: Double) -> Vec3 { a + (b - a) * u }
}

/// Camera keyframe. `ease` shapes the segment that starts at this key (Blender keyframe interpolation).
public struct CamKey: Codable, Hashable, Sendable {
    public var t: Double
    public var position: Vec3
    public var target: Vec3?
    public var focalMm: Double?
    public var rollDeg: Double?
    public var ease: String?

    public init(t: Double, position: Vec3, target: Vec3? = nil, focalMm: Double? = nil, rollDeg: Double? = nil, ease: String? = nil) {
        self.t = t
        self.position = position
        self.target = target
        self.focalMm = focalMm
        self.rollDeg = rollDeg
        self.ease = ease
    }
}

/// Character keyframe. facingDeg 0 = facing -Y (toward the default camera).
public struct CharKey: Codable, Hashable, Sendable {
    public var t: Double
    public var position: Vec3
    public var facingDeg: Double?
    public var action: String?

    public init(t: Double, position: Vec3, facingDeg: Double? = nil, action: String? = nil) {
        self.t = t
        self.position = position
        self.facingDeg = facingDeg
        self.action = action
    }
}

public struct CameraPath: Codable, Hashable, Sendable {
    public var keyframes: [CamKey]
    public var cuts: [Double]?
    public var sensorMm: Double?

    public init(keyframes: [CamKey], cuts: [Double]? = nil, sensorMm: Double? = nil) {
        self.keyframes = keyframes
        self.cuts = cuts
        self.sensorMm = sensorMm
    }
}

public struct CameraBlockingTrack: Codable, Hashable, Sendable {
    public var modelId: String
    public var keyframes: [CharKey]
    public var note: String?

    public init(modelId: String, keyframes: [CharKey], note: String? = nil) {
        self.modelId = modelId
        self.keyframes = keyframes
        self.note = note
    }
}

public struct CameraBlocking: Codable, Hashable, Sendable {
    public var characters: [CameraBlockingTrack]
    public init(characters: [CameraBlockingTrack]) { self.characters = characters }
}

/// A character in the session's cast (`name` is filled in by the server).
public struct CameraCast: Codable, Hashable, Sendable, Identifiable {
    public var modelId: String
    public var name: String
    public var role: String?
    public var heightM: Double?
    public var id: String { modelId }

    public init(modelId: String, name: String, role: String? = nil, heightM: Double? = nil) {
        self.modelId = modelId
        self.name = name
        self.role = role
        self.heightM = heightM
    }
}

public struct CameraRelayPresence: Codable, Hashable, Sendable {
    public var online: Bool
    public var blender: Bool
    public var addonVersion: String?

    public init(online: Bool = false, blender: Bool = false, addonVersion: String? = nil) {
        self.online = online
        self.blender = blender
        self.addonVersion = addonVersion
    }
}

/// Claude's presence on a session: the in-app chat is running a turn / when the owner's own Claude app last used a token.
public struct CameraClaudePresence: Codable, Hashable, Sendable {
    public var chatBusy: Bool?
    public var appLastSeenAt: Double?

    public init(chatBusy: Bool? = nil, appLastSeenAt: Double? = nil) {
        self.chatBusy = chatBusy
        self.appLastSeenAt = appLastSeenAt
    }
}

public struct CameraEstimate: Codable, Hashable, Sendable {
    public var usd: Double
    public var tokens: Double?
    public init(usd: Double, tokens: Double? = nil) {
        self.usd = usd
        self.tokens = tokens
    }
}

/// A Shot draft: an estimate only. `request` is the suite's ShotRequest; the app POSTs it to /v1/suite/shots on Generate.
public struct CameraShotDraft: Codable, Hashable, Sendable {
    public var id: String
    public var state: String?
    public var source: String?
    public var prompt: String?
    public var targetModel: String?
    public var durationSec: Double?
    public var aspect: String?
    public var estimate: CameraEstimate?
    public var request: JSONValue?
    public var warnings: [String]?
    public var jobId: String?
    public var linkedAt: Double?
    public var createdAt: Double?

    public init(id: String, state: String? = "draft", source: String? = nil, prompt: String? = nil, targetModel: String? = nil, durationSec: Double? = nil,
                aspect: String? = nil, estimate: CameraEstimate? = nil, request: JSONValue? = nil, warnings: [String]? = nil, jobId: String? = nil,
                linkedAt: Double? = nil, createdAt: Double? = nil) {
        self.id = id
        self.state = state
        self.source = source
        self.prompt = prompt
        self.targetModel = targetModel
        self.durationSec = durationSec
        self.aspect = aspect
        self.estimate = estimate
        self.request = request
        self.warnings = warnings
        self.jobId = jobId
        self.linkedAt = linkedAt
        self.createdAt = createdAt
    }
}

public struct CameraToolStep: Codable, Hashable, Sendable {
    public var name: String
    public var ok: Bool
    public var summary: String?
    public init(name: String, ok: Bool, summary: String? = nil) {
        self.name = name
        self.ok = ok
        self.summary = summary
    }
}

/// One line of the shared transcript. role "user"|"assistant"|"tool"; source "app"|"chat"|"mcp".
public struct CameraMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var role: String
    public var source: String
    public var text: String
    public var tool: CameraToolStep?
    public var createdAt: Double

    public init(id: String, role: String, source: String, text: String, tool: CameraToolStep? = nil, createdAt: Double) {
        self.id = id
        self.role = role
        self.source = source
        self.text = text
        self.tool = tool
        self.createdAt = createdAt
    }
}

public struct CameraSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var brief: String?
    /// drafting | blocking | rendering | ready | generating | done | failed
    public var status: String
    public var aspect: String
    public var fps: Double
    public var durationSec: Double
    public var targetModel: String?
    public var presets: JSONValue?
    public var characters: [CameraCast]
    public var cameraPath: CameraPath?
    public var blocking: CameraBlocking?
    public var assets: [CameraAsset]
    public var shotDraft: CameraShotDraft?
    /// The directed part of the CameraSpec (assets the Shot points at).
    public var camera: JSONValue?
    public var revision: Int
    public var relay: CameraRelayPresence?
    public var claude: CameraClaudePresence?
    public var createdAt: Double
    public var updatedAt: Double
    /// GET one: the last 50.
    public var messages: [CameraMessage]?

    public init(id: String, title: String, brief: String? = nil, status: String = "drafting", aspect: String = "9:16", fps: Double = 24, durationSec: Double = 6,
                targetModel: String? = nil, presets: JSONValue? = nil, characters: [CameraCast] = [], cameraPath: CameraPath? = nil, blocking: CameraBlocking? = nil,
                assets: [CameraAsset] = [], shotDraft: CameraShotDraft? = nil, camera: JSONValue? = nil, revision: Int = 1, relay: CameraRelayPresence? = nil,
                claude: CameraClaudePresence? = nil, createdAt: Double = 0, updatedAt: Double = 0, messages: [CameraMessage]? = nil) {
        self.id = id
        self.title = title
        self.brief = brief
        self.status = status
        self.aspect = aspect
        self.fps = fps
        self.durationSec = durationSec
        self.targetModel = targetModel
        self.presets = presets
        self.characters = characters
        self.cameraPath = cameraPath
        self.blocking = blocking
        self.assets = assets
        self.shotDraft = shotDraft
        self.camera = camera
        self.revision = revision
        self.relay = relay
        self.claude = claude
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case id, title, brief, status, aspect, fps, durationSec, targetModel, presets, characters, cameraPath, blocking, assets, shotDraft, camera, revision, relay, claude,
             createdAt, updatedAt, messages
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        brief = try c.decodeIfPresent(String.self, forKey: .brief)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "drafting"
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect) ?? "9:16"
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 24
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 6
        targetModel = try c.decodeIfPresent(String.self, forKey: .targetModel)
        presets = try c.decodeIfPresent(JSONValue.self, forKey: .presets)
        characters = try c.decodeIfPresent([CameraCast].self, forKey: .characters) ?? []
        cameraPath = try c.decodeIfPresent(CameraPath.self, forKey: .cameraPath)
        blocking = try c.decodeIfPresent(CameraBlocking.self, forKey: .blocking)
        assets = try c.decodeIfPresent([CameraAsset].self, forKey: .assets) ?? []
        shotDraft = try c.decodeIfPresent(CameraShotDraft.self, forKey: .shotDraft)
        camera = try c.decodeIfPresent(JSONValue.self, forKey: .camera)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        relay = try c.decodeIfPresent(CameraRelayPresence.self, forKey: .relay)
        claude = try c.decodeIfPresent(CameraClaudePresence.self, forKey: .claude)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        messages = try c.decodeIfPresent([CameraMessage].self, forKey: .messages)
    }
}

// MARK: Requests

public struct CameraSessionCreate: Codable, Hashable, Sendable {
    public struct Member: Codable, Hashable, Sendable {
        public var modelId: String
        public var role: String?
        public var heightM: Double?
        public init(modelId: String, role: String? = nil, heightM: Double? = nil) {
            self.modelId = modelId
            self.role = role
            self.heightM = heightM
        }
    }
    public var title: String?
    public var brief: String?
    public var aspect: String?
    public var fps: Double?
    public var durationSec: Double?
    public var characters: [Member]?

    public init(title: String? = nil, brief: String? = nil, aspect: String? = nil, fps: Double? = nil, durationSec: Double? = nil, characters: [Member]? = nil) {
        self.title = title
        self.brief = brief
        self.aspect = aspect
        self.fps = fps
        self.durationSec = durationSec
        self.characters = characters
    }
}

public struct CameraSessionPatch: Codable, Hashable, Sendable {
    public var title: String?
    public var brief: String?
    public var aspect: String?
    public var fps: Double?
    public var durationSec: Double?
    public var revision: Int?
    public init(title: String? = nil, brief: String? = nil, aspect: String? = nil, fps: Double? = nil, durationSec: Double? = nil, revision: Int? = nil) {
        self.title = title
        self.brief = brief
        self.aspect = aspect
        self.fps = fps
        self.durationSec = durationSec
        self.revision = revision
    }
}

/// PUT /v1/camera-sessions/{id}/path
public struct CameraPathUpdate: Codable, Hashable, Sendable {
    public var camera: CameraPath?
    public var characters: [CameraBlockingTrack]?
    public init(camera: CameraPath? = nil, characters: [CameraBlockingTrack]? = nil) {
        self.camera = camera
        self.characters = characters
    }
}

public struct CameraShotDraftRequest: Codable, Hashable, Sendable {
    public var prompt: String?
    public var targetModel: String?
    public var durationSec: Double?
    public init(prompt: String? = nil, targetModel: String? = nil, durationSec: Double? = nil) {
        self.prompt = prompt
        self.targetModel = targetModel
        self.durationSec = durationSec
    }
}

// MARK: Chat

public struct ChatUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// One event of POST /v1/camera-sessions/{id}/chat (`data: <json>` each).
public enum ChatEvent: Hashable, Sendable {
    case text(String)
    /// status running | done | error
    case tool(id: String, name: String, status: String, summary: String?)
    /// A Blender call is out to the Mac.
    case waiting(reason: String)
    case message(CameraMessage)
    case done(stopReason: String?, usage: ChatUsage?)
    case error(code: String, message: String)

    private struct Wire: Decodable {
        var type: String
        var delta: String?
        var id: String?
        var name: String?
        var status: String?
        var summary: String?
        var reason: String?
        var message: CameraMessage?
        var stopReason: String?
        var usage: ChatUsage?
        var code: String?
        var error: String?
    }

    /// One event's JSON; nil for an unknown type (newer servers may add some).
    public static func parse(_ json: Data) -> ChatEvent? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: json) else { return nil }
        switch w.type {
        case "text": return .text(w.delta ?? "")
        case "tool": return .tool(id: w.id ?? "", name: w.name ?? "tool", status: w.status ?? "running", summary: w.summary)
        case "waiting": return .waiting(reason: w.reason ?? "blender")
        case "message": return w.message.map { .message($0) }
        case "done": return .done(stopReason: w.stopReason, usage: w.usage)
        case "error": return .error(code: w.code ?? "error", message: w.error ?? "Something went wrong")
        default: return nil
        }
    }
}

/// Turns SSE lines (no line endings) into ChatEvents.
public struct ChatStreamParser: Sendable {
    private var sse = SSEParser()
    public init() {}
    public mutating func feed(_ line: String) -> ChatEvent? {
        guard let payload = sse.feed(line) else { return nil }
        return ChatEvent.parse(Data(payload.utf8))
    }

    /// A whole body at once (tests, and Linux where URLSession has no byte stream).
    public static func parseAll(_ body: String) -> [ChatEvent] {
        var p = ChatStreamParser()
        var out: [ChatEvent] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let e = p.feed(String(line)) { out.append(e) }
        }
        if let e = p.feed("") { out.append(e) }
        return out
    }
}

// MARK: Connections and tokens

public struct McpToken: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var prefix: String
    public var createdAt: Double
    public var lastUsedAt: Double?
    public var expiresAt: Double?
    public init(id: String, name: String, prefix: String, createdAt: Double, lastUsedAt: Double? = nil, expiresAt: Double? = nil) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
    }
}

/// POST /v1/mcp/tokens reply: `token` is shown once.
public struct McpTokenCreated: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var prefix: String
    public var token: String
    public var createdAt: Double
    public var expiresAt: Double?
    public init(id: String, name: String, prefix: String, token: String, createdAt: Double, expiresAt: Double? = nil) {
        self.id = id
        self.name = name
        self.prefix = prefix
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
    public var listed: McpToken { McpToken(id: id, name: name, prefix: prefix, createdAt: createdAt, expiresAt: expiresAt) }
}

/// GET /v1/connections
public struct CameraConnections: Codable, Hashable, Sendable {
    public struct ClaudeApp: Codable, Hashable, Sendable {
        public var lastSeenAt: Double?
        public var tokens: Int
        public init(lastSeenAt: Double? = nil, tokens: Int = 0) {
            self.lastSeenAt = lastSeenAt
            self.tokens = tokens
        }
    }
    public var relay: CameraRelayPresence
    public var claudeApp: ClaudeApp
    public var mcpUrl: String
    public var inAppChat: Bool
    public var docsUrl: String?
    public init(relay: CameraRelayPresence, claudeApp: ClaudeApp, mcpUrl: String, inAppChat: Bool, docsUrl: String? = nil) {
        self.relay = relay
        self.claudeApp = claudeApp
        self.mcpUrl = mcpUrl
        self.inAppChat = inAppChat
        self.docsUrl = docsUrl
    }
}

// MARK: Live events

/// `camera` events, plus the relay presence from `blender` `op: "relay"` (owners' devices only).
public enum CameraLiveEvent: Hashable, Sendable {
    case upsert(CameraSession)
    case delete(String)
    case message(sessionId: String, CameraMessage)
    case asset(sessionId: String, CameraAsset)
    case relay(CameraRelayPresence)
    /// Not from the server: the event stream (re)connected (the app refetches, and shows ● LIVE).
    case connected
    /// Not from the server: the stream dropped.
    case disconnected

    private struct Envelope: Decodable {
        var type: String
        var op: String?
        var id: String?
        var sessionId: String?
        var session: CameraSession?
        var message: CameraMessage?
        var asset: CameraAsset?
        var online: Bool?
        var blender: JSONValue?
        var addonVersion: String?
    }

    /// One GET /v1/events payload; nil for any other event type.
    public static func parse(_ json: Data) -> CameraLiveEvent? {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: json) else { return nil }
        switch (e.type, e.op) {
        case ("camera", "upsert"): return e.session.map { .upsert($0) }
        case ("camera", "delete"): return e.id.map { .delete($0) }
        case ("camera", "message"):
            guard let s = e.sessionId, let m = e.message else { return nil }
            return .message(sessionId: s, m)
        case ("camera", "asset"):
            guard let s = e.sessionId, let a = e.asset else { return nil }
            return .asset(sessionId: s, a)
        case ("blender", "relay"):
            var p = CameraRelayPresence(online: e.online ?? false, blender: false, addonVersion: e.addonVersion)
            switch e.blender {
            case .bool(let b)?: p.blender = b
            case .object(let o)?:
                if case .bool(let b)? = o["connected"] { p.blender = b }
                if case .string(let v)? = o["addonVersion"] { p.addonVersion = v }
            default: break
            }
            if !p.online { p.blender = false }
            return .relay(p)
        default: return nil
        }
    }
}

/// Picks camera events out of the GET /v1/events SSE stream.
public struct CameraLiveEventFilter: Sendable {
    private var sse = SSEParser()
    public init() {}
    public mutating func feed(_ line: String) -> CameraLiveEvent? {
        guard let payload = sse.feed(line) else { return nil }
        return CameraLiveEvent.parse(Data(payload.utf8))
    }
}
