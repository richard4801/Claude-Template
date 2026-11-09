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
    /// Recreate and edit threads (workstream 1): the role, the MUSE tools for that screen and the id they act on. The Mac
    /// seeds its Claude Code with it. nil on older servers and camera threads.
    public var brief: ClaudeBrief?
    /// The list of chats this one belongs to (`suite:photo`, `recreate:rx_1`…). nil on an older server.
    public var contextKey: String?
    /// The owner's name for the chat, else its first words (set by the server). nil until something is said.
    public var title: String?
    /// In a list: how many messages (yours and Claude's) it has.
    public var messageCount: Int?

    public init(id: String, contextKind: String, contextId: String, claudeSessionId: String? = nil, createdAt: Double, updatedAt: Double,
                brief: ClaudeBrief? = nil, contextKey: String? = nil, title: String? = nil, messageCount: Int? = nil) {
        self.id = id
        self.contextKind = contextKind
        self.contextId = contextId
        self.claudeSessionId = claudeSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.brief = brief
        self.contextKey = contextKey
        self.title = title
        self.messageCount = messageCount
    }

    enum CodingKeys: String, CodingKey { case id, contextKind, contextId, claudeSessionId, createdAt, updatedAt, brief, contextKey, title, messageCount }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contextKind = (try? c.decode(String.self, forKey: .contextKind)) ?? ""
        contextId = (try? c.decode(String.self, forKey: .contextId)) ?? ""
        claudeSessionId = try? c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        brief = try? c.decodeIfPresent(ClaudeBrief.self, forKey: .brief)
        contextKey = try? c.decodeIfPresent(String.self, forKey: .contextKey)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        messageCount = try? c.decodeIfPresent(Int.self, forKey: .messageCount)
    }
}

/// GET /v1/claude/threads?key=: one place's chats, newest first.
public struct ClaudeThreadList: Codable, Hashable, Sendable {
    public var key: String
    public var threads: [ClaudeThread]
    public init(key: String, threads: [ClaudeThread]) {
        self.key = key
        self.threads = threads
    }
    enum CodingKeys: String, CodingKey { case key, threads }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        threads = (try? c.decode([ClaudeThread].self, forKey: .threads)) ?? []
    }
}

/// `ClaudeThread.brief`: `{prompt, tools[], referenceId}` (recreate) or `{prompt, tools[], sessionId}` (edit).
public struct ClaudeBrief: Codable, Hashable, Sendable {
    public var prompt: String
    public var tools: [String]
    public var referenceId: String?
    public var sessionId: String?
    /// Suite threads: the shared composer draft (`sa_…`) Claude's suite tools act on.
    public var assistId: String?

    public init(prompt: String, tools: [String] = [], referenceId: String? = nil, sessionId: String? = nil, assistId: String? = nil) {
        self.prompt = prompt; self.tools = tools; self.referenceId = referenceId; self.sessionId = sessionId; self.assistId = assistId
    }

    enum CodingKeys: String, CodingKey { case prompt, tools, referenceId, sessionId, assistId }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        tools = (try? c.decode([String].self, forKey: .tools)) ?? []
        referenceId = try? c.decodeIfPresent(String.self, forKey: .referenceId)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        assistId = try? c.decodeIfPresent(String.self, forKey: .assistId)
    }

    /// What Claude Code is started with (`--append-system-prompt`): the server's prompt plus the id it acts on.
    public var systemPrompt: String? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        var lines = [p]
        if let r = referenceId, !r.isEmpty { lines.append("The reference: \(r).") }
        if let s = sessionId, !s.isEmpty { lines.append("The edit session: \(s).") }
        if let a = assistId, !a.isEmpty { lines.append("The Suite draft: \(a).") }
        return lines.joined(separator: "\n\n")
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
    /// Images the owner attached: `attachments: [{id, uploadId, mimeType, bytes, width, height, url}]` (the url is a signed
    /// link that lasts an hour: read the thread again for fresh ones). Read leniently (bare upload ids too).
    public var attachments: [ClaudeAttachment]? = nil

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

    private enum K: String, CodingKey { case id, threadId, role, source, text, turnId, tool, image, createdAt, attachments, uploadIds, uploadId }

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
        attachments = Self.attachments(c)
    }

    /// `attachments: [{…} | "id"]`, else `uploadIds: [id]`, else one `uploadId`. nil when there are none.
    private static func attachments(_ c: KeyedDecodingContainer<K>) -> [ClaudeAttachment]? {
        var list: [ClaudeAttachment] = []
        if let wrapped = try? c.decodeIfPresent([Lenient<ClaudeAttachment>].self, forKey: .attachments) {
            list = wrapped.compactMap { $0.value }
        } else if let ids = try? c.decodeIfPresent([String].self, forKey: .uploadIds) {
            list = ids.map { ClaudeAttachment(uploadId: $0) }
        } else if let id = try? c.decodeIfPresent(String.self, forKey: .uploadId) {
            list = [ClaudeAttachment(uploadId: id)]
        }
        let kept = list.filter { !$0.uploadId.isEmpty || $0.url != nil }
        return kept.isEmpty ? nil : kept
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
    /// Images sent with the turn (the claim response carries fresh links).
    public var attachments: [ClaudeAttachment]?

    public init(id: String, threadId: String, text: String, from: String = "phone", state: String = "queued", error: String? = nil,
                createdAt: Double, claimedAt: Double? = nil, finishedAt: Double? = nil, attachments: [ClaudeAttachment]? = nil) {
        self.attachments = attachments
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

    private enum K: String, CodingKey { case id, threadId, text, from, state, error, createdAt, claimedAt, finishedAt, attachments }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = try c.decode(String.self, forKey: .threadId)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? "phone"
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "queued"
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
        createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        claimedAt = (try? c.decodeIfPresent(Double.self, forKey: .claimedAt)) ?? nil
        finishedAt = (try? c.decodeIfPresent(Double.self, forKey: .finishedAt)) ?? nil
        var a: [ClaudeAttachment] = []
        if let wrapped = try? c.decodeIfPresent([Lenient<ClaudeAttachment>].self, forKey: .attachments) { a = wrapped.compactMap { $0.value } }
        attachments = a.isEmpty ? nil : a
    }
}

public enum ClaudeToolStatus: String, Codable, Hashable, Sendable {
    case running, done, error
}

/// What the Mac mirrors (POST …/events) and what the live `claude` `{op: "event"}` carries.
public enum ClaudeEvent: Codable, Hashable, Sendable {
    /// `attachments`: the upload ids of images typed with it on this Mac (`[{uploadId}]` on the wire).
    case user(text: String, attachments: [String] = [])
    case text(delta: String)
    case assistant(text: String)
    case tool(id: String, name: String, status: ClaudeToolStatus, summary: String?, input: JSONValue?)
    /// base64, ≤ 2 MB
    case image(data: String, mimeType: String)
    case done(ok: Bool, error: String?, model: String?)

    public static let maxImageBytes = 2 * 1024 * 1024

    private enum K: String, CodingKey { case type, text, delta, id, name, status, summary, input, data, mimeType, ok, error, model, attachments }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        func s(_ k: K) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        switch type {
        case "user":
            var ids: [String] = []
            if let wrapped = try? c.decodeIfPresent([Lenient<ClaudeAttachment>].self, forKey: .attachments) {
                ids = wrapped.compactMap { $0.value?.uploadId }.filter { !$0.isEmpty }
            }
            self = .user(text: s(.text) ?? "", attachments: ids)
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
        case .user(let text, let attachments):
            try c.encode("user", forKey: .type)
            try c.encode(text, forKey: .text)
            if !attachments.isEmpty { try c.encode(attachments.map { ClaudeAttachmentRef(uploadId: $0) }, forKey: .attachments) }
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
/// An image on a Claude message or turn. Every field but the upload id is optional; a bare string reads as an upload id.
public struct ClaudeAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var uploadId: String
    public var mimeType: String?
    public var bytes: Int?
    public var width: Int?
    public var height: Int?
    /// A private signed link (about an hour), or a normal /uploads address.
    public var url: String?

    public init(id: String? = nil, uploadId: String, mimeType: String? = nil, bytes: Int? = nil, width: Int? = nil, height: Int? = nil, url: String? = nil) {
        self.id = id ?? uploadId
        self.uploadId = uploadId
        self.mimeType = mimeType
        self.bytes = bytes
        self.width = width
        self.height = height
        self.url = url
    }

    private enum K: String, CodingKey { case id, uploadId, mimeType, bytes, width, height, url }

    public init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) {
            self.init(uploadId: s)
            return
        }
        let c = try d.container(keyedBy: K.self)
        func s(_ k: K) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func n(_ k: K) -> Int? { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil).map { Int($0) } }
        var up = ""
        if let u = s(.uploadId) { up = u } else if let i = s(.id) { up = i }
        self.init(id: s(.id), uploadId: up, mimeType: s(.mimeType), bytes: n(.bytes), width: n(.width), height: n(.height), url: s(.url))
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id)
        try c.encode(uploadId, forKey: .uploadId)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(url, forKey: .url)
    }
}

/// `{uploadId}`: an image sent with a message.
public struct ClaudeAttachmentRef: Codable, Hashable, Sendable {
    public var uploadId: String
    public init(uploadId: String) { self.uploadId = uploadId }
}

struct Lenient<T: Decodable>: Decodable {
    var value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}
