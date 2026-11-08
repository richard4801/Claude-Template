import Foundation

/// "Recreate this edit" endpoints (plans/api.md "Recreate this edit", workstream 1's server).
public protocol RecreateAPI: Sendable {
    func listReferences() async throws -> [RecreateReference]
    func reference(_ id: String) async throws -> RecreateReference
    /// Uploads the video (≤ 60 s) and starts its analysis; returns the reference in `analyzing`.
    func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference
    func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference
    func deleteReference(_ id: String) async throws
    func fill(_ id: String) async throws -> RecreateFill
    func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult
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
}

// MARK: HTTP

extension HTTPMuseAPI: RecreateAPI {
    private struct CreateBody: Encodable { var uploadId: String; var name: String? }
    private struct PatchBody: Encodable { var keep: Bool?; var name: String? }

    public func listReferences() async throws -> [RecreateReference] { try await suiteCall("GET", "v1/recreate/references") }
    public func reference(_ id: String) async throws -> RecreateReference { try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))") }
    public func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference {
        let uploadId = try await uploadVideoForAnalysis(file, contentType: contentType, progress: progress)
        return try await suiteCall("POST", "v1/recreate/references", body: try JSONEncoder().encode(CreateBody(uploadId: uploadId, name: name)))
    }
    public func patchReference(_ id: String, keep: Bool?, name: String?) async throws -> RecreateReference {
        try await suiteCall("PATCH", "v1/recreate/references/\(try RecreateIds.check(id))", body: try JSONEncoder().encode(PatchBody(keep: keep, name: name)))
    }
    public func deleteReference(_ id: String) async throws { try await suiteSend("DELETE", "v1/recreate/references/\(try RecreateIds.check(id))") }
    public func fill(_ id: String) async throws -> RecreateFill { try await suiteCall("GET", "v1/recreate/references/\(try RecreateIds.check(id))/fill") }
    public func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult {
        try await suiteCall("POST", "v1/recreate/references/\(try RecreateIds.check(id))/apply", body: try JSONEncoder().encode(req))
    }

    /// Absolute URL for an authenticated reference route ("/v1/recreate/…/video" or a full link); load with `sessionToken`.
    public func recreateMediaURL(_ link: String?) -> URL? { link.flatMap { resolve($0) } }
}

// MARK: Demo

/// Demo mode: one ready reference (workstream 1's fixture) and a fill that matches one slot from the takes and leaves
/// two to generate. Nothing is uploaded or charged; a new reference is analysed instantly.
public final class FakeRecreateAPI: RecreateAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [RecreateReference]

    public init() {
        let sample = try? JSONDecoder().decode(RecreateReference.self, from: Data(RecreateDemo.referenceJSON.utf8))
        refs = sample.map { [$0] } ?? []
    }

    private func with<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }

    public func listReferences() async throws -> [RecreateReference] { with { refs } }
    public func reference(_ id: String) async throws -> RecreateReference {
        try with { guard let r = refs.first(where: { $0.id == id }) else { throw ApiError("not_found", "That reference is gone") }; return r }
    }
    public func createReference(file: URL, contentType: String, name: String?, progress: UploadProgress?) async throws -> RecreateReference {
        try with {
            guard var r = refs.first else { throw ApiError("not_found", "No sample in demo mode") }
            r.id = "rx_demo\(refs.count + 1)"
            r.name = name ?? file.deletingPathExtension().lastPathComponent
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
    public func fill(_ id: String) async throws -> RecreateFill {
        let r = try await reference(id)
        let slots = r.recipe?.slots ?? []
        var rows: [[String: Any]] = []
        for (i, s) in slots.enumerated() {
            if i == 0 {
                rows.append(["slotId": s.id, "state": "matched", "takeId": "t1", "score": 0.82, "reason": "Your take has the same pan on a wide shot"])
            } else {
                let estimate: [String: Any] = ["amount": 0.64, "label": "$0.64"]
                rows.append(["slotId": s.id, "state": "to_generate", "estimate": estimate])
            }
        }
        let json: [String: Any] = ["referenceId": id, "slots": rows]
        return try JSONDecoder().decode(RecreateFill.self, from: JSONSerialization.data(withJSONObject: json))
    }
    public func apply(_ id: String, _ req: RecreateApplyRequest) async throws -> RecreateApplyResult {
        let slots = (try? await reference(id))?.recipe?.slots.map(\.id) ?? []
        let scores = [0.93, 0.81, 0.84]
        let perSlot: [[String: Any]] = slots.enumerated().map { i, s in ["slotId": s, "score": scores[i % scores.count]] }
        let match: [String: Any] = ["overall": 0.86, "cuts": 0.97, "text": 0.9, "ramps": 0.78, "grade": 0.84, "shots": 0.8, "perSlot": perSlot]
        let none: [String] = []
        let json: [String: Any] = ["sessionId": req.sessionId, "revision": (req.baseRevision ?? 0) + 1, "label": "Recreated", "missing": none, "waiting": none, "match": match]
        return try JSONDecoder().decode(RecreateApplyResult.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
