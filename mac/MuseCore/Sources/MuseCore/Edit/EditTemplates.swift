import Foundation

// Edit templates (plans/edit-templates.md §2–§5): the library of effects and transitions on the server
// (GET/POST /v1/editor/templates, POST /v1/editor/templates/{id}/apply, DELETE /v1/editor/templates/{id}). A template is one
// spec on the server, expanded there into ordinary project items, so the app needs no model code for it: Apply is one
// change the edit session sends back like Claude's. Not the photo presets (Templates in the Suite) and not caption kits;
// caption styles stay a section of the same panel. Owner only, like the rest of Edit with Claude. Decoding is lenient: a
// field the server adds later never breaks the library.

/// One setting of a template ("Shape", "Opens before the cut"…).
public struct EditTemplateParam: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    /// number | enum | bool | text | upload | times
    public var type: String
    public var options: [String]
    public var min: Double?
    public var max: Double?
    public var unit: String?
    public var defaultValue: JSONValue?
    public var id: String { key }

    public init(key: String, label: String, type: String, options: [String] = [], min: Double? = nil, max: Double? = nil, unit: String? = nil, defaultValue: JSONValue? = nil) {
        self.key = key; self.label = label; self.type = type; self.options = options; self.min = min; self.max = max; self.unit = unit; self.defaultValue = defaultValue
    }
    enum CodingKeys: String, CodingKey { case key, label, type, options, min, max, unit, defaultValue = "default" }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = (try? c.decode(String.self, forKey: .label)) ?? key
        type = (try? c.decode(String.self, forKey: .type)) ?? "text"
        options = (try? c.decode([String].self, forKey: .options)) ?? []
        min = try? c.decodeIfPresent(Double.self, forKey: .min)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
        unit = try? c.decodeIfPresent(String.self, forKey: .unit)
        defaultValue = try? c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
    }

    /// The control the inspector draws: a segmented control (≤ 4 options), a menu, a slider, a switch or a field.
    public enum Control: Equatable, Sendable { case segmented, menu, slider, toggle, field, hidden }
    public var control: Control {
        switch type {
        case "enum": return options.count <= 1 ? .hidden : options.count <= 4 ? .segmented : .menu
        case "number": return min != nil && max != nil ? .slider : .field
        case "bool": return .toggle
        case "text": return .field
        default: return .hidden // uploads and time ranges: Claude sets them (the Mac's Ask Claude, or chat)
        }
    }

    /// "0.3 s", "1.35 ×", "25°", "3" (the value beside a slider).
    public func valueLabel(_ v: Double) -> String {
        let n = abs(v - v.rounded()) < 1e-9 ? String(Int(v.rounded())) : (abs(v * 10 - (v * 10).rounded()) < 1e-9 ? String(format: "%.1f", v) : String(format: "%.2f", v))
        guard let u = unit, !u.isEmpty else { return n }
        return u == "°" ? "\(n)°" : "\(n) \(u)"
    }

    /// Option words as the apps show them: "box" → "Box", "easeOut" → "Ease out".
    public static func optionLabel(_ o: String) -> String {
        var out = ""
        for ch in o { if ch.isUppercase, !out.isEmpty { out += " " + ch.lowercased() } else { out.append(ch) } }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

/// A template in the library.
public struct EditTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    /// transition | effect
    public var kind: String
    /// clip | cut | edit
    public var target: String
    /// live | matte | primitive | reference
    public var level: String
    /// ready | not_ready | needs_update
    public var state: String
    public var reason: String?
    public var requires: [String]
    public var timing: String?
    /// selected | note-cut: what the secondary Apply covers.
    public var each: String?
    public var params: [EditTemplateParam]
    /// Needs a paid subject cut-out (Remove background), priced on Apply.
    public var paid: Bool
    public var previewUpload: String?
    /// The pack's finished clip (reference only).
    public var referenceUpload: String?
    /// seed (made by Claude for the pack) | claude | owner
    public var by: String
    public var version: Int
    public var updatedAt: Double

    public init(id: String, name: String, description: String = "", kind: String = "transition", target: String = "cut", level: String = "live", state: String = "ready",
                reason: String? = nil, requires: [String] = [], timing: String? = nil, each: String? = nil, params: [EditTemplateParam] = [], paid: Bool = false,
                previewUpload: String? = nil, referenceUpload: String? = nil, by: String = "seed", version: Int = 1, updatedAt: Double = 0) {
        self.id = id; self.name = name; self.description = description; self.kind = kind; self.target = target; self.level = level; self.state = state
        self.reason = reason; self.requires = requires; self.timing = timing; self.each = each; self.params = params; self.paid = paid
        self.previewUpload = previewUpload; self.referenceUpload = referenceUpload; self.by = by; self.version = version; self.updatedAt = updatedAt
    }

    struct Upload: Codable, Hashable { var uploadId: String }
    enum CodingKeys: String, CodingKey { case id, name, description, kind, target, level, state, reason, requires, timing, each, params, paid, preview, reference, by, version, updatedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "effect"
        target = (try? c.decode(String.self, forKey: .target)) ?? "clip"
        level = (try? c.decode(String.self, forKey: .level)) ?? "live"
        state = (try? c.decode(String.self, forKey: .state)) ?? "ready"
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        requires = (try? c.decode([String].self, forKey: .requires)) ?? []
        timing = try? c.decodeIfPresent(String.self, forKey: .timing)
        each = try? c.decodeIfPresent(String.self, forKey: .each)
        params = (try? c.decode([EditTemplateParam].self, forKey: .params)) ?? []
        paid = (try? c.decode(Bool.self, forKey: .paid)) ?? (level == "matte")
        previewUpload = (try? c.decodeIfPresent(Upload.self, forKey: .preview))?.uploadId
        referenceUpload = (try? c.decodeIfPresent(Upload.self, forKey: .reference))?.uploadId
        by = (try? c.decode(String.self, forKey: .by)) ?? "seed"
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(description, forKey: .description)
        try c.encode(kind, forKey: .kind); try c.encode(target, forKey: .target); try c.encode(level, forKey: .level); try c.encode(state, forKey: .state)
        try c.encodeIfPresent(reason, forKey: .reason); try c.encode(requires, forKey: .requires); try c.encodeIfPresent(timing, forKey: .timing)
        try c.encodeIfPresent(each, forKey: .each); try c.encode(params, forKey: .params); try c.encode(paid, forKey: .paid)
        try c.encodeIfPresent(previewUpload.map { Upload(uploadId: $0) }, forKey: .preview)
        try c.encodeIfPresent(referenceUpload.map { Upload(uploadId: $0) }, forKey: .reference)
        try c.encode(by, forKey: .by); try c.encode(version, forKey: .version); try c.encode(updatedAt, forKey: .updatedAt)
    }

    public var isReady: Bool { state == "ready" }
    public var isTransition: Bool { kind == "transition" }
    /// The tile's badge: "Not ready", "Needs update", or none.
    public var badge: String? {
        switch state {
        case "ready": return nil
        case "needs_update": return "Needs update"
        default: return "Not ready"
        }
    }
    /// The level line under the settings ("Live transition: uses the next clip itself, so it works on any video").
    public var levelLine: String {
        switch level {
        case "matte": return "Cuts out the subject (Remove background), priced on Apply. Everything else is live and works on any video."
        case "live": return target == "cut" ? "Live transition: uses the clips themselves, so it works on any video and plays the same on Mac, Android and in the export."
            : target == "edit" ? "Live: goes across the whole edit and plays the same on Mac, Android and in the export."
            : "Live effect: changes the clip itself, so it works on any video and plays the same on Mac, Android and in the export."
        default: return reason ?? "Not ready yet"
        }
    }
    /// "Made by Claude for the Icon edit" / "Saved by you" / "Saved by Claude".
    public var origin: String {
        switch by {
        case "seed": return "Made by Claude for the Icon edit"
        case "owner": return "Saved by you"
        default: return "Saved by Claude"
        }
    }
}

/// GET /v1/editor/templates
public struct EditTemplateLibrary: Codable, Hashable, Sendable {
    public struct CaptionStyle: Codable, Hashable, Sendable, Identifiable { public var id: String; public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name } }
    public var templates: [EditTemplate]
    public var captionStyles: [CaptionStyle]
    public init(templates: [EditTemplate] = [], captionStyles: [CaptionStyle] = []) { self.templates = templates; self.captionStyles = captionStyles }
    enum CodingKeys: String, CodingKey { case templates, captionStyles }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        templates = (try? c.decode([EditTemplate].self, forKey: .templates)) ?? []
        captionStyles = (try? c.decode([CaptionStyle].self, forKey: .captionStyles)) ?? []
    }

    /// The panel's filters (owner decision 1: caption styles are one of them).
    public enum Filter: String, CaseIterable, Hashable, Sendable, Identifiable {
        case all, transitions, effects, captions
        public var id: String { rawValue }
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    /// The tiles for a filter and search words, in the panel's sections: "Yours" (saved by you or Claude), then "Made by
    /// Claude" (the pack's), each ready ones first. Captions shows no tiles (only the caption styles).
    public func sections(filter: Filter, query: String) -> [(title: String, items: [EditTemplate])] {
        guard filter != .captions else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = templates.filter { t in
            (filter == .all || (filter == .transitions) == t.isTransition)
                && (q.isEmpty || "\(t.name) \(t.description) \(t.id)".lowercased().contains(q))
        }
        let order: (EditTemplate, EditTemplate) -> Bool = { a, b in a.isReady != b.isReady ? a.isReady : a.name.localizedCompare(b.name) == .orderedAscending }
        let yours = shown.filter { $0.by != "seed" }.sorted(by: order), pack = shown.filter { $0.by == "seed" }.sorted(by: order)
        let all: [(title: String, items: [EditTemplate])] = [(title: "Yours", items: yours), (title: "Made by Claude", items: pack)]
        return all.filter { !$0.items.isEmpty }
    }
    /// Caption styles show under All and Captions, filtered by the search words too.
    public func captionStyles(filter: Filter, query: String) -> [CaptionStyle] {
        guard filter == .all || filter == .captions else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return captionStyles.filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }
}

/// Where a template goes: a clip, the cut after a clip, several, every cut (or every cut on a note), or the whole edit.
public enum EditTemplateTarget: Hashable, Sendable {
    case item(String)
    case cutAfter(String)
    case items([String])
    case cutsAfter([String])
    case each(String)
    case edit

    var json: JSONValue? {
        switch self {
        case .item(let id): return .object(["itemId": .string(id)])
        case .cutAfter(let id): return .object(["cutAfter": .string(id)])
        case .items(let ids): return .object(["itemIds": .array(ids.map { .string($0) })])
        case .cutsAfter(let ids): return .object(["cutsAfter": .array(ids.map { .string($0) })])
        case .each(let e): return .object(["each": .string(e)])
        case .edit: return nil
        }
    }

    /// What the app applies a template to now: the selected clip (or the one under the playhead); for a cut, the cut before
    /// the selected clip, else the cut nearest the playhead. Nil when there is nothing to apply it to (an empty edit).
    public static func current(for t: EditTemplate, project p: EditV2.Project, selection: String?, playhead: Double) -> (target: EditTemplateTarget, title: String, detail: String)? {
        let spans = EditV2.timeline(p), clips = p.mainClips
        guard !spans.isEmpty else { return nil }
        switch t.target {
        case "edit":
            return (.edit, "The whole edit", "\(EditSuite.clock(EditV2.durationSec(p))) long")
        case "cut":
            guard spans.count >= 2 else { return nil }
            var k: Int?
            if let s = selection, let i = clips.firstIndex(where: { $0.id == s }), i > 0 { k = i }
            if k == nil {
                k = (1..<spans.count).min { abs(cutTime(spans[$0]) - playhead) < abs(cutTime(spans[$1]) - playhead) }
            }
            guard let i = k else { return nil }
            return (.cutAfter(clips[i - 1].id), "Cut at \(EditSuite.clockTenths(cutTime(spans[i])))", "Between clip \(i) and clip \(i + 1)")
        default:
            if let s = selection, p.locate(s) != nil {
                let n = clips.firstIndex { $0.id == s }.map { "Clip \($0 + 1)" } ?? "The selected item"
                return (.item(s), n, "The selected clip")
            }
            let i = spans.firstIndex { playhead >= $0.startSec && playhead < $0.endSec } ?? (spans.count - 1)
            return (.item(spans[i].id), "Clip \(i + 1)", "Under the playhead")
        }
    }
    static func cutTime(_ s: EditV2.MainSpan) -> Double { s.startSec + s.transitionSec / 2 }

    /// The primary button: "Apply to cut at 0:21.7", "Apply to clip 3", "Apply to the whole edit", with the price for a
    /// template that cuts out the subject ("… · $0.82").
    public static func applyTitle(_ title: String, priceUsd: Double?) -> String {
        let place = title.prefix(1).lowercased() + title.dropFirst()
        let base = "Apply to \(place)"
        guard let p = priceUsd, p > 0 else { return base }
        return base + " · $" + String(format: "%.2f", p)
    }
    /// The secondary: "Apply to every cut", "Apply to every cut on a note", "Apply to every clip"; nil for whole-edit ones.
    public static func everyTitle(_ t: EditTemplate) -> (target: EditTemplateTarget, title: String)? {
        switch t.target {
        case "cut": return t.each == "note-cut" ? (.each("note-cut"), "Apply to every cut on a note") : (.each("cut"), "Apply to every cut")
        case "clip": return (.each("clip"), "Apply to every clip")
        default: return nil
        }
    }
}

/// POST /v1/editor/templates/{id}/apply {sessionId, target, params, dryRun?, confirm?}
public struct EditTemplateApplyRequest: Encodable, Sendable {
    public var sessionId: String
    public var target: EditTemplateTarget
    public var params: [String: JSONValue]
    public var dryRun: Bool
    public var confirm: Bool
    public var device: String?
    public init(sessionId: String, target: EditTemplateTarget, params: [String: JSONValue] = [:], dryRun: Bool = false, confirm: Bool = false, device: String? = nil) {
        self.sessionId = sessionId; self.target = target; self.params = params; self.dryRun = dryRun; self.confirm = confirm; self.device = device
    }
    enum CodingKeys: String, CodingKey { case sessionId, target, params, dryRun, confirm, device }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(target.json, forKey: .target)
        if !params.isEmpty { try c.encode(params, forKey: .params) }
        if dryRun { try c.encode(true, forKey: .dryRun) }
        if confirm { try c.encode(true, forKey: .confirm) }
        try c.encodeIfPresent(device, forKey: .device)
    }
}

/// The answer to apply: a dry run's change (`patch`, nothing saved), the price to confirm, or the applied change.
public struct EditTemplateApplyResult: Decodable, Hashable, Sendable {
    public var dryRun: Bool
    public var applied: Bool
    public var needsConfirmation: Bool
    public var revision: Int?
    public var patch: [EditPatchOp]
    public var added: [String]
    public var notes: [String]
    public var priceUsd: Double?
    public var waitingForOwner: Int
    public init(dryRun: Bool = false, applied: Bool = false, needsConfirmation: Bool = false, revision: Int? = nil, patch: [EditPatchOp] = [], added: [String] = [], notes: [String] = [], priceUsd: Double? = nil, waitingForOwner: Int = 0) {
        self.dryRun = dryRun; self.applied = applied; self.needsConfirmation = needsConfirmation; self.revision = revision; self.patch = patch
        self.added = added; self.notes = notes; self.priceUsd = priceUsd; self.waitingForOwner = waitingForOwner
    }
    struct Waiting: Decodable { var pendingId: String? }
    enum CodingKeys: String, CodingKey { case dryRun, applied, needsConfirmation, revision, patch, added, notes, priceUsd, estimateUsd, waitingForOwner }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        dryRun = (try? c.decode(Bool.self, forKey: .dryRun)) ?? false
        applied = (try? c.decode(Bool.self, forKey: .applied)) ?? false
        needsConfirmation = (try? c.decode(Bool.self, forKey: .needsConfirmation)) ?? false
        revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
        patch = (try? c.decode([EditPatchOp].self, forKey: .patch)) ?? []
        added = (try? c.decode([String].self, forKey: .added)) ?? []
        notes = (try? c.decode([String].self, forKey: .notes)) ?? []
        priceUsd = (try? c.decodeIfPresent(Double.self, forKey: .priceUsd)) ?? (try? c.decodeIfPresent(Double.self, forKey: .estimateUsd))
        waitingForOwner = ((try? c.decode([Waiting].self, forKey: .waitingForOwner)) ?? []).count
    }
}

/// POST /v1/editor/templates {name, kind, target?, from: {sessionId, itemIds, cutAt?}} (Save as template)
public struct EditTemplateSaveRequest: Encodable, Hashable, Sendable {
    public struct From: Encodable, Hashable, Sendable { public var sessionId: String; public var itemIds: [String]; public var cutAt: Double? }
    public var name: String
    public var kind: String
    public var target: String?
    public var from: From
    public init(name: String, kind: String, target: String?, sessionId: String, itemIds: [String], cutAt: Double? = nil) {
        self.name = name; self.kind = kind; self.target = target; self.from = From(sessionId: sessionId, itemIds: itemIds, cutAt: cutAt)
    }
}
public struct EditTemplateSaved: Decodable, Hashable, Sendable {
    public var template: EditTemplate
    public var saved: String
    enum CodingKeys: String, CodingKey { case template, saved }
    public init(template: EditTemplate, saved: String) { self.template = template; self.saved = saved }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        template = try c.decode(EditTemplate.self, forKey: .template)
        saved = (try? c.decode(String.self, forKey: .saved)) ?? "Saved \(template.name) as a template"
    }
}

/// The library's endpoints. Owner only: members get 403.
public protocol EditTemplateAPI: Sendable {
    func editTemplates() async throws -> EditTemplateLibrary
    func applyEditTemplate(_ id: String, _ req: EditTemplateApplyRequest) async throws -> EditTemplateApplyResult
    func saveEditTemplate(_ req: EditTemplateSaveRequest) async throws -> EditTemplateSaved
    func deleteEditTemplate(_ id: String) async throws
    /// Where a preview or reference upload can be played (GET /v1/editor/uploads/{id} → url).
    func editTemplateMediaURL(uploadId: String) async throws -> URL
}

public enum EditTemplateIds {
    /// Template ids are slugs ("window-open-next"); anything else is refused before it reaches a URL.
    public static func check(_ id: String) throws -> String {
        guard id.range(of: #"^[a-z0-9][a-z0-9-]{1,63}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't a template") }
        return id
    }
    static func upload(_ id: String) throws -> String {
        guard id.range(of: #"^[\w-]{1,80}$"#, options: .regularExpression) != nil else { throw ApiError("bad_id", "That isn't an upload") }
        return id
    }
}

struct EditTemplateUploadURL: Decodable { var url: String }

extension HTTPMuseAPI: EditTemplateAPI {
    public func editTemplates() async throws -> EditTemplateLibrary { try await suiteCall("GET", "v1/editor/templates") }
    public func applyEditTemplate(_ id: String, _ req: EditTemplateApplyRequest) async throws -> EditTemplateApplyResult {
        try await suiteCall("POST", "v1/editor/templates/\(try EditTemplateIds.check(id))/apply", body: try JSONEncoder().encode(req))
    }
    public func saveEditTemplate(_ req: EditTemplateSaveRequest) async throws -> EditTemplateSaved {
        try await suiteCall("POST", "v1/editor/templates", body: try JSONEncoder().encode(req))
    }
    public func deleteEditTemplate(_ id: String) async throws { try await suiteSend("DELETE", "v1/editor/templates/\(try EditTemplateIds.check(id))") }
    public func editTemplateMediaURL(uploadId: String) async throws -> URL {
        let r: EditTemplateUploadURL = try await suiteCall("GET", "v1/editor/uploads/\(try EditTemplateIds.upload(uploadId))")
        if let u = URL(string: r.url), u.scheme != nil { return u }
        guard let u = URL(string: r.url, relativeTo: baseURL) else { throw ApiError("bad_url", "That preview can't be played") }
        return u.absoluteURL
    }
}

/// Demo mode and tests: a small library like the pack's (a ready transition, a ready effect, a paid one, a not-ready one).
public final class FakeEditTemplateAPI: EditTemplateAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var library: EditTemplateLibrary
    public private(set) var applied: [(id: String, req: EditTemplateApplyRequest)] = []
    /// The next call throws (a dropped connection), once.
    public var failNext = false

    public init(empty: Bool = false) {
        library = empty ? EditTemplateLibrary() : EditTemplateLibrary(templates: [
            EditTemplate(id: "window-open-next", name: "Window opens the next shot", description: "The next shot opens early in a band, a column, slats or a box, in place and unscaled, then the cut lands.",
                         kind: "transition", target: "cut", timing: "0.3 s before the cut",
                         params: [EditTemplateParam(key: "shape", label: "Shape", type: "enum", options: ["box", "band", "column", "slats"], defaultValue: .string("box")),
                                  EditTemplateParam(key: "lead", label: "Opens before the cut", type: "number", min: 0.1, max: 1, unit: "s", defaultValue: .number(0.3)),
                                  EditTemplateParam(key: "wash", label: "Entrance wash", type: "enum", options: ["white", "blue", "off"], defaultValue: .string("white"))]),
            EditTemplate(id: "hit-rgb-split", name: "RGB split hit", description: "Red and blue pull apart on the cut for a few frames.", kind: "transition", target: "cut", timing: "On the cut, 0.1 s", each: "selected",
                         params: [EditTemplateParam(key: "sec", label: "Length", type: "number", min: 0.1, max: 0.4, unit: "s", defaultValue: .number(0.1))]),
            EditTemplate(id: "punch-in", name: "Punch-in", description: "The shot starts punched in and settles back to its own size.", kind: "effect", target: "clip", timing: "Over the whole clip",
                         params: [EditTemplateParam(key: "from", label: "Starts at", type: "number", min: 1.05, max: 2, unit: "×", defaultValue: .number(1.35))]),
            EditTemplate(id: "band-behind-subject", name: "Band behind the subject", description: "A band of the next shot opens behind the current subject.", kind: "transition", target: "cut", level: "matte", timing: "Before the cut", paid: true),
            EditTemplate(id: "glass-shatter", name: "Glass shatter", description: "The frame breaks like glass and falls away.", kind: "transition", target: "cut", level: "reference", state: "not_ready",
                         reason: "The shatter isn't built into Edit yet: ask Claude on the Mac to make it for this cut", timing: "On the cut"),
        ], captionStyles: [.init(id: "pop", name: "Word pop"), .init(id: "karaoke", name: "Karaoke"), .init(id: "box", name: "Bold box"), .init(id: "plain", name: "Minimal")])
    }

    private func with<T>(_ f: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; throw ApiError("offline", "Couldn't reach MUSE") }
        return try f()
    }
    public func editTemplates() async throws -> EditTemplateLibrary { try with { library } }
    public func applyEditTemplate(_ id: String, _ req: EditTemplateApplyRequest) async throws -> EditTemplateApplyResult {
        try with {
            guard let t = library.templates.first(where: { $0.id == id }) else { throw ApiError("not_found", "That template is gone") }
            guard t.isReady else { throw ApiError(t.state, "\(t.name): \(t.reason ?? "not ready yet")") }
            if req.dryRun { return EditTemplateApplyResult(dryRun: true, added: [], priceUsd: t.paid ? 0.82 : nil) }
            if t.paid && !req.confirm { return EditTemplateApplyResult(needsConfirmation: true, priceUsd: 0.82) }
            applied.append((id, req))
            return EditTemplateApplyResult(applied: true, revision: applied.count, waitingForOwner: t.paid ? 1 : 0)
        }
    }
    public func saveEditTemplate(_ req: EditTemplateSaveRequest) async throws -> EditTemplateSaved {
        try with {
            let name = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ApiError("bad_request", "Name it first") }
            let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            let t = EditTemplate(id: slug, name: name, kind: req.kind, target: req.target ?? (req.from.cutAt != nil ? "cut" : "clip"), by: "owner")
            library.templates.removeAll { $0.id == t.id }
            library.templates.append(t)
            return EditTemplateSaved(template: t, saved: "Saved \(name) as a template")
        }
    }
    public func deleteEditTemplate(_ id: String) async throws { try with { library.templates.removeAll { $0.id == id } } }
    public func editTemplateMediaURL(uploadId: String) async throws -> URL { throw ApiError("not_found", "No preview in demo mode") }
}
