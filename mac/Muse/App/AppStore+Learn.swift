import Foundation
import MuseCore
import Observation
import SwiftUI

// The learning editor in Edit (plans/learning-editor-ui.md, owner only): the Playbook (the rules Claude follows, the
// suggestions from the owner's corrections, the history of corrections) and Recipes (every analysed reference and
// finished edit, with the effects MUSE can't make yet). Opened from the Edit home and from the Claude panel's Playbook
// tab. Demo mode uses MuseCore's FakeLearnAPI; a server uses the HTTPMuseAPI instance. Nothing here spends money.

enum LearnPage: String { case playbook, recipes }
enum PlaybookTab: String { case rules, suggestions, history }

/// The rule editor's draft: a new rule (`id` nil), one being edited, or one made from a suggestion.
struct RuleDraft: Equatable {
    var id: String?
    var text = ""
    var area = "other"
    var evidence: [LearnEvidence] = []
    /// "Add a note" opened its field.
    var noting = false
    var note = ""
    var isNew: Bool { id == nil }
}

@MainActor
@Observable
final class LearnState {
    /// Showing in Edit in place of the Edit home.
    var page: LearnPage?

    // Playbook
    var tab: PlaybookTab = .rules
    var rules: [LearnRule]?
    var lessons: [LearnLesson]?
    var corrections: [LearnCorrection]?
    var loadingPlaybook = false
    var playbookError: String?
    var draft: RuleDraft?
    var saving = false
    /// The rule whose delete is being confirmed ("Delete this rule?").
    var deletingRule: String?

    // Recipes
    var recipes: [LearnRecipe]?
    var gaps: [LearnGap] = []
    var loadingRecipes = false
    var recipesError: String?
    var query = ""
    var origin: LearnOrigin = .all
    var sort: LearnSort = .newest
    var tag: String?
    var selectedId: String?
    var detail: LearnRecipe?
    var nearest: [LearnRecipe] = []
    var loadingDetail = false
    /// The selected reference's video still exists (Recreate can use it).
    var referenceUsable = false
    var askDeleteRecipe = false

    let fake = FakeLearnAPI()

    func reset() {
        page = nil
        tab = .rules
        rules = nil; lessons = nil; corrections = nil
        playbookError = nil
        draft = nil
        deletingRule = nil
        recipes = nil
        gaps = []
        recipesError = nil
        clearFilters()
        clearSelection()
    }

    func clearFilters() {
        query = ""
        origin = .all
        sort = .newest
        tag = nil
    }

    func clearSelection() {
        selectedId = nil
        detail = nil
        nearest = []
        referenceUsable = false
        askDeleteRecipe = false
    }

    var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    var full: Bool { (rules?.count ?? 0) >= Learn.maxRules }
    var filtered: [LearnRecipe] { LearnFilter.apply(recipes ?? [], query: query, origin: origin, tags: tag.map { [$0] } ?? [], sort: sort) }
    var topTags: [String] { LearnFilter.topTags(recipes ?? []) }
    var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || origin != .all || tag != nil }
    /// The pinned rules the Claude panel lists (the first 10).
    var pinned: [LearnRule] { Array((rules ?? []).filter(\.pinned).prefix(10)) }
}

/// What a recipe's picture is: the edited take's thumbnail, the reference's poster, a bundled demo still, or nothing
/// (then `field` with a film-strip icon). Never a sample person.
enum LearnPicture: Equatable {
    case take(ImageRef)
    case poster(String)
    case bundled(String)
    case none
}

extension AppStore {
    /// Demo mode: the fake. A server: the same HTTPMuseAPI the rest of the app uses.
    var learnAPI: any LearnAPI {
        if let http = api as? HTTPMuseAPI { return http }
        return learn.fake
    }

    private func learnLine(_ error: Error, _ fallback: String) -> String {
        if let e = error as? ApiError, e.code != "offline" { return e.friendlyMessage }
        return fallback
    }

    // MARK: Opening and closing

    /// Edit home → Playbook or Recipes (owner only; members never see the buttons, and the server answers them 403).
    func openLearn(_ page: LearnPage) {
        recreate.clearReference()
        recreate.open = false
        learn.draft = nil
        learn.deletingRule = nil
        learn.page = page
        Task {
            switch page {
            case .playbook: await loadPlaybook()
            case .recipes: await loadRecipes()
            }
        }
    }

    func closeLearn() {
        learn.page = nil
        learn.draft = nil
        learn.deletingRule = nil
        learn.clearSelection()
    }

    // MARK: Playbook

    func loadPlaybook() async {
        learn.loadingPlaybook = true
        learn.playbookError = nil
        defer { learn.loadingPlaybook = false }
        do {
            learn.rules = try await learnAPI.playbook()
        } catch {
            learn.playbookError = "Couldn't load the playbook · check your connection"
            return
        }
        // Suggestions and history are extras: the rules still show if they fail.
        learn.lessons = (try? await learnAPI.lessons()) ?? learn.lessons ?? []
        learn.corrections = (try? await learnAPI.corrections(limit: 50)) ?? learn.corrections ?? []
    }

    /// The Claude panel's Playbook tab: the rules only.
    func loadPinnedRules() async {
        if let r = try? await learnAPI.playbook() { learn.rules = r }
    }

    func startNewRule() {
        guard !learn.full else { return }
        learn.draft = RuleDraft()
    }

    func startEditing(_ r: LearnRule) {
        learn.draft = RuleDraft(id: r.id, text: r.text, area: Learn.areas.contains(r.area) ? r.area : "other", evidence: r.evidence)
    }

    /// "Make a rule": the area preset, the field empty (the owner says it in their own words), the lesson's corrections as
    /// evidence. Nothing becomes a rule until "Save rule".
    func startRule(from l: LearnLesson) {
        guard !learn.full else { return }
        let evidence = l.ids.enumerated().map { i, id in
            LearnEvidence(kind: "correction", id: String(id), note: l.examples.indices.contains(i) ? l.examples[i] : (l.examples.first ?? ""), at: i == 0 ? l.last : nil)
        }
        learn.draft = RuleDraft(area: Learn.areas.contains(l.area) ? l.area : "other", evidence: evidence)
    }

    func cancelRule() {
        learn.draft = nil
    }

    func saveRule() async {
        guard let d = learn.draft, !learn.saving else { return }
        let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { showToast("Say what Claude should do"); return }
        let note = d.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = note.isEmpty ? [] : [LearnEvidence(kind: "note", note: String(note.prefix(300)), at: learn.now)]
        learn.saving = true
        defer { learn.saving = false }
        do {
            if let id = d.id {
                // Evidence is sent only when a note is added (the server re-dates the evidence it's given).
                _ = try await learnAPI.patchRule(id, LearnRuleRequest(text: String(text.prefix(Learn.maxRuleChars)), area: d.area,
                                                                      evidence: added.isEmpty ? nil : d.evidence + added))
            } else {
                _ = try await learnAPI.addRule(LearnRuleRequest(text: String(text.prefix(Learn.maxRuleChars)), area: d.area, evidence: d.evidence + added))
            }
            learn.draft = nil
            learn.tab = .rules
            await refreshRules()
        } catch {
            showToast(learnLine(error, "Couldn't save the rule · check your connection"))
        }
    }

    func togglePin(_ r: LearnRule) async {
        do {
            let new = try await learnAPI.patchRule(r.id, LearnRuleRequest(pinned: !r.pinned))
            if let i = learn.rules?.firstIndex(where: { $0.id == r.id }) { learn.rules?[i] = new }
            await refreshRules()
        } catch {
            showToast(learnLine(error, "Couldn't change the pin · check your connection"))
        }
    }

    func askDeleteRule(_ id: String) { learn.deletingRule = id }

    func keepRule() { learn.deletingRule = nil }

    /// `id` is read when "Delete rule" is pressed (the sheet closing clears `deletingRule`).
    func confirmDeleteRule(_ id: String?) async {
        guard let id = id ?? learn.deletingRule else { return }
        learn.deletingRule = nil
        do {
            try await learnAPI.deleteRule(id)
            if learn.draft?.id == id { learn.draft = nil }
            learn.rules?.removeAll { $0.id == id }
            await refreshRules()
        } catch {
            showToast(learnLine(error, "Couldn't delete the rule · check your connection"))
        }
    }

    private func refreshRules() async {
        if let r = try? await learnAPI.playbook() { learn.rules = r }
    }

    /// A correction's edit, when its take is still in the library.
    func correctionTake(_ id: String?) -> Take? {
        guard let id else { return nil }
        return takes.first { $0.id == id && $0.isVideo }
    }

    /// The take a piece of evidence points at (a correction still in the history, whose take still exists).
    func evidenceTake(_ e: LearnEvidence) -> Take? {
        guard e.kind == "correction", let id = e.id.flatMap(Int.init) else { return nil }
        return correctionTake(learn.corrections?.first { $0.id == id }?.takeId)
    }

    // MARK: Recipes

    func loadRecipes() async {
        learn.loadingRecipes = true
        learn.recipesError = nil
        defer { learn.loadingRecipes = false }
        do {
            learn.recipes = try await learnAPI.recipes(limit: 200)
        } catch {
            learn.recipesError = "Couldn't load the recipes · check your connection"
            return
        }
        learn.gaps = (try? await learnAPI.gaps(limit: 10)) ?? learn.gaps
        if let id = learn.selectedId, !(learn.recipes ?? []).contains(where: { $0.id == id }) { learn.clearSelection() }
    }

    func toggleTag(_ t: String) { learn.tag = learn.tag == t ? nil : t }

    func selectRecipe(_ id: String) async {
        learn.selectedId = id
        learn.askDeleteRecipe = false
        learn.detail = learn.recipes?.first { $0.id == id }
        learn.nearest = []
        learn.referenceUsable = false
        learn.loadingDetail = true
        defer { learn.loadingDetail = false }
        do {
            let r = try await learnAPI.recipe(id)
            guard learn.selectedId == id else { return }
            learn.detail = r
        } catch {
            showToast(learnLine(error, "Couldn't open the recipe · check your connection"))
            return
        }
        if let n = try? await learnAPI.nearest(recipeId: id, k: 3), learn.selectedId == id { learn.nearest = n.nearest }
        if let refId = learn.detail?.referenceId, learn.detail?.isReference == true,
           let ref = try? await recreateAPI.reference(refId), learn.selectedId == id {
            // The reference's video is kept 30 days unless kept; once it has expired Recreate can't use it.
            let expired = (ref.expiresAt ?? .max) < learn.now && ref.keep != true
            learn.referenceUsable = ref.isReady && !expired
        }
    }

    func closeRecipe() { learn.clearSelection() }

    func renameRecipe(_ name: String) async {
        guard let id = learn.selectedId else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != learn.detail?.name else { return }
        await patchRecipe(id, LearnRecipePatch(name: String(n.prefix(120))))
    }

    func addRecipeTag(_ raw: String) async {
        guard let id = learn.selectedId, let d = learn.detail, let t = LearnFilter.cleanTag(raw), !d.tags.contains(t) else { return }
        guard d.tags.count < Learn.maxTags else { showToast("A recipe keeps at most \(Learn.maxTags) tags"); return }
        await patchRecipe(id, LearnRecipePatch(tags: d.tags + [t]))
    }

    func removeRecipeTag(_ t: String) async {
        guard let id = learn.selectedId, let d = learn.detail else { return }
        await patchRecipe(id, LearnRecipePatch(tags: d.tags.filter { $0 != t }))
    }

    private func patchRecipe(_ id: String, _ patch: LearnRecipePatch) async {
        do {
            var r = try await learnAPI.patchRecipe(id, patch)
            if r.recipe == nil { r.recipe = learn.detail?.recipe }
            if learn.selectedId == id { learn.detail = r }
            if let i = learn.recipes?.firstIndex(where: { $0.id == id }) {
                var row = r
                row.recipe = nil
                learn.recipes?[i] = row
            }
        } catch {
            showToast(learnLine(error, "Couldn't save the recipe · check your connection"))
        }
    }

    /// Removes the recipe from the library only: the reference and the take stay.
    func confirmDeleteRecipe() async {
        guard let id = learn.selectedId else { return }
        learn.askDeleteRecipe = false
        do {
            try await learnAPI.deleteRecipe(id)
            learn.recipes?.removeAll { $0.id == id }
            learn.clearSelection()
        } catch {
            showToast(learnLine(error, "Couldn't delete the recipe · check your connection"))
        }
    }

    /// "Use in Recreate": the reference opens in Recreate (matching takes is free; nothing is generated without the
    /// owner confirming the total there).
    func useRecipeInRecreate() {
        guard let refId = learn.detail?.referenceId else { return }
        closeLearn()
        openRecreate()
        Task { await openRecreateReference(refId) }
    }

    /// The take an edit recipe was made from (nil when it has left the library).
    func learnTake(_ r: LearnRecipe) -> Take? {
        guard !r.isReference, let id = r.takeId else { return nil }
        return takes.first { $0.id == id }
    }

    /// "Open edit": the edited take in the editor; closing the editor comes back here.
    func openRecipeEdit() {
        guard let d = learn.detail else { return }
        guard let take = learnTake(d) else {
            showToast("This edit is no longer in your library")
            return
        }
        openLearnTake(take.id)
    }

    /// Opens a take in the editor from the learning editor (a correction in History, an evidence line, "Open edit").
    func openLearnTake(_ id: String) {
        // The Edit screen follows `editTakeId`; clear it first so the same take opens again after its editor was closed.
        suite.editTakeId = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            openEdit(takeId: id)
        }
    }

    /// A recipe's picture (owner note 1: the studio's own videos, never sample people).
    func learnPicture(_ r: LearnRecipe) -> LearnPicture {
        if r.isReference {
            guard api is HTTPMuseAPI, let ref = r.referenceId, let path = LearnIds.posterPath(referenceId: ref) else { return .none }
            return .poster(path)
        }
        if let take = learnTake(r), take.thumb.url != nil || take.thumb.asset != nil { return .take(take.thumb) }
        // Demo mode: the bundled Blender mannequin stills (design/previews), never a person.
        guard isDemo else { return .none }
        let stills = ["angles/full.webp", "angles/cowboy.webp", "angles/ms.webp", "angles/ls.webp", "angles/mcu.webp"]
        let h = r.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return .bundled(stills[h % stills.count])
    }
}
