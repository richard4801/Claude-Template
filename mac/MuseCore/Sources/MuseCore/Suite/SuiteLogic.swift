import Foundation

// AI suite (workstream 1): pure logic behind the video suite screens (testable on Linux). Labels follow the API's wording.

public enum SuiteText {
    /// The one quality ladder (decision 2): Draft / Standard / HD / Cinema, everywhere.
    public static let tierIds = ["draft", "standard", "hd", "cinema"]

    public static func tierLabel(_ id: String?) -> String {
        switch id {
        case "standard": return "Standard"
        case "hd": return "HD"
        case "cinema": return "Cinema"
        default: return "Draft"
        }
    }

    /// The suite-off states.
    public static let offOwnerTitle = "Turn on the AI suite"
    public static let offOwnerBody = "The server's AI suite is switched off. In Railway → Variables, set SUITE_MODE to live (real renders) or mock (free test renders), then redeploy."
    public static let offVariable = "SUITE_MODE"
    public static let offMember = "The AI suite isn't on yet · ask the studio owner"
    public static let testBadge = "Test renders · free"
    public static let comingSoon = "Coming soon"

    /// "Shot · HD · 1080p" style label for a tier and resolution (as the server's `shotLabel`).
    public static func shotLabel(_ tier: String, resolution: String, kind: String = "Shot") -> String {
        let r = resolution.allSatisfy(\.isNumber) ? "\(resolution)p" : (resolution.hasSuffix("P") ? String(resolution.dropLast()) + "p" : resolution)
        return "\(kind) · \(tierLabel(tier)) · \(r)"
    }

    /// "about $0.78 · 6 s" (+ " · 2 takes").
    public static func priceLine(_ usd: Double, seconds: Double, takes: Int) -> String {
        "about \(Pricing.money(usd)) · \(Pricing.trimNum(seconds)) s" + (takes > 1 ? " · \(takes) takes" : "")
    }

    /// "Generate · 6 s · $0.78" (+ " · 2 takes").
    public static func buttonLabel(_ usd: Double, seconds: Double, takes: Int) -> String {
        "Generate · \(Pricing.trimNum(seconds)) s · \(Pricing.money(usd))" + (takes > 1 ? " · \(takes) takes" : "")
    }

    /// Words that name a provider or a model. Members never see text that has one.
    static let engineWords = try! NSRegularExpression(
        pattern: #"\b(replicate|fal|runpod|minimax|h3|kling|seedance|veo|wan|ltx|lightricks|bytedance|google|sora)\b"#, options: [.caseInsensitive])

    /// True when `text` names no provider or model (member-safe for the suite).
    public static func isMemberSafe(_ text: String) -> Bool {
        engineWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil && MemberText.isSafe(text)
    }
}

// MARK: Moves (decision 5: 16 in the library, UGC first, at most two combined)

public enum SuiteMoves {
    /// Library filters: All, UGC, Cinematic, Energy, Subtle.
    public static let tags: [(id: String?, label: String)] = [(nil, "All"), ("ugc", "UGC"), ("cinematic", "Cinematic"), ("energy", "Energy"), ("subtle", "Subtle")]
    static let unmixable: Set<String> = ["static", "time", "aerial"]

    /// The library filtered by tag, UGC first (the catalog's order already is).
    public static func library(_ c: CameraCatalog, tag: String?) -> [SuiteLibraryMove] {
        let all = c.library.isEmpty ? c.moves.map { SuiteLibraryMove(id: $0.id, label: $0.label, tag: "", description: $0.description, category: $0.category) } : c.library
        guard let tag else { return all }
        return all.filter { $0.tag == tag }
    }

    static func category(_ id: String, _ c: CameraCatalog) -> String { c.move(id)?.category ?? c.libraryMove(id)?.category ?? "" }

    /// Two moves combine when they are of different kinds and neither is static, time or aerial (the catalog's `limits.mixPairs`).
    public static func canMix(_ a: String, _ b: String, _ c: CameraCatalog) -> Bool {
        let ca = category(a, c), cb = category(b, c)
        return a != b && ca != cb && !unmixable.contains(ca) && !unmixable.contains(cb)
    }

    /// Tapping a move in the library: off if it's on; on as move 1, or as move 2 when it mixes with move 1; otherwise it
    /// replaces the selection. Returns the new (move, mix) and a short note when something was dropped.
    public static func toggle(_ id: String, move: SuiteMove?, mix: SuiteMove?, catalog c: CameraCatalog) -> (move: SuiteMove?, mix: SuiteMove?, note: String?) {
        if move?.id == id { return (mix, nil, nil) }
        if mix?.id == id { return (move, nil, nil) }
        let fresh = SuiteMove(id: id, intensity: 0.5, speed: "normal")
        guard let m = move else { return (fresh, nil, nil) }
        if mix == nil && canMix(m.id, id, c) { return (m, fresh, nil) }
        if mix == nil { return (fresh, nil, "These two don't mix · \(c.libraryMove(id)?.label ?? id) replaces \(c.libraryMove(m.id)?.label ?? m.id)") }
        return (m, canMix(m.id, id, c) ? fresh : mix, canMix(m.id, id, c) ? nil : "Mix 2/2 · these two don't mix")
    }

    /// "Mix · 2 of 2".
    public static func mixCount(move: SuiteMove?, mix: SuiteMove?) -> Int { (move == nil ? 0 : 1) + (mix == nil ? 0 : 1) }

    /// "Dolly in · 60% + Rack focus".
    public static func line(move: SuiteMove?, mix: SuiteMove?, catalog c: CameraCatalog) -> String? {
        guard let m = move else { return nil }
        let name = { (id: String) in c.libraryMove(id)?.label ?? c.move(id)?.label ?? id }
        var s = "\(name(m.id)) · \(Int(((m.intensity ?? 0.5) * 100).rounded()))%"
        if let x = mix { s += " + \(name(x.id))" }
        return s
    }
}

// MARK: Camera summary ("Your camera")

public enum CameraSummary {
    /// The parts of "Your camera" in order: body, lens + focal, aperture, fps, light, palette, moves, height.
    public static func parts(_ spec: CameraSpec, _ c: CameraCatalog) -> [String] {
        let pick = { (list: [SuiteOption], id: String?) -> String? in id.flatMap { i in list.first { $0.id == i }?.title } }
        var out: [String] = []
        if let b = pick(c.bodies, spec.rig?.body) { out.append(b) }
        let lens = pick(c.lenses, spec.rig?.lens)
        let focal = spec.rig?.focalMm.map { "\(Int($0)) mm" }
        if lens != nil || focal != nil { out.append([lens, focal].compactMap { $0 }.joined(separator: " ")) }
        if let a = spec.rig?.aperture, let o = c.apertures.first(where: { $0.id == a }) { out.append(o.label.components(separatedBy: " · ").first ?? o.label) }
        if let f = spec.rig?.fps { out.append(f == "slowmo" ? "slow motion" : "\(f) fps") }
        if let l = pick(c.lighting, spec.lighting?.preset) { out.append(l) }
        if let p = pick(c.palettes, spec.palette?.preset) { out.append(p) }
        if let look = pick(c.looks, spec.rig?.look) { out.append(look) }
        if let m = SuiteMoves.line(move: spec.move, mix: spec.mix, catalog: c) { out.append(m) }
        if let h = spec.angle?.height, let o = c.heights.first(where: { $0.id == h }) { out.append(o.label) }
        return out
    }

    public static func line(_ spec: CameraSpec, _ c: CameraCatalog) -> String {
        let p = parts(spec, c)
        return p.isEmpty ? "Auto · the camera follows the scene" : p.joined(separator: " · ")
    }

    /// The renders to show for a spec, in bag order: body, lens, lighting, palette (only options that have one).
    public static func renders(_ spec: CameraSpec, _ c: CameraCatalog) -> [String] {
        let r = { (list: [SuiteOption], id: String?) -> String? in id.flatMap { i in list.first { $0.id == i }?.render } }
        return [r(c.bodies, spec.rig?.body), r(c.lenses, spec.rig?.lens), r(c.lighting, spec.lighting?.preset), r(c.palettes, spec.palette?.preset)].compactMap { $0 }
    }

    /// Starting from a preset: its spec, remembering which preset it was.
    public static func fromPreset(_ p: SuitePreset) -> CameraSpec {
        var s = p.spec
        s.mode = "preset"
        s.preset = p.id
        return s
    }
}

// MARK: Result pane (D10)

/// The 9:16 result pane's state across Shot, Swap and Storyboard.
public enum SuiteResultState: Equatable, Sendable {
    case empty
    case queued(position: Int?)
    case rendering(percent: Int, step: Int)
    case ready
    case failed(message: String)

    /// The job's state for the pane. `takes` are the job's takes (ready shows them).
    public static func of(_ job: Job?) -> SuiteResultState {
        guard let j = job else { return .empty }
        if j.isFailed { return .failed(message: j.failureLine) }
        if j.isDone { return .ready }
        if j.isQueued || j.isWaiting || (j.isRunning && j.progress <= 0 && j.queuePosition != nil) { return .queued(position: j.queuePosition) }
        let p = max(0, min(99, Int(j.progress.rounded())))
        return .rendering(percent: p, step: p < 34 ? 0 : p < 80 ? 1 : 2)
    }

    /// How much blur the picture keeps: heavy while queued, easing out over the last 30 % ("developing film").
    public var blur: Double {
        switch self {
        case .empty, .ready: return 0
        case .queued, .failed: return 22
        case .rendering(let p, _):
            let f = Double(p) / 100
            return f < 0.7 ? 22 : 22 * max(0, (1 - f) / 0.3)
        }
    }

    /// The three named steps (what's happening, never how).
    public static func steps(character: String?) -> [String] {
        [character.map { "Keyframe from \($0)’s sheet" } ?? "Keyframe from your scene", "Motion & camera", "Sharpen & finish"]
    }

    /// "#2 in line" / "Waiting to start".
    public var queueLine: String {
        if case .queued(let pos) = self, let p = pos, p > 1 { return "#\(p) in line" }
        return MemberText.waitingToStart
    }
}

// MARK: Storyboard (D8)

public struct StoryShot: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var prompt: String
    public var line: String
    public var moveId: String?
    public var seconds: Int
    public var jobId: String?

    public init(id: String = UUID().uuidString, title: String, prompt: String = "", line: String = "", moveId: String? = nil, seconds: Int = 4, jobId: String? = nil) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.line = line
        self.moveId = moveId
        self.seconds = seconds
        self.jobId = jobId
    }

    /// Ready to generate: it says what happens.
    public var isReady: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A storyboard: one cast, one look lock (camera), one quality; every shot is a suite shot.
public struct Storyboard: Codable, Hashable, Sendable {
    public var title: String
    public var idea: String
    public var castIds: [String]
    public var camera: CameraSpec
    public var quality: String
    public var shots: [StoryShot]

    public init(title: String = "New storyboard", idea: String = "", castIds: [String] = [], camera: CameraSpec = CameraSpec(), quality: String = "draft", shots: [StoryShot] = []) {
        self.title = title
        self.idea = idea
        self.castIds = castIds
        self.camera = camera
        self.quality = quality
        self.shots = shots
    }

    public var totalSeconds: Int { shots.reduce(0) { $0 + $1.seconds } }

    /// Shots to send on "Generate ready shots": ready and not made yet.
    public var toGenerate: [StoryShot] { shots.filter { $0.isReady && $0.jobId == nil } }

    /// The suite request for one shot: the board's cast lead, look lock and quality, the shot's own move.
    public func request(for s: StoryShot) -> ShotRequest {
        var cam = camera
        if let m = s.moveId { cam.move = SuiteMove(id: m, intensity: cam.move?.id == m ? cam.move?.intensity : 0.5, speed: "normal"); cam.mix = nil }
        let words = [s.prompt, s.line.isEmpty ? "" : "She says: \"\(s.line)\""].filter { !$0.isEmpty }.joined(separator: " ")
        return ShotRequest(title: "\(title) · \(s.title)", modelId: castIds.first, prompt: words, duration: s.seconds, quality: quality, camera: cam)
    }

    /// A simple shot list from an idea (no AI, no spending): one shot per sentence, up to 6.
    public static func shotList(from idea: String) -> [StoryShot] {
        let parts = idea.split(whereSeparator: { ".!?\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.prefix(6).enumerated().map { i, p in
            let words = p.split(separator: " ").prefix(5).joined(separator: " ")
            return StoryShot(title: words.isEmpty ? "Shot \(i + 1)" : words, prompt: p, seconds: 4)
        }
    }
}

// MARK: Layout (plans/ux-audit-2-mac.md)

public enum SuiteLayout {
    /// Columns for a grid of `count` equal tiles at least `minimum` wide in `width`: the fewest rows that fit, then the
    /// fewest empty places in the last row, so 6 tiles in room for 5 read 3 + 3 rather than 5 + 1. Unknown width (0) → 3.
    public static func balancedColumns(count: Int, width: Double, minimum: Double, spacing: Double) -> Int {
        guard count > 0 else { return 1 }
        guard width > 0 else { return min(count, 3) }
        let fit = max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
        if count <= fit { return count }
        var best = 1
        var bestKey = (Int.max, Int.max)
        for c in 1...fit {
            let rows = (count + c - 1) / c
            let empty = rows * c - count
            let key = (rows, empty)
            if key < bestKey {
                bestKey = key
                best = c
            }
        }
        return best
    }
}
