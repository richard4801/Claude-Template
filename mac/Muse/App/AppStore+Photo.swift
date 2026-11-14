import AppKit
import MuseCore
import SwiftUI

// AI suite · the Photo tool (workstream 3, plans/video-composer.md "Photo tool"). Photoshoot folded into the composer:
// CHARACTER and her outfit, an optional PRODUCT (the composer's image slot, as in UGC ad), up to 3 REFERENCES (pose, look,
// scene), the Style / Camera / Look / Lighting chips and a Photos 1–4 count. The price comes from
// POST /v1/suite/photos/estimate; Generate starts /v1/suite/photos as a job (WS19) and the stills land on the stage.
// Old Photoshoot routes (a model's Photo button, a template's Use, a saved outfit, Retake on a still) land here.

extension AppStore {
    // MARK: Routes

    /// Suite → Photo, with a character, her outfit and a preset (a photo template) preselected when given.
    func openPhoto(model: String? = nil, outfit: String? = nil, preset: String? = nil) {
        openTool(.photo)
        if let id = model, let m = character(id) {
            if suite.composer.tokens.characterId != m.id { setComposerCharacter(m) }
            if let o = outfit { suite.composer.outfitId = o }
        }
        if let p = preset { suite.photo.presetId = p }
    }

    /// Switching to Photo: a still has no #moves or tempo, and the video presets' collapsed composer doesn't apply.
    func preparePhoto() {
        let t = suite.composer.tokens
        if !t.moves.isEmpty { suite.composer.tokens = t.withoutMoves }
        suite.composer.settings.tempo = nil
        suite.composer.collapsed = nil
        if templates.isEmpty { Task { await loadTemplates() } }
    }

    // MARK: The request and its price

    /// The PRODUCT slot's photo (the composer's image slot), once uploaded.
    var photoProduct: ImageRef? {
        guard let v = suite.composerSlots.slots[SlotId(.image)], v.ready else { return nil }
        return v.image
    }

    /// What Generate would send now (nil until a character is picked).
    var photoRequest: PhotoRequest? { suite.composer.photoRequest(suite.photo, product: photoProduct) }

    /// The preset the Photo tool starts from.
    var photoPreset: MuseTemplate? { suite.photo.presetId.flatMap { id in templates.first { $0.id == id } } }

    /// Choosing a preset again clears it (back to the chips).
    func choosePhotoPreset(_ t: MuseTemplate) {
        suite.photo.presetId = suite.photo.presetId == t.id ? nil : t.id
    }

    /// The price, the still rig check and the Look (debounced by the composer's `.task(id:)`). Holds nothing.
    func estimatePhoto() async {
        guard var req = photoRequest else {
            suite.photoEstimate = nil
            suite.photoError = nil
            suite.rig = []
            return
        }
        suite.rigDismissals.sync(RigChoices(req))
        if suite.composer.sent != nil { req.draft = ComposerDrafts.draft(suite.composer, photo: suite.photo) } // images sent
        do {
            let e = try await api.suitePhotoEstimate(req)
            guard !Task.isCancelled else { return }
            suite.photoEstimate = e
            suite.photoError = nil
            suite.rig = e.rig
            if !e.aspects.isEmpty { suite.photoAspectsSeen = e.aspects }
            suite.photoModelSeen = e.model?.name
        } catch let e as ApiError {
            guard !Task.isCancelled else { return }
            suite.photoEstimate = nil
            suite.photoError = e.friendlyMessage
            // The warnings still show when the estimate fails: the shot rig check, kept to the still rules.
            let check = ShotRequest(prompt: req.prompt, camera: req.camera)
            suite.rig = PhotoRig.still((try? await api.suiteRigCheck(check)) ?? [])
        } catch {}
    }

    func generatePhoto() {
        guard !suite.generating else { return }
        let uploading = suite.photoRefsUploading > 0 || suite.composerSlots.slots.uploading
        if let need = suite.composer.photoMissing(suite.photo, uploading: uploading) {
            showToast(need)
            return
        }
        guard let req = photoRequest else { return }
        if let p = req.problem {
            showToast(p)
            return
        }
        if let e = suite.photoEstimate, e.estimate > balance.balance {
            notEnough("for these photos")
            return
        }
        suite.generating = true
        perform { [self] in
            defer { suite.generating = false }
            var req = req
            req.draft = ComposerDrafts.draft(suite.composer, photo: suite.photo) // Reuse settings
            // WS19: the run is a job: the stage and the Queue follow it, and the stills land on the stage (and the Library).
            let j = try await api.suiteStartPhotos(req)
            upsert(j)
            suite.photoSessionJobs.insert(j.id) // the Photo stage shows this session's runs only
            rememberStage(j.id, tool: .photo)
            balance = try await api.balance()
            showToast("Making \(PhotoEstimate.photos(max(1, j.request.takes))) · \(Pricing.money(j.cost))", action: "Open queue") { [weak self] in self?.go(.queue) }
        }
    }

    // MARK: References (up to 3)

    var photoRefsFull: Bool { suite.photo.references.count + suite.photoRefsUploading >= ShootRef.max }
    var photoRefsFeature: ShootReferencesFeature { photoPricing.references ?? ShootReferencesFeature() }

    func pickPhotoRefs() {
        let room = ShootRef.max - suite.photo.references.count - suite.photoRefsUploading
        guard room > 0 else {
            showToast("Up to \(ShootRef.max) reference images")
            return
        }
        addPhotoRefs(MediaImport.pick(MediaImport.imageTypes, multiple: room > 1, prompt: "Use as reference"))
    }

    /// From the file picker or a drop. Each one uploads, then joins with the first guide the others don't use yet.
    func addPhotoRefs(_ urls: [URL]) {
        let images = urls.filter(MediaImport.isImage)
        guard !images.isEmpty else {
            if !urls.isEmpty { showToast("That isn't an image") }
            return
        }
        let room = ShootRef.max - suite.photo.references.count - suite.photoRefsUploading
        if images.count > room { showToast("Up to \(ShootRef.max) reference images") }
        for url in images.prefix(max(0, room)) {
            suite.photoRefsUploading += 1
            perform { [self] in
                defer { suite.photoRefsUploading -= 1 }
                let ref = try await uploadImage(url)
                guard suite.photo.references.count < ShootRef.max else { return }
                suite.photo.references.append(ShootRef(image: ref, guides: [ShootRef.defaultGuide(after: suite.photo.references)]))
            }
        }
    }

    func togglePhotoRefGuide(_ index: Int, _ g: ShootGuide) {
        guard suite.photo.references.indices.contains(index) else { return }
        if suite.photo.references[index].guides == [g] {
            showToast("Keep at least one guide on")
            return
        }
        suite.photo.references[index].toggle(g)
    }

    func removePhotoRef(_ index: Int) {
        guard suite.photo.references.indices.contains(index) else { return }
        suite.photo.references.remove(at: index)
    }
}
