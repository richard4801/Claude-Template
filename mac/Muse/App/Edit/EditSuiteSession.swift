import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import AppKit
import MuseCore
import Observation

/// One open Edit suite (designs E1–E4): the editor state (MuseCore EditSuiteState: every edit, undo/redo), the sources on
/// this Mac, the live preview (EditV2Engine), timeline strips and waveforms, Looks thumbnails on the current frame, the AI
/// helper jobs (estimates first; free ones say Free) and the export → upload as a new edited version with its v2 project.
@MainActor
@Observable
final class EditSuiteSession {
    typealias E = EditV2

    enum Phase: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    enum ExportPhase: Equatable {
        case idle
        case rendering(Double)
        case uploading(Double)
    }

    /// E1 (timeline) or E3 (captions & hooks, transcript first).
    enum Mode: String { case timeline, captions }

    let take: Take
    private(set) var sourceTakeId: String
    private(set) var phase: Phase = .loading("Opening the video…")
    /// The editor state. Change it through `edit` so the preview follows.
    private(set) var state: EditSuiteState
    var mode: Mode = .timeline
    var binTab: EditSuite.BinTab = .takes
    /// The playhead while playing (timeline seconds); `state.playhead` follows it when playback stops or an edit needs it.
    private(set) var playhead: Double = 0
    private(set) var playing = false
    /// J / K / L shuttle rate (0 = stopped).
    private(set) var shuttle: Double = 0

    private(set) var files: [String: URL] = [:]
    /// Frame strips per video asset (evenly over the whole file) and waveforms per sounding asset (0…1 peaks over the file).
    private(set) var strips: [String: [CGImage]] = [:]
    private(set) var waves: [String: [Float]] = [:]
    /// Looks thumbnails (look id → tile) of the current frame.
    private(set) var lookThumbs: [String: CGImage] = [:]
    private(set) var lookFrame: CGImage?

    private(set) var jobs: [EditorJobKind: EditorJob] = [:]
    private(set) var estimates: [EditorJobKind: EditorEstimate] = [:]
    /// Remove background → "Pick what to keep": the points on a frame of the selected clip, its picture and its price.
    var keepPick: EditSuite.KeepPick?
    /// What the server offers now (`/v1/editor/features`): paid helpers switched off by the owner, background removal not
    /// ready yet. Nil until asked (everything offered).
    private(set) var features: EditorFeatures?
    /// A paid helper's message shown at its own button (the owner switched them off, today's limit reached).
    private(set) var helperNotes: [EditorJobKind: String] = [:]
    /// A paid helper waiting for the owner to confirm its price (the confirmation dialog).
    private(set) var paidAsk: PaidAsk?
    struct PaidAsk {
        let kind: EditorJobKind
        let title: String
        let price: String
        let go: () async -> Void
    }
    var matteAvailable: Bool { features?.matteAvailable ?? true }
    func helperAvailable(_ k: EditorJobKind) -> Bool { features?.isAvailable(k) ?? true }
    /// Why a helper can't run now, or the message its last try got: shown at its button.
    func helperNote(_ k: EditorJobKind) -> String? { features?.note(k) ?? helperNotes[k] }
    private(set) var keepFrame: CGImage?
    private(set) var keepEstimate: EditorEstimate?
    /// The newest transcript job (fillers / silences reuse it for free).
    private(set) var transcriptJobId: String?
    var lastError: String?
    var notice: String?

    private(set) var exportPhase: ExportPhase = .idle
    private(set) var savedAt: Date?
    /// "v3": edited versions of the source so far + 1.
    private(set) var versionNumber = 1
    /// The file of the last export (for Reveal in Finder).
    private(set) var lastExport: URL?

    let player = AVPlayer()

    @ObservationIgnored let api: any MuseAPI
    @ObservationIgnored private let lookupTake: (String) -> Take?
    @ObservationIgnored var sources = EditV2Engine.Sources()
    @ObservationIgnored private var builtProject: E.Project?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var thumbTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    /// "Remove background" on a clip: its own asset before the cut-out replaced it.
    @ObservationIgnored private var matteOriginal: [String: String] = [:]

    // Claude in the Edit suite (edit sessions, owner only; EditSuiteLive.swift). Members keep the local editor.
    /// The studio owner: the edit is shared live with Claude.
    let isOwner: Bool
    /// This Mac in edit sessions ("mac-1a2b3c4d").
    let device = editSessionDeviceId()
    /// The live session (nil for members, while opening, or when it couldn't be opened: then the editor works locally).
    @ObservationIgnored var live: EditSessionSync?
    /// What the views show of it (the sync itself isn't observed).
    var liveHistory: [EditHistoryEntry] = []
    var liveConnected = false
    /// "Claude · Look · film-gold 70 %" when Claude's change lands.
    var claudeToast: String?
    /// A paid helper Claude asked for, waiting for the owner's answer (the confirmation sheet).
    var askPending: EditPending?
    /// Claude asked for an export: the export sheet opens with these settings.
    var exportAsk: EditSuite.ExportSettings?
    @ObservationIgnored var exportAskRequest: EditAppRequest?
    /// A save/export Claude asked for that is rendering now (answered when it ends).
    @ObservationIgnored var requestInExport: EditAppRequest?
    @ObservationIgnored var liveTasks: [Task<Void, Never>] = []
    @ObservationIgnored var flushTask: Task<Void, Never>?
    @ObservationIgnored var applyingRemote = false
    @ObservationIgnored var nextChangeLabel: String?
    /// This Mac's edits not on the server yet, per take (never dropped silently).
    @ObservationIgnored let drafts = EditSessionDrafts.standard
    /// A kept draft differs from the session's latest: "Keep this device's changes / Use the latest".
    var draftAsk: EditSessionDraft?
    /// The app's gallery hook for versions saved on Claude's request.
    @ObservationIgnored var onVersionSaved: ((Take) -> Void)?

    init(take: Take, api: any MuseAPI, isOwner: Bool = false, lookupTake: @escaping (String) -> Take?) {
        self.take = take
        self.api = api
        self.isOwner = isOwner
        self.lookupTake = lookupTake
        sourceTakeId = take.parentTakeId.flatMap { lookupTake($0) != nil ? $0 : nil } ?? take.id
        // A placeholder until load() reads the source.
        state = EditSuiteState(E.Project(sourceTakeId: take.id, canvas: E.Canvas(width: 1080, height: 1920, fps: 30), assets: [],
                                         tracks: [E.Track(id: "main", kind: .main)]))
        player.actionAtItemEnd = .pause
    }

    var project: E.Project { state.project }
    /// The preview's player item shows the current project (review mode's Edit operations check waits for it).
    var previewIsCurrent: Bool { builtProject == project && player.currentItem != nil }
    var duration: Double { state.duration }
    var isReady: Bool { phase == .ready }
    var busy: Bool { exportPhase != .idle }
    var title: String { take.title.isEmpty ? "Edit" : take.displayTitle }

    // MARK: Loading

    /// Opens the take: a v2 version re-opens its project on its source, a v1 version its edit list (fromV1), anything else
    /// starts fresh on the take's own video.
    func load() async {
        phase = .loading("Opening the video…")
        do {
            let srcTake = lookupTake(sourceTakeId) ?? take
            guard let v = srcTake.videoUrl, let url = URL(string: v) else { throw ApiError("edit_no_video", "This take has no video to edit") }
            let local = try await EditSuiteMedia.localCopy(url, key: srcTake.id)
            let info = try await VideoEditEngine.info(AVURLAsset(url: local))
            guard info.duration > 0 else { throw ApiError("edit_no_video", "This take has no video to edit") }
            let facts = E.SourceFacts(width: info.width, height: info.height, fps: info.fps > 0 ? info.fps : 30, hasAudio: true)
            var project: E.Project
            if let p2 = take.editsV2, take.parentTakeId == sourceTakeId {
                project = p2
            } else if let v1 = take.edits, take.parentTakeId == sourceTakeId {
                project = E.fromV1(v1.fitted(to: info.duration, sourceTakeId: sourceTakeId), facts)
            } else {
                // A take graded with a suite look starts with it on the main clip (reversible like any look).
                project = E.withTakeLook(E.fromV1(EditList(sourceTakeId: sourceTakeId, sourceDurationSec: info.duration), facts), take: srcTake)
            }
            project.sourceTakeId = sourceTakeId
            state = EditSuiteState(project)
            state.paletteIds = EditV2LookLibrary.shared.paletteIds
            state.markSaved()
            for a in project.assets {
                if a.take == sourceTakeId { files[a.id] = local }
                state.assetNames[a.id] = name(of: a)
            }
            phase = .ready
            Task { [weak self] in await self?.refreshFeatures() }
            Task { [weak self] in await self?.loadContent() }
            observeTime()
            await ensureFiles()
            rebuild(immediately: true)
            refreshMedia()
            refreshLookThumbs()
            if let n = try? await api.takeVersions(takeId: sourceTakeId).count { versionNumber = n + 1 }
            if isOwner { await startLive() }
        } catch {
            phase = .failed((error as? ApiError)?.message ?? "Couldn't open this video")
        }
    }

    private func name(of a: E.Asset) -> String {
        if let t = a.take, let tk = lookupTake(t) { return tk.title.isEmpty ? "Take" : tk.displayTitle }
        if a.kind == .audio { return a.library ?? "Audio" }
        return a.kind.rawValue.capitalized
    }

    /// Downloads every asset file the project needs and doesn't have yet (takes by their video, uploads by their url hint).
    private func ensureFiles() async {
        for a in project.assets where files[a.id] == nil {
            // Content stickers and sound effects (WS8 84df583): the catalog's file, downloaded once per catalog version.
            if let ref = a.contentRef {
                if content == nil { await loadContent() }
                if let path = content?.item(ref: ref)?.item.file, let u = await contentFile(path) { files[a.id] = u }
                continue
            }
            var link: String?
            if let t = a.take { link = lookupTake(t)?.videoUrl }
            if link == nil { link = a.url }
            guard let link, let url = URL(string: link) else { continue }
            if let local = try? await EditSuiteMedia.localCopy(url, key: a.take ?? a.upload ?? a.id) { files[a.id] = local }
        }
        await ensureContentFonts()
    }

    /// The content fonts this edit's text and captions use, loaded for the preview (each family draws in its bundled
    /// fallback until its file is here).
    private func ensureContentFonts() async {
        let need = project.contentFonts.filter { !EditV2TextRenderer.hasContentFont($0) }
        guard !need.isEmpty else { return }
        if content == nil { await loadContent() }
        for k in need {
            guard let path = content?.fontFile(k.font, weight: k.weight), let u = await contentFile(path) else { continue }
            EditV2TextRenderer.registerContentFont(k, file: u)
        }
    }

    func close() {
        stopLive()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        buildTask?.cancel()
        exportTask?.cancel()
        thumbTask?.cancel()
    }

    // MARK: Editing

    /// Applies an edit to the state (undoable when it changes the project) and updates the preview.
    @discardableResult
    func edit(_ f: (inout EditSuiteState) -> Bool) -> Bool {
        guard isReady, !busy else { return false }
        if !playing { state.playhead = playhead }
        let before = state.project
        // The closure works on a copy (owner crash 2026-11-08): `f(&state)` held exclusive access to the session's state for
        // the whole closure, so any read of session.state inside it (a view helper) was a Swift exclusivity trap. Reads
        // inside now see the state as it was before this edit; the copy is cheap (copy-on-write).
        var next = state
        let ok = f(&next)
        state = next
        playhead = state.playhead
        // Mac Edit audit: a change the server would refuse is not made; say why instead of silently doing nothing.
        if !ok, let r = state.lastRefusal { lastError = Self.refusalText(r) }
        if state.project != before { projectChanged() }
        return ok
    }

    /// A timeline drag (trim, move): one undo step for the whole gesture; the preview follows (debounced).
    func beginGesture() {
        guard isReady, !busy else { return }
        if !playing { state.playhead = playhead }
        state.beginGesture()
    }

    func updateGesture(_ make: (EditSuiteState) -> E.Project?) {
        guard isReady, !busy else { return }
        let before = state.project
        state.updateGesture(make(state))
        if state.project != before { projectChanged() }
    }

    func endGesture() { state.endGesture() }

    /// "That doesn't fit: the text would run into the next one" style message for a refused change.
    static func refusalText(_ p: E.EditProblem) -> String {
        let f = p.field
        if f == "user" { return p.message }
        if f.hasSuffix("startSec") || f.hasSuffix("durationSec") || p.message.contains("overlap") {
            return "That doesn't fit there · it would overlap the next item on its row"
        }
        if f.contains("transition") { return "That transition doesn't fit · make the clips longer or the transition shorter" }
        if f.contains("duration") || f.contains("speed") { return "That would make the edit too short or too long (0.5 s to 10 min)" }
        return "That change isn't possible here (\(p.message))"
    }

    /// View-only changes (selection, zoom, tabs, snapping…).
    func view(_ f: (inout EditSuiteState) -> Void) { var next = state; f(&next); state = next }   // a copy, as in edit (exclusivity)

    func undo() { nextChangeLabel = "Undo"; edit { $0.undo() }; nextChangeLabel = nil }
    func redo() { nextChangeLabel = "Redo"; edit { $0.redo() }; nextChangeLabel = nil }

    private func projectChanged() {
        Task { await ensureFiles(); rebuild(); refreshMedia() }
        if !applyingRemote { liveLocalChange() }
    }

    /// A change from the live session (Claude's, another device's, a rebase): shown at once, undoable with ⌘Z like any edit.
    func showRemote(_ p: E.Project) {
        guard isReady, p != project else { return }
        if !playing { state.playhead = playhead }
        applyingRemote = true
        // Not a local undo step: ⌘Z keeps undoing only this Mac's own edits (Claude's and other devices' changes are undone
        // from the History list, on the server).
        if state.applyRemote(p) { projectChanged() }
        applyingRemote = false
        playhead = state.playhead
        // A change arriving during a drag ends the drag where it is.
    }

    // MARK: Preview

    /// Rebuilds the player item after a change (debounced), keeping the playhead.
    func rebuild(immediately: Bool = false) {
        buildTask?.cancel()
        let p = project
        let wanted = files
        buildTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard let self, !Task.isCancelled else { return }
            do {
                // Read only the sources not read yet.
                let missing = wanted.filter { id, _ in
                    self.sources.media[id] == nil && self.sources.images[id] == nil && self.sources.luts[id] == nil
                }
                if !missing.isEmpty {
                    let more = try await EditV2Engine.load(p, files: missing)
                    self.sources.media.merge(more.media) { a, _ in a }
                    self.sources.images.merge(more.images) { a, _ in a }
                    self.sources.luts.merge(more.luts) { a, _ in a }
                }
                guard !Task.isCancelled else { return }
                let b = try EditV2Engine.build(p, sources: self.sources)
                let wasPlaying = self.player.rate != 0
                self.player.replaceCurrentItem(with: EditV2Engine.playerItem(b))
                self.builtProject = p
                self.playhead = min(self.playhead, b.plan.durationSec)
                _ = await self.player.seek(to: CMTime(seconds: self.playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { self.player.play() }
            } catch {
                self.lastError = (error as? ApiError)?.message ?? "Couldn't update the preview (\(error.localizedDescription))"
            }
        }
    }

    private func observeTime() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = t.seconds
                if s.isFinite, self.player.rate != 0 { self.playhead = min(max(0, s), self.duration) }
                let now = self.player.rate != 0
                if self.playing && !now {
                    self.state.playhead = self.playhead
                    self.shuttle = 0
                    self.refreshLookThumbs()
                }
                self.playing = now
            }
        }
    }

    func togglePlay() {
        guard isReady else { return }
        if player.rate != 0 { pause() } else { play(rate: 1) }
    }

    func play(rate: Double) {
        guard isReady else { return }
        if rate > 0, playhead >= duration - 0.05 { seek(0) }
        player.rate = Float(rate)
        shuttle = rate
        playing = player.rate != 0
    }

    func pause() {
        player.pause()
        shuttle = 0
        playing = false
        state.playhead = playhead
    }

    /// J / K / L: back faster, stop, forward faster (1×, 2×, 4×).
    func shuttleStep(_ dir: Int) {

        guard isReady else { return }
        if dir == 0 { pause(); return }
        let cur = shuttle
        var next: Double
        if dir > 0 { next = cur <= 0 ? 1 : min(4, cur * 2) } else { next = cur >= 0 ? -1 : max(-4, cur * 2) }
        if next < 0, player.currentItem?.canPlayReverse != true {
            // This item can't play backwards: step back instead.
            pause()
            seek(playhead - 0.5)
            return
        }
        play(rate: next)
        shuttle = next
    }

    func seek(_ t: Double) {
        let v = min(max(0, t), duration)
        playhead = v
        state.playhead = v
        player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seeks and selects what's there (a click on a row, or the main clip).
    func scrub(to t: Double, trackId: String? = nil) {
        seek(t)
        state.select(at: t, trackId: trackId)
    }

    func step(_ dir: Int) {
        guard isReady else { return }
        pause()
        seek(playhead + Double(dir) / max(1, project.canvas.fps))
    }

    /// Writes the edit's frame at timeline `t` (the preview's render: looks, text, captions) as a PNG. Nil on success, else why.
    func saveFrame(at t: Double, to url: URL) async -> String? {
        guard let item = player.currentItem else { return "The preview isn't ready yet" }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        do {
            let cg = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return "Couldn't make the picture" }
            try data.write(to: url)
            return nil
        } catch {
            return "Couldn't save the frame (\(error.localizedDescription))"
        }
    }

    // MARK: Media (strips, waveforms, Looks thumbnails)

    private func refreshMedia() {
        for a in project.assets where files[a.id] != nil {
            let url = files[a.id]!
            if a.kind == .video, strips[a.id] == nil {
                strips[a.id] = []
                Task { [weak self] in
                    let s = await EditSuiteMedia.strip(url, count: 24)
                    self?.strips[a.id] = s
                }
            }
            if a.kind == .audio || (a.kind == .video && a.hasAudio != false), waves[a.id] == nil {
                waves[a.id] = []
                Task { [weak self] in
                    let w = await EditSuiteMedia.waveform(url)
                    self?.waves[a.id] = w
                }
            }
        }
    }

    /// The selected (or current) video clip's frame at the playhead, and every bundled look drawn on it.
    func refreshLookThumbs() {
        thumbTask?.cancel()
        let p = project
        let t = playhead
        let clip = state.selectedVideo ?? p.mainClip(at: t).map { p.mainClips[$0.index] }
        guard let clip, let url = files[clip.asset] else { return }
        let local: Double
        if let loc = p.locate(clip.id), p.tracks[loc.track].kind == .main, let span = E.timeline(p).first(where: { $0.id == clip.id }) {
            local = max(0, t - span.startSec)
        } else {
            local = max(0, t - (clip.startSec ?? 0))
        }
        let src = E.clipSourceAt(clip, local)
        let matrix = E.colorMatrix(E.adjustAt(clip.adjust, clip.keyframes, local), clip.filter)
        thumbTask = Task { [weak self] in
            guard let frame = await EditSuiteMedia.frame(url, at: src, maxSide: 360), !Task.isCancelled else { return }
            let tiles = await EditV2LookThumbnails.render(frame: frame, matrix: E.isIdentity(matrix) ? nil : matrix, shortSide: 96)
            guard !Task.isCancelled, let self else { return }
            self.lookFrame = frame
            self.lookThumbs = tiles
        }
    }

    // MARK: Bin

    /// A take from the bin: at the end of the main track, or as an overlay at the playhead.
    func addTake(_ t: Take, overlay: Bool = false) {
        guard let d = t.durationSec, d > 0 else { lastError = "That take has no video yet"; return }
        let id = project.newId("t")
        let a = E.Asset(id: id, kind: .video, take: t.id, durationSec: d, width: t.width, height: t.height, hasAudio: true, url: t.videoUrl)
        state.assetNames[id] = t.title.isEmpty ? "Take" : t.displayTitle
        edit { $0.addVideo(a, overlay: overlay) }
    }

    /// A take as an asset of this edit (named after it).
    private func takeAsset(_ t: Take) -> E.Asset? {
        guard let d = t.durationSec, d > 0 else { lastError = "That take has no video yet"; return nil }
        let id = project.newId("t")
        state.assetNames[id] = t.title.isEmpty ? "Take" : t.displayTitle
        return E.Asset(id: id, kind: .video, take: t.id, durationSec: d, width: t.width, height: t.height, hasAudio: true, url: t.videoUrl)
    }

    /// Parity: another take's sound at the playhead (sound effects row).
    func addTakeSound(_ t: Take) {
        guard let a = takeAsset(t) else { return }
        if edit({ $0.addTakeSound(a) }) { notice = "Sound added · on the sound effects row" }
    }

    /// Parity: the selected (or current) main clip plays this take instead, keeping its edits.
    func replaceClip(with t: Take) {
        guard let a = takeAsset(t) else { return }
        if edit({ $0.replaceClip(with: a) }) { notice = "Clip replaced · its edits stay" }
    }

    /// Music / voice-over / sound effect from a file on this Mac: uploaded (editor upload), then added to its row.
    func importAudio(_ url: URL, kind: E.TrackKind, at: Double? = nil, trimStart: Double = 0) async {
        guard isReady else { return }
        do {
            let asset = AVURLAsset(url: url)
            let d = try await asset.load(.duration).seconds
            guard d.isFinite, d >= E.minClipSourceSec else { throw ApiError("bad_media", "That file has no sound to use") }
            notice = "Uploading \(url.lastPathComponent)…"
            let up = try await api.uploadEditorFile(url, contentType: Self.contentType(url), purpose: nil, progress: nil)
            let id = project.newId("a")
            let a = E.Asset(id: id, kind: .audio, upload: up, durationSec: (d * 1000).rounded() / 1000, hasAudio: true)
            files[id] = url
            state.assetNames[id] = url.deletingPathExtension().lastPathComponent
            notice = nil
            edit { $0.addAudio(a, kind: kind, at: at, trimStart: trimStart) }
        } catch {
            notice = nil
            lastError = (error as? ApiError)?.message ?? "Couldn't add that file"
        }
    }

    /// A video or picture from this Mac (Uploads / Stickers): uploaded as an editor upload, then added like a take (a video at
    /// the end of the main track, or as an overlay at the playhead) or as a picture at the playhead (Mac Edit audit: the
    /// Uploads tab could only take sounds, and pictures had no way in).
    func importMedia(_ url: URL, overlay: Bool = false) async {
        guard isReady else { return }
        let ext = url.pathExtension.lowercased()
        do {
            if Self.pictureTypes[ext] != nil {
                guard let img = NSImage(contentsOf: url), img.representations.first != nil else { throw ApiError("bad_media", "That picture can't be opened") }
                // Design pass (owner-approved): very large photos go up at 2048 px on the long side (PNGs keep transparency).
                let (file, type, pw, ph) = try Self.pictureForUpload(url, ext: ext)
                notice = "Uploading \(url.lastPathComponent)…"
                let up = try await api.uploadEditorFile(file, contentType: type, purpose: nil, progress: nil)
                let id = project.newId("p")
                let a = E.Asset(id: id, kind: .image, upload: up, width: pw, height: ph)
                files[id] = file
                state.assetNames[id] = url.deletingPathExtension().lastPathComponent
                notice = nil
                // Selected, with the Video tab (Transform, blend, keyframes) open so it can be placed straight away.
                if edit({ $0.addImage(a) }) { view { $0.tab = .video } }
                return
            }
            let info = try await VideoEditEngine.info(AVURLAsset(url: url))
            guard info.duration >= E.minClipSourceSec else { throw ApiError("bad_media", "That file has no video to use") }
            notice = "Uploading \(url.lastPathComponent)…"
            let up = try await api.uploadEditorFile(url, contentType: ext == "mov" ? "video/quicktime" : "video/mp4", purpose: nil, progress: nil)
            let id = project.newId("v")
            let audioTracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            let sound = !audioTracks.isEmpty
            let a = E.Asset(id: id, kind: .video, upload: up, durationSec: (info.duration * 1000).rounded(.down) / 1000, width: info.width, height: info.height,
                            hasAudio: sound)
            files[id] = url
            state.assetNames[id] = url.deletingPathExtension().lastPathComponent
            notice = nil
            edit { $0.addVideo(a, overlay: overlay) }
        } catch {
            notice = nil
            lastError = (error as? ApiError)?.message ?? "Couldn't add that file"
        }
    }

    /// Picture types an editor upload takes (server `/v1/editor/uploads/presign`).
    /// The file to upload for a picture: itself, or a copy at 2048 px on the long side when larger (PNG stays PNG, others
    /// become JPEG), upright. Returns the file, its content type and its pixel size.
    static func pictureForUpload(_ url: URL, ext: String) throws -> (URL, String, Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw ApiError("bad_media", "That picture can't be opened") }
        var w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        let maxSide = 2048
        guard max(w, h) > maxSide else { return (url, pictureTypes[ext] ?? "image/jpeg", max(1, w), max(1, h)) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw ApiError("bad_media", "That picture can't be opened") }
        let png = ext == "png"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pic-\(UUID().uuidString).\(png ? "png" : "jpg")")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else {
            throw ApiError("bad_media", "That picture can't be resized")
        }
        CGImageDestinationAddImage(dest, cg, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ApiError("bad_media", "That picture can't be resized") }
        return (out, png ? "image/png" : "image/jpeg", cg.width, cg.height)
    }

    static let pictureTypes: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic", "webp": "image/webp"]

    /// Pictures in this edit (the Stickers tab lists them to add again).
    var pictureAssets: [E.Asset] { project.assets.filter { $0.kind == .image } }

    // MARK: Record VO (Edit suite, workstream 3)

    /// True while a voice-over is being recorded from the Mac's microphone.
    var isRecordingVO = false
    @ObservationIgnored private var voRecorder: AVAudioRecorder?
    /// Where the recording started on the timeline (the take lands there), and the output delay to trim when the video played.
    @ObservationIgnored private var voStart: Double = 0
    @ObservationIgnored private var voTrim: Double = 0
    /// Design pass (owner-approved 2026-11-09): play the video, with the edit's sound, while recording. Remembered once
    /// chosen; until then on only when the sound goes to headphones, Bluetooth or USB, so the microphone doesn't hear it.
    var voPlayback: Bool = (UserDefaults.standard.object(forKey: "edit.voPlayback") as? Bool) ?? EditSuiteMedia.outputIsPrivate {
        didSet { UserDefaults.standard.set(voPlayback, forKey: "edit.voPlayback") }
    }
    /// When recording began (the timeline's red bar grows from voStart by the time since).
    var voStartedAt: Date?
    var voStartSec: Double { voStart }

    /// Starts recording a voice-over (asks for the microphone the first time), or stops and adds it to the voice row.
    @MainActor
    func toggleRecordVO() async {
        if let r = voRecorder {
            r.stop()
            if playing { pause() }
            voRecorder = nil
            isRecordingVO = false
            voStartedAt = nil
            await importAudio(r.url, kind: .voice, at: voStart, trimStart: voTrim)
            return
        }
        guard isReady else { return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else {
            lastError = "MUSE can't use the microphone · allow it in System Settings → Privacy & Security → Microphone"
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vo-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            if playing { pause() }
            // At the very end there's nothing to play over: start from the top (as Play does).
            if voPlayback, playhead >= duration - 0.05 { seek(0) }
            voStart = playhead
            // Over playback: the voice answers what the user hears, which the output plays this late.
            voTrim = voPlayback ? EditSuiteMedia.outputLatencySec : 0
            guard r.record() else { throw ApiError("record_failed", "Couldn't start recording") }
            if voPlayback { play(rate: 1) }
            voRecorder = r
            isRecordingVO = true
            voStartedAt = Date()
        } catch {
            lastError = (error as? ApiError)?.message ?? "Couldn't start recording"
        }
    }

    static func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "m4a", "aac", "mp4": return "audio/mp4"
        case "cube": return "application/octet-stream"
        default: return "audio/mp4"
        }
    }

    // MARK: Looks

    /// Picks a bundled look for the selected video/picture (strength 1, its default effects).
    func applyLook(_ id: String?) {
        let look = id.flatMap { EditV2LookLibrary.shared.packLook($0) }
        edit { s in s.changeVisual { $0.look = look } }
        refreshLookThumbs()
    }

    /// The selected item's bundled look id ("pack:<id>"), if any.
    var selectedLookId: String? {
        guard let l = state.selectedVisual?.look?.lut, l.hasPrefix("pack:") else { return nil }
        return String(l.dropFirst(5))
    }

    /// Imports a .cube: checked here first (the error names the bad line), uploaded, checked by the server, then used as the
    /// selected item's LUT.
    func importCube(_ url: URL) async {
        switch EditV2LookLibrary.importCube(url) {
        case .failure(let e):
            lastError = ".cube: \(e.description)"
        case .success(let cube):
            do {
                notice = "Uploading \(url.lastPathComponent)…"
                let up = try await api.uploadEditorFile(url, contentType: "application/octet-stream", purpose: "lut", progress: nil)
                _ = try await api.validateLut(uploadId: up)
                let id = project.newId("lut")
                files[id] = url
                sources.luts[id] = cube.lut
                notice = nil
                edit { s in
                    guard let sel = s.selection else { return false }
                    return s.apply { p in
                        p.addingAsset(E.Asset(id: id, kind: .lut, upload: up)).updating(sel) { it in
                            switch it {
                            case .video(var c): var l = c.look ?? E.Look(); l.lut = id; l.strength = 1; c.look = l; it = .video(c)
                            case .image(var c): var l = c.look ?? E.Look(); l.lut = id; l.strength = 1; c.look = l; it = .image(c)
                            default: break
                            }
                        }
                    }
                }
            } catch {
                notice = nil
                lastError = (error as? ApiError)?.message ?? "Couldn't use that .cube"
            }
        }
    }

    // MARK: Shape

    /// Changes the canvas shape; each clip is re-framed to keep the faces Vision finds in view.
    func setRatio(_ r: EditSuite.Ratio) async {
        let framing = await EditSuiteMedia.framing(project, files: files)
        edit { $0.setRatio(r, framing: framing) }
    }

    // MARK: AI helpers

    /// The main video's source (the selected main clip's, else the first one's).
    var mainSourceAsset: E.Asset? {
        let c = (state.selectedIsMain ? state.selectedVideo : nil) ?? project.mainClips.first
        return c.flatMap { project.asset($0.asset) }
    }

    func isRunning(_ k: EditorJobKind) -> Bool { jobs[k]?.isRunning == true }

    /// "Free" / "≈ $0.04" for a helper on its source (asked once per kind and source).
    func estimateLabel(_ k: EditorJobKind) -> String? { estimates[k]?.label }

    func loadEstimate(_ k: EditorJobKind, source: EditorSource? = nil, options: EditorJobOptions? = nil) async {
        guard let src = source ?? mainSourceAsset.flatMap({ EditorSource($0) }) else { return }
        if let e = try? await api.editorEstimate(EditorJobRequest(kind: k, source: src, options: options, engineModel: model(k, options))) { estimates[k] = e }
    }

    func refreshFeatures() async {
        if let f = (try? await api.editorFeatures()) ?? nil { features = f }
    }

    private static func helperTitle(_ k: EditorJobKind) -> String {
        switch k {
        case .captions: return "Auto-captions"
        case .matte: return "Remove background"
        case .denoise: return "Noise reduction"
        case .cuts: return "Cut silences"
        case .beats: return "Detect beats"
        case .reverse: return "Reverse"
        case .stabilize: return "Stabilise"
        case .slowmo: return "Smooth slow motion"
        case .translate: return "Translate captions"
        case .separate: return "Split voice and music"
        case .cutout: return "Cut out"
        }
    }

    /// Runs the paid helper the owner just confirmed.
    func confirmPaid() {
        guard let ask = paidAsk else { return }
        paidAsk = nil
        Task { await ask.go() }
    }
    func cancelPaid() { paidAsk = nil }

    /// The guardrails' answers (2026-11-08): shown at the helper's button, and the features asked again.
    private func helperRefused(_ k: EditorJobKind, _ error: Error) -> Bool {
        guard let e = error as? ApiError, e.code == "editor_paid_off" || e.code == "editor_daily_cap" else { return false }
        helperNotes[k] = e.message
        Task { await refreshFeatures() }
        return true
    }

    /// Starts a job, polls it until it ends and hands the result to `apply` (on success). A helper that costs money asks
    /// first (`paidAsk`: its price, Run or Cancel) unless `confirmed` (tap to keep confirms in its own panel).
    /// The owner's model picks for the Edit helpers (OwnerModelPill beside each; members never set one): purpose → model id.
    var helperModels: [EnginePurpose: String] = [:]

    /// The model a helper job asks for (nil = the studio's default).
    private func model(_ k: EditorJobKind, _ options: EditorJobOptions?) -> String? { k.enginePurpose(options).flatMap { helperModels[$0] } }

    private func run(_ k: EditorJobKind, source: EditorSource, options: EditorJobOptions? = nil, confirmed: Bool = false,
                     apply: @escaping (EditorJobResult) -> Void) async {
        guard !isRunning(k) else { return }
        helperNotes[k] = nil
        if !confirmed {
            do {
                let e = try await api.editorEstimate(EditorJobRequest(kind: k, source: source, options: options, engineModel: model(k, options)))
                if !e.free && e.usd > 0 {
                    paidAsk = PaidAsk(kind: k, title: Self.helperTitle(k), price: e.label) { [weak self] in
                        await self?.run(k, source: source, options: options, confirmed: true, apply: apply)
                    }
                    return
                }
            } catch {
                if helperRefused(k, error) { return }
                lastError = (error as? ApiError)?.message ?? "That didn't work · try again"
                return
            }
        }
        do {
            var job = try await api.startEditorJob(EditorJobRequest(kind: k, source: source, options: options, engineModel: model(k, options)))
            jobs[k] = job
            while job.isRunning {
                try await Task.sleep(nanoseconds: 700_000_000)
                job = try await api.editorJob(id: job.id)
                jobs[k] = job
            }
            if job.isDone, let r = job.result {
                if k == .captions { transcriptJobId = job.id }
                if k == .captions || k == .translate { captionExportNotice = r.exportNotice }
                apply(r)
            } else if job.state == "failed" {
                lastError = job.error ?? "That didn't work · try again"
            }
        } catch {
            if var j = jobs[k], j.isRunning {
                j.state = "failed"
                jobs[k] = j
            }
            if helperRefused(k, error) { return }
            if !(error is CancellationError) { lastError = (error as? ApiError)?.message ?? "That didn't work · try again" }
        }
    }

    func cancelJob(_ k: EditorJobKind) {
        guard let j = jobs[k], j.isRunning else { return }
        Task { try? await api.cancelEditorJob(id: j.id) }
    }

    /// Auto-captions: word-timed transcript of the main video → the caption track (current style, Word pop by default).
    func autoCaptions(language: String = "auto") async {
        guard let a = mainSourceAsset, let src = EditorSource(a) else { lastError = "Captions need the video's source take"; return }
        await run(.captions, source: src, options: EditorJobOptions(language: language)) { [weak self] r in
            guard let self, let words = r.words, !words.isEmpty else { self?.lastError = "No speech found"; return }
            self.edit { $0.setCaptions(words: words, assetId: a.id) }
            self.notice = "Captions added · \(words.count) words"
        }
    }

    /// Lyric captions (WS8 54f4b17): the song on the music track (an upload), as captions that follow its clips.
    var songAsset: E.Asset? {
        for t in project.tracks where t.kind == .music {
            for case .audio(let c) in t.items {
                if let a = project.asset(c.asset), a.upload != nil { return a }
            }
        }
        return nil
    }

    func captionsFromSong() async {
        guard let a = songAsset, let src = EditorSource(a) else { lastError = "Add a song from this Mac to the music row first"; return }
        await run(.captions, source: src, options: EditorJobOptions(language: "auto")) { [weak self] r in
            guard let self, let words = r.words, !words.isEmpty else { self?.lastError = "No words found in the song"; return }
            self.edit { $0.setCaptions(words: words, assetId: a.id) }
            self.notice = "Lyrics added · \(words.count) words, following the song's clips"
        }
    }

    /// Cut silences: the free silence-only pass first (no transcript needed); filler words come from the transcript.
    func cutSilences() async {
        if project.captionTrack != nil {
            let cuts = state.silenceCuts()
            if let asset = project.captionTrack?.asset, !cuts.isEmpty {
                edit { $0.applyCuts(cuts, assetId: asset) }
                notice = "Cut \(cuts.count) silence\(cuts.count == 1 ? "" : "s")"
                return
            }
        }
        guard let a = mainSourceAsset, let src = EditorSource(a) else { return }
        await run(.cuts, source: src, options: EditorJobOptions(silenceOnly: true)) { [weak self] r in
            guard let self else { return }
            let cuts = (r.cuts ?? []).filter { $0.reason == .silence }.map(\.range)
            if cuts.isEmpty { self.notice = "No long silences found"; return }
            self.edit { $0.applyCuts(cuts, assetId: a.id) }
            self.notice = "Cut \(cuts.count) silence\(cuts.count == 1 ? "" : "s")"
        }
    }

    /// Remove filler words (um, uh…) found in the transcript. Free.
    func removeFillers() {
        guard let asset = project.captionTrack?.asset else { return }
        let cuts = state.fillerCuts
        guard !cuts.isEmpty else { notice = "No filler words left"; return }
        edit { $0.applyCuts(cuts, assetId: asset) }
        notice = "Removed \(cuts.count) filler\(cuts.count == 1 ? "" : "s")"
    }

    /// Whether the selected clip's background is removed (an alpha matte, or an older green cut-out).
    var backgroundRemoved: Bool {
        guard let c = state.selectedVideo else { return false }
        return c.alphaMatte != nil || (c.chroma != nil && matteOriginal[c.id] != nil) || (c.chroma != nil && c.audioAsset != nil)
    }

    /// Remove background on the selected clip: the person, as an alpha matte on the clip (2026-11-08 contract); off takes
    /// it away (and puts an older cut-out's original picture back).
    /// Reverse (contract, WS8 cb5413e): the selected clip plays a reversed copy of its source, made once by the server
    /// (free, up to 60 s) and kept in the edit; toggling back switches to the original at once. Background removal and a
    /// separate sound are aligned to the original's frames, so they're dropped (and the notice says so).
    func toggleReverse() async {
        guard let c = state.selectedVideo else { lastError = "Select a clip to reverse"; return }
        if let last = state.blockingStep(for: "reverse") { lastError = "Turn off \(EditSuiteState.stepName(last)) first"; return }
        if let orig = state.reversedFrom, let a = project.asset(orig) { switchReverse(to: a); return }
        if let copy = state.reversedCopy(of: c.asset) { switchReverse(to: copy); return }
        guard c.holdSec == nil else { lastError = "A freeze frame has nothing to reverse"; return }
        guard let a = project.asset(c.asset), let src = EditorSource(a) else { lastError = "Reverse needs a take or an upload"; return }
        await run(.reverse, source: src) { [weak self] r in
            Task { @MainActor in await self?.addReversed(r, of: a) }
        }
    }

    private func addReversed(_ r: EditorJobResult, of a: E.Asset) async {
        guard let ra = r.asset, ra.upload != nil || ra.take != nil else { lastError = "Couldn't reverse this clip"; return }
        let id = project.newId("v")
        var copy = E.Asset(id: id, kind: .video, take: ra.upload == nil ? ra.take : nil, upload: ra.upload, durationSec: ra.durationSec ?? r.durationSec ?? a.durationSec,
                           width: r.width ?? a.width, height: r.height ?? a.height, hasAudio: r.hasAudio ?? a.hasAudio, url: ra.url)
        copy.reverseOf = a.id
        let link = ra.url ?? ra.take.flatMap { lookupTake($0)?.videoUrl }
        if let link, let u = URL(string: link), let local = try? await EditSuiteMedia.localCopy(u, key: ra.upload ?? ra.take ?? id) { files[id] = local }
        else if ra.upload == a.upload, ra.take == a.take { files[id] = files[a.id] }   // the fake hands back the source itself
        state.assetNames[id] = "Reversed"
        switchReverse(to: copy)
    }

    private func switchReverse(to target: E.Asset) {
        var dropped: [String]?
        edit { s in dropped = s.reverseSelected(to: target); return dropped != nil }
        guard let dropped else { return }
        let backwards = target.reverseOf != nil
        if dropped.isEmpty { notice = backwards ? "Plays backwards" : "Plays forwards again" }
        else { notice = "\(backwards ? "Plays backwards" : "Plays forwards again") · \(dropped.joined(separator: " and ")) turned off (run it again on this clip)" }
    }

    /// Stabilise (XL, WS16's free job, WS8's derivedFrom): the selected clip plays a steadied copy of its source, made once
    /// by the server (up to 3 minutes) and kept in the edit; toggling back switches to the original at once. Only the last
    /// helper step switches off. The steadied frames move, so background removal is dropped (the notice says so).
    func toggleStabilize() async {
        guard let c = state.selectedVideo else { lastError = "Select a clip to steady"; return }
        if let last = state.blockingStep(for: "stabilize") { lastError = "Turn off \(EditSuiteState.stepName(last)) first"; return }
        if let orig = state.steadiedFrom, let a = project.asset(orig) { switchStabilize(to: a); return }
        if let copy = state.steadiedCopy(of: c.asset) { switchStabilize(to: copy); return }
        guard let a = project.asset(c.asset), let src = EditorSource(a) else { lastError = "Stabilise needs a take or an upload"; return }
        if let max = features?.stabilize?.maxSec, let d = a.durationSec, d > max + 0.01 {
            lastError = "Stabilise works on videos up to \(Int(max / 60)) minutes"; return
        }
        await run(.stabilize, source: src) { [weak self] r in
            Task { @MainActor in await self?.addSteadied(r, of: a) }
        }
    }

    private func addSteadied(_ r: EditorJobResult, of a: E.Asset) async {
        guard let ra = r.asset, ra.upload != nil || ra.take != nil else { lastError = "Couldn't steady this clip"; return }
        let id = project.newId("v")
        var copy = E.Asset(id: id, kind: .video, take: ra.upload == nil ? ra.take : nil, upload: ra.upload, durationSec: ra.durationSec ?? r.durationSec ?? a.durationSec,
                           width: r.width ?? a.width, height: r.height ?? a.height, hasAudio: r.hasAudio ?? a.hasAudio, url: ra.url)
        copy.derivedFrom = E.DerivedFrom(asset: a.id, op: .stabilize)
        let link = ra.url ?? ra.take.flatMap { lookupTake($0)?.videoUrl }
        if let link, let u = URL(string: link), let local = try? await EditSuiteMedia.localCopy(u, key: ra.upload ?? ra.take ?? id) { files[id] = local }
        else if ra.upload == a.upload, ra.take == a.take { files[id] = files[a.id] }   // the fake hands back the source itself
        state.assetNames[id] = "Steadied"
        switchStabilize(to: copy)
    }

    private func switchStabilize(to target: E.Asset) {
        var dropped: [String]?
        edit { s in dropped = s.stabilizeSelected(to: target); return dropped != nil }
        guard let dropped else { return }
        let on = target.derivedFrom?.kind == .stabilize
        notice = (on ? "Steadied" : "Stabilise off") + (dropped.isEmpty ? "" : " · \(dropped.joined(separator: " and ")) turned off (run it again on this clip)")
    }

    // MARK: Translated captions (XL): the caption lines as shown, in another language, timed by the server (paid)

    var translateTarget = "es"
    var translateQuality = "standard"
    /// The server's note about exporting these captions (WS16: a script its export can't draw yet), shown with them.
    var captionExportNotice: String?

    /// The languages to offer (the server's, by name), or a short list when it doesn't say.
    var translateLanguages: [(code: String, name: String)] {
        // The server's list (only scripts its export draws, WS16 0cfa277e); a short safe list when it doesn't say.
        let l = features?.translate?.languages ?? ["es": "Spanish", "fr": "French", "de": "German", "pt-BR": "Portuguese (Brazil)", "it": "Italian",
                                                   "ru": "Russian", "en": "English"]
        return l.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    func translateCaptions() async {
        guard let ct = project.captionTrack else { lastError = "Make captions first"; return }
        guard let a = project.asset(ct.asset), let src = EditorSource(a) else { lastError = "Translate needs captions from a take or an upload"; return }
        let lines = state.captionLinesToTranslate
        guard !lines.isEmpty else { lastError = "There are no caption words to translate"; return }
        let target = translateTarget
        var o = EditorJobOptions()
        o.targetLanguage = target
        o.sourceLanguage = ct.original?.language ?? ct.language
        o.quality = translateQuality
        o.lines = lines
        await run(.translate, source: src, options: o) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard let words = r.words, !words.isEmpty else { self.lastError = "The translation came back empty · try again"; return }
                if self.edit({ $0.setCaptionTranslation(language: r.language ?? target, words: words, sourceLanguage: r.sourceLanguage) }) {
                    let name = self.translateLanguages.first { $0.code == (r.language ?? target) }?.name ?? (r.language ?? target)
                    let kept = (r.untranslatedLines ?? 0) > 0 ? " · \(r.untranslatedLines!) lines kept as they were" : ""
                    self.notice = "Captions in \(name)\(kept)"
                }
            }
        }
    }

    // MARK: Smooth slow motion (XL): a range of the clip, 2× or 4× slower with new frames in between

    /// 2 or 4, and the length of the range from the playhead (seconds of source).
    var slowmoFactor: Double = 4
    var slowmoLength: Double = 2
    /// 0…1 while this Mac makes the slowed copy itself; nil otherwise.
    var slowmoLocalProgress: Double?
    /// Whether this Mac makes the copy itself (free) rather than the paid server job.
    var slowmoOnDevice: Bool { EditV2SlowmoLocal.available }

    /// The selected main clip from the playhead, `slowmoLength` long, slowed `slowmoFactor`×: the copy is made once (the
    /// paid server job, its price confirmed first) and reused; the clip is split around it with the shared applySlowmo,
    /// the slowed piece muted and selected.
    func smoothSlowmo() async {
        guard let c = state.selectedVideo else { lastError = "Select a clip to slow down"; return }
        guard let r = state.slowmoRange(lengthSec: slowmoLength) else {
            lastError = "Smooth slow motion works on a main clip at one speed, at least 0.3 s long"; return
        }
        let factor = slowmoFactor
        if let copy = state.slowmoCopy(of: c.asset, startSec: r.startSec, endSec: r.endSec, factor: factor) { applySlowmo(copy); return }
        guard let a = project.asset(c.asset), let src = EditorSource(a) else { lastError = "Smooth slow motion needs a take or an upload"; return }
        // On this Mac first (macOS 15.4+, free): Apple's frame interpolation, uploaded so the render and other devices have it.
        if EditV2SlowmoLocal.available, #available(macOS 15.4, *), let file = files[a.id], slowmoLocalProgress == nil {
            slowmoLocalProgress = 0
            defer { slowmoLocalProgress = nil }
            do {
                let made = try await EditV2SlowmoLocal.make(file, startSec: r.startSec, endSec: r.endSec, factor: Int(factor)) { [weak self] v in
                    self?.slowmoLocalProgress = v
                }
                notice = "Uploading the slowed clip…"
                let up = try await api.uploadEditorFile(made.file, contentType: "video/mp4", purpose: nil, progress: nil)
                notice = nil
                let id = project.newId("v")
                var copy = E.Asset(id: id, kind: .video, upload: up, durationSec: made.durationSec, width: made.width, height: made.height, hasAudio: false)
                copy.derivedFrom = E.DerivedFrom(asset: a.id, op: .slowmo, startSec: r.startSec, endSec: r.endSec, factor: factor)
                files[id] = made.file
                state.assetNames[id] = "Smooth \(Int(factor))×"
                applySlowmo(copy)
                return
            } catch is CancellationError {
                return
            } catch {
                notice = nil   // falls through to the server job
            }
        }
        var o = EditorJobOptions()
        o.factor = factor; o.startSec = r.startSec; o.endSec = r.endSec
        await run(.slowmo, source: src, options: o) { [weak self] res in
            Task { @MainActor in await self?.addSlowmo(res, of: a, startSec: r.startSec, endSec: r.endSec, factor: factor) }
        }
    }

    private func addSlowmo(_ r: EditorJobResult, of a: E.Asset, startSec: Double, endSec: Double, factor: Double) async {
        guard let ra = r.asset, ra.upload != nil || ra.take != nil else { lastError = "Couldn't slow this clip down"; return }
        let id = project.newId("v")
        let len = ra.durationSec ?? r.durationSec ?? ((endSec - startSec) * factor * 1e6).rounded() / 1e6
        var copy = E.Asset(id: id, kind: .video, take: ra.upload == nil ? ra.take : nil, upload: ra.upload, durationSec: len,
                           width: r.width ?? a.width, height: r.height ?? a.height, hasAudio: false, url: ra.url)
        copy.derivedFrom = E.DerivedFrom(asset: a.id, op: .slowmo, startSec: r.startSec ?? startSec, endSec: r.endSec ?? endSec, factor: r.factor ?? factor)
        let link = ra.url ?? ra.take.flatMap { lookupTake($0)?.videoUrl }
        if let link, let u = URL(string: link), let local = try? await EditSuiteMedia.localCopy(u, key: ra.upload ?? ra.take ?? id) { files[id] = local }
        else if ra.upload == a.upload, ra.take == a.take { files[id] = files[a.id] }   // the fake hands back the source itself
        state.assetNames[id] = "Smooth \(Int(factor))×"
        applySlowmo(copy)
    }

    private func applySlowmo(_ copy: E.Asset) {
        if edit({ $0.applySlowmoSelected(copy) }) {
            notice = "\(E.derivedLabel(project, copy.id)) · the slowed part is selected and muted"
        }
    }

    // MARK: Split voice and music, cut out a picture (XL helpers, WS16 jobs, WS8 shared ops)

    /// The selected clip's sound split by the server (paid, the price first); the clip is muted and the kept part(s)
    /// land on a voice and / or music track in sync with it.
    func separateSelected(keep: E.SeparationKeep) async {
        guard let c = state.selectedVideo, let a = project.asset(c.asset), let src = EditorSource(a) else { lastError = "Select a video clip with sound"; return }
        guard a.hasAudio != false else { lastError = "This clip has no sound to split"; return }
        await run(.separate, source: src) { [weak self] r in
            Task { @MainActor in await self?.addSeparation(r, clipId: c.id, keep: keep) }
        }
    }

    private func addSeparation(_ r: EditorJobResult, clipId: String, keep: E.SeparationKeep) async {
        guard let v = r.vocals, let i = r.instrumental, v.upload != nil || v.take != nil, i.upload != nil || i.take != nil else {
            lastError = "Couldn't split this clip's sound"; return
        }
        let vid = project.newId("a")
        let iid = vid + "i"
        let vocals = E.Asset(id: vid, kind: .audio, take: v.upload == nil ? v.take : nil, upload: v.upload, durationSec: v.durationSec ?? r.durationSec, hasAudio: true, url: v.url, name: "Voice")
        let instrumental = E.Asset(id: iid, kind: .audio, take: i.upload == nil ? i.take : nil, upload: i.upload, durationSec: i.durationSec ?? r.durationSec, hasAudio: true, url: i.url, name: "Music")
        for (id, part) in [(vid, v), (iid, i)] {
            if let link = part.url ?? part.take.flatMap({ lookupTake($0)?.videoUrl }), let u = URL(string: link),
               let local = try? await EditSuiteMedia.localCopy(u, key: part.upload ?? part.take ?? id) { files[id] = local }
        }
        state.assetNames[vid] = "Voice"; state.assetNames[iid] = "Music"
        view { $0.selection = clipId }
        if edit({ $0.applySeparationSelected(vocals: vocals, instrumental: instrumental, keep: keep) }) {
            notice = keep == .both ? "Voice and music on their own rows · the clip is muted" : keep == .vocals ? "Voice only · the clip is muted" : "Music only · the clip is muted"
        }
    }

    /// The selected picture cut out by the server (paid): the person, or what `points` keep; it stays where the subject sat.
    func cutoutSelected(points: [KeepPoint]? = nil) async {
        guard case .image(let im)? = state.selectedItem, let a = project.asset(im.asset), let src = EditorSource(a) else { lastError = "Select a picture to cut out"; return }
        await run(.cutout, source: src, options: points.map { EditorJobOptions(points: $0) }) { [weak self] r in
            Task { @MainActor in await self?.addCutout(r, itemId: im.id) }
        }
    }

    private func addCutout(_ r: EditorJobResult, itemId: String?) async {
        guard let ra = r.asset, ra.upload != nil || ra.take != nil else { lastError = "Couldn't cut that out"; return }
        let id = project.newId("p")
        let asset = E.Asset(id: id, kind: .image, take: ra.upload == nil ? ra.take : nil, upload: ra.upload, width: ra.width, height: ra.height, url: ra.url)
        if let link = ra.url, let u = URL(string: link), let local = try? await EditSuiteMedia.localCopy(u, key: ra.upload ?? id) { files[id] = local }
        state.assetNames[id] = "Cut-out"
        if let itemId, let box = r.box, let sw = r.sourceWidth, let sh = r.sourceHeight {
            view { $0.selection = itemId }
            if edit({ $0.applyCutoutSelected(asset, box: box, sourceWidth: sw, sourceHeight: sh) }) { notice = "Cut out · it stays where it was" }
        } else if edit({ $0.addImage(asset) }) {
            notice = "Cut-out added at the playhead"
        }
    }

    /// "Cut out a picture…" (Stickers): a picture from this Mac, uploaded (JPEG or PNG), cut out, and added at the playhead.
    func cutoutPicture(_ url: URL) async {
        do {
            let ext = url.pathExtension.lowercased()
            var (file, type, _, _) = try Self.pictureForUpload(url, ext: ext)
            if type == "image/heic" || type == "image/webp" { (file, type) = try Self.jpegCopy(file) }   // the cut-out takes JPEG or PNG
            notice = "Uploading \(url.lastPathComponent)…"
            let up = try await api.uploadEditorFile(file, contentType: type, purpose: nil, progress: nil)
            notice = nil
            await run(.cutout, source: EditorSource(uploadId: up)) { [weak self] r in
                Task { @MainActor in await self?.addCutout(r, itemId: nil) }
            }
        } catch {
            notice = nil
            lastError = (error as? ApiError)?.message ?? "Couldn't cut out that picture"
        }
    }

    /// A JPEG copy of a picture (for helpers that don't take HEIC or WebP).
    static func jpegCopy(_ url: URL) throws -> (URL, String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ApiError("bad_media", "That picture can't be opened")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pic-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ApiError("bad_media", "That picture can't be converted") }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ApiError("bad_media", "That picture can't be converted") }
        return (out, "image/jpeg")
    }

    func setRemoveBackground(_ on: Bool) async {
        guard let c = state.selectedVideo else { return }
        if !on {
            let orig = matteOriginal[c.id]
            edit { s in s.changeVideo { v in
                if v.alphaMatte != nil { v.alphaMatte = nil; return }
                if let orig { v.asset = orig }; v.chroma = nil
            } }
            matteOriginal[c.id] = nil
            return
        }
        guard let a = project.asset(c.asset), let src = EditorSource(a) else { lastError = "Background removal needs a take"; return }
        await run(.matte, source: src) { [weak self] r in self?.applyMatte(r, clip: c, source: a) }
    }

    /// Puts a finished matte job on the clip: an alpha matte (the clip keeps its own picture), or an older green cut-out.
    private func applyMatte(_ r: EditorJobResult, clip c: E.VideoClip, source a: E.Asset) {
        guard let ra = r.asset else { return }
        if r.alpha == true {
            let id = project.newId("bg")
            let asset = E.Asset(id: id, kind: .video, take: ra.take, upload: ra.take == nil ? ra.upload : nil, durationSec: ra.durationSec ?? a.durationSec,
                                width: a.width, height: a.height, hasAudio: false, url: ra.url)
            state.assetNames[id] = "Cut-out of \(state.assetNames[c.asset] ?? "the clip")"
            edit { s in
                s.apply { p in
                    p.addingAsset(asset).updating(c.id) { it in
                        guard case .video(var v) = it else { return }
                        v.alphaMatte = E.AlphaMatte(asset: id)
                        v.chroma = nil
                        it = .video(v)
                    }
                }
            }
            Task { await ensureFiles(); rebuild(immediately: true) }
            notice = r.mode == "tracked" ? "Cut out what you picked" : "Background removed"
            return
        }
        // An older result: the person on green replaces the clip's picture, keyed out with the chroma key.
        let id = project.newId("matte")
        let asset = E.Asset(id: id, kind: .video, take: ra.take, upload: ra.take == nil ? ra.upload : nil, durationSec: ra.durationSec ?? a.durationSec,
                            width: a.width, height: a.height, hasAudio: false, url: ra.url)
        matteOriginal[c.id] = c.asset
        state.assetNames[id] = state.assetNames[c.asset]
        edit { s in
            s.apply { p in
                p.addingAsset(asset).updating(c.id) { it in
                    guard case .video(var v) = it else { return }
                    v.audioAsset = v.audioAsset ?? v.asset
                    v.asset = id
                    v.chroma = r.chroma ?? E.Chroma(color: "#00FF00")
                    it = .video(v)
                }
            }
        }
    }

    // MARK: Pick what to keep (tap to keep)

    /// Starts "Pick what to keep" on the selected clip, on the frame under the playhead (else the clip's first frame).
    func startKeepPick() async {
        guard let c = state.selectedVideo else { return }
        guard let url = files[c.asset] else { lastError = "Pick what to keep needs the clip's video"; return }
        pause()
        let plan = E.renderPlan(project, media: sources.infos)
        let seg = plan.video.first { $0.itemId == c.id && $0.contains(playhead) } ?? plan.video.first { $0.itemId == c.id }
        let sec = seg.map { E.sourceTime($0, at: playhead) } ?? c.inSec
        keepPick = EditSuite.KeepPick(clipId: c.id, assetId: c.asset, sourceSec: sec)
        keepEstimate = nil
        keepFrame = nil
        let frame = await EditSuiteMedia.frame(url, at: sec, maxSide: 720)
        guard keepPick?.clipId == c.id else { return }
        keepFrame = frame
        if frame == nil { lastError = "Couldn't show that frame · move the playhead and try again"; keepPick = nil }
    }

    /// A tap on the frame (0–1 from the top left): adds a point, or removes the one tapped.
    func tapKeep(x: Double, y: Double) {
        guard var k = keepPick else { return }
        let aspect = keepFrame.map { Double($0.width) / Double(max(1, $0.height)) } ?? 1
        guard k.tap(x: x, y: y, aspect: aspect) else {
            if k.points.count >= EditSuite.maxKeepPoints { notice = "Up to \(EditSuite.maxKeepPoints) points" }
            return
        }
        keepPick = k
        keepEstimate = nil
        Task { await loadKeepEstimate() }
    }

    func setKeepLeaveOut(_ on: Bool) { keepPick?.leaveOut = on }

    func clearKeep() { keepPick?.clear(); keepEstimate = nil }

    func cancelKeep() { keepPick = nil; keepFrame = nil; keepEstimate = nil }

    /// The price of cutting out what was picked (asked with the same points the job will get).
    func loadKeepEstimate() async {
        guard let k = keepPick, k.canRun, let a = project.asset(k.assetId), let src = EditorSource(a) else { keepEstimate = nil; return }
        let e = try? await api.editorEstimate(EditorJobRequest(kind: .matte, source: src, options: k.options, engineModel: model(.matte, k.options)))
        if keepPick?.points == k.points { keepEstimate = e }
    }

    /// Shows the price and asks to confirm (nothing runs yet).
    func askKeep() {
        guard keepPick?.canRun == true else { return }
        keepPick?.confirming = true
        if keepEstimate == nil { Task { await loadKeepEstimate() } }
    }

    /// Runs the confirmed cut-out: the picked subject is followed through the clip and comes back as its alpha matte.
    func runKeep() async {
        guard let k = keepPick, k.canRun, k.confirming else { return }
        guard let clip = project.tracks.lazy.compactMap({ $0.item(k.clipId)?.videoClip }).first, let a = project.asset(k.assetId), let src = EditorSource(a) else {
            lastError = "Background removal needs a take"
            return
        }
        keepPick?.confirming = false
        await run(.matte, source: src, options: k.options, confirmed: true) { [weak self] r in
            self?.applyMatte(r, clip: clip, source: a)
            self?.cancelKeep()
        }
    }

    /// Noise reduction on the selected clip: its voice alone becomes the clip's sound; off goes back to the original.
    func setNoiseReduction(_ on: Bool) async {
        guard let c = state.selectedItem else { return }
        if !on {
            // Back to the clip's own sound (or, after Remove background, the original video's).
            let back = matteOriginal[c.id]
            edit { s in s.changeSound { $0.audioAsset = back } }
            return
        }
        let assetId: String
        switch c {
        case .video(let v): assetId = matteOriginal[v.id] ?? v.asset
        case .audio(let v): assetId = v.asset
        default: return
        }
        guard let a = project.asset(assetId), let src = EditorSource(a) else { lastError = "Noise reduction needs a take or an upload"; return }
        await run(.denoise, source: src) { [weak self] r in
            guard let self, let ra = r.asset else { self?.notice = r.suggestion?.reason; return }
            let id = self.project.newId("voice")
            let asset = E.Asset(id: id, kind: .audio, take: ra.take, upload: ra.take == nil ? ra.upload : nil, durationSec: ra.durationSec ?? a.durationSec,
                                hasAudio: true, url: ra.url)
            self.edit { s in
                s.apply { p in
                    p.addingAsset(asset).updating(c.id) { it in
                        if case .video(var v) = it { v.audioAsset = id; it = .video(v) }
                    }
                }
            }
        }
    }

    /// Beat detection (free) on the selected music clip, or the first one.
    func detectBeats() async {
        let music = state.selectedItem?.audioClip ?? state.musicTrack?.items.first?.audioClip
        guard let m = music, let a = project.asset(m.asset), let src = EditorSource(a) else { lastError = "Add music first"; return }
        await run(.beats, source: src) { [weak self] r in
            guard let self else { return }
            self.edit { $0.setBeats(m.id, beats: r.beats ?? [], strong: r.strong ?? []) }
            if let bpm = r.bpm { self.notice = "\(Int(bpm.rounded())) BPM" }
        }
    }

    // MARK: Even out volume (parity)

    /// Measures each main and voice clip's sound over the part that plays (RMS above a −50 dB gate, and the loudest
    /// sample), then evens them out to the median (EditSuiteState.evenVolume).
    func evenVolume() async {
        var levels: [String: (rms: Double, peak: Double)] = [:]
        for t in project.tracks where t.kind == .main || t.kind == .voice {
            for it in t.items {
                let (id, assetId, a, b): (String, String, Double, Double)
                switch it {
                case .video(let c): (id, assetId, a, b) = (c.id, c.audioAsset ?? c.asset, c.inSec, c.outSec)
                case .audio(let c): (id, assetId, a, b) = (c.id, c.asset, c.inSec, c.outSec)
                default: continue
                }
                guard let url = files[assetId], let l = await EditSuiteMedia.level(url, from: a, to: b) else { continue }
                levels[id] = l
            }
        }
        var changed = 0
        edit { s in changed = s.evenVolume(levels: levels); return changed > 0 }
        if changed > 0 { notice = "Evened out \(changed) clip\(changed == 1 ? "" : "s")" }
    }

    // MARK: Key colour from the picture (design pass, owner-approved 2026-11-09)

    /// The selected clip's source frame under the playhead, before its look (the pixels the key compares), while picking.
    struct KeyPickFrame { let width: Int; let height: Int; let rgba: [UInt8] }
    var pickingKeyColour = false
    @ObservationIgnored private(set) var keyPickFrame: KeyPickFrame?

    /// "Pick from video": pauses, reads the clip's source frame at the playhead, then waits for a click on the preview.
    /// Picking again (or Esc) cancels.
    func toggleKeyPick() async {
        if pickingKeyColour { pickingKeyColour = false; keyPickFrame = nil; return }
        guard let c = state.selectedVideo, c.chroma != nil, let url = files[c.asset], let loc = project.locate(c.id) else { return }
        pause()
        let track = project.tracks[loc.track]
        let span = E.itemSpan(project, track, track.items[loc.item])
        let local = min(max(0, playhead - span.startSec), span.endSec - span.startSec)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        guard let cg = try? await gen.image(at: CMTime(seconds: E.clipSourceAt(c, local), preferredTimescale: 600)).image else {
            lastError = "Couldn't read this clip's picture"; return
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        keyPickFrame = KeyPickFrame(width: w, height: h, rgba: px)
        pickingKeyColour = true
    }

    /// The colour under a canvas point (pixels, top-left origin): a 3 × 3 average of the source frame, as #RRGGBB.
    func keyColour(canvasX x: Double, canvasY y: Double) -> String? {
        guard let f = keyPickFrame,
              let p = state.sourcePoint(canvasX: x, canvasY: y, sourceWidth: Double(f.width), sourceHeight: Double(f.height)) else { return nil }
        let cx = min(f.width - 1, max(0, Int(p.u * Double(f.width)))), cy = min(f.height - 1, max(0, Int(p.v * Double(f.height))))
        var sum = [0, 0, 0], n = 0
        for dy in -1...1 { for dx in -1...1 {
            let xx = cx + dx, yy = cy + dy
            guard xx >= 0, yy >= 0, xx < f.width, yy < f.height else { continue }
            let i = (yy * f.width + xx) * 4
            sum[0] += Int(f.rgba[i]); sum[1] += Int(f.rgba[i + 1]); sum[2] += Int(f.rgba[i + 2]); n += 1
        } }
        guard n > 0 else { return nil }
        return String(format: "#%02X%02X%02X", sum[0] / n, sum[1] / n, sum[2] / n)
    }

    /// Sets the key colour from a click on the preview (one undo step) and leaves picking.
    func pickKeyColour(canvasX x: Double, canvasY y: Double) {
        guard let hex = keyColour(canvasX: x, canvasY: y) else { notice = "Click on the clip itself"; return }
        edit { $0.setKeyColour(hex) }
        pickingKeyColour = false
        keyPickFrame = nil
    }

    // MARK: Own fonts (contract, WS8 6ccd9aa)

    /// A .ttf / .otf for the selected text: checked here (sfnt, 10 MB), uploaded, checked by the server (it names it from the
    /// file), added as a font asset and set on the text. The preview draws it at once.
    func importFont(_ url: URL) async {
        guard state.selectedItem?.textItem != nil else { lastError = "Select a text first"; return }
        let ext = url.pathExtension.lowercased()
        guard ext == "ttf" || ext == "otf" else { lastError = "Fonts are .ttf or .otf files"; return }
        guard let data = try? Data(contentsOf: url), data.count <= E.fontMaxBytes else { lastError = "That font is over 10 MB"; return }
        guard E.fontName(data) != nil else { lastError = "That isn't a TrueType or OpenType font (WOFF and .ttc aren't supported)"; return }
        do {
            notice = "Uploading \(url.lastPathComponent)…"
            let up = try await api.uploadEditorFile(url, contentType: ext == "otf" ? "font/otf" : "font/ttf", purpose: "font", progress: nil)
            let check = try await api.checkFont(uploadId: up)
            let id = project.newId("fnt")
            files[id] = url
            EditV2TextRenderer.registerOwnFont(id, file: url)
            notice = nil
            let a = E.Asset(id: id, kind: .font, upload: up, name: check.name)
            if edit({ $0.setTextFont(a) }) { notice = "Using \(check.name)" }
        } catch {
            notice = nil
            lastError = (error as? ApiError)?.message ?? "Couldn't add that font"
        }
    }

    // MARK: Content library (WS8 84df583): stickers, sound effects, fonts and the in-house looks, captions and transitions

    /// The content catalog: nil until loaded, or when this server has none.
    var content: ContentCatalog?
    /// The sound effect being previewed (its ref).
    var previewingSound: String?
    @ObservationIgnored private var contentTask: Task<ContentCatalog?, Never>?
    @ObservationIgnored private var soundPreview: AVAudioPlayer?

    func loadContent() async {
        if content != nil { return }
        let task = contentTask ?? Task { [api] in try? await api.editorContent() }
        contentTask = task
        content = await task.value
        if content == nil { contentTask = nil }   // try again next time
    }

    /// A content file on this Mac (downloaded once per catalog version), or nil when it can't be had.
    func contentFile(_ path: String) async -> URL? {
        guard let c = content else { return nil }
        return try? await api.editorContentFile(path, version: c.version)
    }

    /// A sticker at the playhead on the Stickers row (downloaded first, so the preview has it).
    func addContentSticker(_ pack: ContentPack, _ item: ContentItem) async {
        guard let path = item.file, let url = await contentFile(path) else { lastError = "Couldn't download that sticker · check the connection"; return }
        let ref = ContentCatalog.ref(pack: pack.id, item: item.id)
        if edit({ $0.addContentSticker(pack, item) }) {
            for a in project.assets where a.library == ref { files[a.id] = url }
            rebuild(immediately: true)
            view { $0.tab = .video }
        }
    }

    /// A sound effect at the playhead on the sound effects row.
    func addContentSound(_ pack: ContentPack, _ item: ContentItem) async {
        guard let path = item.file, let url = await contentFile(path) else { lastError = "Couldn't download that sound · check the connection"; return }
        let ref = ContentCatalog.ref(pack: pack.id, item: item.id)
        if edit({ $0.addContentSound(pack, item) }) {
            for a in project.assets where a.library == ref { files[a.id] = url }
            rebuild(immediately: true)
        }
    }

    /// Plays a sound effect once (again: stops it).
    func previewSound(_ pack: ContentPack, _ item: ContentItem) async {
        let ref = ContentCatalog.ref(pack: pack.id, item: item.id)
        soundPreview?.stop()
        if previewingSound == ref { previewingSound = nil; return }
        previewingSound = ref
        guard let path = item.file, let url = await contentFile(path), previewingSound == ref,
              let p = try? AVAudioPlayer(contentsOf: url) else { if previewingSound == ref { previewingSound = nil }; return }
        soundPreview = p
        p.play()
        let len = p.duration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(len + 0.05))
            if self?.previewingSound == ref { self?.previewingSound = nil }
        }
    }

    /// One of the in-house looks on the selected picture (its whole look: LUT, grain, vignette and the rest).
    func applyContentLook(_ look: E.Look) {
        edit { s in s.changeVisual { v in v.look = look } }
    }

    // MARK: Auto reframe (XL, owner-approved): the selected clip follows a face, on this Mac (Vision)

    /// 0…1 while faces are being found in the selected clip; nil otherwise.
    var reframeProgress: Double?
    @ObservationIgnored private var reframeTask: Task<Void, Never>?

    func followFaces() {
        guard reframeProgress == nil, let c = state.selectedVideo, let url = files[c.asset] else { return }
        reframeProgress = 0
        reframeTask = Task { [weak self] in
            let samples = await EditSuiteMedia.faceTrack(url, clip: c) { v in self?.reframeProgress = v }
            guard let self, !Task.isCancelled else { self?.reframeProgress = nil; return }
            self.reframeProgress = nil
            // The clip may have changed meanwhile: only the same clip, unchanged.
            guard self.state.selectedVideo == c else { self.lastError = "The clip changed while finding faces · try again"; return }
            if self.edit({ $0.followFaces(samples) }) { self.notice = "The clip follows the face · \(self.state.selectedVideo?.keyframes?.x?.count ?? 0) keys" }
        }
    }

    func cancelFollowFaces() { reframeTask?.cancel(); reframeTask = nil; reframeProgress = nil }

    // MARK: Style kits (parity, shared kit engine)

    /// The studio's saved style kits (members: their own), newest first; nil until loaded.
    var kits: [EditKit]?

    func loadKits() async {
        do { kits = try await api.editKits() } catch { if kits == nil { kits = [] } }
    }

    /// Saves this edit's look, colour, transition, caption and text styles and background as a kit.
    func saveKit(name: String) async -> Bool {
        let kit = E.kitOf(project)
        guard kit != E.StyleKit() else { lastError = "This edit has no style to save yet · add a look, colour, transition or captions"; return false }
        do {
            let k = try await api.saveEditKit(name: name, kit: kit)
            kits = [k] + (kits ?? [])
            notice = "Saved \u{201C}\(k.name)\u{201D}"
            return true
        } catch let e as E.EditProblem {
            lastError = "This style can't be saved (\(e.message))"
        } catch {
            lastError = (error as? ApiError)?.message ?? "Couldn't save the style · try again"
        }
        return false
    }

    /// Applies a kit to this edit (one undo step).
    func applyKit(_ k: EditKit) {
        if edit({ $0.apply { E.applyKit($0, k.kit) } }) { notice = "Applied \u{201C}\(k.name)\u{201D}" }
        else if lastError == nil { notice = "This edit already has that style" }
    }

    func deleteKit(_ k: EditKit) async {
        do {
            try await api.deleteEditKit(id: k.id)
            kits?.removeAll { $0.id == k.id }
        } catch {
            lastError = (error as? ApiError)?.message ?? "Couldn't delete the style kit · try again"
        }
    }

    // MARK: Auto adjust (parity)

    /// Auto adjust of the selected clip from its own picture under the playhead (the source frame, before its look), as
    /// Android: exposure, contrast, saturation, temperature and tint; highlights and shadows kept.
    func autoAdjust() async {
        let p = project
        guard let c = state.selectedVideo ?? p.mainClip(at: playhead).map({ p.mainClips[$0.index] }) else { lastError = "Select a clip to adjust"; return }
        guard let url = files[c.asset] else { lastError = "This clip's file isn't on this Mac yet"; return }
        guard let loc = p.locate(c.id) else { return }
        let track = p.tracks[loc.track]
        let span = E.itemSpan(p, track, track.items[loc.item])
        let local = min(max(0, playhead - span.startSec), span.endSec - span.startSec)
        guard let rgb = await EditSuiteMedia.frameRGB(url, at: E.clipSourceAt(c, local)) else { lastError = "Couldn't read this clip's picture"; return }
        var changed = false
        edit { s in
            if s.selection != c.id { s.selection = c.id }
            changed = s.autoAdjust(rgb); return changed
        }
        notice = changed ? "Adjusted · fine-tune with the sliders" : "This picture already looks balanced"
    }

    // MARK: Export → upload → new version

    /// Problems that stop an export (shown on the sheet).
    var exportProblem: String? {
        if let p = E.problem(project, paletteIds: EditV2LookLibrary.shared.paletteIds) { return p.message.prefix(1).uppercased() + p.message.dropFirst() }
        return nil
    }

    /// Renders with the sheet's settings (shape, size, fps, codec, captions), uploads and saves the new version. With
    /// `saveFileTo` the .mp4 (and the .srt) are also copied there.
    func export(_ settings: EditSuite.ExportSettings, saveFileTo: URL?, request: EditAppRequest? = nil, onSaved: @escaping (Take) -> Void) {
        guard isReady, !busy, exportProblem == nil else {
            if let request { answerRequest(request, .failed(exportProblem ?? "The Mac is busy · try again in a moment")) }
            return
        }
        // Sound only and GIF (parity): a file on this Mac, nothing saved to the Library.
        if settings.format != .video {
            guard let dest = saveFileTo else { return }
            exportOther(settings, to: dest)
            return
        }
        requestInExport = request
        pause()
        var p = project
        let size = settings.size
        p.canvas.width = size.width
        p.canvas.height = size.height
        p.canvas.fps = Double(settings.fps)
        let files = self.files
        let sourceId = sourceTakeId
        lastError = nil
        exportPhase = .rendering(0)
        exportTask = Task { [weak self] in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit", isDirectory: true)
            let file = dir.appendingPathComponent("edit-\(UUID().uuidString.prefix(8)).mp4")
            do {
                guard let self else { return }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let sources = try await EditV2Engine.load(p, files: files)
                // Captions go out as an .srt only next to a saved file; the Library's video always carries them burnt in
                // (Mac Edit audit: "Save to Library" with .SRT lost the captions).
                let burn = settings.captions == .burnIn || saveFileTo == nil
                let built = try EditV2Engine.build(p, sources: sources, burnCaptions: burn, hdr: settings.hdr)
                let onProgress: @MainActor (Double) -> Void = { [weak self] v in
                    if case .rendering = self?.exportPhase { self?.exportPhase = .rendering(v) }
                }
                if settings.bitrate == .recommended, !settings.hdr {
                    try await EditV2Engine.export(built, to: file, hevc: settings.codec == .hevc, progress: onProgress)
                } else {
                    // A chosen bitrate (parity), or HDR (HEVC Main 10, HLG): reader → writer at the size estimate's rate.
                    try await EditV2Engine.write(built, to: file, hevc: settings.effectiveCodec == .hevc, bitrate: settings.videoBitrate,
                                                 hdr: settings.hdr, progress: onProgress)
                }
                try Task.checkCancellation()
                let video = try await VideoEditEngine.describe(file)
                guard TakeVersionV2Request.accepts(project: p, durationSec: video.durationSec) else {
                    throw ApiError("edit_export_failed", "The exported video came out the wrong length. Try again.")
                }
                if let dest = saveFileTo {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: file, to: dest)
                    if settings.captions == .srt { try EditSuiteMedia.writeSrt(p, nextTo: dest) }
                    self.lastExport = dest
                }
                self.exportPhase = .uploading(0)
                let up = try await self.api.uploadEditedVideo(video, progress: { v in
                    Task { @MainActor [weak self] in
                        if case .uploading = self?.exportPhase { self?.exportPhase = .uploading(v) }
                    }
                })
                // Claude's save request may name the version.
                let t = try await self.api.createTakeVersionV2(takeId: sourceId, .make(up, video: video, edits: p, name: request?.name, aiLabel: settings.labelAI))
                try? FileManager.default.removeItem(at: file)
                self.exportPhase = .idle
                self.savedAt = Date()
                self.state.markSaved()
                self.versionNumber += 1
                self.notice = settings.labelAI ? "Saved · it will carry the AI label when you post" : "Saved as a new version · the original is kept"
                if let r = self.requestInExport { self.answerRequest(r, .done(versionId: t.id)) }
                self.requestInExport = nil
                onSaved(t)
            } catch {
                try? FileManager.default.removeItem(at: file)
                guard let self else { return }
                self.exportPhase = .idle
                if let r = self.requestInExport {
                    self.answerRequest(r, .failed((error as? ApiError)?.message ?? (error is CancellationError ? "The owner cancelled the export" : "Couldn't export the edit")))
                }
                self.requestInExport = nil
                if !(error is CancellationError) && !Task.isCancelled {
                    self.lastError = (error as? ApiError)?.message ?? "Couldn't export the edit"
                }
            }
        }
    }

    /// What the export makes now (the progress card's words).
    private(set) var exportFormat: EditSuite.ExportFormat = .video

    /// Sound only (.m4a) or GIF to a file on this Mac.
    private func exportOther(_ settings: EditSuite.ExportSettings, to dest: URL) {
        pause()
        var p = project
        if settings.format == .gif {
            guard duration <= EditSuite.ExportFormat.gifMaxSec + 0.05 else { lastError = "GIFs are up to 30 s · trim the edit or export a video"; return }
        } else {
            let size = settings.size
            p.canvas.width = size.width
            p.canvas.height = size.height
        }
        let files = self.files
        lastError = nil
        exportFormat = settings.format
        exportPhase = .rendering(0)
        exportTask = Task { [weak self] in
            do {
                let sources = try await EditV2Engine.load(p, files: files)
                let built = try EditV2Engine.build(p, sources: sources, burnCaptions: true)
                let onProgress: @MainActor (Double) -> Void = { [weak self] v in
                    if case .rendering = self?.exportPhase { self?.exportPhase = .rendering(v) }
                }
                if settings.format == .gif {
                    try await EditV2Engine.writeGif(built, to: dest, progress: onProgress)
                } else {
                    try await EditV2Engine.write(built, to: dest, audioOnly: true, progress: onProgress)
                }
                guard let self else { return }
                self.exportPhase = .idle
                self.exportFormat = .video
                self.lastExport = dest
                self.notice = settings.format == .gif ? "Saved the GIF" : "Saved the sound file"
            } catch {
                guard let self else { return }
                self.exportPhase = .idle
                self.exportFormat = .video
                if !(error is CancellationError) && !Task.isCancelled {
                    self.lastError = (error as? ApiError)?.message ?? "Couldn't export the edit"
                }
            }
        }
    }

    func cancelExport() {
        if let r = requestInExport { answerRequest(r, .failed("The owner cancelled the export")) }
        requestInExport = nil
        exportTask?.cancel()
        exportTask = nil
        exportPhase = .idle
        exportFormat = .video
    }

    /// "v3 · saved just now" / "v3 · unsaved changes".
    var saveLine: String {
        let v = "v\(versionNumber)"
        if state.hasUnsavedChanges { return "\(v) · unsaved changes" }
        guard let at = savedAt else { return "\(v) · not exported yet" }
        let s = Date().timeIntervalSince(at)
        return s < 60 ? "\(v) · saved just now" : "\(v) · saved \(Int(s / 60)) min ago"
    }
}
