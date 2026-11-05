import AppKit
import MuseCore
import Observation
import SwiftUI

// AI suite (workstream 1): the Video suite's state and actions. Everything goes through `api` (the real /v1/suite, or demo
// mode's fake). Prices always come from POST /v1/suite/shots/estimate; nothing is spent until someone presses Generate.

enum SuiteMode: String, CaseIterable, Identifiable {
    case hub, shot, swap, storyboard, talking, ugc, extend, cameraStage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hub: return "Video suite"
        case .shot: return "Shot"
        case .swap: return "Character swap"
        case .storyboard: return "Storyboard"
        case .talking: return "Talking · lipsync"
        case .ugc: return "UGC ad"
        case .extend: return "Extend & upscale"
        case .cameraStage: return "Camera stage"
        }
    }

    /// The modes in the sidebar group, in order.
    static let group: [SuiteMode] = [.shot, .swap, .storyboard, .talking, .ugc, .extend, .cameraStage]
    /// No backend yet: a quiet "Coming soon" tile, never a broken screen.
    var comingSoon: Bool { self == .talking || self == .ugc || self == .extend }

    /// Hub tiles: the hardware render behind each, its line and shortcut hint (design/source/ai_desktop.py).
    var tileRender: String {
        switch self {
        case .shot: return "palette-01-naturalistic"
        case .swap: return "palette-04-bleached-warm"
        case .storyboard: return "palette-02-teal-orange"
        case .talking: return "light-06-ring-creator"
        case .ugc: return "grip-05-slider"
        case .extend: return "stock-03-sensor"
        default: return "body-02-super35"
        }
    }

    var tileLine: String {
        switch self {
        case .shot: return "Text or image → a video of your character, with a real camera."
        case .swap: return "Put your character into a real clip. Draft · Standard · HD · Cinema."
        case .storyboard: return "A sequence of shots with the same cast, one look."
        case .talking: return "Script → voice → talking clip, or re-dub a take."
        case .ugc: return "Product refs or a link → review, unboxing, before/after."
        case .extend: return "Longer, smoother, sharper. Finish any take."
        default: return "Block the shot in Blender and use it as the camera."
        }
    }
}

enum SceneTab: String, CaseIterable { case text, image, refs }
enum BagTab: String, CaseIterable { case rig, light, move }
enum BagTarget { case shot, storyboard }
enum SwapKind: String { case swap, recast }

/// The Shot builder's choices (D2).
struct ShotDraft: Equatable {
    var title = "New shot"
    /// Up to 3 characters, lead first.
    var castIds: [String] = []
    var outfitByModel: [String: String] = [:]
    var sceneTab: SceneTab = .text
    var prompt = ""
    var emotion: String?
    var startFrame: ImageRef?
    var endFrame: ImageRef?
    var refs: [SuiteRefImage] = []
    var duration = 5
    var aspect = "9:16"
    var quality = "draft"
    var takes = 1
    var audio = true
    var camera = CameraSpec()
    /// "preset" or "directed".
    var cameraTab = "preset"
}

/// Character swap and Recast (D7).
struct SwapDraft: Equatable {
    var kind: SwapKind = .swap
    var modelId: String?
    var outfitId: String?
    var quality = "standard"
    var keepAudio = true
    /// Swap's add-ons (they stay add-ons: Edit, Fast · beta), off = the ladder.
    var addOn: VideoQuality?
    /// Recast: who in the clip becomes whom (1–4).
    var cast: [CastMember] = []
}

@MainActor
@Observable
final class SuiteState {
    var mode: SuiteMode = .hub
    var catalog: SuiteCatalog?
    var catalogError: String?
    var loadingCatalog = false

    // Shot builder
    var shot = ShotDraft()
    var estimate: ShotEstimate?
    var estimateError: String?
    /// The four tiers' estimates for the quality cards.
    var tierEstimates: [String: ShotEstimate] = [:]
    var shotJobIds: [String] = []
    var shotTakeId: String?
    var generating = false
    /// Owner: the Engines drawer instead of Camera in the Shot builder (D9).
    var showEngines = false
    var settings: SuiteSettings?

    // Camera bag (D3–D5)
    var bagOpen = false
    var bagTab: BagTab = .rig
    var bagDraft = CameraSpec()
    var bagTarget: BagTarget = .shot
    var bagDirected = false
    var moveTag: String?
    var bagNote: String?
    /// Rigs saved from the bag on this Mac ("Save as rig…").
    var savedRigs: [String: CameraSpec] = [:]

    // Character swap + Recast (D7)
    var swap = SwapDraft()
    var swapEstimate: ShotEstimate?
    var swapEstimates: [String: ShotEstimate] = [:]
    var swapError: String?
    var swapJobIds: [String] = []

    // Storyboard (D8)
    var board = Storyboard()
    var boardShotId: String?
    var boardEstimate: Double?
    var boardEstimateError: String?

    /// The take Edit opens with (top-level Edit: nil).
    var editTakeId: String?
    /// Swap with an add-on renders on the classic pipeline: the result pane follows the studio stage's job.
    var swapUsesStage = false

    func reset() {
        catalog = nil
        catalogError = nil
        estimate = nil
        tierEstimates = [:]
        shotJobIds = []
        swapJobIds = []
        swapEstimate = nil
        swapEstimates = [:]
        settings = nil
        board = Storyboard()
        shot = ShotDraft()
        swap = SwapDraft()
        mode = .hub
    }

    var camera: CameraCatalog { catalog?.camera ?? CameraCatalog() }
    var enabled: Bool { catalog?.enabled ?? true }
}

extension AppStore {
    // MARK: Navigation

    func openSuite(_ mode: SuiteMode = .hub) {
        suite.mode = mode
        go(.suite)
        if suite.catalog == nil { Task { await loadSuite() } }
    }

    /// Edit, top level or with a take.
    func openEdit(takeId: String? = nil) {
        suite.editTakeId = takeId
        go(.edit)
    }

    // MARK: Catalog

    func loadSuite(force: Bool = false) async {
        guard force || suite.catalog == nil, !suite.loadingCatalog else { return }
        suite.loadingCatalog = true
        defer { suite.loadingCatalog = false }
        do {
            let c = try await api.suiteCatalog()
            suite.catalog = c
            suite.catalogError = nil
            if suite.shot.castIds.isEmpty, let lead = suiteCharacters.first { suite.shot.castIds = [lead.id] }
            if suite.board.castIds.isEmpty, let lead = suiteCharacters.first { suite.board.castIds = [lead.id] }
            if suite.swap.modelId == nil { suite.swap.modelId = suiteCharacters.first?.id }
            if suite.shot.quality.isEmpty || !SuiteText.tierIds.contains(suite.shot.quality) { suite.shot.quality = c.defaultQuality }
            if suite.savedRigs.isEmpty { suite.savedRigs = Self.loadSavedRigs() }
            if isOwner { suite.settings = try? await api.suiteSettings() }
        } catch let e as ApiError {
            suite.catalogError = e.code == "not_found" || e.code == "http_404" ? "This server doesn't have the AI suite yet" : e.friendlyMessage
        } catch {
            suite.catalogError = error.localizedDescription
        }
    }

    /// The studio's real characters (never placeholders): not drafts, with a sheet.
    var suiteCharacters: [MuseModel] { models.filter { !$0.isDraft && !$0.archived } }

    func character(_ id: String?) -> MuseModel? { id.flatMap { i in models.first { $0.id == i } } }

    // MARK: Shot builder

    var shotRequest: ShotRequest {
        let d = suite.shot
        let lead = d.castIds.first
        var refs = d.refs
        // Other cast members ride as person references.
        for id in d.castIds.dropFirst() {
            if let m = character(id), let face = m.cover { refs.append(SuiteRefImage(image: face, role: "person", label: m.name)) }
        }
        var cam = d.camera
        if let e = d.emotion { cam.performance = .object(["emotion": .string(e)]) }
        let frames = d.sceneTab == .image && (d.startFrame != nil || d.endFrame != nil) ? SuiteFrames(start: d.startFrame, end: d.endFrame) : nil
        return ShotRequest(title: d.title, modelId: lead, outfitId: lead.flatMap { d.outfitByModel[$0] ?? outfits(for: character($0)).first?.id }, prompt: d.prompt,
                           frames: frames, references: refs.isEmpty ? nil : SuiteReferences(images: Array(refs.prefix(6))), duration: d.duration, aspectRatio: d.aspect,
                           quality: d.quality, takes: d.takes, audio: d.audio, camera: cam == CameraSpec() ? nil : cam)
    }

    /// Prices for the Shot builder: the current choice and each tier (debounced by the caller's `.task(id:)`).
    func estimateShot() async {
        guard suite.enabled, suite.catalog != nil else { return }
        let req = shotRequest
        do {
            suite.estimate = try await api.suiteEstimate(req)
            suite.estimateError = nil
        } catch let e as ApiError {
            suite.estimate = nil
            suite.estimateError = e.friendlyMessage
        } catch {}
        suite.tierEstimates = await tierPrices(req)
    }

    /// One estimate per tier (free; nothing is held).
    func tierPrices(_ req: ShotRequest) async -> [String: ShotEstimate] {
        let api = self.api
        var out: [String: ShotEstimate] = [:]
        await withTaskGroup(of: (String, ShotEstimate?).self) { g in
            for t in SuiteText.tierIds {
                var copy = req
                copy.quality = t
                let r = copy
                g.addTask { (t, try? await api.suiteEstimate(r)) }
            }
            for await (t, e) in g { if let e { out[t] = e } }
        }
        return out
    }

    func generateShot() {
        guard !suite.generating else { return }
        if let p = suite.estimate?.problem {
            showToast(p)
            return
        }
        let req = shotRequest
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            let j = try await api.suiteCreateShot(req)
            upsert(j)
            suite.shotJobIds.append(j.id)
            suite.shotTakeId = nil
            balance = try await api.balance()
            showToast("Rendering \(j.engineLabel) · \(Pricing.money(j.cost)). You'll get a notification when it's done.", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    /// The Shot builder's newest job (the result pane follows it).
    var shotJob: Job? { suite.shotJobIds.last.flatMap { id in jobs.first { $0.id == id } } }
    func takes(of job: Job?) -> [Take] { job.map { j in takes.filter { $0.jobId == j.id }.sorted { $0.index < $1.index } } ?? [] }

    func addShotRef(role: String) {
        guard let url = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use image").first else { return }
        perform { [self] in
            let ref = try await uploadImage(url)
            suite.shot.refs.append(SuiteRefImage(image: ref, role: role, label: role.capitalized))
        }
    }

    func setShotFrame(end: Bool) {
        guard let url = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use frame").first else { return }
        perform { [self] in
            let ref = try await uploadImage(url)
            if end { suite.shot.endFrame = ref } else { suite.shot.startFrame = ref }
            suite.shot.sceneTab = .image
        }
    }

    func toggleCast(_ m: MuseModel) {
        if let i = suite.shot.castIds.firstIndex(of: m.id) {
            suite.shot.castIds.remove(at: i)
        } else if suite.shot.castIds.count < 3 {
            suite.shot.castIds.append(m.id)
        } else {
            showToast("Up to 3 in a shot")
        }
    }

    /// The Shot builder's shot goes onto the storyboard (D2 "Add to storyboard").
    func addShotToStoryboard() {
        let d = suite.shot
        suite.board.shots.append(StoryShot(title: d.title, prompt: d.prompt, moveId: d.camera.move?.id, seconds: d.duration))
        if suite.board.castIds.isEmpty { suite.board.castIds = Array(d.castIds.prefix(3)) }
        showToast("Added to the storyboard", action: "Open") { [weak self] in self?.openSuite(.storyboard) }
    }

    // MARK: Camera bag

    func openBag(_ target: BagTarget, tab: BagTab = .rig) {
        suite.bagTarget = target
        suite.bagDraft = target == .shot ? suite.shot.camera : suite.board.camera
        suite.bagDirected = target == .shot && suite.shot.cameraTab == "directed"
        suite.bagTab = tab
        suite.bagNote = nil
        withAnimation(.easeOut(duration: 0.2)) { suite.bagOpen = true }
    }

    func closeBag(apply: Bool) {
        if apply {
            switch suite.bagTarget {
            case .shot: suite.shot.camera = suite.bagDraft
            case .storyboard: suite.board.camera = suite.bagDraft
            }
        }
        withAnimation(.easeIn(duration: 0.15)) { suite.bagOpen = false }
    }

    /// Directed mode (workstream 2) hands back a CameraSpec as JSON.
    func applyDirected(_ json: String) {
        guard var spec = CameraSpec.fromJSON(json) else {
            showToast("That camera couldn't be read")
            return
        }
        spec.mode = "directed"
        suite.bagDraft = spec
        suite.shot.cameraTab = "directed"
        closeBag(apply: true)
        showToast("Directed camera applied")
    }

    func startBag(from preset: SuitePreset?) {
        suite.bagDraft = preset.map(CameraSummary.fromPreset) ?? CameraSpec()
    }

    func toggleBagMove(_ id: String) {
        let r = SuiteMoves.toggle(id, move: suite.bagDraft.move, mix: suite.bagDraft.mix, catalog: suite.camera)
        suite.bagDraft.move = r.move
        suite.bagDraft.mix = r.mix
        suite.bagNote = r.note
    }

    func saveRig(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        suite.savedRigs[n] = suite.bagDraft
        if let d = try? JSONEncoder().encode(suite.savedRigs) { UserDefaults.standard.set(d, forKey: "muse.suite.rigs") }
        showToast("Saved \(n)")
    }

    static func loadSavedRigs() -> [String: CameraSpec] {
        guard let d = UserDefaults.standard.data(forKey: "muse.suite.rigs") else { return [:] }
        return (try? JSONDecoder().decode([String: CameraSpec].self, from: d)) ?? [:]
    }

    // MARK: Character swap + Recast

    var swapRequest: ShotRequest? {
        guard let c = clip else { return nil }
        let d = suite.swap
        switch d.kind {
        case .swap:
            guard let m = d.modelId else { return nil }
            return ShotRequest(mode: "swap", title: "\(character(m)?.shortName ?? "Swap") · swap", modelId: m, outfitId: d.outfitId ?? outfits(for: character(m)).first?.id,
                               quality: d.quality, clipId: c.id, keepAudio: d.keepAudio)
        case .recast:
            guard !d.cast.isEmpty else { return nil }
            return .recast(clipId: c.id, cast: d.cast, quality: d.quality, keepAudio: d.keepAudio, title: "Recast · \(c.name)")
        }
    }

    func estimateSwap() async {
        guard suite.enabled, suite.catalog != nil, let req = swapRequest else {
            suite.swapEstimate = nil
            return
        }
        do {
            suite.swapEstimate = try await api.suiteEstimate(req)
            suite.swapError = nil
        } catch let e as ApiError {
            suite.swapEstimate = nil
            suite.swapError = e.friendlyMessage
        } catch {}
        suite.swapEstimates = await tierPrices(req)
    }

    func generateSwap() {
        if let addOn = suite.swap.addOn {
            // Add-ons stay add-ons: the classic pipeline with the same clip, character and outfit.
            if let m = suite.swap.modelId { modelId = m }
            if let o = suite.swap.outfitId { outfitIdByModel[modelId] = o }
            keepAudio = suite.swap.keepAudio
            quality = addOn
            generate()
            suite.swapUsesStage = true
            return
        }
        guard let req = swapRequest else {
            showToast(clip == nil ? "Choose a clip first" : "Pick who to replace")
            return
        }
        if let p = suite.swapEstimate?.problem {
            showToast(p)
            return
        }
        guard !suite.generating else { return }
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            let j = try await api.suiteCreateShot(req)
            upsert(j)
            suite.swapJobIds.append(j.id)
            suite.swapUsesStage = false
            balance = try await api.balance()
            showToast("Rendering \(j.engineLabel) · \(Pricing.money(j.cost))", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    var swapJob: Job? {
        let id = suite.swapUsesStage ? stageJobIds.last : suite.swapJobIds.last
        return id.flatMap { i in jobs.first { $0.id == i } }
    }

    func addRecastPerson() {
        let max = suite.catalog?.recastMaxPeople ?? 4
        guard suite.swap.cast.count < max else {
            showToast("Up to \(max) people")
            return
        }
        let hints = ["left", "right", "center", "background"]
        let used = Set(suite.swap.cast.compactMap(\.personHint))
        let hint = hints.first { !used.contains($0) } ?? "foreground"
        let who = suiteCharacters.first { m in !suite.swap.cast.contains { $0.characterId == m.id } } ?? suiteCharacters.first
        guard let w = who else {
            showToast("Add a character first")
            return
        }
        suite.swap.cast.append(CastMember(characterId: w.id, personHint: hint))
    }

    // MARK: Storyboard

    func boardRequests() -> [ShotRequest] { suite.board.toGenerate.map { suite.board.request(for: $0) } }

    func estimateBoard() async {
        guard suite.enabled, suite.catalog != nil else { return }
        let reqs = boardRequests()
        guard !reqs.isEmpty else {
            suite.boardEstimate = nil
            return
        }
        var total = 0.0
        do {
            for r in reqs { total += try await api.suiteEstimate(r).estimate }
            suite.boardEstimate = total
            suite.boardEstimateError = nil
        } catch let e as ApiError {
            suite.boardEstimate = nil
            suite.boardEstimateError = e.friendlyMessage
        } catch {}
    }

    func generateBoard() {
        let list = suite.board.toGenerate
        guard !list.isEmpty, !suite.generating else {
            showToast("Write what happens in a shot first")
            return
        }
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            for s in list {
                let j = try await api.suiteCreateShot(suite.board.request(for: s))
                upsert(j)
                if let i = suite.board.shots.firstIndex(where: { $0.id == s.id }) { suite.board.shots[i].jobId = j.id }
            }
            balance = try await api.balance()
            showToast("Generating \(list.count) shot\(list.count == 1 ? "" : "s")", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    func boardJob(_ s: StoryShot) -> Job? { s.jobId.flatMap { id in jobs.first { $0.id == id } } }

    // MARK: Results

    /// Retake: the same request again (a failed one was refunded in full).
    func retakeShot(_ job: Job) {
        if suite.shotJobIds.contains(job.id) { generateShot() } else if suite.swapJobIds.contains(job.id) { generateSwap() } else { runAgain(job) }
    }

    /// "Try Standard": the same shot one tier down.
    func tryCheaper(_ job: Job) {
        let t = job.request.quality ?? "draft"
        guard let i = SuiteText.tierIds.firstIndex(of: t), i > 0 else { return }
        if suite.shotJobIds.contains(job.id) {
            suite.shot.quality = SuiteText.tierIds[i - 1]
            generateShot()
        } else if suite.swapJobIds.contains(job.id) {
            suite.swap.quality = SuiteText.tierIds[i - 1]
            generateSwap()
        }
    }

    // MARK: Owner (D9)

    func loadSuiteSettings() async {
        guard isOwner else { return }
        suite.settings = try? await api.suiteSettings()
    }

    func setSuiteModel(_ id: String, enabled: Bool) {
        perform { [self] in
            suite.settings = try await api.updateSuiteSettings(SuiteSettingsPatch(models: [id: SuiteModelPatch(enabled: enabled)]))
            await loadSuite(force: true)
        }
    }
}

/// Loads the camera bag's photoreal renders from the app bundle (`hardware/<name>.webp`).
@MainActor
enum HardwareRenders {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let i = cache[name] { return i }
        let file = name.hasSuffix(".webp") ? String(name.dropLast(5)) : name
        guard let url = Bundle.main.url(forResource: file, withExtension: "webp", subdirectory: "hardware") ?? Bundle.main.url(forResource: file, withExtension: "webp"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}
