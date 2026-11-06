import AppKit
import MuseCore
import SwiftUI

/// The owner's prompt library (Settings → Prompts). The Photoshoot screen's references and preview moved to the AI suite's
/// Photo tool (AppStore+Photo.swift, workstream 3).
extension AppStore {
    /// Signing out or switching servers: the prompt library belongs to that account.
    func resetPromptLibrary() {
        promptLibrary = nil
        promptLibraryError = nil
        closePrompt()
        resetPromptScripts() // prompt scripts (workstream 4)
    }

    // MARK: Prompt library (owner)

    func loadPrompts() async {
        guard isOwner else { return }
        do {
            promptLibrary = try await api.prompts()
            promptLibraryError = nil
        } catch let e as ApiError {
            promptLibraryError = e.code == "not_found" || e.code == "http_404" ? "This server doesn't have the prompt library yet." : e.friendlyMessage
        } catch {
            promptLibraryError = error.localizedDescription
        }
    }

    var editingPrompt: PromptEntry? { promptEditKey.flatMap { promptLibrary?.entry($0) } }
    var promptDirty: Bool { editingPrompt.map { $0.current != promptDraft } ?? false }

    func openPrompt(_ key: String) {
        guard let e = promptLibrary?.entry(key) else { return }
        promptEditKey = key
        promptDraft = e.current
        promptDraftBase = e.current
        promptError = nil
        promptLivePreview = nil
    }

    func closePrompt() {
        promptEditKey = nil
        promptLivePreview = nil
        promptError = nil
    }

    func insertPlaceholder(_ p: PromptPlaceholder) {
        let sep = promptDraft.isEmpty || promptDraft.hasSuffix(" ") || promptDraft.hasSuffix("\n") ? "" : " "
        promptDraft += sep + p.token
    }

    /// The editor's live preview (debounced by the view): POST /v1/prompts/preview with the draft.
    func refreshPromptPreview() async {
        guard let key = promptEditKey else { return }
        let text = promptDraft
        do {
            let p = try await api.previewPrompt(PromptPreviewRequest(key: key, text: text))
            guard !Task.isCancelled, promptEditKey == key, promptDraft == text else { return }
            promptLivePreview = p
            promptError = nil
        } catch let e as ApiError where e.code == "prompt_invalid" {
            guard !Task.isCancelled, promptEditKey == key else { return }
            promptError = e.message
        } catch {}
    }

    func savePrompt() {
        guard let key = promptEditKey, !promptSaving else { return }
        promptSaving = true
        let text = promptDraft
        Task { [weak self] in
            guard let self else { return }
            defer { self.promptSaving = false }
            do {
                let e = try await self.api.setPrompt(key: key, text: text)
                self.promptLibrary?.apply(e)
                self.promptDraft = e.current
                self.promptDraftBase = e.current
                self.promptError = nil
                self.promptsVersion += 1
                self.showToast(e.overridden ? "Saved · used for every new render" : "Saved · back on the default")
            } catch let e as ApiError where e.code == "prompt_invalid" {
                self.promptError = e.message
            } catch let e as ApiError {
                self.handle(e)
            } catch {
                self.showToast(error.localizedDescription)
            }
        }
    }

    func resetPrompt() {
        guard let key = promptEditKey else { return }
        perform { [self] in
            let e = try await api.resetPrompt(key: key)
            promptLibrary?.apply(e)
            if promptEditKey == key {
                promptDraft = e.current
                promptDraftBase = e.current
            }
            promptError = nil
            promptsVersion += 1
            showToast("Back on the default")
        }
    }

    /// A `prompts` event: another device saved or reset an entry. An open editor with no unsaved edits follows it.
    func promptChanged(_ p: PromptEntry) {
        promptsVersion += 1
        guard promptEditKey == p.key else { return }
        if promptDraft == promptDraftBase { promptDraft = p.current }
        promptDraftBase = p.current
    }
}
