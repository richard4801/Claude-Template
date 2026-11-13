import Foundation

// Edit → Uploads as a media bin (owner, 2026-11-12; plans/design/edit-panels/uploads-{b,a}.png): files from this Mac (or a
// link, or the microphone) land in the bin first; "+" puts one on the timeline at the playhead and dragging places it.
// The kind comes from the file, so one "Add" covers videos, pictures and sounds.

extension EditSuite {
    /// What an upload is, from its file.
    public enum UploadKind: String, CaseIterable, Hashable, Sendable {
        case video, picture, audio
    }

    /// The bin's filter chips (shown only when the bin holds more than one kind).
    public enum UploadFilter: String, CaseIterable, Hashable, Sendable, Identifiable {
        case all, video, pictures, audio
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .all: return "All"
            case .video: return "Video"
            case .pictures: return "Images"
            case .audio: return "Audio"
            }
        }
        public func includes(_ k: UploadKind) -> Bool {
            switch self {
            case .all: return true
            case .video: return k == .video
            case .pictures: return k == .picture
            case .audio: return k == .audio
            }
        }
    }

    /// One tile of the bin.
    public struct Upload: Identifiable, Hashable, Sendable {
        public var id: String
        public var kind: UploadKind
        public var name: String
        public var durationSec: Double?
    }

    public enum UploadBin {
        public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        public static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
        public static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "aac"]

        /// The kind a file becomes, from its extension (nil: MUSE can't use it).
        public static func kind(ofExtension ext: String) -> UploadKind? {
            let e = ext.lowercased()
            if videoExtensions.contains(e) { return .video }
            if pictureExtensions.contains(e) { return .picture }
            if audioExtensions.contains(e) { return .audio }
            return nil
        }

        /// The edit's own uploads (not takes, not the content library, not helper copies such as reversed or stabilized
        /// videos), newest first. `names` are the display names the app keeps per asset.
        public static func items(_ p: EditV2.Project, names: [String: String]) -> [Upload] {
            p.assets.compactMap { a -> Upload? in
                guard a.upload != nil, a.reverseOf == nil, a.derivedFrom == nil else { return nil }
                let kind: UploadKind
                switch a.kind {
                case .video: kind = .video
                case .image: kind = .picture
                case .audio: kind = .audio
                default: return nil
                }
                let fallback = kind == .video ? "Video" : kind == .picture ? "Picture" : "Sound"
                let name = (names[a.id] ?? a.name).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? fallback
                return Upload(id: a.id, kind: kind, name: name, durationSec: kind == .picture ? nil : a.durationSec)
            }
            .reversed()
        }

        /// The chips to show: none while the bin holds one kind (or nothing), else All and each kind present.
        public static func filters(_ items: [Upload]) -> [UploadFilter] {
            let kinds = Set(items.map(\.kind))
            guard kinds.count > 1 else { return [] }
            return [.all] + UploadFilter.allCases.filter { f in f != .all && kinds.contains { f.includes($0) } }
        }

        /// The items under a chip; a chip that no longer applies (its kind is gone) shows everything.
        public static func filtered(_ items: [Upload], by f: UploadFilter) -> [Upload] {
            guard filters(items).contains(f) else { return items }
            return items.filter { f.includes($0.kind) }
        }

        /// The length on a tile: "0:23", "2:48", "1:02:05" (never "0:00" for a real clip).
        public static func length(_ seconds: Double?) -> String? {
            guard let s = seconds, s.isFinite, s > 0 else { return nil }
            let total = max(1, Int(s.rounded()))
            let h = total / 3600, m = (total / 60) % 60, sec = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        }

        /// The row a sound goes on: the audio row it was dropped on, else music for a long file (a song) and a sound
        /// effect for a short one.
        public static func audioKind(lane: EditV2.TrackKind?, durationSec: Double?) -> EditV2.TrackKind {
            if let lane, lane.isAudio { return lane }
            return (durationSec ?? 0) >= songSec ? .music : .sfx
        }

        /// A sound this long or longer is taken as a song.
        public static let songSec: Double = 30
    }
}

extension EditSuiteState {
    /// Puts an upload in the bin without placing it (undoable; an unused asset is valid in the shared contract).
    @discardableResult
    public mutating func addToBin(_ asset: E.Asset) -> Bool {
        guard project.asset(asset.id) == nil else { return false }
        return apply { $0.addingAsset(asset) }
    }

    /// Places an upload from the bin: at `t` (a drop) or the playhead ("+"). `lane` is the row it was dropped on: a video
    /// goes into the main sequence (at the cut nearest that time) unless dropped on an overlay row; a sound goes on the
    /// audio row it was dropped on (`audioKind` overrides, from the "+" menu); a picture goes on the Stickers row.
    @discardableResult
    public mutating func placeUpload(_ assetId: String, at t: Double? = nil, lane: E.TrackKind? = nil, audioKind: E.TrackKind? = nil) -> Bool {
        guard let a = project.asset(assetId) else { return false }
        return place(a, at: t, lane: lane, audioKind: audioKind)
    }

    /// Places any media asset the same way (a take from Takes, or an upload); the asset joins the project if it isn't in it.
    @discardableResult
    public mutating func place(_ a: E.Asset, at t: Double? = nil, lane: E.TrackKind? = nil, audioKind: E.TrackKind? = nil) -> Bool {
        if let t { playhead = min(max(0, EditSuite.finiteSeconds(t)), duration) }
        switch a.kind {
        case .image:
            return addImage(a)
        case .audio:
            let kind = audioKind.flatMap { $0.isAudio ? $0 : nil } ?? EditSuite.UploadBin.audioKind(lane: lane, durationSec: a.durationSec)
            return addAudio(a, kind: kind, at: playhead)
        case .video:
            if let lane, lane != .main { return addVideo(a, overlay: true) }
            return insertMain(a, at: playhead)
        default:
            return false
        }
    }

    /// A video into the main sequence at the cut nearest `at` (before the clip whose middle is after it).
    private mutating func insertMain(_ a: E.Asset, at: Double) -> Bool {
        guard let d = a.durationSec, d >= E.minClipSourceSec else { return false }
        var newId: String?
        let ok = apply { p in
            let q = p.addingAsset(a)
            guard let main = q.mainTrack else { return nil }
            let index = E.timeline(q).filter { ($0.startSec + $0.endSec) / 2 < at }.count
            let id = q.newId("c")
            newId = id
            return q.adding(.video(E.VideoClip(id: id, asset: a.id, inSec: 0, outSec: E.r6(d))), toTrack: main.id, index: index)
        }
        if ok { selection = newId }
        return ok
    }
}
