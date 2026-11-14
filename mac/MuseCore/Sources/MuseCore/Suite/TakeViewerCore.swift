import Foundation

// The take viewer (plans/swap-viewer-design.md §B, owner-approved 2026-11-12): one viewer wherever a take or image is
// shown. This file holds what the app's views need that can be tested without AppKit: the frame maths (no letterbox),
// playback without a scrubber (the keys, the jumps, the readout), the take actions and the order in which their labels
// give way, and the New Swap trimmer. The platform layouts ("skins") and their safe zones live here too, but since the
// owner's decision of 2026-11-12 they are shown in Edit only (Edit/EditPlatformPreview.swift), never in the viewer.

// MARK: Preview skins

/// How Edit's preview shows the edit: clean, or under a generic drawing of a platform's layout. Portrait and square
/// canvases get the phone layouts; landscape ones get the landscape players.
public enum PreviewSkin: String, Codable, CaseIterable, Sendable {
    case clean, tiktok, reels, shorts, facebook, youtube

    public var label: String {
        switch self {
        case .clean: return "Clean"
        case .tiktok: return "TikTok"
        case .reels: return "Reels"
        case .shorts: return "Shorts"
        case .facebook: return "Facebook"
        case .youtube: return "YouTube"
        }
    }

    /// The choices for media of this shape (width / height): portrait and square get the phone layouts.
    public static func options(aspect: Double) -> [PreviewSkin] {
        isLandscape(aspect) ? [.clean, .youtube, .facebook] : [.clean, .tiktok, .reels, .shorts, .facebook]
    }

    public static func isLandscape(_ aspect: Double) -> Bool { aspect.isFinite && aspect > 1.05 }
}

/// The parts of the screen a platform's own buttons and captions cover, as fractions of the screen (approximate; the
/// apps move their buttons now and then, so the server can send corrections: GET /v1/preview/layouts).
public struct SafeZone: Codable, Hashable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double, bottom: Double, left: Double = 0, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    /// The safe box, in the unit square (x, y, width, height).
    public var safeRect: (x: Double, y: Double, w: Double, h: Double) {
        let l = Self.clamp(left), r = Self.clamp(right), t = Self.clamp(top), b = Self.clamp(bottom)
        return (l, t, max(0, 1 - l - r), max(0, 1 - t - b))
    }

    private static func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 0.5) : 0 }
}

/// The safe zones per skin. The defaults follow the common guidance of the safe-zone checkers (Pallyy, bundle.social,
/// upload-post) on a 1080 × 1920 frame; the server's table replaces any it sends.
public struct PreviewLayouts: Codable, Hashable, Sendable {
    public var zones: [String: SafeZone]
    /// Landscape players (YouTube, Facebook): what their title and controls cover on a 16:9 frame.
    public var landscape: [String: SafeZone]?
    public var note: String?

    public init(zones: [String: SafeZone], landscape: [String: SafeZone]? = nil, note: String? = nil) {
        self.zones = zones
        self.landscape = landscape
        self.note = note
    }

    public static let defaults = PreviewLayouts(zones: [
        PreviewSkin.tiktok.rawValue: SafeZone(top: 0.11, bottom: 0.29, left: 0.03, right: 0.17),
        PreviewSkin.reels.rawValue: SafeZone(top: 0.10, bottom: 0.30, left: 0.03, right: 0.16),
        PreviewSkin.shorts.rawValue: SafeZone(top: 0.09, bottom: 0.30, left: 0.03, right: 0.17),
        PreviewSkin.facebook.rawValue: SafeZone(top: 0.10, bottom: 0.28, left: 0.03, right: 0.16),
    ], landscape: [
        PreviewSkin.youtube.rawValue: SafeZone(top: 0.12, bottom: 0.16, left: 0.03, right: 0.03),
        PreviewSkin.facebook.rawValue: SafeZone(top: 0.08, bottom: 0.16, left: 0.03, right: 0.03),
    ], note: "Approximate. Each app moves its buttons now and then.")

    /// The phone zone for a skin: the server's, else the default; none for Clean and YouTube (a landscape player).
    public func zone(_ skin: PreviewSkin) -> SafeZone? {
        guard skin != .clean, skin != .youtube else { return nil }
        return zones[skin.rawValue] ?? Self.defaults.zones[skin.rawValue]
    }

    /// The landscape zone for a skin (YouTube, Facebook): the server's, else the default; none for Clean.
    public func landscapeZone(_ skin: PreviewSkin) -> SafeZone? {
        guard skin == .youtube || skin == .facebook else { return nil }
        return landscape?[skin.rawValue] ?? Self.defaults.landscape?[skin.rawValue]
    }

    /// The server's table over the defaults (a skin it leaves out keeps its default).
    public func merged(over base: PreviewLayouts = .defaults) -> PreviewLayouts {
        PreviewLayouts(zones: base.zones.merging(zones) { _, new in new },
                       landscape: (base.landscape ?? [:]).merging(landscape ?? [:]) { _, new in new },
                       note: note ?? base.note)
    }
}

// MARK: Frames (no letterbox)

public enum ViewerFrame {
    /// The media's shape (width / height): the take's own size, else 9:16 for video and 4:5 for a still until it loads.
    public static func aspect(width: Int?, height: Int?, isVideo: Bool) -> Double {
        if let w = width, let h = height, w > 0, h > 0 { return Double(w) / Double(h) }
        return isVideo ? 9.0 / 16.0 : 4.0 / 5.0
    }

    /// The largest size of this shape inside the box: the frame is the media's shape, never a box around it.
    public static func fit(aspect: Double, width: Double, height: Double) -> (w: Double, h: Double) {
        guard aspect.isFinite, aspect > 0, width > 0, height > 0 else { return (0, 0) }
        if width / height > aspect { return ((height * aspect).rounded(), height.rounded()) }
        return (width.rounded(), (width / aspect).rounded())
    }
}

// MARK: Playback without a scrubber

/// What a key does in the viewer (Mac). The keys only work while the viewer has focus and no text field does.
public enum ViewerCommand: Equatable, Sendable {
    case togglePlay
    case jump(Double)           // seconds, signed
    case shuttle(Double)        // playback rate, signed; 0 pauses
    case frame(Int)             // one frame back or forward (paused)
    case toStart, toEnd
    case mute
    case fullScreen
    case previousTake, nextTake
    case close
}

public enum ViewerKey: Equatable, Sendable {
    case space, left, right, up, down, home, end, escape
    case character(Character)
}

/// The viewer's transport: the keys (owner 2026-11-12: space plays or pauses, ← → 3 s and 10 s with ⇧, J/K/L) and the
/// shuttle's state.
public struct ViewerTransport: Equatable, Sendable {
    public static let jump = 3.0
    public static let bigJump = 10.0
    public static let rates: [Double] = [1, 2, 4]

    /// The shuttle's current rate (signed; 0 = paused by K, or not shuttling).
    public private(set) var shuttle: Double = 0
    /// K is held (with J or L: one frame).
    public var kHeld = false

    public init() {}

    /// The command for a key, and the shuttle's next state.
    public mutating func command(for key: ViewerKey, shift: Bool) -> ViewerCommand? {
        switch key {
        case .space: shuttle = 0; return .togglePlay
        case .left: return .jump(-(shift ? Self.bigJump : Self.jump))
        case .right: return .jump(shift ? Self.bigJump : Self.jump)
        case .up: return .previousTake
        case .down: return .nextTake
        case .home: return .toStart
        case .end: return .toEnd
        case .escape: return .close
        case .character(let c):
            switch Character(c.lowercased()) {
            case "k": shuttle = 0; return .shuttle(0)
            case "l":
                if kHeld { return .frame(1) }
                shuttle = Self.next(shuttle, forward: true)
                return .shuttle(shuttle)
            case "j":
                if kHeld { return .frame(-1) }
                shuttle = Self.next(shuttle, forward: false)
                return .shuttle(shuttle)
            case ",": return .frame(-1)
            case ".": return .frame(1)
            case "m": return .mute
            case "f": return .fullScreen
            default: return nil
            }
        }
    }

    /// L: 1×, then 2×, then 4× forward; while going backward, L first slows the backward speed down to a stop. J the same, mirrored.
    static func next(_ rate: Double, forward: Bool) -> Double {
        let sign: Double = forward ? 1 : -1
        if rate == 0 || (rate > 0) != forward {
            // Starting, or turning around: going the other way at speed steps down first, then stops, then starts.
            if rate != 0 {
                let mag = abs(rate)
                guard let i = rates.firstIndex(of: mag), i > 0 else { return 0 }
                return -sign * rates[i - 1]
            }
            return sign * rates[0]
        }
        let mag = abs(rate)
        let i = rates.firstIndex(of: mag) ?? 0
        return sign * rates[min(i + 1, rates.count - 1)]
    }

    /// Where a jump lands, inside the take.
    public static func seek(_ time: Double, by delta: Double, duration: Double) -> Double {
        let d = duration.isFinite ? max(0, duration) : 0
        let t = (time.isFinite ? time : 0) + delta
        return min(max(0, t), d)
    }

    /// The brief readout while seeking: "+3 s  0:07 / 0:10" (the jump, then where it landed); with no jump, only the time.
    public static func readout(delta: Double?, time: Double, duration: Double) -> String {
        let clock = "\(Take.clock(max(0, time))) / \(Take.clock(max(0, duration)))"
        guard let d = delta, d != 0 else { return clock }
        let n = Pricing.trimNum(abs(d))
        return "\(d > 0 ? "+" : "−")\(n) s  \(clock)"
    }

    /// A shuttle's readout: "2× ▸" / "◂ 2×".
    public static func shuttleLabel(_ rate: Double) -> String {
        guard rate != 0 else { return "Paused" }
        let n = Pricing.trimNum(abs(rate))
        return rate > 0 ? "\(n)× forward" : "\(n)× back"
    }
}

/// The phone's double-tap skip (Android, after the Mac): the left or right third, 3 s per tap, taps adding up while they
/// keep coming (YouTube style, owner 2026-11-12). Kept here so both apps share the rule.
public struct DoubleTapSkip: Equatable, Sendable {
    public static let step = 3.0
    public static let window = 0.6
    public private(set) var total: Double = 0
    private var lastAt: Double = -1
    private var lastSide = 0

    public init() {}

    /// -1 left third, +1 right third, 0 middle (a double-tap in the middle does nothing).
    public static func side(x: Double, width: Double) -> Int {
        guard width > 0 else { return 0 }
        if x < width / 3 { return -1 }
        if x > width * 2 / 3 { return 1 }
        return 0
    }

    /// A tap that belongs to a double-tap run on `side` at time `at` (seconds): the skip it adds, and the run's total.
    public mutating func tap(side: Int, at: Double) -> Double {
        guard side != 0 else { return 0 }
        if side != lastSide || at - lastAt > Self.window { total = 0 }
        lastSide = side
        lastAt = at
        total += Double(side) * Self.step
        return Double(side) * Self.step
    }
}

// MARK: Take actions

/// The viewer's take actions, in their one order (plans/swap-viewer-design.md §B4).
public enum TakeViewerAction: String, CaseIterable, Sendable {
    case keep, redo, extend, upscale, split, useInShot, share

    public var title: String {
        switch self {
        case .keep: return "Keep"
        case .redo: return "Redo"
        case .extend: return "Extend"
        case .upscale: return "Upscale"
        case .split: return "Split"
        case .useInShot: return "Use in Shot"
        case .share: return "Share"
        }
    }

    public var help: String {
        switch self {
        case .keep: return "Keep this take"
        case .redo: return "Make it again with the same settings"
        case .extend: return "A longer take: what happens next, or before"
        case .upscale: return "Sharper 1080p, 2K or 4K from this take"
        case .split: return "Open it in Edit at this moment"
        case .useInShot: return "Start a video from this photo (its start frame)"
        case .share: return "Post or share this take"
        }
    }
}

/// Where the viewer is shown, which sets its actions.
public enum TakeViewerContext: String, Sendable {
    /// The Suite's stage and the Takes viewer: every action.
    case suite
    /// The Library's take page: the page's inspector holds the actions.
    case library
    /// Compare: Keep only (More in the menu).
    case compare
    /// New Swap's source clip: none.
    case source
}

public enum TakeViewerActions {
    /// The actions shown: the context's, minus any this take can't do (hidden, not greyed; More says why).
    /// `canUseInShot`: a still from the Photo tab (owner 2026-11-14: "Use in Shot" makes it a video's start frame).
    public static func list(_ ctx: TakeViewerContext, isVideo: Bool, canRedo: Bool, canExtend: Bool, canUpscale: Bool, canUseInShot: Bool = false) -> [TakeViewerAction] {
        switch ctx {
        case .source, .library: return []
        case .compare: return [.keep]
        case .suite:
            return TakeViewerAction.allCases.filter {
                switch $0 {
                case .keep, .share: return true
                case .redo: return canRedo
                case .extend: return isVideo && canExtend
                case .upscale: return canUpscale
                case .split: return isVideo
                case .useInShot: return !isVideo && canUseInShot
                }
            }
        }
    }

    /// The order labels give way when a row is too narrow: Split, Upscale, Extend, then Redo. Keep and Share keep theirs.
    public static let dropOrder: [TakeViewerAction] = [.split, .useInShot, .upscale, .extend, .redo]

    /// Each step's icon-only set, from all labels to the fewest: what `ViewThatFits` tries in turn.
    public static func steps(_ actions: [TakeViewerAction]) -> [Set<TakeViewerAction>] {
        var out: [Set<TakeViewerAction>] = [[]]
        var cur = Set<TakeViewerAction>()
        for a in dropOrder where actions.contains(a) {
            cur.insert(a)
            out.append(cur)
        }
        return out
    }

    /// Why an action isn't offered, for the More menu.
    public static func hiddenReasons(isVideo: Bool, canRedo: Bool, canExtend: Bool, canUpscale: Bool, isMaxResolution: Bool) -> [String] {
        var r: [String] = []
        if !canRedo { r.append("Redo: this take was made before its settings were saved") }
        if isVideo && !canExtend { r.append("Extend: no model can continue this take") }
        if !canUpscale { r.append(isMaxResolution ? "Upscale: already 4K" : "Upscale: not for this take") }
        return r
    }
}

// MARK: New Swap's trimmer

/// The filmstrip trimmer's maths: a window [from, to] inside the clip, at least `minLen` and at most `maxLen` long.
public struct TrimWindow: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public let duration: Double
    public let minLen: Double
    public let maxLen: Double

    public init(from: Double, to: Double, duration: Double, minLen: Double, maxLen: Double) {
        let d = max(0, duration.isFinite ? duration : 0)
        self.duration = d
        self.minLen = min(max(0, minLen), d)
        self.maxLen = max(self.minLen, min(maxLen.isFinite ? maxLen : d, d))
        self.from = 0
        self.to = 0
        self.set(from: from, to: to)
    }

    public var length: Double { to - from }

    /// The window for a clip with nothing picked yet: from the start, as long as the model takes.
    public static func initial(duration: Double, minLen: Double, maxLen: Double, range: (Double, Double)?) -> TrimWindow {
        if let r = range { return TrimWindow(from: r.0, to: r.1, duration: duration, minLen: minLen, maxLen: maxLen) }
        return TrimWindow(from: 0, to: min(duration, maxLen), duration: duration, minLen: minLen, maxLen: maxLen)
    }

    mutating func set(from a: Double, to b: Double) {
        var a = Self.tenth(max(0, min(a, duration)))
        var b = Self.tenth(max(0, min(b, duration)))
        if b - a > maxLen { b = a + maxLen }
        if b - a < minLen {
            b = min(duration, a + minLen)
            a = max(0, b - minLen)
        }
        from = a
        to = b
    }

    /// Drag the start handle: the end stays unless the length would leave the model's limits.
    public mutating func moveStart(to x: Double) {
        let a = max(0, min(x, to - minLen))
        let b = to - a > maxLen ? a + maxLen : to
        set(from: a, to: b)
    }

    /// Drag the end handle.
    public mutating func moveEnd(to x: Double) {
        let b = min(duration, max(x, from + minLen))
        let a = b - from > maxLen ? b - maxLen : from
        set(from: a, to: b)
    }

    /// Drag the middle: the same length, slid along the clip.
    public mutating func slide(by dx: Double) {
        let len = length
        let a = max(0, min(from + dx, duration - len))
        set(from: a, to: a + len)
    }

    /// The whole clip fits the model.
    public var wholeClipFits: Bool { duration <= maxLen + 0.05 }

    /// "Uses 0:02–0:12 of 0:24, 10 s." (+ the model's limit when the clip is longer than it takes)
    public func line(model: String?) -> String {
        var s = "Uses \(Take.clock(from))–\(Take.clock(to)) of \(Take.clock(duration)), \(Pricing.trimNum(length)) s."
        if !wholeClipFits, let m = model { s += " \(m) takes up to \(Pricing.trimNum(maxLen)) s." }
        return s
    }

    private static func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

// The viewer's one call. Outside the MuseAPI protocol like New Swap's, so every client and test double compiles
// unchanged; anything but the HTTP client (demo mode, tests) gets the defaults.
extension MuseAPI {
    /// GET /v1/preview/layouts: the safe zones per skin, merged over the defaults. Never throws: a server without the
    /// route, or offline, gives the defaults.
    public func previewLayouts() async -> PreviewLayouts {
        guard let h = self as? HTTPMuseAPI, let l: PreviewLayouts = try? await h.suiteCall("GET", "v1/preview/layouts") else { return .defaults }
        return l.merged()
    }
}
