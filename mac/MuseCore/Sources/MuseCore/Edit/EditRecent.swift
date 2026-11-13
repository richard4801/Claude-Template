import Foundation

// Continue a draft (owner, 2026-11-12): clicking Edit reopens the last edit exactly where it was left. The owner's edits live
// on the server (edit sessions; the project is pushed on every change) and each session also keeps where the editor was left
// (`EditSessionView`, POST …/{id}/view), so another device continues at the same place. Members' editors are local: this Mac
// keeps their last edits (project and view) in `EditRecentStore`. Pure, so the rules are tested on Linux.

/// Where the editor was left: playhead, zoom, tabs, platform view, the edit's name. `at` (ms) is set by the server or the store.
public struct EditSessionView: Codable, Hashable, Sendable {
    public var playhead: Double?
    public var zoom: Double?
    /// Inspector tab (`EditSuite.InspectorTab` raw value).
    public var tab: String?
    /// Media bin tab (`EditSuite.BinTab` raw value).
    public var binTab: String?
    /// timeline | captions
    public var mode: String?
    public var selection: String?
    /// The platform preview: a `PreviewSkin` raw value with the red box on; "off" (or the server's null) = the box off.
    public var safeArea: String?
    public var title: String?
    public var at: Double?

    public init(playhead: Double? = nil, zoom: Double? = nil, tab: String? = nil, binTab: String? = nil, mode: String? = nil,
                selection: String? = nil, safeArea: String? = nil, title: String? = nil, at: Double? = nil) {
        self.playhead = playhead; self.zoom = zoom; self.tab = tab; self.binTab = binTab; self.mode = mode; self.selection = selection
        self.safeArea = safeArea; self.title = title; self.at = at
    }

    enum CodingKeys: String, CodingKey { case playhead, zoom, tab, binTab, mode, selection, safeArea, title, at }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        playhead = try? c.decodeIfPresent(Double.self, forKey: .playhead)
        zoom = try? c.decodeIfPresent(Double.self, forKey: .zoom)
        tab = try? c.decodeIfPresent(String.self, forKey: .tab)
        binTab = try? c.decodeIfPresent(String.self, forKey: .binTab)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
        selection = try? c.decodeIfPresent(String.self, forKey: .selection)
        // The server keeps "off" as null: a present null means off, a missing key means "not saved".
        if c.contains(.safeArea), (try? c.decodeNil(forKey: .safeArea)) == true { safeArea = "off" }
        else { safeArea = try? c.decodeIfPresent(String.self, forKey: .safeArea) }
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        at = try? c.decodeIfPresent(Double.self, forKey: .at)
    }

    /// The same place (the time it was saved aside).
    public func samePlace(_ o: EditSessionView) -> Bool {
        var a = self, b = o
        a.at = nil; b.at = nil
        return a == b
    }
}

/// POST /v1/edit-sessions/{id}/view
public struct EditSessionViewRequest: Codable, Hashable, Sendable {
    public var view: EditSessionView
    public init(view: EditSessionView) { self.view = view }
}

/// → `{ok, view}`
public struct EditSessionViewReply: Codable, Hashable, Sendable {
    public var view: EditSessionView?
}

extension EditSuiteState {
    /// Where the editor is now (the app adds the bin tab, the mode and the title it keeps itself).
    public func viewSnapshot(binTab: EditSuite.BinTab? = nil, mode: String? = nil, title: String? = nil) -> EditSessionView {
        EditSessionView(playhead: EditV2.r3(max(0, playhead.isFinite ? playhead : 0)), zoom: EditV2.r3(zoom), tab: tab.rawValue,
                        binTab: binTab?.rawValue, mode: mode, selection: selection, safeArea: preview.safeArea ? preview.view.rawValue : "off", title: title)
    }

    /// Puts the editor back where it was left. Anything the edit no longer has (a deleted clip, a playhead past the end, an
    /// unknown tab from a newer app) is ignored, so a saved view never breaks opening.
    public mutating func restore(_ v: EditSessionView) {
        if let p = v.playhead, p.isFinite { playhead = min(max(0, p), max(0, duration)) }
        if let z = v.zoom, z.isFinite { zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, z)) }
        if let s = v.tab, let tb = EditSuite.InspectorTab(rawValue: s) { tab = tb }
        // The platform preview (plans/edit-platform-preview.md): "off" turns the red box off, a view's name shows that view
        // with the box on; anything else (an older app's value) keeps the preview as it is.
        if let s = v.safeArea {
            if s == "off" { preview.safeArea = false } else if let skin = PreviewSkin(rawValue: s) { preview = EditPreview(view: skin, safeArea: true) }
        }
        if let sel = v.selection, project.tracks.contains(where: { $0.items.contains { $0.id == sel } }) { selection = sel }
    }
}

extension EditSuite {
    /// The bin tab a saved view asks for (nil: unknown, keep the default).
    public static func binTab(_ v: EditSessionView) -> BinTab? { v.binTab.flatMap(BinTab.init(rawValue:)) }

    /// Assets that need a file on this Mac (video, picture, sound) but have none: the timeline marks their clips "Missing"
    /// instead of the edit failing to open. Content-library items (stickers, sound effects) and LUTs are left out.
    public static func missingAssets(_ p: EditV2.Project, have: Set<String>) -> Set<String> {
        let used = Set(p.tracks.flatMap(\.items).compactMap { item -> String? in
            if let c = item.videoClip { return c.asset }
            if let i = item.imageItem { return i.asset }
            if let a = item.audioClip { return a.asset }
            return nil
        })
        return Set(p.assets.filter { a in
            used.contains(a.id) && a.contentRef == nil && (a.kind == .video || a.kind == .image || a.kind == .audio) && !have.contains(a.id)
        }.map(\.id))
    }
}

/// One edit in "Recent edits": the owner's server session or a member's edit kept on this Mac.
public struct EditRecentItem: Identifiable, Hashable, Sendable {
    /// The session id, or "local:<takeId>" for an edit kept on this Mac.
    public var id: String
    public var takeId: String
    /// The server session to join (owner).
    public var sessionId: String?
    public var title: String
    /// The take whose picture stands for the edit (nil: none yet, e.g. an empty blank project).
    public var thumbTakeId: String?
    /// Last worked on, ms since 1970.
    public var lastEditedAt: Double
    public var view: EditSessionView?

    public init(id: String, takeId: String, sessionId: String? = nil, title: String, thumbTakeId: String? = nil, lastEditedAt: Double,
                view: EditSessionView? = nil) {
        self.id = id; self.takeId = takeId; self.sessionId = sessionId; self.title = title; self.thumbTakeId = thumbTakeId
        self.lastEditedAt = lastEditedAt; self.view = view
    }

    public var isBlank: Bool { takeId == EditV2.blankSourceId }
}

/// A member's edit kept on this Mac (the whole project and where it was left), or the owner's offline copy of where the
/// editor was.
public struct EditLocalDraft: Codable, Hashable, Sendable {
    public var takeId: String
    public var sessionId: String?
    /// A blank project kept on this Mac only (no session): its own id, so two blanks are two edits.
    public var localId: String?
    /// Members: the edit itself (their editor is local). Nil for the owner (the server holds the project).
    public var project: EditV2.Project?
    public var view: EditSessionView
    public var title: String
    /// ms since 1970.
    public var savedAt: Double

    public init(takeId: String, sessionId: String? = nil, localId: String? = nil, project: EditV2.Project? = nil, view: EditSessionView, title: String,
                savedAt: Double) {
        self.takeId = takeId; self.sessionId = sessionId; self.localId = localId; self.project = project; self.view = view; self.title = title; self.savedAt = savedAt
    }

    /// One draft per take; a blank project (no take) per session, or one local blank.
    public var key: String { takeId == EditV2.blankSourceId ? "blank-\(sessionId ?? localId ?? "local")" : takeId }
}

public enum EditRecent {
    /// Recent edits shown on the Edit home.
    public static let shown = 8
    /// Edits kept on this Mac.
    public static let kept = 12

    /// "Untitled edit" when nothing better is known.
    public static let untitled = "Untitled edit"

    /// The thumbnail's take: the source take, or for a blank project the first take on its timeline.
    public static func thumbTake(takeId: String, project: EditV2.Project?) -> String? {
        if takeId != EditV2.blankSourceId { return takeId }
        guard let p = project else { return nil }
        for c in p.mainClips { if let t = p.assets.first(where: { $0.id == c.asset })?.take { return t } }
        return p.assets.first(where: { $0.take != nil })?.take
    }

    /// The server's sessions (owner) and this Mac's drafts, the last worked on first; an empty blank project is left out. A draft of a session the server lists is
    /// the same edit (the newer view wins). `takeTitle` names a take (nil: it's gone). Members pass no sessions.
    public static func items(sessions: [EditSession], local: [EditLocalDraft], takeTitle: (String) -> String?) -> [EditRecentItem] {
        var out: [String: EditRecentItem] = [:]
        for s in sessions where s.status == "open" {
            let p = try? JSONPatch.decode(EditV2.Project.self, s.project)
            // A blank project nothing was added to is not an edit yet ("New edit" pressed and left).
            if s.takeId == EditV2.blankSourceId, let p, p.assets.isEmpty { continue }
            let at = max(s.lastTouchedAt ?? 0, s.updatedAt ?? 0, s.view?.at ?? 0)
            out[s.id] = EditRecentItem(id: s.id, takeId: s.takeId, sessionId: s.id, title: title(view: s.view, takeId: s.takeId, takeTitle: takeTitle),
                                       thumbTakeId: thumbTake(takeId: s.takeId, project: p), lastEditedAt: at, view: s.view)
        }
        for d in local {
            if let sid = d.sessionId {
                // The owner's own record of a session: only its newer view counts (a session the server no longer lists is closed).
                guard var it = out[sid] else { continue }
                if d.savedAt > it.lastEditedAt {
                    var v = d.view
                    v.at = d.savedAt
                    it.view = v
                    it.lastEditedAt = d.savedAt
                }
                out[sid] = it
                continue
            }
            guard d.project != nil else { continue }
            let id = "local:\(d.key)"
            out[id] = EditRecentItem(id: id, takeId: d.takeId, title: d.title.isEmpty ? title(view: d.view, takeId: d.takeId, takeTitle: takeTitle) : d.title,
                                     thumbTakeId: thumbTake(takeId: d.takeId, project: d.project), lastEditedAt: d.savedAt, view: withAt(d.view, d.savedAt))
        }
        return out.values.sorted { $0.lastEditedAt != $1.lastEditedAt ? $0.lastEditedAt > $1.lastEditedAt : $0.id < $1.id }
    }

    static func withAt(_ v: EditSessionView, _ at: Double) -> EditSessionView { var v = v; v.at = at; return v }

    static func title(view: EditSessionView?, takeId: String, takeTitle: (String) -> String?) -> String {
        if let t = view?.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        if takeId == EditV2.blankSourceId { return untitled }
        return takeTitle(takeId) ?? untitled
    }

    /// "Just now", "5 min ago", "3 h ago", "Yesterday", "Tuesday", "12 Nov" (the year added when it isn't this year).
    public static func lastEditedText(_ atMs: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let at = Date(timeIntervalSince1970: atMs / 1000)
        let s = now.timeIntervalSince(at)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if calendar.isDate(at, inSameDayAs: now) { return "\(Int(s / 3600)) h ago" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        if s < 6 * 86_400 { f.dateFormat = "EEEE" }
        else if calendar.component(.year, from: at) == calendar.component(.year, from: now) { f.dateFormat = "d MMM" }
        else { f.dateFormat = "d MMM yyyy" }
        return f.string(from: at)
    }
}

/// This Mac's recent edits on disk (one JSON file, newest first, at most `EditRecent.kept`).
public struct EditRecentStore: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }

    /// ~/Library/Application Support/MUSE/EditDrafts/recent.json (next to the unsent-change drafts).
    public static var standard: EditRecentStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return EditRecentStore(file: base.appendingPathComponent("MUSE/EditDrafts/recent.json"))
    }

    public func load() -> [EditLocalDraft] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([EditLocalDraft].self, from: data)) ?? []
    }

    /// Saves this draft as the newest (replacing the same edit's older one).
    public func save(_ d: EditLocalDraft) {
        var list = load().filter { $0.key != d.key }
        list.insert(d, at: 0)
        write(Array(list.prefix(EditRecent.kept)))
    }

    /// Forgets one edit (its key).
    public func remove(key: String) { write(load().filter { $0.key != key }) }

    private func write(_ list: [EditLocalDraft]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
    }
}
