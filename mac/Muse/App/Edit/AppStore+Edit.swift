import AppKit
import MuseCore

// Edit suite (workstream 3): what the suite needs from the app store. Navigation (the sidebar's Edit entry) belongs to the
// video suite workstream; the suite itself is `EditSuiteView(takeId:)`.
extension AppStore {
    /// Video takes the suite can open, newest first (renders and edited versions).
    var editSuiteTakes: [Take] {
        takes.filter { $0.isVideo && $0.videoUrl != nil }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A new suite session for a take (nil for a photo or a take without video).
    func makeEditSuiteSession(takeId: String) -> EditSuiteSession? {
        guard let t = takes.first(where: { $0.id == takeId }), t.isVideo, t.videoUrl != nil else { return nil }
        return EditSuiteSession(take: t, api: api) { [weak self] id in self?.takes.first { $0.id == id } }
    }

    /// A version the suite saved: into the gallery, marked new.
    func editSuiteSaved(_ t: Take) {
        if let i = takes.firstIndex(where: { $0.id == t.id }) { takes[i] = t } else { takes.insert(t, at: 0) }
        fresh.insert(t.id)
        showToast("Saved as a new version · the original is kept")
    }

    /// Opens a saved version in the gallery's result view.
    func showEditedVersion(_ id: String) {
        openTakeId = id
        go(.result)
    }
}
