import AppKit
import MuseCore
import SwiftUI

/// What the shoot preview depends on: when any of it changes, the preview refetches (debounced).
struct ShootPreviewKey: Equatable {
    var modelId: String?
    var outfitId: String?
    var templateId: String?
    var settings: ShootSettings
    var presets: Bool
    var refs: [ShootRef]
    var edited: String?
    var templateDirection: String
    var templateShuffle: Int64
    var templateLockLook: Bool
    var promptsVersion: Int
    var source: String
}

extension AppStore {
    // MARK: Reference images (up to 3)

    var shootRefsFull: Bool { shootRefs.count + shootRefsUploading >= ShootRef.max }
    var shootRefsFeature: ShootReferencesFeature { photoPricing.references ?? ShootReferencesFeature() }

    func pickShootRefs() {
        let room = ShootRef.max - shootRefs.count - shootRefsUploading
        guard room > 0 else { showToast("Up to \(ShootRef.max) reference images"); return }
        addShootRefs(MediaImport.pick(MediaImport.imageTypes, multiple: room > 1, prompt: "Use as reference"))
    }

    /// From the file picker or a drop. Each one uploads, then joins with the first guide the others don't use yet.
    func addShootRefs(_ urls: [URL]) {
        let images = urls.filter(MediaImport.isImage)
        guard !images.isEmpty else {
            if !urls.isEmpty { showToast("That isn't an image") }
            return
        }
        let room = ShootRef.max - shootRefs.count - shootRefsUploading
        if images.count > room { showToast("Up to \(ShootRef.max) reference images") }
        for url in images.prefix(max(0, room)) {
            shootRefsUploading += 1
            perform { [self] in
                defer { shootRefsUploading -= 1 }
                let ref = try await uploadImage(url)
                guard shootRefs.count < ShootRef.max else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    shootRefs.append(ShootRef(image: ref, guides: [ShootRef.defaultGuide(after: shootRefs)]))
                }
            }
        }
    }

    func toggleShootRefGuide(_ index: Int, _ g: ShootGuide) {
        guard shootRefs.indices.contains(index) else { return }
        if shootRefs[index].guides == [g] {
            showToast("Keep at least one guide on")
            return
        }
        shootRefs[index].toggle(g)
    }

    func removeShootRef(_ index: Int) {
        guard shootRefs.indices.contains(index) else { return }
        _ = withAnimation(.easeOut(duration: 0.2)) { shootRefs.remove(at: index) }
    }

    // MARK: The server-built prompt

    var shootPreviewKey: ShootPreviewKey {
        ShootPreviewKey(modelId: currentModel?.id, outfitId: currentOutfit?.id, templateId: shootTemplate?.id, settings: shoot, presets: shootPresets,
                        refs: shootRefs, edited: promptOverride, templateDirection: templateDirection, templateShuffle: templateShuffle,
                        templateLockLook: templateLockLook, promptsVersion: promptsVersion, source: serverKey)
    }

    /// The request Shoot would send right now (also the preview's body).
    func currentShootRequest() -> ShootRequest? {
        guard let m = currentModel, let o = currentOutfit else { return nil }
        var req: ShootRequest
        if let t = shootTemplate {
            req = ShootRequest.template(t.id, modelId: m.id, outfitId: o.id, direction: templateDirection, shuffleSeed: templateShuffle,
                                        lockSeed: templateLockLook, productImage: t.acceptsProduct ? templateProduct : nil, refs: shootRefs)
        } else {
            req = ShootRequest.built(modelId: m.id, outfitId: o.id, settings: shoot, presets: shootPresets, refs: shootRefs, prompt: promptOverride)
        }
        req.models = shootOverrides
        return req
    }

    /// POST /v1/shoots/preview, called by the Photoshoot screen ~300 ms after the last change. Demo mode and an unreachable
    /// server fall back to the app's own engine (marked as local).
    func refreshShootPreview() async {
        guard let req = currentShootRequest() else {
            shootPreview = nil
            return
        }
        do {
            let p = try await api.shootPreview(req)
            guard !Task.isCancelled else { return }
            shootPreview = p
            shootPreviewIsLocal = isDemo
        } catch is CancellationError {
        } catch let e as ApiError where e.code == "bad_request" {
            guard !Task.isCancelled else { return }
            shootPreview = nil
            showToast(e.friendlyMessage)
        } catch {
            guard !Task.isCancelled else { return }
            // An older server without the preview, or offline: the local engine (same default wording).
            shootPreview = nil
            shootPreviewIsLocal = true
        }
    }

    /// Signing out or switching servers: references, previews and the prompt library belong to that account.
    func resetShootAndPrompts() {
        shootRefs = []
        shootPreview = nil
        shootPreviewIsLocal = false
        promptLibrary = nil
        promptLibraryError = nil
        closePrompt()
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
