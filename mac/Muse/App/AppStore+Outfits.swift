import AppKit
import MuseCore
import SwiftUI

/// The outfit page (plans/outfit-head-looks.md §4/§5): folders, the open outfit, rename, delete, missing angles.
extension AppStore {
    /// Her outfits as folders, newest first.
    func outfitFolders(for m: MuseModel) -> [Outfit] { OutfitPages.newestFirst(outfits(for: m)) }

    func outfitPageIndex(for m: MuseModel) -> Int { OutfitPages.clamp(outfitPage[m.id] ?? 0, items: outfitFolders(for: m).count) }

    func stepOutfitPage(_ m: MuseModel, by d: Int) {
        outfitPage[m.id] = OutfitPages.clamp(outfitPageIndex(for: m) + d, items: outfitFolders(for: m).count)
    }

    var openedOutfit: Outfit? { openOutfitId.flatMap { id in outfits.first { $0.id == id } } }

    func openOutfit(_ o: Outfit) {
        openOutfitViewing = nil
        withAnimation(.easeOut(duration: 0.15)) { openOutfitId = o.id }
    }

    func closeOutfit() {
        openOutfitViewing = nil
        withAnimation(.easeOut(duration: 0.15)) { openOutfitId = nil }
    }

    /// The owner or whoever made it may rename or delete it (the server checks too).
    func canChange(_ o: Outfit) -> Bool { isOwner || o.createdBy == nil || o.createdBy == user?.id }

    func renameOutfit(_ o: Outfit, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != o.name else { return }
        guard !name.isEmpty else {
            showToast("Give the outfit a name")
            return
        }
        perform { [self] in
            let u = try await api.renameOutfit(id: o.id, name: String(name.prefix(OutfitNaming.maxLength)))
            LiveEvents.applyOutfit(&outfits, &models, u)
        }
    }

    /// The folder menu's Rename…: a small sheet with the name selected.
    func askRenameOutfit(_ o: Outfit) {
        let alert = NSAlert()
        alert.messageText = "Rename outfit"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: o.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameOutfit(o, to: field.stringValue)
    }

    func deleteOutfit(_ o: Outfit) {
        guard !fillingOutfits.contains(o.id), o.state != "generating" else {
            showToast("This outfit is still being made · delete it when it finishes")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this outfit?"
        alert.informativeText = "Takes and photos already made with it are kept."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in
            try await api.deleteOutfit(id: o.id)
            outfitGone(o.id)
            showToast("Outfit deleted")
        }
    }

    /// Gone (deleted here or by someone else): out of her list and every pick; the page steps back if it emptied.
    func outfitGone(_ id: String) {
        LiveEvents.removeOutfit(&outfits, &models, id: id)
        if openOutfitId == id { closeOutfit() }
        for (k, v) in outfitIdByModel where v == id { outfitIdByModel[k] = nil }
        if suite.composer.outfitId == id { suite.composer.outfitId = nil }
        if suite.swap.outfitId == id { suite.swap.outfitId = nil }
        fillingOutfits.remove(id)
    }

    /// Makes the missing ¾/side/back of a set from its front.
    func fillOutfit(_ o: Outfit) {
        guard o.front != nil else {
            showToast("Its front picture is missing · make a new outfit instead")
            return
        }
        fillingOutfits.insert(o.id)
        perform { [self] in
            do {
                _ = try await api.fillOutfit(id: o.id, imageModel: enginePick(.outfit)?.model)
                balance = try await api.balance()
            } catch {
                fillingOutfits.remove(o.id)
                throw error
            }
        }
    }

    /// The outfit's missing-angle estimate (edits of its front).
    func outfitFillEstimate(_ o: Outfit) -> Double { Double(4 - o.madeAngles) * photoPricing.perEdit }

    /// "Add face close-ups" for an older outfit: its missing faces, from her base faces and its front (3 edits).
    func addOutfitFaces(_ o: Outfit) {
        guard o.front != nil else {
            showToast("Its front picture is missing · make a new outfit instead")
            return
        }
        remake(o, Set((4..<7).filter { OutfitPictures.refs(o)[$0] == nil })) { [self] in
            try await api.addOutfitFaces(id: o.id, imageModel: enginePick(.outfit)?.model)
        }
    }
    func outfitFacesEstimate(_ o: Outfit) -> Double { Double(3 - o.madeFaces) * photoPricing.perEdit }

    /// Redo one of its 7 pictures (0–3 angles, 4–6 faces).
    func redoOutfitPicture(_ o: Outfit, _ k: Int) {
        guard OutfitPictures.keys.indices.contains(k) else { return }
        remake(o, [k]) { [self] in
            try await api.redoOutfit(id: o.id, picture: OutfitPictures.keys[k], imageModel: enginePick(.outfit)?.model)
        }
    }
    /// Move a picture to another of its 7 slots (owner 2026-11-12: "the picture in Side is actually the back"): the two
    /// swap, so nothing is lost. Free; the owner or the outfit's maker (the server checks too).
    func moveOutfitPicture(_ o: Outfit, from: Int, to: Int) {
        let keys = OutfitPictures.keys
        guard from != to, keys.indices.contains(from), keys.indices.contains(to), canChange(o) else { return }
        guard remakingOutfit[o.id] == nil, !fillingOutfits.contains(o.id), o.state != "generating" else {
            showToast("This outfit is still being made")
            return
        }
        perform { [self] in
            let r = try await api.reorderOutfit(id: o.id, moves: [OutfitMove(from: keys[from], to: keys[to])])
            LiveEvents.applyOutfit(&outfits, &models, r.outfit)
        }
    }

    /// One edit; the front is a new shot (its price as one new outfit picture).
    func outfitRedoEstimate(_ k: Int) -> Double { k == 0 ? photoPricing.outfitSet() - 3 * photoPricing.perEdit : photoPricing.perEdit }

    private func remake(_ o: Outfit, _ pictures: Set<Int>, _ call: @escaping () async throws -> OutfitFill) {
        guard remakingOutfit[o.id] == nil, !fillingOutfits.contains(o.id), o.state != "generating" else {
            showToast("This outfit is still being made")
            return
        }
        remakingOutfit[o.id] = pictures
        perform { [self] in
            do {
                _ = try await call()
                balance = try await api.balance()
            } catch {
                remakingOutfit[o.id] = nil
                throw error
            }
        }
    }
}

/// Keep-from-base (plans/outfit-head-looks.md §6): the base set the new outfit starts from, and swapping one angle.
extension AppStore {
    /// The four base images that will be sent (Front, ¾, Side, Back): the set's own, or the angle chosen instead.
    func baseSet(_ d: OutfitDraft) -> [ImageRef?] {
        let m = models.first { $0.id == d.modelId }
        let own: [ImageRef?]
        if let oid = d.baseOutfitId, let o = outfits.first(where: { $0.id == oid }) {
            own = (0..<4).map { o.angles.indices.contains($0) ? o.angles[$0] : nil }
        } else {
            own = OutfitBaseAngles.keys.map { m?.slot($0)?.image }
        }
        return (0..<4).map { d.baseAngles[$0] ?? own[$0] }
    }

    func setBaseSource(_ outfitId: String?) {
        outfitSheet?.baseOutfitId = outfitId
        outfitSheet?.baseAngles = OutfitBaseAngles()
    }

    func swapBaseAngle(_ i: Int, to ref: ImageRef?) { outfitSheet?.baseAngles[i] = ref }

    /// Swap one angle for a photo of her picked from disk.
    func uploadBaseAngle(_ i: Int) {
        guard let url = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use").first else { return }
        perform { [self] in
            let ref = try await uploadImage(url)
            outfitSheet?.baseAngles[i] = ref
        }
    }
}
