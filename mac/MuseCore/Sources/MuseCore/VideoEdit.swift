import Foundation

// The on-device video editor's edit list and its math (plans/video-editor.md, plans/api.md "Video editor: edited versions
// of a take"). Trim + Split + Speed + Mute. The Mac renders it with AVFoundation; the server only stores it.

/// One kept piece of the source video, in source seconds, played at `speed`. `id` is local (selection, undo); it isn't sent.
public struct EditSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var inSec: Double
    public var outSec: Double
    /// One of `EditList.speeds`.
    public var speed: Double
    public var muted: Bool

    public init(id: String = EditList.newId(), inSec: Double, outSec: Double, speed: Double = 1, muted: Bool = false) {
        self.id = id
        self.inSec = inSec
        self.outSec = outSec
        self.speed = speed
        self.muted = muted
    }

    enum CodingKeys: String, CodingKey { case inSec, outSec, speed, muted }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = EditList.newId()
        inSec = c.v(.inSec, 0)
        outSec = c.v(.outSec, 0)
        speed = c.v(.speed, 1)
        muted = c.v(.muted, false)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(inSec, forKey: .inSec)
        try c.encode(outSec, forKey: .outSec)
        try c.encode(speed, forKey: .speed)
        if muted { try c.encode(true, forKey: .muted) }
    }

    /// Ids are local, so two segments are the same when their cut is.
    public static func == (a: EditSegment, b: EditSegment) -> Bool {
        a.inSec == b.inSec && a.outSec == b.outSec && a.speed == b.speed && a.muted == b.muted
    }
    public func hash(into h: inout Hasher) {
        h.combine(inSec)
        h.combine(outSec)
        h.combine(speed)
        h.combine(muted)
    }

    /// Source seconds this segment covers.
    public var sourceLength: Double { max(0, outSec - inSec) }
    /// Seconds it lasts in the edit.
    public var outputLength: Double { sourceLength / (speed > 0 ? speed : 1) }
}

/// The edit list (`EditList` in the contract): the kept segments in source order, plus whole-video mute.
public struct EditList: Codable, Hashable, Sendable {
    public static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// The shortest segment a split or trim leaves, and how close to an edge a split may be (source seconds).
    public static let minSegment: Double = 0.1
    public static let maxSegments = 50
    /// Output length limits.
    public static let minOutput: Double = 0.5
    public static let maxOutput: Double = 600
    /// Slack the server allows past the source's length.
    public static let endSlack: Double = 0.05
    public static let maxJSONBytes = 16 * 1024

    public var version: Int
    /// The take whose video the segments cut (the version's `parentTakeId`).
    public var sourceTakeId: String
    public var sourceDurationSec: Double
    public var segments: [EditSegment]
    /// Whole video silent.
    public var mute: Bool

    /// The untouched source: one segment over the whole video at 1× with sound.
    public init(sourceTakeId: String, sourceDurationSec: Double, segments: [EditSegment]? = nil, mute: Bool = false) {
        version = 1
        self.sourceTakeId = sourceTakeId
        self.sourceDurationSec = max(0, sourceDurationSec)
        self.segments = segments ?? [EditSegment(inSec: 0, outSec: max(0, sourceDurationSec))]
        self.mute = mute
    }

    enum CodingKeys: String, CodingKey { case version, sourceTakeId, sourceDurationSec, segments, mute }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = c.v(.version, 1)
        sourceTakeId = c.v(.sourceTakeId, "")
        sourceDurationSec = c.v(.sourceDurationSec, 0)
        segments = c.v(.segments, [])
        mute = c.v(.mute, false)
    }

    public static func newId() -> String { "s" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)) }

    // MARK: Duration math

    /// Seconds the edited video lasts: Σ (out − in) / speed.
    public var duration: Double { segments.reduce(0) { $0 + $1.outputLength } }

    /// Where each segment starts in the edit.
    public var outputStarts: [Double] {
        var t = 0.0
        return segments.map { s in defer { t += s.outputLength }; return t }
    }

    /// The trim: the first segment's in point and the last one's out point.
    public var trimIn: Double { segments.first?.inSec ?? 0 }
    public var trimOut: Double { segments.last?.outSec ?? sourceDurationSec }

    /// Nothing changed from the source.
    public var isUnedited: Bool {
        guard !mute, segments.count == 1, let s = segments[safe: 0] else { return false }
        return s.inSec <= 0.0005 && abs(s.outSec - sourceDurationSec) <= 0.0005 && s.speed == 1 && !s.muted
    }

    /// A segment is silent when the whole video or that segment is muted.
    public func isSilent(_ i: Int) -> Bool { mute || (segments[safe: i]?.muted ?? true) }

    /// The segment playing at edit time `t` (the last one at or past the end), nil when empty.
    public func segmentIndex(at t: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        var acc = 0.0
        for (i, s) in segments.enumerated() {
            acc += s.outputLength
            if t < acc - 1e-9 { return i }
        }
        return segments.count - 1
    }

    /// The source time shown at edit time `t`.
    public func sourceTime(at t: Double) -> Double? {
        guard let i = segmentIndex(at: t) else { return nil }
        let s = segments[i]
        let local = min(max(0, t - outputStarts[i]), s.outputLength)
        return min(s.outSec, s.inSec + local * s.speed)
    }

    /// The edit time where source time `src` of segment `index` plays.
    public func outputTime(segment index: Int, source src: Double) -> Double {
        guard segments.indices.contains(index) else { return 0 }
        let s = segments[index]
        return outputStarts[index] + (min(max(src, s.inSec), s.outSec) - s.inSec) / s.speed
    }

    // MARK: Operations (each returns false and leaves the list as it was when it can't apply)

    /// Can the segment under edit time `t` be split there? Not within 0.1 s of its edges, not past 50 segments.
    public func canSplit(at t: Double) -> Bool {
        guard segments.count < EditList.maxSegments, let i = segmentIndex(at: t), let src = sourceTime(at: t) else { return false }
        let s = segments[i]
        return src - s.inSec >= EditList.minSegment - 1e-9 && s.outSec - src >= EditList.minSegment - 1e-9
    }

    /// Splits the segment under edit time `t` at `t`; both halves keep its speed and mute. `snap` rounds the cut to a frame.
    @discardableResult
    public mutating func split(at t: Double, fps: Double? = nil) -> Bool {
        guard canSplit(at: t), let i = segmentIndex(at: t), var src = sourceTime(at: t) else { return false }
        let s = segments[i]
        if let fps { src = EditList.snap(src, fps: fps) }
        guard src - s.inSec >= EditList.minSegment - 1e-9, s.outSec - src >= EditList.minSegment - 1e-9 else { return false }
        var a = s
        a.outSec = src
        var b = s
        b.id = EditList.newId()
        b.inSec = src
        segments.replaceSubrange(i...i, with: [a, b])
        return true
    }

    /// Removes a segment (cuts it out). The last remaining one can't be deleted.
    @discardableResult
    public mutating func delete(_ id: String) -> Bool {
        guard segments.count > 1, let i = segments.firstIndex(where: { $0.id == id }) else { return false }
        segments.remove(at: i)
        return true
    }

    /// Moves a segment's in point (source seconds): never before the previous segment's out point (or 0), and at least
    /// `minSegment` before its own out point. `fps` snaps it to a frame.
    @discardableResult
    public mutating func trimIn(_ id: String, to src: Double, fps: Double? = nil) -> Bool {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return false }
        let lo = i > 0 ? segments[i - 1].outSec : 0
        let hi = segments[i].outSec - EditList.minSegment
        guard hi >= lo else { return false }
        var v = fps.map { EditList.snap(src, fps: $0) } ?? src
        v = min(max(lo, v), hi)
        guard abs(v - segments[i].inSec) > 1e-9 else { return false }
        segments[i].inSec = v
        return true
    }

    /// Moves a segment's out point: never past the next segment's in point (or the source's end), and at least `minSegment`
    /// after its own in point.
    @discardableResult
    public mutating func trimOut(_ id: String, to src: Double, fps: Double? = nil) -> Bool {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return false }
        let hi = i < segments.count - 1 ? segments[i + 1].inSec : sourceDurationSec
        let lo = segments[i].inSec + EditList.minSegment
        guard hi >= lo else { return false }
        var v = fps.map { EditList.snap(src, fps: $0) } ?? src
        v = min(max(lo, v), hi)
        guard abs(v - segments[i].outSec) > 1e-9 else { return false }
        segments[i].outSec = v
        return true
    }

    /// Sets one segment's speed, or every segment's when `id` is nil ("Whole video"). Only the six speeds are allowed.
    @discardableResult
    public mutating func setSpeed(_ speed: Double, segment id: String? = nil) -> Bool {
        guard EditList.speeds.contains(speed) else { return false }
        var changed = false
        for i in segments.indices where id == nil || segments[i].id == id {
            if segments[i].speed != speed {
                segments[i].speed = speed
                changed = true
            }
        }
        return changed
    }

    /// Mutes one segment, or the whole video when `id` is nil.
    @discardableResult
    public mutating func setMuted(_ on: Bool, segment id: String? = nil) -> Bool {
        if let id {
            guard let i = segments.firstIndex(where: { $0.id == id }), segments[i].muted != on else { return false }
            segments[i].muted = on
            return true
        }
        guard mute != on else { return false }
        mute = on
        return true
    }

    /// The server's rules, checked before exporting: what's wrong, in the member's words, or nil.
    public var problem: String? {
        if version != 1 { return "This edit was made with a newer version of MUSE" }
        if segments.isEmpty { return "Keep at least one part of the video" }
        if segments.count > EditList.maxSegments { return "Up to \(EditList.maxSegments) parts" }
        var prevOut = 0.0
        for s in segments {
            if s.inSec < 0 || s.inSec >= s.outSec || s.outSec > sourceDurationSec + EditList.endSlack { return "A part of the edit is outside the video" }
            if s.inSec < prevOut - 1e-9 { return "The parts overlap" }
            if s.sourceLength < EditList.minSegment - 1e-9 { return "A part is shorter than 0.1 s" }
            if !EditList.speeds.contains(s.speed) { return "That speed isn't available" }
            prevOut = s.outSec
        }
        let d = duration
        if d < EditList.minOutput - 1e-9 { return "The edit must be at least 0.5 s long" }
        if d > EditList.maxOutput + 1e-9 { return "The edit can be up to 10 minutes long" }
        if let data = try? JSONEncoder().encode(self), data.count > EditList.maxJSONBytes { return "This edit has too many parts" }
        return nil
    }

    /// Is an exported file's length close enough to the list's (max(0.5 s, 5 %))?
    public func accepts(durationSec d: Double) -> Bool {
        abs(d - duration) <= max(0.5, duration * 0.05)
    }

    /// Fits a stored list to the real source length (it can differ a little from `Take.durationSec`): points past the end
    /// are pulled in, and segments left too short are dropped. Falls back to the whole source.
    public func fitted(to sourceDuration: Double, sourceTakeId: String? = nil) -> EditList {
        var segs: [EditSegment] = []
        for var s in segments {
            s.outSec = min(s.outSec, sourceDuration)
            s.inSec = max(segs.last?.outSec ?? 0, min(s.inSec, s.outSec))
            if !EditList.speeds.contains(s.speed) { s.speed = 1 }
            if s.sourceLength >= EditList.minSegment - 1e-9 { segs.append(s) }
        }
        let id = sourceTakeId ?? self.sourceTakeId
        if segs.isEmpty { return EditList(sourceTakeId: id, sourceDurationSec: sourceDuration, mute: mute) }
        return EditList(sourceTakeId: id, sourceDurationSec: sourceDuration, segments: segs, mute: mute)
    }

    /// Rounds to the nearest frame at `fps`.
    public static func snap(_ t: Double, fps: Double) -> Double {
        guard fps > 0 else { return t }
        return (t * fps).rounded() / fps
    }

    /// "0:03.40": minutes, seconds and hundredths, as the editor shows times.
    public static func clock(_ s: Double) -> String {
        let cs = Int((max(0, s) * 100).rounded())
        return "\(cs / 6000):" + String(format: "%02d.%02d", (cs / 100) % 60, cs % 100)
    }

    /// "1×", "0.75×", "1.5×".
    public static func speedLabel(_ s: Double) -> String {
        var t = String(format: "%.2f", s)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t + "×"
    }
}

/// Undo / redo over edit lists (up to 100 steps). Reset is a change too, so it can be undone.
public struct EditHistory: Sendable {
    public static let maxSteps = 100

    public private(set) var current: EditList
    /// The untouched source, for Reset.
    public let original: EditList
    private var undoStack: [EditList] = []
    private var redoStack: [EditList] = []

    public init(_ list: EditList, original: EditList? = nil) {
        current = list
        self.original = original ?? EditList(sourceTakeId: list.sourceTakeId, sourceDurationSec: list.sourceDurationSec)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }

    /// Runs `change` on a copy and records it when it changed something. Returns whether it did.
    @discardableResult
    public mutating func apply(_ change: (inout EditList) -> Bool) -> Bool {
        var next = current
        guard change(&next), next != current else { return false }
        push(current)
        current = next
        return true
    }

    private mutating func push(_ l: EditList) {
        undoStack.append(l)
        if undoStack.count > EditHistory.maxSteps { undoStack.removeFirst(undoStack.count - EditHistory.maxSteps) }
        redoStack.removeAll()
    }

    /// A drag (trim handle): `begin` records one undo step, `update` changes the list without new steps, `end` drops the
    /// step again when the drag ended where it began.
    public mutating func begin() { push(current) }
    public mutating func update(_ list: EditList) { current = list }
    public mutating func end() {
        if let last = undoStack.last, last == current { undoStack.removeLast() }
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(current)
        current = prev
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(current)
        current = next
        return true
    }

    /// Back to the whole source at 1× with sound (undoable).
    @discardableResult
    public mutating func reset() -> Bool {
        let o = original
        return apply { $0 = o; return true }
    }
}

/// POST /v1/takes/{id}/versions: the edited file (an upload whose PUT is done, not confirmed), its thumbnail, the edit list
/// and the file's real length, size and frame rate.
public struct TakeVersionRequest: Codable, Sendable, Equatable {
    public var uploadId: String
    public var thumbUploadId: String?
    public var thumb: ImageRef?
    public var edits: EditList
    public var durationSec: Double
    public var width: Int
    public var height: Int
    public var fps: Double?

    public init(uploadId: String, thumbUploadId: String? = nil, thumb: ImageRef? = nil, edits: EditList, durationSec: Double, width: Int, height: Int, fps: Double? = nil) {
        self.uploadId = uploadId
        self.thumbUploadId = thumbUploadId
        self.thumb = thumb
        self.edits = edits
        self.durationSec = durationSec
        self.width = width
        self.height = height
        self.fps = fps
    }
}

/// What `uploadEditedVideo` hands back for `TakeVersionRequest`.
public struct EditedUpload: Sendable, Equatable {
    public var uploadId: String
    public var thumbUploadId: String?
    public var thumb: ImageRef?

    public init(uploadId: String, thumbUploadId: String? = nil, thumb: ImageRef? = nil) {
        self.uploadId = uploadId
        self.thumbUploadId = thumbUploadId
        self.thumb = thumb
    }
}

extension TakeVersionRequest {
    /// The request for an exported, uploaded edit.
    public static func make(_ upload: EditedUpload, video: EditedVideo, edits: EditList) -> TakeVersionRequest {
        TakeVersionRequest(uploadId: upload.uploadId, thumbUploadId: upload.thumbUploadId, thumb: upload.thumbUploadId == nil ? upload.thumb : nil,
                           edits: edits, durationSec: (video.durationSec * 1000).rounded() / 1000, width: video.width, height: video.height,
                           fps: video.fps.map { ($0 * 100).rounded() / 100 })
    }
}

/// The exported file and its facts, before upload.
public struct EditedVideo: Sendable {
    public var file: URL
    /// A JPEG frame of the output (≤ 720 px on the long side), if one was made.
    public var thumbJPEG: Data?
    public var durationSec: Double
    public var width: Int
    public var height: Int
    public var fps: Double?

    public init(file: URL, thumbJPEG: Data?, durationSec: Double, width: Int, height: Int, fps: Double?) {
        self.file = file
        self.thumbJPEG = thumbJPEG
        self.durationSec = durationSec
        self.width = width
        self.height = height
        self.fps = fps
    }
}

extension Take {
    /// An edited version of a take (made in the video editor).
    public var isEdit: Bool { kind == "edit" }

    /// Where the editor opens this take: an edited version re-opens its edit list on its source when that take still exists
    /// (`sourceExists`); otherwise its own video is the source with a fresh list. Nil for photos and takes with no video.
    public func editorStart(sourceExists: (String) -> Bool) -> (sourceTakeId: String, list: EditList?)? {
        guard isVideo, videoUrl != nil else { return nil }
        if isEdit, let parent = parentTakeId, let e = edits, sourceExists(parent) {
            return (parent, e)
        }
        return (id, nil)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
