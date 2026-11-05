import AppKit
import AVFoundation
import MuseCore
import Observation

/// One open editor (plans/video-editor.md): the source video (downloaded to a local file), the edit list with undo / redo,
/// the live preview, the timeline thumbnails and the export. The edit itself is made on this Mac (VideoEditEngine).
@MainActor
@Observable
final class VideoEditorSession {
    enum Phase: Equatable {
        case loading
        case ready
        case exporting(Double)
        case uploading(Double)
        case failed(String)
    }

    /// The take that was opened (a render, or an edited version).
    let take: Take
    /// The take whose video the segments cut (`EditList.sourceTakeId`, the new version's parent).
    let sourceTakeId: String
    private(set) var phase: Phase = .loading
    private(set) var history: EditHistory
    private(set) var info: VideoEditEngine.SourceInfo?
    private(set) var thumbs: [(Double, CGImage)] = []
    var selectedId: String?
    /// Speed and Delete act on every segment when on ("Whole video").
    var wholeVideo = false
    private(set) var playhead: Double = 0
    private(set) var playing = false
    var lastError: String?
    /// The version the last export was saved as.
    var savedTakeId: String?
    let player = AVPlayer()

    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var buildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// The finished export of `exportedList`, kept so a failed upload can be retried without encoding again.
    private var exported: EditedVideo?
    private var exportedList: EditList?

    var list: EditList { history.current }
    var duration: Double { list.duration }
    var selectedIndex: Int? { list.segments.firstIndex { $0.id == selectedId } }
    var selected: EditSegment? { selectedIndex.map { list.segments[$0] } }
    var fps: Double { info?.fps ?? 30 }
    var isReady: Bool { phase == .ready }
    var busy: Bool {
        switch phase {
        case .exporting, .uploading: return true
        default: return false
        }
    }

    init(take: Take, sourceTakeId: String, start: EditList?) {
        self.take = take
        self.sourceTakeId = sourceTakeId
        history = EditHistory(start ?? EditList(sourceTakeId: sourceTakeId, sourceDurationSec: take.durationSec ?? 0))
        player.actionAtItemEnd = .pause
    }

    // MARK: Loading

    /// Downloads the source (cached per take), reads its size, frame rate and length, then the thumbnails.
    func load(source: URL) async {
        phase = .loading
        do {
            let local = try await Self.localCopy(source, key: sourceTakeId)
            let a = AVURLAsset(url: local)
            let i = try await VideoEditEngine.info(a)
            guard i.duration > 0 else { throw ApiError("edit_no_video", "This take has no video to edit") }
            asset = a
            info = i
            // A stored list is fitted to the real file (its reported length can differ a little).
            let start = history.current.fitted(to: i.duration, sourceTakeId: sourceTakeId)
            history = EditHistory(start, original: EditList(sourceTakeId: sourceTakeId, sourceDurationSec: i.duration))
            selectedId = start.segments.first?.id
            phase = .ready
            observeTime()
            rebuild()
            thumbs = await VideoEditEngine.thumbnails(a, duration: i.duration, count: 48, height: 64)
        } catch {
            phase = .failed((error as? ApiError)?.message ?? "Couldn't open this video")
        }
    }

    static func localCopy(_ src: URL, key: String) async throws -> URL {
        if src.isFileURL { return src }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("MUSE-edit", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = key.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension
        let dst = dir.appendingPathComponent("src-\(safe.isEmpty ? "take" : safe)").appendingPathExtension(ext)
        if fm.fileExists(atPath: dst.path) { return dst }
        let tmp: URL
        do {
            tmp = try await URLSession.shared.download(from: src).0
        } catch {
            throw ApiError("download_failed", "Couldn't download the video")
        }
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }

    private func observeTime() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                let s = t.seconds
                if s.isFinite, self.player.rate != 0 { self.playhead = min(max(0, s), self.duration) }
                self.playing = self.player.rate != 0
            }
        }
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        buildTask?.cancel()
        exportTask?.cancel()
    }

    // MARK: Preview

    /// Rebuilds the preview after a change, keeping the playhead where it was (clamped to the new length).
    private func rebuild() {
        guard let asset else { return }
        let l = list
        let at = min(playhead, l.duration)
        playhead = at
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            guard let b = try? await VideoEditEngine.build(l, asset: asset), !Task.isCancelled, let self else { return }
            let wasPlaying = self.player.rate != 0
            self.player.replaceCurrentItem(with: VideoEditEngine.playerItem(b))
            _ = await self.player.seek(to: CMTime(seconds: self.playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { self.player.play() }
        }
    }

    func togglePlay() {
        guard isReady else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if playhead >= duration - 0.05 { seek(0) }
            player.play()
        }
        playing = player.rate != 0
    }

    func seek(_ t: Double) {
        let v = min(max(0, t), duration)
        playhead = v
        player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seeks and selects the segment there (a click on the timeline).
    func scrub(to t: Double) {
        seek(t)
        if let i = list.segmentIndex(at: min(playhead, max(0, duration - 0.0001))) { selectedId = list.segments[i].id }
    }

    /// One source frame back or forward (←/→).
    func step(_ dir: Int) {
        guard isReady else { return }
        player.pause()
        let speed = list.segmentIndex(at: playhead).map { list.segments[$0].speed } ?? 1
        seek(playhead + Double(dir) * speed / fps)
    }

    // MARK: Edits

    private func change(_ f: (inout EditList) -> Bool) {
        guard isReady else { return }
        if history.apply(f) { afterChange() }
    }

    private func afterChange() {
        if selectedId == nil || !list.segments.contains(where: { $0.id == selectedId }) {
            selectedId = list.segmentIndex(at: min(playhead, max(0, duration - 0.0001))).map { list.segments[$0].id }
        }
        rebuild()
    }

    var canSplit: Bool { isReady && list.canSplit(at: playhead) }
    var canDelete: Bool { isReady && list.segments.count > 1 && selectedId != nil && !wholeVideo }

    /// S: splits the segment under the playhead at the playhead, and selects the right half.
    func split() {
        let t = playhead
        let f = fps
        change { $0.split(at: t, fps: f) }
        if let i = list.segmentIndex(at: t) { selectedId = list.segments[i].id }
    }

    /// ⌫: removes the selected segment.
    func deleteSelected() {
        guard canDelete, let id = selectedId else { return }
        let i = selectedIndex ?? 0
        change { $0.delete(id) }
        let next = list.segments[min(i, list.segments.count - 1)]
        selectedId = next.id
        seek(list.outputStarts[min(i, list.segments.count - 1)])
    }

    /// The speed shown: the selected segment's, or the whole video's when they all match.
    var shownSpeed: Double? {
        if wholeVideo || selected == nil {
            let all = Set(list.segments.map(\.speed))
            return all.count == 1 ? all.first : nil
        }
        return selected?.speed
    }

    func setSpeed(_ s: Double) {
        let id = wholeVideo ? nil : selectedId
        change { $0.setSpeed(s, segment: id) }
    }

    func setMuted(_ on: Bool) { change { $0.setMuted(on) } }

    func setSegmentMuted(_ on: Bool) {
        guard let id = selectedId else { return }
        change { $0.setMuted(on, segment: id) }
    }

    func undo() { if isReady, history.undo() { afterChange() } }
    func redo() { if isReady, history.redo() { afterChange() } }
    func reset() {
        guard isReady, history.reset() else { return }
        selectedId = list.segments.first?.id
        afterChange()
    }

    // Trim handles: one undo step per drag; the playhead follows the handle so the frame is shown.
    func beginTrim() { history.begin() }

    func trim(_ id: String, isIn: Bool, to src: Double) {
        var l = list
        let ok = isIn ? l.trimIn(id, to: src, fps: fps) : l.trimOut(id, to: src, fps: fps)
        guard ok else { return }
        history.update(l)
        selectedId = id
        if let i = l.segments.firstIndex(where: { $0.id == id }) {
            let s = l.segments[i]
            let t = l.outputTime(segment: i, source: isIn ? s.inSec : s.outSec)
            playhead = min(t, l.duration)
            player.pause()
        }
    }

    func endTrim() {
        history.end()
        rebuild()
    }

    // MARK: Export → upload → new version

    var exportProblem: String? { list.problem ?? (list.isUnedited ? "Make a change first" : nil) }

    /// Exports (unless this exact list was already exported), then `save` uploads it and creates the version.
    func export(save: @escaping @MainActor (EditedVideo, EditList, @escaping @Sendable (Double) -> Void) async throws -> Void,
                done: @escaping @MainActor () -> Void) {
        guard isReady, let asset, exportProblem == nil else { return }
        player.pause()
        let l = list
        lastError = nil
        phase = .exporting(0)
        exportTask = Task { [weak self] in
            var out: URL?
            do {
                guard let self else { return }
                let video: EditedVideo
                if let e = self.exported, self.exportedList == l {
                    video = e
                } else {
                    let b = try await VideoEditEngine.build(l, asset: asset)
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit", isDirectory: true)
                        .appendingPathComponent("edit-\(UUID().uuidString.prefix(8)).mp4")
                    out = file
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await VideoEditEngine.export(b, to: file) { [weak self] p in
                        if case .exporting = self?.phase { self?.phase = .exporting(p) }
                    }
                    try Task.checkCancellation()
                    video = try await VideoEditEngine.describe(file)
                    if !l.accepts(durationSec: video.durationSec) {
                        throw ApiError("edit_export_failed", "The exported video came out the wrong length. Try again.")
                    }
                    self.exported = video
                    self.exportedList = l
                    out = nil
                }
                try Task.checkCancellation()
                self.phase = .uploading(0)
                try await save(video, l) { p in
                    Task { @MainActor [weak self] in
                        if case .uploading = self?.phase { self?.phase = .uploading(p) }
                    }
                }
                try? FileManager.default.removeItem(at: video.file)
                self.exported = nil
                self.exportedList = nil
                self.phase = .ready
                done()
            } catch {
                // Cancelling deletes the half-made file.
                if let out { try? FileManager.default.removeItem(at: out) }
                guard let self else { return }
                self.phase = .ready
                if !(error is CancellationError) && !Task.isCancelled {
                    self.lastError = (error as? ApiError)?.message ?? "Couldn't save the edit"
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        phase = .ready
    }
}
