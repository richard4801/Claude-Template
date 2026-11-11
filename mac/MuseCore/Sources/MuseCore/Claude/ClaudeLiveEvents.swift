import Foundation

/// The `claude` live events (GET /v1/events, owners' devices), plus the stream opening and closing.
public enum ClaudeLiveEvent: Hashable, Sendable {
    case connected
    case disconnected
    case thread(ClaudeThread)
    /// A chat was deleted (on any device).
    case threadDeleted(threadId: String)
    case message(threadId: String, ClaudeMessage)
    /// Streaming text and tool progress of a turn (the Mac's own turns have no turnId).
    case event(threadId: String, turnId: String?, ClaudeEvent)
    /// A phone turn queued for the Mac.
    case turn(ClaudeTurn)
    case stop(turnId: String)
    case status(ClaudeStatus)
    /// One Claude: a line Claude left for the app (open a page, "Remembered … Undo").
    case ui(threadId: String, name: String, ClaudeUI)
}

/// SSE lines → `claude` live events; everything else on the stream is ignored.
public struct ClaudeLiveEventFilter: Sendable {
    private var parser = SSEParser()

    public init() {}

    public mutating func feed(_ line: String) -> ClaudeLiveEvent? {
        guard let payload = parser.feed(line) else { return nil }
        return Self.parse(Data(payload.utf8))
    }

    private struct Envelope: Decodable {
        var type: String
        var op: String?
        var threadId: String?
        var turnId: String?
        var thread: ClaudeThread?
        var message: ClaudeMessage?
        var turn: ClaudeTurn?
        var status: ClaudeStatus?
        var event: ClaudeEvent?
        var name: String?
        var ui: ClaudeUI?

        private enum K: String, CodingKey { case type, op, threadId, turnId, thread, message, turn, status, event, name, ui }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            type = try c.decode(String.self, forKey: .type)
            op = try? c.decodeIfPresent(String.self, forKey: .op)
            threadId = try? c.decodeIfPresent(String.self, forKey: .threadId)
            turnId = try? c.decodeIfPresent(String.self, forKey: .turnId)
            thread = try? c.decodeIfPresent(ClaudeThread.self, forKey: .thread)
            message = try? c.decodeIfPresent(ClaudeMessage.self, forKey: .message)
            turn = try? c.decodeIfPresent(ClaudeTurn.self, forKey: .turn)
            status = try? c.decodeIfPresent(ClaudeStatus.self, forKey: .status)
            event = try? c.decodeIfPresent(ClaudeEvent.self, forKey: .event)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            ui = try? c.decodeIfPresent(ClaudeUI.self, forKey: .ui)
        }
    }

    /// One event's JSON, e.g. `{type: "claude", op: "turn", turn}`. Unknown ops and malformed bodies are nil.
    public static func parse(_ json: Data) -> ClaudeLiveEvent? {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: json), e.type == "claude" else { return nil }
        switch e.op {
        case "thread": return e.thread.map { .thread($0) }
        case "threadDeleted": return e.threadId.map { .threadDeleted(threadId: $0) }
        case "message":
            guard let m = e.message else { return nil }
            return .message(threadId: e.threadId ?? m.threadId, m)
        case "event":
            guard let ev = e.event, let tid = e.threadId else { return nil }
            return .event(threadId: tid, turnId: e.turnId, ev)
        case "turn": return e.turn.map { .turn($0) }
        case "stop": return (e.turnId ?? e.turn?.id).map { .stop(turnId: $0) }
        case "status": return e.status.map { .status($0) }
        case "ui":
            guard let tid = e.threadId, let name = e.name, let ui = e.ui else { return nil }
            return .ui(threadId: tid, name: name, ui)
        default: return nil
        }
    }
}
