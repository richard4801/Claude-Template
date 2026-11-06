import Foundation

// Edit sessions (workstream 3): this device's edits not on the server yet, kept per take so they are never dropped silently.
// When the editor opens the take's session again and the draft differs from the latest revision, the owner chooses
// "Keep this device's changes" (pushed as one change on top of the latest) or "Use the latest" (the draft is discarded).

public struct EditSessionDraft: Codable, Hashable, Sendable {
    public var takeId: String
    public var sessionId: String
    /// The session revision the draft was made on.
    public var baseRevision: Int
    public var project: EditV2.Project
    /// The session's project the draft was made on (so Keep re-applies only this device's changes on top of the latest).
    public var base: EditV2.Project?
    public var label: String?
    /// Seconds since 1970.
    public var savedAt: Double

    public init(takeId: String, sessionId: String, baseRevision: Int, project: EditV2.Project, base: EditV2.Project? = nil, label: String? = nil,
                savedAt: Double = 0) {
        self.takeId = takeId; self.sessionId = sessionId; self.baseRevision = baseRevision; self.project = project; self.base = base; self.label = label
        self.savedAt = savedAt
    }
}

/// Drafts on disk, one JSON file per take in `directory`.
public struct EditSessionDrafts: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// ~/Library/Application Support/MUSE/EditDrafts
    public static var standard: EditSessionDrafts {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return EditSessionDrafts(directory: base.appendingPathComponent("MUSE/EditDrafts", isDirectory: true))
    }

    func file(_ takeId: String) -> URL {
        let safe = takeId.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("draft-\(safe).json")
    }

    public func load(takeId: String) -> EditSessionDraft? {
        guard let data = try? Data(contentsOf: file(takeId)) else { return nil }
        return try? JSONDecoder().decode(EditSessionDraft.self, from: data)
    }

    /// Saves the draft (nil removes the take's draft).
    public func save(_ d: EditSessionDraft?, takeId: String) {
        guard let d else { remove(takeId: takeId); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: file(takeId), options: .atomic) }
    }

    public func remove(takeId: String) { try? FileManager.default.removeItem(at: file(takeId)) }
}
