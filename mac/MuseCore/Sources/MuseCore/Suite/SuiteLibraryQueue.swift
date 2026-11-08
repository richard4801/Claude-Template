import Foundation

// Library collections and the Suite queue (plans/api.md "Library collections and the Suite queue", WS1 build step 3,
// migration 0020; plans/ai-suite-design.md refinements 1 and 6). Wire types (decoded leniently), the calls, and their
// HTTP and demo implementations. Server: server/api/src/suite/collections.ts and queue.ts.

// MARK: Collections

/// A named group of the studio's takes and photos. The whole studio sees it; its maker or the owner edits it (`canEdit`).
public struct LibraryCollection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var userId: String
    public var mine: Bool
    public var canEdit: Bool
    /// Takes and photos that still exist.
    public var count: Int
    /// The newest item's thumb.
    public var cover: ImageRef?
    public var createdAt: Int64
    public var updatedAt: Int64
    /// Present on the single-collection calls (newest added first).
    public var takeIds: [String]?

    /// A name is 1–60 characters (trimmed); 200 collections per studio, 2,000 items per collection.
    public static let maxName = 60
    public static let maxPerStudio = 200
    public static let maxItems = 2000

    public init(id: String, name: String, userId: String = "", mine: Bool = true, canEdit: Bool = true, count: Int = 0, cover: ImageRef? = nil,
                createdAt: Int64 = 0, updatedAt: Int64 = 0, takeIds: [String]? = nil) {
        self.id = id
        self.name = name
        self.userId = userId
        self.mine = mine
        self.canEdit = canEdit
        self.count = count
        self.cover = cover
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.takeIds = takeIds
    }

    enum CodingKeys: String, CodingKey { case id, name, userId, mine, canEdit, count, cover, createdAt, updatedAt, takeIds }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, "")
        userId = c.v(.userId, "")
        mine = c.v(.mine, false)
        canEdit = c.v(.canEdit, false)
        count = c.v(.count, 0)
        cover = c.o(.cover)
        createdAt = SuiteTime.ms(c, .createdAt)
        updatedAt = SuiteTime.ms(c, .updatedAt)
        takeIds = c.o(.takeIds)
    }

    /// The name as the server stores it (trimmed), or the message it refuses it with.
    public static func cleanName(_ raw: String) -> Result<String, ApiError> {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return .failure(ApiError("bad_request", "Give the collection a name")) }
        if n.count > maxName { return .failure(ApiError("bad_request", "A collection's name is up to \(maxName) characters")) }
        return .success(n)
    }
}

// MARK: The queue

/// A shot saved to run later: checked and priced, nothing held. `buttonLabel` is "Run · $0.40".
public struct QueuedShot: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var tool: String
    public var modelId: String?
    public var userId: String
    public var mine: Bool
    public var estimate: Double
    public var buttonLabel: String
    public var prompt: String?
    public var draft: SuiteDraft?
    public var createdAt: Int64

    public init(id: String, title: String, tool: String = "shot", modelId: String? = nil, userId: String = "", mine: Bool = true, estimate: Double = 0,
                buttonLabel: String = "", prompt: String? = nil, draft: SuiteDraft? = nil, createdAt: Int64 = 0) {
        self.id = id
        self.kind = "queued"
        self.title = title
        self.tool = tool
        self.modelId = modelId
        self.userId = userId
        self.mine = mine
        self.estimate = estimate
        self.buttonLabel = buttonLabel.isEmpty ? QueuedShot.runLabel(estimate) : buttonLabel
        self.prompt = prompt
        self.draft = draft
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, kind, title, tool, modelId, userId, mine, estimate, buttonLabel, prompt, draft, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.v(.kind, "queued")
        title = c.v(.title, "")
        tool = c.v(.tool, "shot")
        modelId = c.o(.modelId)
        userId = c.v(.userId, "")
        mine = c.v(.mine, false)
        estimate = c.v(.estimate, 0)
        let label: String = c.v(.buttonLabel, "")
        buttonLabel = label.isEmpty ? QueuedShot.runLabel(estimate) : label
        prompt = c.o(.prompt)
        draft = c.o(.draft)
        createdAt = SuiteTime.ms(c, .createdAt)
    }

    /// "Run · $0.40" (the server's wording when it sends none).
    public static func runLabel(_ amount: Double) -> String { "Run · \(Pricing.money(amount))" }

    /// Up to 50 per member (`409 queue_full`).
    public static let maxPerMember = 50
}

/// `POST /v1/suite/queue/{id}/estimate`: today's price. `changed`: it differs from the stored one (show it, then confirm).
public struct QueuedEstimate: Decodable, Hashable, Sendable {
    public var item: QueuedShot
    public var estimateView: ShotEstimate?
    public var changed: Bool

    public init(item: QueuedShot, estimateView: ShotEstimate? = nil, changed: Bool = false) {
        self.item = item
        self.estimateView = estimateView
        self.changed = changed
    }

    enum CodingKeys: String, CodingKey { case estimateView, changed }
    public init(from d: Decoder) throws {
        item = try QueuedShot(from: d)
        let c = try d.container(keyedBy: CodingKeys.self)
        estimateView = c.o(.estimateView)
        changed = c.v(.changed, false)
    }
}

/// `POST /v1/suite/queue/{id}/run {confirm: true}` → the job it became; the queue entry is gone.
public struct QueueRunResult: Decodable, Hashable, Sendable {
    public var queuedId: String
    public var job: Job

    public init(queuedId: String, job: Job) {
        self.queuedId = queuedId
        self.job = job
    }

    enum CodingKeys: String, CodingKey { case queuedId, job }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        queuedId = c.v(.queuedId, "")
        job = try c.decode(Job.self, forKey: .job)
    }
}

// MARK: The calls

public protocol LibraryQueueAPI: Sendable {
    /// GET /v1/library/collections: most recently changed first.
    func collections() async throws -> [LibraryCollection]
    /// POST /v1/library/collections {name, takeIds?}
    func createCollection(name: String, takeIds: [String]) async throws -> LibraryCollection
    /// GET /v1/library/collections/{id} (with `takeIds`)
    func collection(_ id: String) async throws -> LibraryCollection
    /// PATCH /v1/library/collections/{id} {name}
    func renameCollection(_ id: String, name: String) async throws -> LibraryCollection
    /// DELETE /v1/library/collections/{id}: the takes stay in the library.
    func deleteCollection(_ id: String) async throws
    /// POST …/{id}/items {takeIds}
    func addToCollection(_ id: String, takeIds: [String]) async throws -> LibraryCollection
    /// POST …/{id}/items/remove {takeIds}
    func removeFromCollection(_ id: String, takeIds: [String]) async throws -> LibraryCollection
    /// GET /v1/library/takes/{takeId}/collections
    func collections(ofTake takeId: String) async throws -> [LibraryCollection]

    /// POST /v1/suite/queue {the body of POST /v1/suite/shots}: checked and priced, nothing held.
    func queueShot(_ req: ShotRequest) async throws -> QueuedShot
    /// GET /v1/suite/queue: newest first (a member's own; the owner sees the studio's).
    func queuedShots() async throws -> [QueuedShot]
    /// POST /v1/suite/queue/{id}/estimate: today's price.
    func estimateQueued(_ id: String) async throws -> QueuedEstimate
    /// POST /v1/suite/queue/{id}/run {confirm: true}: only after the person confirmed the price.
    func runQueued(_ id: String) async throws -> QueueRunResult
    /// DELETE /v1/suite/queue/{id}: nothing was held.
    func removeQueued(_ id: String) async throws
}

struct CollectionBody: Encodable {
    var name: String?
    var takeIds: [String]?
}

struct TakeIdsBody: Encodable { var takeIds: [String] }
struct QueueRunConfirmBody: Encodable { var confirm = true }

extension HTTPMuseAPI: LibraryQueueAPI {
    private func json<B: Encodable>(_ b: B) throws -> Data { try JSONEncoder().encode(b) }
    private func fixed(_ c: LibraryCollection) -> LibraryCollection {
        var out = c
        out.cover = absolutize(c.cover)
        return out
    }

    public func collections() async throws -> [LibraryCollection] {
        (try await suiteCall("GET", "v1/library/collections") as [LibraryCollection]).map(fixed)
    }
    public func createCollection(name: String, takeIds: [String]) async throws -> LibraryCollection {
        fixed(try await suiteCall("POST", "v1/library/collections", body: json(CollectionBody(name: name, takeIds: takeIds.isEmpty ? nil : takeIds))))
    }
    public func collection(_ id: String) async throws -> LibraryCollection {
        fixed(try await suiteCall("GET", "v1/library/collections/\(Self.pathKey(id))"))
    }
    public func renameCollection(_ id: String, name: String) async throws -> LibraryCollection {
        fixed(try await suiteCall("PATCH", "v1/library/collections/\(Self.pathKey(id))", body: json(CollectionBody(name: name))))
    }
    public func deleteCollection(_ id: String) async throws {
        try await suiteSend("DELETE", "v1/library/collections/\(Self.pathKey(id))")
    }
    public func addToCollection(_ id: String, takeIds: [String]) async throws -> LibraryCollection {
        fixed(try await suiteCall("POST", "v1/library/collections/\(Self.pathKey(id))/items", body: json(TakeIdsBody(takeIds: takeIds))))
    }
    public func removeFromCollection(_ id: String, takeIds: [String]) async throws -> LibraryCollection {
        fixed(try await suiteCall("POST", "v1/library/collections/\(Self.pathKey(id))/items/remove", body: json(TakeIdsBody(takeIds: takeIds))))
    }
    public func collections(ofTake takeId: String) async throws -> [LibraryCollection] {
        (try await suiteCall("GET", "v1/library/takes/\(Self.pathKey(takeId))/collections") as [LibraryCollection]).map(fixed)
    }

    public func queueShot(_ req: ShotRequest) async throws -> QueuedShot {
        var r = req
        r.dryRun = nil
        return try await suiteCall("POST", "v1/suite/queue", body: json(r))
    }
    public func queuedShots() async throws -> [QueuedShot] { try await suiteCall("GET", "v1/suite/queue") }
    public func estimateQueued(_ id: String) async throws -> QueuedEstimate {
        try await suiteCall("POST", "v1/suite/queue/\(Self.pathKey(id))/estimate", body: json([String: String]()))
    }
    public func runQueued(_ id: String) async throws -> QueueRunResult {
        var r: QueueRunResult = try await suiteCall("POST", "v1/suite/queue/\(Self.pathKey(id))/run", body: json(QueueRunConfirmBody()))
        r.job = absolutize(r.job)
        return r
    }
    public func removeQueued(_ id: String) async throws {
        try await suiteSend("DELETE", "v1/suite/queue/\(Self.pathKey(id))")
    }
}

// MARK: Demo mode (same rules and wording as the server)

/// A demo collection as stored: its items newest first.
struct FakeCollection: Sendable {
    var id: String
    var name: String
    var userId: String
    var takeIds: [String]
    var createdAt: Int64
    var updatedAt: Int64
}

/// A demo queued shot and the request it runs.
struct FakeQueued: Sendable {
    var item: QueuedShot
    var request: ShotRequest
}

extension FakeMuseAPI: LibraryQueueAPI {
    private func collectionView(_ c: FakeCollection, withItems: Bool) -> LibraryCollection {
        let live = c.takeIds.filter { id in takes.contains { $0.id == id } }
        let cover = live.first.flatMap { id in takes.first { $0.id == id }?.thumb }
        let me = suiteUserId
        return LibraryCollection(id: c.id, name: c.name, userId: c.userId, mine: c.userId == me, canEdit: suiteIsOwner || c.userId == me,
                                 count: live.count, cover: cover, createdAt: c.createdAt, updatedAt: c.updatedAt, takeIds: withItems ? live : nil)
    }

    private func collectionIndex(_ id: String) throws -> Int {
        guard let i = libraryCollections.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Collection not found") }
        return i
    }

    private func editableCollection(_ id: String) throws -> Int {
        let i = try collectionIndex(id)
        guard suiteIsOwner || libraryCollections[i].userId == suiteUserId else {
            throw ApiError("not_yours", "Only the one who made this collection, or the owner, can change it")
        }
        return i
    }

    private func checkTakeIds(_ ids: [String]) throws {
        if ids.count > 200 { throw ApiError("bad_request", "takeIds: up to 200 at a time") }
        if let bad = ids.first(where: { id in !takes.contains { $0.id == id } }) {
            throw ApiError("bad_request", "takeIds: no take or photo \"\(bad)\" in this studio")
        }
    }

    public func collections() async throws -> [LibraryCollection] {
        libraryCollections.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id > $1.id }.map { collectionView($0, withItems: false) }
    }

    public func createCollection(name: String, takeIds: [String]) async throws -> LibraryCollection {
        let clean = try LibraryCollection.cleanName(name).get()
        if libraryCollections.count >= LibraryCollection.maxPerStudio {
            throw ApiError("too_many_collections", "A studio can keep \(LibraryCollection.maxPerStudio) collections · delete one first")
        }
        try checkTakeIds(takeIds)
        let now = nowMs()
        var unique: [String] = []
        for id in takeIds.reversed() where !unique.contains(id) { unique.append(id) }
        let c = FakeCollection(id: "col_" + shortId(), name: clean, userId: suiteUserId, takeIds: unique, createdAt: now, updatedAt: now)
        libraryCollections.append(c)
        return collectionView(c, withItems: true)
    }

    public func collection(_ id: String) async throws -> LibraryCollection { collectionView(libraryCollections[try collectionIndex(id)], withItems: true) }

    public func renameCollection(_ id: String, name: String) async throws -> LibraryCollection {
        let clean = try LibraryCollection.cleanName(name).get()
        let i = try editableCollection(id)
        libraryCollections[i].name = clean
        libraryCollections[i].updatedAt = max(nowMs(), libraryCollections[i].updatedAt + 1)
        return collectionView(libraryCollections[i], withItems: true)
    }

    public func deleteCollection(_ id: String) async throws {
        let i = try editableCollection(id)
        libraryCollections.remove(at: i)
    }

    public func addToCollection(_ id: String, takeIds: [String]) async throws -> LibraryCollection {
        let i = try editableCollection(id)
        try checkTakeIds(takeIds)
        var list = libraryCollections[i].takeIds
        for t in takeIds where !list.contains(t) { list.insert(t, at: 0) }
        if list.count > LibraryCollection.maxItems {
            throw ApiError("collection_full", "A collection holds up to \(LibraryCollection.maxItems) takes and photos")
        }
        libraryCollections[i].takeIds = list
        libraryCollections[i].updatedAt = max(nowMs(), libraryCollections[i].updatedAt + 1)
        return collectionView(libraryCollections[i], withItems: true)
    }

    public func removeFromCollection(_ id: String, takeIds: [String]) async throws -> LibraryCollection {
        let i = try editableCollection(id)
        libraryCollections[i].takeIds.removeAll { takeIds.contains($0) }
        libraryCollections[i].updatedAt = max(nowMs(), libraryCollections[i].updatedAt + 1)
        return collectionView(libraryCollections[i], withItems: true)
    }

    public func collections(ofTake takeId: String) async throws -> [LibraryCollection] {
        try await collections().filter { c in libraryCollections.first { $0.id == c.id }?.takeIds.contains(takeId) ?? false }
    }

    /// The take ids of a collection, for the feed's `collection` filter (nil: unknown collection).
    func collectionTakeIds(_ id: String) -> Set<String>? {
        libraryCollections.first { $0.id == id }.map { Set($0.takeIds) }
    }

    // Queue

    private func queuedView(_ q: FakeQueued) -> QueuedShot {
        var v = q.item
        v.mine = q.item.userId == suiteUserId
        return v
    }

    /// Each member sees their own queue; the owner sees the studio's.
    func visibleQueue() -> [QueuedShot] {
        let me = suiteUserId
        return suiteQueue.filter { suiteIsOwner || $0.item.userId == me }.map(queuedView).sorted { $0.createdAt > $1.createdAt }
    }

    public func queueShot(_ req: ShotRequest) async throws -> QueuedShot {
        let me = suiteUserId
        if suiteQueue.filter({ $0.item.userId == me }).count >= QueuedShot.maxPerMember {
            throw ApiError("queue_full", "You can queue \(QueuedShot.maxPerMember) shots · run or remove one first")
        }
        var r = req
        r.dryRun = nil
        let e = try await suiteEstimate(r)
        if let p = e.problem { throw ApiError(e.code ?? "bad_request", p) }
        let title = r.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(r.prompt.prefix(60))
        let item = QueuedShot(id: "q_" + shortId(), title: title.isEmpty ? "Shot" : title, tool: r.draft?.tool ?? "shot", modelId: r.modelId, userId: me,
                              mine: true, estimate: e.estimate, buttonLabel: QueuedShot.runLabel(e.estimate), prompt: r.prompt, draft: r.draft, createdAt: nowMs())
        suiteQueue.append(FakeQueued(item: item, request: r))
        return item
    }

    public func queuedShots() async throws -> [QueuedShot] { visibleQueue() }

    private func queueIndex(_ id: String) throws -> Int {
        let me = suiteUserId
        guard let i = suiteQueue.firstIndex(where: { $0.item.id == id && (suiteIsOwner || $0.item.userId == me) }) else {
            throw ApiError("not_found", "Queued shot not found")
        }
        return i
    }

    public func estimateQueued(_ id: String) async throws -> QueuedEstimate {
        let i = try queueIndex(id)
        let e = try await suiteEstimate(suiteQueue[i].request)
        let changed = abs(e.estimate - suiteQueue[i].item.estimate) > 0.0001
        suiteQueue[i].item.estimate = e.estimate
        suiteQueue[i].item.buttonLabel = QueuedShot.runLabel(e.estimate)
        return QueuedEstimate(item: queuedView(suiteQueue[i]), estimateView: e, changed: changed)
    }

    public func runQueued(_ id: String) async throws -> QueueRunResult {
        let i = try queueIndex(id)
        let q = suiteQueue[i]
        let job = try await suiteCreateShot(q.request)
        if let j = suiteQueue.firstIndex(where: { $0.item.id == id }) { suiteQueue.remove(at: j) }
        return QueueRunResult(queuedId: id, job: job)
    }

    public func removeQueued(_ id: String) async throws {
        let i = try queueIndex(id)
        suiteQueue.remove(at: i)
    }
}
