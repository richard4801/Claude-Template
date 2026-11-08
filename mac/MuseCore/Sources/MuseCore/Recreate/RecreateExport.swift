import Foundation

/// Export from Recreate (plans/recreate-edit.md step 7): the built edit with the reference's sound as a guide track, so it
/// can be checked against the beat and posted with the platform's "Use this sound"; or silent, timed for the sound. The
/// Mac mixes it locally (the reference's audio from its authenticated video); nothing is rendered on the server.
public enum RecreateExport {
    public enum Sound: String, CaseIterable, Hashable, Sendable {
        /// The reference's sound under the edit, in place of the takes' own sound.
        case guide
        /// No sound at all: the edit is timed for the sound you attach when posting.
        case silent

        public var label: String {
            switch self {
            case .guide: return "With the sound as a guide"
            case .silent: return "Silent"
            }
        }

        public var hint: String {
            switch self {
            case .guide: return "The reference’s sound plays under your edit, so you can check the cuts land on the beat."
            case .silent: return "No sound. The cuts are timed for the reference’s sound."
            }
        }
    }

    /// The reminder under the choice and after the export (the server's own words when it sends some).
    public static func reminder(_ reference: RecreateReference?) -> String {
        if let s = reference?.soundReminder?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        return "Post with TikTok’s “Use this sound” so the real sound plays."
    }

    /// The guide track is the reference's audio from 0 for the edit's length (the cuts land on the reference's times).
    /// nil when there is nothing to lay under it.
    public static func guideRange(editSec: Double, referenceSec: Double) -> (start: Double, duration: Double)? {
        guard editSec.isFinite, referenceSec.isFinite, editSec > 0, referenceSec > 0 else { return nil }
        return (0, min(editSec, referenceSec))
    }

    /// "Summer cut · recreated.mp4" → a file name without characters Finder refuses.
    public static func fileName(_ name: String?, sound: Sound) -> String {
        let base = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Recreated edit"
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) recreated\(sound == .silent ? " silent" : "").mp4"
    }
}
