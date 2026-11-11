import Foundation

// "Pick the model everywhere" (owner requirement 2026-11-08, WS6 Mac; server contract from WS13): every surface that
// makes images or video (or runs an AI tool on them) has the owner's Model pill, and Settings → Default models sets what
// "Auto" uses per purpose. Owner only: members never see engine names (403 owner_only on every override).
//
//   GET   /v1/engines[?purpose=P] → {purposes:[{id, label, kind, default, studioDefault}], engines:[Engine]}
//   GET   /v1/engines/defaults    → {defaults:{purpose: model|null}, builtin:{purpose: model}}
//   PATCH /v1/engines/defaults {purpose: model|null}
//   Overrides: engineModel(+resolution) on video and tool paths, imageModel on stills; 400 engine_not_allowed {valid:[…]}.

/// The purposes, as the server names them.
public enum EnginePurpose: String, CaseIterable, Sendable, Hashable, Identifiable {
    case shot, talking, ugc, storyboard, guide, recast, extend, swap, fill, photo, outfit, character, plate, upscale, matte, track, captions, denoise
    public var id: String { rawValue }

    /// The label when the server's list hasn't come yet ("Model for character swap").
    public var fallbackLabel: String {
        switch self {
        case .shot: return "Shots"
        case .talking: return "Talking"
        case .ugc: return "UGC ads"
        case .storyboard: return "Storyboards"
        case .guide: return "Directed shots"
        case .recast: return "Recast"
        case .extend: return "Extend"
        case .swap: return "Character swap"
        case .fill: return "Recreate shots"
        case .photo: return "Photos"
        case .outfit: return "Outfits"
        case .character: return "Model photos"
        case .plate: return "Background plates"
        case .upscale: return "Upscale"
        case .matte: return "Remove background"
        case .track: return "Pick what to keep"
        case .captions: return "Captions"
        case .denoise: return "Noise reduction"
        }
    }

    /// Which request field carries the pick: `imageModel` for stills, else `engineModel`.
    public var isImage: Bool { self == .photo || self == .outfit || self == .character || self == .plate }

    /// The composer's tool → its purpose.
    public init?(tool: ComposerTool) {
        switch tool {
        case .shot: self = .shot
        case .talking: self = .talking
        case .ugc: self = .ugc
        case .storyboard: self = .storyboard
        case .swap: self = .swap
        case .recast: self = .recast
        case .extend: self = .extend
        case .photo: self = .photo
        }
    }
}

/// One purpose in the catalog.
public struct EnginePurposeInfo: Decodable, Hashable, Sendable {
    public var id: String
    public var label: String
    /// "video" | "image" | "tool".
    public var kind: String
    /// What Auto uses (the studio's default, else MUSE's own).
    public var `default`: String?
    /// The studio's own default (nil = MUSE's built-in).
    public var studioDefault: String?

    public init(id: String, label: String, kind: String = "video", default d: String? = nil, studioDefault: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.default = d
        self.studioDefault = studioDefault
    }

    enum CodingKeys: String, CodingKey { case id, label, kind, `default`, studioDefault }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.v(.label, id)
        kind = c.v(.kind, "video")
        self.default = c.o(.default)
        studioDefault = c.o(.studioDefault)
    }
}

/// One engine of the catalog, read into the picker's own entry (SuiteModelOption) so one list view serves every surface.
public struct EngineEntry: Decodable, Hashable, Sendable {
    public struct Limits: Decodable, Hashable, Sendable {
        public var minSeconds: Double?
        public var maxSeconds: Double?
        public var allowedSeconds: [Double]?
        public var aspectRatios: [String]
        public var resolutions: [SuiteResolution]
        public var maxInputSeconds: Double?
        enum CodingKeys: String, CodingKey { case minSeconds, maxSeconds, allowedSeconds, aspectRatios, resolutions, maxInputSeconds }
        public init(minSeconds: Double? = nil, maxSeconds: Double? = nil, allowedSeconds: [Double]? = nil, aspectRatios: [String] = [],
                    resolutions: [SuiteResolution] = [], maxInputSeconds: Double? = nil) {
            self.minSeconds = minSeconds
            self.maxSeconds = maxSeconds
            self.allowedSeconds = allowedSeconds
            self.aspectRatios = aspectRatios
            self.resolutions = resolutions
            self.maxInputSeconds = maxInputSeconds
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            minSeconds = c.o(.minSeconds)
            maxSeconds = c.o(.maxSeconds)
            allowedSeconds = c.o(.allowedSeconds)
            aspectRatios = c.v(.aspectRatios, [])
            resolutions = c.v(.resolutions, [])
            maxInputSeconds = c.o(.maxInputSeconds)
        }
    }

    public var model: String
    public var name: String
    public var kind: String
    public var purposes: [String]
    public var custom: Bool
    /// With `?purpose=`: this is what Auto uses.
    public var isDefault: Bool
    public var notice: String?
    public var limits: Limits
    public var resolution: String?
    public var price: SuiteModelOption.Price?
    public var inputs: SuiteInputs?

    public init(model: String, name: String, kind: String = "video", purposes: [String] = [], custom: Bool = false, isDefault: Bool = false, notice: String? = nil,
                limits: Limits = Limits(), resolution: String? = nil, price: SuiteModelOption.Price? = nil, inputs: SuiteInputs? = nil) {
        self.model = model
        self.name = name
        self.kind = kind
        self.purposes = purposes
        self.custom = custom
        self.isDefault = isDefault
        self.notice = notice
        self.limits = limits
        self.resolution = resolution
        self.price = price
        self.inputs = inputs
    }

    /// 4c: the provider's company name, while the studio shows it to members (always for the owner).
    public var providerName: String?
    /// "Kling 4.0 · Replicate": the name with its provider when the server sends one.
    public var shownName: String { providerName.map { "\(name) · \($0)" } ?? name }

    enum CodingKeys: String, CodingKey { case model, name, kind, purposes, custom, `default`, notice, limits, resolution, price, inputs, providerName }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        name = c.v(.name, model)
        kind = c.v(.kind, "video")
        purposes = c.v(.purposes, [])
        custom = c.v(.custom, false)
        isDefault = c.v(.default, false)
        notice = c.o(.notice)
        providerName = c.o(.providerName)
        limits = c.v(.limits, Limits())
        resolution = c.o(.resolution)
        price = c.o(.price)
        inputs = c.o(.inputs)
    }

    /// The picker's entry: the price per second (or per output second) on the engine's own resolution; the others
    /// show without a price (the server prices only the one it lists).
    public var option: SuiteModelOption {
        let perSecond = price.flatMap { $0.basis == "per_run" ? nil : $0.usd }
        let rs = limits.resolutions.map { r in SuiteResolution(id: r.id, label: r.label, perSec: r.id == resolution ? (perSecond ?? r.perSec) : r.perSec) }
        return SuiteModelOption(model: model, name: name, kind: kind, custom: custom, resolution: resolution, resolutions: rs, perSec: perSecond,
                                perRun: price?.basis == "per_run" ? price?.usd : nil, minSeconds: limits.minSeconds, maxSeconds: limits.maxSeconds,
                                allowedSeconds: limits.allowedSeconds, aspectRatios: limits.aspectRatios, inputs: inputs, price: price)
    }
}

/// GET /v1/engines[?purpose=].
public struct EngineCatalog: Decodable, Sendable {
    public var purposes: [EnginePurposeInfo]
    public var engines: [EngineEntry]

    public init(purposes: [EnginePurposeInfo] = [], engines: [EngineEntry] = []) {
        self.purposes = purposes
        self.engines = engines
    }

    enum CodingKeys: String, CodingKey { case purposes, engines }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        purposes = c.v(.purposes, [])
        engines = c.v(.engines, [])
    }

    public func purpose(_ p: EnginePurpose) -> EnginePurposeInfo? { purposes.first { $0.id == p.rawValue } }

    /// The engines for a purpose (all of them when the list was asked for that purpose already), default first.
    public func engines(for p: EnginePurpose) -> [EngineEntry] {
        let list = engines.filter { $0.purposes.isEmpty || $0.purposes.contains(p.rawValue) }
        return list.sorted { a, b in
            if a.custom != b.custom { return !a.custom }
            if a.isDefault != b.isDefault { return a.isDefault }
            return false
        }
    }

    /// The pill's words for a pick: "Auto (Kling 4.0)" / "Auto" / the model's name (and resolution).
    public func label(_ p: EnginePurpose, model: String?, resolution: String? = nil) -> String {
        guard let model else {
            let d = purpose(p)?.default
            let name = d.flatMap { id in engines.first { $0.model == id }?.name }
            return name.map { "Auto (\($0))" } ?? "Auto"
        }
        let e = engines.first { $0.model == model }
        let name = e?.name ?? model
        let res = resolution.flatMap { r in e?.limits.resolutions.first { $0.id == r }?.label }
        return res.map { "\(name), \(ComposerModelPicker.resLabel($0))" } ?? name
    }
}

/// GET /v1/engines/defaults.
public struct EngineDefaults: Decodable, Sendable, Equatable {
    /// The studio's choice per purpose (nil = MUSE's built-in).
    public var defaults: [String: String?]
    /// MUSE's own per purpose.
    public var builtin: [String: String]

    public init(defaults: [String: String?] = [:], builtin: [String: String] = [:]) {
        self.defaults = defaults
        self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey { case defaults, builtin }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let raw: [String: String?] = (try? c.decode([String: String?].self, forKey: .defaults)) ?? [:]
        defaults = raw
        builtin = c.v(.builtin, [:])
    }

    public func studioDefault(_ p: EnginePurpose) -> String? { defaults[p.rawValue] ?? nil }
}

public protocol EngineChoiceAPI: Sendable {
    func engines(purpose: EnginePurpose?) async throws -> EngineCatalog
    func engineDefaults() async throws -> EngineDefaults
    /// Sets (a model) or clears (nil: back to MUSE's own) one purpose's default.
    func setEngineDefault(_ purpose: EnginePurpose, model: String?) async throws -> EngineDefaults
    /// 4c (owner): "Show provider names to members" and each video/image model's shown/hidden state.
    func engineMembers() async throws -> EngineMembers
    /// PATCH {showProviderNames?, hidden?: {model: true|false}}.
    func setEngineMembers(showProviderNames: Bool?, hidden: [String: Bool]) async throws -> EngineMembers
}

public extension EngineChoiceAPI {
    func engineMembers() async throws -> EngineMembers { throw ApiError("not_found", "This server doesn't have model choice for members yet") }
    func setEngineMembers(showProviderNames: Bool?, hidden: [String: Bool]) async throws -> EngineMembers {
        throw ApiError("not_found", "This server doesn't have model choice for members yet")
    }
}

/// 4c: GET /v1/engines/members (owner): what members see of the studio's models.
public struct EngineMembers: Codable, Hashable, Sendable {
    public struct Model: Codable, Hashable, Sendable, Identifiable {
        public var model: String
        public var name: String
        public var kind: String
        public var custom: Bool?
        public var provider: String?
        /// Shown to members (not hidden).
        public var members: Bool
        public var id: String { model }
    }
    public var showProviderNames: Bool
    public var models: [Model]
}

// MARK: HTTP

extension HTTPMuseAPI: EngineChoiceAPI {
    public func engines(purpose: EnginePurpose?) async throws -> EngineCatalog {
        try await suiteCall("GET", purpose.map { "v1/engines?purpose=\($0.rawValue)" } ?? "v1/engines")
    }

    public func engineDefaults() async throws -> EngineDefaults { try await suiteCall("GET", "v1/engines/defaults") }

    public func setEngineDefault(_ purpose: EnginePurpose, model: String?) async throws -> EngineDefaults {
        // {purpose: model|null}: an explicit null clears it.
        let body = "{\"\(purpose.rawValue)\":\(model.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? "null")}"
        return try await suiteCall("PATCH", "v1/engines/defaults", body: Data(body.utf8))
    }

    public func engineMembers() async throws -> EngineMembers { try await suiteCall("GET", "v1/engines/members") }

    public func setEngineMembers(showProviderNames: Bool?, hidden: [String: Bool]) async throws -> EngineMembers {
        struct Patch: Encodable { var showProviderNames: Bool?; var hidden: [String: Bool]? }
        let body = try JSONEncoder().encode(Patch(showProviderNames: showProviderNames, hidden: hidden.isEmpty ? nil : hidden))
        return try await suiteCall("PATCH", "v1/engines/members", body: body)
    }
}

// MARK: Demo mode

/// The demo's engines per purpose: the registry's video models (shots, swap, recast, extend), two photo models, and
/// the tools' models (upscale, matte, captions, denoise). Free in demo mode.
public enum DemoEngines {
    static let toolEngines: [EngineEntry] = [
        EngineEntry(model: "seedvr2", name: "SeedVR2", kind: "tool", purposes: ["upscale"], isDefault: true,
                    price: SuiteModelOption.Price(basis: "per_output_second", usd: 0.03)),
        EngineEntry(model: "topaz-video", name: "Topaz Video Upscale", kind: "tool", purposes: ["upscale"],
                    price: SuiteModelOption.Price(basis: "per_output_second", usd: 0.08)),
        EngineEntry(model: "rvm", name: "Robust Video Matting", kind: "tool", purposes: ["matte"], isDefault: true,
                    price: SuiteModelOption.Price(basis: "per_second", usd: 0.004)),
        EngineEntry(model: "sam2-video", name: "SAM 2 video", kind: "tool", purposes: ["matte", "track"], isDefault: true,
                    price: SuiteModelOption.Price(basis: "per_second", usd: 0.01)),
        EngineEntry(model: "whisper-large-v3", name: "Whisper large v3", kind: "tool", purposes: ["captions"], isDefault: true,
                    price: SuiteModelOption.Price(basis: "per_second", usd: 0.0005)),
        EngineEntry(model: "resemble-enhance", name: "Resemble Enhance", kind: "tool", purposes: ["denoise"], isDefault: true,
                    price: SuiteModelOption.Price(basis: "per_second", usd: 0.002)),
    ]

    public static func catalog(defaults: [String: String?] = [:]) -> EngineCatalog {
        let s = SuiteDemoCatalog.settings
        var engines: [EngineEntry] = []
        for m in s?.models ?? [] {
            guard let o = SuiteModelOption.from(m, ladder: s?.ladder ?? [:]) else {
                if m.modes.recast, m.enabled, !m.blocked, m.status != "removed" {
                    engines.append(EngineEntry(model: m.id, name: m.name, purposes: ["recast"],
                                               limits: .init(minSeconds: m.duration?.min, maxSeconds: m.duration?.max, aspectRatios: m.aspectRatios, resolutions: m.resolutions),
                                               resolution: m.resolutions.last?.id,
                                               price: m.resolutions.last.map { SuiteModelOption.Price(basis: "per_second", usd: $0.perSec) }))
                }
                continue
            }
            var purposes = ["shot", "storyboard", "swap", "extend", "fill"]
            if o.inputs?.audio == true { purposes.append("talking") }
            if (o.inputs?.images ?? 0) > 0 { purposes.append("ugc") }
            if m.modes.guide { purposes.append("guide") }
            engines.append(EngineEntry(model: o.model, name: o.name, purposes: purposes,
                                       limits: .init(minSeconds: o.minSeconds, maxSeconds: o.maxSeconds, allowedSeconds: o.allowedSeconds,
                                                     aspectRatios: o.aspectRatios, resolutions: o.resolutions),
                                       resolution: o.resolution, price: o.price, inputs: o.inputs))
        }
        for i in FakeMuseAPI.demoImageEngines {
            engines.append(EngineEntry(model: i.model, name: i.name, kind: "image", purposes: ["photo", "outfit", "character", "plate"],
                                       limits: .init(aspectRatios: i.aspectRatios), price: i.price, inputs: i.inputs))
        }
        engines += toolEngines
        let builtin = Self.builtin
        let purposes = EnginePurpose.allCases.map { p in
            EnginePurposeInfo(id: p.rawValue, label: p.fallbackLabel, kind: p.isImage ? "image" : ["upscale", "matte", "track", "captions", "denoise"].contains(p.rawValue) ? "tool" : "video",
                              default: (defaults[p.rawValue] ?? nil) ?? builtin[p.rawValue], studioDefault: defaults[p.rawValue] ?? nil)
        }
        return EngineCatalog(purposes: purposes, engines: engines)
    }

    public static let builtin: [String: String] = [
        "shot": "h3-lite", "talking": "h3-lite", "ugc": "h3-lite", "storyboard": "h3-lite", "guide": "kling-v4", "recast": "kling-o1",
        "extend": "wan-2.7", "swap": "h3-lite", "fill": "h3-lite", "photo": "black-forest-labs/flux-2-pro", "outfit": "black-forest-labs/flux-2-pro",
        "character": "black-forest-labs/flux-2-pro", "plate": "black-forest-labs/flux-2-pro", "upscale": "seedvr2", "matte": "rvm", "track": "sam2-video",
        "captions": "whisper-large-v3", "denoise": "resemble-enhance",
    ]
}

extension FakeMuseAPI: EngineChoiceAPI {
    public func engines(purpose: EnginePurpose?) async throws -> EngineCatalog {
        // 4c: members see the models too (the demo hides none).
        var c = DemoEngines.catalog(defaults: engineDefaultsBox)
        if let p = purpose {
            let d = c.purpose(p)?.default
            c.engines = c.engines.filter { $0.purposes.contains(p.rawValue) }.map { var e = $0; e.isDefault = e.model == d; return e }
        }
        return c
    }

    public func engineDefaults() async throws -> EngineDefaults {
        guard suiteIsOwner else { throw ApiError("owner_only", "Only the studio owner can see models") }
        return EngineDefaults(defaults: engineDefaultsBox, builtin: DemoEngines.builtin)
    }

    public func setEngineDefault(_ purpose: EnginePurpose, model: String?) async throws -> EngineDefaults {
        guard suiteIsOwner else { throw ApiError("owner_only", "Only the studio owner can set default models") }
        if let model, !DemoEngines.catalog().engines.contains(where: { $0.model == model && $0.purposes.contains(purpose.rawValue) }) {
            throw ApiError("engine_not_allowed", "That model can't be used for \(purpose.fallbackLabel.lowercased())")
        }
        engineDefaultsBox[purpose.rawValue] = .some(model)
        return try await engineDefaults()
    }
}
