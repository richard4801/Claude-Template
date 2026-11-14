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

/// Swap's Background pill: Keep (the clip's place), New photo (a studio location or an upload), Describe it (the prompt's words).
enum SwapBackground: String, CaseIterable, Equatable {
    case keep, photo, describe
    var label: String {
        switch self {
        case .keep: return "Keep"
        case .photo: return "New photo"
        case .describe: return "Describe it"
        }
    }
    /// What the request sends (nil = the server's default, Keep).
    var value: String? { self == .keep ? nil : rawValue }
}

/// One choice of the Background pill's list.
enum SwapBackgroundPick: Hashable {
    case keep, describe, location(String), upload
}

/// Character swap and Recast (tools of the composer).
struct SwapDraft: Equatable {
    var kind: SwapKind = .swap
    var modelId: String?
    var outfitId: String?
    var quality = "standard"
    var keepAudio = true
    var speaking: ComposerSpeaking = .auto
    /// Background: keep (the clip's place) or describe (the prompt's words set the new place; Auto then runs Genjutsu Light).
    var background: SwapBackground = .keep
    /// New photo: the picture and its name (a location's, or the uploaded file's).
    var backgroundImage: ImageRef?
    var backgroundName: String?
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
    /// Saved rigs (GET /v1/suite/rigs, the Setup rail's Rigs row): members see theirs, the owner sees all.
    var savedRigs: [SuiteRigView] = []
    /// The results feed beside the composer (GET /v1/suite/feed): shown in place of the picture while `feedOpen`; the
    /// loaded cards, the next page and the filter.
    var feedOpen = false
    var feed: [SuiteFeedItem] = []
    var feedCursor: String?
    var feedFilter: SuiteFeedFilter = .all
    /// The feed narrowed to one tool (nil: this composer's tools) or one model (nil: every model).
    var feedTool: String?
    var feedModel: String?
    /// The take open large over the feed.
    var viewerTakeId: String?
    var feedLoading = false
    /// Two takes side by side over the composer (Compare in the feed); one picked waits for the second.
    var compareIds: [String] = []
    /// The Suite queue (build step 3): shots saved to run later, the one being priced for Run, and the fresh price the
    /// person confirms before it runs. The feed's collection filter.
    var queued: [QueuedShot] = []
    var queuePricing: String?
    var runAsk: QueuedEstimate?
    var feedCollection: String?
    /// The character of a draft Reuse settings just restored: its default rig isn't laid over the restored rig.
    var restoredCharacterId: String?
    var estimate: ShotEstimate?
    var estimateError: String?
    /// The four tiers' estimates for the Quality pill.
    var tierEstimates: [String: ShotEstimate] = [:]
    /// The rig check (workstream 3): the estimate's `rig`, or POST /v1/suite/rig-check's when the estimate fails.
    var rig: [RigWarning] = []
    var rigDismissals = RigDismissals()
    var shotJobIds: [String] = []
    /// WS19: each mode's latest job on the stage (tool → job id), also kept in UserDefaults per server.
    var stageJobs: [String: String] = [:]
    var generating = false
    /// Extend: the VIDEO slot's upload in flight (0…1), nil when none.
    var extendUpload: Double?
    /// Owner: the Engines sheet (D9).
    var showEngines = false
    /// Claude in the Suite (owner only): the panel, the shared draft and Claude's paid asks (SuiteClaudeBridge.swift).
    let claude = SuiteClaudeBridge()

    // Photo tool (workstream 3): the count, preset and references; the estimate from POST /v1/suite/photos/estimate.
    var photo = PhotoDraft()
    var photoEstimate: PhotoEstimate?
    var photoError: String?
    /// Reference images still uploading.
    var photoRefsUploading = 0
    /// The Photo tab (owner 2026-11-14): the last estimate's shapes and Auto's model, kept while the next estimate is on
    /// its way (the Size pill and "Auto · <model>" don't blink away on each change).
    var photoAspectsSeen: [PhotoAspectOption] = []
    var photoModelSeen: String?
    /// Photo runs started in this session: the Photo stage shows only these (owner: never an old result on an empty stage).
    var photoSessionJobs: Set<String> = []
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
    // New Swap (beta, plans/new-swap.md): the header switch (remembered on this Mac), the panel's toggles, its estimate
    // and the model pill's list.
    var swapVariant: SwapVariant = SwapVariant.saved
    var remix = RemixDraft()
    var remixEstimate: ShotEstimate?
    var remixError: String?
    var remixModels: RemixModels?

    // Storyboard (D8)
    var board = Storyboard()
    /// The storyboard's look lock as composer settings (Style, Camera setup and angle, Look, Lighting).
    var boardSettings = ComposerSettings()
    var boardShotId: String?
    var boardEstimate: Double?
    var boardEstimateError: String?

    /// The take Edit opens with (top-level Edit: nil).
    var editTakeId: String?
    /// Where Edit's playhead starts on that take (the viewer's Split: "open it in Edit at this moment"); read once.
    var editAt: Double?
    /// One Claude: Claude opened an edit session (open_page edit es_…): Edit opens the editor on exactly that session.
    var editAttach: EditAttach?
    struct EditAttach: Equatable { let id = UUID(); var takeId: String; var sessionId: String }
    /// Edit home's "New" asked for from outside the view (a check): starts a blank project.
    var editNewRequest: UUID?
    /// Recent edits on the Edit home (the last worked on first), loaded when it shows.
    var recentEdits: [EditRecentItem] = []
    /// Counts loads of `recentEdits`; a load shows its list only if no newer one started meanwhile.
    var recentEditsGeneration = 0
    /// A recent edit to open (the home's list, or a check).
    var editResume: EditRecentItem?
    /// Asks the open editor to close back to the Edit home (a check; the editor's own Back does the same).
    var editHomeRequest: UUID?
    /// The editor open now (checks read where it opened).
    var editCurrent: EditSuiteSession?
    /// Swap with an add-on renders on the classic pipeline: the result pane follows the studio stage's job.
    var swapUsesStage = false

    func reset() {
        claude.reset()
        catalog = nil
        catalogError = nil
        estimate = nil
        tierEstimates = [:]
        rig = []
        rigDismissals = RigDismissals()
        shotJobIds = []
        stageJobs = [:]
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
        recentEdits = []
        editResume = nil
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
            suite.swap.addOn = nil // Edit / Fast are swap models in the Model list now (coordinator 2026-11-08)
            if tool == .recast {
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
    func openEdit(takeId: String? = nil, at seconds: Double? = nil) {
        suite.editAt = seconds
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
            revalidateModelPins() // the owner's model pins (WS6)
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
    var composerInputs: SuiteInputs { ComposerModelPicker.inputs(suite.composer, catalog: suite.catalog, settings: suite.settings) }

    var shotRequest: ShotRequest {
        let r = suite.composer.request(suite.composerSlots.slots, composerInputs, locations: suite.locations)
        // Claude's reference images (Claude in the Suite) go as reference images, as on the server's own request.
        return SuiteAssistDraft.request(r, with: suite.claude.references)
    }

    /// "Coming soon" until the server lists the tool in the catalog's modes.
    func isComingSoon(_ tool: ComposerTool) -> Bool { tool.isComingSoon(in: suite.catalog) }
    /// The hub tiles and sidebar: a mode with a composer tool follows the catalog's `tools`.
    func isComingSoon(_ mode: SuiteMode) -> Bool { mode.tool.map { isComingSoon($0) } ?? mode.comingSoon }

    /// The quality changed: the Length slider's range and the owner's engine pin follow it.
    func setComposerQuality(_ id: String) {
        suite.composer.quality = id
        suite.composer.duration = ComposerBar.clampLength(suite.composer.duration, suite.catalog?.tier(id))
        suite.composer = ComposerModelPicker.validated(suite.composer, catalog: suite.catalog, settings: suite.settings) // the owner's model pin (WS6)
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
        var req = shotRequest
        suite.rigDismissals.sync(RigChoices(req))
        if suite.composer.sent != nil { req.draft = ComposerDrafts.draft(suite.composer) } // images sent: the draft carries the choice
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
        var req = shotRequest
        req.draft = ComposerDrafts.draft(suite.composer) // Reuse settings (the server keeps it on the job and its takes)
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
            rememberStage(j.id)
            balance = try await api.balance()
            showToast("Rendering \(j.engineLabel) · \(Pricing.money(j.cost)). You'll get a notification when it's done.", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }


    /// The composer's newest job.
    var shotJob: Job? { suite.shotJobIds.last.flatMap { id in jobs.first { $0.id == id } } }
    /// A job's takes; a Photo job's stills are jobless takes it lists (WS19).
    func takes(of job: Job?) -> [Take] {
        guard let j = job else { return [] }
        if let ids = j.takeIds, !ids.isEmpty { return ids.compactMap { id in takes.first { $0.id == id } } }
        return takes.filter { $0.jobId == j.id }.sorted { $0.index < $1.index }
    }

    // MARK: The stage (WS19)

    private var stageMemoryKey: String { "suite.stage.\(serverKey)" }

    /// A new generation in a mode replaces that mode's stage; remembered across leaving the page and restarts.
    /// `tool`: the mode; nil = the job's own (its draft's), else the composer's.
    func rememberStage(_ jobId: String, tool: ComposerTool? = nil) {
        let own: ComposerTool? = jobs.first(where: { $0.id == jobId }).flatMap { $0.suiteTool }.flatMap { ComposerTool(rawValue: $0) }
        let t = tool ?? own ?? suite.composer.tool
        if t == .photo { suite.photoSessionJobs.insert(jobId) } // the Photo stage shows this session's runs (owner 2026-11-14)
        var m = suite.stageJobs.isEmpty ? (UserDefaults.standard.dictionary(forKey: stageMemoryKey) as? [String: String] ?? [:]) : suite.stageJobs
        m[t.rawValue] = jobId
        suite.stageJobs = m
        UserDefaults.standard.set(m, forKey: stageMemoryKey)
    }

    /// The stage's job for a mode: the newest of the one remembered for it, the newest of my jobs made with it, and this
    /// session's. Running or finished, it comes back when the mode opens again.
    func stageJob(_ tool: ComposerTool) -> Job? {
        let remembered = suite.stageJobs[tool.rawValue] ?? (UserDefaults.standard.dictionary(forKey: stageMemoryKey) as? [String: String])?[tool.rawValue]
        let me = user?.id
        var picks: [Job] = jobs.filter { j in
            j.suiteTool == tool.rawValue && (me == nil || j.userId == nil || j.userId == me)
        }.max { $0.createdAt < $1.createdAt }.map { [$0] } ?? []
        if let id = remembered, let j = jobs.first(where: { $0.id == id }) { picks.append(j) }
        switch tool {
        case .swap, .recast: if let j = swapJob { picks.append(j) }
        case .photo:
            // The Photo tab (owner 2026-11-14): only this session's runs; before one, the stage is empty.
            return picks.filter { suite.photoSessionJobs.contains($0.id) }.max { $0.createdAt < $1.createdAt }
                ?? jobs.filter { suite.photoSessionJobs.contains($0.id) }.max { $0.createdAt < $1.createdAt }
        default: if let j = shotJob, j.suiteTool == nil || j.suiteTool == tool.rawValue { picks.append(j) }
        }
        return picks.max { $0.createdAt < $1.createdAt }
    }

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

    /// Backspace cleared the prompt (owner decision 2026-11-08): the selected preset is unselected and the composer is back
    /// to normal (Shot lets go of `collapsed` and the preset's rows; Photo of its preset).
    func unselectPresetOnEmptyPrompt() {
        guard suite.composer.tokens.isEmpty else { return }
        if suite.composer.tool == .photo {
            suite.photo.presetId = nil
        } else {
            let d = suite.composer.unselectingPreset()
            if d != suite.composer { suite.composer = d }
        }
    }

    // MARK: The picker shell

    func openPicker(_ p: ComposerPicker, step: String? = nil, target: PickerTarget = .composer) {
        suite.pickerTarget = target
        let ugc = target == .composer && suite.composer.tool == .ugc
        let photo = target == .composer && suite.composer.tool == .photo // Photo tool (workstream 3)
        suite.pickerStep = step ?? p.steps(owner: isOwner, target: target, ugc: ugc, photo: photo).first?.id ?? ""
        // Set plainly, never inside withAnimation: in the same tick as a tool switch the animated change sometimes never
        // reached the views that draw the picker (CI reproduced it; the PANEL lines in fit-check.txt). No fade, then.
        suite.picker = p
    }

    func closePicker() {
        suite.picker = nil // plainly, as openPicker
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
                                prompt: d.promptOn || d.background == .describe ? suite.composer.tokens.promptText() : "", quality: d.quality, speaking: d.speaking.value, clipId: c.id, keepAudio: d.keepAudio)
            applySwapBackground(&r, d)
            applyLook(&r)
            applyEnginePick(&r, .swap) // the owner's model (WS6)
            if d.promptOn, let mv = suite.composer.tokens.moves.first?.move {
                var cam = r.camera ?? CameraSpec(mode: "preset")
                cam.move = mv
                r.camera = cam
            }
            return r
        case .recast:
            guard !d.cast.isEmpty else { return nil }
            let cast = RecastFaces.resolveClashes(d.cast, faces: d.people.map(\.face))
            var r = ShotRequest.recast(clipId: c.id, cast: cast, quality: d.quality, keepAudio: d.keepAudio, title: "Recast · \(c.name)",
                                       prompt: d.background == .describe ? suite.composer.tokens.promptText() : "")
            if cast.count == 1 { applySwapBackground(&r, d) } // a new background is a one-person swap
            applyLook(&r)
            applyEnginePick(&r, .recast) // the owner's model (WS6)
            return r
        }
    }

    /// Background: Keep sends nothing; New photo sends its picture (none picked yet = Keep); Describe it sends the words.
    private func applySwapBackground(_ r: inout ShotRequest, _ d: SwapDraft) {
        switch d.background {
        case .keep: r.background = nil
        case .describe: r.background = "describe"
        case .photo:
            guard let img = d.backgroundImage else { r.background = nil; return }
            r.background = "photo"
            r.backgroundImage = img
        }
    }

    /// The Background pill's choice: a studio location or an uploaded picture makes it New photo.
    func pickSwapBackground(_ p: SwapBackgroundPick) {
        switch p {
        case .keep: suite.swap.background = .keep
        case .describe:
            suite.swap.background = .describe
            suite.swap.promptOn = true // the words set the new place
        case .location(let id):
            guard let loc = suite.locations.first(where: { $0.id == id }) else { return }
            suite.swap.background = .photo
            suite.swap.backgroundImage = loc.image
            suite.swap.backgroundName = loc.name
        case .upload:
            guard let url = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use as the new background").first(where: MediaImport.isImage) else { return }
            perform { [self] in
                let ref = try await uploadImage(url)
                suite.swap.background = .photo
                suite.swap.backgroundImage = ref
                suite.swap.backgroundName = url.deletingPathExtension().lastPathComponent
            }
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
        guard suite.enabled, suite.catalog != nil, var req = swapRequest else {
            suite.swapEstimate = nil
            return
        }
        if suite.composer.sent != nil, req.draft == nil { req.draft = ComposerDrafts.draft(suite.composer) } // images sent
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
        guard var req = swapRequest else {
            showToast(clip == nil ? "Choose a clip first" : "Pick who to replace")
            return
        }
        if let p = suite.swapEstimate?.problem {
            showToast(p)
            return
        }
        guard !suite.generating else { return }
        if suite.composer.sent != nil, req.draft == nil { req.draft = ComposerDrafts.draft(suite.composer) } // images sent
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            let j = try await api.suiteCreateShot(req)
            upsert(j)
            suite.swapJobIds.append(j.id)
            rememberStage(j.id)
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

    func boardRequests() -> [ShotRequest] { suite.board.toGenerate.map { boardRequest($0) } }
    /// A storyboard shot's request with the owner's storyboard model (WS6).
    func boardRequest(_ s: StoryShot) -> ShotRequest {
        var r = suite.board.request(for: s)
        applyEnginePick(&r, .storyboard)
        return r
    }

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
                let j = try await api.suiteCreateShot(boardRequest(s))
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
        if job.isPhoto { return generatePhoto() } // WS19: the Photo composer's run again
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
