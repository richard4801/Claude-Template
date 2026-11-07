import Foundation

// The cinematic Suite's Reuse settings (plans/api.md, "The new Suite's server pieces"): the composer's draft goes with each
// Shot and Photo request as `draft` and comes back on the job and every take; restoring puts the prompt (with its chip
// keys), the rig and the bar's values back exactly. Slots are not restored (their uploads may be gone).
public enum ComposerDrafts {
    /// The prompt's parts as JSON: {t:"text",text} · {t:"move",id,label,category,intensity,key} · {t:"mention",kind,id,label,key}.
    public static func encode(_ tokens: PromptTokens) -> [JSONValue] {
        tokens.parts.map { p in
            switch p {
            case .text(let s): return .object(["t": .string("text"), "text": .string(s)])
            case .move(let id, let label, let category, let intensity, let key):
                return .object(["t": .string("move"), "id": .string(id), "label": .string(label), "category": .string(category),
                                "intensity": .number(Double(intensity)), "key": .number(Double(key))])
            case .mention(let kind, let id, let label, let key):
                return .object(["t": .string("mention"), "kind": .string(kind), "id": .string(id), "label": .string(label), "key": .number(Double(key))])
            }
        }
    }

    public static func decode(_ values: [JSONValue]) -> PromptTokens {
        func str(_ o: [String: JSONValue], _ k: String) -> String? { if case .string(let s)? = o[k] { return s } else { return nil } }
        func int(_ o: [String: JSONValue], _ k: String) -> Int? { if case .number(let n)? = o[k] { return Int(n) } else { return nil } }
        let parts: [PromptPart] = values.compactMap { v in
            guard case .object(let o) = v, let t = str(o, "t") else { return nil }
            switch t {
            case "text": return str(o, "text").map(PromptPart.text)
            case "move":
                guard let id = str(o, "id"), let key = int(o, "key") else { return nil }
                return .move(id: id, label: str(o, "label") ?? id, category: str(o, "category") ?? "", intensity: int(o, "intensity") ?? 50, key: key)
            case "mention":
                guard let kind = str(o, "kind"), let id = str(o, "id"), let key = int(o, "key") else { return nil }
                return .mention(kind: kind, id: id, label: str(o, "label") ?? id, key: key)
            default: return nil
            }
        }
        return PromptTokens(parts)
    }

    /// The draft sent with a request.
    public static func draft(_ d: ComposerDraft, photo: PhotoDraft? = nil) -> SuiteDraft {
        var extra: [String: JSONValue] = [:]
        if let o = d.outfitId { extra["outfitId"] = .string(o) }
        if let p = photo?.presetId { extra["presetId"] = .string(p) }
        if d.tool == .photo {
            return SuiteDraft(tool: "photo", count: photo?.count, rig: SuiteRig(d.settings), tokens: encode(d.tokens), extra: extra)
        }
        return SuiteDraft(tool: d.tool.rawValue, quality: d.quality, aspect: d.aspect, duration: Double(d.duration), takes: d.takes, sound: d.sound,
                          speaking: d.speaking.value, rig: SuiteRig(d.settings), tokens: encode(d.tokens), extra: extra)
    }

    /// The composer as the draft left it. Unknown or missing fields keep the current values.
    public static func restore(_ s: SuiteDraft, into d: ComposerDraft) -> ComposerDraft {
        var out = d
        if let t = ComposerTool(rawValue: s.tool) { out.tool = t }
        if let q = s.quality { out.quality = q }
        if let a = s.aspect { out.aspect = a }
        if let du = s.duration { out.duration = Int(du.rounded()) }
        if let tk = s.takes { out.takes = tk }
        if let so = s.sound { out.sound = so }
        out.speaking = s.speaking.map { $0 ? .on : .off } ?? .auto
        if let r = s.rig { out.settings = r.settings }
        if let toks = s.tokens { out.tokens = decode(toks) }
        if case .string(let o)? = s.extra["outfitId"] { out.outfitId = o }
        out.collapsed = nil
        out.directed = nil
        return out
    }
}

public extension ComposerDrafts {
    /// The characters @-mentioned in the prompt, in order (a model's default rig applies only when there is exactly one).
    static func characterIds(_ t: PromptTokens) -> [String] {
        t.parts.compactMap { p in p.mentionInfo.flatMap { $0.kind == "character" ? $0.id : nil } }
    }
    /// The prompt's #moves as a saved rig's moves (intensity 0–1).
    static func rigMoves(_ t: PromptTokens) -> [SuiteRigMove]? {
        let m = t.parts.compactMap { $0.move }.map { SuiteRigMove(id: $0.id, intensity: $0.intensity) }
        return m.isEmpty ? nil : m
    }
}
