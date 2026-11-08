import AppKit
import AVFoundation
import Foundation
import MuseCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

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
    /// Shots unticked in the confirmation ("pick which ones"): they stay to generate for later and aren't charged.
    var confirmSkipped: Set<String> = []
    /// Slots whose new shot didn't generate (refunded by the server), in plain words.
    var fillErrors: [String: String] = [:]
    /// Takes picked here ("Use one of my takes"), kept over each fill refresh.
    var picks: [String: RecreateFill.SlotFill] = [:]
    /// Survive leaving the reference (never cleared by `clearReference`): references whose edit is built as soon as their
    /// new shots are ready, and "referenceId/slotId" fills still being started (never started twice).
    var buildWhenReady: Set<String> = []
    var startingFills: Set<String> = []

    // Start page: a pasted link (plans/api.md "From a link").
    var linkText = ""
    var fetchingLink = false
    /// While a link is fetched on this Mac: "Fetching the video… 42%", then the upload; and its progress (0…1).
    var linkStatus: String?
    var linkProgress: Double?
    /// The fetch in progress (Stop cancels it).
    @ObservationIgnored var linkTask: Task<Void, Never>?
    /// The studio's link rules (GET /v1/recreate/settings), when the server has them.
    var linkSettings: RecreateLinkSettings?
    /// The last link refusal, with the file drop offered beside it (every link_* code).
    var linkProblem: RecreateLinkProblem?

    /// The Cast step (Release 1 item E): who plays the lead in the new shots. nil = the studio's current model.
    var leadId: String?
    /// The cast list is open under the lead (inline in the panel).
    var castOpen = false

    /// The edit session the built edit lives in (after Build), and the built edit Compare plays.
    var sessionId: String?
    var built: RecreateBuiltPreview?
    var loadingBuilt = false

    /// How each shot is made (G2): "swap" | "generate" picked here (nil = the server's default, swap), the swaps that use
    /// your own setting instead of the reference's, and each slot's full estimate (method, button label, swap notes).
    var methods: [String: String] = [:]
    var ownSetting: Set<String> = []
    /// "Use your own setting": the studio location picked per shot (nil = make one from the brief).
    var locationFor: [String: String] = [:]
    /// Shots whose fill came back with a new price or a failed background: priced and confirmed again before anything.
    var repriced: Set<String> = []
    var estimateInfo: [String: RecreateSlotEstimate] = [:]
    /// Swapped shots that already carry the reference's camera, speed and look (slotId → parts): "Already in the shot".
    var baked: [String: [String]] = [:]

    /// "Write the shot briefs" (G8): its price or why it's off, the confirmation, and the write in progress.
    var briefs: RecreateBriefsEstimate?
    var askBriefs = false
    var writingBriefs = false
    var briefsError: String?

    /// "Fix shot N" in Compare: the shot the sheet is open for, what it is doing, its price and any problem.
    var fixSlot: String?
    var fixBusy: String?
    var fixEstimate: ShotEstimate?
    /// The priced method (sent explicitly with the fill), and why a swap fell back to generate.
    var fixMethod: String?
    var fixSwapNote: String?
    var fixError: String?
    /// The shot isn't in the edit any more (slot_not_in_edit): the sheet offers "Rebuild the edit".
    var fixNeedsRebuild = false
    /// Demo mode: shots swapped for a take, kept on this Mac so "Your edit" shows them (slotId → takeId).
    var demoSwaps: [String: String] = [:]
    @ObservationIgnored var fixTask: Task<Void, Never>?

    /// Export (plans/recreate-edit.md step 7).
    var exportOpen = false
    var exportSound: RecreateExport.Sound = .guide
    /// 0…1 while exporting.
    var exportProgress: Double?
    var exportedFile: URL?
    var exportError: String?
    /// The server's "Post with the original sound" steps (with its export), when it sends them.
    var useThisSound: UseThisSound?
    @ObservationIgnored var exportTask: Task<Void, Never>?

    /// Claude on the Recreate screens (Release 1 item C).
    var claudeOpen = false
    /// The edit session Claude's tools work in (the built edit's, or one opened on a take for it).
    var claudeSessionId: String?
    /// A paid step Claude asked for (fill_slot with confirm): waiting for the owner's answer. Never started without it.
    var claudeAsk: EditPending?
    @ObservationIgnored var claudeWatch: Task<Void, Never>?
    @ObservationIgnored var claudeRevision: Int?

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
        linkTask?.cancel()
        linkTask = nil
        linkText = ""
        fetchingLink = false
        linkStatus = nil
        linkProgress = nil
        linkSettings = nil
        leadId = nil
        closeClaude()
        claudeSessionId = nil
    }

    func closeClaude() {
        claudeWatch?.cancel()
        claudeWatch = nil
        claudeOpen = false
        claudeAsk = nil
        claudeRevision = nil
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
        confirmSkipped = []
        fillErrors = [:]
        picks = [:]
        linkProblem = nil
        sessionId = nil
        built?.close()
        built = nil
        loadingBuilt = false
        exportTask?.cancel()
        exportTask = nil
        exportOpen = false
        exportProgress = nil
        exportedFile = nil
        exportError = nil
        useThisSound = nil
        fixTask?.cancel()
        fixTask = nil
        fixSlot = nil
        fixBusy = nil
        fixEstimate = nil
        fixError = nil
        fixNeedsRebuild = false
        demoSwaps = [:]
        briefs = nil
        askBriefs = false
        writingBriefs = false
        briefsError = nil
        methods = [:]
        ownSetting = []
        locationFor = [:]
        repriced = []
        estimateInfo = [:]
        baked = [:]
        claudeAsk = nil
        claudeRevision = nil
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
    var confirmTotal: Double { confirmPicked.compactMap { estimates[$0]?.estimate }.reduce(0, +) }
    /// The ticked shots of the open confirmation (all of them unless the person unticked some).
    var confirmPicked: [String] { confirmSlots.filter { !confirmSkipped.contains($0) } }
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
        Task { await loadRecreateLinkSettings() }
        // "Use your own setting" lists the studio locations (the Suite's own list).
        if suite.locations.isEmpty { Task { if let l = try? await api.suiteLocations() { suite.locations = l } } }
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
            await loadRecreateBriefs()
        }
        if recreate.claudeOpen, !isDemo, recreate.claudeSessionId == nil { await ensureRecreateClaudeSession() }
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
                recreate.fillErrors[s.slotId] = s.fallback == "generate"
                    ? (s.reason ?? "The swap didn’t work and you weren’t charged · generate this shot instead")
                    : "This shot didn’t generate. You weren’t charged for it."
            }
            // A failed swap is offered as generate, priced on its own (the next price asks for generate).
            if s.fallback == "generate", recreate.methods[s.slotId] == nil || recreate.methods[s.slotId] == "swap" {
                recreate.methods[s.slotId] = "generate"
                recreate.estimates[s.slotId] = nil
                recreate.estimateInfo[s.slotId] = nil
            }
            if let p = recreate.picks[s.slotId] { f.slots[i] = p }
        }
        recreate.fill = f
        if !new.baked.isEmpty { recreate.baked = new.baked }
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

    /// "Paste a link" → Fetch. With a server, this Mac downloads the video first (platforms refuse the cloud server) and
    /// uploads it like a dropped file; a video the Mac refuses (private, too long, too big) is shown at once, and when the
    /// Mac can't fetch it at all the server's link endpoint tries (or returns the reference already made from it). A
    /// refusal says why, with the file drop offered right there. Demo mode keeps its instant fake path.
    func createRecreateReference(link raw: String) async {
        let link = RecreateLinks.detect(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !recreate.fetchingLink else { return }
        recreate.error = nil
        recreate.linkProblem = nil
        recreate.fetchingLink = true
        recreate.linkStatus = nil
        recreate.linkProgress = nil
        let task = Task { await fetchRecreateLink(link) }
        recreate.linkTask = task
        await task.value
        recreate.linkTask = nil
        recreate.fetchingLink = false
        recreate.linkStatus = nil
        recreate.linkProgress = nil
    }

    /// Stop: the fetch (on this Mac, or the server's call) is cancelled; nothing is uploaded.
    func stopRecreateLinkFetch() {
        recreate.linkTask?.cancel()
    }

    private func fetchRecreateLink(_ link: String) async {
        if api is HTTPMuseAPI, await fetchLinkOnThisMac(link) { return }
        if Task.isCancelled { return }
        // The server tries (demo mode: its instant fake). On the big platforms it usually answers link_blocked, shown
        // with the file drop offered.
        do {
            let r = try await recreateAPI.createReference(link: link, name: nil)
            if Task.isCancelled { return }
            await openLinkReference(r)
        } catch {
            if Task.isCancelled { return }
            if let p = RecreateLinkProblem(error) {
                recreate.linkProblem = p
            } else {
                recreate.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
            }
        }
    }

    /// A reference made (or found again) from a link, opened.
    private func openLinkReference(_ r: RecreateReference) async {
        recreate.linkText = ""
        if r.cached == true { showToast("You read this video before: here it is again") }
        recreate.references.removeAll { $0.id == r.id }
        recreate.references.insert(r, at: 0)
        await showRecreateReference(r)
    }

    /// The studio's link rules (`GET /v1/recreate/settings`), kept for the Settings toggle; nil when the server doesn't
    /// have the call yet (this Mac then uses the defaults: strict, 60 s, 80 MB).
    @discardableResult
    func loadRecreateLinkSettings() async -> RecreateLinkSettings? {
        guard let s = try? await recreateAPI.linkSettings() else { return nil }
        recreate.linkSettings = s
        return s
    }

    /// Settings → Studio → "Strict link rules" (owner).
    func setStrictLinks(_ on: Bool) {
        Task {
            do {
                recreate.linkSettings = try await recreateAPI.setStrictLinks(on)
                showToast(on ? "Strict link rules are on" : "Strict link rules are off")
            } catch {
                showToast((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)
            }
        }
    }

    /// The link fetched on this Mac (DeviceLinkFetcher) and uploaded with `sourceUrl`, under the studio's link rules.
    /// true = done here (the reference is open, a refusal is shown, or it was stopped); false = the server should try.
    private func fetchLinkOnThisMac(_ raw: String) async -> Bool {
        recreate.linkStatus = RecreateDeviceFetch.statusLine(fetched: nil)
        let settings = await loadRecreateLinkSettings() ?? recreate.linkSettings ?? RecreateLinkSettings()
        // The server's verdict on the link first: refused (with its reason and the file offered), or this member's
        // reference from it (opened, nothing downloaded). A server without the check: strict rules on this Mac.
        var link = raw
        var platform: String?
        do {
            let c = try await recreateAPI.checkLink(raw)
            if Task.isCancelled { return true }
            if let p = c.problem {
                recreate.linkProblem = p
                return true
            }
            if var hit = c.cached {
                hit.cached = true
                await openLinkReference(hit)
                return true
            }
            if let u = c.url, !u.isEmpty { link = u }
            platform = c.platform
        } catch {
            if Task.isCancelled { return true }
            guard RecreateLinks.platform(raw) != nil || !settings.strictLinks else { return false }
        }
        let result = await DeviceLinkFetcher.shared.fetch(link, platform: platform, settings: settings) { v in
            Task { @MainActor [weak self] in
                guard let self, self.recreate.fetchingLink, self.recreate.linkTask?.isCancelled == false else { return }
                self.recreate.linkProgress = v
                self.recreate.linkStatus = RecreateDeviceFetch.statusLine(fetched: v)
            }
        }
        if Task.isCancelled {
            if case .success(let f) = result { try? FileManager.default.removeItem(at: f.file.deletingLastPathComponent()) }
            return true
        }
        switch result {
        case .failure(.refused(let p)):
            // The server would refuse it too: no second try there.
            recreate.linkProblem = p
            return true
        case .failure(.unavailable(let why)):
            NSLog("[link] this Mac couldn't fetch it (%@): the server tries", why)
            return false
        case .success(let f):
            defer { try? FileManager.default.removeItem(at: f.file.deletingLastPathComponent()) }
            recreate.linkStatus = "Uploading the video…"
            recreate.linkProgress = 0
            let title = f.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name: String? = title.isEmpty ? nil : String(title.prefix(80))
            do {
                let r = try await recreateAPI.createReference(file: f.file, contentType: RecreateDeviceFetch.contentType(f.file), name: name,
                                                              sourceUrl: raw) { v in
                    Task { @MainActor [weak self] in
                        guard let self, self.recreate.fetchingLink else { return }
                        self.recreate.linkProgress = v
                        self.recreate.linkStatus = "Uploading the video… \(Int((v * 100).rounded()))%"
                    }
                }
                if Task.isCancelled { return true }
                await openLinkReference(r)
            } catch {
                if Task.isCancelled { return true }
                // The server re-checks the link and the file (422 link_unsupported / link_too_big): shown with the file offered.
                if let p = RecreateLinkProblem(error) {
                    recreate.linkProblem = p
                } else {
                    recreate.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
                }
            }
            return true
        }
    }

    /// ⌘V on the start page: a video file copied in Finder is read like a dropped one; a link is fetched.
    func pasteIntoRecreate() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first(where: Self.isMovieFile) {
            Task { await createRecreateReference(from: file) }
            return
        }
        guard let text = pb.string(forType: .string) ?? (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString else { return }
        recreate.linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let other = recreate.linkSettings?.strictLinks == false && text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http")
        if RecreateLinks.detect(text) != nil || other {
            Task { await createRecreateReference(link: text) }
        } else {
            recreate.linkProblem = RecreateLinkProblem(code: "link_unsupported", message: RecreateLinks.message(code: "link_unsupported", message: nil))
        }
    }

    /// A file a person can drop or paste: a movie by its extension (mp4, mov, m4v…).
    nonisolated static func isMovieFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .movie) ?? false
    }

    // MARK: Cast (Release 1 item E)

    /// The lead the new shots are made with: the one picked here, else the studio's current model, else the first.
    var recreateLead: MuseModel? {
        if let id = recreate.leadId, let m = suiteCharacters.first(where: { $0.id == id }) { return m }
        if let m = currentModel, suiteCharacters.contains(where: { $0.id == m.id }) { return m }
        return suiteCharacters.first
    }

    /// Picks who plays the lead: the new shots are priced again for her (nothing is held).
    func setRecreateLead(_ m: MuseModel) {
        guard m.id != recreateModelId else { return }
        recreate.leadId = m.id
        recreate.estimates = [:]
        recreate.estimateErrors = [:]
        if let id = recreate.reference?.id { Task { await priceRecreateSlots(id) } }
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
    /// The lead picked in the Cast step (Release 1 item E), else the current model, else the first character.
    var recreateModelId: String? { recreateLead?.id ?? currentModel?.id }

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
        let opts = Dictionary(uniqueKeysWithValues: todo.map { ($0, recreateFillOptions($0)) })
        var got: [String: Result<RecreateSlotEstimate, Error>] = [:]
        await withTaskGroup(of: (String, Result<RecreateSlotEstimate, Error>).self) { g in
            for s in todo {
                let o = opts[s] ?? RecreateFillOptions()
                g.addTask {
                    do { return (s, .success(try await api.estimateSlot(id, slotId: s, modelId: model, quality: nil, options: o))) } catch { return (s, .failure(error)) }
                }
            }
            for await (s, r) in g { got[s] = r }
        }
        guard recreate.reference?.id == id else { return }
        for (s, r) in got {
            switch r {
            case .success(let e):
                recreate.estimates[s] = e.estimate
                recreate.estimateInfo[s] = e
                recreate.estimateErrors[s] = e.estimate.problem.map { p in (p.hasSuffix(".") ? p : p + ".") + " Use one of your takes for this shot." }
            case .failure(let err):
                recreate.estimates[s] = nil
                recreate.estimateInfo[s] = nil
                recreate.estimateErrors[s] = Self.recreatePriceProblem(err)
            }
        }
    }

    /// How a slot is made (G2): the method picked here (else generate after a failed swap, else the server's default:
    /// swap), and "Use your own setting" for a swap. No outfit is sent: the Cast step picks the lead only.
    func recreateFillOptions(_ slotId: String) -> RecreateFillOptions {
        let fell = recreate.slotFill(slotId)?.fallback == "generate"
        let method = recreate.methods[slotId] ?? (fell ? "generate" : nil)
        let own = method != "generate" && recreate.ownSetting.contains(slotId)
        return RecreateFillOptions(method: method, keepBackground: own ? false : nil, locationId: own ? recreate.locationFor[slotId] : nil)
    }

    /// "Swap into the reference shot" / "Generate a new shot": the slot is priced again (nothing is held).
    func setRecreateMethod(_ slotId: String, _ method: String) {
        recreate.methods[slotId] = method
        recreate.estimates[slotId] = nil
        recreate.estimateInfo[slotId] = nil
        recreate.estimateErrors[slotId] = nil
        if let id = recreate.reference?.id { Task { await priceRecreateSlots(id) } }
    }

    /// "Keep the reference's setting" (on) / "Use your own setting" (off) for a swap: priced again.
    func setRecreateKeepSetting(_ slotId: String, _ keep: Bool) {
        if keep { recreate.ownSetting.remove(slotId) } else { recreate.ownSetting.insert(slotId) }
        recreate.estimates[slotId] = nil
        recreate.estimateInfo[slotId] = nil
        if let id = recreate.reference?.id { Task { await priceRecreateSlots(id) } }
    }

    /// "Use your own setting": one of the studio's locations (free), or nil = make one from the brief. Priced again.
    func setRecreateLocation(_ slotId: String, _ locationId: String?) {
        recreate.locationFor[slotId] = locationId
        recreate.estimates[slotId] = nil
        recreate.estimateInfo[slotId] = nil
        if let id = recreate.reference?.id { Task { await priceRecreateSlots(id) } }
    }

    private static func recreatePriceProblem(_ error: Error) -> String {
        guard let e = error as? ApiError else { return "This shot couldn’t be priced. Check the connection and try again." }
        switch e.code {
        case "swap_unavailable": return "Swapping can’t run for this shot right now. Generate a new shot instead, or use one of your takes."
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
        recreate.confirmSkipped = []
        recreate.askBuild = true
    }

    /// The person said yes to the total: each confirmed shot is made (one at a time; the server holds and charges it),
    /// then, once all are ready, the edit is built and Compare opens. Leaving the page doesn't stop it: the fills that
    /// were confirmed are still started, and coming back resumes from the server's fill. A slot is never filled twice.
    func confirmRecreateBuild() {
        guard let ref = recreate.reference, !recreate.building else { return }
        let id = ref.id
        // Only the ticked shots are made; unticked ones stay "to generate" for later. At least one must be ticked.
        guard recreate.confirmSlots.isEmpty || !recreate.confirmPicked.isEmpty else { return }
        let confirmed = recreate.confirmPicked
        recreate.askBuild = false
        recreate.confirmSlots = []
        recreate.confirmSkipped = []
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
        // Each shot is made the way it was priced and confirmed (the estimate's method, sent explicitly).
        var opts: [String: RecreateFillOptions] = [:]
        for s in confirmed {
            var o = recreateFillOptions(s)
            if let m = recreate.estimateInfo[s]?.method { o.method = m }
            o.maxUsd = recreate.estimates[s]?.estimate
            opts[s] = o
        }
        let fillOpts = opts
        Task { [weak self] in
            guard let self else { return }
            let api = self.recreateAPI
            // The server's own fill decides: a slot already generating or ready is never filled again.
            let current = try? await api.fill(id)
            for s in confirmed {
                defer { self.recreate.startingFills.remove("\(id)/\(s)") }
                if let state = current?.slots.first(where: { $0.slotId == s })?.state, state != "to_generate" { continue }
                do {
                    let started = try await api.fillSlot(id, slotId: s, modelId: model, quality: nil, options: fillOpts[s] ?? RecreateFillOptions())
                    if !self.isDemo { self.upsert(started.job) }
                    self.recreate.fillErrors[s] = nil
                    self.recreate.repriced.remove(s)
                    if self.recreate.reference?.id == id, var f = self.recreate.fill, let i = f.slots.firstIndex(where: { $0.slotId == s }) {
                        f.slots[i].state = "generating"
                        f.slots[i].jobId = started.job.id
                        f.slots[i].method = started.method ?? fillOpts[s]?.method
                        self.recreate.fill = f
                    }
                } catch {
                    if self.recreate.reference?.id == id {
                        let e = error as? ApiError
                        switch e?.code {
                        case "swap_unavailable":
                            self.recreate.fillErrors[s] = "Swapping can’t run for this shot right now. Generate a new shot instead (it’s priced first)."
                        case "background_failed", "price_changed":
                            // The server's own words ("you weren't charged" / the new price); priced again before any retry.
                            self.recreate.fillErrors[s] = e?.message ?? "This shot didn’t start."
                            self.recreate.repriced.insert(s)
                            self.recreate.estimates[s] = nil
                            self.recreate.estimateInfo[s] = nil
                        default:
                            self.recreate.fillErrors[s] = "This shot didn’t start: \(e?.friendlyMessage ?? error.localizedDescription)"
                        }
                        if e?.code == "swap_unavailable" { self.recreate.methods[s] = "generate" }
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
            // A new price (409 price_changed) or a background that couldn't be made: the server's words, and nothing is
            // made until the new price is seen and confirmed (Try again prices the shot and asks again).
            if let s = failed.first(where: { recreate.repriced.contains($0) }), let why = recreate.fillErrors[s] {
                showToast("\(recreate.shotName(s)): \(why)", action: "Review the price") { [weak self] in
                    Task { await self?.requestRecreateBuild() }
                }
                return
            }
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
            recreate.baked = result.baked ?? [:]
            recreate.builtTakeId = baseTake
            recreate.sessionId = isDemo ? nil : sessionId
            if !isDemo { recreate.claudeSessionId = sessionId }
            recreate.mode = .compare
            Task { await loadRecreateBuilt() }
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

    // MARK: Write the shot briefs (G8)

    /// Shots without a brief ("Not described yet"): the button's price, or why it's off. Free; nothing is held. Older
    /// servers (404) just don't show the button.
    func loadRecreateBriefs() async {
        guard let ref = recreate.reference, !(ref.recipe?.slotsWithoutBriefs.isEmpty ?? true) else { recreate.briefs = nil; return }
        let e = try? await recreateAPI.briefsEstimate(ref.id)
        guard recreate.reference?.id == ref.id else { return }
        recreate.briefs = e
    }

    func requestRecreateBriefs() {
        guard recreate.briefs?.available == true, !recreate.writingBriefs else { return }
        recreate.briefsError = nil
        recreate.askBriefs = true
    }

    /// The owner said yes to the price: one call writes every brief (charged from the wallet). The returned reference
    /// replaces the one on screen, and the new shots are priced again from their briefs.
    func confirmRecreateBriefs() {
        guard let ref = recreate.reference else { return }
        recreate.askBriefs = false
        recreate.writingBriefs = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.recreate.writingBriefs = false }
            do {
                let w = try await self.recreateAPI.writeBriefs(ref.id)
                if !self.isDemo, let b = try? await self.api.balance() { self.balance = b }
                guard self.recreate.reference?.id == ref.id else { return }
                let fresh: RecreateReference
                if let r = w.reference { fresh = r } else { fresh = try await self.recreateAPI.reference(ref.id) }
                self.recreate.reference = fresh
                if let i = self.recreate.references.firstIndex(where: { $0.id == fresh.id }) { self.recreate.references[i] = fresh }
                self.recreate.briefs = nil
                let n = w.written.count
                self.showToast(n == 1 ? "1 shot described" : "\(n) shots described")
                self.recreate.estimates = [:]
                self.recreate.estimateInfo = [:]
                await self.priceRecreateSlots(ref.id)
            } catch {
                // briefs_unavailable / editor_paid_off (503), editor_daily_cap (402), briefs_failed (502, nothing charged).
                self.recreate.briefsError = (error as? ApiError)?.message ?? error.localizedDescription
            }
        }
    }

    // MARK: Fix shot N (Compare: replace one shot in the built edit)

    /// The session the edit was built into (demo mode: the fake's).
    private var recreateBuiltSession: String? { recreate.sessionId ?? (isDemo && recreate.match != nil ? "es_demo" : nil) }

    /// Compare → "Fix shot N": the sheet with "Use one of my takes" and "Regenerate this shot".
    func openRecreateFix(_ i: Int) {
        guard recreate.slots.indices.contains(i) else { return }
        recreate.playing = false
        selectRecreateSlot(i)
        recreate.fixSlot = recreate.slots[i].id
        recreate.fixBusy = nil
        recreate.fixEstimate = nil
        recreate.fixMethod = nil
        recreate.fixSwapNote = nil
        recreate.fixError = nil
        recreate.fixNeedsRebuild = false
    }

    func closeRecreateFix() {
        // A shot already being made carries on; it goes into the edit when it's done.
        recreate.fixSlot = nil
    }

    /// Swaps the shot's clip in the built edit for `take` (a take id, or a finished fill job id) as one undoable change, then
    /// plays the new revision in Compare.
    @discardableResult
    func replaceRecreateSlot(_ slotId: String, take: String) async -> String? {
        guard let ref = recreate.reference, let sid = recreateBuiltSession else {
            recreate.fixError = "Build the edit first."
            return "not_built"
        }
        recreate.fixError = nil
        recreate.fixNeedsRebuild = false
        recreate.fixBusy = "Putting it in the edit"
        defer { recreate.fixBusy = nil }
        do {
            let r = try await recreateAPI.replaceSlot(ref.id, slotId: slotId, sessionId: sid, take: take, baseRevision: nil)
            guard recreate.reference?.id == ref.id else { return nil }
            if isDemo, let t = r.takeId { recreate.demoSwaps[slotId] = t }
            // A swapped take is baked in; any other take brings the reference's camera, speed and look back.
            recreate.baked[slotId] = r.baked.flatMap { $0.isEmpty ? nil : $0 }
            if recreate.fixSlot == slotId { recreate.fixSlot = nil }
            showToast(r.note ?? "\(recreate.shotName(slotId)) replaced. Undo it in the editor’s history.")
            await loadRecreateBuilt()
            return nil
        } catch let e as ApiError {
            switch e.code {
            case "slot_not_in_edit":
                recreate.fixNeedsRebuild = true
                recreate.fixError = "\(recreate.shotName(slotId)) isn’t in the edit any more. Rebuild the edit to put it back."
            case "not_built_here":
                recreate.fixError = "This edit wasn’t built from this reference here. Build the edit again first."
            case "job_not_done":
                recreate.fixError = nil
            case "bad_request", "http_400":
                recreate.fixError = "That take can’t be used: it has no video yet, or it’s gone."
            default:
                recreate.fixError = e.friendlyMessage
            }
            return e.code
        } catch {
            recreate.fixError = error.localizedDescription
            return "failed"
        }
    }

    /// slot_not_in_edit → "Rebuild the edit": the recipe applied again with the current fill.
    func rebuildRecreateFromFix() {
        recreate.fixSlot = nil
        Task { await applyRecreate() }
    }

    /// "Regenerate this shot", step 1: its price (nothing is held).
    func priceRecreateFix() async {
        guard let ref = recreate.reference, let slot = recreate.fixSlot else { return }
        guard let model = recreateModelId else { recreate.fixError = "Add a model first: new shots are made with her."; return }
        recreate.fixError = nil
        recreate.fixBusy = "Pricing the shot"
        defer { recreate.fixBusy = nil }
        do {
            let e = try await recreateAPI.estimateSlot(ref.id, slotId: slot, modelId: model, quality: nil, options: recreateFillOptions(slot))
            if let p = e.estimate.problem {
                recreate.fixError = p
            } else {
                recreate.fixEstimate = e.estimate
                recreate.fixMethod = e.method
                recreate.fixSwapNote = e.swapUnavailable
            }
        } catch {
            recreate.fixError = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    /// "Regenerate this shot", step 2, after the owner saw the price and said yes: the shot is made (held and charged like
    /// any shot), its fill is read every 3 s until it's ready, then it replaces the shot in the edit.
    func confirmRecreateFix() {
        guard let ref = recreate.reference, let slot = recreate.fixSlot, recreate.fixEstimate != nil, let model = recreateModelId else { return }
        var opts = recreateFillOptions(slot)
        if let m = recreate.fixMethod { opts.method = m }
        opts.maxUsd = recreate.fixEstimate?.estimate
        let fillOpts = opts
        let id = ref.id
        recreate.fixEstimate = nil
        recreate.fixBusy = "Generating \(recreate.shotName(slot).lowercased())"
        recreate.fixTask?.cancel()
        recreate.fixTask = Task { [weak self] in
            guard let self else { return }
            let api = self.recreateAPI
            do {
                let started = try await api.fillSlot(id, slotId: slot, modelId: model, quality: nil, options: fillOpts)
                if !self.isDemo { self.upsert(started.job) }
                if !self.isDemo, let b = try? await self.api.balance() { self.balance = b }
                var job = started.job.id
                for _ in 0..<400 {
                    try await Task.sleep(for: .seconds(3))
                    guard let f = try? await api.fill(id), let s = f.slots.first(where: { $0.slotId == slot }) else { continue }
                    if self.recreate.reference?.id == id { self.takeRecreateFill(f) }
                    if s.state == "ready" {
                        job = s.jobId ?? job
                        // The job may still be finishing on the server: job_not_done means read again.
                        while true {
                            guard self.recreate.reference?.id == id else { return }
                            let code = await self.replaceRecreateSlot(slot, take: job)
                            guard code == "job_not_done" else { return }
                            self.recreate.fixBusy = "Finishing the new shot"
                            try await Task.sleep(for: .seconds(3))
                        }
                    }
                    if s.state == "to_generate" || s.state == "empty" {
                        self.recreate.fixBusy = nil
                        self.recreate.fixError = s.fallback == "generate" ? (s.reason ?? "The swap didn’t work and you weren’t charged · generate this shot instead") : "\(self.recreate.shotName(slot)) didn’t generate. You weren’t charged for it."
                        return
                    }
                }
                self.recreate.fixBusy = nil
                self.recreate.fixError = "\(self.recreate.shotName(slot)) is taking long. It goes into the edit when you fix it again once it’s ready."
            } catch is CancellationError {
            } catch {
                self.recreate.fixBusy = nil
                let e = error as? ApiError
                self.recreate.fixError = ["background_failed", "price_changed"].contains(e?.code ?? "") ? e?.message : (e?.friendlyMessage ?? error.localizedDescription)
            }
        }
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

    // MARK: The built edit (Compare's "Your edit", Release 1 gap 1)

    /// The built edit as a project and its files on this Mac. With a server: the edit session's own project (what Build
    /// wrote: ramps, camera keys, text, the Look), its takes downloaded. Demo mode (no session): the recipe assembled the
    /// server's way on the newest video take, so Compare still plays a real edit. nil when there is no video to build on.
    func recreateBuiltProject() async throws -> (project: EditV2.Project, files: [String: URL])? {
        let project: EditV2.Project
        if isDemo {
            guard let recipe = recreate.recipe, let take = editSuiteTakes.first(where: { !$0.isEdit }),
                  let v = take.videoUrl, let url = URL(string: v) else { return nil }
            var locals: [String: URL] = [:]
            var facts: [String: RecreateAssembly.TakeInfo] = [:]
            func load(_ t: Take, _ url: URL) async throws {
                guard facts[t.id] == nil else { return }
                let local = try await EditSuiteMedia.localCopy(url, key: t.id)
                let info = try await VideoEditEngine.info(AVURLAsset(url: local))
                locals[t.id] = local
                facts[t.id] = RecreateAssembly.TakeInfo(id: t.id, durationSec: info.duration, width: info.width, height: info.height)
            }
            try await load(take, url)
            var slotTakes: [String: RecreateAssembly.TakeInfo] = [:]
            for s in recipe.slots {
                // "Fix shot N" swapped this shot for one of the takes (demo mode keeps the swap on this Mac).
                if let id = recreate.demoSwaps[s.id], let t = self.takes.first(where: { $0.id == id }), let v = t.videoUrl, let u = URL(string: v) {
                    try await load(t, u)
                    slotTakes[s.id] = facts[t.id]
                } else {
                    slotTakes[s.id] = facts[take.id]
                }
            }
            project = RecreateAssembly.project(recipe, sourceTakeId: take.id, takes: slotTakes, paletteIds: EditV2LookLibrary.shared.paletteIds,
                                               startAtSlot: true).project
            var files: [String: URL] = [:]
            for a in project.assets { if let t = a.take, let f = locals[t] { files[a.id] = f } }
            return (project, files)
        }
        guard let sid = recreate.sessionId else { return nil }
        let session = try await api.editSession(id: sid)
        project = try JSONPatch.decode(EditV2.Project.self, session.project)
        // New shots made for the edit are new takes: read the gallery once when one isn't here yet.
        if project.assets.contains(where: { a in a.take.map { id in !takes.contains { $0.id == id } } ?? false }) { await reload() }
        var files: [String: URL] = [:]
        for a in project.assets {
            var link: String?
            if let t = a.take { link = takes.first { $0.id == t }?.videoUrl }
            if link == nil { link = a.url }
            guard let link, let url = URL(string: link) else { continue }
            files[a.id] = try await EditSuiteMedia.localCopy(url, key: a.take ?? a.upload ?? a.id)
        }
        return (project, files)
    }

    /// Builds the player for "Your edit" with the editor's own engine (EditV2Engine), so it plays what the editor plays.
    func loadRecreateBuilt() async {
        let id = recreate.reference?.id
        recreate.built?.close()
        recreate.built = nil
        recreate.loadingBuilt = true
        defer { recreate.loadingBuilt = false }
        // A server that renders previews: its render of the session's revision (what Export makes too). An older server
        // (404) or a failed render falls back to this Mac's render with the editor's engine.
        if !isDemo, let sid = recreate.sessionId {
            if let b = try? await serverBuiltPreview(sid) {
                guard recreate.reference?.id == id else { b.close(); return }
                await b.load()
                if b.phase == .ready {
                    b.seek(recreate.time)
                    recreate.built = b
                    return
                }
                b.close()
            }
            guard recreate.reference?.id == id else { return }
        }
        do {
            guard let got = try await recreateBuiltProject(), recreate.reference?.id == id else { return }
            let b = RecreateBuiltPreview(project: got.project, files: got.files)
            await b.load()
            guard recreate.reference?.id == id else { b.close(); return }
            b.seek(recreate.time)
            recreate.built = b
        } catch {
            // Compare keeps the stand-in; say why once.
            showToast("Your edit couldn’t be loaded to play here: \((error as? ApiError)?.message ?? error.localizedDescription)")
        }
    }

    /// `POST …/preview`, then the state every 2 s (up to 3 minutes) until it is ready; its file downloaded with the token.
    /// nil when the server has no previews, the render failed or took too long.
    private func serverBuiltPreview(_ sid: String) async throws -> RecreateBuiltPreview? {
        let api = recreateAPI
        var r = try await api.startPreview(sessionId: sid)
        var polls = 0
        while !r.isReady {
            if r.isFailed || polls >= 90 || recreate.sessionId != sid { return nil }
            try await Task.sleep(for: .seconds(2))
            r = try await api.preview(sessionId: sid, revision: r.revision)
            polls += 1
        }
        guard let file = await RecreateMediaLoader.video(recreateMedia(r.url)) else { return nil }
        return RecreateBuiltPreview(render: r, file: file)
    }

    // MARK: Export (plans/recreate-edit.md step 7)

    func openRecreateExport() {
        recreate.playing = false
        recreate.exportProgress = nil
        recreate.exportedFile = nil
        recreate.exportError = nil
        // Without the reference's sound on this Mac (demo mode), the silent export is the one on offer.
        if !recreateHasReferenceSound { recreate.exportSound = .silent }
        recreate.exportOpen = true
        // Demo mode: the fake's steps, shaped like the server's.
        if isDemo, let r = recreate.reference { recreate.useThisSound = FakeRecreateAPI.useThisSound(r) }
        // The server's "Post with the original sound" steps for this reference, before anything is exported.
        if !isDemo, let sid = recreate.sessionId, let rid = recreate.reference?.id {
            let sound = recreate.exportSound.rawValue
            Task { [weak self] in
                guard let self, let e = try? await self.recreateAPI.exportState(rid, sessionId: sid, sound: sound) else { return }
                if let u = e.useThisSound { self.recreate.useThisSound = u }
            }
        }
    }

    /// The reference's sound can go under the edit: a server reference with its video and sound.
    var recreateHasReferenceSound: Bool {
        guard let r = recreate.reference else { return false }
        return recreateMedia(r.videoUrl) != nil && r.recipe?.source?.hasAudio != false
    }

    /// Exports the built edit into `dest`: the server's render when it has the export route (workstream 1), else this
    /// Mac's render with the editor's engine, with the reference's sound as the only audio (guide) or none (silent).
    /// Nothing is uploaded or charged. A guide export without the reference's sound offers the silent one.
    func exportRecreate(to dest: URL) {
        guard recreate.exportProgress == nil else { return }
        let sound = recreate.exportSound
        let link = recreate.reference?.videoUrl
        let rid = recreate.reference?.id
        let sid = isDemo ? nil : recreate.sessionId
        recreate.exportError = nil
        recreate.exportedFile = nil
        recreate.exportProgress = 0
        recreate.exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let rid, let sid, let file = try await self.serverExport(rid, sessionId: sid, sound: sound) {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: file, to: dest)
                    self.recreate.exportedFile = dest
                    self.recreate.exportProgress = nil
                    return
                }
                guard let got = try await self.recreateBuiltProject() else {
                    throw ApiError("no_edit", "There’s no built edit to export yet. Build the edit first.")
                }
                var guide: URL?
                if sound == .guide {
                    guide = await RecreateMediaLoader.video(self.recreateMedia(link))
                    if guide == nil { throw ApiError("no_sound", "The reference’s sound couldn’t be loaded. Export silent, or try again.") }
                }
                try await RecreateExporter.export(project: got.project, files: got.files, guide: guide, to: dest) { [weak self] v in
                    self?.recreate.exportProgress = v
                }
                self.recreate.exportedFile = dest
            } catch is CancellationError {
            } catch let e as ApiError where e.code == "no_reference_sound" {
                self.recreate.exportSound = .silent
                self.recreate.exportError = "The reference’s sound is gone (references are kept 30 days). Export silent instead: the cuts are still timed for it."
            } catch {
                self.recreate.exportError = (error as? ApiError)?.message ?? error.localizedDescription
            }
            self.recreate.exportProgress = nil
        }
    }

    /// The server's export: started, then its state every 2 s (up to 5 minutes), then its file downloaded with the token.
    /// nil when the server has no export route (an older server): the Mac renders it instead.
    private func serverExport(_ rid: String, sessionId sid: String, sound: RecreateExport.Sound) async throws -> URL? {
        let api = recreateAPI
        var e: RecreateServerExport
        do {
            e = try await api.startExport(rid, sessionId: sid, sound: sound.rawValue)
        } catch where RecreateExport.serverLacksRender(error) {
            return nil
        }
        if let u = e.useThisSound { recreate.useThisSound = u }
        var polls = 0
        while !e.isReady {
            if e.isFailed { throw ApiError("export_failed", e.error ?? "The export didn’t render. Try again.") }
            if polls >= 150 { throw ApiError("export_slow", "The export is taking too long. Try again in a moment.") }
            try await Task.sleep(for: .seconds(2))
            e = try await api.exportState(rid, sessionId: sid, sound: sound.rawValue)
            if let u = e.useThisSound { recreate.useThisSound = u }
            polls += 1
            recreate.exportProgress = min(0.9, Double(polls) / 30)
        }
        guard let file = await RecreateMediaLoader.video(recreateMedia(e.url)) else {
            throw ApiError("download_failed", "The export couldn’t be downloaded. Try again.")
        }
        return file
    }

    func cancelRecreateExport() {
        recreate.exportTask?.cancel()
        recreate.exportTask = nil
        recreate.exportProgress = nil
    }

    // MARK: Claude (Release 1 item C)

    /// Opens or hides the Claude panel. With a server it finds the edit session Claude's tools work in (the built edit's,
    /// or one opened on the take the edit is built on: free) and watches it for Claude's asks and changes.
    func toggleRecreateClaude() {
        if recreate.claudeOpen { recreate.closeClaude(); return }
        recreate.claudeOpen = true
        guard !isDemo else { return }
        Task { await ensureRecreateClaudeSession() }
    }

    func ensureRecreateClaudeSession() async {
        if recreate.claudeSessionId == nil {
            if let s = recreate.sessionId {
                recreate.claudeSessionId = s
            } else if let take = recreate.fill?.slots.compactMap(\.takeId).first(where: { id in takes.contains { $0.id == id && $0.videoUrl != nil } })
                        ?? recreateTakeChoices.first?.id {
                recreate.claudeSessionId = try? await api.openEditSession(EditSessionOpenRequest(takeId: take, device: "mac")).id
            }
        }
        watchRecreateClaude()
    }

    /// While the panel is open: the session every 3 s. A paid step Claude asked for waits for the owner's answer here;
    /// a change Claude made (apply_recipe) refreshes the fill, the match and "Your edit".
    private func watchRecreateClaude() {
        recreate.claudeWatch?.cancel()
        recreate.claudeWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.recreate.claudeOpen else { return }
                if let sid = self.recreate.claudeSessionId, let s = try? await self.api.editSession(id: sid) {
                    let ask = s.pending.first { $0.status == "waiting" }
                    if ask?.id != self.recreate.claudeAsk?.id { self.recreate.claudeAsk = ask }
                    if let before = self.recreate.claudeRevision, s.revision != before, let ref = self.recreate.reference?.id {
                        self.recreate.sessionId = sid
                        await self.loadRecreateFill(ref)
                        if self.recreate.mode == .compare { await self.loadRecreateBuilt() }
                    }
                    self.recreate.claudeRevision = s.revision
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The owner's answer to Claude's paid step. Only a yes starts (and pays for) it.
    func answerRecreateClaude(approve: Bool) {
        guard let p = recreate.claudeAsk, let sid = recreate.claudeSessionId else { recreate.claudeAsk = nil; return }
        recreate.claudeAsk = nil
        Task {
            do {
                _ = try await api.answerEditPending(sessionId: sid, pendingId: p.id, approve: approve)
                showToast(approve ? "\(p.label) started. Claude adds it to the edit when it’s ready." : "Told Claude not now")
                if approve, !isDemo, let b = try? await api.balance() { balance = b }
            } catch {
                showToast((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)
            }
        }
    }
}
