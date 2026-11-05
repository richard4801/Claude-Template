import AppKit
import MuseCore
import Observation

/// The v1 editor's session, kept as a thin handle so the existing "Edit" entry points (AppStore.openEditor, Result and
/// Gallery) keep working: the editing itself now happens in the Edit suite (EditSuiteView / EditSuiteSession), which
/// opens the same take — a v1 edited version re-opens its edit list there through EditV2.fromV1, a v2 version its project.
@MainActor
@Observable
final class VideoEditorSession {
    /// The take that was opened (a render, or an edited version).
    let take: Take
    /// The take whose video is cut (the new version's parent).
    let sourceTakeId: String
    /// The version the last export was saved as (set by the suite's save).
    var savedTakeId: String?

    init(take: Take, sourceTakeId: String, start: EditList?) {
        self.take = take
        self.sourceTakeId = sourceTakeId
    }

    /// The Edit suite loads the source itself.
    func load(source: URL) async {}

    func close() {}

    /// Exports run in the Edit suite's own sheet (E4).
    var exportProblem: String? { "Use Export in the Edit suite" }

    func export(save: @escaping @MainActor (EditedVideo, EditList, @escaping @Sendable (Double) -> Void) async throws -> Void,
                done: @escaping @MainActor () -> Void) {}
}
