import MuseCore
import Observation
import SwiftUI

/// The owner's model for one purpose on this Mac: the model and, for video, its resolution.
struct EnginePick: Hashable {
    var model: String
    var resolution: String?
}

/// "Pick the model everywhere" (owner requirement 2026-11-08; MuseCore EngineChoice.swift): the engine catalog
/// (GET /v1/engines), the studio's defaults, and this session's picks per purpose (nil = Auto, the default).
@Observable @MainActor
final class EngineChoiceState {
    var catalog: EngineCatalog?
    var defaults: EngineDefaults?
    var picks: [EnginePurpose: EnginePick] = [:]
    var loading = false
    var error: String?
}

extension AppStore {
    var engineChoiceAPI: (any EngineChoiceAPI)? { api as? any EngineChoiceAPI }

    /// The catalog for every purpose (owner only), once per session or when asked again.
    func loadEngines(force: Bool = false) async {
        guard isOwner, let api = engineChoiceAPI, !engineChoice.loading, force || engineChoice.catalog == nil else { return }
        engineChoice.loading = true
        defer { engineChoice.loading = false }
        do {
            engineChoice.catalog = try await api.engines(purpose: nil)
            engineChoice.error = nil
            // A pick the list no longer offers goes back to Auto.
            for (p, pick) in engineChoice.picks where !(engineChoice.catalog?.engines(for: p).contains { $0.model == pick.model } ?? true) {
                engineChoice.picks[p] = nil
            }
        } catch {
            engineChoice.error = (error as? ApiError)?.code == "not_found" || (error as? ApiError)?.code == "http_404"
                ? "This server doesn't list models yet" : ((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)
        }
    }

    /// The owner's pick for this purpose (nil = Auto). Members never have one.
    func enginePick(_ p: EnginePurpose) -> EnginePick? { isOwner ? engineChoice.picks[p] : nil }

    func setEnginePick(_ p: EnginePurpose, _ pick: EnginePick?) {
        guard isOwner else { return }
        engineChoice.picks[p] = pick
    }

    /// Swap, Recast: the owner's model on the shot request.
    func applyEnginePick(_ r: inout ShotRequest, _ p: EnginePurpose) {
        guard let pick = enginePick(p) else { return }
        r.engineModel = pick.model
        r.resolution = pick.resolution
    }

    /// Extend: the owner's model on its request.
    func withExtendPick(_ r: ShotRequest) -> ShotRequest {
        var x = r
        applyEnginePick(&x, .extend)
        return x
    }

    /// Settings → Default models: sets or clears one purpose's default (owner).
    func setEngineDefault(_ p: EnginePurpose, model: String?) {
        guard let api = engineChoiceAPI else { return }
        Task {
            do {
                engineChoice.defaults = try await api.setEngineDefault(p, model: model)
                await loadEngines(force: true)
                showToast(model == nil ? "\(p.fallbackLabel) back to Auto" : "Default for \(p.fallbackLabel.lowercased()) saved")
            } catch {
                showToast((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)
            }
        }
    }
}
