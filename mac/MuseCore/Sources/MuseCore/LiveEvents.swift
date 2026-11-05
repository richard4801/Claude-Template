import Foundation

/// Applies live events (GET /v1/events) to the app's lists, so a change made on another device (the phone, a member's
/// app) shows up here within a second or two. Pure list logic; the app keeps its toasts and notifications.
public enum LiveEvents {
    /// `take` events and a finished job's `takes`: new ones go first (newest at the top), changed ones replace theirs,
    /// `op: "delete"` removes one. Returns the ids that were new.
    @discardableResult
    public static func applyTakes(_ takes: inout [Take], _ e: ApiEvent) -> [String] {
        if e.type == "take", e.op == "delete", let id = e.id {
            takes.removeAll { $0.id == id }
            return []
        }
        var incoming = e.takes
        if e.type == "take", let t = e.take { incoming.append(t) }
        var added: [String] = []
        for t in incoming.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let i = takes.firstIndex(where: { $0.id == t.id }) { takes[i] = t } else { takes.insert(t, at: 0); added.append(t.id) }
        }
        return added
    }

    /// `job` events: upsert, or `op: "delete"` (removed on another device).
    public static func applyJobs(_ jobs: inout [Job], _ e: ApiEvent) {
        if e.type == "job", e.op == "delete", let id = e.id { jobs.removeAll { $0.id == id }; return }
        guard let j = e.job else { return }
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) }
    }

    /// `template` events: my view of it, or a delete (deleted, or made private by someone else).
    /// The event never carries the detail's recent stills, so the ones already loaded are kept.
    public static func applyTemplates(_ templates: inout [MuseTemplate], _ e: ApiEvent) {
        guard e.type == "template" else { return }
        if e.op == "delete", let id = e.id { templates.removeAll { $0.id == id }; return }
        guard var t = e.template else { return }
        if let i = templates.firstIndex(where: { $0.id == t.id }) {
            if t.recent == nil { t.recent = templates[i].recent }
            templates[i] = t
        } else {
            templates.insert(t, at: 0)
        }
    }

    /// `model` deletes: the model, her outfits, accounts and unsent posts go (the server deletes them too).
    public static func isModelDelete(_ e: ApiEvent) -> String? { e.type == "model" && e.op == "delete" ? e.id : nil }

    /// `outfit` events: upsert; a saved (`ready`) outfit joins its model's list.
    public static func applyOutfit(_ outfits: inout [Outfit], _ models: inout [MuseModel], _ o: Outfit) {
        if let i = outfits.firstIndex(where: { $0.id == o.id }) { outfits[i] = o } else { outfits.append(o) }
        if o.state == "ready", let m = models.firstIndex(where: { $0.id == o.modelId }), !models[m].outfitIds.contains(o.id) { models[m].outfitIds.append(o.id) }
    }

    /// `post` events: upsert or delete.
    public static func applyPosts(_ posts: inout [Post], _ e: ApiEvent) {
        if e.type == "post", e.op == "delete", let id = e.id { posts.removeAll { $0.id == id }; return }
        guard let p = e.post else { return }
        if let i = posts.firstIndex(where: { $0.id == p.id }) { posts[i] = p } else { posts.insert(p, at: 0) }
    }

    /// `account` events: connected (upsert by platform) or disconnected (`op: "delete"`).
    public static func applyAccounts(_ accounts: inout [String: [Account]], _ e: ApiEvent) {
        guard e.type == "account", let modelId = e.modelId ?? e.account?.modelId else { return }
        let platform = e.account?.platform.rawValue ?? e.platform
        var list = (accounts[modelId] ?? []).filter { $0.platform.rawValue != platform }
        if e.op != "delete", let a = e.account { list.append(a) }
        accounts[modelId] = list
    }

    /// `member` events (owners): a member's credit moved, their caps changed, or someone joined.
    public static func applyMembers(_ members: inout [Member], _ e: ApiEvent) {
        guard e.type == "member", let m = e.member else { return }
        if let i = members.firstIndex(where: { $0.id == m.id }) { members[i] = m } else { members.append(m) }
    }
}
