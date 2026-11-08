import AppKit
import Foundation
import MuseCore
import Observation
import SwiftUI

// "Recreate this edit" (plans/recreate/README.md): a reference video analysed into its recipe (Recipe), built with the
// studio's takes and new shots, then compared with the reference (Compare). It lives inside Edit, opened from the Edit home.
// Demo mode uses MuseCore's FakeRecreateAPI (workstream 1's fixture: nothing is uploaded or charged); a server uses the
// HTTPMuseAPI instance. Nothing is generated or spent without the person confirming the total first.

enum RecreateMode: String { case recipe, compare }

@MainActor
@Observable
final class RecreateState {
    /// Recreate is showing in Edit, in place of the Edit home.
    var open = false
    var references: [RecreateReference] = []
    var loadingList = false
    /// The reference on screen (analysing, ready or failed).
    var reference: RecreateReference?
    var fill: RecreateFill?
    var loadingFill = false
    /// After Build: how close our version is.
    var match: RecreateMatch?
    /// The take the built edit lives on (Open in the editor).
    var builtTakeId: String?
    var mode: RecreateMode = .recipe
    var selectedSlot = 0
    /// The shared playhead (seconds in the reference); both players follow it.
    var time: Double = 0
    var playing = false
    var error: String?
    /// Build's confirmation (the total, before anything is made).
    var askBuild = false
    /// Build is pricing the shots to generate (before the confirmation).
    var estimating = false
    /// After the yes: the shots are being made, then the edit is built. Cleared when Compare opens or nothing is left to do.
    var building = false
    var uploading = false
    /// The slot estimates for the reference on screen: slotId → price (nothing held).
    var estimates: [String: ShotEstimate] = [:]
    /// Slots that couldn't be priced, in plain words ("This shot can’t be made…"): never offered to spend on.
    var estimateErrors: [String: String] = [:]
    /// The slots the open confirmation covers (priced, to generate), frozen when it opened.
    var confirmSlots: [String] = []
    /// Slots whose new shot didn't generate (refunded by the server), in plain words.
    var fillErrors: [String: String] = [:]
    /// Takes picked here ("Use one of my takes"), kept over each fill refresh.
    var picks: [String: RecreateFill.SlotFill] = [:]
    /// Survive leaving the reference (never cleared by `clearReference`): references whose edit is built as soon as their
    /// new shots are ready, and "referenceId/slotId" fills still being started (never started twice).
    var buildWhenReady: Set<String> = []
    var startingFills: Set<String> = []

    let fake = FakeRecreateAPI()
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var playTask: Task<Void, Never>?
    /// Watches `GET …/fill` while new shots are generating (every 3 s).
    @ObservationIgnored var fillWatch: Task<Void, Never>?

    func reset() {
        pollTask?.cancel()
        playTask?.cancel()
        open = false
        references = []
        clearReference()
        error = nil
        uploading = false
        buildWhenReady = []
    }

    func clearReference() {
        pollTask?.cancel()
        playTask?.cancel()
        fillWatch?.cancel()
        reference = nil
        fill = nil
        match = nil
        builtTakeId = nil
        mode = .recipe
        selectedSlot = 0
        time = 0
        playing = false
        askBuild = false
        building = false
        estimating = false
        estimates = [:]
        estimateErrors = [:]
        confirmSlots = []
        fillErrors = [:]
        picks = [:]
    }

    var recipe: Recipe? { reference?.recipe }
    var slots: [Recipe.Slot] { recipe?.slots ?? [] }
    var duration: Double { max(0.1, recipe?.durationSec ?? reference?.durationSec ?? 0) }
    var selected: Recipe.Slot? { slots.indices.contains(selectedSlot) ? slots[selectedSlot] : nil }
    func slotFill(_ id: String) -> RecreateFill.SlotFill? { fill?.slots.first { $0.slotId == id } }
    func score(_ slotId: String) -> Double? { match?.perSlot?.first { $0.slotId == slotId }?.score }
    /// The slot under the playhead.
    var slotAtTime: Int? { slots.lastIndex { $0.startSec <= time + 1e-6 } }
    /// Slots still being made: generating on the server, or their fill still being started here.
    var generatingSlots: [String] {
        guard let id = reference?.id else { return [] }
        return slots.map(\.id).filter { s in slotFill(s)?.state == "generating" || startingFills.contains("\(id)/\(s)") }
    }
    var isGenerating: Bool { !generatingSlots.isEmpty }
    /// The shots to generate that can be priced (and so offered to spend on).
    var toGenerate: [String] {
        guard let id = reference?.id else { return [] }
        return (fill?.slots ?? []).filter { $0.state == "to_generate" && !startingFills.contains("\(id)/\($0.slotId)") }.map(\.slotId)
    }
    var prices: [String: Double] { estimates.filter { $0.value.ok }.mapValues(\.estimate) }
    var unpriceable: Set<String> { Set(estimateErrors.keys) }
    /// The total the confirmation shows: the confirmed slots' estimates.
    var confirmTotal: Double { confirmSlots.compactMap { estimates[$0]?.estimate }.reduce(0, +) }
    /// "Shot 2".
    func shotName(_ slotId: String) -> String { slots.firstIndex { $0.id == slotId }.map { "Shot \($0 + 1)" } ?? "A shot" }

    /// The shot with the lowest match after Build ("Fix shot 2").
    var weakestSlot: Int? {
        guard let per = match?.perSlot, !per.isEmpty else { return nil }
        let worst = per.min { $0.score < $1.score }
        return slots.firstIndex { $0.id == worst?.slotId }
    }
}

extension AppStore {
    /// Demo mode: the fake (no uploads, no charges). A server: the same HTTPMuseAPI the rest of the app uses.
    var recreateAPI: any RecreateAPI {
        if let http = api as? HTTPMuseAPI { return http }
        return recreate.fake
    }

    /// An authenticated reference route (video, poster, a shot's frame) and the token to load it with. nil in demo mode.
    func recreateMedia(_ link: String?) -> (url: URL, token: String?)? {
        guard let http = api as? HTTPMuseAPI, let u = http.recreateMediaURL(link) else { return nil }
        return (u, http.sessionToken)
    }

    private func recreateFail(_ error: Error) {
        let line = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        recreate.error = line
        if recreate.reference != nil { showToast(line) }
    }

    // MARK: Opening and closing

    /// Edit home → Recreate an edit: the start page (drop a video, or open a reference analysed before). Nothing is
    /// uploaded until a video is chosen.
    func openRecreate() {
        recreate.clearReference()
        recreate.error = nil
        recreate.open = true
        Task { await loadRecreateReferences() }
    }

    func closeRecreate() {
        recreate.clearReference()
        recreate.open = false
    }

    /// From a reference back to the start page.
    func leaveRecreateReference() {
        recreate.clearReference()
        Task { await loadRecreateReferences() }
    }

    func loadRecreateReferences() async {
        recreate.loadingList = true
        defer { recreate.loadingList = false }
        do { recreate.references = try await recreateAPI.listReferences() } catch { recreateFail(error) }
    }

    func openRecreateReference(_ id: String) async {
        recreate.error = nil
        do { await showRecreateReference(try await recreateAPI.reference(id)) } catch { recreateFail(error) }
    }

    private func showRecreateReference(_ r: RecreateReference) async {
        recreate.clearReference()
        recreate.reference = r
        recreate.time = r.recipe?.slots.first?.keyframeSec ?? 0
        if r.isAnalyzing {
            pollRecreateReference(r.id)
        } else if r.isReady {
            await loadRecreateFill(r.id)
        }
    }

    /// While a reference is analysed, its steps come in as `phase` / `progress`.
    private func pollRecreateReference(_ id: String) {
        recreate.pollTask?.cancel()
        recreate.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard let r = try? await self.recreateAPI.reference(id) else { continue }
                guard self.recreate.reference?.id == id else { return }
                self.recreate.reference = r
                if let i = self.recreate.references.firstIndex(where: { $0.id == id }) { self.recreate.references[i] = r }
                if !r.isAnalyzing {
                    if r.isReady { await self.loadRecreateFill(id) }
                    return
                }
            }
        }
    }

    func loadRecreateFill(_ id: String) async {
        recreate.loadingFill = true
        defer { recreate.loadingFill = false }
        do {
            var f = try await recreateAPI.fill(id)
            // Nothing scored against the takes yet: match them once (free), so the fill says what's yours and what to make.
            if !f.slots.isEmpty, f.slots.allSatisfy({ $0.state == "empty" }) {
                try? await recreateAPI.matchSlots(id, modelId: recreateModelId)
                f = try await recreateAPI.fill(id)
            }
            guard recreate.reference?.id == id else { return }
            takeRecreateFill(f)
            if let m = f.match { recreate.match = m }
        } catch {
            recreateFail(error)
            return
        }
        // Shots made before (or still being made after leaving the page): carry on watching, never fill them again.
        if recreate.isGenerating {
            recreate.building = recreate.buildWhenReady.contains(id)
            watchRecreateFills(id)
        }
        await priceRecreateSlots(id)
    }

    /// A fetched fill on screen: takes picked here stay, and a slot that was generating and came back without its shot
    /// is marked as not generated (the server refunds it).
    private func takeRecreateFill(_ new: RecreateFill) {
        var f = new
        let wasMaking = Set(recreate.generatingSlots)
        for i in f.slots.indices {
            let s = f.slots[i]
            if s.state == "generating" || s.state == "ready" {
                recreate.fillErrors[s.slotId] = nil
                recreate.picks[s.slotId] = nil
                continue
            }
            if wasMaking.contains(s.slotId), !recreate.startingFills.contains("\(new.referenceId)/\(s.slotId)") {
                recreate.fillErrors[s.slotId] = "This shot didn’t generate. You weren’t charged for it."
            }
            if let p = recreate.picks[s.slotId] { f.slots[i] = p }
        }
        recreate.fill = f
    }

    /// A video chosen or dropped on the start page: uploaded (≤ 60 s) and analysed. Demo mode analyses the sample at once.
    func createRecreateReference(from url: URL) async {
        recreate.error = nil
        recreate.uploading = true
        defer { recreate.uploading = false }
        let ext = url.pathExtension.lowercased()
        let type = ext == "mov" ? "video/quicktime" : ext == "m4v" ? "video/x-m4v" : "video/mp4"
        let name = url.deletingPathExtension().lastPathComponent
        let api = recreateAPI
        do {
            let r = try await withUploadProgress("Uploading \(url.lastPathComponent)") { p in
                try await api.createReference(file: url, contentType: type, name: name, progress: p)
            }
            recreate.references.removeAll { $0.id == r.id }
            recreate.references.insert(r, at: 0)
            await showRecreateReference(r)
        } catch {
            recreateFail(error)
        }
    }

    // MARK: Recipe

    func selectRecreateSlot(_ i: Int) {
        guard recreate.slots.indices.contains(i) else { return }
        recreate.selectedSlot = i
        let s = recreate.slots[i]
        recreate.time = s.keyframeSec ?? (s.startSec + s.endSec) / 2
    }

    /// "Use one of my takes": the slot is filled from that take instead (nothing to generate, nothing to pay for it).
    func useTakeForRecreateSlot(_ slotId: String, take: Take) {
        guard var f = recreate.fill else { return }
        guard let i = f.slots.firstIndex(where: { $0.slotId == slotId }) else { return }
        f.slots[i].state = "matched"
        f.slots[i].takeId = take.id
        f.slots[i].jobId = nil
        f.slots[i].estimate = nil
        f.slots[i].score = nil
        f.slots[i].reason = "You picked “\(take.caption)”"
        recreate.picks[slotId] = f.slots[i]
        recreate.fillErrors[slotId] = nil
        recreate.estimateErrors[slotId] = nil
        recreate.fill = f
    }

    /// The takes that can fill a shot: the studio's video takes, newest first.
    var recreateTakeChoices: [Take] { Array(editSuiteTakes.filter { !$0.isEdit }.prefix(12)) }

    // MARK: Play

    func toggleRecreatePlay() {
        recreate.playing.toggle()
        recreate.playTask?.cancel()
        guard recreate.playing else { return }
        recreate.playTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.recreate.playing else { return }
                let now = Date()
                var t = self.recreate.time + now.timeIntervalSince(last)
                last = now
                if t >= self.recreate.duration { t = 0 }
                self.recreate.time = t
            }
        }
    }

    func stepRecreate(_ frames: Int) {
        let fps = recreate.recipe?.source?.fps ?? 30
        recreate.time = min(recreate.duration, max(0, recreate.time + Double(frames) / max(1, fps)))
    }

    // MARK: Build and compare

    /// The character new shots are made with: the studio's current model, as the Suite's shots use.
    var recreateModelId: String? { currentModel?.id ?? suiteCharacters.first?.id }

    /// Prices every shot still to generate (free; nothing is held). A shot that can't be made says why in plain words
    /// and is never offered to spend on. The cost line beside Build uses these prices once they are in.
    func priceRecreateSlots(_ id: String) async {
        let todo = recreate.toGenerate
        guard !todo.isEmpty else { return }
        guard let model = recreateModelId else {
            for s in todo { recreate.estimateErrors[s] = "Add a model first: new shots are made with her." }
            return
        }
        let api = recreateAPI
        var got: [String: Result<RecreateSlotEstimate, Error>] = [:]
        await withTaskGroup(of: (String, Result<RecreateSlotEstimate, Error>).self) { g in
            for s in todo {
                g.addTask {
                    do { return (s, .success(try await api.estimateSlot(id, slotId: s, modelId: model, quality: nil))) } catch { return (s, .failure(error)) }
                }
            }
            for await (s, r) in g { got[s] = r }
        }
        guard recreate.reference?.id == id else { return }
        for (s, r) in got {
            switch r {
            case .success(let e):
                recreate.estimates[s] = e.estimate
                recreate.estimateErrors[s] = e.estimate.problem.map { p in (p.hasSuffix(".") ? p : p + ".") + " Use one of your takes for this shot." }
            case .failure(let err):
                recreate.estimates[s] = nil
                recreate.estimateErrors[s] = Self.recreatePriceProblem(err)
            }
        }
    }

    private static func recreatePriceProblem(_ error: Error) -> String {
        guard let e = error as? ApiError else { return "This shot couldn’t be priced. Check the connection and try again." }
        switch e.code {
        case "nothing_fits": return "This shot can’t be made at this length and quality. Use one of your takes for it."
        case "engine_unavailable": return "New shots can’t be made right now. Use one of your takes for this shot."
        default: return e.friendlyMessage
        }
    }

    /// Build: prices the shots to generate, then asks once with the real total. Nothing is spent before the yes. With
    /// nothing to generate it asks too ("Build the edit?", nothing charged). While shots are generating, it waits for them.
    func requestRecreateBuild() async {
        guard let ref = recreate.reference, recreate.fill != nil, !recreate.building, !recreate.estimating else { return }
        recreate.playing = false
        if recreate.toGenerate.isEmpty && recreate.isGenerating {
            recreate.buildWhenReady.insert(ref.id)
            recreate.building = true
            watchRecreateFills(ref.id)
            showToast("The new shots are still generating. The edit is built when they’re ready.")
            return
        }
        recreate.estimating = true
        await priceRecreateSlots(ref.id)
        recreate.estimating = false
        guard recreate.reference?.id == ref.id else { return }
        recreate.confirmSlots = recreate.toGenerate.filter { recreate.estimates[$0]?.ok == true && recreate.estimateErrors[$0] == nil }
        recreate.askBuild = true
    }

    /// The person said yes to the total: each confirmed shot is made (one at a time; the server holds and charges it),
    /// then, once all are ready, the edit is built and Compare opens. Leaving the page doesn't stop it: the fills that
    /// were confirmed are still started, and coming back resumes from the server's fill. A slot is never filled twice.
    func confirmRecreateBuild() {
        guard let ref = recreate.reference, !recreate.building else { return }
        let id = ref.id
        let confirmed = recreate.confirmSlots
        recreate.askBuild = false
        recreate.confirmSlots = []
        recreate.building = true
        recreate.buildWhenReady.insert(id)
        guard !confirmed.isEmpty, let model = recreateModelId else {
            if recreate.isGenerating {
                watchRecreateFills(id)
            } else {
                recreate.building = false
                Task { await applyRecreate() }
            }
            return
        }
        for s in confirmed { recreate.startingFills.insert("\(id)/\(s)") }
        Task { [weak self] in
            guard let self else { return }
            let api = self.recreateAPI
            // The server's own fill decides: a slot already generating or ready is never filled again.
            let current = try? await api.fill(id)
            for s in confirmed {
                defer { self.recreate.startingFills.remove("\(id)/\(s)") }
                if let state = current?.slots.first(where: { $0.slotId == s })?.state, state != "to_generate" { continue }
                do {
                    let started = try await api.fillSlot(id, slotId: s, modelId: model, quality: nil)
                    if !self.isDemo { self.upsert(started.job) }
                    self.recreate.fillErrors[s] = nil
                    if self.recreate.reference?.id == id, var f = self.recreate.fill, let i = f.slots.firstIndex(where: { $0.slotId == s }) {
                        f.slots[i].state = "generating"
                        f.slots[i].jobId = started.job.id
                        self.recreate.fill = f
                    }
                } catch {
                    if self.recreate.reference?.id == id {
                        self.recreate.fillErrors[s] = "This shot didn’t start: \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)"
                    }
                }
            }
            if !self.isDemo, let b = try? await self.api.balance() { self.balance = b }
            guard self.recreate.reference?.id == id else { return }
            if let f = try? await api.fill(id) { self.takeRecreateFill(f) }
            if self.recreate.isGenerating {
                self.watchRecreateFills(id)
            } else {
                await self.finishRecreateBuild(id)
            }
        }
    }

    /// While shots generate: the fill every 3 s until none is generating, then the edit is built (when Build asked for it).
    func watchRecreateFills(_ id: String) {
        recreate.fillWatch?.cancel()
        recreate.fillWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.recreate.reference?.id == id else { return }
                guard let f = try? await self.recreateAPI.fill(id) else { continue }
                guard !Task.isCancelled, self.recreate.reference?.id == id else { return }
                self.takeRecreateFill(f)
                if !self.recreate.isGenerating {
                    await self.finishRecreateBuild(id)
                    return
                }
            }
        }
    }

    /// Every new shot is ready or didn't generate. All ready: build and compare. Some didn't: stop and say so, with Try
    /// again on those shots (Build again prices and asks for them alone).
    private func finishRecreateBuild(_ id: String) async {
        guard recreate.buildWhenReady.contains(id) else {
            recreate.building = false
            return
        }
        let failed = recreate.slots.map(\.id).filter { recreate.fillErrors[$0] != nil }
        if !failed.isEmpty {
            recreate.buildWhenReady.remove(id)
            recreate.building = false
            let names = failed.map { recreate.shotName($0) }.joined(separator: " and ")
            showToast("\(names) didn’t generate. You weren’t charged for \(failed.count == 1 ? "it" : "them"). Try again, or use one of your takes.")
            return
        }
        recreate.building = false
        await applyRecreate()
        recreate.buildWhenReady.remove(id)
    }

    /// Builds the edit (an edit session on the take the first shot comes from) from the takes and finished shots, and
    /// shows Compare. Demo mode builds against the fake.
    func applyRecreate() async {
        guard let ref = recreate.reference, let fill = recreate.fill, !recreate.building else { return }
        recreate.building = true
        recreate.playing = false
        defer { recreate.building = false }
        var slots: [String: String] = [:]
        for s in fill.slots {
            switch s.state {
            case "matched": if let t = s.takeId { slots[s.slotId] = t }
            case "ready": if let v = s.jobId ?? s.takeId { slots[s.slotId] = v }
            default: break
            }
        }
        let baseTake = fill.slots.compactMap(\.takeId).first(where: { id in takes.contains { $0.id == id } }) ?? recreateTakeChoices.first?.id
        do {
            let sessionId: String
            var revision: Int?
            if isDemo {
                sessionId = "es_demo"
            } else {
                guard let baseTake else { throw ApiError("no_takes", "Make a video first: the edit is built on one of your takes") }
                let s = try await api.openEditSession(EditSessionOpenRequest(takeId: baseTake, device: "mac"))
                sessionId = s.id
                revision = s.revision
            }
            let result = try await recreateAPI.apply(ref.id, RecreateApplyRequest(sessionId: sessionId, baseRevision: revision, slots: slots, device: "mac"))
            recreate.match = result.match ?? recreate.match
            recreate.builtTakeId = baseTake
            recreate.mode = .compare
            if let w = result.waiting, !w.isEmpty {
                showToast("\(w.map { recreate.shotName($0) }.joined(separator: " and ")) isn’t ready yet, so the edit leaves it out for now")
            }
        } catch {
            recreateFail(error)
        }
    }

    /// "Fix shot 2": back to the recipe on the weakest shot, to pick another take for it.
    func fixWeakestRecreateShot() {
        if let i = recreate.weakestSlot { selectRecreateSlot(i) }
        recreate.mode = .recipe
    }

    /// Compare → the built edit in the editor (where it is exported).
    func openRecreateInEditor() {
        guard let id = recreate.builtTakeId, takes.contains(where: { $0.id == id }) else {
            showToast("The built edit opens with its take in the editor")
            return
        }
        closeRecreate()
        openEdit(takeId: id)
    }
}
