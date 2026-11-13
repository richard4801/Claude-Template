import Foundation
import MuseCore

// Continue a draft (owner, 2026-11-12): "When you click on Edit, you should see the last draft you were editing." The owner's
// recent edits come from the server (so they match across devices), a member's from this Mac (their editor is local).
extension AppStore {
    /// Recent edits, the last worked on first; also kept in `suite.recentEdits` for the Edit home.
    @discardableResult
    func loadRecentEdits() async -> [EditRecentItem] {
        // Run 610: an older load finishing after a newer one put a stale list (and a stale Continue draft) on the home. Only
        // the latest load started may show its list.
        suite.recentEditsGeneration &+= 1
        let generation = suite.recentEditsGeneration
        var sessions: [EditSession] = []
        if isOwner { sessions = (try? await api.recentEditSessions(limit: 20)) ?? [] }
        let items = EditRecent.items(sessions: sessions, local: EditRecentStore.standard.load()) { [weak self] id in
            guard let t = self?.takes.first(where: { $0.id == id }) else { return nil }
            return t.title.isEmpty ? nil : t.displayTitle
        }
        if suite.recentEditsGeneration == generation { suite.recentEdits = items }
        return items
    }

    /// An editor on a recent edit, as it was left. Its take may be gone: the edit opens on a stand-in and its missing clips
    /// are marked. Nil (with a toast) when the server's session can't be read.
    func makeEditSuiteSession(resuming item: EditRecentItem) async -> EditSuiteSession? {
        let resume: EditResume
        if let sid = item.sessionId {
            do {
                var s = try await api.editSession(id: sid)
                // This Mac's own newer record of where it was left wins over the server's (it may not have arrived yet).
                if let v = item.view, (v.at ?? 0) >= (s.view?.at ?? 0) || s.view == nil { s.view = v }
                resume = .session(s)
            } catch {
                showToast("Couldn't open that edit. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
                return nil
            }
        } else {
            let key = item.id.hasPrefix("local:") ? String(item.id.dropFirst(6)) : item.id
            guard let d = EditRecentStore.standard.load().first(where: { $0.key == key }), d.project != nil else {
                showToast("That edit isn't on this Mac any more")
                return nil
            }
            resume = .local(d)
        }
        let take = takes.first { $0.id == item.takeId }
            ?? Take(id: item.takeId, kind: "edit", title: item.isBlank ? (item.title == EditRecent.untitled ? "New project" : item.title) : item.title,
                    label: item.isBlank ? "Blank" : "Missing", thumb: ImageRef())
        let s = EditSuiteSession(take: take, api: api, isOwner: isOwner) { [weak self] id in self?.takes.first { $0.id == id } }
        s.onVersionSaved = { [weak self] t in self?.editSuiteSaved(t) }
        s.attachSessionId = item.sessionId
        s.resume = resume
        return s
    }

    /// The recent edit for a take opened from the Edit home (it continues where that edit was left), if there is one.
    func recentEdit(forTake takeId: String) -> EditRecentItem? {
        guard takeId != EditV2.blankSourceId else { return nil }
        return suite.recentEdits.first { $0.takeId == takeId }
    }
}
