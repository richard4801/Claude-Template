import AppKit
import MuseCore
import SwiftUI

/// Where the model catalog was opened from: Settings (changes the step's default) or a per-run chooser (owner only).
enum CatalogTarget: Equatable {
    case settings, enhance, dressUp
}

/// The owner's model catalog sheet for one image step.
struct CatalogDraft {
    var step: ImageStep
    var target: CatalogTarget
    var query = ""
    var collection: String?
    var collections: [CatalogCollectionRef] = []
    var models: [CatalogModel] = []
    var loading = false
    var error: String?
    /// "Paste any owner/model".
    var paste = ""
    /// The opened model (advanced view: price, compatibility, mapping, inputs).
    var detail: ModelDetail?
    var detailLoading = false
    /// Advanced inputs as typed, by input name.
    var extraText: [String: String] = [:]
    var saving = false
}

struct EnhanceDraft {
    var modelId: String
    var realism = EnhanceFeatures.defaultRealism
    var upscale = EnhanceFeatures.defaultUpscale
    var estimate: ToolEstimate?
    var estimating = false
    var starting = false
    var runId: String?
    /// Owner only: per-run models (step → "owner/name").
    var models: [String: String] = [:]
}

struct DressUpDraft {
    var modelId: String
    var image: URL?
    var name = ""
    var engine = DressUpFeatures.defaultEngine
    var estimate: ToolEstimate?
    var estimating = false
    var starting = false
    var runId: String?
    var models: [String: String] = [:]
}

struct VersionsDraft {
    var modelId: String
    var versions: [SheetVersion] = []
    var loading = true
}

extension AppStore {
    // MARK: Derived

    var toolsFeatures: ToolsFeatures? { studioSettings?.features.tools }

    func resetModelTools() {
        stepModels = []
        archivedModels = []
        catalog = nil
        enhanceDraft = nil
        dressUpDraft = nil
        versionsDraft = nil
        toolRuns = [:]
    }

    /// The name shown for a step's model in a chooser (owner only): the per-run pick, else the step's current model.
    func modelName(for step: ImageStep, override: String?) -> String {
        if let o = override { return parseModelId(o)?.name ?? o }
        return stepModels.first { $0.step == step.rawValue }?.name ?? parseModelId(step.defaultModel)?.name ?? step.defaultModel
    }

    /// Dress up option labels. Members see "Option A" / "Option B"; the owner also sees the model behind each.
    func dressUpLabel(_ option: ToolOption) -> String {
        guard isOwner, option.id != "both" else { return option.label }
        let step: ImageStep = option.id == "b" ? .dressB : .dressA
        let override = dressUpDraft?.models[step.rawValue]
        let name = override.map { parseModelId($0)?.name ?? $0 } ?? toolsFeatures?.dressUp.models?[step.rawValue]?.name ?? modelName(for: step, override: nil)
        return "\(option.label) · \(name)"
    }

    func dropArchived(_ m: MuseModel) {
        models.removeAll { $0.id == m.id }
        outfits.removeAll { $0.modelId == m.id }
        if isOwner, !archivedModels.contains(where: { $0.id == m.id }) { archivedModels.insert(m, at: 0) }
        if modelId == m.id, let next = models.first(where: { !$0.isDraft }) ?? models.first { modelId = next.id }
        if profileModelId == m.id, let next = models.first { profileModelId = next.id }
    }

    func applyToolRun(_ r: ToolRun) {
        let before = toolRuns[r.id]
        toolRuns[r.id] = r
        guard before?.isRunning == true else { return }
        let what = r.isEnhance ? "Enhance" : "Dress up"
        if r.isReview {
            showToast("\(what) is ready to review")
            Notifier.shared.post(title: "\(what) is ready", body: "\(r.items.count) images to review.")
        } else if r.state == "failed" {
            showToast("\(what) stopped · \(r.error ?? MemberText.wentWrong)")
        }
    }

    // MARK: Image models (owner)

    func loadImageModels() {
        guard isOwner else { return }
        perform { [self] in stepModels = try await api.imageModels() }
    }

    func openCatalog(_ step: ImageStep, target: CatalogTarget) {
        guard isOwner else { return }
        catalog = CatalogDraft(step: step, target: target)
        searchCatalog()
    }

    func searchCatalog() {
        guard let d = catalog else { return }
        catalog?.loading = true
        catalog?.error = nil
        let q = CatalogQuery(step: d.step, q: d.query, collection: d.query.trimmingCharacters(in: .whitespaces).isEmpty ? d.collection : nil)
        let api = self.api
        Task { [weak self] in
            do {
                let r = try await api.imageModelCatalog(q)
                guard let self, self.catalog?.step == d.step else { return }
                self.catalog?.models = r.models
                if !r.collections.isEmpty { self.catalog?.collections = r.collections }
                self.catalog?.loading = false
            } catch let e as ApiError {
                self?.catalog?.loading = false
                self?.catalog?.error = e.friendlyMessage
            } catch {
                self?.catalog?.loading = false
            }
        }
    }

    /// Opens one model (from the list or pasted): its price, compatibility, mapping and advanced inputs.
    func openCatalogModel(_ id: String) {
        guard let d = catalog else { return }
        guard let p = parseModelId(id) else {
            catalog?.error = "Paste a model as owner/name, e.g. black-forest-labs/flux-2-pro"
            return
        }
        catalog?.detailLoading = true
        catalog?.error = nil
        let api = self.api
        let current = d.target == .settings ? stepModels.first { $0.step == d.step.rawValue } : nil
        Task { [weak self] in
            do {
                let detail = try await api.imageModelDetail(id: "\(p.owner)/\(p.name)", step: d.step)
                guard let self else { return }
                self.catalog?.detail = detail
                self.catalog?.detailLoading = false
                // Prefill the advanced inputs with what's saved for this step's model.
                if let current, current.model == detail.model.id {
                    self.catalog?.extraText = current.extra.mapValues(\.description)
                } else {
                    self.catalog?.extraText = [:]
                }
            } catch let e as ApiError {
                self?.catalog?.detailLoading = false
                self?.catalog?.error = e.friendlyMessage
            } catch {
                self?.catalog?.detailLoading = false
            }
        }
    }

    /// The typed advanced inputs as JSON values, or the first problem.
    func catalogExtra() -> (extra: [String: JSONValue], problem: String?) {
        guard let d = catalog, let detail = d.detail else { return ([:], nil) }
        var out: [String: JSONValue] = [:]
        for f in detail.editableInputs {
            let text = d.extraText[f.name] ?? ""
            if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let v = JSONValue.parse(text, type: f.type) else { return ([:], "\(f.name): that isn't a valid \(f.type)") }
            out[f.name] = v
        }
        return (out, SetImageModelRequest.validate(extra: out, inputs: detail.inputs))
    }

    /// Settings: makes the opened model this step's default. Per-run: uses it for this run only.
    func useCatalogModel() {
        guard let d = catalog, let detail = d.detail else { return }
        if detail.model.compatible == false {
            catalog?.error = "This model can't do \(d.step.label): \(detail.model.reasons.joined(separator: ", "))"
            return
        }
        switch d.target {
        case .settings:
            let (extra, problem) = catalogExtra()
            if let problem { catalog?.error = problem; return }
            catalog?.saving = true
            perform { [self] in
                do {
                    let s = try await api.setImageModel(step: d.step, SetImageModelRequest(model: detail.model.id, extra: extra))
                    if let i = stepModels.firstIndex(where: { $0.step == s.step }) { stepModels[i] = s } else { stepModels.append(s) }
                    catalog = nil
                    showToast("\(d.step.label) now uses \(s.name)")
                    await loadStudio()
                } catch {
                    catalog?.saving = false
                    throw error
                }
            }
        case .enhance:
            enhanceDraft?.models[d.step.rawValue] = detail.model.id
            catalog = nil
            refreshEnhanceEstimate()
        case .dressUp:
            dressUpDraft?.models[d.step.rawValue] = detail.model.id
            catalog = nil
            refreshDressUpEstimate()
        }
    }

    func resetImageModel(_ step: ImageStep) {
        perform { [self] in
            let s = try await api.resetImageModel(step: step)
            if let i = stepModels.firstIndex(where: { $0.step == s.step }) { stepModels[i] = s }
            if catalog?.step == step { catalog = nil }
            showToast("\(step.label) is back on the default")
            await loadStudio()
        }
    }

    /// Per-run chooser → "Default".
    func clearOverride(_ step: ImageStep, target: CatalogTarget) {
        switch target {
        case .enhance:
            enhanceDraft?.models[step.rawValue] = nil
            refreshEnhanceEstimate()
        case .dressUp:
            dressUpDraft?.models[step.rawValue] = nil
            refreshDressUpEstimate()
        case .settings: resetImageModel(step)
        }
    }

    func modelOverride(_ step: ImageStep, target: CatalogTarget) -> String? {
        switch target {
        case .enhance: return enhanceDraft?.models[step.rawValue]
        case .dressUp: return dressUpDraft?.models[step.rawValue]
        case .settings: return nil
        }
    }

    // MARK: Enhance

    func openEnhance(_ m: MuseModel) {
        guard m.filled > 0 else {
            showToast("Add character-sheet images first")
            return
        }
        // Reopen a run still waiting for review.
        let open = toolRuns.values.filter { $0.modelId == m.id && $0.isEnhance && ($0.isRunning || $0.isReview) }.max { $0.createdAt < $1.createdAt }
        enhanceDraft = EnhanceDraft(modelId: m.id, runId: open?.id)
        if open == nil { refreshEnhanceEstimate() }
    }

    private var enhanceRequest: EnhanceRequest? {
        guard let d = enhanceDraft else { return nil }
        return EnhanceRequest(realism: d.realism, upscale: d.upscale, models: isOwner ? d.models : nil)
    }

    func refreshEnhanceEstimate() {
        guard let d = enhanceDraft, let req = enhanceRequest else { return }
        guard req.isValid else {
            enhanceDraft?.estimate = nil
            return
        }
        enhanceDraft?.estimating = true
        let api = self.api
        Task { [weak self] in
            let est = try? await api.enhanceEstimate(modelId: d.modelId, req)
            guard let self, self.enhanceDraft?.modelId == d.modelId else { return }
            self.enhanceDraft?.estimate = est
            self.enhanceDraft?.estimating = false
        }
    }

    func startEnhance() {
        guard let d = enhanceDraft, let req = enhanceRequest, !d.starting else { return }
        guard req.isValid else {
            showToast("Turn on realism or upscale")
            return
        }
        if let e = d.estimate?.estimate, e > creditUsd + 1e-9 {
            notEnough("to enhance")
            return
        }
        enhanceDraft?.starting = true
        perform { [self] in
            do {
                let run = try await api.enhance(modelId: d.modelId, req)
                toolRuns[run.id] = run
                enhanceDraft?.runId = run.id
                enhanceDraft?.starting = false
                balance = try await api.balance()
            } catch {
                enhanceDraft?.starting = false
                throw error
            }
        }
    }

    // MARK: Dress up

    func openDressUp(_ m: MuseModel) {
        guard m.filled > 0 else {
            showToast("Add character-sheet images first")
            return
        }
        let open = toolRuns.values.filter { $0.modelId == m.id && $0.isDressUp && ($0.isRunning || $0.isReview) }.max { $0.createdAt < $1.createdAt }
        dressUpDraft = DressUpDraft(modelId: m.id, runId: open?.id)
        if open == nil { refreshDressUpEstimate() }
    }

    func refreshDressUpEstimate() {
        guard let d = dressUpDraft else { return }
        dressUpDraft?.estimating = true
        let req = DressUpEstimateRequest(engine: d.engine, models: isOwner ? d.models : nil)
        let api = self.api
        Task { [weak self] in
            let est = try? await api.dressUpEstimate(modelId: d.modelId, req)
            guard let self, self.dressUpDraft?.modelId == d.modelId else { return }
            self.dressUpDraft?.estimate = est
            self.dressUpDraft?.estimating = false
        }
    }

    func setDressUpImage(_ url: URL) {
        guard MediaImport.isImage(url) else {
            showToast("That isn't an image")
            return
        }
        dressUpDraft?.image = url
        if dressUpDraft?.name.isEmpty ?? false {
            dressUpDraft?.name = String(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").prefix(40))
        }
    }

    func startDressUp() {
        guard let d = dressUpDraft, !d.starting else { return }
        guard let url = d.image else {
            showToast("Drop an outfit photo first")
            return
        }
        if let e = d.estimate?.estimate, e > creditUsd + 1e-9 {
            notEnough("to dress up")
            return
        }
        dressUpDraft?.starting = true
        perform { [self] in
            do {
                let ref = try await uploadImage(url)
                let run = try await api.dressUp(modelId: d.modelId, DressUpRequest(outfitImage: ref, name: d.name, engine: d.engine, models: isOwner ? d.models : nil))
                toolRuns[run.id] = run
                dressUpDraft?.runId = run.id
                dressUpDraft?.starting = false
                balance = try await api.balance()
            } catch {
                dressUpDraft?.starting = false
                throw error
            }
        }
    }

    // MARK: Review and apply (both tools)

    func decide(_ run: ToolRun, _ item: ToolItem, keep: Bool, pick: String? = nil) {
        perform { [self] in
            toolRuns[run.id] = try await api.decideToolItem(runId: run.id, slot: item.slot, ToolDecisionRequest(decision: keep ? "keep" : "reject", pick: pick))
        }
    }

    func pickWholeSet(_ run: ToolRun, _ pick: String) {
        perform { [self] in toolRuns[run.id] = try await api.pickToolRun(runId: run.id, pick: pick) }
    }

    func retryItem(_ run: ToolRun, _ item: ToolItem, engine: String? = nil) {
        perform { [self] in
            toolRuns[run.id] = try await api.retryToolItem(runId: run.id, slot: item.slot, engine: engine)
            balance = try await api.balance()
        }
    }

    func applyRun(_ run: ToolRun, name: String? = nil) {
        guard run.canApply else {
            showToast("Keep at least one image first")
            return
        }
        perform { [self] in
            let r = try await api.applyToolRun(runId: run.id, ToolApplyRequest(name: name))
            toolRuns[r.run.id] = r.run
            replaceModel(r.model)
            if let o = r.outfit {
                if let i = outfits.firstIndex(where: { $0.id == o.id }) { outfits[i] = o } else { outfits.append(o) }
                dressUpDraft = nil
                showToast("Saved as a new outfit · \(o.name)")
            } else {
                enhanceDraft = nil
                let modelId = r.model.id
                showToast("Character sheet updated · the previous version is kept", action: "Versions") { [weak self] in self?.openVersions(modelId) }
            }
        }
    }

    func discardRun(_ run: ToolRun) {
        perform { [self] in
            try await api.discardToolRun(runId: run.id)
            toolRuns[run.id]?.state = "discarded"
            if enhanceDraft?.runId == run.id { enhanceDraft = nil }
            if dressUpDraft?.runId == run.id { dressUpDraft = nil }
            balance = try await api.balance()
        }
    }

    // MARK: Sheet versions

    func openVersions(_ modelId: String) {
        versionsDraft = VersionsDraft(modelId: modelId)
        perform { [self] in
            let v = try await api.sheetVersions(modelId: modelId)
            guard versionsDraft?.modelId == modelId else { return }
            versionsDraft?.versions = v
            versionsDraft?.loading = false
        }
    }

    func restoreVersion(_ v: SheetVersion) {
        guard let d = versionsDraft else { return }
        perform { [self] in
            let m = try await api.restoreSheetVersion(modelId: d.modelId, versionId: v.id)
            replaceModel(m)
            versionsDraft = nil
            showToast("Previous character sheet restored")
        }
    }

    // MARK: Archive (owner)

    func archiveModel(_ m: MuseModel) {
        guard isOwner else { return }
        let alert = NSAlert()
        alert.messageText = "Archive \(m.name)?"
        alert.informativeText = "She disappears from every list and picker. Her outfits, photos, renders and posts stay. You can restore her in Settings → Archived models."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in
            let a = try await api.archiveModel(id: m.id)
            dropArchived(a)
            if screen == .profile { go(.models) }
            showToast("\(m.name) archived", action: "Archived") { [weak self] in self?.openSettings(.studio) }
        }
    }

    func unarchiveModel(_ m: MuseModel) {
        perform { [self] in
            let back = try await api.unarchiveModel(id: m.id)
            archivedModels.removeAll { $0.id == back.id }
            if !models.contains(where: { $0.id == back.id }) { models.append(back) }
            outfits = try await api.listOutfits()
            showToast("\(back.name) restored", action: "Open") { [weak self] in self?.openProfile(back.id) }
        }
    }

    func loadArchived() {
        // Kept current by `model` events (archive / unarchive): refetch only when over a minute old.
        guard isOwner, !listFreshness.isFresh("archived", maxAge: Self.listMaxAge) else { return }
        perform { [self] in
            archivedModels = try await api.listArchivedModels()
            listFreshness.mark("archived")
        }
    }
}
