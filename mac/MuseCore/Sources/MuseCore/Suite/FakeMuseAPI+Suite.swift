import Foundation

// AI suite (workstream 1): demo mode's /v1/suite. Same shapes and wording as server/api in mock mode: the catalog (bundled
// copy), estimates with the real labels and caps, shots that run on the fake job pipeline (live `job` events, takes labelled
// with the tier), Recast, and the owner's settings. Nothing is spent beyond the demo balance.

/// The demo's prices per output second, per tier (the default ladders' first steps).
enum FakeSuitePrices {
    struct Tier { let resolution: String; let perSec: Double; let maxSeconds: Int; let model: String; let name: String; let provider: String }
    static let shot: [String: Tier] = [
        "draft": Tier(resolution: "768P", perSec: 0.02, maxSeconds: 15, model: "h3-lite", name: "MiniMax H3 Lite", provider: "replicate"),
        "standard": Tier(resolution: "768P", perSec: 0.08, maxSeconds: 15, model: "h3", name: "MiniMax H3", provider: "replicate"),
        "hd": Tier(resolution: "2K", perSec: 0.13, maxSeconds: 15, model: "h3", name: "MiniMax H3", provider: "replicate"),
        "cinema": Tier(resolution: "1080p", perSec: 0.141, maxSeconds: 30, model: "kling-v4", name: "Kling 4.0", provider: "replicate"),
    ]
    static let recast: [String: Tier] = [
        "draft": Tier(resolution: "480p", perSec: 0.05, maxSeconds: 30, model: "wan-2.2-animate", name: "Wan 2.2 Animate", provider: "replicate"),
        "standard": Tier(resolution: "720p", perSec: 0.1, maxSeconds: 30, model: "kling-o1", name: "Kling O1", provider: "replicate"),
        "hd": Tier(resolution: "1080p", perSec: 0.45, maxSeconds: 30, model: "h3-max-recast", name: "MiniMax H3 Max Recast", provider: "fal"),
        "cinema": Tier(resolution: "1080p", perSec: 0.45, maxSeconds: 30, model: "h3-max-recast", name: "MiniMax H3 Max Recast", provider: "fal"),
    ]
    static let capPerJob = 5.0
    static let capPerDay = 25.0
}

extension FakeMuseAPI {
    /// Demo mode: the file stays on this Mac; the slot gets a demo storage key.
    public func uploadSuiteMedia(_ file: URL, contentType: String, progress: UploadProgress?) async throws -> SuiteVideoRef {
        progress?(0)
        let ext = file.pathExtension.isEmpty ? (contentType.hasPrefix("audio/") ? "m4a" : "mp4") : file.pathExtension
        progress?(1)
        return SuiteVideoRef(key: "c/demo_\(shortId()).\(ext)")
    }

    public func suiteCatalog() async throws -> SuiteCatalog {
        var c = SuiteDemoCatalog.catalog
        c.enabled = true
        c.test = true
        if !suiteIsOwner { c.tiers = c.tiers.map { var t = $0; t.models = nil; return t } }
        return c
    }

    public func suiteCamera() async throws -> CameraCatalog { SuiteDemoCatalog.catalog.camera }

    public func suiteCompileCamera(_ req: CameraCompileRequest) async throws -> CameraCompiled {
        let c = SuiteDemoCatalog.catalog.camera
        let words = CameraSummary.parts(req.camera, c)
        let text = words.isEmpty ? "" : "Camera: " + words.joined(separator: ", ").lowercased() + "."
        return CameraCompiled(text: text, moves: [req.camera.move?.id, req.camera.mix?.id].compactMap { $0 }, engine: suiteIsOwner ? FakeSuitePrices.shot[req.quality ?? "draft"]?.name : nil)
    }

    /// The plan the demo makes for a request: label, seconds, price, warnings.
    func suitePlan(_ r: ShotRequest) throws -> ShotEstimate {
        let tier = SuiteText.tierIds.contains(r.quality) ? r.quality : "draft"
        if r.takes < 1 || r.takes > 4 { throw ApiError("bad_request", "Invalid shot: takes must be 1–4") }
        if r.engineModel != nil || r.resolution != nil, !suiteIsOwner { throw ApiError("owner_only", "Only the studio owner can pick the engine") }
        let mode = r.mode ?? (r.frames?.start != nil || r.frames?.end != nil ? "image" : r.modelId != nil ? "reference" : "text")
        var warnings: [String] = []
        let kind: String
        let p: FakeSuitePrices.Tier
        var seconds: Double
        var cast: [SuiteCastLine]?
        switch mode {
        case "recast", "swap":
            guard let id = r.clipId, let clip = suiteClip(id) else { throw ApiError("not_found", "Clip not found") }
            if mode == "recast" {
                guard let list = r.cast, !list.isEmpty else { throw ApiError("bad_request", "Pick who to recast") }
                if list.count > 4 { throw ApiError("bad_request", "Invalid shot: cast at most 4 people") }
                let hints = list.compactMap { $0.personIndex.map(String.init) ?? $0.personHint }
                if Set(hints).count < hints.count { throw ApiError("bad_request", "Two entries are for the same person") }
                for m in list { _ = try model(m.characterId) }
                cast = list.enumerated().map { i, m in
                    SuiteCastLine(characterId: m.characterId, outfitId: m.outfitId, who: Self.whoWords(m, index: i), speaking: m.speaking.map { $0 ? "yes" : "no" } ?? (list.count == 1 ? "no" : "unknown"))
                }
            }
            kind = mode == "recast" ? "Recast" : "Swap"
            p = FakeSuitePrices.recast[tier]!
            seconds = max(5, min(30, clip.durationSec.rounded()))
            if clip.durationSec > 15 && mode == "recast" { warnings.append("no single shot in the clip may be longer than 15 s") }
        default:
            kind = "Shot"
            if let m = r.modelId { _ = try model(m) }
            p = FakeSuitePrices.shot[tier]!
            if r.duration > p.maxSeconds {
                throw ApiError("nothing_fits", "\(SuiteText.tierLabel(tier)) can't make this shot · try another quality, a shorter length or fewer references")
            }
            seconds = Double(max(4, min(p.maxSeconds, r.duration)))
            if Int(seconds) != r.duration { warnings.append("length set to \(Int(seconds)) s (this quality makes 4–\(p.maxSeconds) s)") }
        }
        let est = ((p.perSec * seconds * Double(r.takes)) * 10000).rounded() / 10000
        let shown = (est * 100).rounded() / 100
        let spent = bal.today ?? 0
        var caps = SuiteCaps(perJob: FakeSuitePrices.capPerJob, perDay: FakeSuitePrices.capPerDay, spentToday: (spent * 100).rounded() / 100,
                             leftToday: max(0, ((FakeSuitePrices.capPerDay - spent) * 100).rounded() / 100))
        if est > caps.perJob + 1e-9 {
            caps.ok = false
            caps.code = "suite_over_job_limit"
            caps.message = "Over the studio's \(Pricing.money(caps.perJob)) per-shot limit"
        } else if spent + est > caps.perDay + 1e-9 {
            caps.ok = false
            caps.code = "suite_over_day_limit"
            caps.message = "Over the studio's \(Pricing.money(caps.perDay)) daily AI suite limit · \(Pricing.money(caps.leftToday)) left today"
        }
        var moves = [r.camera?.move?.id, r.camera?.mix?.id].compactMap { $0 }
        if moves.count > 1, !SuiteMoves.canMix(moves[0], moves[1], SuiteDemoCatalog.catalog.camera) {
            warnings.append("one camera move per shot: \(moves[1]) dropped")
            moves = [moves[0]]
        }
        let speaking = r.speaking ?? false
        var e = ShotEstimate(quality: tier, label: SuiteText.shotLabel(tier, resolution: p.resolution, kind: kind), resolution: p.resolution, seconds: seconds,
                             takes: r.takes, mode: mode, estimate: shown, priceLine: SuiteText.priceLine(shown, seconds: seconds, takes: r.takes),
                             buttonLabel: SuiteText.buttonLabel(shown, seconds: seconds, takes: r.takes), ok: caps.ok, code: caps.code, message: caps.message, caps: caps,
                             warnings: warnings, camera: SuiteEstimateCamera(moves: moves), prompt: suitePrompt(r), test: true,
                             speaking: SuiteSpeaking(speaking: speaking, source: r.speaking == nil ? "default" : "switch"), cast: cast,
                             keepAudio: mode == "recast" || mode == "swap" ? (r.keepAudio ?? true) : nil)
        e.look = SuiteLooks.look(for: r, camera: SuiteDemoCatalog.catalog.camera)
        e.rig = mode == "recast" || mode == "swap" ? [] : FakeRigCheck.check(prompt: r.prompt, camera: r.camera, speaking: speaking)
        if suiteIsOwner {
            e.engine = SuiteEngine(model: p.model, name: p.name, provider: p.provider, resolution: p.resolution, perSec: p.perSec, billedPerTake: seconds, test: true)
        }
        return e
    }

    static func whoWords(_ m: CastMember, index: Int) -> String {
        if let n = m.personNote, !n.isEmpty { return n }
        switch m.personHint {
        case "left": return "the person on the left"
        case "right": return "the person on the right"
        case "center": return "the person in the centre"
        case "foreground": return "the person in the foreground"
        case "background": return "the person in the background"
        default:
            let ord = ["first", "second", "third", "fourth"]
            let i = (m.personIndex ?? index + 1) - 1
            return "the \(ord[max(0, min(3, i))]) person (from the left, or to appear)"
        }
    }

    /// A short member-safe prompt (the server's suite.shot script is richer; this is the demo's).
    func suitePrompt(_ r: ShotRequest) -> String {
        let who = r.modelId.flatMap { id in models.first { $0.id == id } }
        var lines: [String] = []
        if let m = who { lines.append("\(m.name) is the woman shown in the character sheet. Keep her face, hair, skin and body exactly as in those images.") }
        if !r.prompt.isEmpty { lines.append(r.prompt) }
        let cam = CameraSummary.parts(r.camera ?? CameraSpec(), SuiteDemoCatalog.catalog.camera)
        if !cam.isEmpty { lines.append("Cinematography: " + cam.joined(separator: ", ") + ".") }
        lines.append("Photorealistic. No text, captions, logos or watermarks anywhere.")
        return lines.joined(separator: "\n")
    }

    public func suiteEstimate(_ req: ShotRequest) async throws -> ShotEstimate { try suitePlan(req) }

    /// The rig check alone: no character, engine or price needed (swap and recast have none).
    public func suiteRigCheck(_ req: ShotRequest) async throws -> [RigWarning] {
        if req.mode == "swap" || req.mode == "recast" { return [] }
        return FakeRigCheck.check(prompt: req.prompt, camera: req.camera, speaking: req.speaking ?? false)
    }

    /// Demo mode's locations reuse demo stills.
    static let demoLocations: [SuiteLocation] = [
        SuiteLocation(id: "loc_demo_living", name: "Living room", image: .asset("vid_living"), createdAt: 1_762_300_000_000),
        SuiteLocation(id: "loc_demo_bath", name: "Bathroom", image: .asset("vid_bath"), createdAt: 1_762_300_060_000),
    ]

    public func suiteLocations() async throws -> [SuiteLocation] { suiteLocationList.sorted { $0.createdAt > $1.createdAt } }

    public func createSuiteLocation(_ new: NewSuiteLocation) async throws -> SuiteLocation {
        guard let name = ComposerLocations.cleanName(new.name) else { throw ApiError("bad_request", "Give the location a name") }
        guard new.image.url != nil || new.image.asset != nil else { throw ApiError("bad_request", "Pick a photo of the place") }
        let l = SuiteLocation(id: "loc_" + shortId(), name: name, image: new.image, createdAt: Double(nowMs()))
        suiteLocationList.append(l)
        return l
    }

    public func deleteSuiteLocation(id: String) async throws {
        guard suiteLocationList.contains(where: { $0.id == id }) else { throw ApiError("not_found", "Location not found") }
        suiteLocationList.removeAll { $0.id == id }
    }

    public func suiteCreateShot(_ req: ShotRequest) async throws -> Job {
        if req.mode == "swap" {
            // The existing character swap (POST /v1/jobs, engine replicate; Cinema → HD).
            guard let mid = req.modelId, let cid = req.clipId else { throw ApiError("bad_request", "Pick a character and a clip") }
            let m = try model(mid)
            let outfit = req.outfitId ?? m.outfitIds.first ?? ""
            let q = VideoQuality(rawValue: req.quality == "cinema" ? "hd" : req.quality) ?? .draft
            return try createJob(JobRequest.replicate(title: req.title ?? "\(m.name) · swap", modelId: mid, outfitId: outfit, clipId: cid, quality: q, takes: req.takes,
                                                      keepAudio: req.keepAudio ?? true, clipSeconds: suiteClip(cid)?.durationSec))
        }
        let e = try suitePlan(req)
        if !e.ok { throw ApiError(e.code ?? "suite_over_job_limit", e.message ?? "Over the studio's limits") }
        let lead = req.modelId ?? req.cast?.first?.characterId
        let m = lead.flatMap { id in models.first { $0.id == id } }
        let outfitId = req.outfitId ?? req.cast?.first?.outfitId ?? ""
        let title = req.title ?? (e.mode == "recast" ? "Recast" : m.map { "\($0.name) · shot" } ?? "Shot")
        var jr = JobRequest(title: title, modelId: lead ?? "", outfitId: outfitId, clipId: req.clipId ?? "", engine: "suite", steps: Pricing.stepsDefault,
                            use: ClipUse.full.rawValue, takes: req.takes, keepAudio: req.keepAudio ?? true, clipSeconds: e.seconds, quality: e.quality, speaking: req.speaking)
        jr.speakingSource = req.speaking == nil ? "default" : "switch"
        let total = Pricing.totalSeconds(jr.spec)
        var j = Job(id: "jl_" + shortId(), title: title, modelId: lead ?? "", modelName: m?.name ?? "", outfitId: outfitId, request: jr, state: "queued",
                    phase: MemberText.waitingToStart, secondsLeft: total, totalSeconds: total, cost: e.estimate, createdAt: nowMs(), prompt: e.prompt ?? "",
                    seed: Int64.random(in: 1000...99999), thumb: outfits.first { $0.id == outfitId }?.front ?? m?.cover)
        j.engineText = e.label
        if let look = e.look { suiteLooks[j.id] = look }
        return try enqueueSuiteJob(j)
    }

    public func suiteShot(id: String) async throws -> SuiteShot {
        guard let j = jobs.first(where: { $0.id == id }), j.request.engine == "suite" else { throw ApiError("not_found", "Shot not found") }
        var engine: SuiteEngine?
        if suiteIsOwner, let p = (j.engineText?.hasPrefix("Recast") == true ? FakeSuitePrices.recast : FakeSuitePrices.shot)[j.request.quality ?? "draft"] {
            engine = SuiteEngine(model: p.model, name: p.name, provider: p.provider, resolution: p.resolution, perSec: p.perSec, test: true)
        }
        return SuiteShot(job: j, warnings: [], engine: engine)
    }

    public func suiteSettings() async throws -> SuiteSettings {
        guard suiteIsOwner else { throw ApiError("owner_only", "Only the studio owner can do that") }
        if let s = suiteSettingsBox { return s }
        guard var s = SuiteDemoCatalog.settings else { throw ApiError("not_found", "No suite settings") }
        s.spentToday = ((bal.today ?? 0) * 100).rounded() / 100
        return s
    }

    public func updateSuiteSettings(_ patch: SuiteSettingsPatch) async throws -> SuiteSettings {
        var s = try await suiteSettings()
        for (id, p) in patch.models ?? [:] {
            guard let i = s.models.firstIndex(where: { $0.id == id }) else { throw ApiError("bad_request", "Unknown model \(id)") }
            if let on = p.enabled {
                if on && (s.models[i].blocked || s.models[i].status == "removed") {
                    throw ApiError("model_blocked", "\(s.models[i].name) can't be switched on (\(s.models[i].status == "removed" ? "removed" : "licence"))")
                }
                s.models[i].enabled = on
            }
            if let a = p.acknowledge { s.models[i].needsAck = !a && s.models[i].needsAck }
            if let k = p.priceScale {
                guard k >= 0.5 && k <= 3 else { throw ApiError("bad_request", "priceScale: 0.5–3") }
                s.models[i].priceScale = k
            }
        }
        if let v = patch.capPerJob { s.caps.perJob = v }
        if let v = patch.capPerDay { s.caps.perDay = v }
        suiteSettingsBox = s
        return s
    }
}
