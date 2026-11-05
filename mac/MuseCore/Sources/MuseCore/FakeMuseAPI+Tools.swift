import Foundation

extension ApiError {
    /// New work on an archived model (plans/api.md "Model tools" §7).
    public static let modelArchived = ApiError("model_archived", "This model is archived · restore her in Settings → Archived models")
    static let ownerOnly = ApiError("owner_only", "Only the studio owner can do that")
}

/// A demo catalog entry: what the model can take, so compatibility follows the contract's rules.
struct FakeCatalogEntry {
    var model: CatalogModel
    var prompt: Bool
    /// none | single | array
    var images: String
    var maxImages: Int?
    var scale: Bool
    var strength: Bool
    var inputs: [InputField]
}

/// Model tools in demo mode: the same rules as the server, with simulated results (placeholder stills) and the contract's prices.
extension FakeMuseAPI {
    static let collections: [CatalogCollectionRef] = [
        CatalogCollectionRef(slug: "text-to-image", name: "Generate images", description: "Models that make images from text prompts"),
        CatalogCollectionRef(slug: "image-editing", name: "Edit images", description: "Models that change an image from an instruction"),
        CatalogCollectionRef(slug: "super-resolution", name: "Upscale images", description: "Make images bigger and sharper"),
        CatalogCollectionRef(slug: "ai-image-restoration", name: "Restore images", description: "Fix old, blurry or damaged photos"),
    ]

    static let fluxProPrice = PriceInfo.perUnit([PriceUnit(metric: "run_count", usd: 0.015, label: "per run"),
                                                 PriceUnit(metric: "image_input_megapixel_count", usd: 0.015, label: "per input MP"),
                                                 PriceUnit(metric: "image_output_megapixel_count", usd: 0.015, label: "per output MP")], source: "config")

    static func perImage(_ usd: Double, source: String = "model page") -> PriceInfo {
        .perUnit([PriceUnit(metric: "image_output_count", usd: usd, label: "per output image")], source: source)
    }

    static func field(_ name: String, _ type: String, required: Bool = false, def: JSONValue? = nil, options: [JSONValue]? = nil, min: Double? = nil, max: Double? = nil,
                      maxItems: Int? = nil, desc: String? = nil, mapped: String? = nil) -> InputField {
        InputField(name: name, type: type, required: required, defaultValue: def, options: options, minimum: min, maximum: max, maxItems: maxItems, description: desc, mappedAs: mapped)
    }

    /// The demo catalog: the defaults plus a few well-known alternatives (prices as on their model pages, checked 2026-11-04).
    static let catalog: [(entry: FakeCatalogEntry, collections: [String])] = {
        let safety = field("disable_safety_checker", "boolean", def: .bool(false), desc: "Disable the safety checker")
        let format = field("output_format", "enum", def: .string("webp"), options: [.string("webp"), .string("jpg"), .string("png")], mapped: "outputFormat")
        let seed = field("seed", "integer", desc: "Random seed", mapped: "seed")
        func e(_ id: String, _ desc: String, runs: Int, official: Bool, price: PriceInfo, prompt: Bool = true, images: String, max: Int? = nil, scale: Bool = false,
               strength: Bool = false, extra: [InputField] = [], _ cols: [String]) -> (FakeCatalogEntry, [String]) {
            var inputs: [InputField] = []
            if prompt { inputs.append(field("prompt", "string", required: true, desc: "Text prompt", mapped: "prompt")) }
            if images == "array" { inputs.append(field("input_images", "array", maxItems: max, desc: "Reference images", mapped: "images")) }
            if images == "single" { inputs.append(field("image", "string", required: !prompt, desc: "Input image", mapped: "image")) }
            if scale { inputs.append(field("scale_factor", "number", def: .number(2), min: 1, max: 4, mapped: "scale")) }
            if strength { inputs.append(field("prompt_strength", "number", def: .number(0.8), min: 0, max: 1, mapped: "strength")) }
            inputs += [seed, format] + extra + [safety]
            return (FakeCatalogEntry(model: CatalogModel(id: id, description: desc, runCount: runs, official: official, price: price), prompt: prompt, images: images,
                                     maxImages: max, scale: scale, strength: strength, inputs: inputs), cols)
        }
        return [
            e("black-forest-labs/flux-2-pro", "High-quality image generation and editing with up to 8 reference images", runs: 4_210_000, official: true, price: fluxProPrice,
              images: "array", max: 8, extra: [field("safety_tolerance", "integer", def: .number(2), min: 1, max: 5, desc: "Safety tolerance, 1 is most strict")],
              ["text-to-image", "image-editing"]),
            e("qwen/qwen-image-edit-2511", "Image editing that keeps people and products consistent across several input images", runs: 1_830_000, official: true,
              price: perImage(0.03, source: "config"), images: "array", max: 3, extra: [field("go_fast", "boolean", def: .bool(true), desc: "Faster, slightly lower quality")],
              ["image-editing"]),
            e("black-forest-labs/flux-krea-dev", "An opinionated text-to-image model with photographic realism, also works image-to-image", runs: 2_960_000, official: true,
              price: perImage(0.025), images: "single", strength: true, extra: [field("guidance", "number", def: .number(4.5), min: 0, max: 10)],
              ["text-to-image", "image-editing"]),
            e("philz1337x/clarity-upscaler", "High-resolution image upscaler and enhancer", runs: 22_400_000, official: false,
              price: .perSecond(0.00115, hardware: "A100 (40GB)", typical: 0.018), prompt: true, images: "single", scale: true,
              extra: [field("creativity", "number", def: .number(0.35), min: 0, max: 1), field("resemblance", "number", def: .number(0.6), min: 0, max: 3)],
              ["super-resolution", "ai-image-restoration"]),
            e("nightmareai/real-esrgan", "Real-ESRGAN with optional face correction and adjustable upscale", runs: 71_500_000, official: false,
              price: .perSecond(0.000225, hardware: "T4", typical: 0.0024), prompt: false, images: "single", scale: true,
              extra: [field("face_enhance", "boolean", def: .bool(false))], ["super-resolution"]),
            e("google/nano-banana", "Image generation and editing with strong character consistency", runs: 9_800_000, official: true, price: perImage(0.039),
              images: "array", max: 3, ["text-to-image", "image-editing"]),
            e("bytedance/seedream-4", "Unified text-to-image generation and precise single-sentence editing at up to 4K", runs: 5_100_000, official: true,
              price: perImage(0.03), images: "array", max: 10, ["text-to-image", "image-editing"]),
            e("black-forest-labs/flux-kontext-pro", "Edit images with text instructions while keeping the subject", runs: 6_400_000, official: true, price: perImage(0.04),
              images: "single", ["image-editing"]),
            e("black-forest-labs/flux-1.1-pro", "Faster, better text-to-image generation", runs: 38_000_000, official: true, price: perImage(0.04), images: "none",
              ["text-to-image"]),
            e("sczhou/codeformer", "Robust face restoration for old photos and AI-generated faces", runs: 15_200_000, official: false,
              price: .perSecond(0.000225, hardware: "T4", typical: 0.0031), prompt: false, images: "single", ["ai-image-restoration"]),
        ]
    }()

    static func catalogEntry(_ id: String) -> FakeCatalogEntry? { catalog.first { $0.entry.model.id == id }?.entry }

    /// Compatibility for a step, with the contract's rules and reasons.
    static func check(_ e: FakeCatalogEntry, step: ImageStep) -> CatalogModel {
        var m = e.model
        var reasons: [String] = []
        var warnings: [String] = []
        let needsImage: Set<ImageStep> = [.edit, .realism, .upscale, .dressA, .dressB]
        let needsPrompt: Set<ImageStep> = [.shot, .edit, .realism, .dressA, .dressB]
        if needsImage.contains(step) && e.images == "none" { reasons.append("needs an input image") }
        if needsPrompt.contains(step) && !e.prompt { reasons.append("needs a prompt") }
        if (step == .dressA || step == .dressB) && e.images == "single" { reasons.append("needs two or more input images") }
        if step == .shot && e.images == "none" { warnings.append("no reference images · faces may drift") }
        if step == .shot && e.images == "single" { warnings.append("one reference image only") }
        if step == .realism && !e.strength { warnings.append("no strength control") }
        if step == .upscale && !e.scale { warnings.append("no scale control") }
        m.compatible = reasons.isEmpty
        m.reasons = reasons
        m.warnings = warnings
        return m
    }

    static func mapping(_ e: FakeCatalogEntry) -> ModelMapping {
        var m = ModelMapping(prompt: e.prompt ? "prompt" : nil, seed: "seed")
        if e.images == "array" { m.image = ModelMapping.ImageField(field: "input_images", array: true, max: e.maxImages) }
        if e.images == "single" { m.image = ModelMapping.ImageField(field: "image", array: false, max: nil) }
        if e.scale { m.scale = ModelMapping.Scale(field: "scale_factor", kind: "number", values: nil) }
        if e.strength { m.strength = ModelMapping.Strength(field: "prompt_strength", min: 0, max: 1) }
        m.outputFormat = "output_format"
        return m
    }

    func requireOwner() throws { if !isOwner { throw ApiError.ownerOnly } }

    /// A member sending `models` gets owner_only.
    func checkOverrides(_ models: ModelOverrides?) throws {
        guard let models, !models.isEmpty else { return }
        try requireOwner()
        for (step, id) in models {
            guard let s = ImageStep(rawValue: step) else { throw ApiError("bad_request", "Unknown step \(step)") }
            guard let e = Self.catalogEntry(id) else { throw ApiError("not_found", "Model \(id) not found") }
            let c = Self.check(e, step: s)
            if c.compatible == false { throw ApiError("model_incompatible", "This model can't do \(s.label): \(c.reasons.joined(separator: ", "))") }
        }
    }

    func activeModel(_ id: String) throws -> MuseModel {
        let m = try model(id)
        if m.archived { throw ApiError.modelArchived }
        return m
    }

    func stepModelId(_ step: ImageStep, override: ModelOverrides? = nil) -> String {
        override?[step.rawValue] ?? stepModels[step]?.model ?? step.defaultModel
    }

    func stepPrice(_ step: ImageStep, override: ModelOverrides? = nil) -> PriceInfo? {
        Self.catalogEntry(stepModelId(step, override: override))?.model.price
    }

    func toolModelRefs(_ steps: [ImageStep]) -> [String: ToolModelRef] {
        Dictionary(uniqueKeysWithValues: steps.map { s in
            let id = stepModelId(s)
            return (s.rawValue, ToolModelRef(model: id, name: Self.catalogEntry(id)?.model.name ?? id))
        })
    }

    func stepModel(_ step: ImageStep) -> StepModel {
        let id = stepModelId(step)
        let e = Self.catalogEntry(id)
        let c = e.map { Self.check($0, step: step) }
        return StepModel(step: step, model: id, name: c?.name, official: c?.official ?? false, price: c?.price ?? .unknown, priceLine: c?.priceLine,
                         compatible: c?.compatible ?? true, reasons: c?.reasons ?? [], warnings: c?.warnings ?? [], mapping: e.map(Self.mapping) ?? ModelMapping(),
                         extra: stepModels[step]?.extra ?? [:])
    }

    // MARK: Image models (owner)

    public func imageModels() throws -> [StepModel] {
        try requireOwner()
        return ImageStep.allCases.map(stepModel)
    }

    public func setImageModel(step: ImageStep, _ req: SetImageModelRequest) throws -> StepModel {
        try requireOwner()
        guard let p = parseModelId(req.model), let e = Self.catalogEntry("\(p.owner)/\(p.name)") else { throw ApiError("not_found", "Model \(req.model) not found") }
        let c = Self.check(e, step: step)
        if c.compatible == false { throw ApiError("model_incompatible", "This model can't do \(step.label): \(c.reasons.joined(separator: ", "))") }
        let extra = req.extra ?? [:]
        if let problem = SetImageModelRequest.validate(extra: extra, inputs: e.inputs) { throw ApiError("bad_request", problem) }
        stepModels[step] = (e.model.id, extra)
        return stepModel(step)
    }

    public func resetImageModel(step: ImageStep) throws -> StepModel {
        try requireOwner()
        stepModels[step] = nil
        return stepModel(step)
    }

    public func imageModelCatalog(_ query: CatalogQuery) throws -> CatalogResponse {
        try requireOwner()
        let q = query.q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cols = query.step.collections
        var list = Self.catalog.filter { item in
            if !q.isEmpty {
                let m = item.entry.model
                return m.id.lowercased().contains(q) || m.description.lowercased().contains(q)
            }
            if let c = query.collection, !c.isEmpty { return item.collections.contains(c) }
            return !Set(item.collections).isDisjoint(with: cols)
        }.map { Self.check($0.entry, step: query.step) }
        if q.isEmpty { list.sort { $0.runCount > $1.runCount } } else { list = Array(list.prefix(20)) }
        return CatalogResponse(step: query.step.rawValue, collections: Self.collections.filter { cols.contains($0.slug) }, models: list, cachedAt: nowMs())
    }

    public func imageModelCollections() throws -> [CatalogCollectionRef] {
        try requireOwner()
        return Self.collections
    }

    public func imageModelDetail(id: String, step: ImageStep) throws -> ModelDetail {
        try requireOwner()
        guard let p = parseModelId(id), let e = Self.catalogEntry("\(p.owner)/\(p.name)") else { throw ApiError("not_found", "Model \(id) not found") }
        return ModelDetail(model: Self.check(e, step: step), mapping: Self.mapping(e), inputs: e.inputs, version: "demo-" + String(e.model.name.prefix(6)))
    }

    // MARK: Enhance and Dress up

    func enhanceSlots(_ m: MuseModel, _ req: EnhanceRequest) -> [SheetSlot] {
        let filled = m.filledSlots
        guard let want = req.slots, !want.isEmpty else { return filled }
        return filled.filter { want.contains($0.key) }
    }

    func enhanceEstimateValue(_ m: MuseModel, _ req: EnhanceRequest) -> ToolEstimate {
        ToolPricing.enhance(images: enhanceSlots(m, req).count, realism: req.realism, upscale: req.upscale,
                            realismPrice: stepPrice(.realism, override: req.models), upscalePrice: stepPrice(.upscale, override: req.models))
    }

    public func enhanceEstimate(modelId: String, _ req: EnhanceRequest) throws -> ToolEstimate {
        try checkOverrides(req.models)
        return enhanceEstimateValue(try model(modelId), req)
    }

    public func enhance(modelId: String, _ req: EnhanceRequest) throws -> ToolRun {
        try checkOverrides(req.models)
        let m = try activeModel(modelId)
        guard req.isValid else { throw ApiError("bad_request", "Turn on realism or upscale") }
        let slots = enhanceSlots(m, req)
        guard !slots.isEmpty else { throw ApiError("bad_request", "The character sheet has no images yet") }
        let est = enhanceEstimateValue(m, req)
        let items = slots.map { ToolItem(slot: $0.key, before: $0.image) }
        let models = isOwner ? Dictionary(uniqueKeysWithValues: ImageStep.enhanceSteps.map { ($0.rawValue, stepModelId($0, override: req.models)) }) : nil
        let run = ToolRun(id: "tr_" + shortId(), kind: "enhance", modelId: modelId,
                          options: ToolRunOptions(realism: req.realism ?? EnhanceFeatures.defaultRealism, upscale: req.upscale ?? EnhanceFeatures.defaultUpscale),
                          engines: ["a"], items: items, estimate: est.estimate, phase: "Starting", createdAt: nowMs(), models: models)
        return try startRun(run, perImage: ["a": est.perImage ?? 0])
    }

    func dressUpEstimateValue(_ m: MuseModel, engine: String?, models: ModelOverrides?) -> ToolEstimate {
        ToolPricing.dressUp(images: m.filledSlots.count, engine: engine, priceA: stepPrice(.dressA, override: models), priceB: stepPrice(.dressB, override: models))
    }

    public func dressUpEstimate(modelId: String, _ req: DressUpEstimateRequest) throws -> ToolEstimate {
        try checkOverrides(req.models)
        return dressUpEstimateValue(try model(modelId), engine: req.engine, models: req.models)
    }

    public func dressUp(modelId: String, _ req: DressUpRequest) throws -> ToolRun {
        try checkOverrides(req.models)
        let m = try activeModel(modelId)
        let engine = req.engine ?? DressUpFeatures.defaultEngine
        guard ["a", "b", "both"].contains(engine) else { throw ApiError("bad_request", "Pick Option A, Option B or Both") }
        guard req.outfitImage.asset != nil || req.outfitImage.url != nil else { throw ApiError("bad_request", "Drop an outfit photo first") }
        // The full-body front first, then every other filled slot.
        var slots = m.filledSlots
        guard !slots.isEmpty else { throw ApiError("bad_request", "The character sheet has no images yet") }
        if let i = slots.firstIndex(where: { $0.key == "front" }) { slots.insert(slots.remove(at: i), at: 0) }
        let est = dressUpEstimateValue(m, engine: engine, models: req.models)
        let engines = engine == "both" ? ["a", "b"] : [engine]
        let models = isOwner ? Dictionary(uniqueKeysWithValues: ImageStep.dressUpSteps.map { ($0.rawValue, stepModelId($0, override: req.models)) }) : nil
        let n = Double(max(1, slots.count))
        var per: [String: Double] = [:]
        if engines.contains("a") { per["a"] = ToolPricing.dressUpOption(images: slots.count, price: stepPrice(.dressA, override: req.models)) / n }
        if engines.contains("b") { per["b"] = ToolPricing.dressUpOption(images: slots.count, price: stepPrice(.dressB, override: req.models)) / n }
        let run = ToolRun(id: "tr_" + shortId(), kind: "dressup", modelId: modelId,
                          options: ToolRunOptions(engine: engine, name: req.name, outfitImage: req.outfitImage), engines: engines,
                          items: slots.map { ToolItem(slot: $0.key, before: $0.image) }, estimate: est.estimate, phase: "Starting", createdAt: nowMs(), models: models)
        return try startRun(run, perImage: per)
    }

    /// Holds the estimate and makes the images one after another.
    func startRun(_ run: ToolRun, perImage: [String: Double]) throws -> ToolRun {
        if run.estimate > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        charge(run.estimate)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        toolRuns.insert(run, at: 0)
        let fail = failNext
        failNext = false
        let id = run.id
        toolTasks[id] = Task { await self.driveRun(id, perImage: perImage, fail: fail) }
        return run
    }

    func runIndex(_ id: String) throws -> Int {
        guard let i = toolRuns.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Run not found") }
        return i
    }

    func emitTool(_ i: Int) { hub.emit(ApiEvent(type: "tool", tool: toolRuns[i])) }

    static func resultAsset(_ run: ToolRun, slot: String, engine: String, attempt: Int = 0) -> ImageRef {
        .asset("\(run.isEnhance ? "enh" : "dress\(engine)")_\(slot)" + (attempt > 0 ? "_r\(attempt)" : ""))
    }

    private func driveRun(_ id: String, perImage: [String: Double], fail: Bool) async {
        guard let start = toolRuns.firstIndex(where: { $0.id == id }) else { return }
        let total = toolRuns[start].items.count
        let verb = toolRuns[start].isEnhance ? "Enhancing" : "Dressing up"
        for n in 0..<total {
            guard let i = toolRuns.firstIndex(where: { $0.id == id }), toolRuns[i].isRunning else { return }
            toolRuns[i].items[n].state = "running"
            toolRuns[i].phase = "\(verb) · \(n + 1) of \(total)"
            toolRuns[i].progress = Double(n) / Double(total) * 100
            emitTool(i)
            try? await Task.sleep(nanoseconds: UInt64(genDelay * 1_000_000_000))
            guard let j = toolRuns.firstIndex(where: { $0.id == id }), toolRuns[j].isRunning else { return }
            if fail && n == min(1, total - 1) {
                // Nothing made from here on is billed: release the rest of the hold.
                let spent = toolRuns[j].cost
                refund(max(0, toolRuns[j].estimate - spent))
                toolRuns[j].items[n].state = "failed"
                toolRuns[j].state = "failed"
                toolRuns[j].error = MemberText.wentWrong
                toolRuns[j].phase = "Failed"
                toolRuns[j].finishedAt = nowMs()
                hub.emit(ApiEvent(type: "balance", balance: bal))
                emitTool(j)
                return
            }
            var item = toolRuns[j].items[n]
            for e in toolRuns[j].engines {
                item.results[e] = Self.resultAsset(toolRuns[j], slot: item.slot, engine: e)
                item.cost += perImage[e] ?? 0
            }
            item.state = "done"
            toolRuns[j].items[n] = item
            toolRuns[j].cost += item.cost
            emitTool(j)
        }
        guard let k = toolRuns.firstIndex(where: { $0.id == id }), toolRuns[k].isRunning else { return }
        // Settle to the exact cost (the demo's exact cost is its estimate).
        let diff = toolRuns[k].estimate - toolRuns[k].cost
        if diff > 1e-9 { refund(diff) } else if diff < -1e-9 { charge(-diff) }
        toolRuns[k].state = "review"
        toolRuns[k].progress = 100
        toolRuns[k].phase = "Ready to review"
        toolRuns[k].finishedAt = nowMs()
        toolTasks[id] = nil
        hub.emit(ApiEvent(type: "balance", balance: bal))
        emitTool(k)
    }

    public func listToolRuns(_ query: ToolRunQuery) -> [ToolRun] {
        Array(toolRuns.filter { r in (query.modelId.map { r.modelId == $0 } ?? true) && (query.kind.map { r.kind == $0 } ?? true) }.prefix(20))
    }

    public func toolRun(id: String) throws -> ToolRun { toolRuns[try runIndex(id)] }

    public func decideToolItem(runId: String, slot: String, _ req: ToolDecisionRequest) throws -> ToolRun {
        let i = try runIndex(runId)
        guard toolRuns[i].isReview else { throw ApiError("bad_request", "This run isn't ready to review") }
        guard let n = toolRuns[i].items.firstIndex(where: { $0.slot == slot }) else { throw ApiError("not_found", "No such image") }
        var item = toolRuns[i].items[n]
        switch req.decision {
        case "keep":
            let pick = req.pick ?? item.pick ?? (item.results.a != nil ? "a" : "b")
            guard item.results[pick] != nil else { throw ApiError("bad_request", "There's no result to keep") }
            item.decision = "keep"
            item.pick = pick
        case "reject":
            item.decision = "reject"
        default:
            throw ApiError("bad_request", "Keep or reject")
        }
        toolRuns[i].items[n] = item
        emitTool(i)
        return toolRuns[i]
    }

    public func pickToolRun(runId: String, pick: String) throws -> ToolRun {
        let i = try runIndex(runId)
        guard toolRuns[i].isReview else { throw ApiError("bad_request", "This run isn't ready to review") }
        guard pick == "a" || pick == "b" else { throw ApiError("bad_request", "Pick a or b") }
        for n in toolRuns[i].items.indices where toolRuns[i].items[n].results[pick] != nil {
            toolRuns[i].items[n].decision = "keep"
            toolRuns[i].items[n].pick = pick
        }
        emitTool(i)
        return toolRuns[i]
    }

    public func retryToolItem(runId: String, slot: String, engine: String?) throws -> ToolRun {
        let i = try runIndex(runId)
        guard toolRuns[i].isReview else { throw ApiError("bad_request", "This run isn't ready to review") }
        guard let n = toolRuns[i].items.firstIndex(where: { $0.slot == slot }) else { throw ApiError("not_found", "No such image") }
        let e = engine ?? toolRuns[i].engines.first ?? "a"
        guard toolRuns[i].engines.contains(e) else { throw ApiError("bad_request", "That option didn't run") }
        let run = toolRuns[i]
        let price: Double
        if run.isEnhance {
            price = ToolPricing.enhancePerImage(realism: run.options.realism, upscale: run.options.upscale,
                                                realismPrice: Self.catalogEntry(run.models?["realism"] ?? stepModelId(.realism))?.model.price,
                                                upscalePrice: Self.catalogEntry(run.models?["upscale"] ?? stepModelId(.upscale))?.model.price)
        } else {
            let step: ImageStep = e == "b" ? .dressB : .dressA
            price = ToolPricing.prediction(Self.catalogEntry(run.models?[step.rawValue] ?? stepModelId(step))?.model.price, inputImages: slot == "front" ? 2 : 3)
        }
        if price > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        charge(price)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        toolRuns[i].items[n].state = "running"
        toolRuns[i].items[n].decision = "pending"
        emitTool(i)
        let attempt = (toolRuns[i].items[n].results[e]?.asset?.components(separatedBy: "_r").last.flatMap { Int($0) } ?? 0) + 1
        Task { [genDelay] in
            try? await Task.sleep(nanoseconds: UInt64(genDelay * 1_000_000_000))
            self.finishRetry(runId, slot: slot, engine: e, attempt: attempt, cost: price)
        }
        return toolRuns[i]
    }

    private func finishRetry(_ runId: String, slot: String, engine: String, attempt: Int, cost: Double) {
        guard let i = toolRuns.firstIndex(where: { $0.id == runId }), let n = toolRuns[i].items.firstIndex(where: { $0.slot == slot }) else { return }
        toolRuns[i].items[n].results[engine] = Self.resultAsset(toolRuns[i], slot: slot, engine: engine, attempt: attempt)
        toolRuns[i].items[n].state = "done"
        toolRuns[i].items[n].decision = "pending"
        toolRuns[i].items[n].cost += cost
        toolRuns[i].cost += cost
        emitTool(i)
    }

    public func applyToolRun(runId: String, _ req: ToolApplyRequest) throws -> ToolApplyResponse {
        let i = try runIndex(runId)
        let run = toolRuns[i]
        guard run.isReview else { throw ApiError("bad_request", "This run isn't ready to apply") }
        let kept = run.items.filter { $0.isKept && $0.after != nil }
        guard !kept.isEmpty else { throw ApiError("bad_request", "Keep at least one image first") }
        var m = try model(run.modelId)
        var outfit: Outfit?
        if run.isEnhance {
            saveVersion(m, reason: "enhance")
            for item in kept {
                let ref = item.pick.flatMap { item.results[$0] } ?? item.after
                if let s = m.slots.firstIndex(where: { $0.key == item.slot }) { m.slots[s] = SheetSlot(key: item.slot, image: ref, source: "generated") }
            }
            replace(m)
        } else {
            func pick(_ slot: String) -> ImageRef? {
                guard let item = kept.first(where: { $0.slot == slot }) else { return nil }
                return item.pick.flatMap { item.results[$0] } ?? item.after
            }
            let name = req.name ?? run.options.name ?? "Dressed look"
            let o = Outfit(id: "o_" + shortId(), modelId: m.id, name: name, mode: "dressup", description: "Dressed up from an outfit photo",
                           angles: ["front", "tq", "side", "back"].map(pick), state: "ready", faces: ["face", "faceTq", "profile"].map(pick))
            outfits.append(o)
            m.outfitIds.append(o.id)
            replace(m)
            toolRuns[i].outfitId = o.id
            outfit = o
            hub.emit(ApiEvent(type: "outfit", outfit: o))
        }
        toolRuns[i].state = "applied"
        toolRuns[i].appliedAt = nowMs()
        hub.emit(ApiEvent(type: "model", model: m))
        emitTool(i)
        return ToolApplyResponse(run: toolRuns[i], model: m, outfit: outfit)
    }

    public func discardToolRun(runId: String) throws {
        let i = try runIndex(runId)
        if toolRuns[i].isRunning {
            toolTasks[runId]?.cancel()
            toolTasks[runId] = nil
            // Images not made yet are released from the hold.
            refund(max(0, toolRuns[i].estimate - toolRuns[i].cost))
            hub.emit(ApiEvent(type: "balance", balance: bal))
        }
        toolRuns[i].state = "discarded"
        emitTool(i)
    }

    func saveVersion(_ m: MuseModel, reason: String) {
        var list = sheetVersionsByModel[m.id] ?? []
        list.insert(SheetVersion(id: "sv_" + shortId(), createdAt: nowMs(), reason: reason, slots: m.slots), at: 0)
        sheetVersionsByModel[m.id] = Array(list.prefix(10))
    }

    public func sheetVersions(modelId: String) throws -> [SheetVersion] {
        _ = try model(modelId)
        return sheetVersionsByModel[modelId] ?? []
    }

    public func restoreSheetVersion(modelId: String, versionId: String) throws -> MuseModel {
        var m = try model(modelId)
        guard let v = sheetVersionsByModel[modelId]?.first(where: { $0.id == versionId }) else { throw ApiError("not_found", "Version not found") }
        saveVersion(m, reason: "restore")
        m.slots = v.slots
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
        return m
    }

    // MARK: Archive (owner)

    public func archiveModel(id: String) throws -> MuseModel {
        try requireOwner()
        var m = try model(id)
        m.archived = true
        m.archivedAt = nowMs()
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
        return m
    }

    public func unarchiveModel(id: String) throws -> MuseModel {
        try requireOwner()
        var m = try model(id)
        m.archived = false
        m.archivedAt = nil
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
        return m
    }

    public func listArchivedModels() throws -> [MuseModel] {
        try requireOwner()
        return models.filter(\.archived).sorted { ($0.archivedAt ?? 0) > ($1.archivedAt ?? 0) }
    }
}
