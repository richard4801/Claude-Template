import MuseCore
import Observation
import SwiftUI

/// Settings → Providers (owner-approved 2026-11-09; WS5's contract, MuseCore Providers.swift).
@Observable @MainActor
final class ProvidersState {
    var kinds: [ProviderKind] = []
    var accounts: [ProviderAccount] = []
    /// false: the server has no key store yet (PROVIDER_KEYS_SECRET unset): keys can't be added.
    var keysReady = true
    var loaded = false
    var loadError: String?
    /// The provider whose models are listed.
    var selected: String?
    var catalog: [ProviderCatalogModel] = []
    var customs: [ProviderCustomModel] = []
    var search = ""
    /// "all" | "video" | "image" | "on".
    var filter = "all"
    var loadingModels = false
    /// The add-a-key form: open, its provider, whether it replaces a provider's key, and the key being typed (never stored).
    var adding = false
    var addKind = "replicate"
    var replacing: String?
    var keyText = ""
    var saving = false
    var formError: String?
}

extension AppStore {
    var providersAPI: (any ProvidersAPI)? { api as? any ProvidersAPI }

    func loadProviders() async {
        guard isOwner, let api = providersAPI else { return }
        let s = providersState
        do {
            async let k = api.providerKinds()
            async let a = api.providers()
            let (kinds, accounts) = try await (k, a)
            s.kinds = kinds.kinds
            s.accounts = accounts.providers
            s.keysReady = kinds.keysReady && accounts.keysReady
            s.loadError = nil
            if s.selected == nil || !s.accounts.contains(where: { $0.id == s.selected }) { s.selected = s.accounts.first?.id }
            if s.addKind.isEmpty || !s.kinds.contains(where: { $0.kind == s.addKind }) { s.addKind = s.kinds.first?.kind ?? "replicate" }
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            s.loadError = "This server doesn't support your own providers yet."
        } catch {
            s.loadError = ProviderText.message(error)
        }
        s.loaded = true
        await loadProviderModels()
    }

    /// The selected provider's models (the search and filter applied) and the studio's custom models.
    func loadProviderModels() async {
        let s = providersState
        guard let api = providersAPI, let id = s.selected else { s.catalog = []; return }
        s.loadingModels = true
        defer { s.loadingModels = false }
        do {
            let query = s.search
            let kind: String? = s.filter == "video" || s.filter == "image" ? s.filter : nil
            async let page = api.providerModels(id, query: query, kind: kind, cursor: nil)
            async let mine = api.customModels()
            let (p, c) = try await (page, mine)
            guard s.selected == id else { return }
            s.catalog = p.models
            s.customs = c
        } catch {
            showToast(ProviderText.message(error))
        }
    }

    func openProviderForm(replacing id: String? = nil) {
        let s = providersState
        s.replacing = id
        if let id, let p = s.accounts.first(where: { $0.id == id }) { s.addKind = p.kind }
        s.keyText = ""
        s.formError = nil
        s.adding = true
    }

    func closeProviderForm() {
        let s = providersState
        s.adding = false
        s.keyText = ""
        s.replacing = nil
        s.formError = nil
    }

    /// Saves the key (checked by the server first). The typed key is cleared whatever happens.
    func saveProviderKey() {
        let s = providersState
        guard let api = providersAPI, !s.saving else { return }
        let key = s.keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { s.formError = "Paste the key first."; return }
        s.saving = true
        Task {
            defer {
                s.saving = false
                s.keyText = ""
            }
            do {
                let p: ProviderAccount
                if let id = s.replacing {
                    p = try await api.replaceProviderKey(id, apiKey: key)
                } else {
                    p = try await api.addProvider(kind: s.addKind, apiKey: key, label: nil)
                }
                s.adding = false
                s.replacing = nil
                s.formError = nil
                s.selected = p.id
                showToast("\(p.label) key saved, ending \(p.keyLast4.replacingOccurrences(of: "…", with: ""))")
                await loadProviders()
            } catch {
                s.formError = ProviderText.message(error)
            }
        }
    }

    func removeProvider(_ p: ProviderAccount) {
        guard let api = providersAPI else { return }
        Task {
            do {
                try await api.removeProvider(p.id)
                showToast("\(p.label) removed. Its models left the AI Suite.")
                providersState.selected = nil
                await loadProviders()
                await loadEngines(force: true)
            } catch {
                showToast(ProviderText.message(error))
            }
        }
    }

    /// The studio's custom model for a catalog entry.
    func customModel(for m: ProviderCatalogModel) -> ProviderCustomModel? {
        let s = providersState
        if let id = m.added?.id { return s.customs.first { $0.id == id } }
        return s.customs.first { $0.ref == m.ref && $0.providerId == s.selected }
    }

    /// On: added (if needed) and switched on; off: switched off. Enabled models join the Suite's model picker.
    func setProviderModel(_ m: ProviderCatalogModel, on: Bool) {
        let s = providersState
        guard let api = providersAPI, let pid = s.selected else { return }
        Task {
            do {
                var c = customModel(for: m)
                if c == nil, on { c = try await api.addProviderModel(pid, ref: m.ref, displayName: nil) }
                if let c { _ = try await api.updateCustomModel(c.id, enabled: on, displayName: nil) }
                await loadProviderModels()
                await loadProviders()
                await loadEngines(force: true)
            } catch {
                showToast(ProviderText.message(error))
                await loadProviderModels()
            }
        }
    }

    func renameProviderModel(_ m: ProviderCatalogModel, to name: String) {
        let s = providersState
        guard let api = providersAPI, let pid = s.selected else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        Task {
            do {
                if let c = customModel(for: m) {
                    _ = try await api.updateCustomModel(c.id, enabled: nil, displayName: n)
                } else {
                    _ = try await api.addProviderModel(pid, ref: m.ref, displayName: n)
                }
                await loadProviderModels()
                await loadEngines(force: true)
            } catch {
                showToast(ProviderText.message(error))
            }
        }
    }
}
