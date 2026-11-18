import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

// Her world, phase 1 (plans/model-world.md): her places (the Places tab on her page) and the studio's. They share
// `suite.locations` with the composer's @ list, so a place made on her page is in @ at once.
extension AppStore {
    /// Her places, newest first.
    func places(for m: MuseModel) -> [SuiteLocation] { Places.forModel(m.id, suite.locations).hers }
    /// The studio's shared places ("Studio places").
    var studioPlaces: [SuiteLocation] { Places.forModel(nil, suite.locations).studio }

    func reloadPlaces() async {
        if let list = try? await api.suiteLocations() { suite.locations = list }
    }

    private func keep(_ l: SuiteLocation) {
        if let i = suite.locations.firstIndex(where: { $0.id == l.id }) { suite.locations[i] = l } else { suite.locations.insert(l, at: 0) }
    }

    private func placeError(_ e: Error, _ fallback: String) {
        if let e = e as? ApiError {
            showToast(e.code == "tag_taken" || e.code == "place_full" || e.code == "price_changed" || e.code == "needs_a_photo" ? e.message : e.friendlyMessage)
        } else {
            showToast(fallback)
        }
    }

    /// "Add a place": a name (and optional starter words), hers alone. Photos come next, on the place itself.
    func newPlace(for m: MuseModel, name: String) async -> SuiteLocation? {
        guard let clean = ComposerLocations.cleanName(name) else {
            showToast("Give the place a name")
            return nil
        }
        do {
            let l = try await api.createPlace(NewPlace(name: clean, modelId: m.id))
            keep(l)
            return l
        } catch {
            placeError(error, "The place wasn't saved · try again")
            return nil
        }
    }

    /// Asks for a name in a small dialog (Add a place).
    func askPlaceName(_ title: String = "Add a place", initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Her bedroom, the gym, a park… You can add photos next."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Café by the gym"
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: title == "Add a place" ? "Add place" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func updatePlace(_ l: SuiteLocation, _ patch: PlacePatch) async {
        do { keep(try await api.updatePlace(id: l.id, patch)) } catch { placeError(error, "The change wasn't saved · try again") }
    }

    /// Add photo → Upload photos: free. Up to the place's room (8 photos).
    func uploadPlacePhotos(_ l: SuiteLocation, urls: [URL]) async {
        let room = Places.maxImages - l.images.count
        guard room > 0 else {
            showToast("A place keeps up to \(Places.maxImages) photos · remove one first")
            return
        }
        if urls.count > room { showToast("Added the first \(room) · a place keeps up to \(Places.maxImages) photos") }
        var last = l
        for url in urls.prefix(room) {
            guard let data = try? Data(contentsOf: url) else {
                showToast("Couldn't read \(url.lastPathComponent)")
                continue
            }
            if data.count > InputSlots.maxImageBytes {
                showToast("\(url.lastPathComponent) is over \(InputSlots.maxImageBytes / (1024 * 1024)) MB")
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            do {
                let image = try await api.uploadImage(name: url.lastPathComponent, data: data, mime: mime, progress: nil)
                last = try await api.addPlaceImage(id: last.id, image: image)
                keep(last)
            } catch {
                placeError(error, "The photo wasn't added · try again")
                return
            }
        }
    }

    /// Save to Mac (ci_2cc7832459f5): the place photo in original quality to ~/Downloads/MUSE, never over another file,
    /// as Library's Download saves a take. A bundled demo picture is rendered as a PNG.
    func savePlacePhoto(_ l: SuiteLocation, index: Int) {
        guard l.images.indices.contains(index) else { return }
        let ref = l.images[index].image
        let number = index + 1
        func done(_ file: URL?) {
            showToast(file == nil ? "Couldn't save the photo to Downloads" : "Saved to Downloads › MUSE", action: file == nil ? nil : "Show in Finder") {
                if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        if let u = ref.url, let src = URL(string: u), let scheme = src.scheme, ["http", "https", "file"].contains(scheme) {
            let name = SaveFileName.forPlacePhoto(place: l.name, id: l.id, number: number, ext: src.pathExtension)
            perform { [self] in
                done(try await downloadVideo(src, fileName: name, what: "photo"))
            }
            return
        }
        let fm = FileManager.default
        guard let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent("MUSE", isDirectory: true) else { return done(nil) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = SaveFileName.unique(SaveFileName.forPlacePhoto(place: l.name, id: l.id, number: number, ext: "png"), in: dir)
        let size = CGSize(width: 1600, height: 1200)
        let r = ImageRenderer(content: MuseImage(ref: ref).frame(width: size.width, height: size.height))
        r.proposedSize = ProposedViewSize(size)
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
              (try? png.write(to: dst, options: .withoutOverwriting)) != nil else { return done(nil) }
        done(dst)
    }

    func removePlacePhoto(_ l: SuiteLocation, index: Int) async {
        do { keep(try await api.removePlaceImage(id: l.id, index: index)) } catch { placeError(error, "The photo wasn't removed · try again") }
    }

    /// The price first (the Add photo menu and the Generate button); nil when it can't be priced right now.
    func placePhotoPrice(_ l: SuiteLocation, _ req: PlacePhotoRequest) async -> PlacePhotoEstimate? {
        try? await api.placePhotoEstimate(id: l.id, req)
    }

    /// Makes one photo at the price the person pressed (never charged above it). True when it was made.
    func makePlacePhoto(_ l: SuiteLocation, _ req: PlacePhotoRequest) async -> Bool {
        do {
            let r = try await api.makePlacePhoto(id: l.id, req)
            keep(r.place)
            if let w = try? await api.wallet() { wallet = w }
            return true
        } catch {
            placeError(error, "The photo wasn't made · you weren't charged · try again")
            return false
        }
    }

    /// A reference picture for "From a reference picture": picked and uploaded, not added to the place.
    func pickPlaceReference() async -> ImageRef? {
        guard let url = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use picture").first, let data = try? Data(contentsOf: url) else { return nil }
        if data.count > InputSlots.maxImageBytes {
            showToast("That picture is over \(InputSlots.maxImageBytes / (1024 * 1024)) MB")
            return nil
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        do { return try await api.uploadImage(name: url.lastPathComponent, data: data, mime: mime, progress: nil) } catch {
            placeError(error, "The picture wasn't uploaded · try again")
            return nil
        }
    }

    func copyPlace(_ l: SuiteLocation, to m: MuseModel) async {
        do {
            let c = try await api.copyPlace(id: l.id, toModel: m.id)
            keep(c)
            showToast("Copied to \(m.shortName) as @\(c.tag)")
        } catch { placeError(error, "The place wasn't copied · try again") }
    }

    /// "Delete place?" first; the person who added it or the owner.
    func deletePlace(_ l: SuiteLocation) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \(l.name)?"
        alert.informativeText = "Its \(ScreenCopy.count(l.images.count, "photo")) go too. Prompts with @\(l.tag) won't find it any more."
        alert.addButton(withTitle: "Delete place")
        alert.addButton(withTitle: "Keep")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try await api.deleteSuiteLocation(id: l.id)
            suite.locations.removeAll { $0.id == l.id }
            return true
        } catch {
            placeError(error, "The place wasn't deleted · try again")
            return false
        }
    }

    /// "New shot" at a place: the composer with her and @place in the prompt.
    func shootAt(_ l: SuiteLocation, model m: MuseModel) {
        selectModel(m)
        openTool(.shot)
        setComposerCharacter(m)
        suite.composer.tokens = addLocation(l, to: suite.composer.tokens, at: nil)
    }
}
