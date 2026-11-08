import Foundation

/// Claude on the Recreate screens (Release 1 gap 4): the chat runs on the edit session the reference is built into, with
/// MUSE's recreate tools (`analyze_reference`, `get_recipe`, `set_slot_briefs`, `match_slots`, `apply_recipe`, `fill_slot`).
/// Each message carries a short context line naming the reference and the session, so Claude calls the tools on the right
/// ones. `fill_slot` keeps its confirmation: Claude only asks; the owner's yes in the app starts (and pays for) a shot.
public enum RecreateClaude {
    public struct Suggestion: Hashable, Sendable, Identifiable {
        public var label: String
        public var prompt: String
        public var id: String { label }
        public init(label: String, prompt: String) { self.label = label; self.prompt = prompt }
    }

    /// The line in front of each message (kept short; shown in the chat as part of the message).
    public static func context(reference: RecreateReference?, sessionId: String?) -> String {
        var parts = ["Recreate"]
        if let r = reference {
            parts.append("reference \(r.id)")
            if let n = r.name, !n.isEmpty { parts.append("“\(n)”") }
        } else {
            parts.append("no reference open yet")
        }
        if let s = sessionId, !s.isEmpty { parts.append("edit session \(s)") }
        return "[" + parts.joined(separator: " · ") + "]"
    }

    /// The message sent: the context line, then what the owner typed or picked.
    public static func message(_ text: String, reference: RecreateReference?, sessionId: String?) -> String {
        "\(context(reference: reference, sessionId: sessionId))\n\(text)"
    }

    /// What the owner typed, without the context line (for showing a stored message).
    public static func stripContext(_ text: String) -> String {
        guard text.hasPrefix("[Recreate"), let nl = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: nl)...])
    }

    /// The chips over the composer: the shot on screen, the weakest one after Build, and a new video.
    public static func suggestions(selectedShot: Int?, weakestShot: Int?, hasRecipe: Bool) -> [Suggestion] {
        var out: [Suggestion] = []
        if hasRecipe {
            let n = (selectedShot ?? 1) + 1
            out.append(Suggestion(label: "Explain shot \(n)",
                                  prompt: "Explain shot \(n) of this reference: what happens, the camera, the speed, and how we'll make it. Use get_recipe."))
            if let w = weakestShot {
                out.append(Suggestion(label: "Fix shot \(w + 1)",
                                      prompt: "Shot \(w + 1) matches the reference least. Find a better take for it with match_slots and apply_recipe. If a new shot is needed, use fill_slot for its price first; I confirm before anything is spent."))
            } else {
                out.append(Suggestion(label: "Fix the weakest shot",
                                      prompt: "Which shot will match the reference least? Suggest a better take for it with match_slots, and apply it with apply_recipe. If a new shot is needed, use fill_slot for its price first; I confirm before anything is spent."))
            }
        }
        out.append(Suggestion(label: "Analyse a new video",
                              prompt: "I want to recreate another video. Tell me how to give it to you: paste its link here, or I drop the file on the Recreate page."))
        return out
    }
}
