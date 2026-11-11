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
}
