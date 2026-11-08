import Foundation

/// Claude in the AI Suite: the chat's chips, the context line each message carries (the shared draft's id and revision and
/// the composer as it is now, so the owner's own edits are in front of Claude on every turn) and demo mode's stand-in reply.
public enum SuiteAssistClaude {
    // MARK: Chips

    public static let fillPrompt = "Fill in the composer from my idea in the prompt: the character, the prompt and every Setup row, using only options the composer offers (suite_options, then suite_set_draft). Then tell me in a few lines what you set."
    public static let cinematicPrompt = "Make this shot more cinematic: change the camera, light, look and style rows with suite_set_draft. Keep my prompt and character. Tell me briefly what you changed."
    public static let explainPrompt = "Explain the settings in the composer now, row by row, in plain words. Don't change anything."

    public static var suggestions: [RecreateClaude.Suggestion] {
        [RecreateClaude.Suggestion(label: "Fill this in from my idea", prompt: fillPrompt),
         RecreateClaude.Suggestion(label: "Make it more cinematic", prompt: cinematicPrompt),
         RecreateClaude.Suggestion(label: "Explain the settings", prompt: explainPrompt)]
    }

    // MARK: The context line

    /// "[Suite · draft sa_1 rev 3 · Shot · Draft, 9:16, 8 s, 1 take · Camera: Cinema camera, Anamorphic · Light: Auto · … ·
    /// prompt: “…”]". Rows Claude's last draft couldn't set are listed, so it can choose again.
    public static func context(assistId: String?, revision: Int?, composer d: ComposerDraft, camera: CameraCatalog,
                               characterName: String? = nil, rejected: [SuiteDraftRejection] = []) -> String {
        var parts = ["Suite"]
        if let id = assistId { parts.append("draft \(id)" + (revision.map { " rev \($0)" } ?? "")) }
        parts.append(d.tool.title)
        parts.append("\(SuiteText.tierLabel(d.quality)), \(d.aspect), \(d.duration) s, \(d.takes) take\(d.takes == 1 ? "" : "s")")
        for chip in [ComposerChip.camera, .lighting, .look, .style] where d.tool.chips.contains(chip) {
            let s = ComposerCatalog.summary(chip, d.settings, camera)
            parts.append("\(chip == .lighting ? "Light" : chip.title): \(s.value)")
        }
        if let n = characterName { parts.append("character: \(n)") }
        let moves = d.tokens.moves.compactMap { $0.moveInfo?.label }
        if !moves.isEmpty { parts.append("moves: \(moves.joined(separator: ", "))") }
        let text = d.tokens.promptText()
        parts.append(text.isEmpty ? "prompt: empty" : "prompt: “\(String(text.prefix(280)))”")
        if !rejected.isEmpty { parts.append("not applied: " + rejected.prefix(4).map(\.text).joined(separator: "; ")) }
        return "[" + parts.joined(separator: " · ") + "]"
    }

    public static func message(_ text: String, context: String) -> String { "\(context)\n\(text)" }

    /// What the owner typed, without the context line.
    public static func stripContext(_ text: String) -> String {
        guard text.hasPrefix("[Suite"), let nl = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: nl)...])
    }

    // MARK: Demo mode

    /// Demo mode's stand-in for Claude: a reply, the draft it would set with suite_set_draft, and whether the owner said go
    /// (then a paid ask is made, which the owner still has to approve).
    public struct DemoReply: Sendable {
        public var text: String
        public var draft: SuiteDraft?
        public var generate: Bool
    }

    /// Fills the composer from the typed words: a character the text names, the words as the prompt, and every rig row the
    /// tool uses, from options whose names appear in the text, then a few keyword looks, then a calm default. Only visible
    /// options. "Explain the settings" changes nothing; a short "go" asks to generate.
    public static func demoReply(to raw: String, composer d: ComposerDraft, options: SuiteDraftOptions) -> DemoReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = text.lowercased()
        let cam = options.camera
        if text == explainPrompt || low.hasPrefix("explain") {
            return DemoReply(text: explain(d, cam), draft: nil, generate: false)
        }
        let words = low.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let goWords: Set<String> = ["go", "generate", "render", "shoot", "yes", "ok", "okay"]
        if words.count <= 4, words.contains(where: goWords.contains) {
            return DemoReply(text: "Asking to generate it now. Check the price and confirm, or change anything first.", draft: nil, generate: true)
        }

        var out = d
        let cinematic = text == cinematicPrompt || low.contains("cinematic")
        let fromIdea = text == fillPrompt
        // The prompt: the owner's words, unless a chip asked (then the prompt box is the idea).
        var idea = fromIdea || text == cinematicPrompt ? d.tokens.parts.compactMap(\.text).joined() : text
        if idea.trimmingCharacters(in: .whitespaces).isEmpty { idea = " walks into a quiet café at golden hour and turns to camera with a soft smile." }
        // The words the rows are picked from: the idea itself when a chip asked.
        let basis = fromIdea || text == cinematicPrompt ? idea.lowercased() : low
        var character = d.tokens.characterId.flatMap { id in options.characters[id].map { (id, $0) } }
        if let hit = options.characters.sorted(by: { $0.value < $1.value }).first(where: { basis.contains($0.value.lowercased()) }) { character = (hit.key, hit.value) }

        var tokens = PromptTokens()
        if let c = character { tokens = tokens.addMention(kind: "character", id: c.0, label: c.1).0 }
        let body = character.map { c in idea.replacingOccurrences(of: c.1, with: "", options: .caseInsensitive) } ?? idea
        tokens = PromptTokens(tokens.parts + [.text((character == nil ? "" : " ") + body.trimmingCharacters(in: .whitespaces))])

        // Rig rows.
        let hay = cinematic ? basis + " cinema anamorphic contre-jour teal drama steady low angle" : basis
        func find(_ list: [SuiteOption], _ fallback: String?) -> String? {
            let vis = ComposerCatalog.visible(list)
            if let o = vis.first(where: { hay.contains($0.label.lowercased()) }) { return o.id }
            return fallback.flatMap { f in vis.first { $0.id == f }?.id }
        }
        func keyword(_ pairs: [(String, String)], _ list: [SuiteOption], _ fallback: String) -> String? {
            find(list, pairs.first(where: { hay.contains($0.0) })?.1 ?? fallback)
        }
        var s = ComposerSettings(gradeLook: d.settings.gradeLook)
        let tool = d.tool
        if tool.chips.contains(.camera) {
            s.body = keyword([("cinema", "cinema_digital"), ("film", "film_35"), ("phone", "phone"), ("selfie", "phone"), ("vlog", "vlog")], cam.bodies, "cinema_digital")
            s.lens = keyword([("anamorphic", "anamorphic"), ("vintage", "warm_vintage"), ("dream", "halation")], cam.lenses, cinematic ? "anamorphic" : "clean")
            let steps = ComposerCatalog.focalSteps(cam)
            s.focalMm = (basis.contains("close") ? 85 : basis.contains("wide") ? 24 : 35).nearest(in: steps)
            s.aperture = find(cam.apertures, "f2.8")
            s.height = keyword([("low angle", "low"), ("overhead", "overhead"), ("high angle", "high")], cam.heights, "eye")
            s.shotSize = keyword([("close", "cu"), ("wide", "ls"), ("full body", "full")], cam.shotSizes, "ms")
        }
        if tool.chips.contains(.lighting) {
            s.lighting = keyword([("café", "window"), ("cafe", "window"), ("coffee", "window"), ("sunset", "golden_hour"), ("golden", "golden_hour"),
                                  ("night", "neon"), ("neon", "neon"), ("studio", "studio_3pt"), ("contre", "contre_jour")], cam.lighting, "natural")
        }
        if tool.chips.contains(.look) {
            s.palette = keyword([("golden", "golden_warmth"), ("sunset", "golden_warmth"), ("night", "moody_blue"), ("neon", "hyper_neon"), ("teal", "teal_orange"),
                                 ("retro", "retro_80s"), ("vintage", "vintage_fade")], cam.palettes, "naturalistic")
        }
        if tool.chips.contains(.style) {
            s.genre = keyword([("advert", "commercial"), ("product", "commercial"), ("tiktok", "ugc"), ("ugc", "ugc"), ("drama", "drama"), ("fashion", "fashion")],
                              cam.genres, "commercial")
            if tool != .photo { s.tempo = keyword([("slow", "slow_motion"), ("calm", "calm"), ("fast", "dynamic"), ("energy", "dynamic")], cam.tempos, "steady") }
            if tool == .ugc { s.format = find(cam.ugcFormats, "review") }
        }
        out.settings = s
        // One #move that suits the words (none in a still).
        if tool != .photo {
            let move = [("orbit", "orbit_left"), ("handheld", "handheld"), ("follow", "follow"), ("crane", "crane_up"), ("push", "dolly_in"), ("dolly", "dolly_in")]
                .first(where: { hay.contains($0.0) })?.1 ?? (cinematic ? "dolly_in" : "micro_push")
            if let m = cam.move(move) { tokens = tokens.addMove(m, intensity: 40, catalog: cam).0 }
        }
        out.tokens = tokens
        if basis.contains("vertical") || basis.contains("tiktok") || basis.contains("reel") { out.aspect = "9:16" }
        if basis.contains("widescreen") || cinematic { out.aspect = "16:9" }

        let set = SuiteAssistDraft.changedRows(d, out).filter { !["Prompt", "Character"].contains($0) }
        var reply = cinematic ? "Made it more cinematic." : "Filled in the composer from your idea."
        let rows = [ComposerChip.camera, .lighting, .look, .style].filter { tool.chips.contains($0) }.map { chip -> String in
            "\(chip == .lighting ? "Light" : chip.title): \(ComposerCatalog.summary(chip, s, cam).value)"
        }
        if !rows.isEmpty { reply += " " + rows.joined(separator: ". ") + "." }
        if set.isEmpty { reply += " Nothing else needed changing." }
        reply += " Change anything by hand and I'll work from that. Say go when you want to see the price."
        return DemoReply(text: reply, draft: ComposerDrafts.draft(out), generate: false)
    }

    private static func explain(_ d: ComposerDraft, _ cam: CameraCatalog) -> String {
        var lines: [String] = []
        for chip in [ComposerChip.camera, .lighting, .look, .style] where d.tool.chips.contains(chip) {
            let s = ComposerCatalog.summary(chip, d.settings, cam)
            let name = chip == .lighting ? "Light" : chip.title
            lines.append(s.auto ? "\(name) is on Auto, so it's chosen for the shot." : "\(name) is \(s.value).")
        }
        lines.append("It renders at \(SuiteText.tierLabel(d.quality)), \(d.aspect), \(d.duration) seconds, \(d.takes) take\(d.takes == 1 ? "" : "s").")
        return lines.joined(separator: " ")
    }
}

private extension Int {
    func nearest(in steps: [Double]) -> Double {
        steps.min { abs($0 - Double(self)) < abs($1 - Double(self)) } ?? Double(self)
    }
}
