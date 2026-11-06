import Foundation

// Wording and list assembly for the Directed pane, the Direct with Claude panel and Settings → Connections
// (plans/mcp-bridge.md "Phase 2 · UI"). Pure, so it is tested on Linux and shared by every view.

public enum CameraText {
    /// "1.5 m", "0.4 m", "12 m".
    public static func metres(_ m: Double) -> String {
        let a = abs(m)
        return a >= 10 ? "\(Int(m.rounded())) m" : String(format: "%.1f m", m)
    }

    /// "6.0 s"
    public static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }

    /// The id chip: `cs_` + the first 4 characters after it, upper-case ("cs_7q2mxk…" → "cs_7Q2M").
    public static func idChip(_ id: String) -> String {
        let body = id.hasPrefix("cs_") ? String(id.dropFirst(3)) : id
        return "cs_" + String(body.prefix(4)).uppercased()
    }

    /// "9:16 · 24 fps · 6.0 s · rev 4"
    public static func stripMeta(_ s: CameraSession) -> String {
        "\(s.aspect) · \(fps(s.fps)) fps · \(seconds(s.durationSec)) · rev \(s.revision)"
    }

    static func fps(_ f: Double) -> String { f == f.rounded() ? String(Int(f)) : String(format: "%.2f", f) }

    /// "Mia, Noor" (or "No cast").
    public static func cast(_ s: CameraSession) -> String {
        s.characters.isEmpty ? "No cast" : s.characters.map(\.name).joined(separator: ", ")
    }

    /// The session's status pill: GUIDES READY / BLOCKING / DRAFTING / RENDERING / GENERATING / DONE / FAILED.
    public static func statusPill(_ s: CameraSession) -> (text: String, tone: CameraTone) {
        switch s.status {
        case "ready": return ("Guides ready", .good)
        case "rendering": return ("Rendering", .warn)
        case "generating": return ("Generating", .warn)
        case "done": return ("Done", .good)
        case "failed": return ("Failed", .bad)
        case "blocking": return CameraGuides.greyboxReady(s) ? ("Guides ready", .good) : ("Blocking", .neutral)
        default: return CameraGuides.greyboxReady(s) ? ("Guides ready", .good) : ("Drafting", .neutral)
        }
    }

    /// "2 min ago", "just now", "3 h ago", "2 d ago".
    public static func ago(_ ms: Double, now: Double) -> String {
        let s = max(0, (now - ms) / 1000)
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, Int((s / 60).rounded()))) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }

    /// "4.2 MB", "820 KB", "12 B".
    public static func size(_ bytes: Int64?) -> String? {
        guard let b = bytes else { return nil }
        if b >= 1_000_000_000 { return String(format: "%.1f GB", Double(b) / 1e9) }
        if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1e6) }
        if b >= 1000 { return "\(Int((Double(b) / 1000).rounded())) KB" }
        return "\(b) B"
    }

    /// Who made something: the asset/message `source`.
    public static func source(_ src: String?) -> String {
        switch src {
        case "relay": return "Mac app"
        case "mcp": return "your Claude"
        case "chat": return "chat"
        case "app": return "MUSE app"
        default: return "MUSE"
        }
    }

    /// The footer under the composer, with the draft's price and quality when there is a draft.
    public static func footer(_ draft: CameraShotDraft?) -> String {
        let base = "Claude never spends money. Generating waits for your tap"
        guard let usd = draft?.estimate?.usd else { return base + "." }
        let price = String(format: "$%.2f", usd)
        if let q = quality(draft?.request) { return "\(base) · est. \(price) at \(q)." }
        return "\(base) · est. \(price)."
    }

    /// The draft request's quality as shown ("HD", "Cinema", "Standard", "Draft").
    public static func quality(_ request: JSONValue?) -> String? {
        guard case .object(let o)? = request, case .string(let q)? = o["quality"] else { return nil }
        switch q {
        case "hd": return "HD"
        case "draft": return "Draft"
        case "standard": return "Standard"
        case "cinema": return "Cinema"
        default: return q.capitalized
        }
    }

    public static let emptyPlan = "No blocking yet · ask Claude in the chat, or block it in Blender from your Claude app."
    public static let dragNote = "Drag a token or the camera to adjust · Claude sees your edits"
    public static let rerenderMessage = "Re-render the guides for this revision."
    public static let composerPlaceholder = "Direct the shot… “lower the camera, lens 50”"
    public static let chatBusy = "Claude is still working on this shot"
    public static let directorUnavailable = "Direct with Claude isn't set up on the server yet (ANTHROPIC_API_KEY) · you can still direct from your own Claude app"

    /// What a chat error shows inline.
    public static func chatError(code: String, message: String) -> String {
        switch code {
        case "chat_busy": return chatBusy
        case "director_unavailable": return directorUnavailable
        case "offline": return "Can't reach MUSE · check your connection"
        default: return message
        }
    }
}

/// Dot / pill colours, mapped to the theme by the views.
public enum CameraTone: String, Sendable, Hashable {
    case good, warn, bad, neutral, off
}

// MARK: Status rows

public struct CameraStatusRow: Hashable, Sendable {
    public var title: String
    public var detail: String
    public var tone: CameraTone
    public init(title: String, detail: String, tone: CameraTone) {
        self.title = title
        self.detail = detail
        self.tone = tone
    }
}

public enum CameraStatus {
    /// The owner's own Claude app counts as connected for 5 minutes after its last MCP call.
    public static let appWindowMs = 5.0 * 60 * 1000

    /// Claude session · Blender <version> · Renders.
    /// - inAppChat: from GET /v1/connections (nil = not known yet: assume available).
    /// - busy: a chat turn is streaming here (also counts when the server says chatBusy).
    /// - machine: this Mac's name ("Mac Studio"); "Mac" if unknown.
    public static func rows(_ s: CameraSession, inAppChat: Bool?, busy: Bool, now: Double, machine: String? = nil, thisMac: Bool = false) -> [CameraStatusRow] {
        [claude(s, inAppChat: inAppChat, busy: busy, now: now), blender(s.relay, machine: machine, thisMac: thisMac), renders(s)]
    }

    /// The Blender row's "offline" on the Mac app itself.
    public static let offlineHere = "Relay off · turn it on in Connections"

    public static func claude(_ s: CameraSession, inAppChat: Bool?, busy: Bool, now: Double) -> CameraStatusRow {
        let t = "Claude session"
        if busy || s.claude?.chatBusy == true { return CameraStatusRow(title: t, detail: "Working…", tone: .warn) }
        if let seen = s.claude?.appLastSeenAt, now - seen < appWindowMs { return CameraStatusRow(title: t, detail: "Connected · your Claude app", tone: .good) }
        if inAppChat == false { return CameraStatusRow(title: t, detail: "Not set up", tone: .off) }
        return CameraStatusRow(title: t, detail: "In MUSE (this chat)", tone: .good)
    }

    /// - thisMac: the row is drawn by the Mac app itself, so "Mac app offline" would contradict the screen it's on: it says the
    ///   relay is off instead (it's switched on in Connections).
    public static func blender(_ r: CameraRelayPresence?, machine: String? = nil, thisMac: Bool = false) -> CameraStatusRow {
        let title = r?.addonVersion.map { "Blender \($0)" } ?? "Blender"
        guard let r, r.online else { return CameraStatusRow(title: title, detail: thisMac ? offlineHere : "Mac app offline", tone: .off) }
        if r.blender { return CameraStatusRow(title: title, detail: "\(machine ?? "Mac") · localhost", tone: .good) }
        return CameraStatusRow(title: title, detail: "Mac app online · Blender not connected", tone: .warn)
    }

    public static func renders(_ s: CameraSession) -> CameraStatusRow {
        if let up = uploading(s.assets) { return CameraStatusRow(title: "Renders", detail: "Uploading \(up.n) of \(up.m) to MUSE", tone: .warn) }
        if CameraGuides.greyboxReady(s) { return CameraStatusRow(title: "Renders", detail: "Guides ready", tone: .good) }
        return CameraStatusRow(title: "Renders", detail: "None yet", tone: .off)
    }

    /// While assets are pending: the batch is every asset made from 2 minutes before the oldest pending one on (one render's
    /// files arrive together); n = the one uploading now (1-based).
    public static func uploading(_ assets: [CameraAsset]) -> (n: Int, m: Int)? {
        let pending = assets.filter { $0.state == "pending" }
        guard !pending.isEmpty else { return nil }
        let since = (pending.compactMap(\.createdAt).min() ?? 0) - 120_000
        let batch = assets.filter { ($0.createdAt ?? since) >= since }
        let ready = batch.filter { $0.state == "ready" }.count
        return (min(batch.count, ready + 1), batch.count)
    }

    /// `● LIVE` while the event stream is connected.
    public static func livePill(_ connected: Bool) -> String? { connected ? "● Live" : nil }
}

// MARK: Timeline

public struct TimelineSpan: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var label: String
    /// A muted span (a character holding before their first key).
    public var muted: Bool
    /// An orbit span is tinted (accent) like the design.
    public var accent: Bool
    public init(start: Double, end: Double, label: String, muted: Bool = false, accent: Bool = false) {
        self.start = start
        self.end = end
        self.label = label
        self.muted = muted
        self.accent = accent
    }
}

public struct TimelineTrack: Hashable, Sendable, Identifiable {
    /// "camera", a modelId, or "cuts".
    public var id: String
    /// Upper-case: "CAMERA", "MIA", "CUTS".
    public var name: String
    public var keys: [Double]
    public var spans: [TimelineSpan]
    public init(id: String, name: String, keys: [Double], spans: [TimelineSpan]) {
        self.id = id
        self.name = name
        self.keys = keys
        self.spans = spans
    }
}

public enum CameraTimeline {
    /// How the camera moves from one key to the next: "orbit 90°" for a turn around the look-at of 15° or more,
    /// else "push 0.4 m" / "pull 0.4 m" (toward / away from the look-at), "track 1.2 m" (sideways), "rise 0.5 m" / "drop 0.5 m",
    /// "zoom 35→50 mm", or "hold"; non-linear eases add " · ease in-out".
    public static func cameraMove(_ a: CamKey, _ b: CamKey, targetA: Vec3, targetB: Vec3) -> (label: String, orbit: Bool) {
        let va = a.position - targetA, vb = b.position - targetB
        var turn = 0.0
        if va.planLength > 1e-3, vb.planLength > 1e-3 {
            turn = (atan2(vb.y, vb.x) - atan2(va.y, va.x)) * 180 / .pi
            while turn > 180 { turn -= 360 }
            while turn < -180 { turn += 360 }
        }
        if abs(turn) >= 15 { return ("orbit \(Int((abs(turn) / 5).rounded() * 5))°", true) }
        let ease = CameraEase.label(a.ease).map { " · \($0)" } ?? ""
        let moved = b.position - a.position
        let dz = moved.z, planMove = moved.planLength
        let toward = va.length - vb.length
        let fa = a.focalMm ?? CameraMotion.defaultFocal, fb = b.focalMm ?? fa
        if planMove < 0.05 && abs(dz) < 0.05 {
            if abs(fb - fa) >= 1 { return ("zoom \(Int(fa.rounded()))→\(Int(fb.rounded())) mm\(ease)", false) }
            return ("hold", false)
        }
        if abs(dz) > planMove { return ("\(dz > 0 ? "rise" : "drop") \(CameraText.metres(abs(dz)))\(ease)", false) }
        if abs(toward) >= planMove * 0.5 { return ("\(toward > 0 ? "push" : "pull") \(CameraText.metres(abs(toward)))\(ease)", false) }
        return ("track \(CameraText.metres(planMove))\(ease)", false)
    }

    /// CAMERA, one track per character (cast order), CUTS.
    public static func tracks(_ s: CameraSession) -> [TimelineTrack] {
        var out: [TimelineTrack] = []
        let ck = s.cameraPath?.keyframes ?? []
        let tg = CameraMotion.targets(ck)
        var camSpans: [TimelineSpan] = []
        if ck.count > 1 {
            for i in 0..<(ck.count - 1) where ck[i + 1].t > ck[i].t {
                let m = cameraMove(ck[i], ck[i + 1], targetA: tg[i], targetB: tg[i + 1])
                camSpans.append(TimelineSpan(start: ck[i].t, end: ck[i + 1].t, label: m.label, accent: m.orbit))
            }
        }
        out.append(TimelineTrack(id: "camera", name: "CAMERA", keys: ck.map(\.t), spans: camSpans))
        let tracks = s.blocking?.characters ?? []
        let ordered = s.characters.compactMap { c in tracks.first { $0.modelId == c.modelId } } + tracks.filter { t in !s.characters.contains { $0.modelId == t.modelId } }
        for tr in ordered {
            let name = s.characters.first { $0.modelId == tr.modelId }?.name ?? "Character"
            let keys = tr.keyframes
            var spans: [TimelineSpan] = []
            if let f = keys.first, f.t > 0.05 { spans.append(TimelineSpan(start: 0, end: f.t, label: tr.note ?? "holds", muted: true)) }
            for (i, k) in keys.enumerated() {
                let end = i + 1 < keys.count ? keys[i + 1].t : s.durationSec
                guard end > k.t else { continue }
                var label = k.action ?? ""
                if label.isEmpty, i + 1 < keys.count {
                    let d = (keys[i + 1].position - k.position).planLength
                    label = d >= 0.1 ? String(format: "walk · %.1f m/s", d / (end - k.t)) : "holds"
                }
                spans.append(TimelineSpan(start: k.t, end: end, label: label, muted: label == "holds"))
            }
            out.append(TimelineTrack(id: tr.modelId, name: name.uppercased(), keys: keys.map(\.t), spans: spans))
        }
        out.append(TimelineTrack(id: "cuts", name: "CUTS", keys: s.cameraPath?.cuts ?? [], spans: []))
        return out
    }

    /// The playhead chip: "2.4 s".
    public static func playheadLabel(_ t: Double) -> String { CameraText.seconds(t) }
    /// "END 6.0 S" chip text (upper-cased by the view in Editorial).
    public static func endLabel(_ d: Double) -> String { "end \(CameraText.seconds(d))" }

    /// x (points) → seconds on a timeline `width` wide, clamped to 0…duration, snapped to frames.
    public static func time(x: Double, width: Double, duration: Double, fps: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        let t = min(max(0, x / width * duration), duration)
        return fps > 0 ? (t * fps).rounded() / fps : t
    }
}

// MARK: Transcript

/// A tool step chip: "PLACE_CHARACTER ×2", red outline when one failed.
public struct ToolChip: Hashable, Sendable {
    public var name: String
    public var count: Int
    public var ok: Bool
    public var text: String { count > 1 ? "\(name) ×\(count)" : name }
    public init(name: String, count: Int = 1, ok: Bool = true) {
        self.name = name
        self.count = count
        self.ok = ok
    }

    /// "blender_place_character" → "PLACE_CHARACTER".
    public static func display(_ tool: String) -> String {
        (tool.hasPrefix("blender_") ? String(tool.dropFirst(8)) : tool).uppercased()
    }

    /// Consecutive steps of the same tool collapse into one chip.
    public static func collapse(_ steps: [CameraToolStep]) -> [ToolChip] {
        var out: [ToolChip] = []
        for s in steps {
            let n = display(s.name)
            if var last = out.last, last.name == n {
                last.count += 1
                last.ok = last.ok && s.ok
                out[out.count - 1] = last
            } else {
                out.append(ToolChip(name: n, ok: s.ok))
            }
        }
        return out
    }
}

public enum TranscriptItem: Hashable, Sendable, Identifiable {
    /// A user message: "YOU · MAC APP" / "YOU · PHONE" / "YOU".
    case user(id: String, label: String, text: String)
    /// Claude's run between two user messages: its texts and its tool steps (collapsed), plus a note from the app.
    case claude(id: String, label: String, text: String, chips: [ToolChip])

    public var id: String {
        switch self {
        case .user(let id, _, _), .claude(let id, _, _, _): return id
        }
    }
}

public enum CameraTranscript {
    /// - devices: message id → "MAC APP" / "PHONE" for messages whose sending device is known (the ones sent from this Mac).
    public static func items(_ messages: [CameraMessage], devices: [String: String] = [:]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var texts: [String] = [], steps: [CameraToolStep] = [], runId: String?, label = "Claude"
        func flush() {
            if let id = runId, !(texts.isEmpty && steps.isEmpty) {
                out.append(.claude(id: id, label: label, text: texts.joined(separator: "\n\n"), chips: ToolChip.collapse(steps)))
            }
            texts = []; steps = []; runId = nil; label = "Claude"
        }
        for m in messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            switch m.role {
            case "user":
                flush()
                if m.source == "chat" || m.source == "app" && devices[m.id] != nil {
                    let dev = devices[m.id].map { "You · \($0)" } ?? "You"
                    out.append(.user(id: m.id, label: dev, text: m.text))
                } else if m.source == "app" {
                    // A note left from the app (not a chat turn): Claude reads it on its next look.
                    out.append(.user(id: m.id, label: "You · note", text: m.text))
                } else {
                    out.append(.user(id: m.id, label: "You", text: m.text))
                }
            case "tool":
                if runId == nil { runId = m.id }
                if m.source == "mcp" { label = "Your Claude" }
                if let t = m.tool { steps.append(t) }
            default:
                if runId == nil { runId = m.id }
                if m.source == "mcp" { label = "Your Claude" }
                let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { texts.append(t) }
            }
        }
        flush()
        return out
    }
}

// MARK: Working strip

/// What the chat shows while a turn streams, built from its ChatEvents.
public struct ChatTurn: Hashable, Sendable {
    public var startRevision: Int
    public var text = ""
    public var stepsSeen = 0
    public var stepsDone = 0
    public var lastStep: String?
    public var waitingForBlender = false
    public var finished = false
    public var error: String?
    public var errorCode: String?
    /// The last tool steps of this turn, for the live chips before the transcript catches up.
    public var steps: [CameraToolStep] = []
    private var running: Set<String> = []

    public init(startRevision: Int) { self.startRevision = startRevision }

    public mutating func apply(_ e: ChatEvent) {
        switch e {
        case .text(let d): text += d
        case .tool(let id, let name, let status, let summary):
            if status == "running" {
                if !running.contains(id) { running.insert(id); stepsSeen += 1 }
                lastStep = summary ?? ToolChip.display(name).lowercased().replacingOccurrences(of: "_", with: " ")
            } else {
                if !running.contains(id) { stepsSeen += 1 } else { running.remove(id) }
                stepsDone += 1
                steps.append(CameraToolStep(name: name, ok: status != "error", summary: summary))
                if let summary { lastStep = summary }
            }
            waitingForBlender = false
        case .waiting: waitingForBlender = true
        case .message: break
        case .done: finished = true
        case .error(let code, let message):
            finished = true
            errorCode = code
            error = CameraText.chatError(code: code, message: message)
        }
    }

    /// "CLAUDE · WORKING ON REV 5"
    public var title: String { "Claude · working on rev \(startRevision + 1)" }

    /// The quote under the title: the last step, else the last line of text.
    public var quote: String? {
        if waitingForBlender { return "↳ Waiting for Blender on your Mac" + (lastStep.map { " · \($0)" } ?? "") }
        if let s = lastStep { return "↳ \(s)" }
        let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line.flatMap { $0.isEmpty ? nil : "↳ “\(String($0.prefix(140)))”" }
    }

    /// Steps done / steps seen (0 before the first step). `renderProgress` (0…1) wins when the Mac reports one.
    public func progress(renderProgress: Double? = nil) -> Double {
        if let r = renderProgress { return min(1, max(0, r)) }
        return stepsSeen == 0 ? 0 : min(1, Double(stepsDone) / Double(stepsSeen))
    }

    public func percent(renderProgress: Double? = nil) -> String { "\(Int((progress(renderProgress: renderProgress) * 100).rounded()))%" }
}

// MARK: Guides

public struct GuideItem: Hashable, Sendable, Identifiable {
    public var asset: CameraAsset
    /// "GREYBOX", "DEPTH", "START", "camera.json", ".blend"…
    public var label: String
    public var isVideo: Bool
    public var isImage: Bool
    public var size: String?
    public var source: String
    public var id: String { asset.id }
}

public enum CameraGuides {
    public static let order = ["greybox", "depth", "pose", "tracks", "keyframe_start", "keyframe_mid", "keyframe_end", "camera_json", "characters_json", "blend", "preview", "still"]

    public static func label(_ kind: String) -> String {
        switch kind {
        case "keyframe_start": return "START"
        case "keyframe_mid": return "MID"
        case "keyframe_end": return "END"
        case "camera_json": return "camera.json"
        case "characters_json": return "characters.json"
        case "blend": return ".blend"
        default: return kind.uppercased()
        }
    }

    public static func greyboxReady(_ s: CameraSession) -> Bool { s.assets.contains { $0.kind == "greybox" && $0.state == "ready" } }

    /// Ready assets in the design's order, newest first within a kind; `latestOnly` keeps one per kind (the one the Shot uses).
    public static func items(_ assets: [CameraAsset], latestOnly: Bool = false) -> [GuideItem] {
        let ready = assets.filter { $0.state == "ready" }
        var out: [GuideItem] = []
        let kinds = order + Set(ready.map(\.kind)).subtracting(order).sorted()
        for k in kinds {
            var of = ready.filter { $0.kind == k }.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
            if latestOnly { of = Array(of.prefix(1)) }
            for a in of {
                let ct = a.contentType ?? ""
                let video = ct.hasPrefix("video/") || ["greybox", "depth", "pose", "tracks"].contains(k)
                let image = ct.hasPrefix("image/") || k.hasPrefix("keyframe_") || k == "preview" || k == "still"
                out.append(GuideItem(asset: a, label: label(k), isVideo: video, isImage: image && !video, size: CameraText.size(a.bytes), source: CameraText.source(a.source)))
            }
        }
        return out
    }

    /// The chat's "Guides ready · rev N" card: greybox, depth, pose and START/MID/END (whatever exists).
    public static func card(_ s: CameraSession) -> [GuideItem]? {
        guard greyboxReady(s) else { return nil }
        let kinds = ["greybox", "depth", "pose", "keyframe_start", "keyframe_mid", "keyframe_end"]
        return items(s.assets, latestOnly: true).filter { kinds.contains($0.asset.kind) }
    }

    /// Camera view: the newest still nearest the playhead (keyframe START at 0, MID at the middle, END at the end), else the newest preview.
    public static func still(_ s: CameraSession, at t: Double) -> CameraAsset? {
        let ready = s.assets.filter { $0.state == "ready" && $0.url != nil }
        let times: [String: Double] = ["keyframe_start": 0, "keyframe_mid": s.durationSec / 2, "keyframe_end": s.durationSec]
        let keys = ready.filter { times[$0.kind] != nil }
        if let best = keys.min(by: { a, b in
            let da = abs(times[a.kind]! - t), db = abs(times[b.kind]! - t)
            return da != db ? da < db : (a.createdAt ?? 0) > (b.createdAt ?? 0)
        }) { return best }
        return ready.filter { $0.kind == "preview" || $0.kind == "still" }.max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }
}

// MARK: History

public struct HistoryEntry: Hashable, Sendable, Identifiable {
    public var id: String
    /// "rev 4 · Claude (chat) · set camera path and blocking · 2 min ago"
    public var title: String
    public var detail: String?
    public var at: Double
    public var ok: Bool
}

public enum CameraHistory {
    static func who(_ source: String) -> String {
        switch source {
        case "chat": return "Claude (chat)"
        case "mcp": return "Your Claude"
        case "relay": return "Mac app"
        default: return "You"
        }
    }

    /// Newest first: tool steps and notes from the transcript plus ready assets, consecutive items of one source within
    /// 2 minutes grouped into one line; the newest line carries the current revision.
    public static func entries(_ s: CameraSession, now: Double) -> [HistoryEntry] {
        struct Raw { var id: String; var at: Double; var source: String; var what: String; var ok: Bool; var note: String? }
        var raw: [Raw] = []
        for m in s.messages ?? [] {
            if m.role == "tool", let t = m.tool {
                raw.append(Raw(id: m.id, at: m.createdAt, source: m.source, what: ToolChip.display(t.name).lowercased().replacingOccurrences(of: "_", with: " "), ok: t.ok, note: t.summary))
            } else if m.role == "user", m.source == "app" {
                raw.append(Raw(id: m.id, at: m.createdAt, source: "app", what: "note", ok: true, note: m.text))
            }
        }
        for a in s.assets where a.state == "ready" {
            raw.append(Raw(id: a.id, at: a.createdAt ?? 0, source: a.source ?? "app", what: "\(CameraGuides.label(a.kind).lowercased()) ready", ok: true, note: nil))
        }
        raw.sort { $0.at > $1.at }
        var out: [HistoryEntry] = []
        var group: [Raw] = []
        func flush() {
            guard let first = group.first else { return }
            var whats: [String] = []
            for r in group.reversed() where !whats.contains(r.what) { whats.append(r.what) }
            let rev = out.isEmpty ? "rev \(s.revision) · " : ""
            let notes = group.compactMap(\.note)
            out.append(HistoryEntry(id: first.id, title: "\(rev)\(who(first.source)) · \(join(whats)) · \(CameraText.ago(first.at, now: now))",
                                    detail: notes.isEmpty ? nil : notes.reversed().joined(separator: " · "), at: first.at, ok: group.allSatisfy(\.ok)))
            group = []
        }
        for r in raw {
            if let last = group.last, last.source == r.source, last.at - r.at <= 120_000 { group.append(r) } else { flush(); group = [r] }
        }
        flush()
        return out
    }

    /// "a, b and c"
    static func join(_ xs: [String]) -> String {
        if xs.count <= 1 { return xs.first ?? "" }
        return xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }
}

// MARK: Session lists and live events

public enum CameraSessions {
    /// Applies a live event to the sessions list (newest change first). Messages already loaded stay when the event has none.
    public static func apply(_ list: inout [CameraSession], _ e: CameraLiveEvent) {
        switch e {
        case .upsert(var s):
            if let i = list.firstIndex(where: { $0.id == s.id }) {
                if s.messages == nil { s.messages = list[i].messages }
                list.remove(at: i)
            }
            let at = list.firstIndex { $0.updatedAt <= s.updatedAt } ?? list.count
            list.insert(s, at: at)
        case .delete(let id):
            list.removeAll { $0.id == id }
        case .message(let sid, let m):
            guard let i = list.firstIndex(where: { $0.id == sid }) else { return }
            var ms = list[i].messages ?? []
            if let j = ms.firstIndex(where: { $0.id == m.id }) { ms[j] = m } else { ms.append(m) }
            list[i].messages = ms
        case .asset(let sid, let a):
            guard let i = list.firstIndex(where: { $0.id == sid }) else { return }
            if let j = list[i].assets.firstIndex(where: { $0.id == a.id }) { list[i].assets[j] = a } else { list[i].assets.append(a) }
        case .relay(let r):
            for i in list.indices { list[i].relay = r }
        case .connected, .disconnected:
            break
        }
    }

    /// The JSON CameraSpec handed to the Shot builder ("Apply to shot"): the draft request's `camera` (mode directed, guide video,
    /// keyframes, cameraSessionId). nil when the draft has no camera.
    public static func handoff(_ draft: CameraShotDraft?) -> String? {
        guard case .object(let req)? = draft?.request, let cam = req["camera"], case .object = cam else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(cam)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Whether the draft's camera carries a guide video (else the shot runs without Blender guides).
    public static func handoffHasGuide(_ draft: CameraShotDraft?) -> Bool {
        guard case .object(let req)? = draft?.request, case .object(let cam)? = req["camera"], case .object? = cam["guide"] else { return false }
        return true
    }
}

// MARK: Connections

public enum CameraConnectionsText {
    public static func claudeCode(url: String, token: String?) -> String {
        "claude mcp add --transport http muse \(url) --header \"Authorization: Bearer \(token ?? "muse_pat_…")\""
    }

    public static func claudeCodeBlender() -> String {
        "claude mcp add blender -e DISABLE_TELEMETRY=true -e BLENDER_MCP_SAFE_MODE=1 -- uvx mcp-for-blender"
    }

    public static func claudeDesktop(url: String, token: String?) -> String {
        """
        {
          "mcpServers": {
            "blender": { "command": "uvx", "args": ["mcp-for-blender"], "env": { "DISABLE_TELEMETRY": "true", "BLENDER_MCP_SAFE_MODE": "1" } },
            "muse": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(url)", "--header", "Authorization:${MUSE_AUTH}"],
              "env": { "MUSE_AUTH": "Bearer \(token ?? "muse_pat_…")" }
            }
          }
        }
        """
    }

    /// "muse_pat_ab12…"
    public static func prefix(_ t: McpToken) -> String { t.prefix + "…" }

    /// "Created 2 d ago · last used 3 min ago" / "· never used".
    public static func tokenLine(_ t: McpToken, now: Double) -> String {
        var s = "Created \(CameraText.ago(t.createdAt, now: now))"
        s += t.lastUsedAt.map { " · last used \(CameraText.ago($0, now: now))" } ?? " · never used"
        if let e = t.expiresAt { s += e > now ? " · expires in \(max(1, Int(((e - now) / 86_400_000).rounded(.up)))) d" : " · expired" }
        return s
    }

    public static let installSteps = [
        "Install Blender (3.0+) and uv: curl -LsSf https://astral.sh/uv/install.sh | sh",
        "uvx mcp-for-blender install-addon, then enable “Interface: MCP for Blender” in Blender → Preferences → Add-ons",
        "In the 3D viewport sidebar (N) → MCP for Blender → Connect (localhost:9876)",
    ]

    public static func inAppChat(_ on: Bool) -> String { on ? "Direct with Claude in MUSE is available" : "Needs ANTHROPIC_API_KEY on the server" }
}
