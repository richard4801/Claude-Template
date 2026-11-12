import Foundation

/// One row of the chat: user bubbles, Claude's text (streaming while a turn runs), tool chips and grabbed frames.
public enum ClaudeChatItem: Hashable, Sendable, Identifiable {
    case user(id: String, text: String, source: String)
    case assistant(id: String, text: String, streaming: Bool)
    case tool(id: String, name: String, summary: String, status: ClaudeToolStatus)
    /// `url` is the server's link, or a `data:` URL while the turn is live.
    case image(id: String, url: String)
    /// A card Claude put up (claude/cards.ts): plan, clip, what changed, approve. `messageId` is the stored line (Undo).
    case card(id: String, messageId: String, ClaudeCard)

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _, _), .tool(let id, _, _, _), .image(let id, _), .card(let id, _, _): return id
        }
    }
}

/// The transcript of one thread from both sides: the server's stored messages, and the live events of the turn in flight
/// (from this Mac's own Claude Code, or `claude` `{op: "event"}` while another device's turn runs). A live row is dropped as
/// soon as the stored message that covers it arrives (tools by id; user/assistant text and images in order), so nothing
/// shows twice.
public struct ClaudeTranscript: Hashable, Sendable {
    public private(set) var messages: [ClaudeMessage] = []
    public private(set) var live: [ClaudeChatItem] = []
    /// A turn is streaming (its `done` hasn't come).
    public private(set) var streaming = false
    /// The last turn's `done`, when it failed.
    public private(set) var lastError: String?
    /// The model Claude Code answered with (owner only).
    public private(set) var model: String?
    private var counter = 0

    public init(messages: [ClaudeMessage] = []) { load(messages) }

    /// A full reload (GET …/threads/{id}). Live rows already stored go; a turn still running keeps the rest.
    public mutating func load(_ messages: [ClaudeMessage]) {
        self.messages = []
        for m in messages { upsertMessage(m) }
        if !streaming { live = [] }
    }

    /// A stored message (`{op: "message"}`, or a reply's message).
    public mutating func upsert(_ m: ClaudeMessage) { upsertMessage(m) }

    /// How many videos a stored message carries (they show as a "Video" chip, never loaded as a picture).
    public func videoCount(_ messageId: String) -> Int {
        messages.first { $0.id == messageId }?.attachments?.filter(\.isVideo).count ?? 0
    }

    /// The image links a stored message carries (attachments with a link), for the thumbnails in its bubble.
    public func attachmentURLs(_ messageId: String) -> [String] {
        messages.first { $0.id == messageId }?.attachments?.compactMap { $0.url } ?? []
    }

    private mutating func upsertMessage(_ m: ClaudeMessage) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i] = m
        } else {
            messages.append(m)
            messages.sort { $0.createdAt < $1.createdAt }
        }
        absorb(m)
    }

    /// Removes the first live row this message stands for.
    private mutating func absorb(_ m: ClaudeMessage) {
        let idx: Int?
        if let t = m.tool {
            idx = live.firstIndex { if case .tool(let id, _, _, _) = $0 { return id == t.id }; return false }
        } else if m.image != nil {
            idx = live.firstIndex { if case .image = $0 { return true }; return false }
        } else if m.role == "user" {
            // Matched on the words typed (WS18): the app's context line in front must not make the same message show twice.
            let typed = ClaudeSessions.typedText(m.text)
            idx = live.firstIndex { if case .user(_, let text, _) = $0 { return ClaudeSessions.typedText(text) == typed }; return false }
        } else if m.role == "assistant" {
            idx = live.firstIndex { if case .assistant(_, let text, let s) = $0 { return !s && text == m.text }; return false }
        } else {
            idx = nil
        }
        if let idx { live.remove(at: idx) }
    }

    private mutating func nextId(_ p: String) -> String {
        counter += 1
        return "live_\(p)_\(counter)"
    }

    /// The user's text, shown at once (before the server has it).
    public mutating func begin(userText: String, source: String) {
        streaming = true
        lastError = nil
        let t = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = ClaudeSessions.typedText(t)
        guard !live.contains(where: { if case .user(_, let x, _) = $0 { return ClaudeSessions.typedText(x) == typed }; return false }) else { return }
        if !t.isEmpty, !messages.contains(where: { $0.role == "user" && ClaudeSessions.typedText($0.text) == typed && $0.createdAt > 0 && isRecent($0) }) {
            live.append(.user(id: nextId("user"), text: t, source: source))
        }
    }

    /// Only the last stored message counts as "already here" (the phone's own message arrives before its turn runs).
    private func isRecent(_ m: ClaudeMessage) -> Bool { messages.last(where: { $0.role == "user" })?.id == m.id }

    /// One live event of the turn in flight.
    public mutating func apply(_ e: ClaudeEvent) {
        switch e {
        case .user(let text, _):
            // The runner's echo of a message typed here (with or without the context line) is the bubble already shown.
            let typed = ClaudeSessions.typedText(text)
            if live.contains(where: { if case .user(_, let t, _) = $0 { return ClaudeSessions.typedText(t) == typed }; return false }) { streaming = true } else {
                begin(userText: text, source: "mac")
            }
        case .text(let d):
            streaming = true
            if case .assistant(let id, let text, true)? = live.last {
                live[live.count - 1] = .assistant(id: id, text: text + d, streaming: true)
            } else {
                live.append(.assistant(id: nextId("text"), text: d, streaming: true))
            }
        case .assistant(let text):
            streaming = true
            if case .assistant(let id, _, true)? = live.last {
                live[live.count - 1] = .assistant(id: id, text: text, streaming: false)
            } else if !messages.contains(where: { $0.role == "assistant" && $0.text == text && isLastAssistant($0) }) {
                live.append(.assistant(id: nextId("text"), text: text, streaming: false))
            }
        case .tool(let id, let name, let status, let summary, let input):
            streaming = true
            let text = summary ?? ClaudeChipText.summary(tool: name, input: input, isError: status == .error)
            if let i = live.firstIndex(where: { if case .tool(let tid, _, _, _) = $0 { return tid == id }; return false }) {
                live[i] = .tool(id: id, name: name, summary: text, status: status)
            } else {
                // A text block before a tool is finished even without its `assistant` line.
                if case .assistant(let aid, let t, true)? = live.last { live[live.count - 1] = .assistant(id: aid, text: t, streaming: false) }
                live.append(.tool(id: id, name: name, summary: text, status: status))
            }
        case .image(let data, let mime):
            streaming = true
            live.append(.image(id: nextId("image"), url: "data:\(mime);base64,\(data)"))
        case .done(let ok, let error, let model):
            streaming = false
            lastError = ok ? nil : error
            if let model { self.model = model }
            // Text still marked streaming (a stop mid-sentence) is kept as it is.
            live = live.map { if case .assistant(let id, let t, true) = $0 { return .assistant(id: id, text: t, streaming: false) }; return $0 }
        }
    }

    private func isLastAssistant(_ m: ClaudeMessage) -> Bool { messages.last(where: { $0.role == "assistant" })?.id == m.id }

    /// Stored messages first (oldest first; one chip per tool id, the latest state), then the live rows.
    public var items: [ClaudeChatItem] {
        var out: [ClaudeChatItem] = []
        var toolAt: [String: Int] = [:]
        for m in messages {
            // A card line (a newer server): drawn as its card; an unknown card falls back to the tool chip.
            if let t = m.tool, let box = t.ui?.card, box.card.kind != "", !{ if case .unknown = box.card { return true }; return false }() {
                let item = ClaudeChatItem.card(id: t.id, messageId: m.id, box.card)
                if let i = toolAt[t.id] { out[i] = item } else {
                    toolAt[t.id] = out.count
                    out.append(item)
                }
                continue
            }
            if let t = m.tool {
                let status: ClaudeToolStatus = t.ok == false ? .error : t.ok == true ? .done : .running
                let item = ClaudeChatItem.tool(id: t.id, name: t.name, summary: t.summary ?? ClaudeChipText.words(t.name), status: status)
                if let i = toolAt[t.id] { out[i] = item } else {
                    toolAt[t.id] = out.count
                    out.append(item)
                }
            } else if let img = m.image {
                out.append(.image(id: m.id, url: img.url))
            } else if m.role == "user" {
                out.append(.user(id: m.id, text: m.text, source: m.source))
            } else if !m.text.isEmpty {
                out.append(.assistant(id: m.id, text: m.text, streaming: false))
            }
        }
        for item in live {
            // A stored chip still running takes the live state of the same tool.
            if case .tool(let id, _, _, _) = item, let i = toolAt[id] {
                if case .tool(_, _, _, .running) = out[i] { out[i] = item }
                continue
            }
            out.append(item)
        }
        return out
    }
}
