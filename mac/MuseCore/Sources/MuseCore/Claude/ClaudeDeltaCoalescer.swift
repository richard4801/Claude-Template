import Foundation

/// Performance (build 704 "it lags"): Claude streams a `text` delta per token, and every one used to change the chat's
/// transcript (re-rendering the chat and re-parsing the streaming reply) and pulse the orb. The chat now joins the deltas
/// that arrive close together into one, applied at most every `window` seconds. Order is kept: any other event first lets
/// the waiting text out, then itself, so a tool card or `done` never lands before the words that came before it.
public struct ClaudeDeltaCoalescer: Sendable {
    public static let window: Double = 0.08

    public private(set) var pending = ""

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// The events to apply now, in order. A text delta is held (empty result) until `flush()` or the next other event.
    public mutating func add(_ e: ClaudeEvent) -> [ClaudeEvent] {
        if case .text(let d) = e {
            pending += d
            return []
        }
        var out: [ClaudeEvent] = []
        if let t = flush() { out.append(t) }
        out.append(e)
        return out
    }

    /// The held text as one delta (nil when nothing waits).
    public mutating func flush() -> ClaudeEvent? {
        guard !pending.isEmpty else { return nil }
        defer { pending = "" }
        return .text(delta: pending)
    }

    /// A new chat opened: whatever waited belonged to the old one.
    public mutating func reset() { pending = "" }
}
