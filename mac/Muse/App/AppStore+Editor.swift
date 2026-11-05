import AppKit
import MuseCore

// The video editor (plans/video-editor.md): opened from any video take with a video, made on this Mac, saved as a new
// "Edited" version linked to the take it was cut from. The original is never changed. Free: nothing is charged.
extension AppStore {
    /// Takes the editor can open: video takes with their video.
    func canEdit(_ t: Take) -> Bool { t.isVideo && t.videoUrl != nil }

    /// Opens the editor. An edited version re-opens its edit list on its source while that take exists; otherwise its own
    /// video is the source with a fresh list.
    func openEditor(_ t: Take) {
        guard let start = t.editorStart(sourceExists: { id in self.takes.contains { $0.id == id && $0.videoUrl != nil } }) else {
            showToast("Only video takes can be edited")
            return
        }
        let source = start.list == nil ? t : (takes.first { $0.id == start.sourceTakeId } ?? t)
        guard let v = source.videoUrl, let url = URL(string: v) else { return }
        editor?.close()
        let s = VideoEditorSession(take: t, sourceTakeId: start.sourceTakeId, start: start.list)
        editor = s
        openTakeId = t.id
        go(.editor)
        Task { await s.load(source: url) }
    }

    /// Leaves the editor (back to the take). An export in progress is cancelled.
    func closeEditor() {
        editor?.close()
        editor = nil
        go(.result)
    }

    /// Export finished: upload the file and its thumbnail (presigned), then create the version.
    @discardableResult
    func saveEditedVersion(_ video: EditedVideo, edits: EditList, progress: @escaping @Sendable (Double) -> Void) async throws -> Take {
        let up = try await api.uploadEditedVideo(video, progress: progress)
        let take = try await api.createTakeVersion(takeId: edits.sourceTakeId, .make(up, video: video, edits: edits))
        if let i = takes.firstIndex(where: { $0.id == take.id }) { takes[i] = take } else { takes.insert(take, at: 0) }
        fresh.insert(take.id)
        return take
    }

    func exportEdit() {
        guard let s = editor else { return }
        if let p = s.exportProblem {
            showToast(p)
            return
        }
        s.export(save: { [weak self] video, edits, progress in
            guard let self else { throw CancellationError() }
            s.savedTakeId = try await self.saveEditedVersion(video, edits: edits, progress: progress).id
        }, done: { [weak self] in
            guard let self, let id = s.savedTakeId else { return }
            self.editor?.close()
            self.editor = nil
            self.openTakeId = id
            self.go(.result)
            self.showToast("Saved as a new version · the original is kept")
        })
    }
}
