import MuseCore
import SwiftUI

// AI suite plan (plans/ai-suite-design.md, "Unchanged from the plan": saved rigs, the model default rig and Reuse
// settings; refinement 3: a default rig never overwrites the user). The server pieces and MuseCore's rules shipped with
// the cinematic preview; when the owner kept the current Suite these were left without a screen. They now sit in the
// current composer: the Setup rail's "Rigs" row (saved rigs, "Make it <name>'s default"), the default rig on @-mention,
// and "Retake with changes" on a take putting its exact composer back.
extension AppStore {
    // MARK: Reuse settings

    /// The take's composer comes back exactly (prompt with its chips, rig, bar values). Slots are not restored (their
    /// uploads may be gone). false: the take has no stored draft (made before Reuse settings).
    @discardableResult
    func reuseSettings(_ take: Take) -> Bool {
        guard let d = take.draft ?? job(for: take)?.draft else { return false }
        let restored = ComposerDrafts.restore(d, into: suite.composer)
        openTool(restored.tool)
        if restored.tool == .photo {
            if let n = d.count { suite.photo.count = n }
            if case .string(let p)? = d.extra["presetId"] { suite.photo.presetId = p }
        }
        if restored.tokens.characterId != suite.composer.tokens.characterId { suite.restoredCharacterId = restored.tokens.characterId }
        suite.composer = restored
        showToast("Settings from \(take.displayLabel) are back")
        return true
    }

    // MARK: Saved rigs

    func loadSavedRigs() async {
        if let r = try? await api.suiteRigs() { suite.savedRigs = r }
    }

    /// Saves the composer's rig (and its #moves) under a name.
    func saveRig(named raw: String) {
        let name: String
        switch SuiteRigView.cleanName(raw) {
        case .success(let n): name = n
        case .failure: showToast("Give the rig a name of up to \(SuiteRigView.maxName) characters"); return
        }
        let rig = SuiteRig(suite.composer.settings, moves: ComposerDrafts.rigMoves(suite.composer.tokens))
        perform { [self] in
            let saved = try await api.createSuiteRig(name: name, rig: rig)
            suite.savedRigs.insert(saved, at: 0)
            showToast("Saved \(saved.name)")
        }
    }

    func deleteSavedRig(_ r: SuiteRigView) {
        perform { [self] in
            try await api.deleteSuiteRig(id: r.id)
            suite.savedRigs.removeAll { $0.id == r.id }
            showToast("Deleted \(r.name)")
        }
    }

    /// A saved rig replaces the rig rows; its moves become #chips only while the prompt has none.
    func applySavedRig(_ r: SuiteRigView) {
        let before = suite.composer
        suite.composer.settings = r.rig.settings
        addRigMoves(r.rig.moves)
        showToast("Applied \(r.name)", action: "Undo") { [weak self] in self?.suite.composer = before }
    }

    // MARK: A model's default rig

    /// The one character @-mentioned in the prompt (a default rig applies, or can be set, only with exactly one).
    var soleMentionedCharacter: MuseModel? {
        let ids = ComposerDrafts.characterIds(suite.composer.tokens)
        return ids.count == 1 ? character(ids[0]) : nil
    }

    /// When exactly one character is @-mentioned and has a default rig: fill only the rows still on Auto, then
    /// "Applied <name>'s rig · Undo". Nothing applies with two characters.
    func applyDefaultRigIfAny() {
        guard let m = soleMentionedCharacter, let rig = m.defaultRig, !rig.isEmpty else { return }
        let before = suite.composer
        let (s, filled) = applyDefaultRig(rig, to: suite.composer.settings)
        let hadMoves = !suite.composer.tokens.moves.isEmpty
        if !filled.isEmpty { suite.composer.settings = s }
        if !hadMoves { addRigMoves(rig.moves) }
        guard !filled.isEmpty || (!hadMoves && !(rig.moves ?? []).isEmpty) else { return }
        showToast("Applied \(m.shortName)’s rig", action: "Undo") { [weak self] in self?.suite.composer = before }
    }

    /// The composer's rig becomes this character's default rig (an all-Auto rig clears it).
    func setDefaultRig(for m: MuseModel) {
        let rig = SuiteRig(suite.composer.settings, moves: ComposerDrafts.rigMoves(suite.composer.tokens))
        perform { [self] in
            let updated = try await api.setModelDefaultRig(modelId: m.id, rig: rig.isEmpty ? nil : rig)
            if let i = models.firstIndex(where: { $0.id == updated.id }) { models[i] = updated }
            showToast(rig.isEmpty ? "Cleared \(m.shortName)’s default rig" : "This rig is now \(m.shortName)’s default")
        }
    }

    // MARK: Vary and Use as start frame

    /// The take's settings back in the composer, ready for another take: nothing renders until Generate (which shows
    /// the price).
    func vary(_ take: Take) {
        if reuseSettings(take) {
            showToast("Ready for a variation: press Generate")
        } else {
            showToast("This take was made before Reuse settings")
        }
    }

    /// The take's frame goes into the Shot composer's start frame.
    func useAsStartFrame(_ take: Take) {
        if suite.composer.tool != .shot { openTool(.shot) }
        let slots = suite.composerSlots
        slots.slots = slots.slots.put(SlotId(.start), SlotValue(name: take.displayLabel, image: take.thumb))
        showToast("Start frame set from \(take.displayLabel)")
    }

    // MARK: Compare (two takes side by side)

    /// Adds the take to the comparison; with two, the side-by-side opens over the composer. Picking a third replaces
    /// the older one.
    func compareInSuite(_ take: Take) {
        if suite.compareIds.contains(take.id) {
            suite.compareIds.removeAll { $0 == take.id }
            return
        }
        suite.compareIds = Array((suite.compareIds + [take.id]).suffix(2))
        if suite.compareIds.count < 2 { showToast("Pick a second take to compare") }
    }

    var suiteComparing: [Take] {
        suite.compareIds.count == 2 ? suite.compareIds.compactMap { id in takes.first { $0.id == id } } : []
    }

    // MARK: The results feed (GET /v1/suite/feed)

    /// The tools a composer's feed shows: the video tools' takes, or Photo's stills.
    func feedTools(photo: Bool) -> [String] { photo ? ["photo"] : ["shot", "extend", "upscale", "swap", "recast"] }

    /// First page (reset) or the next one. Running cards keep live progress from the jobs stream (`feedJob`).
    func loadFeed(photo: Bool, reset: Bool = true) async {
        if !reset && suite.feedCursor == nil { return }
        guard !suite.feedLoading else { return }
        suite.feedLoading = true
        defer { suite.feedLoading = false }
        let q = SuiteFeedQuery(tool: feedTools(photo: photo), status: suite.feedFilter.statuses, cursor: reset ? nil : suite.feedCursor)
        guard let page = try? await api.suiteFeed(q) else { return }
        if reset {
            suite.feed = page.items
        } else {
            let seen = Set(suite.feed.map(\.id))
            suite.feed += page.items.filter { !seen.contains($0.id) }
        }
        suite.feedCursor = page.nextCursor
    }

    /// A running card's live job (the feed's value is from when the page was fetched), and a card's take in the app.
    func feedJob(_ item: SuiteFeedItem) -> Job? { item.jobId.flatMap { id in jobs.first { $0.id == id } } }
    func feedTake(_ item: SuiteFeedItem) -> Take? { item.takeId.flatMap { id in takes.first { $0.id == id } } }

    /// The Suite's own takes already in the app, newest first: the feed's stand-in when the server has none listed
    /// (takes made before the feed, an older server).
    func suiteTakes(photo: Bool) -> [Take] {
        if photo { return takes.filter { $0.kind == "shot" }.sorted { $0.createdAt > $1.createdAt } }
        let suiteIds = Set(jobs.filter { $0.request.engine == "suite" || $0.request.isUpscale }.map(\.id))
        let video = takes.filter { $0.isVideo && $0.kind == "take" }
        let mine = suiteIds.isEmpty ? video : video.filter { $0.jobId.map(suiteIds.contains) ?? false }
        return mine.sorted { $0.createdAt > $1.createdAt }
    }

    private func addRigMoves(_ moves: [SuiteRigMove]?) {
        guard suite.composer.tool != .photo, suite.composer.tokens.moves.isEmpty, let moves else { return }
        var t = suite.composer.tokens
        for m in moves.prefix(PromptTokens.maxMoves) {
            guard let opt = suite.camera.move(m.id) else { continue }
            t = t.addMove(opt, intensity: Int(((m.intensity ?? 0.5) * 100).rounded()), catalog: suite.camera).0
        }
        suite.composer.tokens = t
    }
}

/// The feed's filter: All, Rendering, Finished, Failed.
enum SuiteFeedFilter: String, CaseIterable, Identifiable {
    case all, rendering, finished, failed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .rendering: return "Rendering"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }
    var statuses: [String] {
        switch self {
        case .all: return []
        case .rendering: return ["queued", "running"]
        case .finished: return ["done"]
        case .failed: return ["failed"]
        }
    }
}
