import Foundation

// The owner's prompt library (plans/api.md "Shoot references and the prompt library" §3): every prompt the server sends to a
// model is an entry with a default in code and an optional owner override. Owner only; members never see it.

public struct PromptPlaceholder: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var required: Bool
    public var id: String { name }

    public init(name: String, description: String = "", required: Bool = false) {
        self.name = name
        self.description = description
        self.required = required
    }

    enum CodingKeys: String, CodingKey { case name, description, required }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "")
        description = c.v(.description, "")
        required = c.v(.required, false)
    }

    /// "{name}", what a chip inserts.
    public var token: String { "{\(name)}" }
}

/// One library entry. `kind`: text | list (comma-separated) | lines (one item per line).
public struct PromptEntry: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var group: String
    public var title: String
    public var description: String
    public var kind: String
    public var defaultText: String
    public var current: String
    public var overridden: Bool
    public var allowEmpty: Bool
    public var placeholders: [PromptPlaceholder]
    public var updatedAt: Int64?
    public var updatedBy: String?
    public var id: String { key }

    public init(key: String, group: String, title: String, description: String = "", kind: String = "text", defaultText: String, current: String? = nil,
                allowEmpty: Bool = false, placeholders: [PromptPlaceholder] = [], updatedAt: Int64? = nil, updatedBy: String? = nil) {
        self.key = key
        self.group = group
        self.title = title
        self.description = description
        self.kind = kind
        self.defaultText = defaultText
        self.current = current ?? defaultText
        self.overridden = (current ?? defaultText) != defaultText
        self.allowEmpty = allowEmpty
        self.placeholders = placeholders
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    enum CodingKeys: String, CodingKey {
        case key, group, title, description, kind, current, overridden, allowEmpty, placeholders, updatedAt, updatedBy
        case defaultText = "default"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        group = c.v(.group, "")
        title = c.v(.title, key)
        description = c.v(.description, "")
        kind = c.v(.kind, "text")
        defaultText = c.v(.defaultText, "")
        current = c.v(.current, defaultText)
        overridden = c.v(.overridden, current != defaultText)
        allowEmpty = c.v(.allowEmpty, false)
        placeholders = c.v(.placeholders, [])
        updatedAt = c.o(.updatedAt)
        updatedBy = c.o(.updatedBy)
    }

    /// The list row's one-line preview of the current text.
    public var oneLine: String {
        let s = current.replacingOccurrences(of: "\n", with: " · ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "(empty)" : s
    }

    /// The editor's hint under the text box for list and lines entries.
    public var kindHint: String? {
        switch kind {
        case "list": return "Comma-separated items"
        case "lines": return "One item per line"
        default: return nil
        }
    }
}

public struct PromptGroupRef: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// `GET /v1/prompts`.
public struct PromptLibrary: Codable, Hashable, Sendable {
    public var groups: [PromptGroupRef]
    public var prompts: [PromptEntry]

    public init(groups: [PromptGroupRef] = [], prompts: [PromptEntry] = []) {
        self.groups = groups
        self.prompts = prompts
    }

    enum CodingKeys: String, CodingKey { case groups, prompts }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        groups = c.v(.groups, [])
        prompts = c.v(.prompts, [])
    }

    /// The groups in the server's order with their entries; entries of a group the server didn't list come last under their id.
    public var sections: [(group: PromptGroupRef, entries: [PromptEntry])] {
        var out: [(PromptGroupRef, [PromptEntry])] = groups.map { g in (g, prompts.filter { $0.group == g.id }) }
        let known = Set(groups.map(\.id))
        var extra: [String] = []
        for p in prompts where !known.contains(p.group) && !extra.contains(p.group) { extra.append(p.group) }
        for g in extra { out.append((PromptGroupRef(id: g, label: g.capitalized), prompts.filter { $0.group == g })) }
        return out.filter { !$0.1.isEmpty }.map { (group: $0.0, entries: $0.1) }
    }

    /// A `prompts` event or a PUT/DELETE reply: replace that entry (or add it).
    public mutating func apply(_ e: PromptEntry) {
        if let i = prompts.firstIndex(where: { $0.key == e.key }) { prompts[i] = e } else { prompts.append(e) }
    }

    public func entry(_ key: String) -> PromptEntry? { prompts.first { $0.key == key } }
}

/// `PUT /v1/prompts/{key}`.
public struct SetPromptRequest: Codable, Hashable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// `POST /v1/prompts/preview`. `text` nil = the saved text.
public struct PromptPreviewRequest: Codable, Hashable, Sendable {
    public var key: String
    public var text: String?
    public init(key: String, text: String? = nil) {
        self.key = key
        self.text = text
    }
}

public struct PromptPreview: Codable, Hashable, Sendable {
    public var key: String
    /// This entry rendered with sample values.
    public var text: String
    /// The whole prompt it is part of, built with this text and the sample model.
    public var example: String
    public var sample: [String: String]

    public init(key: String, text: String, example: String, sample: [String: String] = [:]) {
        self.key = key
        self.text = text
        self.example = example
        self.sample = sample
    }

    enum CodingKeys: String, CodingKey { case key, text, example, sample }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = c.v(.key, "")
        text = c.v(.text, "")
        example = c.v(.example, "")
        sample = c.v(.sample, [:])
    }
}

/// Placeholder rules, as the server checks them (used by the demo backend; the app shows the server's `prompt_invalid` message).
public enum PromptPlaceholders {
    public static let maxLength = 4000

    /// The `{name}` placeholders in a text, in order, without repeats. Other braces are left alone.
    public static func names(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9]*)\\}") else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// The `prompt_invalid` message for this text, or nil when it can be saved.
    public static func problem(_ entry: PromptEntry, _ text: String) -> String? {
        if text.count > maxLength { return "Too long · keep it under \(maxLength) characters" }
        if !entry.allowEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "This prompt can't be empty" }
        let allowed = entry.placeholders.map(\.name)
        for n in names(in: text) where !allowed.contains(n) {
            let can = allowed.isEmpty ? "this prompt has no placeholders" : "this prompt can use " + allowed.map { "{\($0)}" }.joined(separator: ", ")
            return "Unknown placeholder {\(n)} · \(can)"
        }
        let used = Set(names(in: text))
        for p in entry.placeholders where p.required && !used.contains(p.name) { return "Keep {\(p.name)} · this prompt needs it" }
        return nil
    }

    /// Fills `{name}` with its value (missing values become empty) and leaves out lines that render empty.
    public static func fill(_ text: String, _ values: [String: String]) -> String {
        var out = text
        for n in names(in: text) { out = out.replacingOccurrences(of: "{\(n)}", with: values[n] ?? "") }
        return out.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
}

/// The demo backend's library: the photoshoot and reference entries with the server's default wording.
public enum PromptLibraryDefaults {
    public static let groups: [PromptGroupRef] = [
        PromptGroupRef(id: "photoshoot", label: "Photo"), PromptGroupRef(id: "references", label: "References"),
        PromptGroupRef(id: "sheet", label: "Character sheet"), PromptGroupRef(id: "outfits", label: "Outfits"),
        PromptGroupRef(id: "enhance", label: "Enhance"), PromptGroupRef(id: "dressup", label: "Dress up"),
        PromptGroupRef(id: "templates", label: "Templates"), PromptGroupRef(id: "video", label: "Video"), PromptGroupRef(id: "lora", label: "LoRA"),
    ]

    private static func ph(_ n: String, _ d: String, _ r: Bool = false) -> PromptPlaceholder { PromptPlaceholder(name: n, description: d, required: r) }

    public static let entries: [PromptEntry] = [
        PromptEntry(key: "style.house", group: "photoshoot", title: "House style", description: "Added to every photo prompt.", defaultText: PromptEngine.houseStyle),
        PromptEntry(key: "never.base", group: "photoshoot", title: "Never add · every model", description: "Appended to every model's never-add list.",
                    kind: "list", defaultText: PromptEngine.globalNever.joined(separator: ", "), allowEmpty: true),
        PromptEntry(key: "shoot.identity", group: "photoshoot", title: "Identity line", description: "Who she is, in every photo prompt.",
                    defaultText: "{name}: {look}. Identity from {refCount} locked reference images{lora}.",
                    placeholders: [ph("name", "Her name"), ph("look", "Her written look"), ph("refCount", "How many locked references"), ph("lora", "The LoRA note, or empty")]),
        PromptEntry(key: "shoot.outfit.set", group: "photoshoot", title: "Outfit · reference set", defaultText: "Wearing: {outfit} (outfit reference set).",
                    placeholders: [ph("outfit", "The outfit name", true)]),
        PromptEntry(key: "shoot.scene", group: "photoshoot", title: "Scene line", defaultText: "Scene: {scene}.", placeholders: [ph("scene", "The scene, lower case", true)]),
        PromptEntry(key: "shoot.camera", group: "photoshoot", title: "Camera line", defaultText: "Camera: {shot} shot, {lens}mm lens, {aperture}{lensNote}.",
                    placeholders: [ph("shot", "Close, medium, full or wide"), ph("lens", "Lens in mm"), ph("aperture", "e.g. f/2.8"), ph("lensNote", "Wide or tele note, or empty")]),
        PromptEntry(key: "shoot.light", group: "photoshoot", title: "Light line", defaultText: "Light: {light}; grade: {grade}.",
                    placeholders: [ph("light", "The light"), ph("grade", "The colour grade")]),
        PromptEntry(key: "shoot.direction", group: "photoshoot", title: "Direction line", defaultText: "Direction: {direction}",
                    placeholders: [ph("direction", "The user's direction", true)]),
        PromptEntry(key: "shoot.style", group: "photoshoot", title: "Style line", defaultText: "Style: {style}.", placeholders: [ph("style", "The house style", true)]),
        PromptEntry(key: "shoot.never", group: "photoshoot", title: "Never-add line", defaultText: "Never add: {never}.", placeholders: [ph("never", "Her list + the base list", true)]),
        PromptEntry(key: "shoot.seed.locked", group: "photoshoot", title: "Seed line · Lock look", description: "When Lock look is on.",
                    defaultText: "Seed: locked (variations keep the same look)."),
        PromptEntry(key: "shoot.seed.new", group: "photoshoot", title: "Seed line · new each shot", defaultText: "Seed: new each shot."),
        PromptEntry(key: "refs.pose", group: "references", title: "Pose & framing", defaultText: "Copy the pose and framing from image {refIndex}.",
                    placeholders: [ph("refIndex", "The reference's image number", true)]),
        PromptEntry(key: "refs.look", group: "references", title: "Look & colour", defaultText: "Copy the light, colour grade and camera feel from image {refIndex}.",
                    placeholders: [ph("refIndex", "The reference's image number", true)]),
        PromptEntry(key: "refs.scene", group: "references", title: "Scene", defaultText: "Use the place and background from image {refIndex}.",
                    placeholders: [ph("refIndex", "The reference's image number", true)]),
        PromptEntry(key: "refs.guard", group: "references", title: "Guard line", description: "Ends every reference line.",
                    defaultText: "Do not take the face, body, hair or clothes from image {refIndex}.", placeholders: [ph("refIndex", "The reference's image number", true)]),
        PromptEntry(key: "sheet.task", group: "sheet", title: "Sheet angle task",
                    defaultText: "Task: {angle} shot on a plain light-grey studio background, even soft light, neutral expression, {framing}.",
                    placeholders: [ph("angle", "The angle"), ph("framing", "The framing")]),
        PromptEntry(key: "outfit.task", group: "outfits", title: "Outfit angle task", defaultText: "Task: {angle}, plain studio background.",
                    placeholders: [ph("angle", "The angle", true)]),
        PromptEntry(key: "template.locked", group: "templates", title: "Locked template line", description: "The line anyone but the template's maker sees.",
                    defaultText: "Template: {name}", placeholders: [ph("name", "The template name", true)]),
    ] + scriptBlocks

    /// Prompt scripts (workstream 4): the other blocks the demo scripts use (photoshoot, video.replicate), with the server's wording.
    static let scriptBlocks: [PromptEntry] = [
        PromptEntry(key: "shoot.outfit.described", group: "photoshoot", title: "Outfit · described", description: "An outfit described in words, with no photos yet.",
                    defaultText: "Wearing: {outfit}.", placeholders: [ph("outfit", "the description", true)]),
        PromptEntry(key: "shoot.outfit.product", group: "photoshoot", title: "Outfit · product photo", description: "An outfit from a product photo.",
                    defaultText: "Wearing: the outfit from the product photo reference ({outfit}).", placeholders: [ph("outfit", "the outfit name, lower case")]),
        PromptEntry(key: "shoot.camera.wide", group: "photoshoot", title: "Camera · wide lens note", description: "Added to the camera line at 24 mm and wider.",
                    defaultText: ", slight wide-angle distortion"),
        PromptEntry(key: "shoot.camera.tele", group: "photoshoot", title: "Camera · long lens note", description: "Added to the camera line at 85 mm and longer.",
                    defaultText: ", compressed background, creamy bokeh"),
        PromptEntry(key: "video.user.direction", group: "video", title: "User section",
                    description: "The user’s own direction, after every system section (anything that would change her identity is removed first).",
                    defaultText: "Direction from the user: {direction}", placeholders: [ph("direction", "the user’s direction", true)]),
        PromptEntry(key: "video.replicate.subjects", group: "video", title: "Draft/Standard/HD · subjects", description: "subject_definitions of the short prompt.",
                    defaultText: "<Subject 1> is the person in <Video 1>.\n<Subject 2> is {subject}, no tattoos.\n<Video 1> is the source video.",
                    placeholders: [ph("subject", "the person in <Image 1> to <Image n>: her look", true)]),
        PromptEntry(key: "video.replicate.summary", group: "video", title: "Draft/Standard/HD · summary", description: "summary of the short prompt.",
                    defaultText: "[video editing + character replacement] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies <Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, eyebrow raise, mouth and lip movement and head turn, at the same moments, and the same body motion. The camera, the exact framing and crop, the background and the lighting of <Video 1> stay unchanged. Any caption or on-screen text is removed."),
        PromptEntry(key: "video.replicate.summary.silent", group: "video", title: "Draft/Standard/HD · summary (not speaking)",
                    description: "summary of the short prompt when the performer does not speak or sing.",
                    defaultText: "[video editing + character replacement] <Subject 1> is replaced by <Subject 2>. <Subject 2> copies <Subject 1>'s facial performance exactly, frame by frame and with the same intensity: every eye movement, side glance, blink, eyebrow raise and head turn, at the same moments, and the same body motion. The camera, the exact framing and crop, the background and the lighting of <Video 1> stay unchanged. Any caption or on-screen text is removed."),
        PromptEntry(key: "video.replicate.retention", group: "video", title: "Draft/Standard/HD · retention", description: "retention_analysis of the short prompt.",
                    defaultText: "<Video 1>: fully_preserved - camera motion, framing and crop, background, lighting and timing.\n<Subject 1>: replaced - only the facial expressions, mouth movements and body motion are kept, not the face, hair, tattoos, jewellery, clothes, body shape or proportions.\n<Subject 2>: reference - {reference}.",
                    placeholders: [ph("reference", "face, body and outfit image ranges and the never-add list", true)]),
        PromptEntry(key: "video.replicate.detailed", group: "video", title: "Draft/Standard/HD · details", description: "detailed_description of the short prompt.",
                    defaultText: "Casual phone video, realistic. [Shot 1] <Subject 2> in the same place, framed exactly like <Subject 1>: keep the exact framing and crop of <Video 1>, the camera does not pull back. The face is fully alive and mirrors every expression of <Subject 1> and the words being mouthed. Sharp face matching {faceRef}, natural skin texture, no beauty filter. No text anywhere.",
                    placeholders: [ph("faceRef", "<Image 1>, or \"the description\"")]),
        PromptEntry(key: "video.replicate.detailed.silent", group: "video", title: "Draft/Standard/HD · details (not speaking)",
                    description: "detailed_description of the short prompt when the performer does not speak or sing.",
                    defaultText: "Casual phone video, realistic. [Shot 1] <Subject 2> in the same place, framed exactly like <Subject 1>: keep the exact framing and crop of <Video 1>, the camera does not pull back. The face is fully alive and mirrors every expression of <Subject 1>. Sharp face matching {faceRef}, natural skin texture, no beauty filter. No text anywhere.",
                    placeholders: [ph("faceRef", "<Image 1>, or \"the description\"")]),
        PromptEntry(key: "video.mouth.speaking", group: "video", title: "Mouth line (speaking)",
                    description: "Ends the details of a character swap when “Performer is speaking” is on (the clip is sent with its sound).",
                    defaultText: "<Subject 2>'s mouth follows <Video 1> and is in sync with <Audio 1>'s speech."),
        PromptEntry(key: "video.mouth.silent", group: "video", title: "Mouth line (not speaking)",
                    description: "Ends the details of a character swap when “Performer is speaking” is off (the clip is sent without sound).",
                    defaultText: "<Subject 2>'s mouth follows <Video 1> exactly; she does not speak, sing or mouth words."),
    ]

    /// Sample values for the demo preview.
    public static let sample: [String: String] = [
        "name": "Demo model", "look": "early 20s, long dark hair, warm brown eyes", "refCount": "6", "lora": "", "outfit": "black slip dress",
        "scene": "rooftop · golden hour", "shot": "medium", "lens": "35", "aperture": "f/2.8", "lensNote": "", "light": "golden hour", "grade": "phone-natural",
        "direction": "laughing mid-step", "style": PromptEngine.houseStyle, "never": PromptEngine.globalNever.joined(separator: ", "), "refIndex": "7",
        "angle": "front", "framing": "head to toe",
    ]
}
