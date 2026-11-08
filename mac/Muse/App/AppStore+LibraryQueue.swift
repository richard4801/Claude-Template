import MuseCore
import SwiftUI

// Library collections and the Suite queue (plans/api.md "Library collections and the Suite queue", build step 3;
// plans/ai-suite-design.md refinements 1 and 6). Collections: the whole studio sees them; the maker or the owner edits
// (`canEdit`). The queue: a shot saved to run later, priced but nothing held; Run prices it again and asks before it
// spends.
@Observable @MainActor
final class LibraryState {
    /// GET /v1/library/collections, most recently changed first.
    var collections: [LibraryCollection] = []
    /// Library's collection filter and the takes in it (newest added first).
    var galleryCollection: String?
    var galleryCollectionTakes: [String] = []
}

extension AppStore {
    var libraryAPI: (any LibraryQueueAPI)? { api as? any LibraryQueueAPI }

    // MARK: Collections

    func loadCollections() async {
        guard let l = libraryAPI else { return }
        if let list = try? await l.collections() { library.collections = list }
        if let id = library.galleryCollection { await loadGalleryCollection(id) }
    }

    /// The collections this person can put takes in.
    var editableCollections: [LibraryCollection] { library.collections.filter(\.canEdit) }

    func setGalleryCollection(_ id: String?) {
        library.galleryCollection = id
        library.galleryCollectionTakes = []
        guard let id else { return }
        Task { await loadGalleryCollection(id) }
    }

    private func loadGalleryCollection(_ id: String) async {
        guard let l = libraryAPI, let c = try? await l.collection(id) else { return }
        if library.galleryCollection == id { library.galleryCollectionTakes = c.takeIds ?? [] }
    }

    /// A new collection, optionally with takes in it.
    func createCollection(named raw: String, takeIds: [String] = []) {
        guard let l = libraryAPI else { return }
        let name: String
        switch LibraryCollection.cleanName(raw) {
        case .success(let n): name = n
        case .failure(let e): showToast(e.message); return
        }
        perform { [self] in
            let c = try await l.createCollection(name: name, takeIds: takeIds)
            upsertCollection(c)
            showToast(takeIds.isEmpty ? "Made \(c.name)" : "Saved to \(c.name)")
        }
    }

    /// Puts the takes in the collection, or takes them out when they're all already in it.
    func toggleInCollection(_ c: LibraryCollection, takeIds: [String], inIt: Bool) {
        guard let l = libraryAPI else { return }
        perform { [self] in
            let out = inIt ? try await l.removeFromCollection(c.id, takeIds: takeIds) : try await l.addToCollection(c.id, takeIds: takeIds)
            upsertCollection(out)
            showToast(inIt ? "Removed from \(out.name)" : "Saved to \(out.name)")
        }
    }

    func renameCollection(_ c: LibraryCollection, to raw: String) {
        guard let l = libraryAPI else { return }
        guard case .success(let name) = LibraryCollection.cleanName(raw) else { return }
        perform { [self] in upsertCollection(try await l.renameCollection(c.id, name: name)) }
    }

    func deleteCollection(_ c: LibraryCollection) {
        guard let l = libraryAPI else { return }
        perform { [self] in
            try await l.deleteCollection(c.id)
            library.collections.removeAll { $0.id == c.id }
            if library.galleryCollection == c.id { setGalleryCollection(nil) }
            if suite.feedCollection == c.id { suite.feedCollection = nil }
            showToast("Deleted \(c.name). Its takes stay in the library.")
        }
    }

    private func upsertCollection(_ c: LibraryCollection) {
        var list = library.collections.filter { $0.id != c.id }
        var row = c
        row.takeIds = nil
        list.insert(row, at: 0)
        library.collections = list
        if library.galleryCollection == c.id, let ids = c.takeIds { library.galleryCollectionTakes = ids }
    }

    /// The collections a take is in (its "Save to collection" list shows them checked).
    func collections(of takeId: String) async -> Set<String> {
        guard let l = libraryAPI, let list = try? await l.collections(ofTake: takeId) else { return [] }
        return Set(list.map(\.id))
    }

    // MARK: The Suite queue

    /// The composer's tools whose request is a Suite shot (the queue takes the body of POST /v1/suite/shots).
    var canQueue: Bool {
        switch suite.composer.tool {
        case .shot, .talking, .ugc: return libraryAPI != nil && !isComingSoon(suite.composer.tool)
        default: return false
        }
    }

    /// "Add to queue": checked and priced like an estimate, nothing held.
    func addShotToQueue() {
        guard let l = libraryAPI else { return }
        if let p = suite.estimate?.problem { return showToast(p) }
        if suite.composerSlots.slots.uploading { return showToast("Wait for the upload to finish") }
        if let need = suite.composer.missing(suite.composerSlots.slots) { return showToast(need) }
        var req = shotRequest
        req.draft = ComposerDrafts.draft(suite.composer)
        if req.prompt.isEmpty && req.modelId == nil && req.frames == nil { return showToast("Describe the scene or pick a character first") }
        perform { [self] in
            let q = try await l.queueShot(req)
            suite.queued.removeAll { $0.id == q.id }
            suite.queued.insert(q, at: 0)
            showToast("Queued \(q.title) · nothing is charged until you run it", action: "Show queue") { [weak self] in self?.suite.feedOpen = true }
        }
    }

    func loadQueue() async {
        guard let l = libraryAPI, let list = try? await l.queuedShots() else { return }
        suite.queued = list
    }

    /// Run: today's price first; the person confirms it (`suite.runAsk`), then it runs. Never spends without that.
    func askRunQueued(_ q: QueuedShot) {
        guard let l = libraryAPI else { return }
        suite.queuePricing = q.id
        perform { [self] in
            defer { suite.queuePricing = nil }
            let e = try await l.estimateQueued(q.id)
            if let i = suite.queued.firstIndex(where: { $0.id == q.id }) { suite.queued[i] = e.item }
            if let p = e.estimateView?.problem { return showToast(p) }
            suite.runAsk = e
        }
    }

    func confirmRunQueued() {
        guard let l = libraryAPI, let ask = suite.runAsk else { return }
        suite.runAsk = nil
        perform { [self] in
            let r = try await l.runQueued(ask.item.id)
            suite.queued.removeAll { $0.id == r.queuedId }
            upsert(r.job)
            suite.shotJobIds.append(r.job.id)
            balance = try await api.balance()
            showToast("Rendering \(ask.item.title) · \(Pricing.money(r.job.cost))")
        }
    }

    func removeQueued(_ q: QueuedShot) {
        guard let l = libraryAPI else { return }
        perform { [self] in
            try await l.removeQueued(q.id)
            suite.queued.removeAll { $0.id == q.id }
            showToast("Removed \(q.title) from the queue")
        }
    }
}
