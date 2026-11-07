import AppKit
import MuseCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// AI suite (workstream 1): the Video suite's state and actions. Everything goes through `api` (the real /v1/suite, or demo
// mode's fake). Prices always come from POST /v1/suite/shots/estimate; nothing is spent until someone presses Generate.
// Shot, Character swap, Recast, Talking, UGC ad and Extend & upscale are tools of one composer (Views/Suite/Composer).

enum SuiteMode: String, CaseIterable, Identifiable {
    case hub, shot, swap, storyboard, talking, ugc, extend, cameraStage
    /// Photo tool (workstream 3): Photoshoot on the composer.
    case photo
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
        case .photo: return "Photo"
        }
    }

    /// The modes in the sidebar group, in order.
    static let group: [SuiteMode] = [.shot, .photo, .swap, .storyboard, .talking, .ugc, .extend, .cameraStage]
    /// No backend yet: a quiet "Coming soon" tile, never a broken screen. (The catalog's `tools` win when it has them.)
    var comingSoon: Bool { self == .talking || self == .ugc }

    /// The composer's tool behind this mode (nil: Storyboard, Camera stage and the hub have their own screens).
    var tool: ComposerTool? {
        switch self {
        case .shot: return .shot
        case .swap: return .swap
        case .talking: return .talking
        case .ugc: return .ugc
        case .extend: return .extend
        case .photo: return .photo
        default: return nil
        }
    }

    /// Hub tiles: the hardware render behind each, its line and shortcut hint (design/source/ai_desktop.py).
    var tileRender: String {
        switch self {
        case .shot: return "palette-01-naturalistic"
        case .swap: return "palette-04-bleached-warm"
        case .storyboard: return "palette-02-teal-orange"
        case .talking: return "light-06-ring-creator"
        case .ugc: return "grip-05-slider"
        case .extend: return "stock-03-sensor"
        case .photo: return "light-04-window"
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
        case .photo: return "Stills of your character in any scene, camera and light."
        default: return "Block the shot in Blender and use it as the camera."
        }
    }
}

extension ComposerTool {
    /// The sidebar entry this tool lights up (Recast lives inside Character swap).
    var mode: SuiteMode {
        switch self {
        case .shot: return .shot
        case .swap, .recast: return .swap
        case .talking: return .talking
        case .ugc: return .ugc
        case .storyboard: return .storyboard
        case .extend: return .extend
        case .photo: return .photo
        }
    }
}

enum SwapKind: String { case swap, recast }

/// Character swap and Recast (tools of the composer).
struct SwapDraft: Equatable {
    var kind: SwapKind = .swap
    var modelId: String?
    var outfitId: String?
    var quality = "standard"
    var keepAudio = true
    var speaking: ComposerSpeaking = .auto
    /// The prompt sits behind a toggle (off by default).
    var promptOn = false
    /// Swap's add-ons (they stay add-ons: Edit, Fast · beta), off = the ladder.
    var addOn: VideoQuality?
    /// Recast: who in the clip becomes whom (1–4), with the face tapped on the first frame.
    var people: [RecastPerson] = []

    /// Recast's cast as the request sends it (a person's face, marker and chip stay with them).
    var cast: [CastMember] {
        get { people.map(\.member) }
        set {
            let old = people
            people = newValue.enumerated().map { i, m -> RecastPerson in
                var p = i < old.count ? old[i] : RecastPerson(member: m)
                p.member = m
                return p
            }
        }
    }
}

/// One person of the clip in Recast: who replaces them, the face tapped on the first frame (its numbered marker) and
/// whether the position chip was picked by hand (then a tap doesn't change it).
struct RecastPerson: Equatable, Identifiable {
    var id = UUID()
    var member: CastMember
    var face: FacePoint?
    var hintChosen = false
    var uploading = false
}

/// Which settings an open picker edits: the composer's, or the storyboard's look lock.
enum PickerTarget { case composer, storyboard }

@MainActor
@Observable
final class SuiteState {
    var mode: SuiteMode = .hub
    var catalog: SuiteCatalog?
    var catalogError: String?
    var loadingCatalog = false

    // The composer
    var composer = ComposerDraft()
    let composerSlots = InputSlotsModel()
    var estimate: ShotEstimate?
    var estimateError: String?
    /// The four tiers' estimates for the Quality pill.
    var tierEstimates: [String: ShotEstimate] = [:]
    /// The rig check (workstream 3): the estimate's `rig`, or POST /v1/suite/rig-check's when the estimate fails.
    var rig: [RigWarning] = []
    var rigDismissals = RigDismissals()
    var shotJobIds: [String] = []
    var generating = false
    /// Extend: the VIDEO slot's upload in flight (0…1), nil when none.
    var extendUpload: Double?
    /// Owner: the Engines sheet (D9).
    var showEngines = false

    // Photo tool (workstream 3): the count, preset and references; the estimate from POST /v1/suite/photos/estimate.
    var photo = PhotoDraft()
    var photoEstimate: PhotoEstimate?
    var photoError: String?
    /// Reference images still uploading.
    var photoRefsUploading = 0
    var settings: SuiteSettings?

    // The picker shell and the tool / preset browser
    var picker: ComposerPicker?
    var pickerStep = ""
    var pickerTarget: PickerTarget = .composer
    var browserOpen = false

    // Character swap + Recast
    var swap = SwapDraft()
    /// The studio's locations (@location in a prompt).
    var locations: [SuiteLocation] = []
    var swapEstimate: ShotEstimate?
    var swapEstimates: [String: ShotEstimate] = [:]
    var swapError: String?
    var swapJobIds: [String] = []

    // Storyboard (D8)
    var board = Storyboard()
    /// The storyboard's look lock as composer settings (Style, Camera setup and angle, Look, Lighting).
    var boardSettings = ComposerSettings()
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
        rig = []
        rigDismissals = RigDismissals()
        shotJobIds = []
        swapJobIds = []
        swapEstimate = nil
        swapEstimates = [:]
        settings = nil
        photo = PhotoDraft() // Photo tool (workstream 3)
        photoEstimate = nil
        photoError = nil
        photoRefsUploading = 0
        board = Storyboard()
        boardSettings = ComposerSettings()
        composer = ComposerDraft()
        composerSlots.slots = InputSlots()
        swap = SwapDraft()
        picker = nil
        browserOpen = false
        mode = .hub
    }

    var camera: CameraCatalog { catalog?.camera ?? CameraCatalog() }
    var enabled: Bool { catalog?.enabled ?? true }

    /// The quality the composer's tool renders at (Swap and Recast keep their own).
    var toolQuality: String {
        get { composer.tool == .swap || composer.tool == .recast ? swap.quality : composer.quality }
        set {
            if composer.tool == .swap || composer.tool == .recast { swap.quality = newValue } else { composer.quality = newValue }
        }
    }

    /// The settings the open picker edits.
    var pickerSettings: ComposerSettings {
        get { pickerTarget == .storyboard ? boardSettings : composer.settings }
        set {
            if pickerTarget == .storyboard {
                boardSettings = newValue
                board.camera = newValue.cameraSpec() ?? CameraSpec()
            } else {
                composer.settings = newValue
            }
        }
    }
}

extension AppStore {
    // MARK: Navigation

    func openSuite(_ mode: SuiteMode = .hub) {
        if let tool = mode.tool {
            let t: ComposerTool = tool == .swap && suite.swap.kind == .recast ? .recast : tool
            if suite.composer.tool != t { suite.composer.collapsed = nil }
            suite.composer.tool = t
            if t == .photo { preparePhoto() } // Photo tool (workstream 3)
            if tool == .swap && clip == nil && isDemo { Task { await useSampleClip(bad: false, quiet: true) } }
        }
        suite.mode = mode
        go(.suite)
        if suite.catalog == nil { Task { await loadSuite() } }
    }

    /// Change on the tool card, the hub tiles and the sidebar: the composer on that tool.
    func openTool(_ tool: ComposerTool) {
        suite.browserOpen = false
        if tool == .swap || tool == .recast {
            suite.swap.kind = tool == .recast ? .recast : .swap
            if tool == .recast {
                suite.swap.addOn = nil
                if suite.swap.cast.isEmpty { addRecastPerson() }
            }
            if clip == nil && isDemo { Task { await useSampleClip(bad: false, quiet: true) } }
        }
        if tool == .storyboard {
            openSuite(.storyboard)
            return
        }
        if suite.composer.tool != tool { suite.composer.collapsed = nil }
        // The UGC format belongs to UGC ad.
        if tool != .ugc { suite.composer.settings.format = nil }
        if tool == .photo { preparePhoto() } // Photo tool (workstream 3): no #moves or tempo in a still
        suite.composer.tool = tool
        suite.mode = tool.mode
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
            if suite.board.castIds.isEmpty, let lead = suiteCharacters.first { suite.board.castIds = [lead.id] }
            if suite.swap.modelId == nil { suite.swap.modelId = suiteCharacters.first?.id }
            if !SuiteText.tierIds.contains(suite.composer.quality) { suite.composer.quality = c.defaultQuality }
            suite.composer.duration = ComposerBar.clampLength(suite.composer.duration, c.tier(suite.composer.quality))
            if isOwner { suite.settings = try? await api.suiteSettings() }
            suite.composer = ComposerEngines.validated(suite.composer, c)
            if let list = try? await api.suiteLocations() { suite.locations = list }
        } catch let e as ApiError {
            suite.catalogError = e.code == "not_found" || e.code == "http_404" ? "This server doesn't have the AI suite yet" : e.friendlyMessage
        } catch {
            suite.catalogError = error.localizedDescription
        }
    }

    /// The studio's real characters (never placeholders): not drafts, with a sheet.
    var suiteCharacters: [MuseModel] { models.filter { !$0.isDraft && !$0.archived } }

    func character(_ id: String?) -> MuseModel? { id.flatMap { i in models.first { $0.id == i } } }

    // MARK: The composer (Shot)

    /// What the chosen quality takes (start / end frames, references, audio); the owner's pinned engine's when one is pinned.
    var composerInputs: SuiteInputs { suite.composer.inputs(suite.catalog) }

    var shotRequest: ShotRequest { suite.composer.request(suite.composerSlots.slots, composerInputs, locations: suite.locations) }

    /// "Coming soon" until the server lists the tool in the catalog's modes.
    func isComingSoon(_ tool: ComposerTool) -> Bool { tool.isComingSoon(in: suite.catalog) }
    /// The hub tiles and sidebar: a mode with a composer tool follows the catalog's `tools`.
    func isComingSoon(_ mode: SuiteMode) -> Bool { mode.tool.map { isComingSoon($0) } ?? mode.comingSoon }

    /// The quality changed: the Length slider's range and the owner's engine pin follow it.
    func setComposerQuality(_ id: String) {
        suite.composer.quality = id
        suite.composer.duration = ComposerBar.clampLength(suite.composer.duration, suite.catalog?.tier(id))
        suite.composer = ComposerEngines.validated(suite.composer, suite.catalog)
    }

    /// The composer's character (the @mention the CHARACTER slot shows).
    var composerCharacter: MuseModel? { character(suite.composer.tokens.characterId) }

    /// Picks the character: an @ chip at the front of the prompt (it replaces the one there).
    func setComposerCharacter(_ m: MuseModel?) {
        var t = suite.composer.tokens
        if let m {
            t = t.addMention(kind: "character", id: m.id, label: m.shortName, at: Caret(0, 0)).0
            if suite.composer.outfitId.map({ o in !outfits(for: m).contains { $0.id == o } }) ?? true { suite.composer.outfitId = outfits(for: m).first?.id }
        } else if let k = t.parts.first(where: { if case .mention(let kind, _, _, _) = $0 { return kind == "character" }; return false })?.key {
            t = t.remove(key: k)
            suite.composer.outfitId = nil
        }
        suite.composer.tokens = t
    }

    /// Prices for the composer: the current choice and each tier (debounced by the caller's `.task(id:)`).
    func estimateShot() async {
        if suite.composer.tool == .extend { return await estimateExtend() }
        guard suite.enabled, suite.catalog != nil else { return }
        let req = shotRequest
        suite.rigDismissals.sync(RigChoices(req))
        do {
            let e = try await api.suiteEstimate(req)
            suite.estimate = e
            suite.estimateError = nil
            suite.rig = e.rig
        } catch let e as ApiError {
            suite.estimate = nil
            suite.estimateError = e.friendlyMessage
            // The warnings still show when no engine fits (the rig check needs no planning).
            suite.rig = (try? await api.suiteRigCheck(req)) ?? []
        } catch {}
        suite.tierEstimates = await tierPrices(req)
    }

    // MARK: The rig check (workstream 3)

    /// The rig warnings the composer shows: a dismissed one stays hidden until the choices change.
    var rigWarnings: [RigWarning] { suite.rigDismissals.visible(suite.rig, at: rigChoices) }

    /// What a dismissal is tied to: the shot's choices, or the Photo request's (workstream 3).
    var rigChoices: RigChoices {
        if suite.composer.tool == .photo { return photoRequest.map { RigChoices($0) } ?? RigChoices() }
        return RigChoices(shotRequest)
    }

    /// A warning's fix (or alt), applied to the choices like a tap in the picker; the line goes until the re-check.
    func applyRigFix(_ fix: RigFix, of w: RigWarning) {
        suite.composer = suite.composer.applying(fix, catalog: suite.camera)
        suite.rig.removeAll { $0.id == w.id }
    }

    func dismissRigWarning(_ w: RigWarning) {
        suite.rigDismissals.dismiss(w, at: rigChoices)
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
        if suite.composer.tool == .extend { return generateExtend() }
        guard !suite.generating else { return }
        if let p = suite.estimate?.problem {
            showToast(p)
            return
        }
        if suite.composerSlots.slots.uploading {
            showToast("Wait for the upload to finish")
            return
        }
        if let need = suite.composer.missing(suite.composerSlots.slots) {
            showToast(need)
            return
        }
        let req = shotRequest
        if req.prompt.isEmpty && req.modelId == nil && req.frames == nil {
            showToast("Describe the scene or pick a character first")
            return
        }
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            let j = try await api.suiteCreateShot(req)
            upsert(j)
            suite.shotJobIds.append(j.id)
            balance = try await api.balance()
            showToast("Rendering \(j.engineLabel) · \(Pricing.money(j.cost)). You'll get a notification when it's done.", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    /// The cinematic Suite is on (owner switch) for this tool: Shot and Photo only in build step 1.
    var cinemaSuite: Bool { newSuite && isOwner }
    func usesCinema(_ mode: SuiteMode) -> Bool { cinemaSuite && (mode == .shot || mode == .photo) }

    /// The composer's newest job.
    var shotJob: Job? { suite.shotJobIds.last.flatMap { id in jobs.first { $0.id == id } } }
    func takes(of job: Job?) -> [Take] { job.map { j in takes.filter { $0.jobId == j.id }.sorted { $0.index < $1.index } } ?? [] }

    /// The Recent takes row: the suite's newest jobs (any job before the first suite one).
    var suiteRecentJobs: [Job] {
        let suiteJobs = jobs.filter { $0.request.engine == "suite" || $0.request.isUpscale }
        return Array((suiteJobs.isEmpty ? jobs : suiteJobs).sorted { $0.createdAt > $1.createdAt }.prefix(6))
    }

    /// The composer's shot goes onto the storyboard.
    func addShotToStoryboard() {
        let d = suite.composer
        suite.board.shots.append(StoryShot(title: d.title, prompt: d.tokens.promptText(), moveId: d.tokens.moves.first?.move?.id, seconds: d.duration))
        if suite.board.castIds.isEmpty, let c = d.tokens.characterId { suite.board.castIds = [c] }
        showToast("Added to the storyboard", action: "Open") { [weak self] in self?.openSuite(.storyboard) }
    }

    /// "Start from a preset": the preset's values in the chips, and the composer collapses to who + shape + Generate (C6).
    func applyPreset(_ p: SuitePreset) {
        suite.browserOpen = false
        if suite.composer.tool != .shot {
            suite.composer.tool = .shot
            suite.mode = .shot
        }
        suite.composer = suite.composer.applying(preset: p, suite.camera)
    }

    // MARK: The picker shell

    func openPicker(_ p: ComposerPicker, step: String? = nil, target: PickerTarget = .composer) {
        suite.pickerTarget = target
        let ugc = target == .composer && suite.composer.tool == .ugc
        let photo = target == .composer && suite.composer.tool == .photo // Photo tool (workstream 3)
        suite.pickerStep = step ?? p.steps(owner: isOwner, target: target, ugc: ugc, photo: photo).first?.id ?? ""
        withAnimation(.easeOut(duration: 0.18)) { suite.picker = p }
    }

    func closePicker() {
        withAnimation(.easeIn(duration: 0.14)) { suite.picker = nil }
    }

    /// Movement: a move tile puts a #move chip in the prompt and closes the picker.
    func insertMove(_ m: SuiteMoveOption) {
        let (t, note) = suite.composer.tokens.addMove(m, catalog: suite.camera)
        if let note {
            showToast(note)
            return
        }
        suite.composer.tokens = t
        closePicker()
    }

    /// Directed mode (workstream 2) hands back a CameraSpec as JSON.
    func applyDirected(_ json: String) {
        guard var spec = CameraSpec.fromJSON(json) else {
            showToast("That camera couldn't be read")
            return
        }
        spec.mode = "directed"
        suite.composer.directed = spec
        closePicker()
        showToast("Directed camera applied")
    }

    // MARK: Character swap + Recast

    var swapRequest: ShotRequest? {
        guard let c = clip else { return nil }
        let d = suite.swap
        switch d.kind {
        case .swap:
            guard let m = d.modelId else { return nil }
            var r = ShotRequest(mode: "swap", title: "\(character(m)?.shortName ?? "Swap") · swap", modelId: m, outfitId: d.outfitId ?? outfits(for: character(m)).first?.id,
                                prompt: d.promptOn ? suite.composer.tokens.promptText() : "", quality: d.quality, speaking: d.speaking.value, clipId: c.id, keepAudio: d.keepAudio)
            applyLook(&r)
            if d.promptOn, let mv = suite.composer.tokens.moves.first?.move {
                var cam = r.camera ?? CameraSpec(mode: "preset")
                cam.move = mv
                r.camera = cam
            }
            return r
        case .recast:
            guard !d.cast.isEmpty else { return nil }
            let cast = RecastFaces.resolveClashes(d.cast, faces: d.people.map(\.face))
            var r = ShotRequest.recast(clipId: c.id, cast: cast, quality: d.quality, keepAudio: d.keepAudio, title: "Recast · \(c.name)")
            applyLook(&r)
            return r
        }
    }

    /// Swap and Recast show only the Look chip: camera and light come from the clip.
    private func applyLook(_ r: inout ShotRequest) {
        let look = suite.composer.settings
        guard look.palette != nil || look.stock != nil else { return }
        r.camera = CameraSpec(mode: "preset", rig: look.stock.map { CameraRig(look: $0) }, palette: look.palette.map { CameraPalette(preset: $0) })
        if !look.gradeLook { r.gradeLook = false }
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

    // MARK: Recast · tap a face

    /// A click on the clip's first frame: on a marker it selects that person; on a new face it goes to the selected
    /// person if they have no face yet, else to a new person (up to the catalog's limit). The position follows the
    /// third the face is in unless a chip was picked, and a square crop around it is uploaded as the person's faceCrop.
    /// Returns the person to select.
    @discardableResult
    func tapFace(_ p: FacePoint, frame: CGImage?, selected: UUID?) -> UUID? {
        let people = suite.swap.people
        let aspect = frame.map { Double($0.width) / Double(Swift.max($0.height, 1)) } ?? 9.0 / 16
        if let hit = RecastFaces.marker(at: p, in: people.map(\.face), aspect: aspect) { return people[hit].id }
        var target = selected.flatMap { id in people.firstIndex { $0.id == id && $0.face == nil } } ?? people.firstIndex { $0.face == nil }
        if target == nil {
            let limit = suite.catalog?.recastMaxPeople ?? 4
            guard people.count < limit else {
                showToast("Up to \(limit) people · remove one first")
                return selected
            }
            let used = Set(people.map(\.member.characterId))
            guard let who = suiteCharacters.first(where: { !used.contains($0.id) }) ?? suiteCharacters.first else {
                showToast("Add a character first")
                return selected
            }
            suite.swap.people.append(RecastPerson(member: CastMember(characterId: who.id, personHint: RecastFaces.hint(x: p.x))))
            target = suite.swap.people.count - 1
        }
        guard let i = target else { return selected }
        var person = suite.swap.people[i]
        person.face = p
        person.member.personHint = RecastFaces.hint(for: p, chosen: person.hintChosen ? person.member.personHint : nil)
        person.member.faceCrop = nil
        suite.swap.people[i] = person
        if let frame { uploadFaceCrop(person.id, p, frame) }
        return person.id
    }

    private func uploadFaceCrop(_ id: UUID, _ p: FacePoint, _ frame: CGImage) {
        let r = RecastFaces.cropRect(p, width: frame.width, height: frame.height)
        guard let crop = frame.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)),
              let jpeg = NSBitmapImageRep(cgImage: crop).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        setPerson(id) { $0.uploading = true }
        let api = self.api
        Task { @MainActor [weak self] in
            do {
                let ref = try await api.uploadImage(name: "face-\(id.uuidString.prefix(8)).jpg", data: jpeg, mime: "image/jpeg", progress: nil)
                // Only while that face is still the one tapped.
                self?.setPerson(id) { q in
                    q.uploading = false
                    if q.face == p { q.member.faceCrop = ref }
                }
            } catch {
                self?.setPerson(id) { $0.uploading = false }
                self?.showToast((error as? ApiError)?.friendlyMessage ?? "The face didn't upload · the position is used instead")
            }
        }
    }

    func setPerson(_ id: UUID, _ f: (inout RecastPerson) -> Void) {
        guard let i = suite.swap.people.firstIndex(where: { $0.id == id }) else { return }
        f(&suite.swap.people[i])
    }

    /// A position chip: it wins over the tapped face's third.
    func setPersonHint(_ id: UUID, _ hint: String) {
        setPerson(id) { p in
            p.member.personHint = hint
            p.member.personIndex = nil
            p.hintChosen = true
        }
    }

    // MARK: @location

    /// Puts an @location in the prompt at `caret`, or says why not (References full).
    func addLocation(_ loc: SuiteLocation, to tokens: PromptTokens, at caret: Caret?) -> PromptTokens {
        let (t, note) = ComposerLocations.add(loc, to: tokens, at: caret, slots: suite.composerSlots.slots, inputs: composerInputs)
        if let note { showToast(note) }
        return t
    }

    /// "+ New location": pick a photo, name it, upload it and save it to the studio's locations.
    func newLocation() async -> SuiteLocation? {
        if let no = ComposerLocations.refusal(suite.composer.tokens, slots: suite.composerSlots.slots, inputs: composerInputs) {
            showToast(no)
            return nil
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = InputSlotsModel.types(.image)
        panel.message = "A photo of the place"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let alert = NSAlert()
        alert.messageText = "Name this location"
        alert.informativeText = "Type @ and its name in any prompt."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Rooftop bar"
        field.stringValue = ComposerLocations.cleanName(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let name = ComposerLocations.cleanName(field.stringValue) else {
            showToast("Give the location a name")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            showToast("Couldn't read that file")
            return nil
        }
        if data.count > InputSlots.maxImageBytes {
            showToast("That photo is over \(InputSlots.maxImageBytes / (1024 * 1024)) MB")
            return nil
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        do {
            let image = try await api.uploadImage(name: url.lastPathComponent, data: data, mime: mime, progress: nil)
            let loc = try await api.createSuiteLocation(NewSuiteLocation(name: name, image: image))
            suite.locations.insert(loc, at: 0)
            return loc
        } catch let e as ApiError {
            showToast(e.code == "not_found" || e.code == "http_404" ? "This server can't save locations yet" : e.friendlyMessage)
        } catch {
            showToast("The location wasn't saved · try again")
        }
        return nil
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
            suite.composer.quality = SuiteText.tierIds[i - 1]
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

/// Loads the composer's photoreal hardware renders from the app bundle (`hardware/<name>.webp`).
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
