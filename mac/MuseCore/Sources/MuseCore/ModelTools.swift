import Foundation

// Model tools (plans/api.md "Model tools", 2026-11-04): the owner's image model catalog per step, Enhance and Dress up for the
// 7-image character sheet with review and apply, sheet versions, and archived models. Model names, prices per unit and the catalog
// are owner only; members get neutral labels ("Option A", "Option B").

/// Any JSON value: the owner's advanced inputs (`extra`) and an input's `default` / `enum`.
public enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) { self = .string(s) } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// How the advanced inputs editor shows a value: strings bare, everything else as JSON.
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : "\(n)"
        case .string(let s): return s
        case .array, .object:
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// Parses what the owner typed for an input of `type` ("string", "integer", "number", "boolean", "array", "enum").
    /// Empty text is nil (the key is left out). Numbers and booleans must parse; arrays must be JSON.
    public static func parse(_ text: String, type: String) -> JSONValue? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        switch type {
        case "integer":
            return Int64(s).map { .number(Double($0)) }
        case "number":
            return Double(s).map { .number($0) }
        case "boolean":
            switch s.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: return nil
            }
        case "array":
            return s.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }.flatMap { if case .array = $0 { return $0 } else { return nil } }
        case "enum":
            if let n = Double(s), s.first?.isNumber == true || s.first == "-" { return .number(n) }
            return .string(s)
        default:
            return .string(s)
        }
    }
}

/// An image-generation step whose model the owner can pick.
public enum ImageStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case shot, edit, realism, upscale, dressA, dressB
    public var id: String { rawValue }

    /// The owner's label (Settings → Engines → Image models).
    public var label: String {
        switch self {
        case .shot: return "New shots"
        case .edit: return "Edits"
        case .realism: return "Enhance · realism"
        case .upscale: return "Enhance · upscale"
        case .dressA: return "Dress up · Option A"
        case .dressB: return "Dress up · Option B"
        }
    }

    public var usedBy: String {
        switch self {
        case .shot: return "Photos, template photos, outfit-set fronts, sheet fills, LoRA set"
        case .edit: return "Outfit-set ¾, side and back"
        case .realism: return "Enhance step 1"
        case .upscale: return "Enhance step 2"
        case .dressA: return "Dress up"
        case .dressB: return "Dress up"
        }
    }

    /// The contract's default model per step (the server's `defaultModel` wins).
    public var defaultModel: String {
        switch self {
        case .shot, .dressB: return "black-forest-labs/flux-2-pro"
        case .edit, .dressA: return "qwen/qwen-image-edit-2511"
        case .realism: return "black-forest-labs/flux-krea-dev"
        case .upscale: return "philz1337x/clarity-upscaler"
        }
    }

    /// Replicate collections listed for the step when there's no search.
    public var collections: [String] {
        switch self {
        case .shot: return ["text-to-image", "image-editing"]
        case .edit, .dressA, .dressB: return ["image-editing"]
        case .realism: return ["image-editing", "text-to-image"]
        case .upscale: return ["super-resolution", "ai-image-restoration"]
        }
    }

    /// Steps Shoot, Enhance and Dress up can override per run (owner only).
    public static let shootSteps: [ImageStep] = [.shot]
    public static let enhanceSteps: [ImageStep] = [.realism, .upscale]
    public static let dressUpSteps: [ImageStep] = [.dressA, .dressB]
}

/// "owner/name" → (owner, name). nil when it isn't a model id.
public func parseModelId(_ text: String) -> (owner: String, name: String)? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://replicate.com/", "http://replicate.com/", "replicate.com/"] where s.lowercased().hasPrefix(prefix) {
        s = String(s.dropFirst(prefix.count))
    }
    if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
    while s.hasSuffix("/") { s.removeLast() }
    let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 || (parts.count == 4 && parts[2] == "versions") else { return nil }
    let ok = { (p: String) in !p.isEmpty && p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } }
    guard ok(parts[0]), ok(parts[1]) else { return nil }
    return (parts[0], parts[1])
}

public struct PriceUnit: Codable, Hashable, Sendable {
    public var metric: String
    public var usd: Double
    public var label: String
    public init(metric: String, usd: Double, label: String = "") {
        self.metric = metric
        self.usd = usd
        self.label = label
    }
    enum CodingKeys: String, CodingKey { case metric, usd, label }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        metric = c.v(.metric, "")
        usd = c.v(.usd, 0)
        label = c.v(.label, "")
    }
}

/// A model's price: per unit (official models), per second of hardware time (community models), or unknown.
public struct PriceInfo: Codable, Hashable, Sendable {
    /// per-unit | per-second | unknown
    public var kind: String
    public var units: [PriceUnit]
    public var usdPerSecond: Double?
    public var hardware: String?
    public var typicalUsd: Double?
    /// "model page" | "config"
    public var source: String?

    public init(kind: String, units: [PriceUnit] = [], usdPerSecond: Double? = nil, hardware: String? = nil, typicalUsd: Double? = nil, source: String? = nil) {
        self.kind = kind
        self.units = units
        self.usdPerSecond = usdPerSecond
        self.hardware = hardware
        self.typicalUsd = typicalUsd
        self.source = source
    }

    public static func perUnit(_ units: [PriceUnit], source: String = "model page") -> PriceInfo { PriceInfo(kind: "per-unit", units: units, source: source) }
    public static func perSecond(_ usd: Double, hardware: String?, typical: Double?) -> PriceInfo {
        PriceInfo(kind: "per-second", usdPerSecond: usd, hardware: hardware, typicalUsd: typical, source: "model page")
    }
    public static let unknown = PriceInfo(kind: "unknown")

    enum CodingKeys: String, CodingKey { case kind, units, usdPerSecond, hardware, typicalUsd, source }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = c.v(.kind, "unknown")
        units = c.v(.units, [])
        usdPerSecond = c.o(.usdPerSecond)
        hardware = c.o(.hardware)
        typicalUsd = c.o(.typicalUsd)
        source = c.o(.source)
    }

    public var isPerUnit: Bool { kind == "per-unit" }
    public var isPerSecond: Bool { kind == "per-second" }
    public var isUnknown: Bool { !isPerUnit && !isPerSecond }
}

/// A model in the owner's catalog (search result, collection entry, or a pasted owner/model).
public struct CatalogModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var owner: String
    public var name: String
    public var description: String
    public var runCount: Int
    public var official: Bool
    public var coverUrl: String?
    /// nil = not read yet (search results until opened).
    public var price: PriceInfo?
    public var priceLine: String
    /// nil = schema not read yet.
    public var compatible: Bool?
    public var reasons: [String]
    public var warnings: [String]

    public init(id: String, description: String = "", runCount: Int = 0, official: Bool = false, coverUrl: String? = nil, price: PriceInfo? = nil,
                priceLine: String? = nil, compatible: Bool? = nil, reasons: [String] = [], warnings: [String] = []) {
        self.id = id
        let p = parseModelId(id)
        owner = p?.owner ?? ""
        name = p?.name ?? id
        self.description = description
        self.runCount = runCount
        self.official = official
        self.coverUrl = coverUrl
        self.price = price
        self.priceLine = priceLine ?? ToolPricing.priceLine(price)
        self.compatible = compatible
        self.reasons = reasons
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey { case id, owner, name, description, runCount, official, coverUrl, price, priceLine, compatible, reasons, warnings }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let rawId: String = c.v(.id, "")
        owner = c.v(.owner, "")
        name = c.v(.name, "")
        if owner.isEmpty || name.isEmpty, let p = parseModelId(rawId) {
            if owner.isEmpty { owner = p.owner }
            if name.isEmpty { name = p.name }
        }
        id = rawId.isEmpty ? "\(owner)/\(name)" : rawId
        description = c.v(.description, "")
        runCount = c.o(.runCount) ?? (c.o(.runCount) as Double?).map { Int($0) } ?? 0
        official = c.v(.official, false)
        coverUrl = c.o(.coverUrl)
        price = c.o(.price)
        compatible = c.o(.compatible)
        reasons = c.v(.reasons, [])
        warnings = c.v(.warnings, [])
        priceLine = c.o(.priceLine) ?? ToolPricing.priceLine(price)
    }

    /// "1.2M runs", "48K runs", "312 runs".
    public var runsLabel: String { ToolPricing.runs(runCount) }
    /// What the compatibility badge says.
    public var compatibilityLabel: String {
        switch compatible {
        case .some(true): return warnings.isEmpty ? "Compatible" : "Compatible · \(warnings[0])"
        case .some(false): return reasons.isEmpty ? "Not compatible" : "Not compatible · \(reasons.joined(separator: ", "))"
        case .none: return "Not checked yet"
        }
    }
}

/// One of a model's inputs, from its schema.
public struct InputField: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var required: Bool
    public var defaultValue: JSONValue?
    public var options: [JSONValue]?
    public var minimum: Double?
    public var maximum: Double?
    public var maxItems: Int?
    public var description: String?
    /// What the mapping fills it with (prompt, image, …); nil = only the owner's extra inputs set it.
    public var mappedAs: String?
    public var id: String { name }

    public init(name: String, type: String, required: Bool = false, defaultValue: JSONValue? = nil, options: [JSONValue]? = nil, minimum: Double? = nil,
                maximum: Double? = nil, maxItems: Int? = nil, description: String? = nil, mappedAs: String? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.options = options
        self.minimum = minimum
        self.maximum = maximum
        self.maxItems = maxItems
        self.description = description
        self.mappedAs = mappedAs
    }

    enum CodingKeys: String, CodingKey {
        case name, type, required, minimum, maximum, maxItems, description, mappedAs
        case defaultValue = "default"
        case options = "enum"
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.v(.name, "")
        type = c.v(.type, "string")
        required = c.v(.required, false)
        defaultValue = c.o(.defaultValue)
        options = c.o(.options)
        minimum = c.o(.minimum)
        maximum = c.o(.maximum)
        maxItems = c.o(.maxItems)
        description = c.o(.description)
        mappedAs = c.o(.mappedAs)
    }

    /// Safety-checker switches are never sent (the server refuses them).
    public var isSafetySwitch: Bool { name.lowercased().contains("safety_checker") }
    /// Inputs the owner may set by hand: everything the mapping doesn't fill, minus safety switches.
    public var isEditable: Bool { mappedAs == nil && !isSafetySwitch }
}

/// How the server maps MUSE's inputs onto a model's schema (shown in the advanced view).
public struct ModelMapping: Codable, Hashable, Sendable {
    public struct ImageField: Codable, Hashable, Sendable {
        public var field: String
        public var array: Bool
        public var max: Int?
    }
    public struct Strength: Codable, Hashable, Sendable {
        public var field: String
        public var min: Double
        public var max: Double
    }
    public struct Scale: Codable, Hashable, Sendable {
        public var field: String
        public var kind: String
        public var values: [String]?
    }
    public struct Size: Codable, Hashable, Sendable {
        public var width: String
        public var height: String
    }
    public var prompt: String?
    public var image: ImageField?
    public var extraImageFields: [String]?
    public var aspectRatio: String?
    public var size: Size?
    public var resolution: String?
    public var seed: String?
    public var strength: Strength?
    public var scale: Scale?
    public var outputFormat: String?
    public var outputQuality: String?
    public var count: String?

    public init(prompt: String? = nil, image: ImageField? = nil, aspectRatio: String? = nil, seed: String? = nil, strength: Strength? = nil, scale: Scale? = nil) {
        self.prompt = prompt
        self.image = image
        self.aspectRatio = aspectRatio
        self.seed = seed
        self.strength = strength
        self.scale = scale
    }

    /// "prompt → prompt · image → input_images (up to 8) · seed → seed".
    public var summary: String {
        var parts: [String] = []
        if let p = prompt { parts.append("prompt → \(p)") }
        if let i = image { parts.append("images → \(i.field)" + (i.array ? (i.max.map { " (up to \($0))" } ?? " (list)") : "")) }
        if let x = extraImageFields, !x.isEmpty { parts.append("more images → \(x.joined(separator: ", "))") }
        if let a = aspectRatio { parts.append("size → \(a)") } else if let s = size { parts.append("size → \(s.width) × \(s.height)") }
        if let r = resolution { parts.append("resolution → \(r)") }
        if let s = seed { parts.append("seed → \(s)") }
        if let s = strength { parts.append("strength → \(s.field)") }
        if let s = scale { parts.append("scale → \(s.field)") }
        return parts.joined(separator: " · ")
    }
}

/// The model in use for one step (GET /v1/image-models).
public struct StepModel: Codable, Hashable, Sendable, Identifiable {
    public var step: String
    public var label: String
    public var model: String
    public var defaultModel: String
    public var isDefault: Bool
    public var name: String
    public var official: Bool
    public var price: PriceInfo
    public var priceLine: String
    public var compatible: Bool
    public var reasons: [String]
    public var warnings: [String]
    public var mapping: ModelMapping
    /// The owner's advanced inputs, sent on every run of this step.
    public var extra: [String: JSONValue]
    public var id: String { step }

    public init(step: ImageStep, model: String? = nil, name: String? = nil, official: Bool = true, price: PriceInfo = .unknown, priceLine: String? = nil,
                compatible: Bool = true, reasons: [String] = [], warnings: [String] = [], mapping: ModelMapping = ModelMapping(), extra: [String: JSONValue] = [:]) {
        self.step = step.rawValue
        label = step.label
        let m = model ?? step.defaultModel
        self.model = m
        defaultModel = step.defaultModel
        isDefault = m == step.defaultModel
        self.name = name ?? (parseModelId(m)?.name ?? m)
        self.official = official
        self.price = price
        self.priceLine = priceLine ?? ToolPricing.priceLine(price)
        self.compatible = compatible
        self.reasons = reasons
        self.warnings = warnings
        self.mapping = mapping
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case step, label, model, defaultModel, isDefault, name, official, price, priceLine, compatible, reasons, warnings, mapping, extra }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        step = c.v(.step, "")
        let known = ImageStep(rawValue: step)
        label = c.o(.label) ?? known?.label ?? step
        model = c.v(.model, known?.defaultModel ?? "")
        defaultModel = c.o(.defaultModel) ?? known?.defaultModel ?? model
        isDefault = c.o(.isDefault) ?? (model == defaultModel)
        name = c.o(.name) ?? (parseModelId(model)?.name ?? model)
        official = c.v(.official, false)
        price = c.v(.price, PriceInfo.unknown)
        priceLine = c.o(.priceLine) ?? ToolPricing.priceLine(price)
        compatible = c.v(.compatible, true)
        reasons = c.v(.reasons, [])
        warnings = c.v(.warnings, [])
        mapping = c.v(.mapping, ModelMapping())
        extra = c.v(.extra, [:])
    }

    public var imageStep: ImageStep? { ImageStep(rawValue: step) }
}

public struct ImageModelsResponse: Codable, Sendable {
    public var steps: [StepModel]
    public init(steps: [StepModel]) { self.steps = steps }
}

/// PUT /v1/image-models/{step}
public struct SetImageModelRequest: Codable, Sendable {
    public var model: String
    public var extra: [String: JSONValue]?
    public init(model: String, extra: [String: JSONValue]? = nil) {
        self.model = model
        self.extra = extra
    }

    /// The server's cap on `extra` (bytes of JSON).
    public static let maxExtraBytes = 4096

    /// Checks the owner's advanced inputs before sending: size, no safety-checker switch, and (when the schema is known) every key an input.
    public static func validate(extra: [String: JSONValue], inputs: [InputField]?) -> String? {
        if let bad = extra.keys.sorted().first(where: { $0.lowercased().contains("safety_checker") }) { return "\(bad) can't be changed" }
        if let inputs {
            let names = Set(inputs.map(\.name))
            if let unknown = extra.keys.sorted().first(where: { !names.contains($0) }) { return "\(unknown) isn't an input of this model" }
        }
        let size = (try? JSONEncoder().encode(extra).count) ?? 0
        if size > maxExtraBytes { return "Too many advanced inputs (4 KB at most)" }
        return nil
    }
}

public struct CatalogCollectionRef: Codable, Hashable, Sendable, Identifiable {
    public var slug: String
    public var name: String
    public var description: String
    public var id: String { slug }
    public init(slug: String, name: String, description: String = "") {
        self.slug = slug
        self.name = name
        self.description = description
    }
    enum CodingKeys: String, CodingKey { case slug, name, description }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slug = c.v(.slug, "")
        name = c.v(.name, slug)
        description = c.v(.description, "")
    }
}

/// GET /v1/image-models/catalog?step=&q=&collection=
public struct CatalogQuery: Sendable, Equatable {
    public var step: ImageStep
    public var q: String
    public var collection: String?
    public init(step: ImageStep, q: String = "", collection: String? = nil) {
        self.step = step
        self.q = q
        self.collection = collection
    }

    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "step", value: step.rawValue)]
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { items.append(URLQueryItem(name: "q", value: s)) }
        if let c = collection, !c.isEmpty { items.append(URLQueryItem(name: "collection", value: c)) }
        return items
    }
}

public struct CatalogResponse: Codable, Sendable {
    public var step: String
    public var collections: [CatalogCollectionRef]
    public var models: [CatalogModel]
    public var cachedAt: Int64?
    public init(step: String, collections: [CatalogCollectionRef], models: [CatalogModel], cachedAt: Int64? = nil) {
        self.step = step
        self.collections = collections
        self.models = models
        self.cachedAt = cachedAt
    }
    enum CodingKeys: String, CodingKey { case step, collections, models, cachedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        step = c.v(.step, "")
        collections = c.v(.collections, [])
        models = c.v(.models, [])
        cachedAt = c.o(.cachedAt) ?? (c.o(.cachedAt) as Double?).map { Int64($0) }
    }
}

/// GET /v1/image-models/model?id=owner/name&step=: one model with its mapping and inputs.
public struct ModelDetail: Codable, Hashable, Sendable {
    public var model: CatalogModel
    public var mapping: ModelMapping
    public var inputs: [InputField]
    public var version: String

    public init(model: CatalogModel, mapping: ModelMapping = ModelMapping(), inputs: [InputField] = [], version: String = "") {
        self.model = model
        self.mapping = mapping
        self.inputs = inputs
        self.version = version
    }

    enum CodingKeys: String, CodingKey { case mapping, inputs, version }
    public init(from d: Decoder) throws {
        model = try CatalogModel(from: d)
        let c = try d.container(keyedBy: CodingKeys.self)
        mapping = c.v(.mapping, ModelMapping())
        inputs = c.v(.inputs, [])
        version = c.v(.version, "")
    }
    public func encode(to e: Encoder) throws {
        try model.encode(to: e)
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(mapping, forKey: .mapping)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(version, forKey: .version)
    }

    /// The inputs the owner can set in the advanced view.
    public var editableInputs: [InputField] { inputs.filter(\.isEditable) }
}

// MARK: Enhance and Dress up

public struct ToolOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String?
    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

/// `features.tools.*.models` (owner only): the step's current model.
public struct ToolModelRef: Codable, Hashable, Sendable {
    public var model: String
    public var name: String
    public init(model: String, name: String) {
        self.model = model
        self.name = name
    }
}

public struct EnhanceFeatures: Codable, Hashable, Sendable {
    public var available: Bool
    public var realism: [ToolOption]
    public var upscale: [ToolOption]
    /// Owner only.
    public var models: [String: ToolModelRef]?

    public init(available: Bool = true, realism: [ToolOption] = EnhanceFeatures.realismOptions, upscale: [ToolOption] = EnhanceFeatures.upscaleOptions,
                models: [String: ToolModelRef]? = nil) {
        self.available = available
        self.realism = realism
        self.upscale = upscale
        self.models = models
    }

    enum CodingKeys: String, CodingKey { case available, realism, upscale, models }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        available = c.v(.available, false)
        realism = c.v(.realism, Self.realismOptions)
        upscale = c.v(.upscale, Self.upscaleOptions)
        models = c.o(.models)
    }

    public static let realismOptions = [ToolOption(id: "off", label: "Off"), ToolOption(id: "subtle", label: "Subtle"),
                                        ToolOption(id: "balanced", label: "Balanced"), ToolOption(id: "strong", label: "Strong")]
    public static let upscaleOptions = [ToolOption(id: "off", label: "Off"), ToolOption(id: "2x", label: "2×"), ToolOption(id: "4x", label: "4×")]
    public static let defaultRealism = "balanced"
    public static let defaultUpscale = "2x"
}

public struct DressUpFeatures: Codable, Hashable, Sendable {
    public var available: Bool
    public var options: [ToolOption]
    /// Owner only: dressA / dressB → the model in use.
    public var models: [String: ToolModelRef]?

    public init(available: Bool = true, options: [ToolOption] = DressUpFeatures.defaultOptions, models: [String: ToolModelRef]? = nil) {
        self.available = available
        self.options = options
        self.models = models
    }

    enum CodingKeys: String, CodingKey { case available, options, models }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        available = c.v(.available, false)
        options = c.v(.options, Self.defaultOptions)
        models = c.o(.models)
    }

    public static let defaultOptions = [ToolOption(id: "a", label: "Option A", detail: "Keeps each photo closest"),
                                        ToolOption(id: "b", label: "Option B", detail: "Richer detail"),
                                        ToolOption(id: "both", label: "Both", detail: "Makes both · pick per photo")]
    public static let defaultEngine = "a"
}

/// `features.tools` (GET /v1/settings/studio). nil on servers without the model tools.
public struct ToolsFeatures: Codable, Hashable, Sendable {
    public var enhance: EnhanceFeatures
    public var dressUp: DressUpFeatures
    public init(enhance: EnhanceFeatures = EnhanceFeatures(), dressUp: DressUpFeatures = DressUpFeatures()) {
        self.enhance = enhance
        self.dressUp = dressUp
    }
    enum CodingKeys: String, CodingKey { case enhance, dressUp }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enhance = c.v(.enhance, EnhanceFeatures(available: false))
        dressUp = c.v(.dressUp, DressUpFeatures(available: false))
    }
}

/// Per-run model override (owner only): step → "owner/name". nil or empty = the defaults.
public typealias ModelOverrides = [String: String]

public struct EnhanceRequest: Codable, Sendable, Equatable {
    public var realism: String?
    public var upscale: String?
    public var slots: [String]?
    public var models: ModelOverrides?
    public init(realism: String? = EnhanceFeatures.defaultRealism, upscale: String? = EnhanceFeatures.defaultUpscale, slots: [String]? = nil, models: ModelOverrides? = nil) {
        self.realism = realism
        self.upscale = upscale
        self.slots = slots
        self.models = (models?.isEmpty ?? true) ? nil : models
    }

    public var realismOn: Bool { (realism ?? EnhanceFeatures.defaultRealism) != "off" }
    public var upscaleOn: Bool { (upscale ?? EnhanceFeatures.defaultUpscale) != "off" }
    /// Both steps off can't start (`bad_request`).
    public var isValid: Bool { realismOn || upscaleOn }
}

public struct DressUpEstimateRequest: Codable, Sendable, Equatable {
    public var engine: String?
    public var models: ModelOverrides?
    public init(engine: String? = DressUpFeatures.defaultEngine, models: ModelOverrides? = nil) {
        self.engine = engine
        self.models = (models?.isEmpty ?? true) ? nil : models
    }
}

public struct DressUpRequest: Codable, Sendable, Equatable {
    public var outfitImage: ImageRef
    public var name: String?
    public var engine: String?
    public var models: ModelOverrides?
    public init(outfitImage: ImageRef, name: String? = nil, engine: String? = DressUpFeatures.defaultEngine, models: ModelOverrides? = nil) {
        self.outfitImage = outfitImage
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (n?.isEmpty ?? true) ? nil : String(n!.prefix(80))
        self.engine = engine
        self.models = (models?.isEmpty ?? true) ? nil : models
    }
}

/// POST …/enhance/estimate and …/dress-up/estimate.
public struct ToolEstimate: Codable, Hashable, Sendable {
    public var images: Int
    public var estimate: Double
    public var label: String
    public var perImage: Double?
    public init(images: Int, estimate: Double, label: String, perImage: Double? = nil) {
        self.images = images
        self.estimate = estimate
        self.label = label
        self.perImage = perImage
    }
    enum CodingKeys: String, CodingKey { case images, estimate, label, perImage }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        images = c.v(.images, 0)
        estimate = c.v(.estimate, 0)
        perImage = c.o(.perImage)
        label = c.o(.label) ?? ToolPricing.label(images: images, options: 1, estimate: estimate)
    }
}

public struct ToolResults: Codable, Hashable, Sendable {
    public var a: ImageRef?
    public var b: ImageRef?
    public init(a: ImageRef? = nil, b: ImageRef? = nil) {
        self.a = a
        self.b = b
    }
    public subscript(_ engine: String) -> ImageRef? {
        get { engine == "b" ? b : a }
        set { if engine == "b" { b = newValue } else { a = newValue } }
    }
}

public struct ToolItem: Codable, Hashable, Sendable, Identifiable {
    public var slot: String
    public var label: String
    public var before: ImageRef?
    public var results: ToolResults
    /// waiting | running | done | failed
    public var state: String
    /// pending | keep | reject
    public var decision: String
    public var pick: String?
    public var cost: Double
    public var error: String?
    public var id: String { slot }

    public init(slot: String, label: String? = nil, before: ImageRef?, results: ToolResults = ToolResults(), state: String = "waiting", decision: String = "pending",
                pick: String? = nil, cost: Double = 0, error: String? = nil) {
        self.slot = slot
        self.label = label ?? SheetAngle(rawValue: slot)?.label ?? slot
        self.before = before
        self.results = results
        self.state = state
        self.decision = decision
        self.pick = pick
        self.cost = cost
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case slot, label, before, results, state, decision, pick, cost, error }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slot = c.v(.slot, "")
        label = c.o(.label) ?? SheetAngle(rawValue: slot)?.label ?? slot
        before = c.o(.before)
        results = c.v(.results, ToolResults())
        state = c.v(.state, "waiting")
        decision = c.v(.decision, "pending")
        pick = c.o(.pick)
        cost = c.v(.cost, 0)
        error = c.o(.error)
    }

    public var isDone: Bool { state == "done" }
    public var isKept: Bool { decision == "keep" }
    public var isRejected: Bool { decision == "reject" }
    public var hasResult: Bool { results.a != nil || results.b != nil }
    /// The result shown as "after": the pick, else Option A, else B.
    public var after: ImageRef? { pick.flatMap { results[$0] } ?? results.a ?? results.b }
}

public struct ToolRunOptions: Codable, Hashable, Sendable {
    public var realism: String?
    public var upscale: String?
    public var engine: String?
    public var name: String?
    public var outfitImage: ImageRef?
    public init(realism: String? = nil, upscale: String? = nil, engine: String? = nil, name: String? = nil, outfitImage: ImageRef? = nil) {
        self.realism = realism
        self.upscale = upscale
        self.engine = engine
        self.name = name
        self.outfitImage = outfitImage
    }
}

public struct ToolRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// enhance | dressup
    public var kind: String
    public var modelId: String
    /// running | review | applied | failed | discarded
    public var state: String
    public var options: ToolRunOptions
    public var engines: [String]
    public var items: [ToolItem]
    public var estimate: Double
    public var cost: Double
    public var progress: Double
    public var phase: String
    public var error: String?
    public var createdAt: Int64
    public var finishedAt: Int64?
    public var appliedAt: Int64?
    public var outfitId: String?
    /// Owner only: the models used.
    public var models: ModelOverrides?

    public init(id: String, kind: String, modelId: String, state: String = "running", options: ToolRunOptions = ToolRunOptions(), engines: [String] = ["a"],
                items: [ToolItem] = [], estimate: Double = 0, cost: Double = 0, progress: Double = 0, phase: String = "", error: String? = nil,
                createdAt: Int64 = 0, finishedAt: Int64? = nil, appliedAt: Int64? = nil, outfitId: String? = nil, models: ModelOverrides? = nil) {
        self.id = id
        self.kind = kind
        self.modelId = modelId
        self.state = state
        self.options = options
        self.engines = engines
        self.items = items
        self.estimate = estimate
        self.cost = cost
        self.progress = progress
        self.phase = phase
        self.error = error
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.appliedAt = appliedAt
        self.outfitId = outfitId
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, modelId, state, options, engines, items, estimate, cost, progress, phase, error, createdAt, finishedAt, appliedAt, outfitId, models
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.v(.kind, "enhance")
        modelId = c.v(.modelId, "")
        state = c.v(.state, "running")
        options = c.v(.options, ToolRunOptions())
        engines = c.v(.engines, ["a"])
        items = c.v(.items, [])
        estimate = c.v(.estimate, 0)
        cost = c.v(.cost, 0)
        progress = c.v(.progress, 0)
        phase = c.v(.phase, "")
        error = c.o(.error)
        createdAt = c.o(.createdAt) ?? (c.o(.createdAt) as Double?).map { Int64($0) } ?? 0
        finishedAt = c.o(.finishedAt) ?? (c.o(.finishedAt) as Double?).map { Int64($0) }
        appliedAt = c.o(.appliedAt) ?? (c.o(.appliedAt) as Double?).map { Int64($0) }
        outfitId = c.o(.outfitId)
        models = c.o(.models)
    }

    public var isEnhance: Bool { kind == "enhance" }
    public var isDressUp: Bool { kind == "dressup" }
    public var isRunning: Bool { state == "running" }
    public var isReview: Bool { state == "review" }
    public var isFinished: Bool { ["applied", "failed", "discarded"].contains(state) }
    public var showsBoth: Bool { engines.count > 1 }
    public var keptCount: Int { items.filter(\.isKept).count }
    public var canApply: Bool { isReview && keptCount > 0 }
    public var anyItemRunning: Bool { items.contains { $0.state == "running" || $0.state == "waiting" } }
    public func item(_ slot: String) -> ToolItem? { items.first { $0.slot == slot } }

    /// The items in the order the sheet shows them: face close-ups, then the full body.
    public var orderedItems: [ToolItem] {
        let order = (SheetAngle.faceGroup + SheetAngle.bodyGroup).map(\.rawValue)
        return items.sorted { (order.firstIndex(of: $0.slot) ?? 99) < (order.firstIndex(of: $1.slot) ?? 99) }
    }
}

public struct ToolDecisionRequest: Codable, Sendable, Equatable {
    public var decision: String
    public var pick: String?
    public init(decision: String, pick: String? = nil) {
        self.decision = decision
        self.pick = pick
    }
}

public struct ToolPickRequest: Codable, Sendable { public var pick: String; public init(pick: String) { self.pick = pick } }
public struct ToolRetryRequest: Codable, Sendable { public var engine: String?; public init(engine: String? = nil) { self.engine = engine } }
public struct ToolApplyRequest: Codable, Sendable {
    public var name: String?
    public init(name: String? = nil) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (n?.isEmpty ?? true) ? nil : String(n!.prefix(80))
    }
}

/// POST /v1/tool-runs/{id}/apply
public struct ToolApplyResponse: Codable, Sendable {
    public var run: ToolRun
    public var model: MuseModel
    public var outfit: Outfit?
    public init(run: ToolRun, model: MuseModel, outfit: Outfit? = nil) {
        self.run = run
        self.model = model
        self.outfit = outfit
    }
}

public struct ToolRunQuery: Sendable, Equatable {
    public var modelId: String?
    public var kind: String?
    public init(modelId: String? = nil, kind: String? = nil) {
        self.modelId = modelId
        self.kind = kind
    }
}

/// A saved character sheet (before an Enhance or a restore).
public struct SheetVersion: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Int64
    /// enhance | restore
    public var reason: String
    public var slots: [SheetSlot]
    public init(id: String, createdAt: Int64, reason: String, slots: [SheetSlot]) {
        self.id = id
        self.createdAt = createdAt
        self.reason = reason
        self.slots = slots
    }
    enum CodingKeys: String, CodingKey { case id, createdAt, reason, slots }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = c.o(.createdAt) ?? (c.o(.createdAt) as Double?).map { Int64($0) } ?? 0
        reason = c.v(.reason, "enhance")
        slots = c.v(.slots, [])
    }
    public var reasonLabel: String { reason == "restore" ? "Before a restore" : "Before Enhance" }
    public var filled: Int { slots.filter { $0.image != nil }.count }
    public var cover: ImageRef? { slots.first { $0.key == "face" }?.image ?? slots.first { $0.image != nil }?.image }
}

// MARK: Pricing (plans/api.md "Model tools" §3)

/// Estimates for any model, the same formulas as the server: per unit Σ units × price; by time the typical run (× (scale/2)² for
/// upscales) or 20 s × the price per second; unknown $0.05 a prediction.
public enum ToolPricing {
    /// MP counted for each reference image sent (a shrunk reference; an un-shrunk sheet image counts the same for the estimate).
    public static let refMp = 0.79
    /// `REPLICATE_TIME_EST_SEC`
    public static let timeEstSec = 20.0
    /// `REPLICATE_UNKNOWN_EST_USD`
    public static let unknownEstUsd = 0.05

    /// One prediction's estimate.
    public static func prediction(_ price: PriceInfo?, inputImages: Int = 0, outputMp: Double = 1, scale: Double? = nil) -> Double {
        guard let p = price else { return unknownEstUsd }
        switch p.kind {
        case "per-unit":
            var total = 0.0
            for u in p.units {
                let n: Double
                switch u.metric {
                case "run_count", "image_output_count": n = 1
                case "image_output_megapixel_count": n = outputMp
                case "image_input_megapixel_count": n = refMp * Double(max(0, inputImages))
                default: n = 1
                }
                total += n * u.usd
            }
            return total
        case "per-second":
            if let typical = p.typicalUsd {
                let f = scale.map { ($0 / 2) * ($0 / 2) } ?? 1
                return typical * f
            }
            return timeEstSec * (p.usdPerSecond ?? 0)
        default:
            return unknownEstUsd
        }
    }

    /// "2x" → 2, "4x" → 4, "off" → nil.
    public static func scale(_ id: String?) -> Double? {
        guard let id, id != "off" else { return nil }
        return Double(id.lowercased().replacingOccurrences(of: "x", with: "").replacingOccurrences(of: "×", with: ""))
    }

    /// Enhance, one image: realism (img2img on the original) then upscale (on its output).
    public static func enhancePerImage(realism: String?, upscale: String?, realismPrice: PriceInfo?, upscalePrice: PriceInfo?) -> Double {
        var v = 0.0
        if (realism ?? EnhanceFeatures.defaultRealism) != "off" { v += prediction(realismPrice, inputImages: 1) }
        if let s = scale(upscale ?? EnhanceFeatures.defaultUpscale) { v += prediction(upscalePrice, inputImages: 1, scale: s) }
        return v
    }

    public static func enhance(images: Int, realism: String?, upscale: String?, realismPrice: PriceInfo?, upscalePrice: PriceInfo?) -> ToolEstimate {
        let per = enhancePerImage(realism: realism, upscale: upscale, realismPrice: realismPrice, upscalePrice: upscalePrice)
        let total = per * Double(images)
        return ToolEstimate(images: images, estimate: total, label: label(images: images, options: 1, estimate: total), perImage: per)
    }

    /// Dress up with one option: the full-body front from [sheet front, outfit] (2 images), every other filled slot from
    /// [sheet image, outfit, new front] (3 images).
    public static func dressUpOption(images: Int, price: PriceInfo?) -> Double {
        guard images > 0 else { return 0 }
        return prediction(price, inputImages: 2) + Double(images - 1) * prediction(price, inputImages: 3)
    }

    public static func dressUp(images: Int, engine: String?, priceA: PriceInfo?, priceB: PriceInfo?) -> ToolEstimate {
        let e = engine ?? DressUpFeatures.defaultEngine
        var total = 0.0
        if e == "a" || e == "both" { total += dressUpOption(images: images, price: priceA) }
        if e == "b" || e == "both" { total += dressUpOption(images: images, price: priceB) }
        return ToolEstimate(images: images, estimate: total, label: label(images: images, options: e == "both" ? 2 : 1, estimate: total))
    }

    /// "7 images · about $0.30", "7 images · 2 options · about $0.86".
    public static func label(images: Int, options: Int, estimate: Double) -> String {
        "\(images) image\(images == 1 ? "" : "s")" + (options > 1 ? " · \(options) options" : "") + " · " + PhotoPricing.label(estimate)
    }

    /// The owner's price line when the server didn't send one.
    public static func priceLine(_ p: PriceInfo?) -> String {
        guard let p else { return "price unknown" }
        switch p.kind {
        case "per-unit":
            if p.units.isEmpty { return "price unknown" }
            return p.units.map { "\(usd($0.usd)) \($0.label.isEmpty ? unitLabel($0.metric) : $0.label)" }.joined(separator: " + ")
        case "per-second":
            let hw = p.hardware.map { " on \($0)" } ?? ""
            let per = "\(usd(p.usdPerSecond ?? 0))/s\(hw)"
            if let t = p.typicalUsd { return "by time · about \(usd(t)) a run (\(per))" }
            return "by time · \(per)"
        default:
            return "price unknown"
        }
    }

    static func unitLabel(_ metric: String) -> String {
        switch metric {
        case "run_count": return "per run"
        case "image_output_count": return "per output image"
        case "image_output_megapixel_count": return "per output MP"
        case "image_input_megapixel_count": return "per input MP"
        default: return "per " + metric.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// $0.025, $0.00115, $0.03: as many decimals as the price needs (at least two).
    public static func usd(_ v: Double) -> String {
        for digits in 2...6 {
            let s = Pricing.toFixed(v, digits)
            if abs((Double(s) ?? 0) - v) < 1e-9 { return "$" + trimZeros(s, keep: 2) }
        }
        return "$" + trimZeros(Pricing.toFixed(v, 6), keep: 2)
    }

    static func trimZeros(_ s: String, keep: Int) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        var out = s
        while out.hasSuffix("0") && out.distance(from: dot, to: out.endIndex) > keep + 1 { out.removeLast() }
        return out
    }

    /// 1234567 → "1.2M runs", 48210 → "48K runs", 312 → "312 runs".
    public static func runs(_ n: Int) -> String {
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return (v >= 10 ? String(Int(v.rounded(.down))) : Pricing.toFixed((v * 10).rounded(.down) / 10, 1).replacingOccurrences(of: ".0", with: "")) + "M runs"
        }
        if n >= 1000 { return "\(n / 1000)K runs" }
        return "\(n) run\(n == 1 ? "" : "s")"
    }
}
