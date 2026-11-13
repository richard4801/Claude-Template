import Foundation

/// Live suggestion chips (owner request 2026-11-12): the chips over Claude's input follow what is on screen and what just
/// happened. The server holds the rules (server/api/src/claude/suggest.ts, GET v1/claude/suggestions); the app tells it
/// what only the app knows (the selection, the platform view, unsaved changes, a clip just imported, and the open edit as
/// it is on screen now, which the server's copy can lag), and keeps the chips' order steady while they change.
public struct ClaudeSuggestQuery: Hashable, Sendable {
    public var page: String?
    public var tool: String?
    /// The page's open ids (sessionId, assistId, takeId, referenceId) and the chat (for follow-ups on Claude's last reply).
    public var ids: [String: String] = [:]
    public var chatId: String?
    // The Edit page, as the app sees it.
    public var selKind: String?
    public var selId: String?
    /// Platform view ("tiktok", "reels", "shorts"); nil = none.
    public var view: String?
    public var unsaved = false
    public var imported: String?
    public var importedId: String?
    public var clips: Int?
    public var captions: Bool?
    public var musicId: String?
    public var beats: Bool?
    public var blank: Bool?
    /// Text ids outside the platform view's safe area.
    public var offSafe: [String] = []

    public init(page: ClaudePage?, chatId: String? = nil) {
        self.page = page?.name
        self.tool = page?.tool
        self.ids = (page?.ids ?? [:]).filter { ["sessionId", "assistId", "takeId", "referenceId"].contains($0.key) }
        self.chatId = chatId
    }

    /// These facts on another page and chat (the Edit page's facts are kept while its page is the one shown).
    public func on(_ page: ClaudePage?, chatId: String?) -> ClaudeSuggestQuery {
        var q = self
        let fresh = ClaudeSuggestQuery(page: page, chatId: chatId)
        q.page = fresh.page; q.tool = fresh.tool; q.ids = fresh.ids; q.chatId = fresh.chatId
        return q
    }

    /// The query string (sorted, so the same facts always make the same request). Ids that aren't plain are left out.
    public var queryString: String {
        var q: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, Self.plain(v) { q.append((k, v)) } }
        add("page", page); add("tool", tool)
        for (k, v) in ids { add(k, v) }
        add("chatId", chatId); add("selKind", selKind); add("selId", selId); add("view", view)
        if unsaved { q.append(("unsaved", "1")) }
        add("imported", imported); add("importedId", importedId)
        if let clips { q.append(("clips", String(max(0, min(9999, clips))))) }
        if let captions { q.append(("captions", captions ? "1" : "0")) }
        add("musicId", musicId)
        if let beats { q.append(("beats", beats ? "1" : "0")) }
        if let blank { q.append(("blank", blank ? "1" : "0")) }
        let off = offSafe.filter(Self.plain).prefix(20)
        if !off.isEmpty { q.append(("offSafe", off.joined(separator: ","))) }
        return q.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func plain(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 80 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The open edit's facts: main clips, captions, the music and its marked beats, the selection, the platform view and
    /// the text outside its safe area (the preview's red box, `EditSafeBox.zone`; nil or the box off = no view), unsaved
    /// changes. Prod's platform preview replaced EditSuite.SafeArea with EditPreview (bundle-10 port).
    public mutating func edit(project p: EditV2.Project, selection: String?, preview: EditPreview?, unsaved: Bool) {
        var clips = 0, captions = false, music: String?, beats = false, texts: [(String, Double, Double)] = []
        var kinds: [String: EditV2.TrackKind] = [:]
        for t in p.tracks {
            if t.kind == .caption, let c = t.caption, !c.words.isEmpty { captions = true }
            for it in t.items {
                kinds[it.id] = t.kind
                if t.kind == .main { clips += 1 }
                if t.kind == .music, music == nil, case .audio(let a) = it { music = a.id; beats = !(a.strongBeats ?? []).isEmpty }
                if t.kind == .text, case .text(let x) = it, x.pin == nil { texts.append((x.id, x.transform?.x ?? 0.5, x.transform?.y ?? 0.5)) }
            }
        }
        self.clips = clips
        self.captions = captions
        self.musicId = music
        self.beats = music == nil ? nil : beats
        self.blank = p.isBlank && clips == 0
        self.unsaved = unsaved
        let shown = preview.flatMap { $0.safeArea ? $0.resolved(width: p.canvas.width, height: p.canvas.height) : nil }
        self.view = shown?.view.rawValue
        if let s = shown, let i = EditSafeBox.zone(s, width: p.canvas.width, height: p.canvas.height) {
            offSafe = texts.filter { $0.1 < i.left || $0.1 > 1 - i.right || $0.2 < i.top || $0.2 > 1 - i.bottom }.map { $0.0 }
        } else { offSafe = [] }
        if let sel = selection, let k = kinds[sel] {
            selId = sel
            switch k {
            case .main, .video: selKind = "video"
            case .image: selKind = "image"
            case .text: selKind = "text"
            case .music, .voice, .sfx: selKind = "audio"
            case .caption: selKind = "caption"
            case .adjust: selKind = nil; selId = nil
            }
        } else { selKind = nil; selId = nil }
    }
}

public extension ClaudeChip {
    /// Steady chips: a chip that stays keeps its place, new ones take the freed places in the server's order, so the row
    /// doesn't jump about when one chip changes.
    static func steady(old: [ClaudeChip], new: [ClaudeChip]) -> [ClaudeChip] {
        guard !old.isEmpty else { return new }
        var rest = new.filter { n in !old.contains { $0.label == n.label } }
        var out: [ClaudeChip] = []
        for o in old {
            if let n = new.first(where: { $0.label == o.label }) { out.append(n) }
            else if !rest.isEmpty { out.append(rest.removeFirst()) }
        }
        out.append(contentsOf: rest)
        return Array(out.prefix(new.count))
    }
}

/// GET v1/claude/suggestions → `{chips, key}`.
public struct ClaudeSuggestionList: Codable, Hashable, Sendable {
    public var chips: [ClaudeChip]
    public var key: String?
}

public extension ClaudeChip {
    /// Demo mode and tests only (FakeClaudeAPI): a small copy of the server's Edit rules, same labels and prompts. The
    /// server's rules (suggest.ts) are the real ones; this only lets review mode show the row changing without a server.
    static func demoSuggestions(_ q: ClaudeSuggestQuery) -> [ClaudeChip] {
        guard q.page == "edit", let clips = q.clips else { return fallback(page: q.page, tool: q.tool) }
        var out: [ClaudeChip] = []
        if let v = q.view, !q.offSafe.isEmpty, let s = PreviewSkin(rawValue: v) {
            out.append(ClaudeChip(label: "Fix the safe area", prompt: "In the \(s.label) view, my text \(q.offSafe.prefix(6).joined(separator: ", ")) sits outside the safe area (under the app's buttons). Move it inside the safe area with apply_edit_ops, keeping its look.", icon: "frame-corners"))
        }
        if q.blank == true, clips == 0 {
            out.append(ClaudeChip(label: "Find takes to use", prompt: "This edit is empty. Find takes in my library that would work for it (library_find) and suggest which to add.", icon: "magnifying-glass"))
        } else {
            if q.captions != true, clips > 0 { out.append(ClaudeChip(label: "Add captions", prompt: "Add captions to this edit (auto_captions). Tell me the price first if it isn't free.", icon: "text-aa")) }
            if let m = q.musicId, q.beats != true { out.append(ClaudeChip(label: "Cut to the beat", prompt: "Find the beats in my music \(m) (detect_beats) and cut the clips to them (apply_edit_ops).", icon: "scissors")) }
            if let m = q.musicId, q.beats == true { out.append(ClaudeChip(label: "Cut to the drop", prompt: "Cut my edit so its biggest moment lands on the drop: use the strong beats marked on \(m) and the action peaks (find_action_peaks), then apply_edit_ops.", icon: "lightning")) }
            if q.musicId == nil, q.captions != true, clips > 0 { out.append(ClaudeChip(label: "Cut the silences", prompt: "Cut the quiet parts out of my main video (cut_silences, free). Tell me how much shorter it is.", icon: "waveform")) }
            if q.captions == true { out.append(ClaudeChip(label: "Restyle the captions", prompt: "Pick a caption style that fits this edit (list_caption_styles) and apply it (apply_edit_ops). Tell me which one and why.", icon: "text-aa")) }
            out.append(ClaudeChip(label: "Watch my edit", prompt: "Watch my edit and tell me what to fix.", icon: "play-circle"))
        }
        // Like the server: with the edit's facts known, only the general chips fill (never "Cut to the beat" with no music).
        for c in fallback(page: nil, tool: nil) where out.count < 3 && !out.contains(where: { $0.label == c.label }) { out.append(c) }
        return Array(out.prefix(3))
    }
}
