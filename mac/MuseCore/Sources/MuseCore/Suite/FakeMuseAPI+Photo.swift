import Foundation

// AI suite · the Photo tool in demo mode (workstream 3): the server's suite/photo.ts on the fake. The estimate is priced
// like the fake's shoot preview (count × per photo, references counted), the rig check is the still rules of the
// FakeRigCheck port, and Generate runs the fake shoot and saves the stills as "Photo · …" takes. Nothing real is spent.

extension FakeMuseAPI {
    /// The shoot the Photo request runs on (the server's `photoPlan`): a template shoot with a preset, else a plain one.
    func photoShoot(_ r: PhotoRequest) throws -> ShootRequest {
        if let p = r.problem { throw ApiError("bad_request", p) }
        // The owner's photo model (server suite/photo.ts): owners only.
        if r.imageModel != nil, !suiteIsOwner { throw ApiError("owner_only", "Only the studio owner can pick the photo model") }
        // No character (owner 2026-11-11): a reference image is needed and no preset; the demo renders on the sample model.
        if r.modelId == nil && r.presetId != nil { throw ApiError("bad_request", "Presets need a character · pick one with @") }
        if r.modelId == nil && (r.references ?? []).isEmpty { throw ApiError("bad_request", "Pick a character or add an image") }
        let m = try activeModel(r.modelId ?? SampleData.demo)
        let outfit = r.outfitId ?? m.outfitIds.first ?? ""
        if let pid = r.presetId {
            return .template(pid, modelId: m.id, outfitId: outfit, shuffleSeed: r.shuffleSeed, lockSeed: r.lockSeed ?? false, productImage: r.productImage,
                             refs: r.references ?? [], count: r.count)
        }
        let scene = r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = ShootRequest(modelId: m.id, outfitId: outfit, scene: scene.isEmpty ? nil : scene, prompt: nil, seed: r.seed, count: r.count)
        s.refs = r.references.flatMap { $0.isEmpty ? nil : $0 }
        s.lockSeed = r.lockSeed
        return s
    }

    /// The server's notes on what a still leaves out.
    static func photoWarnings(_ r: PhotoRequest) -> [String] {
        var out: [String] = []
        guard let c = r.camera else { return out }
        if c.move != nil || c.mix != nil { out.append("Movement doesn’t apply to photos") }
        if c.style?.tempo != nil { out.append("Tempo doesn’t apply to photos") }
        if r.presetId != nil && (c.rig != nil || c.lighting != nil || c.palette != nil || c.angle != nil || c.style != nil) {
            out.append("The preset sets its own camera and light")
        }
        return out
    }

    public func suitePhotoEstimate(_ req: PhotoRequest) async throws -> PhotoEstimate {
        let shoot = try photoShoot(req)
        let preview = try shootPreviewNow(shoot)
        let count = max(1, min(PhotoRequest.maxCount, req.count))
        let still = req.camera.map { c -> CameraSpec in var s = c; s.move = nil; s.mix = nil; return s }
        let rig = PhotoRig.still(FakeRigCheck.check(prompt: req.prompt, camera: still, speaking: false))
        let look = SuiteLooks.look(for: ShotRequest(camera: req.camera).withGrade(req.gradeLook), camera: SuiteDemoCatalog.catalog.camera)
        let preset = req.presetId.flatMap { id in templates.first { $0.id == id } }.map { PhotoPresetRef(id: $0.id, name: $0.name) }
        return PhotoEstimate(count: count, perPhoto: preview.estimate / Double(count), estimate: preview.estimate, warnings: Self.photoWarnings(req), rig: rig,
                             look: look, prompt: preset == nil ? preview.text : nil, preset: preset)
    }

    public func suiteCreatePhotos(_ req: PhotoRequest) async throws -> [Take] {
        try suiteCheckDraft(req.draft) // AI suite (workstream 1): a bad draft is refused before anything is held
        let shots = try await shoot(try photoShoot(req))
        let ids = Set(shots.map(\.id))
        for id in ids { suiteTakeModels[id] = req.modelId }
        let titled = { (t: Take) -> Take in
            var x = t
            let rest = t.displayTitle.replacingOccurrences(of: "Photo · ", with: "").replacingOccurrences(of: "Template · ", with: "")
            x.title = "Photo · \(rest)"
            x.draft = req.draft // every still keeps the draft ("Reuse settings")
            return x
        }
        for i in takes.indices where ids.contains(takes[i].id) { takes[i] = titled(takes[i]) }
        return shots.map(titled)
    }

    /// WS19: the run as a job, like the server's `async: true`: the job comes back running once the price would be held,
    /// `job` events follow, and the last one carries the stills.
    public func suiteStartPhotos(_ req: PhotoRequest) async throws -> Job {
        try suiteCheckDraft(req.draft)
        let shoot = try photoShoot(req)
        let cost = try shootPreviewNow(shoot).estimate
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        let m = try activeModel(req.modelId ?? SampleData.demo)
        let count = max(1, min(PhotoRequest.maxCount, req.count))
        var jr = JobRequest(title: "", modelId: m.id, outfitId: req.outfitId ?? "", clipId: "", engine: "photo", takes: count)
        jr.title = "Photo · \(PhotoEstimate.photos(count))"
        var j = Job(id: "jp_" + shortId(), title: jr.title, modelId: m.id, modelName: m.name, outfitId: jr.outfitId, request: jr, state: "running", progress: 2,
                    totalSteps: count, phase: count > 1 ? "Making photo 1 of \(count)" : "Making your photo", cost: cost, createdAt: nowMs(),
                    prompt: req.prompt, thumb: m.cover)
        j.engineText = "Photo"
        j.draft = req.draft
        jobs.append(j)
        hub.emit(ApiEvent(type: "job", job: j))
        let id = j.id
        Task { await self.finishPhotos(id, req) }
        return j
    }

    private func finishPhotos(_ id: String, _ req: PhotoRequest) async {
        do {
            let shots = try await suiteCreatePhotos(req)
            guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isActive else { return }
            jobs[i].state = "done"
            jobs[i].progress = 100
            jobs[i].step = shots.count
            jobs[i].phase = "Done"
            jobs[i].finishedAt = nowMs()
            jobs[i].thumb = shots.first?.thumb ?? jobs[i].thumb
            jobs[i].takeIds = shots.map(\.id)
            hub.emit(ApiEvent(type: "job", job: jobs[i], takes: shots))
        } catch {
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[i].state = "failed"
            jobs[i].phase = "Failed"
            jobs[i].error = (error as? ApiError)?.friendlyMessage ?? MemberText.wentWrong
            jobs[i].refunded = jobs[i].cost
            jobs[i].finishedAt = nowMs()
            hub.emit(ApiEvent(type: "job", job: jobs[i]))
        }
    }
}

private extension ShotRequest {
    func withGrade(_ on: Bool?) -> ShotRequest {
        var r = self
        if on == false { r.gradeLook = false }
        return r
    }
}
