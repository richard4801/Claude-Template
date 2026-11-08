import Foundation

/// "Recreate this edit" endpoints (plans/api.md "Recreate this edit", workstream 1's server).
public protocol RecreateAPI: Sendable {
    func listReferences() async throws -> [RecreateReference]
    func reference(_ id: String) async throws -> RecreateReference
    /// Uploads the video (≤ 60 s) and starts its analysis; returns the reference in `analyzing`.
    func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference
    /// A video this Mac fetched from a link (RecreateDeviceFetch), uploaded like a dropped file with the link it came from
    /// (`sourceUrl`, optional: a server that doesn't take it yet gets the file alone).
    func createReference(file: URL, contentType: String, name: String?, sourceUrl: String?, progress: UploadProgress?) async throws -> RecreateReference
    /// A public TikTok, Instagram Reel or YouTube link: the server fetches it (`source: "link"`, phase "Fetching the
    /// video"), or returns the member's reference from the same link (`cached: true`). Refusals throw `link_*` / `too_long`.
    func createReference(link: String, name: String?) async throws -> RecreateReference
    func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference
    /// `GET /v1/recreate/settings`: the studio's link rules (strict, platforms, caps), applied on the device too.
    func linkSettings() async throws -> RecreateLinkSettings
    /// `PATCH /v1/recreate/settings {strictLinks}` (owner only): "Strict link rules".
    func setStrictLinks(_ on: Bool) async throws -> RecreateLinkSettings
    /// `POST /v1/recreate/links/check {url}`: the link under the studio's rules before a device downloads it.
    func checkLink(_ url: String) async throws -> RecreateLinkCheck
    func deleteReference(_ id: String) async throws
    func fill(_ id: String) async throws -> RecreateFill
    /// Scores the studio's takes against each slot (free); the fill then says which slots are matched and which to generate.
    func matchSlots(_ id: String, modelId: String?) async throws
    /// The price of making one slot: swapped into the reference's own shot (the server's default) or a new shot. Nothing is
    /// held. `quality` nil = the server's default; `options.method` nil = the server's default (swap where it can run).
    func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?, options: RecreateFillOptions) async throws -> RecreateSlotEstimate
    /// Makes one slot: a swap or a Suite shot, held and charged like any job. Only after the person confirmed the price.
    func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?, options: RecreateFillOptions) async throws -> RecreateSlotFillStart
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
    /// "Fix shot N" in Compare: swaps that shot's clip in the built edit for a take (or a finished fill job's take), as one
    /// undoable change; its timing, transition, ramp, camera and look stay. 409 `not_built_here`, `slot_not_in_edit`,
    /// `job_not_done`; 400 for an unknown take.
    func replaceSlot(_ id: String, slotId: String, sessionId: String, take: String, baseRevision: Int?) async throws -> RecreateReplaceResult
    /// "Write the shot briefs" (G8): its price, or why it isn't available. Nothing is held.
    func briefsEstimate(_ id: String) async throws -> RecreateBriefsEstimate
    /// The owner confirmed the price: one call writes every shot's brief, the summary and tags. Charged from the wallet.
    func writeBriefs(_ id: String) async throws -> RecreateBriefsWritten
}

/// `POST …/briefs/estimate` → this.
public struct RecreateBriefsEstimate: Codable, Hashable, Sendable {
    public var available: Bool
    /// Why it isn't available (points to Settings → Claude, or to asking Claude on the Mac for free).
    public var reason: String?
    /// How many shots it writes.
    public var slots: Int?
    public var estimateUsd: Double
    /// "Write the shot briefs · about $0.02"
    public var label: String
    public var priceLine: String?

    public init(available: Bool, reason: String? = nil, slots: Int? = nil, estimateUsd: Double, label: String, priceLine: String? = nil) {
        self.available = available; self.reason = reason; self.slots = slots; self.estimateUsd = estimateUsd; self.label = label; self.priceLine = priceLine
    }

    enum CodingKeys: String, CodingKey { case available, reason, slots, estimateUsd, label, priceLine }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        available = c.o(.available) ?? false
        reason = c.o(.reason)
        if let n: Int = c.o(.slots) { slots = n } else if let a: [String] = c.o(.slots) { slots = a.count } else { slots = nil }
        estimateUsd = c.o(.estimateUsd) ?? 0
        label = c.o(.label) ?? "Write the shot briefs"
        priceLine = c.o(.priceLine)
    }
}

/// `POST …/briefs/write {confirm: true}` → this; `reference` replaces the one on screen.
public struct RecreateBriefsWritten: Decodable, Hashable, Sendable {
    public var referenceId: String?
    public var written: [String]
    public var costUsd: Double?
    public var reference: RecreateReference?

    public init(referenceId: String? = nil, written: [String], costUsd: Double? = nil, reference: RecreateReference? = nil) {
        self.referenceId = referenceId; self.written = written; self.costUsd = costUsd; self.reference = reference
    }

    enum CodingKeys: String, CodingKey { case referenceId, written, costUsd, reference }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        referenceId = c.o(.referenceId)
        written = c.o(.written) ?? []
        costUsd = c.o(.costUsd)
        reference = c.o(.reference)
    }
}

extension Recipe {
    /// Shots the analysis couldn't describe yet ("Not described yet"): "Write the shot briefs" is offered for them.
    public var slotsWithoutBriefs: [String] { slots.filter { RecreateText.brief($0.brief) == nil }.map(\.id) }
}

extension RecreateAPI {
    /// The server's default method (swap where it can run, else generate).
    public func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotEstimate {
        try await estimateSlot(id, slotId: slotId, modelId: modelId, quality: quality, options: RecreateFillOptions())
    }
    public func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?) async throws -> RecreateSlotFillStart {
        try await fillSlot(id, slotId: slotId, modelId: modelId, quality: quality, options: RecreateFillOptions())
    }
}

/// How a slot is made (G2): `method` swap (the lead put into the reference's own shot) or generate (a new shot);
/// `keepBackground` false = "Use your own setting" (swap only); `outfitId` the lead's outfit when one is chosen.
public struct RecreateFillOptions: Hashable, Sendable {
    public var method: String?
    public var keepBackground: Bool?
    public var outfitId: String?
    /// "Use your own setting": one of the studio's locations (free); nil = the server's pick, else a plate from the brief.
    public var locationId: String?
    /// The fill only: the confirmed price. A swap that would cost more comes back as `409 price_changed`.
    public var maxUsd: Double?
    /// Owner only (WS13): the slot's video model, and the background plate's image model.
    public var engineModel: String?
    public var imageModel: String?
    public init(method: String? = nil, keepBackground: Bool? = nil, outfitId: String? = nil, locationId: String? = nil, maxUsd: Double? = nil,
                engineModel: String? = nil, imageModel: String? = nil) {
        self.method = method; self.keepBackground = keepBackground; self.outfitId = outfitId; self.locationId = locationId; self.maxUsd = maxUsd
        self.engineModel = engineModel; self.imageModel = imageModel
    }
}

/// "Use your own setting": where the background photo comes from (a studio location, free; or a plate made from the
/// brief's setting, about $0.06 the first time, then reused free).
public struct RecreateBackground: Codable, Hashable, Sendable {
    /// location | generated
    public var source: String
    public var locationId: String?
    public var name: String?
    /// The location was matched from the brief's place (not picked).
    public var matched: Bool?
    public var setting: String?
    public var usd: Double
    public var reused: Bool?

    public var isLocation: Bool { source == "location" }

    public init(source: String, locationId: String? = nil, name: String? = nil, matched: Bool? = nil, setting: String? = nil, usd: Double = 0, reused: Bool? = nil) {
        self.source = source; self.locationId = locationId; self.name = name; self.matched = matched; self.setting = setting; self.usd = usd; self.reused = reused
    }

    enum CodingKeys: String, CodingKey { case source, locationId, name, matched, setting, usd, reused }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        source = c.o(.source) ?? "generated"
        locationId = c.o(.locationId)
        name = c.o(.name)
        matched = c.o(.matched)
        setting = c.o(.setting)
        usd = c.o(.usd) ?? 0
        reused = c.o(.reused)
    }

    /// The confirmation's words: "in Rooftop" / "background made from the brief, +$0.06" / "…, made before".
    public var line: String {
        if isLocation { return "in \(name ?? "your location")" }
        if reused == true || usd <= 0 { return "background from the brief, made before" }
        return "background made from the brief, +\(RecreateText.money(usd))"
    }
}

/// What a swap leaves baked in: the reference's camera, speed and look are already in the shot.
public enum RecreateBaked {
    public static func words(_ parts: [String]) -> String {
        let names = parts.map { p -> String in
            switch p {
            case "camera": return "camera"
            case "speed": return "speed"
            case "look": return "look"
            default: return p.replacingOccurrences(of: "_", with: " ")
            }
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

/// `POST …/slots/{slotId}/replace` → this.
public struct RecreateReplaceResult: Codable, Hashable, Sendable {
    public var sessionId: String
    public var revision: Int?
    public var slotId: String
    public var itemId: String?
    public var takeId: String?
    public var inSec: Double?
    public var label: String?
    /// "The take is shorter than the shot, so it plays at 80%".
    public var note: String?
    /// A swapped take is baked: what it already carries (camera, speed, look).
    public var baked: [String]?

    public init(sessionId: String, revision: Int?, slotId: String, itemId: String? = nil, takeId: String? = nil, inSec: Double? = nil,
                label: String? = nil, note: String? = nil, baked: [String]? = nil) {
        self.sessionId = sessionId; self.revision = revision; self.slotId = slotId; self.itemId = itemId; self.takeId = takeId
        self.inSec = inSec; self.label = label; self.note = note; self.baked = baked
    }

    enum CodingKeys: String, CodingKey { case sessionId, revision, slotId, itemId, takeId, inSec, label, note, baked }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sessionId = c.o(.sessionId) ?? ""
        revision = c.o(.revision)
        slotId = c.o(.slotId) ?? ""
        itemId = c.o(.itemId)
        takeId = c.o(.takeId)
        inSec = c.o(.inSec)
        label = c.o(.label)
        note = c.o(.note)
        baked = c.o(.baked)
    }
}

/// `POST …/slots/{slotId}/estimate`: what the slot becomes (a swap of the reference's own segment, or a new shot), and its
/// price (nothing held).
public struct RecreateSlotEstimate: Decodable, Hashable, Sendable {
    public struct Segment: Codable, Hashable, Sendable {
        public var startSec: Double
        public var endSec: Double
        public init(startSec: Double, endSec: Double) { self.startSec = startSec; self.endSec = endSec }
    }
    public var slotId: String
    public var estimate: ShotEstimate
    /// The ShotRequest the slot becomes (kept as sent; the app only shows the price).
    public var request: JSONValue?
    /// swap | generate (nil from an older server: generate).
    public var method: String?
    public var keepBackground: Bool?
    /// The reference's own stretch a swap uses.
    public var segment: Segment?
    /// What a swap carries from the reference (camera, speed, look).
    public var baked: [String]
    /// Why the default fell back to generate (a message to show).
    public var swapUnavailable: String?
    /// brief | summary | default: where a new shot's prompt came from.
    public var promptFrom: String?
    /// "Use your own setting": the background photo, and the price split when the plate is paid (both already in `estimate`).
    public var background: RecreateBackground?
    public var swapUsd: Double?
    public var backgroundUsd: Double?

    public var isSwap: Bool { method == "swap" }

    public init(slotId: String, estimate: ShotEstimate, request: JSONValue? = nil, method: String? = nil, keepBackground: Bool? = nil,
                segment: Segment? = nil, baked: [String] = [], swapUnavailable: String? = nil, promptFrom: String? = nil,
                background: RecreateBackground? = nil, swapUsd: Double? = nil, backgroundUsd: Double? = nil) {
        self.slotId = slotId; self.estimate = estimate; self.request = request; self.method = method; self.keepBackground = keepBackground
        self.segment = segment; self.baked = baked; self.swapUnavailable = swapUnavailable; self.promptFrom = promptFrom
        self.background = background; self.swapUsd = swapUsd; self.backgroundUsd = backgroundUsd
    }

    /// The split of a paid plate's price, read from the estimate object.
    private struct Split: Decodable { var swapUsd: Double?; var backgroundUsd: Double? }

    enum CodingKeys: String, CodingKey { case slotId, estimate, request, method, keepBackground, segment, baked, swapUnavailable, promptFrom, background, swapUsd, backgroundUsd }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slotId = try c.decode(String.self, forKey: .slotId)
        estimate = try c.decode(ShotEstimate.self, forKey: .estimate)
        request = c.o(.request)
        method = c.o(.method)
        keepBackground = c.o(.keepBackground)
        segment = c.o(.segment)
        baked = c.o(.baked) ?? []
        swapUnavailable = c.o(.swapUnavailable)
        promptFrom = c.o(.promptFrom)
        background = c.o(.background)
        let split: Split? = c.o(.estimate)
        swapUsd = split?.swapUsd ?? c.o(.swapUsd)
        backgroundUsd = split?.backgroundUsd ?? c.o(.backgroundUsd)
    }
}

/// `POST …/slots/{slotId}/fill`: the job making the slot (a swap or a Suite shot). The fill then reports the slot
/// `generating`, then `ready`.
public struct RecreateSlotFillStart: Decodable, Hashable, Sendable {
    public var slotId: String
    public var job: Job
    public var method: String?
    public var segment: RecreateSlotEstimate.Segment?

    public init(slotId: String, job: Job, method: String? = nil, segment: RecreateSlotEstimate.Segment? = nil) {
        self.slotId = slotId; self.job = job; self.method = method; self.segment = segment
    }

    enum CodingKeys: String, CodingKey { case slotId, job, method, segment }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slotId = try c.decode(String.self, forKey: .slotId)
        job = try c.decode(Job.self, forKey: .job)
        method = c.o(.method)
        segment = c.o(.segment)
    }
}

public struct RecreateApplyRequest: Codable, Hashable, Sendable {
    public struct Options: Codable, Hashable, Sendable {
        public var camera: Bool?
        public var speed: Bool?
        public var text: Bool?
        public var look: Bool?
        /// Line each take's action peak up with its slot (the server's default: on).
        public var peaks: Bool?
        public init(camera: Bool? = nil, speed: Bool? = nil, text: Bool? = nil, look: Bool? = nil, peaks: Bool? = nil) {
            self.camera = camera; self.speed = speed; self.text = text; self.look = look; self.peaks = peaks
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
    /// Swapped slots: what each already carries from the reference (slotId → ["camera", "speed", "look"]).
    public var baked: [String: [String]]?

    enum CodingKeys: String, CodingKey { case sessionId, revision, durationSec, missing, waiting, notes, label, match, baked }
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
        baked = c.o(.baked)
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

public extension RecreateAPI {
    /// Without `sourceUrl` support: the file alone.
    func createReference(file: URL, contentType: String, name: String?, sourceUrl: String?, progress: UploadProgress?) async throws -> RecreateReference {
        try await createReference(file: file, contentType: contentType, name: name, progress: progress)
    }
}

// MARK: HTTP

extension HTTPMuseAPI: RecreateAPI {
    private struct CreateBody: Encodable { var uploadId: String; var name: String?; var sourceUrl: String? = nil }
    private struct LinkBody: Encodable { var url: String; var name: String? }
    private struct PatchBody: Encodable { var keep: Bool?; var name: String? }
    private struct SlotBody: Encodable { var modelId: String; var quality: String?; var method: String?; var keepBackground: Bool?; var outfitId: String?; var locationId: String?; var maxUsd: Double?
        var engineModel: String? = nil; var imageModel: String? = nil }
    private struct MatchBody: Encodable { var modelId: String? }

    public func listReferences() async throws -> [RecreateReference] { try await suiteCall("GET", "v1/recreate/references") }
    public func reference(_ id: String) async throws -> RecreateReference { try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))") }
    public func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference {
        let uploadId = try await uploadVideoForAnalysis(file, contentType: contentType, progress: progress)
        return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(CreateBody(uploadId: uploadId, name: name)))
    }
    public func createReference(file: URL, contentType: String, name: String?, sourceUrl: String?, progress: UploadProgress?) async throws -> RecreateReference {
        let uploadId = try await uploadVideoForAnalysis(file, contentType: contentType, progress: progress)
        guard let sourceUrl, !sourceUrl.isEmpty else {
            return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(CreateBody(uploadId: uploadId, name: name)))
        }
        do {
            return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(CreateBody(uploadId: uploadId, name: name, sourceUrl: sourceUrl)))
        } catch let e as ApiError where e.code == "bad_request" {
            // A server whose body is strict and doesn't know `sourceUrl` yet: the same upload, without it.
            return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(CreateBody(uploadId: uploadId, name: name)))
        }
    }
    public func createReference(link: String, name: String?) async throws -> RecreateReference {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw ApiError("link_unsupported", "Paste a link first") }
        return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(LinkBody(url: url, name: name)))
    }
    public func linkSettings() async throws -> RecreateLinkSettings { try await suiteCall("GET", "v1/recreate/settings") }
    public func setStrictLinks(_ on: Bool) async throws -> RecreateLinkSettings {
        try await suiteCall("PATCH", "v1/recreate/settings", body: try JSONEncoder().encode(["strictLinks": on]))
    }
    public func checkLink(_ url: String) async throws -> RecreateLinkCheck {
        try await suiteCall("POST", "v1/recreate/links/check", body: try JSONEncoder().encode(["url": url.trimmingCharacters(in: .whitespacesAndNewlines)]))
    }
    public func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference {
        try await suiteCall("PATCH", "v1/recreate/references/\(try RecreateIds.check(id))", body: try JSONEncoder().encode(PatchBody(keep: keep, name: name)))
    }
    public func deleteReference(_ id: String) async throws { try await suiteSend("DELETE", "v1/recreate/references/\(try RecreateIds.check(id))") }
    public func fill(_ id: String) async throws -> RecreateFill { try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))/fill") }
    public func matchSlots(_ id: String, modelId: String?) async throws {
        let _: JSONValue = try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/match", body: try JSONEncoder().encode(MatchBody(modelId: modelId)))
    }
    public func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?, options: RecreateFillOptions) async throws -> RecreateSlotEstimate {
        let path = "v1/recreate/references/\(try RecreateIds.check(id))/slots/\(try RecreateIds.slot(slotId))/estimate"
        return try await suiteCall("POST", path, body: try JSONEncoder().encode(SlotBody(modelId: modelId, quality: quality, method: options.method, keepBackground: options.keepBackground, outfitId: options.outfitId, locationId: options.locationId, maxUsd: options.maxUsd, engineModel: options.engineModel, imageModel: options.imageModel)))
    }
    public func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?, options: RecreateFillOptions) async throws -> RecreateSlotFillStart {
        let path = "v1/recreate/references/\(try RecreateIds.check(id))/slots/\(try RecreateIds.slot(slotId))/fill"
        return try await suiteCall("POST", path, body: try JSONEncoder().encode(SlotBody(modelId: modelId, quality: quality, method: options.method, keepBackground: options.keepBackground, outfitId: options.outfitId, locationId: options.locationId, maxUsd: options.maxUsd, engineModel: options.engineModel, imageModel: options.imageModel)))
    }
    public func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult {
        try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/apply", body: try JSONEncoder().encode(req))
    }

    private struct ExportBody: Encodable { var sessionId: String; var sound: String }
    /// The server's body is strict: sessionId, take and baseRevision only.
    private struct ReplaceBody: Encodable { var sessionId: String; var take: String; var baseRevision: Int? }

    public func briefsEstimate(_ id: String) async throws -> RecreateBriefsEstimate {
        try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/briefs/estimate", body: Data("{}".utf8))
    }
    public func writeBriefs(_ id: String) async throws -> RecreateBriefsWritten {
        try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/briefs/write", body: Data(#"{"confirm":true}"#.utf8))
    }

    public func replaceSlot(_ id: String, slotId: String, sessionId: String, take: String, baseRevision: Int?) async throws -> RecreateReplaceResult {
        let path = "v1/recreate/references/\(try RecreateIds.check(id))/slots/\(try RecreateIds.slot(slotId))/replace"
        let body = try JSONEncoder().encode(ReplaceBody(sessionId: try EditSessionIds.check(sessionId), take: take, baseRevision: baseRevision))
        return try await suiteCall("POST", path, body: body)
    }

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

    /// Demo mode's link rules: strict, the owner may change them.
    private var strictLinks = true
    public func linkSettings() async throws -> RecreateLinkSettings { with { RecreateLinkSettings(strictLinks: strictLinks, canEdit: true) } }
    public func setStrictLinks(_ on: Bool) async throws -> RecreateLinkSettings {
        with {
            strictLinks = on
            return RecreateLinkSettings(strictLinks: on, canEdit: true)
        }
    }
    /// Demo mode's check: TikTok, Instagram and YouTube links (any https link with strict off) are allowed, the
    /// member's reference from the same link comes back as `cached`, and the refusal words ("private", "too-long"…) are
    /// refused as `createReference(link:)` refuses them.
    public func checkLink(_ url: String) async throws -> RecreateLinkCheck {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let strict = with { strictLinks }
        let known = RecreateLinks.platform(link)
        guard known != nil || (!strict && link.lowercased().hasPrefix("https://")) else {
            return RecreateLinkCheck(allowed: false, code: "link_unsupported", reason: RecreateLinks.message(code: "link_unsupported", message: nil))
        }
        let low = link.lowercased()
        for (word, code) in [("private", "link_private"), ("downloads-off", "link_downloads_off"), ("too-big", "link_too_big"), ("too-long", "too_long"), ("blocked", "link_blocked")]
        where low.contains(word) {
            return RecreateLinkCheck(allowed: false, code: code, reason: RecreateLinks.message(code: code, message: nil))
        }
        let platform = known?.lowercased() ?? "other"
        let hit = with { refs.first { $0.sourceUrl == link } }
        return RecreateLinkCheck(allowed: true, url: link, platform: platform, cached: hit)
    }

    public static func demoJobId(_ slotId: String) -> String { "job_rx_\(slotId)" }

    public func fill(_ id: String) async throws -> RecreateFill {
        let r = try await reference(id)
        let slots = r.recipe?.slots ?? []
        let failSwaps = self.failSwaps
        let (counts, methods, failed): ([String: Int], [String: String], Set<String>) = with {
            for k in (made[id] ?? [:]).keys { made[id]?[k, default: 0] += 1 }
            // A swap that fails (tests): refunded on its second read, and the slot is to be generated instead.
            var gone = Set<String>()
            if failSwaps {
                for (k, n) in made[id] ?? [:] where n >= 2 && fillMethods[id]?[k] == "swap" {
                    made[id]?[k] = nil
                    fillMethods[id]?[k] = nil
                    gone.insert(k)
                }
            }
            return (made[id] ?? [:], fillMethods[id] ?? [:], gone)
        }
        var rows: [[String: Any]] = []
        for (i, s) in slots.enumerated() {
            let estimate: [String: Any] = ["amount": Self.demoPrice, "label": RecreateText.money(Self.demoPrice)]
            if failed.contains(s.id) {
                rows.append(["slotId": s.id, "state": "to_generate", "method": "generate", "fallback": "generate", "failedJobId": Self.demoJobId(s.id),
                             "reason": Self.swapFailedReason, "estimate": estimate])
            } else if let n = counts[s.id] {
                let m = methods[s.id] ?? "generate"
                if n >= 2 {
                    rows.append(["slotId": s.id, "state": "ready", "method": m, "jobId": Self.demoJobId(s.id), "takeId": "t_rx_\(s.id)",
                                 "reason": m == "swap" ? "Swapped into the reference shot" : "Generated for this shot"])
                } else {
                    rows.append(["slotId": s.id, "state": "generating", "method": m, "jobId": Self.demoJobId(s.id), "estimate": estimate])
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

    /// Demo mode can swap (G2): the default method. Tests turn it off to see the fallback to generate.
    public var swapAvailable = true
    /// Tests: swaps fail on their second fill read (refunded), and the slot offers generate instead.
    public var failSwaps = false
    public static let demoSwapPrice = 0.41
    public static let swapFailedReason = "The swap didn’t work and you weren’t charged · generate this shot instead"
    /// referenceId → slotId → the method its fill used.
    private var fillMethods: [String: [String: String]] = [:]

    public static let demoPlatePrice = 0.06
    /// Tests: a generated background plate fails (502 background_failed, nothing charged).
    public var failBackground = false
    /// referenceId/slotId plates already made from the brief (reused free).
    private var plates: Set<String> = []

    /// "Use your own setting" in demo mode: the picked studio location (free), else a plate from the brief.
    private func background(_ id: String, slotId: String, locationId: String?) -> RecreateBackground {
        if let locationId {
            let name = FakeMuseAPI.demoLocations.first { $0.id == locationId }?.name ?? "Your location"
            return RecreateBackground(source: "location", locationId: locationId, name: name, matched: false, usd: 0)
        }
        let reused = with { plates.contains("\(id)/\(slotId)") }
        return RecreateBackground(source: "generated", setting: "a bright studio", usd: reused ? 0 : Self.demoPlatePrice, reused: reused)
    }

    private func method(_ asked: String?) throws -> (method: String, unavailable: String?) {
        if asked == "generate" { return ("generate", nil) }
        if swapAvailable { return ("swap", nil) }
        if asked == "swap" { throw ApiError("swap_unavailable", "Swapping isn’t available right now · generate this shot instead") }
        return ("generate", "Swapping isn’t available right now, so this shot is generated")
    }

    public func estimateSlot(_ id: String, slotId: String, modelId: String, quality: String?, options: RecreateFillOptions) async throws -> RecreateSlotEstimate {
        _ = try RecreateIds.slot(slotId)
        let r = try await reference(id)
        guard let s = r.recipe?.slots.first(where: { $0.id == slotId }) else { throw ApiError("not_found", "That shot is gone") }
        let m = try method(options.method)
        if m.method == "swap" {
            let seg = RecreateSlotEstimate.Segment(startSec: s.startSec, endSec: s.endSec)
            let secs = (max(2, s.length) * 10).rounded() / 10
            // "Use your own setting": a studio location (free), else a plate from the brief ($0.06 the first time).
            let bg = options.keepBackground == false ? background(id, slotId: slotId, locationId: options.locationId) : nil
            let total = Self.demoSwapPrice + (bg?.usd ?? 0)
            let price = RecreateText.money(total)
            let e = ShotEstimate(quality: quality ?? "standard", label: "Swap · \(String(format: "%.1f", secs)) s", resolution: "720p", seconds: secs, takes: 1,
                                 mode: "swap", estimate: total, priceLine: "about \(price) · \(String(format: "%.1f", secs)) s",
                                 buttonLabel: "Swap in · \(String(format: "%.1f", secs)) s · \(price)", test: true)
            let paid = (bg?.usd ?? 0) > 0
            return RecreateSlotEstimate(slotId: slotId, estimate: e, method: "swap", keepBackground: options.keepBackground ?? true, segment: seg,
                                        baked: ["camera", "speed", "look"], background: bg,
                                        swapUsd: paid ? Self.demoSwapPrice : nil, backgroundUsd: paid ? bg?.usd : nil)
        }
        let secs = max(2, s.length.rounded(.up))
        let price = RecreateText.money(Self.demoPrice)
        let e = ShotEstimate(quality: quality ?? "standard", label: "Shot · Standard", resolution: "768p", seconds: secs, takes: 1, mode: "reference",
                             estimate: Self.demoPrice, priceLine: "about \(price) · \(Int(secs)) s", buttonLabel: "Generate · \(Int(secs)) s · \(price)", test: true)
        return RecreateSlotEstimate(slotId: slotId, estimate: e, method: "generate", swapUnavailable: m.unavailable,
                                    promptFrom: s.brief == nil ? "summary" : "brief")
    }

    public func fillSlot(_ id: String, slotId: String, modelId: String, quality: String?, options: RecreateFillOptions) async throws -> RecreateSlotFillStart {
        _ = try RecreateIds.slot(slotId)
        let r = try await reference(id)
        guard let i = r.recipe?.slots.firstIndex(where: { $0.id == slotId }) else { throw ApiError("not_found", "That shot is gone") }
        let m = try method(options.method)
        var cost = m.method == "swap" ? Self.demoSwapPrice : Self.demoPrice
        let bg = m.method == "swap" && options.keepBackground == false ? background(id, slotId: slotId, locationId: options.locationId) : nil
        cost += bg?.usd ?? 0
        // The confirmed price (maxUsd): a swap that now costs more is refused with the new price.
        if let max = options.maxUsd, cost > max + 0.005 {
            throw ApiError("price_changed", "The price changed to \(RecreateText.money(cost)). Check it and build again.")
        }
        if let bg, bg.source == "generated", bg.usd > 0 {
            if failBackground { throw ApiError("background_failed", "The background photo couldn’t be made · you weren’t charged. Try again, or pick a location") }
            _ = with { plates.insert("\(id)/\(slotId)") }
        }
        try with {
            // A shot still being made is never started twice; a finished one can be made again ("Regenerate this shot").
            if let n = made[id]?[slotId], n < 2 { throw ApiError("already_filled", "This shot is already being made") }
            made[id, default: [:]][slotId] = 0
            fillMethods[id, default: [:]][slotId] = m.method
        }
        let job = Job(id: Self.demoJobId(slotId), title: "Shot \(i + 1)", modelId: modelId, modelName: "", outfitId: options.outfitId ?? "",
                      request: JobRequest(title: "Shot \(i + 1)", modelId: modelId, outfitId: options.outfitId ?? "", clipId: "", engine: "suite"),
                      state: "queued", cost: cost)
        let s = r.recipe!.slots[i]
        return RecreateSlotFillStart(slotId: slotId, job: job, method: m.method,
                                     segment: m.method == "swap" ? RecreateSlotEstimate.Segment(startSec: s.startSec, endSec: s.endSec) : nil)
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

    /// Demo mode can write briefs (priced, nothing charged). Tests turn it off to see the reason.
    public var briefsAvailable = true
    public static let demoBriefsPrice = 0.02

    public func briefsEstimate(_ id: String) async throws -> RecreateBriefsEstimate {
        let r = try await reference(id)
        let missing = r.recipe?.slotsWithoutBriefs ?? []
        guard briefsAvailable else {
            return RecreateBriefsEstimate(available: false, reason: "Turn on Claude on the server in Settings → Claude, or ask Claude on this Mac to write them for free.",
                                          slots: missing.count, estimateUsd: 0, label: "Write the shot briefs")
        }
        let price = RecreateText.money(Self.demoBriefsPrice)
        return RecreateBriefsEstimate(available: true, slots: missing.count, estimateUsd: Self.demoBriefsPrice,
                                      label: "Write the shot briefs · about \(price)", priceLine: "about \(price) for \(missing.count == 1 ? "1 shot" : "\(missing.count) shots")")
    }

    public func writeBriefs(_ id: String) async throws -> RecreateBriefsWritten {
        guard briefsAvailable else { throw ApiError("briefs_unavailable", "Writing briefs on the server is off. Turn it on in Settings → Claude.") }
        return try with {
            guard let i = refs.firstIndex(where: { $0.id == id }), var recipe = refs[i].recipe else { throw ApiError("not_found", "That reference is gone") }
            var written: [String] = []
            for k in recipe.slots.indices where RecreateText.brief(recipe.slots[k].brief) == nil {
                let n = k + 1
                recipe.slots[k].brief = Recipe.Slot.Brief(shotSize: n == 1 ? "ls" : "ms", angle: "eye", subject: "she",
                                                          action: n == 1 ? "walks into frame" : "turns to camera", location: "a studio", notes: nil)
                written.append(recipe.slots[k].id)
            }
            refs[i].recipe = recipe
            return RecreateBriefsWritten(referenceId: id, written: written, costUsd: written.isEmpty ? 0 : Self.demoBriefsPrice, reference: refs[i])
        }
    }

    /// referenceId → the session it was built into, its revision, and the slots in the edit (Fix shot).
    private var built: [String: (session: String, revision: Int, slots: Set<String>)] = [:]

    public func replaceSlot(_ id: String, slotId: String, sessionId: String, take: String, baseRevision: Int?) async throws -> RecreateReplaceResult {
        _ = try RecreateIds.slot(slotId)
        let r = try await reference(id)
        guard let i = r.recipe?.slots.firstIndex(where: { $0.id == slotId }) else { throw ApiError("not_found", "Slot not found") }
        return try with {
            guard let b = built[id], b.session == sessionId else {
                throw ApiError("not_built_here", "Build the edit from this reference in this session first")
            }
            guard b.slots.contains(slotId) else {
                throw ApiError("slot_not_in_edit", "Shot \(slotId) isn’t in the edit any more · rebuild the edit to put it back")
            }
            if take.hasPrefix("job_rx_") {
                let slot = String(take.dropFirst("job_rx_".count))
                guard let n = made[id]?[slot] else { throw ApiError("bad_request", "take: no video take or job \(take)") }
                if n < 2 { throw ApiError("job_not_done", "That shot is still being made · try again when it’s done") }
            } else if take.isEmpty || take.contains("unknown") {
                throw ApiError("bad_request", "take: no video take or job \(take)")
            }
            let rev = b.revision + 1
            built[id]?.revision = rev
            let takeId = take.hasPrefix("job_rx_") ? "t_rx_\(take.dropFirst("job_rx_".count))" : take
            // The slot's own swap is baked in; any other take brings the reference's camera keys, ramp and look back.
            let ownSwap = take == Self.demoJobId(slotId) && fillMethods[id]?[slotId] == "swap"
            return RecreateReplaceResult(sessionId: sessionId, revision: rev, slotId: slotId, itemId: "c\(i + 1)", takeId: takeId, inSec: 0,
                                         label: "Replaced shot \(slotId) in “\(r.name ?? "Reference")”", baked: ownSwap ? ["camera", "speed", "look"] : nil)
        }
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
        let inEdit = Set(req.slots.keys).subtracting(waiting)
        // Slots filled by their own finished swap carry the reference's camera, speed and look already.
        let swapped: [String: String] = with { fillMethods[id] ?? [:] }
        var baked: [String: [String]] = [:]
        for (slot, v) in req.slots where inEdit.contains(slot) && v == Self.demoJobId(slot) && swapped[slot] == "swap" { baked[slot] = ["camera", "speed", "look"] }
        with { built[id] = (req.sessionId, (req.baseRevision ?? 0) + 1, inEdit) }
        let json: [String: Any] = ["sessionId": req.sessionId, "revision": (req.baseRevision ?? 0) + 1, "label": "Recreated", "missing": none, "waiting": waiting,
                                   "match": match, "baked": baked]
        return try JSONDecoder().decode(RecreateApplyResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
