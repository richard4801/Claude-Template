import Foundation

/// "Recreate this edit" endpoints (plans/api.md "Recreate this edit", workstream 1's server).
public protocol RecreateAPI: Sendable {
    func listReferences() async throws -> [RecreateReference]
    func reference(_ id: String) async throws -> RecreateReference
    /// Uploads the video (≤ 60 s) and starts its analysis; returns the reference in `analyzing`.
    func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference
    /// A public TikTok, Instagram Reel or YouTube link: the server fetches it (`source: "link"`, phase "Fetching the
    /// video"), or returns the member's reference from the same link (`cached: true`). Refusals throw `link_*` / `too_long`.
    func createReference(link: String, name: String?) async throws -> RecreateReference
    func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference
    func deleteReference(_ id: String) async throws
    func fill(_ id: String) async throws -> RecreateFill
    /// Scores the studio's takes against each slot (free); the fill then says which slots are matched and which to generate.
    func matchSlots(_ id: String, modelId: String?) async throws
    /// The price of making one slot as a new shot. Nothing is held. `quality` nil = the server's default.
    func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotEstimate
    /// Makes one slot as a new shot: a Suite job, held and charged like any shot. Only after the person confirmed the price.
    func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotFillStart
    func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult
    /// `POST /v1/edit-sessions/{id}/preview` (owner): renders the session's current revision (once per revision).
    func startPreview(sessionId: String) async throws -> EditPreviewRender
    /// `GET /v1/edit-sessions/{id}/preview?revision`.
    func preview(sessionId: String, revision: Int?) async throws -> EditPreviewRender
    /// `POST /v1/recreate/references/{id}/export {sessionId, sound}`: the built edit with the guide sound, or silent.
    /// A guide export without the reference's sound gets `409 no_reference_sound`.
    func startExport(_ id: String, sessionId: String, sound: String) async throws -> RecreateServerExport
    /// `GET /v1/recreate/references/{id}/export?sessionId&sound`.
    func exportState(_ id: String, sessionId: String, sound: String) async throws -> RecreateServerExport
}

/// `POST …/slots/{slotId}/estimate`: the shot request the slot becomes, and its price (nothing held).
public struct RecreateSlotEstimate: Decodable, Hashable, Sendable {
    public var slotId: String
    public var estimate: ShotEstimate
    /// The ShotRequest the slot becomes (kept as sent; the app only shows the price).
    public var request: JSONValue?

    public init(slotId: String, estimate: ShotEstimate, request: JSONValue? = nil) {
        self.slotId = slotId; self.estimate = estimate; self.request = request
    }

    enum CodingKeys: String, CodingKey { case slotId, estimate, request }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slotId = try c.decode(String.self, forKey: .slotId)
        estimate = try c.decode(ShotEstimate.self, forKey: .estimate)
        request = c.o(.request)
    }
}

/// `POST …/slots/{slotId}/fill`: the Suite job making the slot. The fill then reports the slot `generating`, then `ready`.
public struct RecreateSlotFillStart: Decodable, Hashable, Sendable {
    public var slotId: String
    public var job: Job

    public init(slotId: String, job: Job) { self.slotId = slotId; self.job = job }

    enum CodingKeys: String, CodingKey { case slotId, job }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slotId = try c.decode(String.self, forKey: .slotId)
        job = try c.decode(Job.self, forKey: .job)
    }
}

public struct RecreateApplyRequest: Codable, Hashable, Sendable {
    public struct Options: Codable, Hashable, Sendable {
        public var camera: Bool?
        public var speed: Bool?
        public var text: Bool?
        public var look: Bool?
        public init(camera: Bool? = nil, speed: Bool? = nil, text: Bool? = nil, look: Bool? = nil) {
            self.camera = camera; self.speed = speed; self.text = text; self.look = look
        }
    }
    public var sessionId: String
    public var baseRevision: Int?
    /// slotId → takeId or jobId.
    public var slots: [String: String]
    public var options: Options?
    public var device: String?
    public init(sessionId: String, baseRevision: Int? = nil, slots: [String: String], options: Options? = nil, device: String? = nil) {
        self.sessionId = sessionId; self.baseRevision = baseRevision; self.slots = slots; self.options = options; self.device = device
    }
}

public struct RecreateApplyResult: Codable, Hashable, Sendable {
    public var sessionId: String
    public var revision: Int?
    public var durationSec: Double?
    /// Slots left empty, and slots still waiting on a generation.
    public var missing: [String]?
    public var waiting: [String]?
    public var notes: [String]?
    public var label: String?
    public var match: RecreateMatch?

    enum CodingKeys: String, CodingKey { case sessionId, revision, durationSec, missing, waiting, notes, label, match }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        revision = c.o(.revision)
        durationSec = c.o(.durationSec)
        missing = c.o(.missing)
        waiting = c.o(.waiting)
        notes = c.o(.notes)
        label = c.o(.label)
        match = c.o(.match)
    }
}

public enum RecreateIds {
    /// Reference ids are `rx_…`; anything else is refused before it reaches a URL.
    public static func check(_ id: String) throws -> String {
        guard id.range(of: #"^rx_[A-Za-z0-9_]{1,64}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't a reference") }
        return id
    }

    /// Slot ids are `s1`, `s2`… (the analysis numbers them); anything else is refused before it reaches a URL.
    public static func slot(_ id: String) throws -> String {
        guard id.range(of: #"^s[0-9]{1,4}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't a shot of the reference") }
        return id
    }
}

// MARK: HTTP

extension HTTPMuseAPI: RecreateAPI {
    private struct CreateBody: Encodable { var uploadId: String; var name: String? }
    private struct LinkBody: Encodable { var url: String; var name: String? }
    private struct PatchBody: Encodable { var keep: Bool?; var name: String? }
    private struct SlotBody: Encodable { var modelId: String; var quality: String? }
    private struct MatchBody: Encodable { var modelId: String? }

    public func listReferences() async throws -> [RecreateReference] { try await suiteCall("GET", "v1/recreate/references") }
    public func reference(_ id: String) async throws -> RecreateReference { try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))") }
    public func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference {
        let uploadId = try await uploadVideoForAnalysis(file, contentType: contentType, progress: progress)
        return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(CreateBody(uploadId: uploadId, name: name)))
    }
    public func createReference(link: String, name: String?) async throws -> RecreateReference {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw ApiError("link_unsupported", "Paste a link first") }
        return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(LinkBody(url: url, name: name)))
    }
    public func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference {
        try await suiteCall("PATCH", "v1/recreate/references/\(try RecreateIds.check(id))", body: try JSONEncoder().encode(PatchBody(keep: keep, name: name)))
    }
    public func deleteReference(_ id: String) async throws { try await suiteSend("DELETE", "v1/recreate/references/\(try RecreateIds.check(id))") }
    public func fill(_ id: String) async throws -> RecreateFill { try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))/fill") }
    public func matchSlots(_ id: String, modelId: String?) async throws {
        let _: JSONValue = try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/match", body: try JSONEncoder().encode(MatchBody(modelId: modelId)))
    }
    public func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotEstimate {
        let path = "v1/recreate/references/\(try RecreateIds.check(id))/slots/\(try RecreateIds.slot(slotId))/estimate"
        return try await suiteCall("POST", path, body: try JSONEncoder().encode(SlotBody(modelId: modelId, quality: quality)))
    }
    public func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotFillStart {
        let path = "v1/recreate/references/\(try RecreateIds.check(id))/slots/\(try RecreateIds.slot(slotId))/fill"
        return try await suiteCall("POST", path, body: try JSONEncoder().encode(SlotBody(modelId: modelId, quality: quality)))
    }
    public func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult {
        try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/apply", body: try JSONEncoder().encode(req))
    }

    private struct ExportBody: Encodable { var sessionId: String; var sound: String }

    public func startPreview(sessionId: String) async throws -> EditPreviewRender {
        try await suiteCall("POST", "v1/edit-sessions/\(try EditSessionIds.check(sessionId))/preview", body: Data("{}".utf8))
    }
    public func preview(sessionId: String, revision: Int?) async throws -> EditPreviewRender {
        let q = revision.map { "?revision=\($0)" } ?? ""
        return try await suiteCall("GET", "v1/edit-sessions/\(try EditSessionIds.check(sessionId))/preview\(q)")
    }
    public func startExport(_ id: String, sessionId: String, sound: String) async throws -> RecreateServerExport {
        let body = try JSONEncoder().encode(ExportBody(sessionId: try EditSessionIds.check(sessionId), sound: sound == "silent" ? "silent" : "guide"))
        return try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/export", body: body)
    }
    public func exportState(_ id: String, sessionId: String, sound: String) async throws -> RecreateServerExport {
        let s = sound == "silent" ? "silent" : "guide"
        return try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))/export?sessionId=\(try EditSessionIds.check(sessionId))&sound=\(s)")
    }

    /// Absolute URL for an authenticated reference route ("/v1/recreate/…/video" or a full link); load with `sessionToken`.
    public func recreateMediaURL(_ link: String?) -> URL? { link.flatMap { resolve($0) } }
}

// MARK: Demo

/// Demo mode: one ready reference (workstream 1's fixture) and a fill that matches one slot from the takes and leaves
/// two to generate. Nothing is uploaded or charged; a new reference is analysed instantly. Each shot is priced $0.64; a
/// filled slot reads `generating` on the next `fill()` and `ready` on the one after (a fake job id, nothing spent).
public final class FakeRecreateAPI: RecreateAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [RecreateReference]
    /// referenceId → slotId → `fill()` calls since the slot was filled.
    private var made: [String: [String: Int]] = [:]
    /// Link references whose fetch fails on the next read (demo: a link with "fails" in it).
    private var failing: Set<String> = []
    public static let demoPrice = 0.64
    /// Demo mode's link (any TikTok link reads the sample at once).
    public static let demoLink = "https://www.tiktok.com/@muse.demo/video/7400000000000000001"

    public init() {
        let sample = try? JSONDecoder().decode(RecreateReference.self, from: Data(RecreateDemo.referenceJSON.utf8))
        refs = sample.map { [$0] } ?? []
    }

    private func with<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }

    public func listReferences() async throws -> [RecreateReference] { with { refs } }
    public func reference(_ id: String) async throws -> RecreateReference {
        try with {
            guard let i = refs.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "That reference is gone") }
            // A link whose download is blocked: the next read reports the failure.
            if failing.remove(id) != nil {
                refs[i].state = "failed"
                refs[i].phase = "Failed"
                refs[i].error = RecreateLinks.fallback
                refs[i].errorCode = "link_blocked"
            }
            return refs[i]
        }
    }
    public func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference {
        try with {
            guard var r = refs.first(where: { $0.recipe != nil }) else { throw ApiError("not_found", "No sample in demo mode") }
            r.id = "rx_demo\(refs.count + 1)"
            r.name = name ?? file.deletingPathExtension().lastPathComponent
            r.source = "file"
            r.sourceUrl = nil
            r.cached = nil
            refs.insert(r, at: 0)
            return r
        }
    }

    /// Demo mode's links: any TikTok, Instagram or YouTube link reads the sample at once (`source: "link"`); the same link
    /// again returns it with `cached: true`. Words in the link try the refusals: "private", "downloads-off", "too-big",
    /// "too-long", "blocked" (refused at once) and "fails" (accepted, then the fetch fails with `link_blocked`).
    public func createReference(link: String, name: String?) async throws -> RecreateReference {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RecreateLinks.platform(url) != nil else {
            throw ApiError("link_unsupported", RecreateLinks.message(code: "link_unsupported", message: nil))
        }
        let low = url.lowercased()
        let refusals: [(String, String, String?)] = [
            ("private", "link_private", nil), ("downloads-off", "link_downloads_off", nil),
            ("too-big", "link_too_big", "This video is too big to fetch (212 MB; the limit is 80 MB)"),
            ("too-long", "too_long", "References can be up to 60 s for now (this one is 94 s)"), ("blocked", "link_blocked", nil),
        ]
        for (word, code, message) in refusals where low.contains(word) {
            throw ApiError(code, RecreateLinks.message(code: code, message: message))
        }
        return try with {
            if var hit = refs.first(where: { $0.sourceUrl == url }) {
                hit.cached = true
                return hit
            }
            guard var r = refs.first(where: { $0.recipe != nil }) else { throw ApiError("not_found", "No sample in demo mode") }
            r.id = "rx_demo\(refs.count + 1)"
            r.name = name ?? "\(RecreateLinks.platform(url) ?? "Link") video"
            r.source = "link"
            r.sourceUrl = url
            r.cached = nil
            if low.contains("fails") {
                r.state = "analyzing"
                r.phase = "Fetching the video"
                r.progress = 0
                r.recipe = nil
                failing.insert(r.id)
            }
            refs.insert(r, at: 0)
            return r
        }
    }

    public func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference {
        try with {
            guard let i = refs.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "That reference is gone") }
            if let keep { refs[i].keep = keep }
            if let name { refs[i].name = name }
            return refs[i]
        }
    }
    public func deleteReference(_ id: String) async throws { with { refs.removeAll { $0.id == id } } }
    /// Review mode: every theme starts from the same fill (nothing made yet).
    public func forgetMade() { with { made = [:] } }

    public static func demoJobId(_ slotId: String) -> String { "job_rx_\(slotId)" }

    public func fill(_ id: String) async throws -> RecreateFill {
        let r = try await reference(id)
        let slots = r.recipe?.slots ?? []
        let counts: [String: Int] = with {
            for k in (made[id] ?? [:]).keys { made[id]?[k, default: 0] += 1 }
            return made[id] ?? [:]
        }
        var rows: [[String: Any]] = []
        for (i, s) in slots.enumerated() {
            let estimate: [String: Any] = ["amount": Self.demoPrice, "label": RecreateText.money(Self.demoPrice)]
            if let n = counts[s.id] {
                if n >= 2 {
                    rows.append(["slotId": s.id, "state": "ready", "jobId": Self.demoJobId(s.id), "takeId": "t_rx_\(s.id)", "reason": "Generated for this shot"])
                } else {
                    rows.append(["slotId": s.id, "state": "generating", "jobId": Self.demoJobId(s.id), "estimate": estimate])
                }
            } else if i == 0 {
                rows.append(["slotId": s.id, "state": "matched", "takeId": "t1", "score": 0.82, "reason": "Your take has the same pan on a wide shot"])
            } else {
                rows.append(["slotId": s.id, "state": "to_generate", "estimate": estimate])
            }
        }
        let json: [String: Any] = ["referenceId": id, "slots": rows]
        return try JSONDecoder().decode(RecreateFill.self, from: JSONSerialization.data(withJSONObject: json))
    }
    public func matchSlots(_ id: String, modelId: String?) async throws { _ = try await reference(id) }

    public func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotEstimate {
        _ = try RecreateIds.slot(slotId)
        let r = try await reference(id)
        guard let s = r.recipe?.slots.first(where: { $0.id == slotId }) else { throw ApiError("not_found", "That shot is gone") }
        let secs = max(2, s.length.rounded(.up))
        let price = RecreateText.money(Self.demoPrice)
        let e = ShotEstimate(quality: quality ?? "standard", label: "Shot · Standard", resolution: "768p", seconds: secs, takes: 1, mode: "reference",
                             estimate: Self.demoPrice, priceLine: "about \(price) · \(Int(secs)) s", buttonLabel: "Generate · \(Int(secs)) s · \(price)", test: true)
        return RecreateSlotEstimate(slotId: slotId, estimate: e)
    }

    public func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotFillStart {
        _ = try RecreateIds.slot(slotId)
        let r = try await reference(id)
        guard let i = r.recipe?.slots.firstIndex(where: { $0.id == slotId }) else { throw ApiError("not_found", "That shot is gone") }
        try with {
            if made[id]?[slotId] != nil { throw ApiError("already_filled", "This shot is already being made") }
            made[id, default: [:]][slotId] = 0
        }
        let job = Job(id: Self.demoJobId(slotId), title: "Shot \(i + 1)", modelId: modelId, modelName: "", outfitId: "",
                      request: JobRequest(title: "Shot \(i + 1)", modelId: modelId, outfitId: "", clipId: "", engine: "suite"), state: "queued", cost: Self.demoPrice)
        return RecreateSlotFillStart(slotId: slotId, job: job)
    }

    // Server renders: the fake answers like the server (rendering on the first POST, ready on the next read) with links
    // that only a server can serve. The app never uses them in demo mode: it renders on the Mac there.
    private var renders: Set<String> = []

    public func startPreview(sessionId: String) async throws -> EditPreviewRender {
        let id = try EditSessionIds.check(sessionId)
        let fresh: Bool = with { renders.insert("p/\(id)").inserted }
        return fresh ? EditPreviewRender(sessionId: id, revision: 1, state: "rendering") : try await preview(sessionId: id, revision: nil)
    }
    public func preview(sessionId: String, revision: Int?) async throws -> EditPreviewRender {
        let id = try EditSessionIds.check(sessionId)
        guard with({ renders.contains("p/\(id)") }) else { return EditPreviewRender(sessionId: id, revision: revision, state: "none") }
        return EditPreviewRender(sessionId: id, revision: 1, state: "ready", url: "/v1/edit-sessions/\(id)/preview.mp4?revision=1",
                                 durationSec: 4.4, width: 406, height: 720, unsupported: [])
    }
    public func startExport(_ id: String, sessionId: String, sound: String) async throws -> RecreateServerExport {
        let r = try await reference(id)
        if sound != "silent", r.videoUrl == nil, r.sourceUrl == nil {
            throw ApiError("no_reference_sound", "The reference’s video is gone, so there’s no sound to use. Export silent instead.")
        }
        let key = "e/\(id)/\(sessionId)/\(sound)"
        let fresh: Bool = with { renders.insert(key).inserted }
        if fresh { return Self.export(r, sessionId: sessionId, sound: sound, ready: false) }
        return try await exportState(id, sessionId: sessionId, sound: sound)
    }
    public func exportState(_ id: String, sessionId: String, sound: String) async throws -> RecreateServerExport {
        let r = try await reference(id)
        let made = with { renders.contains("e/\(id)/\(sessionId)/\(sound)") }
        var e = Self.export(r, sessionId: sessionId, sound: sound, ready: made)
        if !made { e.state = "none" }
        return e
    }

    /// The server's useThisSound: the platform's own steps for a link reference, general ones for a file.
    public static func useThisSound(_ r: RecreateReference) -> UseThisSound {
        let platform = r.sourceUrl.flatMap { RecreateLinks.platform($0) }
        let steps: [String]
        switch platform {
        case "TikTok": steps = ["Open the reference on TikTok and tap the sound", "Tap “Use this sound”", "Upload your export and line it up at 0:00"]
        case "Instagram": steps = ["Open the reference Reel and tap the audio", "Tap “Use audio”", "Add your export and line it up at 0:00"]
        case "YouTube": steps = ["Open the reference Short", "Tap “Remix” then “Use sound”", "Add your export and line it up at 0:00"]
        default: steps = ["Find the original sound on the platform you post to", "Use it on your post", "Line your export up at 0:00"]
        }
        return UseThisSound(platform: platform?.lowercased(), sourceUrl: r.sourceUrl, startAtSec: 0, durationSec: r.durationSec,
                            title: "Post with the original sound", steps: steps,
                            note: "The guide sound is only for timing. Post with the platform’s own sound so it plays for everyone.")
    }

    static func export(_ r: RecreateReference, sessionId: String, sound: String, ready: Bool) -> RecreateServerExport {
        let q = "sessionId=\(sessionId)&sound=\(sound)"
        return RecreateServerExport(referenceId: r.id, sessionId: sessionId, revision: 1, sound: sound, state: ready ? "ready" : "rendering",
                                    url: ready ? "/v1/recreate/references/\(r.id)/export.mp4?\(q)" : nil, durationSec: r.durationSec,
                                    useThisSound: useThisSound(r))
    }

    public func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult {
        let slots = (try? await reference(id))?.recipe?.slots.map(\.id) ?? []
        // A finished job's first take fills its slot; one still running is listed in `waiting` (as the server does).
        let done: [String: Int] = with { made[id] ?? [:] }
        let waiting = req.slots.filter { slot, v in v.hasPrefix("job_rx_") && (done[slot] ?? 0) < 2 }.map(\.key).sorted()
        let scores = [0.93, 0.81, 0.84]
        let perSlot: [[String: Any]] = slots.enumerated().map { i, s in ["slotId": s, "score": scores[i % scores.count]] }
        let match: [String: Any] = ["overall": 0.86, "cuts": 0.97, "text": 0.9, "ramps": 0.78, "grade": 0.84, "shots": 0.8, "perSlot": perSlot]
        let none: [String] = []
        let json: [String: Any] = ["sessionId": req.sessionId, "revision": (req.baseRevision ?? 0) + 1, "label": "Recreated", "missing": none, "waiting": waiting, "match": match]
        return try JSONDecoder().decode(RecreateApplyResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
