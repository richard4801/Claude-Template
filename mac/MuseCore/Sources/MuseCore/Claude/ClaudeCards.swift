import Foundation

// Claude panel cards (owner's chosen chat reference, 2026-11-12; server/api/src/claude/cards.ts). Claude's replies can
// carry structured parts the panel draws as cards instead of plain bubbles: a plan that ticks, a clip with its key
// moments, "What I changed" with Undo per row, and an Approve card with price lines and a Total. Each arrives as a tool
// line (tool.name "card" or "approve", tool.ui.card) in the chat, and live as op "message" / "card" / "ui". Plain text
// stays plain. This file is the pure part: decoding (lenient: an unknown card is skipped, never an error), and the
// words and numbers the views show.

public struct ClaudePlanStep: Codable, Hashable, Sendable {
    public var text: String
    public var done: Bool
    public init(text: String, done: Bool = false) { self.text = text; self.done = done }
    private enum K: String, CodingKey { case text, done }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        text = try c.decode(String.self, forKey: .text)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
    }
}

public struct ClaudeMoment: Codable, Hashable, Sendable {
    /// Seconds from the video's start.
    public var from: Double
    public var to: Double?
    public var label: String
    public init(from: Double, to: Double? = nil, label: String) { self.from = from; self.to = to; self.label = label }
    /// "0:04–0:10", or "0:04" for one moment.
    public var timecode: String { to.map { "\(ClaudeCardText.clock(from))–\(ClaudeCardText.clock($0))" } ?? ClaudeCardText.clock(from) }
}

public struct ClaudeCardVideo: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    /// "/uploads/<key>": resolve against the server like other studio media.
    public var url: String
    public var title: String?
}

public struct ClaudeChangeRow: Codable, Hashable, Sendable {
    public var what: String
    public var to: String
    public var undoable: Bool
    public var undone: Bool
    public init(what: String, to: String, undoable: Bool = true, undone: Bool = false) { self.what = what; self.to = to; self.undoable = undoable; self.undone = undone }
    private enum K: String, CodingKey { case what, to, undoable, undone }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        what = try c.decode(String.self, forKey: .what)
        to = try c.decode(String.self, forKey: .to)
        undoable = (try? c.decodeIfPresent(Bool.self, forKey: .undoable)) ?? false
        undone = (try? c.decodeIfPresent(Bool.self, forKey: .undone)) ?? false
    }
}

public struct ClaudePriceLine: Codable, Hashable, Sendable {
    public var label: String
    public var usd: Double
    public init(label: String, usd: Double) { self.label = label; self.usd = usd }
}

/// Who answers an Approve card: a gated action (POST v1/claude/actions/:id) or the Suite composer's waiting shot
/// (POST v1/suite/assist/:id/pending/:pid).
public enum ClaudeApproveTarget: Hashable, Sendable {
    case action(String)
    case suite(assistId: String, pendingId: String)
}

public enum ClaudeCard: Hashable, Sendable, Decodable {
    case plan(planId: String, title: String, steps: [ClaudePlanStep])
    case media(title: String, summary: String?, video: ClaudeCardVideo, durationSec: Double?, moments: [ClaudeMoment])
    case changes(title: String, rows: [ClaudeChangeRow])
    case approve(title: String, subtitle: String?, lines: [ClaudePriceLine], totalUsd: Double?, target: ClaudeApproveTarget, approveLabel: String, declineLabel: String)
    /// A card this app doesn't know yet (a newer server): shown as its tool line's summary.
    case unknown(kind: String)

    private enum K: String, CodingKey { case kind, planId, title, steps, summary, video, durationSec, moments, rows, subtitle, lines, totalUsd, answer, approveLabel, declineLabel }
    private struct Answer: Decodable { var actionId: String?; var assistId: String?; var pendingId: String? }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        let title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        switch kind {
        case "plan":
            guard let steps = try? c.decode([ClaudePlanStep].self, forKey: .steps) else { self = .unknown(kind: kind); return }
            self = .plan(planId: (try? c.decodeIfPresent(String.self, forKey: .planId)) ?? "plan", title: title.isEmpty ? "Plan" : title, steps: steps)
        case "media":
            guard let v = try? c.decode(ClaudeCardVideo.self, forKey: .video) else { self = .unknown(kind: kind); return }
            self = .media(title: title.isEmpty ? "Clip analysis" : title, summary: try? c.decodeIfPresent(String.self, forKey: .summary), video: v,
                          durationSec: try? c.decodeIfPresent(Double.self, forKey: .durationSec), moments: (try? c.decode([ClaudeMoment].self, forKey: .moments)) ?? [])
        case "changes":
            self = .changes(title: title.isEmpty ? "What I changed" : title, rows: (try? c.decode([ClaudeChangeRow].self, forKey: .rows)) ?? [])
        case "approve":
            guard let a = try? c.decode(Answer.self, forKey: .answer) else { self = .unknown(kind: kind); return }
            let target: ClaudeApproveTarget
            if let id = a.actionId { target = .action(id) } else if let s = a.assistId, let p = a.pendingId { target = .suite(assistId: s, pendingId: p) } else { self = .unknown(kind: kind); return }
            self = .approve(title: title, subtitle: try? c.decodeIfPresent(String.self, forKey: .subtitle), lines: (try? c.decode([ClaudePriceLine].self, forKey: .lines)) ?? [],
                            totalUsd: try? c.decodeIfPresent(Double.self, forKey: .totalUsd), target: target,
                            approveLabel: (try? c.decodeIfPresent(String.self, forKey: .approveLabel)) ?? "Approve",
                            declineLabel: (try? c.decodeIfPresent(String.self, forKey: .declineLabel)) ?? "Decline")
        default: self = .unknown(kind: kind)
        }
    }

    public var kind: String {
        switch self { case .plan: "plan"; case .media: "media"; case .changes: "changes"; case .approve: "approve"; case .unknown(let k): k }
    }
    /// The plan's steps done and in all ("2 of 3").
    public var progress: (done: Int, of: Int)? {
        guard case .plan(_, _, let steps) = self else { return nil }
        return (steps.filter(\.done).count, steps.count)
    }
}

/// The card stored on a tool line (encoded back as the raw JSON the server sent, so ClaudeUI stays Codable).
public struct ClaudeCardBox: Codable, Hashable, Sendable {
    public var card: ClaudeCard
    public var raw: JSONValue
    public init(from d: Decoder) throws {
        raw = try JSONValue(from: d)
        card = (try? JSONDecoder().decode(ClaudeCard.self, from: JSONEncoder().encode(raw))) ?? .unknown(kind: "")
    }
    public func encode(to e: Encoder) throws { try raw.encode(to: e) }
    public static func == (a: Self, b: Self) -> Bool { a.raw == b.raw }
    public func hash(into h: inout Hasher) { h.combine(raw) }
}

public enum ClaudeCardText {
    /// "0:04", "1:02:05".
    public static func clock(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    /// "$1.17".
    public static func money(_ v: Double) -> String { String(format: "$%.2f", v) }
    /// The Total under the lines: the card's own, else the lines added up.
    public static func total(_ lines: [ClaudePriceLine], _ total: Double?) -> Double {
        total ?? (lines.reduce(0) { $0 + $1.usd } * 100).rounded() / 100
    }
    /// The accessibility line for a change row ("Outfit changed to Hoodie").
    public static func change(_ r: ClaudeChangeRow) -> String { "\(r.what) changed to \(r.to)\(r.undone ? ", undone" : "")" }
}

/// The quick-action chips over the composer (GET v1/claude/chips; this copy when the server is older or offline).
public struct ClaudeChip: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var prompt: String
    /// Phosphor name ("play-circle", "pencil-simple", "coins").
    public var icon: String
    public var id: String { label }
    public init(label: String, prompt: String, icon: String) { self.label = label; self.prompt = prompt; self.icon = icon }

    public static func fallback(page: String?, tool: String?) -> [ClaudeChip] {
        let price = ClaudeChip(label: "Check the price", prompt: "What will this cost, line by line?", icon: "coins")
        let write = ClaudeChip(label: "Write the prompt", prompt: "Write the prompt for this shot.", icon: "pencil-simple")
        switch page {
        case "suite":
            if let t = tool, ["swap", "remix", "recast", "extend"].contains(t) { return [ClaudeChip(label: "Watch my clip", prompt: "Watch my clip and tell me the key moments.", icon: "play-circle"), write, price] }
            return [write, ClaudeChip(label: "Set the rig", prompt: "Set up the rig for this shot.", icon: "aperture"), price]
        case "edit": return [ClaudeChip(label: "Watch my edit", prompt: "Watch my edit and tell me what to fix.", icon: "play-circle"),
                             ClaudeChip(label: "Cut to the beat", prompt: "Cut this to the beat.", icon: "scissors"), ClaudeChip(label: "Add captions", prompt: "Add captions to this edit.", icon: "text-aa")]
        case "take": return [ClaudeChip(label: "Watch this take", prompt: "Watch this take and tell me what works.", icon: "play-circle"),
                             ClaudeChip(label: "Make a variation", prompt: "Set up a variation of this take.", icon: "pencil-simple"), ClaudeChip(label: "Edit it", prompt: "Open this take in Edit.", icon: "film-strip")]
        default: return [ClaudeChip(label: "What can you do", prompt: "What can you do on this page?", icon: "chat-circle"),
                         ClaudeChip(label: "Start a shot", prompt: "Help me start a new shot.", icon: "video-camera"), ClaudeChip(label: "Watch my clip", prompt: "Watch my latest clip.", icon: "play-circle")]
        }
    }
}

public struct ClaudeChipList: Codable, Hashable, Sendable { public var chips: [ClaudeChip] }

/// Undo on a "What I changed" row (POST v1/claude/cards/:id/undo {row}): the card as it is now.
public struct ClaudeCardUndo: Decodable, Hashable, Sendable { public var ok: Bool; public var card: ClaudeCardBox? }

/// The live activity strip while Claude operates the window or a job runs: "Opening Swap… setting outfit…", a
/// percentage and bar, and "Esc to stop". Steps come from uiCall events (`step`), progress from the job's own events.
public struct ClaudeActivity: Hashable, Sendable {
    public private(set) var steps: [String] = []
    /// 0…1 when a job reports it; nil while only the window is being operated.
    public var progress: Double?
    /// Calls in flight (uiCall without its uiCallEnd yet).
    public private(set) var open: Set<String> = []
    public init() {}

    public var isActive: Bool { !open.isEmpty || progress != nil }
    /// The last two steps, the second in lower case: "Opening Swap… setting outfit…".
    public var line: String {
        let last = steps.suffix(2)
        guard let first = last.first else { return progress != nil ? "Working…" : "" }
        if last.count == 1 { return first }
        let second = last.last!
        return "\(first) \(second.prefix(1).lowercased())\(second.dropFirst())"
    }
    /// "42%".
    public var percent: String? { progress.map { "\(Int((min(1, max(0, $0)) * 100).rounded()))%" } }

    public mutating func began(_ call: UiCall) {
        open.insert(call.id)
        let s = (call.step?.isEmpty == false ? call.step! : "Working in the window…")
        if steps.last != s { steps.append(s) }
        if steps.count > 6 { steps.removeFirst(steps.count - 6) }
    }
    public mutating func ended(_ id: String) {
        open.remove(id)
        if open.isEmpty && progress == nil { steps.removeAll() }
    }
    /// A job's progress (0…1), or nil when it finished.
    public mutating func job(_ p: Double?) {
        progress = p
        if p == nil && open.isEmpty { steps.removeAll() }
    }
    public mutating func stop() { open.removeAll(); steps.removeAll(); progress = nil }
}
