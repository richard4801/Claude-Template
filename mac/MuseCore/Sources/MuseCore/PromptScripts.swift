import Foundation

// Prompt scripts (workstream 4; plans/prompt-scripts.md, contract: plans/api.md "Prompt scripts (2026-11-05)").
// Every prompt the server sends to a model is assembled by a script: typed inputs → rules → blocks (the prompt library
// entries). The owner edits the rules in Settings → Prompts → Scripts; members never see any of it. The one member-facing
// piece is the video studio's "Performer is speaking" switch, pre-set from the clip's talking detection.

// MARK: - Talking detection and the "Performer is speaking" switch

/// `Clip.audio`: the clip's audio, classified on upload. Absent while the detection still runs (a second `clip` event brings
/// it) or when it failed.
public struct ClipAudio: Codable, Hashable, Sendable {
    /// speech | music | silence | none
    public var kind: String
    public var speaking: Bool
    /// false when only the upload said "talking" (no detection result).
    public var detected: Bool

    public init(kind: String, speaking: Bool, detected: Bool = true) {
        self.kind = kind
        self.speaking = speaking
        self.detected = detected
    }

    enum CodingKeys: String, CodingKey { case kind, speaking, detected }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = c.v(.kind, "none")
        speaking = c.v(.speaking, false)
        detected = c.v(.detected, false)
    }

    /// The demo backend's stand-in for the detection: upload meta `talking: true` means speech (and wins, like the server);
    /// anything else reads as music nobody sings to.
    public static func demo(talking: Bool) -> ClipAudio {
        talking ? ClipAudio(kind: "speech", speaking: true, detected: false) : ClipAudio(kind: "music", speaking: false, detected: true)
    }
}

/// The video studio's "Performer is speaking" switch (sent as `JobRequest.speaking`).
public enum PerformerSpeaking {
    public static let title = "Performer is speaking"
    public static let onHint = "She talks or sings: her lips follow the clip's sound"
    public static let offHint = "Her mouth follows the clip; she won't lip-sync to the music"

    public static func hint(_ on: Bool) -> String { on ? onHint : offHint }

    /// The switch's starting value for a clip: its detection, off when unknown (no clip, still running, or failed).
    public static func preset(_ clip: Clip?) -> Bool { clip?.audio?.speaking ?? false }

    /// The switch after the selected clip changed from `old` to `new`. Another clip (or none): its preset. The same clip whose
    /// detection just arrived (a later `clip` event): the preset, unless the user has already flipped the switch. Otherwise unchanged.
    public static func after(_ old: Clip?, _ new: Clip?, current: Bool, touched: Bool) -> Bool {
        if old?.id != new?.id { return preset(new) }
        if !touched, old?.audio == nil, new?.audio != nil { return preset(new) }
        return current
    }
}

// MARK: - Wire types

/// An `{id, label}` pair: enum options, rule places (`targets`).
public struct ScriptOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case id, label }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        label = c.v(.label, id)
    }
}

/// A typed fact about the job. `type`: bool | enum | number | text | list. A list of items has `fields` (conditions inside a
/// section that repeats per item use "item.<field>"); a list of strings has `options`. `sample` is what the preview uses.
public struct ScriptInputDef: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String
    public var description: String
    public var type: String
    public var options: [ScriptOption]?
    public var fields: [ScriptInputDef]?
    public var sample: JSONValue
    public var id: String { name }

    public init(name: String, label: String, description: String = "", type: String, options: [ScriptOption]? = nil, fields: [ScriptInputDef]? = nil,
                sample: JSONValue = .null) {
        self.name = name
        self.label = label
        self.description = description
        self.type = type
        self.options = options
        self.fields = fields
        self.sample = sample
    }

    enum CodingKeys: String, CodingKey { case name, label, description, type, options, fields, sample }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "")
        label = c.v(.label, name)
        description = c.v(.description, "")
        type = c.v(.type, "text")
        options = c.o(.options)
        fields = c.o(.fields)
        sample = c.v(.sample, JSONValue.null)
    }

    /// "Yes / no", "Menu", "Number", "Text", "List": the Inputs list's type column.
    public var typeLabel: String {
        switch type {
        case "bool": return "Yes / no"
        case "enum": return "Menu"
        case "number": return "Number"
        case "list": return fields != nil ? "List of items" : "List"
        default: return "Text"
        }
    }

    public func optionLabel(_ id: String) -> String { options?.first { $0.id == id }?.label ?? id }
}

/// One condition of a rule: an input (or "item.<field>"), a test (`op`) and a value (none for empty / notEmpty).
public struct ScriptCond: Codable, Hashable, Sendable {
    public var input: String
    /// is | isNot | in | notIn | atLeast | atMost | has | hasNot | empty | notEmpty
    public var op: String
    public var value: JSONValue?

    public init(input: String, op: String, value: JSONValue? = nil) {
        self.input = input
        self.op = op
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case input, op, value }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        input = c.v(.input, "")
        op = c.v(.op, "is")
        value = c.o(.value)
    }

    /// empty / notEmpty take no value.
    public var needsValue: Bool { CondOpInfo.needsValue(op) }
}

/// A rule puts one block somewhere (a section id, or "@name" = the value of the {name} placeholder) when all its conditions hold.
public struct ScriptRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var target: String
    public var when: [ScriptCond]
    /// A library key from the script's `blocks`.
    public var block: String
    /// Removed by Presets off (JSON `optional`).
    public var isOptional: Bool?
    /// Can't be switched off or changed; only its block text.
    public var locked: Bool?
    /// false = switched off by the owner (absent = on).
    public var enabled: Bool?

    public init(id: String, label: String, target: String, when: [ScriptCond] = [], block: String, optional isOptional: Bool? = nil, locked: Bool? = nil,
                enabled: Bool? = nil) {
        self.id = id
        self.label = label
        self.target = target
        self.when = when
        self.block = block
        self.isOptional = isOptional
        self.locked = locked
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, label, target, when, block, locked, enabled
        case isOptional = "optional"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        label = c.v(.label, id)
        target = c.v(.target, "")
        when = c.v(.when, [])
        block = c.v(.block, "")
        isOptional = c.o(.isOptional)
        locked = c.o(.locked)
        enabled = c.o(.enabled)
    }

    public var isLocked: Bool { locked == true }
    /// The on/off switch. Turning it on drops `enabled` (the server's default is on).
    public var isOn: Bool {
        get { enabled != false }
        set { enabled = newValue ? nil : false }
    }

    /// Only the fields the server keeps (its `cleanRules`): a trimmed label, `optional`/`locked` only when true, `enabled` only when false.
    public var cleaned: ScriptRule {
        ScriptRule(id: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines), target: target, when: when, block: block,
                   optional: isOptional == true ? true : nil, locked: isLocked ? true : nil, enabled: enabled == false ? false : nil)
    }
}

/// A section of the script (a line, or a "heading:" block of the video prompt). `kind` "user" holds the user's own words.
public struct ScriptSection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// system | user
    public var kind: String
    /// Repeats once per item of this list input.
    public var each: String?
    public var heading: String?
    /// Not sent by the server (yet): first | all. The demo backend's runner uses it; nil = all for a repeating section, else first.
    public var pick: String?
    public var join: String?

    public init(id: String, label: String, kind: String = "system", each: String? = nil, heading: String? = nil, pick: String? = nil, join: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.each = each
        self.heading = heading
        self.pick = pick
        self.join = join
    }

    enum CodingKeys: String, CodingKey { case id, label, kind, each, heading, pick, join }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        label = c.v(.label, id)
        kind = c.v(.kind, "system")
        each = c.o(.each)
        heading = c.o(.heading)
        pick = c.o(.pick)
        join = c.o(.join)
    }
}

/// A placeholder whose value rules choose (target "@name"); `prefix` goes before a non-empty value.
public struct ScriptValueSlot: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String
    public var prefix: String?
    public var id: String { name }

    public init(name: String, label: String, prefix: String? = nil) {
        self.name = name
        self.label = label
        self.prefix = prefix
    }

    enum CodingKeys: String, CodingKey { case name, label, prefix }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "")
        label = c.v(.label, name)
        prefix = c.o(.prefix)
    }
}

/// A value the code supplies (her name, image ranges …), with the preview's sample.
public struct ScriptVar: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var sample: String
    public var id: String { name }

    public init(name: String, description: String = "", sample: String = "") {
        self.name = name
        self.description = description
        self.sample = sample
    }

    enum CodingKeys: String, CodingKey { case name, description, sample }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "")
        description = c.v(.description, "")
        if let s: String = c.o(.sample) { sample = s } else if let v: JSONValue = c.o(.sample) { sample = v.description } else { sample = "" }
    }
}

/// `GET /v1/prompt-scripts/{id}`: one script with the studio's current rules and its defaults.
public struct ScriptView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var group: String
    public var title: String
    public var description: String
    /// lines | sections
    public var format: String
    public var inputs: [ScriptInputDef]
    public var sections: [ScriptSection]
    public var values: [ScriptValueSlot]
    /// Where a rule can put its block: section ids and "@value".
    public var targets: [ScriptOption]
    public var vars: [ScriptVar]
    /// Library keys usable in this script's rules.
    public var blocks: [String]
    public var rules: [ScriptRule]
    public var defaultRules: [ScriptRule]
    public var overridden: Bool
    /// A saved list that no longer fits the script: shown as reset.
    public var stale: Bool
    public var updatedAt: Int64?
    public var updatedBy: String?

    public init(id: String, group: String, title: String, description: String = "", format: String = "lines", inputs: [ScriptInputDef] = [],
                sections: [ScriptSection] = [], values: [ScriptValueSlot] = [], targets: [ScriptOption]? = nil, vars: [ScriptVar] = [],
                blocks: [String]? = nil, rules: [ScriptRule]? = nil, defaultRules: [ScriptRule], overridden: Bool = false, stale: Bool = false,
                updatedAt: Int64? = nil, updatedBy: String? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.description = description
        self.format = format
        self.inputs = inputs
        self.sections = sections
        self.values = values
        self.targets = targets ?? (sections.map { ScriptOption(id: $0.id, label: $0.label) } + values.map { ScriptOption(id: "@" + $0.name, label: $0.label) })
        self.vars = vars
        var keys: [String] = []
        for r in defaultRules where !keys.contains(r.block) { keys.append(r.block) }
        self.blocks = blocks ?? keys
        self.rules = rules ?? defaultRules
        self.defaultRules = defaultRules
        self.overridden = overridden
        self.stale = stale
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    enum CodingKeys: String, CodingKey {
        case id, group, title, description, format, inputs, sections, values, targets, vars, blocks, rules, defaultRules, overridden, stale, updatedAt, updatedBy
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        group = c.v(.group, "")
        title = c.v(.title, id)
        description = c.v(.description, "")
        format = c.v(.format, "lines")
        inputs = c.v(.inputs, [])
        sections = c.v(.sections, [])
        values = c.v(.values, [])
        targets = c.v(.targets, [])
        vars = c.v(.vars, [])
        blocks = c.v(.blocks, [])
        defaultRules = c.v(.defaultRules, [])
        rules = c.v(.rules, defaultRules)
        overridden = c.v(.overridden, false)
        stale = c.v(.stale, false)
        updatedAt = c.o(.updatedAt)
        updatedBy = c.o(.updatedBy)
    }
}

/// One test from `ops`: which input types it applies to.
public struct CondOpInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var types: [String]

    public init(id: String, label: String, types: [String]) {
        self.id = id
        self.label = label
        self.types = types
    }

    enum CodingKeys: String, CodingKey { case id, label, types }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "is")
        label = c.v(.label, id)
        types = c.v(.types, [])
    }

    /// The server's COND_OPS (used until the list is loaded, and by the demo backend).
    public static let defaults: [CondOpInfo] = [
        CondOpInfo(id: "is", label: "is", types: ["bool", "enum", "number", "text"]),
        CondOpInfo(id: "isNot", label: "is not", types: ["bool", "enum", "number", "text"]),
        CondOpInfo(id: "in", label: "is one of", types: ["enum"]),
        CondOpInfo(id: "notIn", label: "is none of", types: ["enum"]),
        CondOpInfo(id: "atLeast", label: "is at least", types: ["number"]),
        CondOpInfo(id: "atMost", label: "is at most", types: ["number"]),
        CondOpInfo(id: "has", label: "includes", types: ["list"]),
        CondOpInfo(id: "hasNot", label: "does not include", types: ["list"]),
        CondOpInfo(id: "empty", label: "is empty", types: ["text", "list"]),
        CondOpInfo(id: "notEmpty", label: "is not empty", types: ["text", "list"]),
    ]

    /// The tests an input of `type` can use, in the server's order (the rule form's test menu).
    public static func ops(for type: String, in ops: [CondOpInfo]) -> [CondOpInfo] {
        (ops.isEmpty ? defaults : ops).filter { $0.types.contains(type) }
    }

    public static func needsValue(_ op: String) -> Bool { op != "empty" && op != "notEmpty" }
}

/// `GET /v1/prompt-scripts`.
public struct PromptScriptsList: Codable, Hashable, Sendable {
    public var groups: [PromptGroupRef]
    public var ops: [CondOpInfo]
    public var scripts: [ScriptView]

    public init(groups: [PromptGroupRef] = [], ops: [CondOpInfo] = CondOpInfo.defaults, scripts: [ScriptView] = []) {
        self.groups = groups
        self.ops = ops
        self.scripts = scripts
    }

    enum CodingKeys: String, CodingKey { case groups, ops, scripts }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        groups = c.v(.groups, [])
        let o: [CondOpInfo] = c.v(.ops, [])
        ops = o.isEmpty ? CondOpInfo.defaults : o
        scripts = c.v(.scripts, [])
    }

    /// The scripts grouped like the blocks: the server's group order, unknown groups last, empty groups left out.
    public var sections: [(group: PromptGroupRef, scripts: [ScriptView])] {
        var out: [(PromptGroupRef, [ScriptView])] = groups.map { g in (g, scripts.filter { $0.group == g.id }) }
        let known = Set(groups.map(\.id))
        var extra: [String] = []
        for s in scripts where !known.contains(s.group) && !extra.contains(s.group) { extra.append(s.group) }
        for g in extra { out.append((PromptGroupRef(id: g, label: g.capitalized), scripts.filter { $0.group == g })) }
        return out.filter { !$0.1.isEmpty }.map { (group: $0.0, scripts: $0.1) }
    }

    public func script(_ id: String) -> ScriptView? { scripts.first { $0.id == id } }

    /// A `promptScript` event or a PUT/DELETE reply: replace that script (or add it).
    public mutating func apply(_ v: ScriptView) {
        if let i = scripts.firstIndex(where: { $0.id == v.id }) { scripts[i] = v } else { scripts.append(v) }
    }
}

/// `PUT /v1/prompt-scripts/{id}`: the whole rule list, in order.
public struct SaveScriptRequest: Codable, Hashable, Sendable {
    public var rules: [ScriptRule]
    public init(rules: [ScriptRule]) { self.rules = rules }
}

/// `POST /v1/prompt-scripts/preview`. Every field but `id` is optional: inputs over the samples, unsaved rules, unsaved block texts.
public struct ScriptPreviewRequest: Codable, Hashable, Sendable {
    public var id: String
    public var inputs: [String: JSONValue]?
    public var rules: [ScriptRule]?
    public var texts: [String: String]?
    public var direction: String?

    public init(id: String, inputs: [String: JSONValue]? = nil, rules: [ScriptRule]? = nil, texts: [String: String]? = nil, direction: String? = nil) {
        self.id = id
        self.inputs = inputs
        self.rules = rules
        self.texts = texts
        self.direction = direction
    }
}

public struct ScriptPart: Codable, Hashable, Sendable {
    public var section: String
    public var layer: String
    public var kind: String
    public var text: String
    /// The rule ids whose blocks made this part.
    public var rules: [String]

    public init(section: String, layer: String? = nil, kind: String = "system", text: String, rules: [String] = []) {
        self.section = section
        self.layer = layer ?? section
        self.kind = kind
        self.text = text
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case section, layer, kind, text, rules }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        section = c.v(.section, "")
        layer = c.v(.layer, section)
        kind = c.v(.kind, "system")
        text = c.v(.text, "")
        rules = c.v(.rules, [])
    }
}

/// The preview's answer: the assembled prompt, its parts, the rules that fired and the inputs it ran with.
public struct ScriptPreview: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var parts: [ScriptPart]
    public var fired: [String]
    public var inputs: [String: JSONValue]

    public init(id: String, text: String, parts: [ScriptPart] = [], fired: [String] = [], inputs: [String: JSONValue] = [:]) {
        self.id = id
        self.text = text
        self.parts = parts
        self.fired = fired
        self.inputs = inputs
    }

    enum CodingKeys: String, CodingKey { case id, text, parts, fired, inputs }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        text = c.v(.text, "")
        parts = c.v(.parts, [])
        fired = c.v(.fired, [])
        inputs = c.v(.inputs, [:])
    }
}

// MARK: - Editor helpers (pure, tested)

/// A place (section or value) with its rules in order: the script screen's Rules list.
public struct ScriptPlace: Hashable, Sendable, Identifiable {
    public var target: ScriptOption
    public var rules: [ScriptRule]
    public var id: String { target.id }
}

extension ScriptView {
    /// The samples, by input name: what the preview starts from.
    public var sampleInputs: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for i in inputs { out[i.name] = i.sample }
        return out
    }

    public func targetLabel(_ id: String) -> String {
        targets.first { $0.id == id }?.label ?? sections.first { $0.id == id }?.label ?? id
    }

    public func section(_ id: String) -> ScriptSection? { sections.first { $0.id == id } }

    /// The input a condition names: a script input, or "item.<field>" of the list a repeating `target` section runs over.
    public func input(_ name: String, target: String) -> ScriptInputDef? {
        guard name.hasPrefix("item.") else { return inputs.first { $0.name == name } }
        guard let each = section(target)?.each else { return nil }
        let field = String(name.dropFirst(5))
        return inputs.first { $0.name == each }?.fields?.first { $0.name == field }
    }

    /// The inputs a rule at `target` can test (the condition's input menu): the script's inputs, plus "item.<field>" in a
    /// section that repeats per list item.
    public func conditionInputs(target: String) -> [(key: String, def: ScriptInputDef)] {
        var out: [(key: String, def: ScriptInputDef)] = inputs.map { (key: $0.name, def: $0) }
        if let each = section(target)?.each, let fields = inputs.first(where: { $0.name == each })?.fields {
            out += fields.map { (key: "item." + $0.name, def: $0) }
        }
        return out
    }

    /// The rules grouped by place, in the order of `targets` (unknown places last). Each rule keeps its list order.
    public func places(_ rules: [ScriptRule]) -> [ScriptPlace] {
        var out: [ScriptPlace] = []
        for t in targets {
            let rs = rules.filter { $0.target == t.id }
            if !rs.isEmpty { out.append(ScriptPlace(target: t, rules: rs)) }
        }
        let known = Set(targets.map(\.id))
        var extra: [String] = []
        for r in rules where !known.contains(r.target) && !extra.contains(r.target) { extra.append(r.target) }
        for t in extra { out.append(ScriptPlace(target: ScriptOption(id: t, label: t), rules: rules.filter { $0.target == t })) }
        return out
    }

    /// A rule the owner added (not one of the defaults): only these can be deleted.
    public func isAdded(_ rule: ScriptRule) -> Bool { !defaultRules.contains { $0.id == rule.id } }

    /// A new rule for the form: a free id, the first place that isn't the user's section, the first block, no conditions.
    public func newRule(existing: [ScriptRule]) -> ScriptRule {
        let ids = Set(existing.map(\.id))
        var n = 1
        while ids.contains("rule.\(n)") { n += 1 }
        let place = targets.first { t in section(t.id)?.kind != "user" } ?? targets.first
        return ScriptRule(id: "rule.\(n)", label: "New rule", target: place?.id ?? "", block: blocks.first ?? "")
    }
}

/// Readable sentences and defaults for the rule editor.
public enum ScriptText {
    /// How a value reads in a sentence: yes / no, an option's label, a number, quoted text, labels joined with "or".
    public static func value(_ v: JSONValue?, _ def: ScriptInputDef?) -> String {
        guard let v else { return "" }
        switch v {
        case .bool(let b): return b ? "yes" : "no"
        case .string(let s): return def?.options != nil ? def!.optionLabel(s) : "“\(s)”"
        case .array(let a): return a.map { value($0, def) }.joined(separator: " or ")
        case .null: return "nothing"
        default: return v.description
        }
    }

    /// "Performer is speaking is no", "Lens (mm) is at least 85", "Guides includes Pose & framing", "Direction is empty".
    public static func condition(_ c: ScriptCond, script: ScriptView, target: String, ops: [CondOpInfo]) -> String {
        let def = script.input(c.input, target: target)
        let name = def?.label ?? c.input
        let op = (ops.isEmpty ? CondOpInfo.defaults : ops).first { $0.id == c.op }?.label ?? c.op
        return c.needsValue ? "\(name) \(op) \(value(c.value, def))" : "\(name) \(op)"
    }

    /// "When Performer is speaking is no → Summary: Draft/Standard/HD · summary (not speaking)"; "Always → …" without conditions.
    /// `blockTitle` names a block (the library entry's title; the key when the library isn't loaded).
    public static func sentence(_ r: ScriptRule, script: ScriptView, ops: [CondOpInfo], blockTitle: (String) -> String) -> String {
        let when = r.when.isEmpty ? "Always" : "When " + r.when.map { condition($0, script: script, target: r.target, ops: ops) }.joined(separator: " and ")
        return "\(when) → \(script.targetLabel(r.target)): \(blockTitle(r.block))"
    }

    public static func blockTitle(_ key: String, library: PromptLibrary?) -> String { library?.entry(key)?.title ?? key }

    /// The value a condition starts with when its input or test changes.
    public static func defaultValue(op: String, def: ScriptInputDef?) -> JSONValue? {
        guard CondOpInfo.needsValue(op), let def else { return nil }
        let first = def.options?.first?.id
        switch op {
        case "in", "notIn": return .array(first.map { [.string($0)] } ?? [])
        case "has", "hasNot": return .string(first ?? "")
        case "atLeast", "atMost":
            if case .number(_) = def.sample { return def.sample }
            return .number(0)
        default:
            switch def.type {
            case "bool": return .bool(true)
            case "number":
                if case .number(_) = def.sample { return def.sample }
                return .number(0)
            case "enum": return .string(first ?? "")
            default: return .string("")
            }
        }
    }

    /// A fresh condition on input `key` with its first test and a default value.
    public static func newCondition(_ key: String, def: ScriptInputDef?, ops: [CondOpInfo]) -> ScriptCond {
        let op = def.flatMap { CondOpInfo.ops(for: $0.type, in: ops).first?.id } ?? "is"
        return ScriptCond(input: key, op: op, value: defaultValue(op: op, def: def))
    }

    /// Moves a rule one step up or down among the rules of the same place (the list order elsewhere is kept).
    @discardableResult
    public static func move(_ rules: inout [ScriptRule], id: String, up: Bool) -> Bool {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return false }
        let target = rules[i].target
        let others = up ? Array((0..<i).reversed()) : Array((i + 1)..<rules.count)
        guard let j = others.first(where: { rules[$0].target == target }) else { return false }
        rules.swapAt(i, j)
        return true
    }
}

// MARK: - Validation and the runner (the server's rules, for the demo backend)

/// The server's `validateRules` and `runScript`, ported for demo mode (the app shows the server's own `script_invalid` text).
public enum ScriptEngine {
    public static let maxRules = 60
    public static let maxConditions = 8

    static func validId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 60 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    static func condError(_ s: ScriptView, _ c: ScriptCond, target: String) -> String? {
        guard let def = s.input(c.input, target: target) else { return "Unknown input \"\(c.input)\"" }
        guard let op = CondOpInfo.defaults.first(where: { $0.id == c.op }), op.types.contains(def.type) else { return "\"\(def.label)\" can't use the test \"\(c.op)\"" }
        let opts = def.options?.map(\.id)
        let list = (opts ?? []).joined(separator: ", ")
        switch c.op {
        case "empty", "notEmpty": return nil
        case "in", "notIn":
            guard case .array(let a)? = c.value, !a.isEmpty, a.allSatisfy({ if case .string(let s) = $0 { return opts?.contains(s) ?? false } else { return false } }) else {
                return "Pick one or more of \(list) for \"\(def.label)\""
            }
            return nil
        case "has", "hasNot":
            guard case .string(let s)? = c.value, opts.map({ $0.contains(s) }) ?? true else { return "Pick one of \(list) for \"\(def.label)\"" }
            return nil
        case "atLeast", "atMost":
            if case .number(let n)? = c.value, n.isFinite { return nil }
            return "\"\(def.label)\" needs a number"
        default:
            switch def.type {
            case "bool":
                if case .bool(_)? = c.value { return nil }
                return "\"\(def.label)\" is yes or no"
            case "number":
                if case .number(_)? = c.value { return nil }
                return "\"\(def.label)\" needs a number"
            case "enum":
                if case .string(let s)? = c.value, opts?.contains(s) == true { return nil }
                return "Pick one of \(list) for \"\(def.label)\""
            default:
                if case .string(let s)? = c.value, s.count <= 200 { return nil }
                return "\"\(def.label)\" needs a short text"
            }
        }
    }

    /// Why `rules` can't be saved for `script`, or nil. The same checks and wording as the server.
    public static func validate(_ script: ScriptView, _ rules: [ScriptRule]) -> String? {
        if rules.count > maxRules { return "At most \(maxRules) rules" }
        var ids = Set<String>()
        let targets = script.targets.map(\.id)
        for r in rules {
            if !validId(r.id) { return "Each rule needs an id" }
            if ids.contains(r.id) { return "Two rules are called \"\(r.id)\"" }
            ids.insert(r.id)
            let label = r.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty || r.label.count > 120 { return "Give rule \"\(r.id)\" a short name" }
            if !targets.contains(r.target) { return "Rule \"\(r.label)\": unknown place \"\(r.target)\"" }
            if !script.blocks.contains(r.block) { return "Rule \"\(r.label)\": this script can't use the block \"\(r.block)\"" }
            if r.when.count > maxConditions { return "Rule \"\(r.label)\": at most \(maxConditions) conditions" }
            for c in r.when { if let e = condError(script, c, target: r.target) { return "Rule \"\(r.label)\": \(e)" } }
        }
        for d in script.defaultRules where d.isLocked {
            guard let r = rules.first(where: { $0.id == d.id }) else { return "\"\(d.label)\" is required and can't be removed" }
            if r.enabled == false || r.target != d.target || r.block != d.block || r.when != d.when || (r.isOptional == true) != (d.isOptional == true) || !r.isLocked {
                return "\"\(d.label)\" is locked: only its text can be changed (Settings → Prompts → its block)"
            }
        }
        return nil
    }

    // ---- running

    static func scalarText(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null: return ""
        case .array(let a): return a.map { scalarText($0) }.joined(separator: ", ")
        default: return v.description
        }
    }

    static func isNothing(_ v: JSONValue?) -> Bool {
        if v == nil { return true }
        if case .null? = v { return true }
        return false
    }

    /// The server's `condHolds`.
    public static func holds(_ c: ScriptCond, inputs: [String: JSONValue], item: [String: JSONValue]? = nil) -> Bool {
        let v: JSONValue? = c.input.hasPrefix("item.") ? item?[String(c.input.dropFirst(5))] : inputs[c.input]
        var list: [JSONValue]?
        if case .array(let a)? = v { list = a }
        let isValue = v == c.value || (isNothing(v) && c.value == .bool(false))
        let empty: Bool = {
            if isNothing(v) { return true }
            if case .string(let s)? = v { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let list { return list.isEmpty }
            return false
        }()
        switch c.op {
        case "is": return isValue
        case "isNot": return !isValue
        case "in", "notIn":
            guard case .array(let opts)? = c.value else { return false }
            let has = opts.contains(.string(scalarText(v)))
            return c.op == "in" ? has : !has
        case "atLeast", "atMost":
            guard case .number(let x)? = v, case .number(let y)? = c.value else { return false }
            return c.op == "atLeast" ? x >= y : x <= y
        case "has": return list.map { l in c.value.map { l.contains($0) } ?? false } ?? false
        case "hasNot": return !(list.map { l in c.value.map { l.contains($0) } ?? false } ?? false)
        case "empty": return empty
        case "notEmpty": return !empty
        default: return false
        }
    }

    static func ruleOn(_ r: ScriptRule, _ inputs: [String: JSONValue], _ item: [String: JSONValue]?) -> Bool {
        r.isOn && !(r.isOptional == true && inputs["presets"] == .bool(false)) && r.when.allSatisfy { holds($0, inputs: inputs, item: item) }
    }

    /// The library's `fill`: {name} → its value (missing = empty), nothing else touched.
    public static func fill(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for n in PromptPlaceholders.names(in: text) { out = out.replacingOccurrences(of: "{\(n)}", with: values[n] ?? "") }
        return out
    }

    /// The user's words as they go into a prompt: one line, trimmed.
    public static func userText(_ s: String?) -> String {
        let one = (s ?? "").components(separatedBy: CharacterSet(charactersIn: "\r\n\t")).joined(separator: " ")
        return one.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The server's `runScript` + `assemble` over a ScriptView (pick: the section's own, else all for a repeating section).
    public static func run(_ s: ScriptView, inputs: [String: JSONValue], rules: [ScriptRule], texts: [String: String], vars given: [String: String] = [:],
                           direction: String? = nil) -> ScriptPreview {
        // The code's samples, then the caller's values (inputs are not placeholders, as on the server).
        var vars: [String: String] = [:]
        for v in s.vars { vars[v.name] = v.sample }
        for (k, v) in given { vars[k] = v }
        vars["direction"] = nil
        var fired: [String] = []
        let render = { (key: String, values: [String: String]) -> String in
            ScriptEngine.fill(texts[key] ?? "", values).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for slot in s.values {
            guard let r = rules.first(where: { $0.target == "@" + slot.name && ruleOn($0, inputs, nil) }) else {
                if vars[slot.name] == nil { vars[slot.name] = "" }
                continue
            }
            fired.append(r.id)
            let t = render(r.block, vars)
            vars[slot.name] = t.isEmpty ? "" : (slot.prefix ?? "") + t
        }
        var parts: [ScriptPart] = []
        let dir = userText(direction)
        for sec in s.sections {
            var items: [[String: JSONValue]?] = [nil]
            if let each = sec.each {
                items = []
                if case .array(let a)? = inputs[each] {
                    for x in a { if case .object(let o) = x { items.append(o) } }
                }
            }
            for item in items {
                var matched = rules.filter { $0.target == sec.id && ruleOn($0, inputs, item) }
                if sec.kind == "user" && dir.isEmpty { matched = [] }
                if (sec.pick ?? (sec.each != nil ? "all" : "first")) == "first" { matched = Array(matched.prefix(1)) }
                var v = vars
                for (k, x) in item ?? [:] { v[k] = scalarText(x) }
                if sec.kind == "user" { v["direction"] = dir }
                let out = matched.map { (id: $0.id, text: render($0.block, v)) }.filter { !$0.text.isEmpty }
                if out.isEmpty { continue }
                fired += out.map(\.id)
                parts.append(ScriptPart(section: sec.id, kind: sec.kind, text: out.map(\.text).joined(separator: sec.join ?? " "), rules: out.map(\.id)))
            }
        }
        return ScriptPreview(id: s.id, text: assemble(s, parts), parts: parts, fired: fired, inputs: inputs)
    }

    /// One line per part ("lines"), or "heading:\nbody" blocks separated by a blank line ("sections").
    public static func assemble(_ s: ScriptView, _ parts: [ScriptPart]) -> String {
        if s.format == "lines" { return parts.map(\.text).joined(separator: "\n") }
        var chunks: [String] = []
        for p in parts {
            let heading = s.section(p.section)?.heading
            if heading != nil || chunks.isEmpty {
                chunks.append(heading.map { "\($0)\n\(p.text)" } ?? p.text)
            } else {
                chunks[chunks.count - 1] += "\n\(p.text)"
            }
        }
        return chunks.isEmpty ? "" : chunks.joined(separator: "\n\n") + "\n"
    }
}

/// `promptScript` events (owners only): a script's rules were saved or reset on another device.
extension LiveEvents {
    @discardableResult
    public static func applyPromptScript(_ list: inout PromptScriptsList?, _ e: ApiEvent) -> ScriptView? {
        guard e.type == "promptScript", let v = e.script else { return nil }
        list?.apply(v)
        return v
    }
}
