import Foundation
import MuseCore

// Edit's platform preview (owner decision 2026-11-12, plans/edit-platform-preview.md): the view picker (Clean or an
// app's chrome), the red safe-area box, the choice remembered per project, Claude told the view with the presence ping,
// and the warning line with "Move into the safe area".
extension EditSuiteSession {
    private static let previewPrefsKey = "edit.preview"

    /// The project's key for the remembered choice: its source take (a blank project shares one key until it is saved).
    var previewKey: String { sourceTakeId }

    static func rememberedPreview(for key: String) -> EditPreview {
        // Review mode starts every project in Clean, so the review shots don't depend on the runner's last choice.
        if SnapshotRunner.probing { return EditPreview() }
        return readPrefs().choice(for: key)
    }

    private static func readPrefs() -> EditPreviewPrefs {
        guard let d = UserDefaults.standard.data(forKey: previewPrefsKey) else { return EditPreviewPrefs() }
        return (try? JSONDecoder().decode(EditPreviewPrefs.self, from: d)) ?? EditPreviewPrefs()
    }

    /// The view or the switch changed: shown at once, remembered for this project (and as this Mac's last choice), and
    /// sent to the server so Claude knows what the person sees.
    func setPreview(_ p: EditPreview, remember: Bool = true) {
        let next = p.resolved(width: project.canvas.width, height: project.canvas.height)
        guard next != state.preview else { return }
        view { $0.preview = next }
        if remember && !SnapshotRunner.probing {
            var prefs = Self.readPrefs()
            prefs.set(next, for: previewKey)
            if let d = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(d, forKey: Self.previewPrefsKey) }
        }
        if let sync = live {
            Task { try? await sync.announce(label: Self.hostLabel, platform: "mac", canRender: true, preview: next) }
        }
    }

    func loadPreviewLayouts() async { previewLayouts = await api.previewLayouts() }

    /// The view this canvas shows (a TikTok choice on a 16:9 project shows Clean).
    var shownPreview: EditPreview { state.preview.resolved(width: project.canvas.width, height: project.canvas.height) }
    var previewIsLandscape: Bool { EditPreview.isLandscape(width: project.canvas.width, height: project.canvas.height) }

    /// The red box, when the switch is on.
    var safeZone: SafeZone? { EditSafeBox.zone(state.preview, width: project.canvas.width, height: project.canvas.height, layouts: previewLayouts) }

    /// Captions and text outside the red box (none while the switch is off).
    var safeIssues: [SafeAreaIssue] {
        guard let z = safeZone else { return [] }
        return EditSafeCheck.issues(project, zone: z)
    }

    /// The warning line under the preview, or nil.
    var safeWarning: String? {
        EditSafeCheck.line(safeIssues, covers: EditSafeBox.covers(state.preview, width: project.canvas.width, height: project.canvas.height))
    }

    /// "Move into the safe area": one undoable change that moves the captions (and their wrap width) and each text item
    /// just inside the box.
    func moveIntoSafeArea() {
        guard let z = safeZone else { return }
        nextChangeLabel = "Moved into the safe area"
        let ok = edit { s in s.apply { p in EditSafeCheck.fixed(p, zone: z) } }
        if !ok { nextChangeLabel = nil }
    }
}
