import Foundation

// Claude in the AI Suite: the "composer patch" is the assist's Draft (the Reuse-settings draft). Before it reaches the
// composer every value is checked against the composer's own option lists, the ones a member sees in the pickers: an
// unknown, hidden or merged option, a row the tool doesn't use, a length the quality can't make, a character not in the
// studio are each left as they were, with the reason. Pure rules, no UI.

/// One value of Claude's draft the composer didn't take, and why ("Lens “cine_zoom” isn't offered in the composer").
public struct SuiteDraftRejection: Hashable, Sendable {
    /// The row as the composer names it ("Lens", "Length", "Character").
    public var field: String
    public var value: String
    public var reason: String

    public init(field: String, value: String, reason: String) {
        self.field = field
        self.value = value
        self.reason = reason
    }

    public var text: String { "\(field) “\(value)” \(reason)" }
}

/// What the composer offers: its catalog and the studio's characters, outfits and locations (id → name).
public struct SuiteDraftOptions: Sendable {
    public var catalog: SuiteCatalog?
    public var characters: [String: String]
    public var outfits: [String: String]
    public var locations: [String: String]

    public init(catalog: SuiteCatalog?, characters: [String: String] = [:], outfits: [String: String] = [:], locations: [String: String] = [:]) {
        self.catalog = catalog
        self.characters = characters
        self.outfits = outfits
        self.locations = locations
    }

    public var camera: CameraCatalog { catalog?.camera ?? CameraCatalog() }
}

/// Claude's draft as the composer took it: the new composer, the rows that changed ("Camera", "Light"…) and what was refused.
public struct SuiteDraftApplied: Sendable {
    public var composer: ComposerDraft
    public var changed: [String]
    public var rejected: [SuiteDraftRejection]
}

public enum SuiteAssistDraft {
    /// The longest prompt text taken from a draft (the server's own limit is larger; this keeps the editor usable).
    public static let maxPromptCharacters = 4000

    // MARK: Apply (Draft → composer)

    /// Claude's draft laid over the composer. Fields the draft leaves out keep their values (as Reuse settings). A draft
    /// for another tool changes nothing but says so: Claude works in the composer that is open.
    public static func apply(_ draft: SuiteDraft, to current: ComposerDraft, options: SuiteDraftOptions) -> SuiteDraftApplied {
        var out = current
        var rejected: [SuiteDraftRejection] = []
        func refuse(_ field: String, _ value: String, _ reason: String) { rejected.append(SuiteDraftRejection(field: field, value: value, reason: reason)) }

        let tool = current.tool
        if !draft.tool.isEmpty, draft.tool != tool.rawValue {
            let name = ComposerTool(rawValue: draft.tool)?.title ?? draft.tool
            refuse("Tool", name, "isn't the composer that's open (\(tool.title)), so nothing was changed")
            return SuiteDraftApplied(composer: current, changed: [], rejected: rejected)
        }
        guard let cat = options.catalog else {
            refuse("Draft", draft.tool, "came before the composer's options loaded")
            return SuiteDraftApplied(composer: current, changed: [], rejected: rejected)
        }

        // The bar: quality, shape, length, takes, sound, speaking.
        if let q = draft.quality, q != current.quality {
            if let tier = cat.tier(q) {
                if tier.available { out.quality = q } else { refuse("Quality", tier.label, "isn't available right now") }
            } else {
                refuse("Quality", q, "isn't one of the composer's qualities")
            }
        }
        if let a = draft.aspect, a != current.aspect {
            let shapes = cat.aspectRatios.isEmpty ? ComposerBar.shapes : cat.aspectRatios
            if shapes.contains(a) { out.aspect = a } else { refuse("Shape", a, "isn't offered; use \(shapes.joined(separator: ", "))") }
        }
        if let du = draft.duration {
            let s = Int(du.rounded())
            let range = ComposerBar.lengthRange(cat.tier(out.quality))
            if s != current.duration || !range.contains(current.duration) {
                if range.contains(s) {
                    out.duration = s
                } else {
                    refuse("Length", "\(s) s", "is outside \(range.lowerBound)–\(range.upperBound) s on \(SuiteText.tierLabel(out.quality))")
                }
            }
        }
        if let tk = draft.takes, tk != current.takes {
            let allowed = ComposerBar.takes(cat.takesMax)
            if allowed.contains(tk) { out.takes = tk } else { refuse("Takes", "\(tk)", "is more than \(allowed.last ?? 1)") }
        }
        if let so = draft.sound { out.sound = so }
        if draft.raw["speaking"] != nil { out.speaking = draft.speaking.map { $0 ? ComposerSpeaking.on : ComposerSpeaking.off } ?? ComposerSpeaking.auto }

        // The rig rows.
        if let rig = draft.rig, SuiteRig(rig.settings) != SuiteRig(current.settings) {
            out.settings = Self.settings(rig, current: current.settings, tool: tool, cat: cat.camera, refuse: refuse)
        }

        // The prompt and its chips.
        if let raw = draft.tokens {
            let checked = Self.tokens(ComposerDrafts.decode(raw), tool: tool, options: options, cat: cat.camera, refuse: refuse)
            if checked != current.tokens { out.tokens = checked }
        }
        if case .string(let o)? = draft.extra["outfitId"], o != current.outfitId {
            if options.outfits[o] != nil { out.outfitId = o } else { refuse("Outfit", o, "isn't one of this character's outfits") }
        }
        // Images sent: Claude's choice (or none) as the draft has it.
        let sent = draft.raw["sent"]
        if !(sent == nil && current.sent == .null) { out.sent = sent } // a reset the server already applied stays a reset
        // A preset's collapsed composer opens up once Claude changes its rig or prompt.
        if out.settings != current.settings || out.tokens != current.tokens { out.collapsed = nil }
        return SuiteDraftApplied(composer: out, changed: changedRows(current, out), rejected: rejected)
    }

    /// The rig rows: each value must be a visible option of its picker and a row the tool uses; anything else keeps the
    /// row as it was.
    private static func settings(_ rig: SuiteRig, current: ComposerSettings, tool: ComposerTool, cat: CameraCatalog,
                                 refuse: @escaping (String, String, String) -> Void) -> ComposerSettings {
        var s = current
        s.preset = nil
        func row(_ field: String, _ value: String?, _ list: [SuiteOption], _ chip: ComposerChip, _ cur: String?, usable: Bool = true) -> String? {
            guard let v = value, !v.isEmpty, v != "auto" else { return nil }
            if v == cur { return v }
            if !tool.chips.contains(chip) || !usable {
                refuse(field, v, "isn't used by \(tool.title)")
                return cur
            }
            guard let o = list.first(where: { $0.id == v }) else {
                refuse(field, v, "isn't one of the composer's options")
                return cur
            }
            if let m = o.mergedInto {
                refuse(field, o.label, "is shown as \(ComposerCatalog.label(list, m) ?? m) (\(m)); use that")
                return cur
            }
            if !o.visible {
                refuse(field, o.label, "isn't offered in the composer")
                return cur
            }
            return v
        }
        s.body = row("Camera", rig.body, cat.bodies, .camera, current.body)
        s.lens = row("Lens", rig.lens, cat.lenses, .camera, current.lens)
        s.aperture = row("Aperture", rig.aperture, cat.apertures, .camera, current.aperture)
        s.height = row("Angle", rig.height, cat.heights, .camera, current.height)
        s.shotSize = row("Framing", rig.shotSize, cat.shotSizes, .camera, current.shotSize)
        s.lighting = row("Light", rig.lighting, cat.lighting, .lighting, current.lighting)
        s.palette = row("Palette", rig.palette, cat.palettes, .look, current.palette)
        s.stock = row("Film stock", rig.stock, cat.looks, .look, current.stock)
        s.genre = row("Genre", rig.genre, cat.genres, .style, current.genre)
        s.era = row("Era", rig.era, cat.eras, .style, current.era)
        s.tempo = row("Tempo", rig.tempo, cat.tempos, .style, current.tempo, usable: tool != .photo)
        s.format = row("Format", rig.format, cat.ugcFormats, .style, current.format, usable: tool == .ugc)
        s.gradeLook = rig.gradeLook ?? true
        if let f = rig.focalMm {
            let steps = ComposerCatalog.focalSteps(cat)
            if f == current.focalMm {
                s.focalMm = f
            } else if !tool.chips.contains(.camera) {
                refuse("Focal length", "\(Int(f))mm", "isn't used by \(tool.title)")
                s.focalMm = current.focalMm
            } else if steps.contains(f) {
                s.focalMm = f
            } else {
                refuse("Focal length", "\(Int(f))mm", "isn't offered; use \(steps.map { "\(Int($0))" }.joined(separator: ", ")) mm")
                s.focalMm = current.focalMm
            }
        } else {
            s.focalMm = nil
        }
        return s
    }

    /// The prompt: text as written (trimmed to the limit), #moves from the catalog (two at most, a pair the server can mix,
    /// none in a still), @mentions only of the studio's characters, outfits and locations, named as the studio names them.
    private static func tokens(_ t: PromptTokens, tool: ComposerTool, options: SuiteDraftOptions, cat: CameraCatalog,
                               refuse: @escaping (String, String, String) -> Void) -> PromptTokens {
        var parts: [PromptPart] = []
        var used = Set<Int>()
        let maxKey = t.parts.compactMap(\.key).max() ?? 0
        var fresh = maxKey
        /// A token keeps its key (the editor tracks chips by it) unless it is taken.
        func keyFor(_ k: Int?) -> Int {
            if let k, k > 0, !used.contains(k) { used.insert(k); return k }
            fresh += 1
            used.insert(fresh)
            return fresh
        }
        var moves: [(id: String, label: String, category: String)] = []
        var characters = 0
        var textCount = 0
        for p in t.parts {
            switch p {
            case .text(let s):
                let room = max(0, maxPromptCharacters - textCount)
                let kept = String(s.prefix(room))
                if kept.count < s.count { refuse("Prompt", String(s.prefix(24)) + "…", "is longer than \(maxPromptCharacters) characters; the rest was left out") }
                textCount += kept.count
                if !kept.isEmpty { parts.append(.text(kept)) }
            case .move(let id, _, _, let intensity, let given):
                guard tool != .photo else { refuse("Move", id, "isn't used in a still"); continue }
                guard let m = cat.move(id) else { refuse("Move", id, "isn't one of the composer's moves"); continue }
                if moves.contains(where: { $0.id == m.id }) { continue }
                if moves.count >= PromptTokens.maxMoves { refuse("Move", m.label, "is a third move; a shot takes \(PromptTokens.maxMoves)"); continue }
                if let first = moves.first, !PromptTokens.canMix(first.category, first.id, m.category, m.id) {
                    refuse("Move", m.label, "can't be combined with \(first.label)")
                    continue
                }
                moves.append((m.id, m.label, m.category))
                parts.append(.move(id: m.id, label: m.label, category: m.category, intensity: min(max(intensity, 0), 100), key: keyFor(given)))
            case .mention(let kind, let id, let label, let given):
                let names: [String: String]
                switch kind {
                case "character": names = options.characters
                case "outfit": names = options.outfits
                case "location": names = options.locations
                default: refuse("Mention", label, "isn't a character, outfit or location"); continue
                }
                guard let name = names[id] else { refuse(kind.capitalized, label, "isn't in this studio"); continue }
                if kind == "character" {
                    characters += 1
                    if characters > 1 { refuse("Character", name, "is a second character; the composer takes one"); continue }
                }
                parts.append(.mention(kind: kind, id: id, label: name, key: keyFor(given)))
            }
        }
        // Neighbouring texts join, as the editor keeps them.
        var joined: [PromptPart] = []
        for p in parts {
            if let s = p.text, let last = joined.last?.text { joined[joined.count - 1] = .text(last + s) } else { joined.append(p) }
        }
        return PromptTokens(joined)
    }

    // MARK: What changed

    /// The composer's rows that differ, in the rail's order: "Character", "Prompt", "Moves", "Camera", "Light", "Look",
    /// "Style", "Quality", "Shape", "Length", "Takes", "Sound", "Speaking".
    public static func changedRows(_ a: ComposerDraft, _ b: ComposerDraft) -> [String] {
        var out: [String] = []
        if a.tokens.characterId != b.tokens.characterId { out.append("Character") }
        if textOnly(a.tokens) != textOnly(b.tokens) { out.append("Prompt") }
        if a.tokens.moves.compactMap(\.move) != b.tokens.moves.compactMap(\.move) { out.append("Moves") }
        let sa = a.settings, sb = b.settings
        let rigA: [String?] = [sa.body, sa.lens, sa.aperture, sa.height, sa.shotSize]
        let rigB: [String?] = [sb.body, sb.lens, sb.aperture, sb.height, sb.shotSize]
        if rigA != rigB || sa.focalMm != sb.focalMm { out.append("Camera") }
        if sa.lighting != sb.lighting { out.append("Light") }
        if sa.palette != sb.palette || sa.stock != sb.stock || sa.gradeLook != sb.gradeLook { out.append("Look") }
        let styleA: [String?] = [sa.genre, sa.era, sa.tempo, sa.format]
        let styleB: [String?] = [sb.genre, sb.era, sb.tempo, sb.format]
        if styleA != styleB { out.append("Style") }
        if a.quality != b.quality { out.append("Quality") }
        if a.aspect != b.aspect { out.append("Shape") }
        if a.duration != b.duration { out.append("Length") }
        if a.takes != b.takes { out.append("Takes") }
        if a.sound != b.sound { out.append("Sound") }
        if a.speaking != b.speaking { out.append("Speaking") }
        if (a.sent == .null ? nil : a.sent) != (b.sent == .null ? nil : b.sent) { out.append("Images sent") }
        return out
    }

    private static func textOnly(_ t: PromptTokens) -> String {
        t.parts.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Claude set Camera, Light and Prompt".
    public static func toast(_ changed: [String]) -> String? {
        guard !changed.isEmpty else { return nil }
        let list = changed.count == 1 ? changed[0] : changed.dropLast().joined(separator: ", ") + " and " + changed[changed.count - 1]
        return "Claude set \(list)"
    }

    // MARK: Merge (409 stale)

    /// The owner's edits since the last sync (`base` → `mine`) laid over the server's newer draft (`theirs`), row by row:
    /// a row the owner changed keeps the owner's value, every other row takes the server's.
    public static func merge(base: ComposerDraft, mine: ComposerDraft, theirs: ComposerDraft) -> ComposerDraft {
        var out = theirs
        func take<T: Equatable>(_ k: WritableKeyPath<ComposerDraft, T>) { if mine[keyPath: k] != base[keyPath: k] { out[keyPath: k] = mine[keyPath: k] } }
        take(\.tokens)
        take(\.outfitId)
        take(\.quality)
        take(\.aspect)
        take(\.duration)
        take(\.takes)
        take(\.sound)
        take(\.speaking)
        take(\.sent)
        take(\.settings.body)
        take(\.settings.lens)
        take(\.settings.focalMm)
        take(\.settings.aperture)
        take(\.settings.height)
        take(\.settings.shotSize)
        take(\.settings.lighting)
        take(\.settings.palette)
        take(\.settings.stock)
        take(\.settings.gradeLook)
        take(\.settings.genre)
        take(\.settings.era)
        take(\.settings.tempo)
        take(\.settings.format)
        return out
    }
}
