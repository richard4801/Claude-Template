import Foundation

// Edit suite (workstream 3) in demo mode: the Editor v2 AI helpers answer like the server's mock (a sample transcript,
// silence/filler cuts from it, a 120 BPM beat grid, the take itself as the "cut-out" and "voice"), after a short wait.
// Free here, like the mock in production.
extension FakeMuseAPI {
    static let sampleTranscript = "I always um order the oat flat white and like they remember my name you know this place is unreal honestly the light in here uh ten out of ten go"

    func editorSourceDuration(_ s: EditorSource) throws -> Double {
        if let id = s.takeId {
            guard let t = takes.first(where: { $0.id == id }) else { throw ApiError("not_found", "Take not found") }
            return t.durationSec ?? 8
        }
        if let d = s.durationSec, d > 0 { return d }
        throw ApiError("bad_request", "source: a take or an upload with its length")
    }

    /// Words of the sample transcript spread over the media, with a long pause after "white" and after "unreal".
    static func mockWords(duration d: Double) -> [EditV2.Word] {
        let texts = sampleTranscript.split(separator: " ").map(String.init)
        let slot = max(0.2, (d - 2.6) / Double(texts.count))
        var t = 0.2
        var out: [EditV2.Word] = []
        for (i, w) in texts.enumerated() {
            let len = slot * 0.8
            if t + len > d { break }
            out.append(EditV2.Word(text: w, startSec: EditV2.r3(t), endSec: EditV2.r3(t + len), score: 0.9))
            t += slot
            if w == "white" { t += 1.4 }
            if w == "unreal" { t += 0.9 }
            _ = i
        }
        return out
    }

    /// Takes the app made up for a check (the Mac's Edit check), so the editor jobs on them find their source.
    public func adoptTakes(_ ts: [Take]) {
        for t in ts where !takes.contains(where: { $0.id == t.id }) { takes.append(t) }
    }

    /// Sets the fake's guardrails (see `editorPriceUsd`): the Mac's Edit check tries the confirm and refusal states with them.
    public func setEditorGuardrails(priceUsd: Double = 0, paidOff: Bool = false, capHit: Bool = false) {
        editorPriceUsd = priceUsd; editorPaidOff = paidOff; editorCapHit = capHit
    }

    /// A run that would cost money on the server (not the free passes).
    private func isPaid(_ req: EditorJobRequest) -> Bool {
        switch req.kind {
        case .captions, .matte: return true
        case .denoise: return req.options?.analyzeOnly != true
        case .cuts, .beats, .reverse, .stabilize: return false
        }
    }

    /// The server's answers when the owner switched paid helpers off or today's cap is reached (WS1's guardrails).
    private func checkGuardrails(_ req: EditorJobRequest) throws {
        guard isPaid(req) else { return }
        if editorPaidOff { throw ApiError("editor_paid_off", "AI editing helpers are switched off for now · the owner can switch them back on") }
        if editorCapHit { throw ApiError("editor_daily_cap", "Today’s AI editing limit ($5.00) is reached · try tomorrow, or the owner can raise it") }
    }

    // Style kits: the same rules as server editor/kits.ts (name 1–60, validateKit, at most 200).
    public func editKits() throws -> [EditKit] { editKitStore }

    public func saveEditKit(name: String, kit: EditV2.StyleKit) throws -> EditKit {
        let n = try Self.kitName(name)
        let k = try EditV2.validateKit(try JSONPatch.encode(kit))
        guard editKitStore.count < 200 else { throw ApiError("bad_request", "At most 200 style kits") }
        let now = ISO8601DateFormatter().string(from: Date())
        let saved = EditKit(id: "kit_\(UUID().uuidString.prefix(8).lowercased())", name: n, kit: k, createdBy: "me", createdAt: now, updatedAt: now)
        editKitStore.insert(saved, at: 0)
        return saved
    }

    public func updateEditKit(id: String, name: String?, kit: EditV2.StyleKit?) throws -> EditKit {
        guard let i = editKitStore.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "That style kit is gone") }
        if let name { editKitStore[i].name = try Self.kitName(name) }
        if let kit { editKitStore[i].kit = try EditV2.validateKit(try JSONPatch.encode(kit)) }
        editKitStore[i].updatedAt = ISO8601DateFormatter().string(from: Date())
        return editKitStore[i]
    }

    public func deleteEditKit(id: String) throws {
        guard let i = editKitStore.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "That style kit is gone") }
        editKitStore.remove(at: i)
    }

    private static func kitName(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(n.count) else { throw ApiError("bad_request", "name: 1 to 60 characters") }
        return n
    }

    public func editorFeatures() throws -> EditorFeatures? {
        guard editorPaidOff else { return nil }
        let off = EditorFeatures.Helper(available: false)
        return EditorFeatures(paid: EditorFeatures.Helper(available: false, reason: "AI editing helpers are switched off for now"), captions: off, matte: off, denoise: off)
    }

    public func editorEstimate(_ req: EditorJobRequest) throws -> EditorEstimate {
        let d = try editorSourceDuration(req.source)
        try checkGuardrails(req)
        let usd = isPaid(req) ? editorPriceUsd : 0
        return EditorEstimate(kind: req.kind, usd: usd, tokens: usd > 0 ? usd * 100 : 0, free: usd <= 0, reusesTranscript: false, durationSec: d)
    }

    public func startEditorJob(_ req: EditorJobRequest) throws -> EditorJob {
        let d = try editorSourceDuration(req.source)
        try checkGuardrails(req)
        if req.kind == .reverse && d > 60 { throw ApiError("bad_request", "Reverse works on videos up to 60 s") }
        if req.kind == .stabilize && d > 180 { throw ApiError("bad_request", "Stabilise works on videos up to 3 minutes") }
        if req.kind == .matte && d > 120 { throw ApiError("bad_request", "Background removal works on videos up to 2 minutes") }
        // Tap to keep: the points are checked before anything starts (as the server does before it holds).
        if req.kind == .matte, let pts = req.options?.points, let problem = EditSuite.keepPointsProblem(pts, sourceSec: d) {
            throw ApiError("bad_request", problem)
        }
        let id = "ej_" + shortId()
        let phase: String
        switch req.kind {
        case .captions: phase = "Listening"
        case .cuts: phase = req.options?.silenceOnly == true ? "Finding silences" : "Listening"
        case .matte: phase = "Cutting out"
        case .denoise: phase = "Cleaning up"
        case .beats: phase = "Finding the beat"
        case .reverse: phase = "Reversing"
        case .stabilize: phase = "Steadying"
        }
        let job = EditorJob(id: id, kind: req.kind, state: "running", progress: 5, phase: phase, estimateUsd: 0, costUsd: 0)
        editorJobs[id] = job
        let wait = max(0.2, genDelay * 0.25)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await self?.finishEditorJob(id, req, duration: d)
        }
        return job
    }

    func finishEditorJob(_ id: String, _ req: EditorJobRequest, duration d: Double) {
        guard var job = editorJobs[id], job.isRunning else { return }
        var r = EditorJobResult(durationSec: d)
        switch req.kind {
        case .captions:
            r.language = req.options?.language.flatMap { $0 == "auto" ? nil : $0 } ?? "en"
            r.words = Self.mockWords(duration: d)
            r.reused = false
        case .cuts:
            let words = req.options?.silenceOnly == true ? [] : Self.mockWords(duration: d)
            let o = EditV2.CutOptions(minSilenceSec: req.options?.minSilenceSec, keepPadSec: req.options?.keepPadSec,
                                      fillers: req.options?.silenceOnly == true ? false : req.options?.fillers, repeats: req.options?.repeats)
            let base = req.options?.silenceOnly == true ? Self.mockWords(duration: d) : words
            let s = EditV2.suggestCuts(base, durationSec: d, options: o)
            r.cuts = req.options?.silenceOnly == true ? s.cuts.filter { $0.reason == .silence } : s.cuts
            r.savedSec = EditV2.r3(r.cuts!.reduce(0) { $0 + $1.endSec - $1.startSec })
            r.words = words
            r.language = "en"
        case .beats:
            let period = 0.5
            var beats: [Double] = []
            var t = 0.25
            while t < d { beats.append(EditV2.r3(t)); t += period }
            r.bpm = 120
            r.beats = beats
            r.strong = beats.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        case .matte:
            // An alpha matte (2026-11-08 contract). The fake hands back the source itself, so its luma is the matte.
            r.asset = EditorResultAsset(kind: "video", upload: req.source.uploadId, take: req.source.takeId, durationSec: d)
            r.alpha = true
            r.mode = req.options?.points?.isEmpty == false ? "tracked" : "person"
            r.points = req.options?.points
        case .reverse, .stabilize:
            // The fake hands back the source itself as the "reversed" or "steadied" copy.
            r.asset = EditorResultAsset(kind: "video", upload: req.source.uploadId, take: req.source.takeId, durationSec: d)
            r.width = 1080; r.height = 1920; r.hasAudio = true
        case .denoise:
            r.suggestion = DenoiseSuggestion(level: "light", reason: "Some background hum", confidence: 0.7)
            if req.options?.analyzeOnly != true {
                r.asset = EditorResultAsset(kind: "audio", upload: req.source.uploadId, take: req.source.takeId, durationSec: d)
            }
        }
        job.state = "done"
        job.progress = 100
        job.phase = nil
        job.result = r
        editorJobs[id] = job
    }

    public func editorJob(id: String) throws -> EditorJob {
        guard let j = editorJobs[id] else { throw ApiError("not_found", "Job not found") }
        return j
    }

    public func cancelEditorJob(id: String) throws {
        guard var j = editorJobs[id] else { throw ApiError("not_found", "Job not found") }
        if j.isRunning { j.state = "cancelled"; editorJobs[id] = j } else { editorJobs[id] = nil }
    }

    public func uploadEditorFile(_ file: URL, contentType: String, purpose: String?, progress: UploadProgress?) throws -> String {
        progress?(0)
        let id = "up_" + shortId()
        editorFiles[id] = file
        progress?(1)
        return id
    }

    public func checkFont(uploadId: String) throws -> FontCheck {
        guard let f = editorFiles[uploadId] else { throw ApiError("not_found", "The upload hasn't arrived") }
        guard let data = try? Data(contentsOf: f) else { throw ApiError("bad_request", "not a TrueType or OpenType font") }
        guard data.count <= EditV2.fontMaxBytes else { throw ApiError("bad_request", "the font is over 10 MB") }
        guard let name = EditV2.fontName(data) else { throw ApiError("bad_request", "not a TrueType or OpenType font") }
        return FontCheck(uploadId: uploadId, name: name)
    }

    public func validateLut(uploadId: String) throws -> LutValidation {
        guard let f = editorFiles[uploadId] else { throw ApiError("not_found", "The upload hasn't arrived") }
        guard let data = try? Data(contentsOf: f) else { throw ApiError("bad_request", ".cube: couldn't read the file") }
        do {
            let lut = try EditV2.parseCube(String(decoding: data, as: UTF8.self))
            return LutValidation(uploadId: uploadId, size: lut.size, title: lut.title)
        } catch {
            throw ApiError("bad_request", ".cube: \(error)")
        }
    }

    public func createTakeVersionV2(takeId: String, _ req: TakeVersionV2Request) throws -> Take {
        guard let src = takes.first(where: { $0.id == takeId }) else { throw ApiError("not_found", "Take not found") }
        guard src.isVideo else { throw ApiError("bad_request", "Edit works on a video take") }
        if req.edits.sourceTakeId != takeId { throw ApiError("bad_request", "edits.sourceTakeId: must be the take in the URL") }
        if let p = EditV2.problem(req.edits) { throw ApiError("bad_request", p.description) }
        if !TakeVersionV2Request.accepts(project: req.edits, durationSec: req.durationSec) {
            throw ApiError("bad_request", "durationSec: doesn't match the edit")
        }
        if usedUploads.contains(req.uploadId) { throw ApiError("upload_used", "This upload is already saved") }
        guard case .video(let file)? = editUploads[req.uploadId] else { throw ApiError("upload_missing", "The upload hasn't arrived") }
        var thumb = src.thumb
        if let tid = req.thumbUploadId, case .image(let f)? = editUploads[tid] { thumb = ImageRef(url: f.absoluteString) } else if let t = req.thumb { thumb = t }
        var t = Take(id: "tk_" + shortId(), kind: "edit", jobId: src.jobId, title: src.title, label: "Edited", engineLabel: src.engineLabel,
                     cost: 0, seed: src.seed, status: "test", thumb: thumb, prompt: src.prompt, createdAt: nowMs())
        t.videoUrl = file.absoluteString
        t.durationSec = req.durationSec
        t.width = req.width
        t.height = req.height
        t.fps = req.fps
        t.parentTakeId = takeId
        t.editsV2 = req.edits
        t.name = TakeVersionV2Request.versionName(req.name)
        t.aiLabel = req.aiLabel == true ? true : nil
        t.templateId = src.templateId
        t.templateName = src.templateName
        usedUploads.insert(req.uploadId)
        editUploads[req.uploadId] = nil
        takes.insert(t, at: 0)
        hub.emit(ApiEvent(type: "take", take: t))
        return t
    }
}
