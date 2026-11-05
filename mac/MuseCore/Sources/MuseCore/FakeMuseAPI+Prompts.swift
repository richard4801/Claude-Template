import Foundation

/// Demo mode: the photoshoot preview and the owner's prompt library, built in the app with the server's default wording.
extension FakeMuseAPI {
    public func shootPreview(_ req: ShootRequest) async throws -> ShootPreview { try shootPreviewNow(req) }

    func shootPreviewNow(_ req: ShootRequest) throws -> ShootPreview {
        if let p = req.refsProblem { throw ApiError("bad_request", p) }
        let m = try model(req.modelId)
        let refs = req.refs ?? []
        let count = max(1, min(4, req.count))
        if let tid = req.templateId {
            let tp = try templatePrompt(id: tid, TemplatePromptRequest(modelId: req.modelId, outfitId: req.outfitId, direction: req.direction ?? "",
                                                                       shuffleSeed: req.shuffleSeed, lockSeed: req.lockSeed ?? false))
            let base = PromptEngine.shootPreview(identity: m.promptIdentity(lora: loras[m.id]), outfitName: "", settings: ShootSettings(), presets: false, refs: refs,
                                                 pricing: photoPricing, count: count)
            let firstRef = base.refs.first { !$0.dropped }?.index ?? 1
            let sent = refs.enumerated().filter { !base.refs[$0.offset].dropped }.map(\.element)
            var slots = tp.slots
            let at = slots.firstIndex { ["style", "negative", "seed"].contains($0.layer) } ?? slots.count
            slots.insert(contentsOf: PromptEngine.referenceSlots(sent, firstIndex: firstRef), at: at)
            return ShootPreview(slots: slots, seed: tp.seed, images: base.images, refs: base.refs, estimate: base.estimate)
        }
        var s = ShootSettings()
        if let sc = req.scene?.trimmingCharacters(in: .whitespacesAndNewlines), !sc.isEmpty {
            if ShootSettings.scenes.contains(sc) { s.scene = sc } else { s.sceneCustom = sc }
        }
        if let c = req.camera {
            s.shot = c.shot
            s.lens = c.lens
            s.aperture = c.aperture
        }
        s.light = req.light ?? s.light
        s.grade = req.grade ?? s.grade
        s.direction = req.direction ?? ""
        s.lockSeed = req.lockSeed ?? false
        let outfit = outfits.first { $0.id == req.outfitId }?.name ?? "outfit"
        var id = m.promptIdentity(lora: loras[m.id])
        id.neverAdd += promptText("never.base").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return PromptEngine.shootPreview(identity: id, outfitName: outfit, settings: s, presets: req.presets ?? true, refs: refs, prompt: req.prompt,
                                         houseStyle: promptText("style.house"), pricing: photoPricing, count: count)
    }

    func promptText(_ key: String) -> String {
        promptOverrides[key] ?? PromptLibraryDefaults.entries.first { $0.key == key }?.defaultText ?? ""
    }

    private func promptEntry(_ key: String) throws -> PromptEntry {
        guard var e = PromptLibraryDefaults.entries.first(where: { $0.key == key }) else { throw ApiError("not_found", "No prompt called \(key)") }
        if let o = promptOverrides[key] {
            e.current = o
            e.overridden = true
            e.updatedAt = promptUpdated[key]
            e.updatedBy = "you@studio.com"
        }
        return e
    }

    private func ownerOnly() throws {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can change prompts") }
    }

    public func prompts() async throws -> PromptLibrary {
        try ownerOnly()
        return PromptLibrary(groups: PromptLibraryDefaults.groups, prompts: try PromptLibraryDefaults.entries.map { try promptEntry($0.key) })
    }

    public func setPrompt(key: String, text: String) async throws -> PromptEntry {
        try ownerOnly()
        let e = try promptEntry(key)
        if let p = PromptPlaceholders.problem(e, text) { throw ApiError("prompt_invalid", p) }
        if text == e.defaultText { promptOverrides[key] = nil } else { promptOverrides[key] = text }
        promptUpdated[key] = nowMs()
        let out = try promptEntry(key)
        hub.emit(ApiEvent(type: "prompts", prompt: out))
        return out
    }

    public func resetPrompt(key: String) async throws -> PromptEntry {
        try ownerOnly()
        _ = try promptEntry(key)
        promptOverrides[key] = nil
        let out = try promptEntry(key)
        hub.emit(ApiEvent(type: "prompts", prompt: out))
        return out
    }

    public func previewPrompt(_ req: PromptPreviewRequest) async throws -> PromptPreview {
        try ownerOnly()
        let e = try promptEntry(req.key)
        let text = req.text ?? e.current
        if let p = PromptPlaceholders.problem(e, text) { throw ApiError("prompt_invalid", p) }
        let sample = PromptLibraryDefaults.sample
        let rendered = PromptPlaceholders.fill(text, sample)
        // The whole photoshoot prompt around it, with the sample model.
        let id = PromptIdentity(name: "Demo model", look: sample["look"] ?? "")
        var s = ShootSettings()
        s.direction = sample["direction"] ?? ""
        let isStyle = e.key == "style.house"
        var lines = PromptEngine.shoot(identity: id, outfitName: sample["outfit"] ?? "outfit", settings: s,
                                       houseStyle: isStyle ? rendered : promptText("style.house")).map(\.text)
        if !isStyle {
            if let i = lines.firstIndex(of: PromptPlaceholders.fill(e.current, sample)) ?? lines.firstIndex(of: PromptPlaceholders.fill(e.defaultText, sample)) {
                lines[i] = rendered
            } else {
                lines.append(rendered)
            }
        }
        return PromptPreview(key: e.key, text: rendered, example: lines.filter { !$0.isEmpty }.joined(separator: "\n"), sample: sample)
    }
}
