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
    var building = false
    var uploading = false

    let fake = FakeRecreateAPI()
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var playTask: Task<Void, Never>?

    func reset() {
        pollTask?.cancel()
        playTask?.cancel()
        open = false
        references = []
        clearReference()
        error = nil
        uploading = false
    }

    func clearReference() {
        pollTask?.cancel()
        playTask?.cancel()
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
    }

    var recipe: Recipe? { reference?.recipe }
    var slots: [Recipe.Slot] { recipe?.slots ?? [] }
    var duration: Double { max(0.1, recipe?.durationSec ?? reference?.durationSec ?? 0) }
    var selected: Recipe.Slot? { slots.indices.contains(selectedSlot) ? slots[selectedSlot] : nil }
    func slotFill(_ id: String) -> RecreateFill.SlotFill? { fill?.slots.first { $0.slotId == id } }
    func score(_ slotId: String) -> Double? { match?.perSlot?.first { $0.slotId == slotId }?.score }
    /// The slot under the playhead.
    var slotAtTime: Int? { slots.lastIndex { $0.startSec <= time + 1e-6 } }
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
        recreate.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
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
            let f = try await recreateAPI.fill(id)
            guard recreate.reference?.id == id else { return }
            recreate.fill = f
            if let m = f.match { recreate.match = m }
        } catch {
            recreateFail(error)
        }
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

    /// After the person confirmed the total: builds the edit (an edit session on the take the first shot comes from) and
    /// shows Compare. Demo mode builds against the fake; nothing is generated here.
    func buildRecreate() async {
        guard let ref = recreate.reference, let fill = recreate.fill, !recreate.building else { return }
        recreate.building = true
        recreate.playing = false
        defer { recreate.building = false }
        var slots: [String: String] = [:]
        for s in fill.slots {
            if let t = s.takeId { slots[s.slotId] = t } else if let j = s.jobId { slots[s.slotId] = j }
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
