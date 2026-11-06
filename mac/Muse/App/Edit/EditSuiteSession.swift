import AVFoundation
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
    var duration: Double { state.duration }
    var isReady: Bool { phase == .ready }
    var busy: Bool { exportPhase != .idle }
    var title: String { take.title.isEmpty ? "Edit" : take.title }

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
            state.markSaved()
            for a in project.assets {
                if a.take == sourceTakeId { files[a.id] = local }
                state.assetNames[a.id] = name(of: a)
            }
            phase = .ready
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
        if let t = a.take, let tk = lookupTake(t) { return tk.title.isEmpty ? "Take" : tk.title }
        if a.kind == .audio { return a.library ?? "Audio" }
        return a.kind.rawValue.capitalized
    }

    /// Downloads every asset file the project needs and doesn't have yet (takes by their video, uploads by their url hint).
    private func ensureFiles() async {
        for a in project.assets where files[a.id] == nil {
            var link: String?
            if let t = a.take { link = lookupTake(t)?.videoUrl }
            if link == nil { link = a.url }
            guard let link, let url = URL(string: link) else { continue }
            if let local = try? await EditSuiteMedia.localCopy(url, key: a.take ?? a.upload ?? a.id) { files[a.id] = local }
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
        let ok = f(&state)
        playhead = state.playhead
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

    /// View-only changes (selection, zoom, tabs, snapping…).
    func view(_ f: (inout EditSuiteState) -> Void) { f(&state) }

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
        if state.apply({ _ in p }) { projectChanged() }
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
                self.lastError = (error as? ApiError)?.message ?? "Couldn't update the preview"
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
        let matrix = E.colorMatrix(clip.adjust, clip.filter)
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
        state.assetNames[id] = t.title.isEmpty ? "Take" : t.title
        edit { $0.addVideo(a, overlay: overlay) }
    }

    /// Music / voice-over / sound effect from a file on this Mac: uploaded (editor upload), then added to its row.
    func importAudio(_ url: URL, kind: E.TrackKind) async {
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
            edit { $0.addAudio(a, kind: kind) }
        } catch {
            notice = nil
            lastError = (error as? ApiError)?.message ?? "Couldn't add that file"
        }
    }

    // MARK: Record VO (Edit suite, workstream 3)

    /// True while a voice-over is being recorded from the Mac's microphone.
    var isRecordingVO = false
    @ObservationIgnored private var voRecorder: AVAudioRecorder?

    /// Starts recording a voice-over (asks for the microphone the first time), or stops and adds it to the voice row.
    @MainActor
    func toggleRecordVO() async {
        if let r = voRecorder {
            r.stop()
            voRecorder = nil
            isRecordingVO = false
            await importAudio(r.url, kind: .voice)
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
            guard r.record() else { throw ApiError("record_failed", "Couldn't start recording") }
            voRecorder = r
            isRecordingVO = true
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
        if let e = try? await api.editorEstimate(EditorJobRequest(kind: k, source: src, options: options)) { estimates[k] = e }
    }

    /// Starts a job, polls it until it ends and hands the result to `apply` (on success).
    private func run(_ k: EditorJobKind, source: EditorSource, options: EditorJobOptions? = nil, apply: @escaping (EditorJobResult) -> Void) async {
        guard !isRunning(k) else { return }
        do {
            var job = try await api.startEditorJob(EditorJobRequest(kind: k, source: source, options: options))
            jobs[k] = job
            while job.isRunning {
                try await Task.sleep(nanoseconds: 700_000_000)
                job = try await api.editorJob(id: job.id)
                jobs[k] = job
            }
            if job.isDone, let r = job.result {
                if k == .captions { transcriptJobId = job.id }
                apply(r)
            } else if job.state == "failed" {
                lastError = job.error ?? "That didn't work · try again"
            }
        } catch {
            if var j = jobs[k], j.isRunning {
                j.state = "failed"
                jobs[k] = j
            }
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

    /// Remove background on the selected clip: its cut-out (person on green) replaces the clip's picture with the chroma
    /// key; off puts the original back.
    func setRemoveBackground(_ on: Bool) async {
        guard let c = state.selectedVideo else { return }
        if !on {
            let orig = matteOriginal[c.id]
            edit { s in s.changeVideo { v in if let orig { v.asset = orig }; v.chroma = nil } }
            matteOriginal[c.id] = nil
            return
        }
        guard let a = project.asset(c.asset), let src = EditorSource(a) else { lastError = "Background removal needs a take"; return }
        await run(.matte, source: src) { [weak self] r in
            guard let self, let ra = r.asset else { return }
            let id = self.project.newId("matte")
            let asset = E.Asset(id: id, kind: .video, take: ra.take, upload: ra.take == nil ? ra.upload : nil, durationSec: ra.durationSec ?? a.durationSec,
                                width: a.width, height: a.height, hasAudio: false, url: ra.url)
            self.matteOriginal[c.id] = c.asset
            self.state.assetNames[id] = self.state.assetNames[c.asset]
            self.edit { s in
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
                let built = try EditV2Engine.build(p, sources: sources, burnCaptions: settings.captions == .burnIn)
                try await EditV2Engine.export(built, to: file, hevc: settings.codec == .hevc) { [weak self] v in
                    if case .rendering = self?.exportPhase { self?.exportPhase = .rendering(v) }
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
                let t = try await self.api.createTakeVersionV2(takeId: sourceId, .make(up, video: video, edits: p))
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

    func cancelExport() {
        if let r = requestInExport { answerRequest(r, .failed("The owner cancelled the export")) }
        requestInExport = nil
        exportTask?.cancel()
        exportTask = nil
        exportPhase = .idle
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
