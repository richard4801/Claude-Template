import MuseCore
import SwiftUI

// The cinematic Suite's server pieces (build step 2, plans/api.md "The new Suite's server pieces"): Reuse settings from a
// take's draft, saved rigs, and a model's default rig when it is @-mentioned.
extension AppStore {
    // MARK: Reuse settings

    /// The take's composer comes back exactly (prompt with its chips, rig, bar values). Slots are not restored.
    func reuseSettings(_ take: Take, vary: Bool = false) {
        guard let d = take.draft else {
            showToast("This take was made before Reuse settings")
            return
        }
        let restored = ComposerDrafts.restore(d, into: suite.composer)
        if restored.tool == .photo {
            if let n = d.count { suite.photo.count = n }
            if case .string(let p)? = d.extra["presetId"] { suite.photo.presetId = p }
        }
        if restored.tool != suite.composer.tool { openTool(restored.tool) }
        suite.composer = restored
        showToast(vary ? "Ready for a variation: press Generate" : "Settings from \(take.displayLabel) are back")
    }

    // MARK: Saved rigs

    func loadSavedRigs() async {
        if let r = try? await api.suiteRigs() { suite.savedRigs = r }
    }

    /// Saves the composer's rig (and its #moves) under a name.
    func saveRig(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let rig = SuiteRig(suite.composer.settings, moves: ComposerDrafts.rigMoves(suite.composer.tokens))
        perform { [self] in
            let saved = try await api.createSuiteRig(name: name, rig: rig)
            suite.savedRigs.insert(saved, at: 0)
            showToast("Saved \(saved.name)")
        }
    }

    /// A saved rig replaces the rig rows; its moves become #chips only while the prompt has none.
    func applySavedRig(_ r: SuiteRigView) {
        let before = suite.composer
        suite.composer.settings = r.rig.settings
        addRigMoves(r.rig.moves)
        showToast("Applied \(r.name)", action: "Undo") { [weak self] in self?.suite.composer = before }
    }

    // MARK: A model's default rig

    /// When exactly one character is @-mentioned and has a default rig: fill only the rows still on Auto, then
    /// "Applied <name>'s rig · Undo". Nothing applies with two characters.
    func applyDefaultRigIfAny() {
        let ids = ComposerDrafts.characterIds(suite.composer.tokens)
        guard ids.count == 1, let m = character(ids[0]), let rig = m.defaultRig, !rig.isEmpty else { return }
        let before = suite.composer
        let (s, filled) = applyDefaultRig(rig, to: suite.composer.settings)
        let hadMoves = !suite.composer.tokens.moves.isEmpty
        if !filled.isEmpty { suite.composer.settings = s }
        if !hadMoves { addRigMoves(rig.moves) }
        guard !filled.isEmpty || (!hadMoves && !(rig.moves ?? []).isEmpty) else { return }
        showToast("Applied \(m.shortName)’s rig", action: "Undo") { [weak self] in self?.suite.composer = before }
    }

    private func addRigMoves(_ moves: [SuiteRigMove]?) {
        guard suite.composer.tool != .photo, suite.composer.tokens.moves.isEmpty, let moves else { return }
        var t = suite.composer.tokens
        for m in moves.prefix(PromptTokens.maxMoves) {
            guard let opt = suite.camera.move(m.id) else { continue }
            t = t.addMove(opt, intensity: Int(((m.intensity ?? 0.5) * 100).rounded()), catalog: suite.camera).0
        }
        suite.composer.tokens = t
    }
}
