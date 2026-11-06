import Foundation

// AI suite (workstream 1): the composer's Extend tool and Upscale on a finished take (plans/api.md "Extend (composer,
// 2026-11-06)" and "App clean-up" §2 Upscale). Pure rules: which videos can be extended (a take's stored key, or an
// upload with its length), the request the tool sends, and the Upscale sizes with their prices (price × the take's length).

// MARK: Extend

/// After (the clip carries on) or Before (what led into it).
public enum ExtendDirection: String, CaseIterable, Sendable, Identifiable {
    case after, before
    public var id: String { rawValue }

    public var label: String { self == .after ? "After" : "Before" }

    /// The prompt box's title.
    public var promptTitle: String { self == .after ? "What happens next" : "What happens before" }

    public var placeholder: String {
        self == .after ? "She turns, smiles and walks out of frame" : "She walks into frame and sits down"
    }
}

/// Stored keys: the part after `/uploads/` in a file's address, as the server reads it (`storageKeyOf`).
public enum SuiteKeys {
    public static let maxLength = 300

    /// What the server accepts as a key: a letter or digit first, then letters, digits, `.`, `_`, `/` and `-`, at most 300
    /// characters (and never a `..` step).
    public static func isAccepted(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= maxLength, !key.contains(".."), let first = key.unicodeScalars.first, alnum(first) else { return false }
        return key.unicodeScalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "/" || $0 == "-" }
    }

    static func alnum(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
    }

    /// A file address's stored key ("https://host/uploads/r/j_1/take_1.mp4" → "r/j_1/take_1.mp4"), or nil when the address
    /// isn't one of the studio's stored files.
    public static func key(fromUrl url: String?) -> String? {
        guard let u = url, let r = u.range(of: "/uploads/") else { return nil }
        var k = String(u[r.upperBound...])
        if let cut = k.firstIndex(where: { $0 == "?" || $0 == "#" }) { k = String(k[..<cut]) }
        return isAccepted(k) ? k : nil
    }
}

/// The video Extend continues: one of the studio's takes (the server knows its length) or an upload (the app sends its
/// length, `seconds`).
public struct ExtendSource: Hashable, Sendable {
    public var key: String
    public var seconds: Double?
    /// Set for a take; nil for an upload.
    public var takeId: String?
    public var name: String
    public var thumb: ImageRef?

    /// The server's limit on a video's `seconds`.
    public static let maxUploadSeconds = 60.0

    public init(key: String, seconds: Double?, takeId: String? = nil, name: String, thumb: ImageRef? = nil) {
        self.key = key
        self.seconds = seconds
        self.takeId = takeId
        self.name = name
        self.thumb = thumb
    }

    /// A finished video take with a stored file (its `videoUrl`; demo mode's `mediaKey`), else nil.
    public static func take(_ t: Take) -> ExtendSource? {
        guard t.isVideo else { return nil }
        guard let key = SuiteKeys.key(fromUrl: t.videoUrl) ?? t.mediaKey.flatMap({ SuiteKeys.isAccepted($0) ? $0 : nil }) else { return nil }
        return ExtendSource(key: key, seconds: t.durationSec, takeId: t.id, name: t.caption, thumb: t.thumb)
    }

    /// An uploaded video with its length. nil when the upload has no stored key or its length is unknown or over the limit
    /// (see `uploadProblem`).
    public static func upload(_ ref: SuiteVideoRef, seconds: Double?, name: String) -> ExtendSource? {
        guard uploadProblem(seconds: seconds) == nil, let key = ref.key.flatMap({ SuiteKeys.isAccepted($0) ? $0 : nil }) ?? SuiteKeys.key(fromUrl: ref.url) else { return nil }
        return ExtendSource(key: key, seconds: seconds, name: name)
    }

    /// Why an upload of this length can't be extended, or nil.
    public static func uploadProblem(seconds: Double?) -> String? {
        guard let s = seconds, s > 0 else { return "Couldn't read that video's length" }
        if s > maxUploadSeconds { return "Pick a video up to \(Int(maxUploadSeconds)) s" }
        return nil
    }

    public var isUpload: Bool { takeId == nil }

    /// What the request carries: the key, plus the length for an upload (a take's length is on the server).
    public var videoRef: SuiteVideoRef {
        SuiteVideoRef(key: key, seconds: isUpload ? seconds.map { ($0 * 1000).rounded() / 1000 } : nil)
    }

    /// "0:08 · take" / "0:12 · upload" under the VIDEO slot.
    public var caption: String {
        let length = seconds.map { Take.clock($0) }
        return [length, isUpload ? "upload" : "take"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The Extend tool's own settings (the bottom bar's quality, length and takes are the composer's).
public struct ExtendDraft: Hashable, Sendable {
    public var source: ExtendSource?
    public var direction: ExtendDirection
    public var prompt: String

    public init(source: ExtendSource? = nil, direction: ExtendDirection = .after, prompt: String = "") {
        self.source = source
        self.direction = direction
        self.prompt = prompt
    }
}

/// One take in the VIDEO slot's picker.
public struct ExtendTakeOption: Hashable, Sendable, Identifiable {
    public var take: Take
    public var source: ExtendSource
    public var id: String { take.id }
}

public enum ComposerExtend {
    /// The takes the VIDEO slot offers: finished video takes with a stored file, newest first.
    public static func takes(_ all: [Take]) -> [ExtendTakeOption] {
        all.sorted { $0.createdAt > $1.createdAt }.compactMap { t in ExtendSource.take(t).map { ExtendTakeOption(take: t, source: $0) } }
    }
}

extension ComposerDraft {
    /// Extend's request: `{mode: "extend", extend: {video, direction}, duration, prompt, quality, takes, aspectRatio, audio}`;
    /// nil until a video is picked. The owner's engine pin is a shot engine, so it isn't sent.
    public func extendRequest() -> ShotRequest? {
        guard let s = extend.source else { return nil }
        let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var r = ShotRequest.extendShot(s.videoRef, direction: extend.direction.rawValue, duration: duration, quality: quality, takes: takes,
                                       prompt: extend.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                       title: name.isEmpty ? "Extend" : "\(name.prefix(80)) · extended")
        r.aspectRatio = aspect
        r.audio = sound
        return r
    }

    /// The composer on Extend with this video (the take's "Extend" action).
    public func extending(_ source: ExtendSource, direction: ExtendDirection? = nil) -> ComposerDraft {
        var d = self
        d.tool = .extend
        d.collapsed = nil
        d.extend.source = source
        if let direction { d.extend.direction = direction }
        return d
    }
}

// MARK: Upscale

/// One size in the Upscale picker: its price for this take (price per output second × the take's length), or greyed "Soon".
public struct UpscaleChoice: Hashable, Sendable, Identifiable {
    public var size: UpscaleSize
    public var available: Bool
    public var price: Double?
    public var id: String { size.id }

    /// "$0.32", "Soon" (not offered yet) or "—" (offered, but the take's length is unknown).
    public var priceText: String {
        guard available else { return "Soon" }
        return price.map { Pricing.money($0) } ?? "—"
    }

    /// The size can be picked now.
    public var canPick: Bool { available && price != nil }
}

public enum UpscaleOffer {
    /// The add-on is on: available, not coming soon, with at least one priced size.
    public static func isLive(_ f: VideoFeatures) -> Bool {
        guard let a = f.upscale, a.available, !a.comingSoon else { return false }
        return a.sizes.contains { $0.available && $0.price != nil }
    }

    /// The price of upscaling `seconds` of video to this size, as the server holds it (rounded to $0.0001); nil when the size
    /// isn't priced or the length is unknown.
    public static func cost(_ s: UpscaleSize, seconds: Double?) -> Double? {
        guard s.available, let p = s.price, let secs = seconds, secs > 0 else { return nil }
        let rounded = (secs * 1000).rounded() / 1000
        return (p * rounded * 10000).rounded() / 10000
    }

    /// The picker's three sizes for a take of this length, in the server's order.
    public static func choices(_ f: VideoFeatures, seconds: Double?) -> [UpscaleChoice] {
        let a = f.upscale ?? AddonOption.defaults[2]
        let on = a.available && !a.comingSoon
        let sizes = a.sizes.isEmpty ? UpscaleSize.defaults : a.sizes
        return sizes.map { s in
            let ok = on && s.available && s.price != nil
            return UpscaleChoice(size: s, available: ok, price: ok ? cost(s, seconds: seconds) : nil)
        }
    }

    /// The toast for a refused upscale: `409 upscale_unavailable` means it isn't offered (any more).
    public static func refusal(_ e: ApiError) -> String? {
        e.code == "upscale_unavailable" ? "Upscale isn't available for this take yet · it's coming soon" : nil
    }

    /// Demo mode's Upscale sizes: 1080p $0.02 and 2K $0.04 per output second; 4K not yet.
    public static let demoSizes: [UpscaleSize] = [
        UpscaleSize(id: "1080p", label: "1080p", width: 1080, height: 1920, available: true, price: 0.02),
        UpscaleSize(id: "2k", label: "2K", width: 1440, height: 2560, available: true, price: 0.04),
        UpscaleSize(id: "4k", label: "4K", width: 2160, height: 3840, available: false, price: nil),
    ]
}

extension VideoFeatures {
    /// Demo mode's features: the contract's table with Upscale on (1080p and 2K priced, 4K coming).
    public static let demo: VideoFeatures = {
        var f = VideoFeatures()
        f.addons = f.addons.map { a0 -> AddonOption in
            var a = a0
            if a.id == "upscale" {
                a.available = true
                a.comingSoon = false
                a.sizes = UpscaleOffer.demoSizes
            }
            return a
        }
        return f
    }()
}
