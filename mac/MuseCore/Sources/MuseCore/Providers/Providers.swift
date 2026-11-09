import Foundation

// Settings → Providers (owner-approved 2026-11-09; server contract WS5, plans/api.md "Bring your own provider"): the
// owner's own provider accounts. A key is checked by the server, stored encrypted and never returned (only its last 4);
// the provider's models are browsed, added, switched on and renamed, and enabled ones join the AI Suite's model picker.
// Owner only (403 owner_only for members).

public struct ProviderKind: Decodable, Hashable, Sendable, Identifiable {
    public var kind: String
    public var label: String
    public var keyHint: String?
    public var keyUrl: String?
    public var id: String { kind }

    public init(kind: String, label: String, keyHint: String? = nil, keyUrl: String? = nil) {
        self.kind = kind
        self.label = label
        self.keyHint = keyHint
        self.keyUrl = keyUrl
    }

    enum CodingKeys: String, CodingKey { case kind, label, keyHint, keyUrl }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        label = c.v(.label, kind)
        keyHint = c.o(.keyHint)
        keyUrl = c.o(.keyUrl)
    }
}

public struct ProviderAccount: Decodable, Hashable, Sendable, Identifiable {
    public struct Counts: Decodable, Hashable, Sendable {
        public var added: Int
        public var enabled: Int
        public init(added: Int = 0, enabled: Int = 0) {
            self.added = added
            self.enabled = enabled
        }
        enum CodingKeys: String, CodingKey { case added, enabled }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            added = c.v(.added, 0)
            enabled = c.v(.enabled, 0)
        }
    }

    public var id: String
    public var kind: String
    public var label: String
    /// "…a1b2": all the app ever sees of the key.
    public var keyLast4: String
    /// "ok" | "invalid" (the provider refused the key during a run).
    public var status: String
    public var checkedAt: Int64?
    public var createdAt: Int64?
    public var models: Counts

    public init(id: String, kind: String, label: String, keyLast4: String, status: String = "ok", checkedAt: Int64? = nil, createdAt: Int64? = nil,
                models: Counts = Counts()) {
        self.id = id
        self.kind = kind
        self.label = label
        self.keyLast4 = keyLast4
        self.status = status
        self.checkedAt = checkedAt
        self.createdAt = createdAt
        self.models = models
    }

    enum CodingKeys: String, CodingKey { case id, kind, label, keyLast4, status, checkedAt, createdAt, models }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.v(.kind, "")
        label = c.v(.label, kind)
        keyLast4 = c.v(.keyLast4, "")
        status = c.v(.status, "ok")
        checkedAt = c.o(.checkedAt)
        createdAt = c.o(.createdAt)
        models = c.v(.models, Counts())
    }
}

/// A price the provider publishes, or the owner set.
public struct ProviderPrice: Decodable, Hashable, Sendable {
    public var basis: String
    public var costUsd: Double
    public var source: String?
    public init(basis: String, costUsd: Double, source: String? = nil) {
        self.basis = basis
        self.costUsd = costUsd
        self.source = source
    }
    enum CodingKeys: String, CodingKey { case basis, costUsd, source }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        basis = c.v(.basis, "per_run")
        costUsd = c.v(.costUsd, 0)
        source = c.o(.source)
    }
}

/// One of the provider's models, as browsed (`added` when it is one of the studio's custom models).
public struct ProviderCatalogModel: Decodable, Hashable, Sendable, Identifiable {
    public struct Added: Decodable, Hashable, Sendable {
        public var id: String
        public var enabled: Bool
        public init(id: String, enabled: Bool) {
            self.id = id
            self.enabled = enabled
        }
    }

    public var ref: String
    public var name: String
    public var description: String?
    /// "image" | "video" | nil (unknown).
    public var kind: String?
    public var missing: [String]
    public var ready: Bool
    public var price: ProviderPrice?
    public var added: Added?
    public var id: String { ref }

    public init(ref: String, name: String, description: String? = nil, kind: String? = nil, missing: [String] = [], ready: Bool = true,
                price: ProviderPrice? = nil, added: Added? = nil) {
        self.ref = ref
        self.name = name
        self.description = description
        self.kind = kind
        self.missing = missing
        self.ready = ready
        self.price = price
        self.added = added
    }

    enum CodingKeys: String, CodingKey { case ref, name, description, kind, missing, ready, price, added }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        name = c.v(.name, ref)
        description = c.o(.description)
        kind = c.o(.kind)
        missing = c.v(.missing, [])
        ready = c.v(.ready, true)
        price = c.o(.price)
        added = c.o(.added)
    }
}

/// One of the studio's custom models (`c_…`).
public struct ProviderCustomModel: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var providerId: String
    public var providerKind: String
    public var ref: String
    public var providerName: String
    public var displayName: String
    public var kind: String
    public var enabled: Bool
    public var members: Bool
    /// "ready" | "needs_setup".
    public var status: String
    public var missing: [String]
    public var price: ProviderPrice?

    public init(id: String, providerId: String, providerKind: String = "", ref: String, providerName: String = "", displayName: String, kind: String = "video",
                enabled: Bool = false, members: Bool = false, status: String = "ready", missing: [String] = [], price: ProviderPrice? = nil) {
        self.id = id
        self.providerId = providerId
        self.providerKind = providerKind
        self.ref = ref
        self.providerName = providerName
        self.displayName = displayName
        self.kind = kind
        self.enabled = enabled
        self.members = members
        self.status = status
        self.missing = missing
        self.price = price
    }

    enum CodingKeys: String, CodingKey { case id, providerId, providerKind, ref, providerName, displayName, kind, enabled, members, status, missing, price }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        providerId = c.v(.providerId, "")
        providerKind = c.v(.providerKind, "")
        ref = c.v(.ref, "")
        providerName = c.v(.providerName, ref)
        displayName = c.v(.displayName, providerName)
        kind = c.v(.kind, "video")
        enabled = c.v(.enabled, false)
        members = c.v(.members, false)
        status = c.v(.status, "ready")
        missing = c.v(.missing, [])
        price = c.o(.price)
    }
}

public struct ProviderKindsList: Decodable, Sendable {
    public var kinds: [ProviderKind]
    public var keysReady: Bool
    enum CodingKeys: String, CodingKey { case kinds, keysReady }
    public init(kinds: [ProviderKind], keysReady: Bool) {
        self.kinds = kinds
        self.keysReady = keysReady
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kinds = c.v(.kinds, [])
        keysReady = c.v(.keysReady, true)
    }
}

public struct ProviderAccountsList: Decodable, Sendable {
    public var providers: [ProviderAccount]
    public var keysReady: Bool
    enum CodingKeys: String, CodingKey { case providers, keysReady }
    public init(providers: [ProviderAccount], keysReady: Bool) {
        self.providers = providers
        self.keysReady = keysReady
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        providers = c.v(.providers, [])
        keysReady = c.v(.keysReady, true)
    }
}

public struct ProviderCatalogPage: Decodable, Sendable {
    public var models: [ProviderCatalogModel]
    public var nextCursor: String?
    enum CodingKeys: String, CodingKey { case models, nextCursor }
    public init(models: [ProviderCatalogModel], nextCursor: String? = nil) {
        self.models = models
        self.nextCursor = nextCursor
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        models = c.v(.models, [])
        nextCursor = c.o(.nextCursor)
    }
}

struct CustomModelList: Decodable {
    var models: [ProviderCustomModel]
    enum CodingKeys: String, CodingKey { case models }
    init(from d: Decoder) throws { models = (try? d.container(keyedBy: CodingKeys.self).decode([ProviderCustomModel].self, forKey: .models)) ?? [] }
}

public protocol ProvidersAPI: Sendable {
    func providerKinds() async throws -> ProviderKindsList
    func providers() async throws -> ProviderAccountsList
    /// The key is checked by the server and stored encrypted; it is never sent back.
    func addProvider(kind: String, apiKey: String, label: String?) async throws -> ProviderAccount
    func replaceProviderKey(_ id: String, apiKey: String) async throws -> ProviderAccount
    func removeProvider(_ id: String) async throws
    func providerModels(_ id: String, query: String, kind: String?, cursor: String?) async throws -> ProviderCatalogPage
    func addProviderModel(_ id: String, ref: String, displayName: String?) async throws -> ProviderCustomModel
    func customModels() async throws -> [ProviderCustomModel]
    func updateCustomModel(_ id: String, enabled: Bool?, displayName: String?) async throws -> ProviderCustomModel
    func removeCustomModel(_ id: String) async throws
}

public enum ProviderText {
    /// "Key ending a1b2, added 8 Nov. 9 of 48 models on." (the owner's words in the approved mock).
    public static func line(_ p: ProviderAccount, now: Date = Date()) -> String {
        let last4 = p.keyLast4.replacingOccurrences(of: "…", with: "")
        var s = "Key ending \(last4)"
        if let c = p.createdAt {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("dMMM")
            s += ", added \(f.string(from: Date(timeIntervalSince1970: Double(c) / 1000)))"
        }
        s += ". \(p.models.enabled) of \(p.models.added) models on."
        if p.status == "invalid" { s += " The provider refused this key: replace it." }
        return s
    }

    /// "$0.07/s", "$0.04" (a run), "" when unknown.
    public static func price(_ p: ProviderPrice?) -> String {
        guard let p else { return "" }
        let v = p.costUsd >= 0.1 ? String(format: "$%.2f", p.costUsd) : String(format: "$%.3f", p.costUsd)
        return p.basis == "per_second" ? v + "/s" : v
    }

    /// The server's errors in plain words.
    public static func message(_ e: Error) -> String {
        guard let a = e as? ApiError else { return e.localizedDescription }
        switch a.code {
        case "invalid_key": return "The provider didn't accept that key. Check it and paste it again."
        case "provider_keys_unavailable": return "Provider keys aren't set up on the server yet."
        case "provider_unreachable": return "Couldn't reach the provider just now. Try again in a minute."
        case "needs_setup": return "This model needs a setting MUSE can't fill in yet, so it can't be switched on."
        case "price_required": return "This model needs a price before it can be switched on."
        default: return a.friendlyMessage
        }
    }
}

// MARK: HTTP

extension HTTPMuseAPI: ProvidersAPI {
    private struct AddBody: Encodable { var kind: String; var apiKey: String; var label: String? }
    private struct KeyBody: Encodable { var apiKey: String }
    private struct RefBody: Encodable { var ref: String; var displayName: String? }
    private struct ModelPatch: Encodable { var enabled: Bool?; var displayName: String? }

    public func providerKinds() async throws -> ProviderKindsList { try await suiteCall("GET", "v1/providers/kinds") }
    public func providers() async throws -> ProviderAccountsList { try await suiteCall("GET", "v1/providers") }
    public func addProvider(kind: String, apiKey: String, label: String?) async throws -> ProviderAccount {
        try await suiteCall("POST", "v1/providers", body: try JSONEncoder().encode(AddBody(kind: kind, apiKey: apiKey, label: label)))
    }
    public func replaceProviderKey(_ id: String, apiKey: String) async throws -> ProviderAccount {
        try await suiteCall("PATCH", "v1/providers/\(Self.pathId(id))", body: try JSONEncoder().encode(KeyBody(apiKey: apiKey)))
    }
    public func removeProvider(_ id: String) async throws { try await suiteSend("DELETE", "v1/providers/\(Self.pathId(id))") }
    public func providerModels(_ id: String, query: String, kind: String?, cursor: String?) async throws -> ProviderCatalogPage {
        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "50")]
            + (kind.map { [URLQueryItem(name: "kind", value: $0)] } ?? []) + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return try await suiteCall("GET", "v1/providers/\(Self.pathId(id))/models?\(q.percentEncodedQuery ?? "")")
    }
    public func addProviderModel(_ id: String, ref: String, displayName: String?) async throws -> ProviderCustomModel {
        try await suiteCall("POST", "v1/providers/\(Self.pathId(id))/models", body: try JSONEncoder().encode(RefBody(ref: ref, displayName: displayName)))
    }
    public func customModels() async throws -> [ProviderCustomModel] {
        let l: CustomModelList = try await suiteCall("GET", "v1/providers/models")
        return l.models
    }
    public func updateCustomModel(_ id: String, enabled: Bool?, displayName: String?) async throws -> ProviderCustomModel {
        try await suiteCall("PATCH", "v1/providers/models/\(Self.pathId(id))", body: try JSONEncoder().encode(ModelPatch(enabled: enabled, displayName: displayName)))
    }
    public func removeCustomModel(_ id: String) async throws { try await suiteSend("DELETE", "v1/providers/models/\(Self.pathId(id))") }

    /// An id as one path segment (letters, digits, - and _ only; anything else is percent-encoded).
    static func pathId(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }
}

// MARK: Demo mode

/// Demo mode's provider catalogs (no provider is called; nothing is spent).
public enum DemoProviders {
    public static let kinds = [ProviderKind(kind: "replicate", label: "Replicate", keyHint: "r8_…", keyUrl: "https://replicate.com/account/api-tokens"),
                               ProviderKind(kind: "fal", label: "fal", keyHint: "Key ID:Secret", keyUrl: "https://fal.ai/dashboard/keys")]

    public static func catalog(_ kind: String) -> [ProviderCatalogModel] {
        kind == "fal" ? [
            ProviderCatalogModel(ref: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video", name: "Kling 2.5 Turbo Pro", kind: "video", price: ProviderPrice(basis: "per_second", costUsd: 0.07, source: "provider")),
            ProviderCatalogModel(ref: "fal-ai/bytedance/seedance/v1/pro/text-to-video", name: "Seedance 1 Pro", kind: "video", price: ProviderPrice(basis: "per_second", costUsd: 0.12, source: "provider")),
            ProviderCatalogModel(ref: "fal-ai/wan-25-preview/text-to-video", name: "Wan 2.5", kind: "video", price: ProviderPrice(basis: "per_second", costUsd: 0.05, source: "provider")),
            ProviderCatalogModel(ref: "fal-ai/flux-pro/kontext", name: "FLUX.1 Kontext Pro", kind: "image", price: ProviderPrice(basis: "per_run", costUsd: 0.04, source: "provider")),
            ProviderCatalogModel(ref: "fal-ai/imagen4/preview", name: "Imagen 4", kind: "image", price: ProviderPrice(basis: "per_run", costUsd: 0.05, source: "provider")),
        ] : [
            ProviderCatalogModel(ref: "black-forest-labs/flux-1.1-pro", name: "FLUX 1.1 Pro", kind: "image"),
            ProviderCatalogModel(ref: "google/veo-3", name: "Veo 3", kind: "video"),
            ProviderCatalogModel(ref: "luma/ray-2", name: "Ray 2", kind: "video", missing: ["loop"], ready: false),
        ]
    }
}

extension FakeMuseAPI: ProvidersAPI {
    private func ownerOnly() throws { guard suiteIsOwner else { throw ApiError("owner_only", "Only the studio owner can manage providers") } }

    public func providerKinds() async throws -> ProviderKindsList {
        try ownerOnly()
        return ProviderKindsList(kinds: DemoProviders.kinds, keysReady: true)
    }

    public func providers() async throws -> ProviderAccountsList {
        try ownerOnly()
        return ProviderAccountsList(providers: demoProviders.map(withCounts), keysReady: true)
    }

    private func withCounts(_ p: ProviderAccount) -> ProviderAccount {
        var x = p
        let mine = demoCustomModels.filter { $0.providerId == p.id }
        x.models = .init(added: mine.count, enabled: mine.filter(\.enabled).count)
        return x
    }

    public func addProvider(kind: String, apiKey: String, label: String?) async throws -> ProviderAccount {
        try ownerOnly()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DemoProviders.kinds.contains(where: { $0.kind == kind }) else { throw ApiError("bad_request", "Unknown provider") }
        guard key.count >= 8 else { throw ApiError("invalid_key", "The provider didn't accept that key") }
        let p = ProviderAccount(id: "prov_" + shortId(), kind: kind, label: label ?? DemoProviders.kinds.first { $0.kind == kind }!.label,
                                keyLast4: "…" + String(key.suffix(4)), createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        demoProviders.append(p)
        return p
    }

    public func replaceProviderKey(_ id: String, apiKey: String) async throws -> ProviderAccount {
        try ownerOnly()
        guard let i = demoProviders.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "No such provider") }
        guard apiKey.count >= 8 else { throw ApiError("invalid_key", "The provider didn't accept that key") }
        demoProviders[i].keyLast4 = "…" + String(apiKey.suffix(4))
        demoProviders[i].status = "ok"
        return withCounts(demoProviders[i])
    }

    public func removeProvider(_ id: String) async throws {
        try ownerOnly()
        demoProviders.removeAll { $0.id == id }
        demoCustomModels.removeAll { $0.providerId == id }
    }

    public func providerModels(_ id: String, query: String, kind: String?, cursor: String?) async throws -> ProviderCatalogPage {
        try ownerOnly()
        guard let p = demoProviders.first(where: { $0.id == id }) else { throw ApiError("not_found", "No such provider") }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = DemoProviders.catalog(p.kind).filter { m in
            (q.isEmpty || "\(m.name) \(m.ref)".lowercased().contains(q)) && (kind == nil || m.kind == kind)
        }.map { m -> ProviderCatalogModel in
            var x = m
            x.added = demoCustomModels.first { $0.providerId == id && $0.ref == m.ref }.map { .init(id: $0.id, enabled: $0.enabled) }
            return x
        }
        return ProviderCatalogPage(models: list)
    }

    public func addProviderModel(_ id: String, ref: String, displayName: String?) async throws -> ProviderCustomModel {
        try ownerOnly()
        guard let p = demoProviders.first(where: { $0.id == id }), let m = DemoProviders.catalog(p.kind).first(where: { $0.ref == ref }) else {
            throw ApiError("not_found", "No such model")
        }
        if let had = demoCustomModels.first(where: { $0.providerId == id && $0.ref == ref }) { return had }
        let c = ProviderCustomModel(id: "c_" + shortId(), providerId: id, providerKind: p.kind, ref: ref, providerName: m.name, displayName: displayName ?? m.name,
                                    kind: m.kind ?? "video", status: m.ready ? "ready" : "needs_setup", missing: m.missing, price: m.price)
        demoCustomModels.append(c)
        return c
    }

    public func customModels() async throws -> [ProviderCustomModel] {
        try ownerOnly()
        return demoCustomModels
    }

    public func updateCustomModel(_ id: String, enabled: Bool?, displayName: String?) async throws -> ProviderCustomModel {
        try ownerOnly()
        guard let i = demoCustomModels.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "No such model") }
        if enabled == true {
            if !demoCustomModels[i].missing.isEmpty { throw ApiError("needs_setup", "This model needs setting up") }
            if demoCustomModels[i].price == nil { throw ApiError("price_required", "This model needs a price") }
        }
        if let enabled { demoCustomModels[i].enabled = enabled }
        if let n = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { demoCustomModels[i].displayName = String(n.prefix(60)) }
        return demoCustomModels[i]
    }

    public func removeCustomModel(_ id: String) async throws {
        try ownerOnly()
        demoCustomModels.removeAll { $0.id == id }
    }
}
