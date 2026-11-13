import Foundation
import MuseCore

/// Continue a draft (owner, 2026-11-12): what an editor reopens. The owner's edit is a server session (joined by its id, so a
/// blank project or an edit whose take was deleted opens too); a member's is the copy this Mac kept.
enum EditResume {
    case session(EditSession)
    case local(EditLocalDraft)

    /// The edit as it was left (nil: build it from the take as usual).
    var project: EditV2.Project? {
        switch self {
        case .session(let s): return try? JSONPatch.decode(EditV2.Project.self, s.project)
        case .local(let d): return d.project
        }
    }

    var view: EditSessionView? {
        switch self {
        case .session(let s): return s.view
        case .local(let d): return d.view
        }
    }

    var localDraft: EditLocalDraft? { if case .local(let d) = self { return d }; return nil }
}

// Where the editor was left is saved shortly after it changes (playhead when stopped, zoom, tabs, platform view, selection),
// and at once when the editor closes: on this Mac (EditRecentStore) and, for the owner, on the session so another device
// continues at the same place. A member's edit itself is kept on this Mac too (their editor has no server copy).
extension EditSuiteSession {
    static let viewSaveAfter: UInt64 = 800_000_000

    /// The edit's name in Recent edits.
    var draftTitle: String {
        if let t = resume?.view?.title, !t.isEmpty, take.title.isEmpty || isBlankStart { return t }
        return isBlankStart ? EditRecent.untitled : title
    }

    /// The take this edit is kept under ("blank" for a blank project).
    var draftTakeId: String { isBlankStart ? E.blankSourceId : sourceTakeId }

    /// The server session this editor is on (owner), if any.
    var draftSessionId: String? { live?.sessionId ?? attachSessionId }

    /// After load: back where it was left, then changes are tracked.
    func restoreView() {
        if case .local(let d)? = resume, d.takeId == E.blankSourceId, let id = d.localId { localBlankId = id }
        if let v = resume?.view {
            view { $0.restore(v) }
            if let b = EditSuite.binTab(v) { binTab = b }
            if let m = v.mode.flatMap(Mode.init(rawValue:)) { mode = m }
            seek(state.playhead)
        }
        lastSentView = nil
        viewTracking = true
        // The edit is the last one worked on from now (even if nothing changes).
        saveViewNow()
    }

    /// Something the view or the edit shows changed: saved after a short pause.
    func viewChanged() {
        guard viewTracking else { return }
        viewTask?.cancel()
        viewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.viewSaveAfter)
            guard let self, !Task.isCancelled else { return }
            self.saveViewNow()
        }
    }

    /// Saves where the editor is now (this Mac at once; the session when it changed).
    func saveViewNow() {
        guard viewTracking, isReady else { return }
        var v = state.viewSnapshot(binTab: binTab, mode: mode.rawValue, title: draftTitle)
        if playing { v.playhead = (playhead * 1000).rounded() / 1000 }
        let sid = isOwner ? draftSessionId : nil
        let now = Double(Date().timeIntervalSince1970 * 1000)
        // The owner's project is on the server; a member's (or the owner's when the edit couldn't be shared) is kept here.
        let keepProject = sid == nil && !(project.isBlank && project.mainClips.isEmpty && project.assets.isEmpty)
        if sid != nil || keepProject {
            recentStore.save(EditLocalDraft(takeId: draftTakeId, sessionId: sid, localId: isBlankStart && sid == nil ? localBlankId : nil,
                                            project: keepProject ? project : nil, view: v, title: draftTitle, savedAt: now))
        }
        guard let sid, lastSentView.map({ !$0.samePlace(v) }) ?? true else { return }
        lastSentView = v
        let api = self.api
        Task { try? await api.saveEditSessionView(sessionId: sid, v) }
    }
}
