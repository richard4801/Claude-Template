import Foundation

// Paid helpers Claude asked for, across ALL of the owner's open edit sessions (owner issue ci_e546642a4026, 2026-11-12:
// an Approve card for a helper on another edit never showed while the Edit page had a different session open). The
// Claude panel lists them whichever edit is open, each naming its edit, and answers them by session id
// (POST /v1/edit-sessions/{id}/pending/{pid}) without switching edits.

/// One paid helper waiting for the owner's yes, and the edit it belongs to.
public struct EditApproval: Identifiable, Hashable, Sendable {
    public var sessionId: String
    public var takeId: String
    public var pending: EditPending
    public var id: String { "\(sessionId)/\(pending.id)" }
    public init(sessionId: String, takeId: String, pending: EditPending) {
        self.sessionId = sessionId; self.takeId = takeId; self.pending = pending
    }

    /// "Allow · $0.40": the price on the action.
    public var allowLabel: String { "Allow · $" + String(format: "%.2f", pending.estimateUsd) }
}

/// The waiting ones, oldest first (the order Claude asked).
public struct EditApprovalList: Hashable, Sendable {
    public private(set) var items: [EditApproval] = []
    public init() {}

    /// Everything waiting in these sessions (GET /v1/edit-sessions: open sessions with their pending helpers).
    public mutating func replace(sessions: [EditSession]) {
        items = sessions.flatMap { s in s.pending.filter(\.isWaiting).map { EditApproval(sessionId: s.id, takeId: s.takeId, pending: $0) } }
        sort()
    }

    /// A live `pending` event of a session: waiting → listed (or updated), anything else → gone. `takeId` names the edit
    /// when the session isn't listed yet (nil: keep what is known, else unnamed until the next reload).
    public mutating func apply(sessionId: String, takeId: String?, _ p: EditPending) {
        let key = "\(sessionId)/\(p.id)"
        guard p.isWaiting else { items.removeAll { $0.id == key }; return }
        if let i = items.firstIndex(where: { $0.id == key }) {
            items[i].pending = p
        } else {
            let tid = takeId ?? items.first { $0.sessionId == sessionId }?.takeId ?? ""
            items.append(EditApproval(sessionId: sessionId, takeId: tid, pending: p))
            sort()
        }
    }

    /// Answered here (or elsewhere): off the list.
    public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    private mutating func sort() { items.sort { ($0.pending.createdAt, $0.id) < ($1.pending.createdAt, $1.id) } }

    /// The edit's name as the card says it: the take's title, "New project" for a blank one, "an edit" when unknown.
    public static func editName(takeId: String, title: String?) -> String {
        if takeId == EditV2.blankSourceId { return "New project" }
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return "an edit"
    }
}
