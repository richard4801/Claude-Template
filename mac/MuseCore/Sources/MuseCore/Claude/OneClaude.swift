import Foundation

// One Claude (plans/one-claude.md): one Claude with several chats. Chats are per piece of work and follow the person
// across pages; Claude knows the page they are on and can open pages itself. These are the server's shapes
// (`/v1/claude/chats`, `/v1/claude/memory`, the `ui` lines Claude leaves), app-neutral so Android can use the same.

/// The page the person is on, as the server takes it (`PageSchema`): the page, its item's name, the AI Suite tool and
/// the ids it has open (they fill in Claude's tools: "this edit", "this shot").
public struct ClaudePage: Codable, Hashable, Sendable {
    public var name: String
    public var label: String?
    public var sub: String?
    public var tool: String?
    public var ids: [String: String]?
    /// In the middle of something (typing, playing, a dialog): Claude asks before taking them away.
    public var busy: Bool?

    public init(name: String, label: String? = nil, sub: String? = nil, tool: String? = nil, ids: [String: String]? = nil, busy: Bool? = nil) {
        self.name = name; self.label = label; self.sub = sub; self.tool = tool; self.ids = ids; self.busy = busy
    }

    static let names = ["home": "Home", "cast": "Cast", "character": "Character", "suite": "AI Suite", "edit": "Edit", "recreate": "Recreate",
                        "library": "Library", "take": "Take", "queue": "Queue", "settings": "Settings", "memory": "Claude's memory", "camera": "Camera"]

    /// "Edit, Beach reel (rev 14)": the panel's "Sees:" line (the server's `pageLine`).
    public var line: String {
        var s = Self.names[name] ?? name.capitalized
        if let t = tool, let f = t.first, name == "suite" { s += ", " + f.uppercased() + t.dropFirst() }
        if let l = label, !l.isEmpty { s += ", \(l)" }
        if let sub, !sub.isEmpty { s += " (\(sub))" }
        return s
    }

    /// The line in front of a message typed on the Mac (Claude Code reads the page from it; titles leave it out).
    public var contextLine: String {
        let open = (ids ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "[Page: \(line)\(open.isEmpty ? "" : " · open: \(open)")\(busy == true ? " · busy: ask before opening another page" : "")]"
    }

    /// The message as typed, without the page line in front.
    public static func stripContext(_ text: String) -> String {
        guard text.hasPrefix("[Page: "), let end = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: end)...])
    }
}

/// One chat in the list (GET /v1/claude/chats): old per-place chats included, each with the page it was last used on.
public struct ClaudeChatSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String?
    /// chat | suite | edit | recreate | camera (an old chat not opened in the one panel yet)
    public var kind: String
    public var page: ClaudePage?
    public var lastOn: String?
    public var updatedAt: Double
    public var messageCount: Int?
    /// Step 6b: the chat's own Claude model; nil = the person's default.
    public var model: String?

    public init(id: String, title: String? = nil, kind: String = "chat", page: ClaudePage? = nil, lastOn: String? = nil, updatedAt: Double = 0, messageCount: Int? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.page = page; self.lastOn = lastOn; self.updatedAt = updatedAt; self.messageCount = messageCount
    }

    public var shownTitle: String { (title?.isEmpty == false ? title : nil) ?? "New chat" }
}

public struct ClaudeChatList: Codable, Hashable, Sendable { public var chats: [ClaudeChatSummary] }

/// A line Claude left for the app (a `ui` live event, and stored on the chat's tool message): open a page, or
/// "Remembered … Undo".
public struct ClaudeUI: Codable, Hashable, Sendable {
    public var page: String?
    public var id: String?
    public var tool: String?
    public var label: String?
    /// Ask with an Open button instead of opening at once.
    public var ask: Bool?
    /// The page the person was on (for Back).
    public var from: ClaudePage?
    /// memory_add (the person asked): the rule saved and its words.
    public var remembered: String?
    public var text: String?
    /// memory_suggest: Claude asks "Shall I remember: …?" (Remember / No); nothing is saved until Remember.
    public var suggest: String?
    public var area: String?
    public var characterId: String?
    /// approve: a gated action Claude asked for (delete, post, spend, settings); nothing happens until the person presses
    /// the button (POST v1/claude/actions/:id). `label` is the button ("Delete", "Approve · $1.30").
    public var approve: String?
    public var gate: String?
    public var summary: String?
    public var priceUsd: Double?
    /// approve_result: the action it answers and how it ended (done, failed, declined).
    public var action: String?
    public var status: String?
    /// A card (claude/cards.ts): plan, clip, what changed, approve with price lines. Drawn instead of the plain line.
    public var card: ClaudeCardBox?

    public init(page: String? = nil, id: String? = nil, tool: String? = nil, label: String? = nil, ask: Bool? = nil, from: ClaudePage? = nil,
                remembered: String? = nil, text: String? = nil, suggest: String? = nil, area: String? = nil, characterId: String? = nil,
                approve: String? = nil, gate: String? = nil, summary: String? = nil, priceUsd: Double? = nil, action: String? = nil, status: String? = nil, card: ClaudeCardBox? = nil) {
        self.page = page; self.id = id; self.tool = tool; self.label = label; self.ask = ask; self.from = from
        self.remembered = remembered; self.text = text; self.suggest = suggest; self.area = area; self.characterId = characterId
        self.approve = approve; self.gate = gate; self.summary = summary; self.priceUsd = priceUsd; self.action = action; self.status = status
        self.card = card
    }

    /// Where it goes, as the person reads it ("AI Suite, Shot", "Take, Sunset walk 3").
    public var target: ClaudePage? { page.map { ClaudePage(name: $0, label: label, tool: tool) } }
}

/// One rule of the studio's memory (GET /v1/claude/memory).
public struct ClaudeMemoryRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var area: String
    public var pinned: Bool
    public var source: String
    public var characterId: String?
}

public struct ClaudeMemory: Codable, Hashable, Sendable {
    public var rules: [ClaudeMemoryRule]
    /// The person changes their own (always true for one's own memory).
    public var canEdit: Bool
}

/// Step 6b: a Claude model anyone can pick for a chat, with speed and cost in plain words (GET /v1/claude/models).
public struct ClaudeModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var speed: String
    public var cost: String
    public var good: String
}

public struct ClaudeModelList: Codable, Hashable, Sendable {
    public var models: [ClaudeModelInfo]
    /// This person's default (nil: the studio's).
    public var `default`: String?
    public var studioDefault: String?
}
