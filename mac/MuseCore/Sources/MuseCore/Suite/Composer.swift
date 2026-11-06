import Foundation

// AI suite (workstream 1): the video composer's pure rules (plans/video-composer.md), same as Android's
// ui/screens/suite/composer: the setting chips (every value Auto until picked; a chip shows only the non-Auto values,
// "Camera · 35mm film, Anamorphic", cut with "…"), the catalogue's visible lists, and the prompt with inline tokens
// (`@` character / outfit / location, `#` camera move; at most two moves, only pairs the server can mix). No layout.

/// The five chips above the prompt, in order. `key` is the mono label.
public enum ComposerChip: String, CaseIterable, Sendable {
    case references, style, camera, look, lighting
    public var key: String { rawValue.uppercased() }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Everything the chips set. nil = Auto (the server decides).
public struct ComposerSettings: Hashable, Sendable {
    // Camera · Setup and Angle
    public var body: String?
    public var lens: String?
    public var focalMm: Double?
    public var aperture: String?
    public var height: String?
    public var shotSize: String?
    // Style
    public var genre: String?
    public var era: String?
    public var tempo: String?
    /// UGC ad: the format wheel (unboxing, review, try_on…).
    public var format: String?
    // Look: a palette and/or a film stock; the take is graded with it unless switched off
    public var palette: String?
    public var stock: String?
    public var gradeLook: Bool
    // Lighting
    public var lighting: String?
    /// The ready-made combo the settings started from (catalog `presets`).
    public var preset: String?

    public init(body: String? = nil, lens: String? = nil, focalMm: Double? = nil, aperture: String? = nil, height: String? = nil, shotSize: String? = nil,
                genre: String? = nil, era: String? = nil, tempo: String? = nil, palette: String? = nil, stock: String? = nil, gradeLook: Bool = true,
                lighting: String? = nil, preset: String? = nil, format: String? = nil) {
        self.format = format
        self.body = body
        self.lens = lens
        self.focalMm = focalMm
        self.aperture = aperture
        self.height = height
        self.shotSize = shotSize
        self.genre = genre
        self.era = era
        self.tempo = tempo
        self.palette = palette
        self.stock = stock
        self.gradeLook = gradeLook
        self.lighting = lighting
        self.preset = preset
    }

    /// "Reset all" in a picker: that chip back to Auto.
    public func reset(_ chip: ComposerChip) -> ComposerSettings {
        var s = self
        switch chip {
        case .references: break
        case .style: s.genre = nil; s.era = nil; s.tempo = nil; s.format = nil
        case .camera: s.body = nil; s.lens = nil; s.focalMm = nil; s.aperture = nil; s.height = nil; s.shotSize = nil
        case .look: s.palette = nil; s.stock = nil; s.gradeLook = true
        case .lighting: s.lighting = nil
        }
        return s
    }

    /// The picker's left-rail dot: does this chip have a non-Auto value?
    public func isSet(_ chip: ComposerChip) -> Bool {
        switch chip {
        case .references: return false
        case .style: return genre != nil || era != nil || tempo != nil || format != nil
        case .camera: return body != nil || lens != nil || focalMm != nil || aperture != nil || height != nil || shotSize != nil
        case .look: return palette != nil || stock != nil
        case .lighting: return lighting != nil
        }
    }

    /// Starts from a catalog preset: its values fill the chips, shown as their nearest visible options.
    public static func fromPreset(_ cat: CameraCatalog, _ id: String, gradeLook: Bool = true) -> ComposerSettings {
        guard let p = cat.presets.first(where: { $0.id == id })?.spec else { return ComposerSettings(gradeLook: gradeLook, preset: id) }
        return ComposerSettings(
            body: ComposerCatalog.survivor(cat.bodies, p.rig?.body), lens: ComposerCatalog.survivor(cat.lenses, p.rig?.lens),
            focalMm: p.rig?.focalMm.map { ComposerCatalog.nearestFocal(cat, $0) }, aperture: p.rig?.aperture.map { ComposerCatalog.nearestAperture(cat, $0) },
            height: p.angle?.height, shotSize: p.angle?.shotSize, genre: p.style?.genre, era: p.style?.era, tempo: p.style?.tempo,
            palette: p.palette?.preset, stock: p.rig?.look, gradeLook: gradeLook, lighting: p.lighting?.preset, preset: id)
    }

    /// The request's camera: only non-Auto values plus the prompt's #moves (first = move, second = mix). nil when all Auto.
    public func cameraSpec(moves: [PromptPart] = []) -> CameraSpec? {
        let rig = CameraRig(body: body, lens: lens, focalMm: focalMm, aperture: aperture, look: stock)
        let angle = CameraAngle(height: height, shotSize: shotSize)
        let style = CameraStyle(genre: genre, era: era, tempo: tempo, format: format)
        let mv = moves.compactMap { $0.move }
        let spec = CameraSpec(mode: "preset", rig: rig.isEmpty ? nil : rig, lighting: lighting.map { CameraLighting(preset: $0) },
                              palette: palette.map { CameraPalette(preset: $0) }, move: mv.first, mix: mv.count > 1 ? mv[1] : nil,
                              angle: angle == CameraAngle() ? nil : angle, style: style == CameraStyle() ? nil : style)
        return spec == CameraSpec(mode: "preset") ? nil : spec
    }
}

/// A chip as the composer draws it: its label and value ("Auto", the non-Auto values joined, or References "2/9").
public struct ChipSummary: Hashable, Sendable {
    public var chip: ComposerChip
    public var values: [String]
    public var auto: Bool
    public var counter: String?

    public var value: String { counter ?? (auto ? "Auto" : values.joined(separator: ", ")) }
    /// "Camera · 35mm film, Anamorphic", cut to `max` characters with "…".
    public func text(max: Int = 40) -> String { ComposerCatalog.ellipsize("\(chip.title) · \(value)", max) }
}

/// Catalog lookups the composer needs: labels through merges, the visible subsets, nearest visible steps.
public enum ComposerCatalog {
    public static func survivor(_ list: [SuiteOption], _ id: String?) -> String? {
        guard let id else { return nil }
        return list.first { $0.id == id }?.mergedInto ?? id
    }

    public static func label(_ list: [SuiteOption], _ id: String?) -> String? {
        guard let s = survivor(list, id) else { return nil }
        return list.first { $0.id == s }?.label ?? s
    }

    /// What members see in a group (the picker adds Auto as the first tile).
    public static func visible(_ list: [SuiteOption]) -> [SuiteOption] { list.filter(\.visible) }

    public static func focalSteps(_ cat: CameraCatalog) -> [Double] {
        let v = cat.focals.filter(\.visible).map(\.mm)
        return v.isEmpty ? cat.focalLengths : v
    }

    public static func focalLabel(_ cat: CameraCatalog, _ mm: Double) -> String {
        if let l = cat.focals.first(where: { $0.mm == mm })?.label, !l.isEmpty { return l }
        return "\(Int(mm))mm"
    }

    public static func nearestFocal(_ cat: CameraCatalog, _ mm: Double) -> Double { focalSteps(cat).min { abs($0 - mm) < abs($1 - mm) } ?? mm }

    /// The nearest visible aperture by f-number, in stops ("f2" → "f2.8", "f8" → "f11").
    public static func nearestAperture(_ cat: CameraCatalog, _ id: String) -> String {
        let vis = visible(cat.apertures)
        if vis.isEmpty || vis.contains(where: { $0.id == id }) { return id }
        guard let f = Double(id.dropFirst()) else { return id }
        let stops = { (o: SuiteOption) -> Double in Double(o.id.dropFirst()).map { abs(log($0 / f)) } ?? .greatestFiniteMagnitude }
        return vis.min { stops($0) < stops($1) }?.id ?? id
    }

    /// A UGC format's label ("Unboxing"); an id the catalog doesn't list yet reads as its own words ("try_on" → "Try on").
    public static func formatLabel(_ cat: CameraCatalog, _ id: String?) -> String? {
        guard let id else { return nil }
        if let l = cat.ugcFormats.first(where: { $0.id == id })?.label { return l }
        let words = id.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    public static func ellipsize(_ s: String, _ max: Int) -> String {
        guard s.count > max, max >= 2 else { return s }
        var t = String(s.prefix(max - 1))
        while let last = t.last, last == " " || last == "," || last == "·" { t.removeLast() }
        return t + "…"
    }

    /// A chip's summary: only the non-Auto values, in the picker's order. References shows "refs/refsMax" always.
    public static func summary(_ chip: ComposerChip, _ s: ComposerSettings, _ cat: CameraCatalog, refs: Int = 0, refsMax: Int = 0) -> ChipSummary {
        let values: [String]
        switch chip {
        case .references: return ChipSummary(chip: chip, values: [], auto: refs == 0, counter: "\(refs)/\(refsMax)")
        case .style: values = [formatLabel(cat, s.format), label(cat.genres, s.genre), label(cat.eras, s.era), label(cat.tempos, s.tempo)].compactMap { $0 }
        case .camera:
            values = [label(cat.bodies, s.body), label(cat.lenses, s.lens), s.focalMm.map { focalLabel(cat, $0) }, label(cat.apertures, s.aperture),
                      label(cat.heights, s.height), label(cat.shotSizes, s.shotSize)].compactMap { $0 }
        case .look: values = [label(cat.palettes, s.palette), label(cat.looks, s.stock)].compactMap { $0 }
        case .lighting: values = [label(cat.lighting, s.lighting)].compactMap { $0 }
        }
        return ChipSummary(chip: chip, values: values, auto: values.isEmpty, counter: nil)
    }

    public static func summaries(_ s: ComposerSettings, _ cat: CameraCatalog, refs: Int = 0, refsMax: Int = 0) -> [ChipSummary] {
        ComposerChip.allCases.map { summary($0, s, cat, refs: refs, refsMax: refsMax) }
    }
}

// MARK: - The prompt with tokens

/// One piece of the prompt. Tokens keep their `key` while they are moved around.
public enum PromptPart: Hashable, Sendable {
    case text(String)
    /// A camera move chip: intensity 0–100 (subtle → strong).
    case move(id: String, label: String, category: String, intensity: Int, key: Int)
    /// kind: character | outfit | location. `label` is what the prompt text says.
    case mention(kind: String, id: String, label: String, key: Int)

    public var key: Int? {
        switch self {
        case .text: return nil
        case .move(_, _, _, _, let k), .mention(_, _, _, let k): return k
        }
    }
    public var isText: Bool { if case .text = self { return true } else { return false } }
    public var text: String? { if case .text(let t) = self { return t } else { return nil } }
    /// The wire move of a #move chip.
    public var move: SuiteMove? {
        if case .move(let id, _, _, let i, _) = self { return SuiteMove(id: id, intensity: Double(min(max(i, 0), 100)) / 100) }
        return nil
    }
    var moveInfo: (id: String, label: String, category: String, intensity: Int)? {
        if case .move(let id, let l, let c, let i, _) = self { return (id, l, c, i) }
        return nil
    }
    var mentionInfo: (kind: String, id: String, label: String)? {
        if case .mention(let k, let id, let l, _) = self { return (k, id, l) }
        return nil
    }
}

/// Where to insert: a part and a character offset in it (for a token, 0 = before it, 1 = after it).
public struct Caret: Hashable, Sendable {
    public var part: Int
    public var offset: Int
    public init(_ part: Int, _ offset: Int) {
        self.part = part
        self.offset = offset
    }
}

/// The trigger being typed at the caret: `@` or `#`, the word after it, and where it started.
public struct PromptTrigger: Hashable, Sendable {
    public var char: Character
    public var query: String
    public var start: Int
}

public struct PromptTokens: Hashable, Sendable {
    public static let maxMoves = 2
    public var parts: [PromptPart]
    public init(_ parts: [PromptPart] = []) { self.parts = parts }
    public static func text(_ t: String) -> PromptTokens { PromptTokens([.text(t)]) }

    private var nextKey: Int { (parts.compactMap(\.key).max() ?? 0) + 1 }
    public var moves: [PromptPart] { parts.filter { $0.moveInfo != nil } }
    public var mentions: [PromptPart] { parts.filter { $0.mentionInfo != nil } }
    public var characterId: String? { mentions.compactMap(\.mentionInfo).first { $0.kind == "character" }?.id }
    public var outfitId: String? { mentions.compactMap(\.mentionInfo).first { $0.kind == "outfit" }?.id }
    public var isEmpty: Bool { parts.allSatisfy { ($0.text ?? "x").trimmingCharacters(in: .whitespaces).isEmpty } }
    public var caretAtEnd: Caret {
        guard let last = parts.last else { return Caret(0, 0) }
        return Caret(parts.count - 1, last.text?.count ?? 1)
    }

    private func inserting(_ token: PromptPart, at: Caret) -> PromptTokens {
        if parts.isEmpty { return PromptTokens([token]) }
        let i = min(max(at.part, 0), parts.count - 1)
        var out = parts
        if let t = parts[i].text {
            let o = min(max(at.offset, 0), t.count)
            let before = String(t.prefix(o)), after = String(t.dropFirst(o))
            out.remove(at: i)
            out.insert(contentsOf: [before.isEmpty ? nil : PromptPart.text(before), token, after.isEmpty ? nil : PromptPart.text(after)].compactMap { $0 }, at: i)
        } else if at.offset <= 0 {
            out.insert(token, at: i)
        } else {
            out.insert(token, at: i + 1)
        }
        return PromptTokens(out)
    }

    /// Adds a #move chip; refused (with the reason) at two moves or when the pair can't be mixed.
    public func addMove(_ m: SuiteMoveOption, at: Caret? = nil, intensity: Int = 50, catalog: CameraCatalog) -> (PromptTokens, String?) {
        let info = moves.compactMap(\.moveInfo)
        if info.contains(where: { $0.id == m.id }) { return (self, "\(m.label) is already in the shot") }
        if info.count >= Self.maxMoves { return (self, "Up to \(Self.maxMoves) moves · remove one first") }
        if let first = info.first, !Self.canMix(first.category, first.id, m.category, m.id) { return (self, "\(m.label) can't be combined with \(first.label)") }
        return (inserting(.move(id: m.id, label: m.label, category: m.category, intensity: intensity, key: nextKey), at: at ?? caretAtEnd), nil)
    }

    /// Adds an @ chip. One character and one outfit per shot (a new one replaces the old); an outfit needs a character.
    public func addMention(kind: String, id: String, label: String, at: Caret? = nil) -> (PromptTokens, String?) {
        if kind == "outfit" && characterId == nil { return (self, "Pick a character first") }
        if kind == "location", mentions.contains(where: { $0.mentionInfo?.kind == "location" && $0.mentionInfo?.id == id }) { return (self, "\(label) is already in the shot") }
        if kind != "location", let i = parts.firstIndex(where: { $0.mentionInfo?.kind == kind }), let old = parts[i].mentionInfo, let k = parts[i].key {
            if old.id == id { return (self, nil) }
            var out = parts
            out[i] = .mention(kind: kind, id: id, label: label, key: k)
            return (PromptTokens(out), "\(old.label) replaced by \(label)")
        }
        return (inserting(.mention(kind: kind, id: id, label: label, key: nextKey), at: at ?? caretAtEnd), nil)
    }

    /// Removes a token (the character takes the outfit with it); neighbouring texts join up.
    public func remove(key: Int) -> PromptTokens {
        guard let gone = parts.first(where: { $0.key == key }) else { return self }
        var drop: Set<Int> = [key]
        if gone.mentionInfo?.kind == "character", let o = parts.first(where: { $0.mentionInfo?.kind == "outfit" })?.key { drop.insert(o) }
        return PromptTokens(parts.filter { p in p.key.map { !drop.contains($0) } ?? true }).joined()
    }

    /// Moves a token to another place (drag to reorder).
    public func reorder(key: Int, to index: Int) -> PromptTokens {
        guard let i = parts.firstIndex(where: { $0.key == key }) else { return self }
        var out = parts
        let t = out.remove(at: i)
        out.insert(t, at: min(max(index, 0), out.count))
        return PromptTokens(out).joined()
    }

    /// Drag to reorder: the token goes where it was dropped (a caret in the parts as they are now, a text split there).
    /// Dropping it on itself, or right next to itself, changes nothing.
    public func move(key: Int, to caret: Caret) -> PromptTokens {
        guard let i = parts.firstIndex(where: { $0.key == key }) else { return self }
        if caret.part == i { return self }
        let token = parts[i]
        var rest = parts
        rest.remove(at: i)
        let at = caret.part > i ? Caret(caret.part - 1, caret.offset) : caret
        return PromptTokens(rest).inserting(token, at: at).joined()
    }

    /// The caret at a UTF-16 offset of the text as the editor shows it (a token is one character).
    public func caret(utf16 offset: Int) -> Caret {
        var pos = 0
        for (i, p) in parts.enumerated() {
            if let t = p.text {
                let len = (t as NSString).length
                if offset <= pos + len {
                    let o = min(max(offset - pos, 0), len)
                    let idx = String.Index(utf16Offset: o, in: t)
                    return Caret(i, t.distance(from: t.startIndex, to: idx))
                }
                pos += len
            } else {
                if offset <= pos { return Caret(i, 0) }
                if offset == pos + 1 { return Caret(i, 1) }
                pos += 1
            }
        }
        return caretAtEnd
    }

    public func setIntensity(key: Int, _ v: Int) -> PromptTokens {
        PromptTokens(parts.map { p in
            if case .move(let id, let l, let c, _, let k) = p, k == key { return .move(id: id, label: l, category: c, intensity: min(max(v, 0), 100), key: k) }
            return p
        })
    }

    public func setText(part i: Int, _ t: String) -> PromptTokens {
        guard parts.indices.contains(i), parts[i].isText else { return self }
        var out = parts
        out[i] = .text(t)
        return PromptTokens(out)
    }

    private func joined() -> PromptTokens {
        var out: [PromptPart] = []
        for p in parts {
            if let t = p.text, let last = out.last?.text { out[out.count - 1] = .text(last + t) } else { out.append(p) }
        }
        return PromptTokens(out)
    }

    /// The prompt the server gets: mentions as their names, #moves left out (they go in camera.move / mix). Spaces tidied.
    public func promptText() -> String {
        let raw = parts.map { p -> String in
            if let t = p.text { return t }
            if let m = p.mentionInfo { return " \(m.label) " }
            return " "
        }.joined()
        var s = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ([,.!?;:])", with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// How the chips read inline ("@Maya walks in #Dolly in").
    public func display() -> String {
        parts.map { p in p.text ?? (p.mentionInfo.map { "@\($0.label)" } ?? p.moveInfo.map { "#\($0.label)" } ?? "") }.joined()
    }

    /// The server's rule: two moves of different kinds, never with static, time or aerial moves.
    public static func canMix(_ catA: String, _ idA: String, _ catB: String, _ idB: String) -> Bool {
        let solo: Set<String> = ["static", "time", "aerial"]
        return idA != idB && catA != catB && !solo.contains(catA) && !solo.contains(catB)
    }

    /// The `@` or `#` word being typed at `caret` (no space between it and the caret), or nil.
    public static func activeTrigger(_ text: String, caret: Int) -> PromptTrigger? {
        let chars = Array(text)
        let c = min(max(caret, 0), chars.count)
        var i = c - 1
        while i >= 0 {
            let ch = chars[i]
            if ch == "@" || ch == "#" {
                guard i == 0 || chars[i - 1].isWhitespace else { return nil }
                return PromptTrigger(char: ch, query: String(chars[(i + 1)..<c]), start: i)
            }
            if ch.isWhitespace { return nil }
            i -= 1
        }
        return nil
    }

    /// Moves matching a # query (label or id), the catalog's featured moves first.
    public static func searchMoves(_ cat: CameraCatalog, _ query: String) -> [SuiteMoveOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let featured = cat.library.map(\.id)
        return cat.moves.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.id.replacingOccurrences(of: "_", with: " ").contains(q) }
            .sorted { (featured.firstIndex(of: $0.id) ?? Int.max) < (featured.firstIndex(of: $1.id) ?? Int.max) }
    }
}

/// The shot request a composer sends (bottom-bar values passed through; `gradeLook` sent only when it is off and a Look is set).
public func composerRequest(_ tokens: PromptTokens, _ s: ComposerSettings, quality: String = "draft", aspectRatio: String = "9:16", duration: Int = 5,
                            takes: Int = 1, speaking: Bool? = nil, title: String? = nil) -> ShotRequest {
    var r = ShotRequest(title: title, modelId: tokens.characterId, outfitId: tokens.outfitId, prompt: tokens.promptText(), duration: duration,
                        aspectRatio: aspectRatio, quality: quality, takes: takes, speaking: speaking, camera: s.cameraSpec(moves: tokens.moves))
    if !s.gradeLook && (s.palette != nil || s.stock != nil) { r.gradeLook = false }
    return r
}

/// The server's Look rule (suite/looks.ts shotLook): the palette, else the film stock, presets included; none when off.
public enum SuiteLooks {
    public static func look(for r: ShotRequest, camera cat: CameraCatalog) -> SuiteLook? {
        if r.gradeLook == false { return nil }
        guard let c = r.camera else { return nil }
        let p = c.preset.flatMap { id in cat.presets.first { $0.id == id }?.spec }
        let pal = c.palette?.preset ?? p?.palette?.preset
        let stock = c.rig?.look ?? p?.rig?.look
        if let o = cat.palettes.first(where: { $0.id == pal }), let lut = o.lut { return SuiteLook(id: o.id, kind: "palette", label: o.label, lut: lut) }
        if let o = cat.looks.first(where: { $0.id == stock }), let lut = o.lut { return SuiteLook(id: o.id, kind: "stock", label: o.label, lut: lut) }
        return nil
    }
}
