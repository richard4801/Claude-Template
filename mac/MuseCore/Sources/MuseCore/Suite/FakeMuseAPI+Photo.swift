import Foundation

// AI suite · the Photo tool in demo mode (workstream 3): the server's suite/photo.ts on the fake. The estimate is priced
// like the fake's shoot preview (count × per photo, references counted), the rig check is the still rules of the
// FakeRigCheck port, and Generate runs the fake shoot and saves the stills as "Photo · …" takes. Nothing real is spent.

extension FakeMuseAPI {
    /// The shoot the Photo request runs on (the server's `photoPlan`): a template shoot with a preset, else a plain one.
    func photoShoot(_ r: PhotoRequest) throws -> ShootRequest {
        if let p = r.problem { throw ApiError("bad_request", p) }
        let m = try activeModel(r.modelId)
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
        let shots = try await shoot(try photoShoot(req))
        let ids = Set(shots.map(\.id))
        let titled = { (t: Take) -> Take in
            var x = t
            let rest = t.title.replacingOccurrences(of: "Shoot · ", with: "").replacingOccurrences(of: "Template · ", with: "")
            x.title = "Photo · \(rest)"
            return x
        }
        for i in takes.indices where ids.contains(takes[i].id) { takes[i] = titled(takes[i]) }
        return shots.map(titled)
    }
}

private extension ShotRequest {
    func withGrade(_ on: Bool?) -> ShotRequest {
        var r = self
        if on == false { r.gradeLook = false }
        return r
    }
}
