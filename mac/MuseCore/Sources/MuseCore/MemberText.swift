import Foundation

/// Member-facing wording (plans/app-cleanup.md, plans/api.md "App clean-up"): members see results, time and price. No GPUs,
/// warm-ups, steps, start-up or provider names; those appear only in the owner's Settings → Engines.
public enum MemberText {
    public static let wentWrong = "Something went wrong · you weren't charged"
    public static let ownerTold = "Something went wrong · you weren't charged. The studio owner has been told."
    public static let waitingToStart = "Waiting to start"

    /// Words members never see. Server text that contains one (an older server's "The GPU disconnected at step 3.",
    /// "Rendering on Replicate") is replaced by the contract's wording.
    static let technical = try! NSRegularExpression(
        pattern: #"\bgpus?\b|warm[- ]?up|\bwarm\b|runpod|replicate|\bh(100|200|3)\b|\blite\b|seedvr|\bsteps?\b|start-?up|\bpods?\b|latentsync|viggle|minimax|flux|qwen|safety filter"#,
        options: [.caseInsensitive])

    /// True when `text` has none of the technical words.
    public static func isSafe(_ text: String) -> Bool {
        technical.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
    }

    /// `text` when it's member-safe, else `fallback`.
    public static func safe(_ text: String?, or fallback: String) -> String {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, isSafe(t) else { return fallback }
        return t
    }
}
