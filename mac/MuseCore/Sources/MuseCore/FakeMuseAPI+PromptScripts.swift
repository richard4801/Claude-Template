import Foundation

// Prompt scripts (workstream 4): demo mode's Settings → Prompts → Scripts. Two scripts transcribed from the server's
// server/api/src/prompt/scripts/defs.ts (photoshoot and video.replicate), the server's validation and a local preview.

/// The demo backend's scripts, with the server's wording and default rules.
public enum PromptScriptDemo {
    private static func bool(_ name: String, _ label: String, _ description: String, _ sample: Bool = true) -> ScriptInputDef {
        ScriptInputDef(name: name, label: label, description: description, type: "bool", sample: .bool(sample))
    }

    private static func opts(_ pairs: [(String, String)]) -> [ScriptOption] { pairs.map { ScriptOption(id: $0.0, label: $0.1) } }

    private static func rule(_ id: String, _ label: String, _ target: String, _ block: String, _ when: [ScriptCond] = [], optional opt: Bool = false,
                             locked: Bool = false) -> ScriptRule {
        ScriptRule(id: id, label: label, target: target, when: when, block: block, optional: opt ? true : nil, locked: locked ? true : nil)
    }

    private static func isTrue(_ input: String, _ v: Bool) -> ScriptCond { ScriptCond(input: input, op: "is", value: .bool(v)) }
    private static func isValue(_ input: String, _ v: String) -> ScriptCond { ScriptCond(input: input, op: "is", value: .string(v)) }

    public static let photoshoot: ScriptView = {
        let refs = ScriptInputDef(
            name: "refs", label: "Reference images", description: "The reference images sent (after her own), each with what it guides.", type: "list",
            fields: [
                ScriptInputDef(name: "refIndex", label: "Image number", description: "Its 1-based number among the images sent.", type: "number", sample: .number(8)),
                ScriptInputDef(name: "guides", label: "Guides", description: "What it guides.", type: "list",
                               options: PromptScriptDemo.opts([("pose", "Pose & framing"), ("look", "Look & colour"), ("scene", "Scene")]),
                               sample: .array([.string("pose"), .string("look"), .string("scene")])),
            ],
            sample: .array([.object(["refIndex": .number(8), "guides": .array([.string("pose"), .string("look"), .string("scene")])])]))
        let inputs = [
            PromptScriptDemo.bool("presets", "Presets on", "The Presets switch. Off removes the optional style blocks (scene, camera, light, style, never-add)."),
            PromptScriptDemo.bool("lockSeed", "Lock look", "Lock look is on (a fixed seed for her).", false),
            ScriptInputDef(name: "outfitSource", label: "Outfit", description: "Where the outfit comes from.", type: "enum",
                           options: PromptScriptDemo.opts([("set", "Reference set (photos)"), ("described", "Described in words"), ("product", "Product photo")]), sample: .string("set")),
            ScriptInputDef(name: "lens", label: "Lens (mm)", description: "The lens in mm.", type: "number", sample: .number(35)),
            refs,
        ]
        let sections = [
            ScriptSection(id: "identity", label: "Identity"), ScriptSection(id: "outfit", label: "Outfit"), ScriptSection(id: "scene", label: "Scene"),
            ScriptSection(id: "camera", label: "Camera"), ScriptSection(id: "light", label: "Light"),
            ScriptSection(id: "direction", label: "Direction from the user", kind: "user"),
            ScriptSection(id: "reference", label: "Reference images", each: "refs", pick: "all", join: " "),
            ScriptSection(id: "style", label: "Style"), ScriptSection(id: "negative", label: "Never add"), ScriptSection(id: "seed", label: "Seed"),
        ]
        let guide = { (g: String) in ScriptCond(input: "item.guides", op: "has", value: .string(g)) }
        let rules = [
            PromptScriptDemo.rule("identity", "Who she is", "identity", "shoot.identity", locked: true),
            PromptScriptDemo.rule("outfit.described", "Outfit described in words", "outfit", "shoot.outfit.described", [PromptScriptDemo.isValue("outfitSource", "described")]),
            PromptScriptDemo.rule("outfit.product", "Outfit from a product photo", "outfit", "shoot.outfit.product", [PromptScriptDemo.isValue("outfitSource", "product")]),
            PromptScriptDemo.rule("outfit.set", "Outfit reference set", "outfit", "shoot.outfit.set"),
            PromptScriptDemo.rule("scene", "The place", "scene", "shoot.scene", optional: true),
            PromptScriptDemo.rule("camera", "Shot size, lens and aperture", "camera", "shoot.camera", optional: true),
            PromptScriptDemo.rule("lens.wide", "Wide lens note (24 mm and wider)", "@lensNote", "shoot.camera.wide", [ScriptCond(input: "lens", op: "atMost", value: .number(24))]),
            PromptScriptDemo.rule("lens.tele", "Long lens note (85 mm and longer)", "@lensNote", "shoot.camera.tele", [ScriptCond(input: "lens", op: "atLeast", value: .number(85))]),
            PromptScriptDemo.rule("light", "Light and grade", "light", "shoot.light", optional: true),
            PromptScriptDemo.rule("direction", "The user’s direction", "direction", "shoot.direction", locked: true),
            PromptScriptDemo.rule("refs.pose", "Guides pose & framing", "reference", "refs.pose", [guide("pose")]),
            PromptScriptDemo.rule("refs.look", "Guides look & colour", "reference", "refs.look", [guide("look")]),
            PromptScriptDemo.rule("refs.scene", "Guides the scene", "reference", "refs.scene", [guide("scene")]),
            PromptScriptDemo.rule("refs.guard", "Never her face, body or clothes from a reference", "reference", "refs.guard", locked: true),
            PromptScriptDemo.rule("style", "House style", "style", "shoot.style", optional: true),
            PromptScriptDemo.rule("never", "Never add", "negative", "shoot.never", optional: true, locked: true),
            PromptScriptDemo.rule("seed.locked", "Lock look on", "seed", "shoot.seed.locked", [PromptScriptDemo.isTrue("lockSeed", true)]),
            PromptScriptDemo.rule("seed.new", "New look each shot", "seed", "shoot.seed.new"),
        ]
        let vars = [
            ScriptVar(name: "name", description: "her name", sample: "Demo model"),
            ScriptVar(name: "look", description: "her written look", sample: "young woman, shoulder-length dark brown hair"),
            ScriptVar(name: "refCount", description: "how many sheet images she has", sample: "7"),
            ScriptVar(name: "lora", description: "\" + LoRA demo_v2 (photo)\" or empty", sample: ""),
            ScriptVar(name: "outfit", description: "the outfit", sample: "green set"),
            ScriptVar(name: "style", description: "the house style", sample: "realistic smartphone photo"),
            ScriptVar(name: "never", description: "her never-add list plus the base list", sample: "tattoos, rings, logos"),
            ScriptVar(name: "scene", description: "the scene, lower case", sample: "rooftop · golden hour"),
            ScriptVar(name: "shot", description: "close, medium, full or wide", sample: "medium"),
            ScriptVar(name: "aperture", description: "f/2.8 …", sample: "f/2.8"),
            ScriptVar(name: "light", description: "the light, lower case", sample: "golden hour"),
            ScriptVar(name: "grade", description: "the grade, lower case", sample: "phone-natural"),
        ]
        return ScriptView(id: "photoshoot", group: "photoshoot", title: "Photo", description: "Every still from the Photo tool (no template).", format: "lines",
                          inputs: inputs, sections: sections, values: [ScriptValueSlot(name: "lensNote", label: "Lens note")], vars: vars, defaultRules: rules)
    }()

    public static let videoReplicate: ScriptView = {
        let speaking = PromptScriptDemo.bool("speaking", PerformerSpeaking.title,
                            "The performer speaks or sings in the clip (detected from its audio; the user can switch it). Off: the clip is sent without audio and its audio is put back afterwards.")
        let sections = [
            ScriptSection(id: "subjects", label: "Subjects", heading: "subject_definitions:"),
            ScriptSection(id: "summary", label: "Summary", heading: "summary:"),
            ScriptSection(id: "retention", label: "Retention", heading: "retention_analysis:"),
            ScriptSection(id: "detailed", label: "Details", heading: "detailed_description:", pick: "all", join: " "),
            ScriptSection(id: "user", label: "Direction from the user", kind: "user"),
        ]
        let rules = [
            PromptScriptDemo.rule("subjects", "Who is who", "subjects", "video.replicate.subjects", locked: true),
            PromptScriptDemo.rule("summary.silent", "Not speaking: no lip-sync", "summary", "video.replicate.summary.silent", [PromptScriptDemo.isTrue("speaking", false)]),
            PromptScriptDemo.rule("summary", "Copy the facial performance", "summary", "video.replicate.summary"),
            PromptScriptDemo.rule("retention", "What is kept", "retention", "video.replicate.retention", locked: true),
            PromptScriptDemo.rule("detailed.silent", "Not speaking: no mouthed words", "detailed", "video.replicate.detailed.silent", [PromptScriptDemo.isTrue("speaking", false)]),
            PromptScriptDemo.rule("detailed", "Details", "detailed", "video.replicate.detailed", [PromptScriptDemo.isTrue("speaking", true)]),
            PromptScriptDemo.rule("mouth.speaking", "Speaking: mouth in sync with the speech", "detailed", "video.mouth.speaking", [PromptScriptDemo.isTrue("speaking", true)]),
            PromptScriptDemo.rule("mouth.silent", "Not speaking: mouth follows the clip, no words", "detailed", "video.mouth.silent", [PromptScriptDemo.isTrue("speaking", false)]),
            PromptScriptDemo.rule("user", "The user’s direction", "user", "video.user.direction", locked: true),
        ]
        let vars = [
            ScriptVar(name: "subject", description: "the person in <Image 1> to <Image n>: her look", sample: "the person in <Image 1> to <Image 5>: young woman"),
            ScriptVar(name: "reference", description: "face, body and outfit image ranges and the never-add list", sample: "face and identity from <Image 1> and <Image 2>"),
            ScriptVar(name: "faceRef", description: "<Image 1>, or \"the description\"", sample: "<Image 1>"),
        ]
        return ScriptView(id: "video.replicate", group: "video", title: "Character swap · Draft/Standard/HD",
                          description: "The short prompt for the hosted video model: her face, body and outfit replace the performer of the clip.", format: "sections",
                          inputs: [speaking, PromptScriptDemo.bool("audioSent", "Clip audio sent", "The clip is sent with its audio (only when the performer speaks).")],
                          sections: sections, vars: vars, defaultRules: rules)
    }()

    public static let scripts: [ScriptView] = [photoshoot, videoReplicate]
}

extension FakeMuseAPI {
    private func scriptOwnerOnly() throws {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can change prompts") }
    }

    private func scriptDef(_ id: String) throws -> ScriptView {
        guard let s = PromptScriptDemo.scripts.first(where: { $0.id == id }) else { throw ApiError("not_found", "Prompt script not found") }
        return s
    }

    /// The demo studio's view of a script: its saved rules, or the defaults.
    func scriptView(_ id: String) throws -> ScriptView {
        var v = try scriptDef(id)
        if let saved = scriptOverrides[id] {
            v.rules = saved
            v.overridden = true
            v.updatedAt = scriptUpdated[id]
            v.updatedBy = "you@studio.com"
        }
        return v
    }

    public func promptScripts() async throws -> PromptScriptsList {
        try scriptOwnerOnly()
        return PromptScriptsList(groups: PromptLibraryDefaults.groups, ops: CondOpInfo.defaults, scripts: try PromptScriptDemo.scripts.map { try scriptView($0.id) })
    }

    public func promptScript(id: String) async throws -> ScriptView {
        try scriptOwnerOnly()
        return try scriptView(id)
    }

    public func savePromptScript(id: String, rules: [ScriptRule]) async throws -> ScriptView {
        try scriptOwnerOnly()
        let def = try scriptDef(id)
        if let why = ScriptEngine.validate(def, rules) { throw ApiError("script_invalid", why) }
        let cleaned = rules.map(\.cleaned)
        // Saving the defaults clears the override.
        if cleaned == def.defaultRules.map(\.cleaned) { scriptOverrides[id] = nil } else { scriptOverrides[id] = cleaned }
        scriptUpdated[id] = nowMs()
        let out = try scriptView(id)
        hub.emit(ApiEvent(type: "promptScript", script: out))
        return out
    }

    public func resetPromptScript(id: String) async throws -> ScriptView {
        try scriptOwnerOnly()
        _ = try scriptDef(id)
        scriptOverrides[id] = nil
        let out = try scriptView(id)
        hub.emit(ApiEvent(type: "promptScript", script: out))
        return out
    }

    public func previewPromptScript(_ req: ScriptPreviewRequest) async throws -> ScriptPreview {
        try scriptOwnerOnly()
        let s = try scriptView(req.id)
        let rules = req.rules ?? s.rules
        if req.rules != nil, let why = ScriptEngine.validate(s, rules) { throw ApiError("script_invalid", why) }
        var texts: [String: String] = [:]
        for k in s.blocks { texts[k] = promptText(k) }
        for (k, v) in req.texts ?? [:] where s.blocks.contains(k) { texts[k] = v }
        var inputs = s.sampleInputs
        for (k, v) in req.inputs ?? [:] { inputs[k] = v }
        let direction = req.direction.map { String($0.prefix(500)) } ?? "smiling, glancing at the camera"
        return ScriptEngine.run(s, inputs: inputs, rules: rules, texts: texts, direction: direction)
    }
}
