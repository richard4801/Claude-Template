import Foundation
import MuseCore

// Owner Settings → Studio → AI editing helpers (plans/api.md "Editor v2", GET/PATCH /v1/editor/settings): the runtime
// switch for the paid helpers (captions, background removal, voice clean-up), the studio's daily limit on them and what
// they've cost today. Demo mode uses a fake that charges nothing. Members never load it (the server answers 403).
extension AppStore {
    var editorSettingsAPI: any EditorSettingsAPI {
        if let http = api as? HTTPMuseAPI { return http }
        return editorSettingsFake
    }

    func loadEditorSettings() async {
        guard isOwner else { return }
        do {
            editorSettings = try await editorSettingsAPI.editorSettings()
            editorSettingsError = nil
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            editorSettings = nil
            editorSettingsError = "This server doesn't have AI editing helper settings yet"
        } catch let e as ApiError {
            editorSettingsError = e.code == "offline" ? "Couldn't load the AI editing helpers · check your connection" : e.friendlyMessage
        } catch {
            editorSettingsError = "Couldn't load the AI editing helpers · check your connection"
        }
    }

    func setPaidHelpers(_ on: Bool) {
        perform { [self] in
            editorSettings = try await editorSettingsAPI.updateEditorSettings(EditorSettingsPatch(paidHelpers: on))
            showToast(on ? "AI editing helpers are on" : "AI editing helpers are off")
        }
    }

    /// A new daily limit, or nil to go back to the server's default ($5).
    func setEditorDailyLimit(_ usd: Double?) {
        perform { [self] in
            editorSettings = try await editorSettingsAPI.updateEditorSettings(
                usd.map { EditorSettingsPatch(capPerDayUsd: $0) } ?? EditorSettingsPatch(resetCap: true))
            showToast("Daily limit saved")
        }
    }
}
