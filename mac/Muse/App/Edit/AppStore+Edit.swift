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
    func makeEditSuiteSession(takeId: String, attachSessionId: String? = nil) -> EditSuiteSession? {
        // "New blank project" (owner request 2026-11-11): no source take; a stand-in take named "blank" until the first save.
        let blank = Take(id: EditV2.blankSourceId, kind: "edit", title: "New project", label: "Blank", thumb: ImageRef())
        guard let t = takeId == EditV2.blankSourceId ? blank : takes.first(where: { $0.id == takeId }), t.isVideo, t.videoUrl != nil || takeId == EditV2.blankSourceId else { return nil }
        // The owner's edit is shared live with Claude (edit sessions); members keep the local editor.
        let s = EditSuiteSession(take: t, api: api, isOwner: isOwner) { [weak self] id in self?.takes.first { $0.id == id } }
        s.onVersionSaved = { [weak self] t in self?.editSuiteSaved(t) }
        s.attachSessionId = attachSessionId
        return s
    }

    /// One Claude: opens the editor on an edit session Claude opened (a blank project included), not just the Edit page.
    func openEditSession(_ sessionId: String) async {
        do {
            let s = try await api.editSession(id: sessionId)
            suite.editAttach = .init(takeId: s.takeId, sessionId: s.id)
            go(.edit)
        } catch {
            showToast("Couldn't open that edit. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    /// A version the suite saved: into the gallery, marked new.
    func editSuiteSaved(_ t: Take) {
        if let i = takes.firstIndex(where: { $0.id == t.id }) { takes[i] = t } else { takes.insert(t, at: 0) }
        fresh.insert(t.id)
        showToast(t.parentTakeId == nil ? "Saved to the Library as a new video" : "Saved as a new version · the original is kept")
    }

    /// Opens a saved version in the gallery's result view.
    func showEditedVersion(_ id: String) {
        openTakeId = id
        go(.result)
    }
}
