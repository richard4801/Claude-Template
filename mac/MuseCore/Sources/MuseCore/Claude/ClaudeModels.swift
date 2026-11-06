import Foundation

// Claude on the owner's plan (plans/api.md "Claude on the owner's plan: OAuth, chat threads, Mac runner (2026-11-06)").
// The Mac runs Anthropic's Claude Code (signed in to the owner's subscription) per chat thread and mirrors its stream to
// the server; the phone relays its messages to the Mac. Owner only. Timestamps are epoch milliseconds, like the rest of the API.

/// One conversation per camera or edit session.
public struct ClaudeThread: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var contextKind: String
    public var contextId: String
    /// Claude Code's session id for `--resume`, set by the Mac.
    public var claudeSessionId: String?
    public var createdAt: Double
    public var updatedAt: Double

    public init(id: String, contextKind: String, contextId: String, claudeSessionId: String? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id
        self.contextKind = contextKind
        self.contextId = contextId
        self.claudeSessionId = claudeSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// GET /v1/claude/threads/{id}: the thread, its last 100 messages (oldest first) and the turn in flight.
public struct ClaudeThreadDetail: Codable, Hashable, Sendable {
    public var thread: ClaudeThread
    public var messages: [ClaudeMessage]
    public var activeTurn: ClaudeTurn?

    public init(thread: ClaudeThread, messages: [ClaudeMessage] = [], activeTurn: ClaudeTurn? = nil) {
        self.thread = thread
        self.messages = messages
        self.activeTurn = activeTurn
    }

    private enum K: String, CodingKey { case messages, activeTurn }

    public init(from d: Decoder) throws {
        thread = try ClaudeThread(from: d)
        let c = try d.container(keyedBy: K.self)
        messages = (try? c.decodeIfPresent([Lenient<ClaudeMessage>].self, forKey: .messages))?.compactMap(\.value) ?? []
        activeTurn = try? c.decodeIfPresent(ClaudeTurn.self, forKey: .activeTurn)
    }

    public func encode(to e: Encoder) throws {
        try thread.encode(to: e)
        var c = e.container(keyedBy: K.self)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(activeTurn, forKey: .activeTurn)
    }
}

public struct ClaudeToolRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var ok: Bool?
    public var summary: String?
    public init(id: String, name: String, ok: Bool? = nil, summary: String? = nil) {
        self.id = id
        self.name = name
        self.ok = ok
        self.summary = summary
    }
}

public struct ClaudeImageRef: Codable, Hashable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}

public struct ClaudeMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var threadId: String
    /// user | assistant | tool
    public var role: String
    /// mac | phone | api
    public var source: String
    public var text: String
    public var turnId: String?
    public var tool: ClaudeToolRef?
    /// A frame Claude grabbed.
    public var image: ClaudeImageRef?
    public var createdAt: Double

    public init(id: String, threadId: String, role: String, source: String, text: String = "", turnId: String? = nil,
                tool: ClaudeToolRef? = nil, image: ClaudeImageRef? = nil, createdAt: Double) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.source = source
        self.text = text
        self.turnId = turnId
        self.tool = tool
        self.image = image
        self.createdAt = createdAt
    }

    private enum K: String, CodingKey { case id, threadId, role, source, text, turnId, tool, image, createdAt }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = (try? c.decodeIfPresent(String.self, forKey: .threadId)) ?? ""
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "mac"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        turnId = try? c.decodeIfPresent(String.self, forKey: .turnId)
        tool = try? c.decodeIfPresent(ClaudeToolRef.self, forKey: .tool)
        image = try? c.decodeIfPresent(ClaudeImageRef.self, forKey: .image)
        createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
    }
}

public struct ClaudeTurn: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var threadId: String
    public var text: String
    /// phone | mac
    public var from: String
    /// queued | running | done | failed | stopped
    public var state: String
    public var error: String?
    public var createdAt: Double
    public var claimedAt: Double?
    public var finishedAt: Double?

    public init(id: String, threadId: String, text: String, from: String = "phone", state: String = "queued", error: String? = nil,
                createdAt: Double, claimedAt: Double? = nil, finishedAt: Double? = nil) {
        self.id = id
        self.threadId = threadId
        self.text = text
        self.from = from
        self.state = state
        self.error = error
        self.createdAt = createdAt
        self.claimedAt = claimedAt
        self.finishedAt = finishedAt
    }

    public var isOpen: Bool { state == "queued" || state == "running" }
}

public enum ClaudeToolStatus: String, Codable, Hashable, Sendable {
    case running, done, error
}

/// What the Mac mirrors (POST …/events) and what the live `claude` `{op: "event"}` carries.
public enum ClaudeEvent: Codable, Hashable, Sendable {
    case user(text: String)
    case text(delta: String)
    case assistant(text: String)
    case tool(id: String, name: String, status: ClaudeToolStatus, summary: String?, input: JSONValue?)
    /// base64, ≤ 2 MB
    case image(data: String, mimeType: String)
    case done(ok: Bool, error: String?, model: String?)

    public static let maxImageBytes = 2 * 1024 * 1024

    private enum K: String, CodingKey { case type, text, delta, id, name, status, summary, input, data, mimeType, ok, error, model }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        func s(_ k: K) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        switch type {
        case "user": self = .user(text: s(.text) ?? "")
        case "text": self = .text(delta: s(.delta) ?? "")
        case "assistant": self = .assistant(text: s(.text) ?? "")
        case "tool":
            self = .tool(id: s(.id) ?? "", name: s(.name) ?? "", status: ClaudeToolStatus(rawValue: s(.status) ?? "") ?? .running,
                         summary: s(.summary), input: (try? c.decodeIfPresent(JSONValue.self, forKey: .input)) ?? nil)
        case "image": self = .image(data: s(.data) ?? "", mimeType: s(.mimeType) ?? "image/png")
        case "done": self = .done(ok: (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false, error: s(.error), model: s(.model))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Claude event \(type)")
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case .user(let text):
            try c.encode("user", forKey: .type)
            try c.encode(text, forKey: .text)
        case .text(let delta):
            try c.encode("text", forKey: .type)
            try c.encode(delta, forKey: .delta)
        case .assistant(let text):
            try c.encode("assistant", forKey: .type)
            try c.encode(text, forKey: .text)
        case .tool(let id, let name, let status, let summary, let input):
            try c.encode("tool", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(summary, forKey: .summary)
            try c.encodeIfPresent(input, forKey: .input)
        case .image(let data, let mimeType):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        case .done(let ok, let error, let model):
            try c.encode("done", forKey: .type)
            try c.encode(ok, forKey: .ok)
            try c.encodeIfPresent(error, forKey: .error)
            try c.encodeIfPresent(model, forKey: .model)
        }
    }
}

/// Claude Code on the owner's Mac, as the heartbeat reports it.
public struct ClaudeCodeInfo: Codable, Hashable, Sendable {
    public var installed: Bool
    public var signedIn: Bool
    public var version: String?
    /// Owner only.
    public var model: String?
    public init(installed: Bool = false, signedIn: Bool = false, version: String? = nil, model: String? = nil) {
        self.installed = installed
        self.signedIn = signedIn
        self.version = version
        self.model = model
    }
    public var ready: Bool { installed && signedIn }
}

public struct ClaudeMacStatus: Codable, Hashable, Sendable {
    public var online: Bool
    public var claudeCode: ClaudeCodeInfo
    public var answeringTurn: String?
    public init(online: Bool = false, claudeCode: ClaudeCodeInfo = ClaudeCodeInfo(), answeringTurn: String? = nil) {
        self.online = online
        self.claudeCode = claudeCode
        self.answeringTurn = answeringTurn
    }
    private enum K: String, CodingKey { case online, claudeCode, answeringTurn }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        claudeCode = (try? c.decodeIfPresent(ClaudeCodeInfo.self, forKey: .claudeCode)) ?? ClaudeCodeInfo()
        answeringTurn = try? c.decodeIfPresent(String.self, forKey: .answeringTurn)
    }
}

public struct ClaudeApiFallback: Codable, Hashable, Sendable {
    /// ANTHROPIC_API_KEY is set on the server.
    public var available: Bool
    /// The owner turned it on (off by default, billed per use).
    public var enabled: Bool
    public init(available: Bool = false, enabled: Bool = false) {
        self.available = available
        self.enabled = enabled
    }
    /// The in-app API chat may be offered.
    public var usable: Bool { available && enabled }
}

public struct ClaudeStatus: Codable, Hashable, Sendable {
    public var mac: ClaudeMacStatus
    public var apiFallback: ClaudeApiFallback
    /// <base>/mcp: what the owner pastes into claude.ai → Settings → Connectors.
    public var connectorUrl: String
    public var openInClaudeUrl: String?

    public init(mac: ClaudeMacStatus = ClaudeMacStatus(), apiFallback: ClaudeApiFallback = ClaudeApiFallback(), connectorUrl: String, openInClaudeUrl: String? = nil) {
        self.mac = mac
        self.apiFallback = apiFallback
        self.connectorUrl = connectorUrl
        self.openInClaudeUrl = openInClaudeUrl
    }

    private enum K: String, CodingKey { case mac, apiFallback, connectorUrl, openInClaudeUrl }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        mac = (try? c.decodeIfPresent(ClaudeMacStatus.self, forKey: .mac)) ?? ClaudeMacStatus()
        apiFallback = (try? c.decodeIfPresent(ClaudeApiFallback.self, forKey: .apiFallback)) ?? ClaudeApiFallback()
        connectorUrl = (try? c.decodeIfPresent(String.self, forKey: .connectorUrl)) ?? ""
        openInClaudeUrl = try? c.decodeIfPresent(String.self, forKey: .openInClaudeUrl)
    }
}

public struct ClaudeHeartbeat: Codable, Hashable, Sendable {
    public var claudeCode: ClaudeCodeInfo
    public init(claudeCode: ClaudeCodeInfo) { self.claudeCode = claudeCode }
}

public struct ClaudeHeartbeatReply: Codable, Hashable, Sendable {
    public var ok: Bool
    public var pending: [ClaudeTurn]
    public init(ok: Bool = true, pending: [ClaudeTurn] = []) {
        self.ok = ok
        self.pending = pending
    }
    private enum K: String, CodingKey { case ok, pending }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        pending = (try? c.decodeIfPresent([Lenient<ClaudeTurn>].self, forKey: .pending))?.compactMap(\.value) ?? []
    }
}

/// POST …/messages (from a device that can't run Claude) → 202.
public struct ClaudeMessagePosted: Codable, Hashable, Sendable {
    public var message: ClaudeMessage
    public var turn: ClaudeTurn
    public init(message: ClaudeMessage, turn: ClaudeTurn) {
        self.message = message
        self.turn = turn
    }
}

/// POST …/events body.
public struct ClaudeEventBatch: Codable, Hashable, Sendable {
    public var turnId: String?
    public var events: [ClaudeEvent]
    public init(turnId: String?, events: [ClaudeEvent]) {
        self.turnId = turnId
        self.events = events
    }
}

/// POST /v1/mcp/session-token: an owner access token for the local Claude Code's `--mcp-config`.
public struct McpSessionToken: Codable, Hashable, Sendable {
    public var token: String
    /// Epoch ms (an ISO 8601 string is accepted too).
    public var expiresAt: Double
    public var mcpUrl: String

    public init(token: String, expiresAt: Double, mcpUrl: String) {
        self.token = token
        self.expiresAt = expiresAt
        self.mcpUrl = mcpUrl
    }

    private enum K: String, CodingKey { case token, expiresAt, mcpUrl }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        token = try c.decode(String.self, forKey: .token)
        mcpUrl = (try? c.decodeIfPresent(String.self, forKey: .mcpUrl)) ?? ""
        if let n = try? c.decode(Double.self, forKey: .expiresAt) {
            expiresAt = n
        } else if let s = try? c.decode(String.self, forKey: .expiresAt), let date = ClaudeTime.iso(s) {
            expiresAt = date.timeIntervalSince1970 * 1000
        } else {
            expiresAt = 0
        }
    }

    /// Kept until 5 minutes before it expires.
    public func fresh(now: Double, margin: Double = 5 * 60_000) -> Bool { expiresAt - margin > now }
}

enum ClaudeTime {
    static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Decodes an element or nil, so one malformed entry never drops a whole list.
struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}
