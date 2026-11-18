import AppKit
import MuseCore
import SwiftUI

// Her world, phase 1 (plans/model-world.md, mockups 2 and 6): the Places tab on her page, the opened place, the Add photo
// menu with each way's price, and the priced Generate sheet (one photo per click, never charged above the button's price).

/// The Places tab: her places as folders on the left, the opened one on the right.
struct PlacesTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    @Binding var openId: String?

    var body: some View {
        let list = store.places(for: model)
        if list.isEmpty {
            PlacesEmpty(model: model) { openId = $0.id }
        } else {
            let open = list.first { $0.id == openId } ?? list[0]
            HStack(alignment: .top, spacing: 0) {
                grid(list, open: open)
                    .frame(width: 460, alignment: .topLeading)
                    .padding(.trailing, Space.s6)
                Rectangle().fill(t.roles.hairline).frame(width: 1)
                PlaceDetail(model: model, place: open)
                    .id(open.id)
                    .padding(.leading, Space.s6)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, Space.s5)
        }
    }

    private func grid(_ list: [SuiteLocation], open: SuiteLocation) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s4), GridItem(.flexible(), spacing: Space.s4)], alignment: .leading, spacing: Space.s4) {
                ForEach(list) { p in
                    Button { openId = p.id } label: { PlaceTile(place: p, selected: p.id == open.id) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(p.name), @\(p.tag), \(ScreenCopy.count(p.images.count, "photo"))")
                }
            }
            Button {
                guard let name = store.askPlaceName() else { return }
                Task { if let l = await store.newPlace(for: model, name: name) { openId = l.id } }
            } label: {
                let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                VStack(spacing: Space.s1) {
                    Label("Add a place", ph: "plus").scaled(t.scale.label, t.roles.ink)
                    Text("Her bedroom, the gym, a park…").scaled(t.scale.caption, t.roles.ink2)
                }
                .frame(maxWidth: .infinity).frame(height: 80)
                .overlay(shape.strokeBorder(t.roles.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A place folder: its cover, name, photo count and @tag.
struct PlaceTile: View {
    @Environment(\.theme) private var t
    var place: SuiteLocation
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let c = place.coverImage {
                MediaFrame(ref: c, ratio: 4.0 / 3.0, selected: selected)
            } else {
                let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                Color.clear.aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .background(shape.fill(t.roles.field))
                    .overlay(Ph("folder-simple", 20).foregroundStyle(t.roles.ink2))
                    .overlay(shape.strokeBorder(t.roles.selection, lineWidth: selected ? 2 : 0).padding(-4))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(place.name).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                    Spacer(minLength: Space.s2)
                    Text("\(place.images.count)").monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
                }
                Text("@\(place.tag)").scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            }
        }
    }
}

/// The opened place: name, @tag, description, photos and Add photo.
struct PlaceDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    var place: SuiteLocation
    @State private var words = ""
    @State private var editingWords = false
    @State private var making: PlacePhotoMode?
    @State private var dropTargeted = false
    /// The photo under the pointer: its Save to Mac button shows (always in review shots).
    @State private var hoveredPhoto: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(place.name).scaled(t.scale.title, t.roles.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s3)
                Button {
                    guard let n = store.askPlaceName("Rename place", initial: place.name) else { return }
                    Task { await store.updatePlace(place, PlacePatch(name: n)) }
                } label: { Label("Rename", ph: "pencil-simple") }
                    .buttonStyle(RButtonStyle(kind: .plain, small: true))
                MoreMenu {
                    Button("Change tag…") { changeTag() }
                    Button("Edit description") { words = place.description; editingWords = true }
                    let others = store.suiteCharacters.filter { $0.id != model.id }
                    if !others.isEmpty {
                        Menu("Copy to another model") {
                            ForEach(others) { m in Button(m.name) { Task { await store.copyPlace(place, to: m) } } }
                        }
                    }
                    Divider()
                    Button("Delete place…", role: .destructive) { Task { _ = await store.deletePlace(place) } }
                }
            }
            HStack(spacing: Space.s3) {
                TagChip(tag: place.tag)
                Text("Type @\(place.tag) in any prompt to film here.").scaled(t.scale.caption, t.roles.ink2)
            }
            .padding(.top, Space.s3)
            description.padding(.top, Space.s4)

            SectionTitle("Photos", top: Space.s6) {
                AddPlacePhotoMenu(place: place) { mode in
                    if let mode { making = mode } else { upload() }
                }
            }
            photos
            Text("Sent as the scene picture when you type @\(place.tag). Her photos always go first; if a model has no room left, the place is described in words instead.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s5)
        }
        .sheet(item: $making) { mode in
            PlacePhotoSheet(place: place, mode: mode) { making = nil }
                .environment(store).environment(\.theme, t)
        }
    }

    @ViewBuilder private var description: some View {
        if editingWords {
            VStack(alignment: .leading, spacing: Space.s2) {
                RTextBox(placeholder: "Corner café with a striped awning, wet cobbles, warm window light", text: $words, lines: 3)
                HStack(spacing: Space.s2) {
                    RButton("Save description", small: true) {
                        editingWords = false
                        Task { await store.updatePlace(place, PlacePatch(description: words)) }
                    }
                    RButton("Cancel", kind: .plain, small: true) { editingWords = false }
                }
            }
        } else if place.description.isEmpty {
            Button { words = ""; editingWords = true } label: {
                Text("Add a description · it is sent in words when a model has no room for the photo").scaled(t.scale.body, t.roles.link)
            }
            .buttonStyle(.plain)
        } else {
            Text(place.description).scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) { words = place.description; editingWords = true }
                .help("Double-click to edit")
        }
    }

    private var photos: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s4), count: 3), alignment: .leading, spacing: Space.s4) {
            ForEach(Array(place.images.enumerated()), id: \.offset) { i, img in
                VStack(alignment: .leading, spacing: Space.s2) {
                    MediaFrame(ref: img.image, ratio: 4.0 / 3.0) {
                        if i == place.cover { StateTag("Cover", .onMedia) }
                    }
                    // Save to Mac (ci_2cc7832459f5): on the photo while the pointer is over it, and in its menu.
                    .overlay(alignment: .bottomTrailing) {
                        if hoveredPhoto == i || SnapshotRunner.dir != nil {
                            OutfitTileButton(icon: "download-simple", title: "Save to Mac") { store.savePlacePhoto(place, index: i) }
                                .help("Save this photo to Downloads › MUSE")
                                .padding(Space.s2)
                        }
                    }
                    Text(img.source.caption).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                }
                .onHover { hoveredPhoto = $0 ? i : (hoveredPhoto == i ? nil : hoveredPhoto) }
                .contextMenu {
                    Button("Save to Mac") { store.savePlacePhoto(place, index: i) }
                    if i != place.cover { Button("Make cover") { Task { await store.updatePlace(place, PlacePatch(cover: i)) } } }
                    Divider()
                    Button("Remove photo", role: .destructive) { Task { await store.removePlacePhoto(place, index: i) } }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(img.source.caption)\(i == place.cover ? ", cover" : "")")
                .accessibilityAction(named: Text("Save to Mac")) { store.savePlacePhoto(place, index: i) }
                .accessibilityAction(named: Text("Make cover")) { Task { await store.updatePlace(place, PlacePatch(cover: i)) } }
                .accessibilityAction(named: Text("Remove photo")) { Task { await store.removePlacePhoto(place, index: i) } }
            }
            if place.images.count < Places.maxImages {
                Button(action: upload) {
                    let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                    Color.clear.aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .background(shape.fill(t.roles.field))
                        .overlay(shape.strokeBorder(dropTargeted ? t.roles.selection : t.roles.hairline,
                                                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [] : [5, 4])))
                        .overlay(Text(dropTargeted ? "Drop to add" : "Upload or drop photos").scaled(t.scale.caption, t.roles.ink2))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .help("Upload photos of \(place.name)")
                .accessibilityLabel("Upload photos of \(place.name)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.uploadPlacePhotos(place, urls: urls.filter(MediaImport.isImage)) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func upload() {
        let urls = MediaImport.pick(MediaImport.imageTypes, multiple: true, prompt: "Add photos")
        guard !urls.isEmpty else { return }
        Task { await store.uploadPlacePhotos(place, urls: urls) }
    }

    private func changeTag() {
        let alert = NSAlert()
        alert.messageText = "Change tag"
        alert.informativeText = "Letters, digits, - or _. Prompts with the old tag won't find this place any more."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = place.tag
        alert.accessoryView = field
        alert.addButton(withTitle: "Save tag")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let tag = Places.cleanTag(field.stringValue) else {
            store.showToast("A tag is 1–30 letters, digits, - or _")
            return
        }
        Task { await store.updatePlace(place, PlacePatch(tag: tag)) }
    }
}

/// "@cafe": the tag as the prompt shows it.
struct TagChip: View {
    @Environment(\.theme) private var t
    var tag: String

    var body: some View {
        Text("@\(tag)").scaled(t.scale.label, t.roles.ink).lineLimit(1)
            .padding(.horizontal, Space.s2).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
            .fixedSize()
            .textSelection(.enabled)
            .accessibilityLabel("Tag @\(tag)")
    }
}

/// Add photo: Upload (free), then the three ways to make one, each with its price (mockup 2). nil = Upload.
struct AddPlacePhotoMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var place: SuiteLocation
    var pick: (PlacePhotoMode?) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Label("Add photo", ph: "plus") }
            .buttonStyle(RButtonStyle(kind: .quiet, small: true, off: place.images.count >= Places.maxImages))
            .disabled(place.images.count >= Places.maxImages)
            .help(place.images.count >= Places.maxImages ? "A place keeps up to \(Places.maxImages) photos" : "Add a photo")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AddPlacePhotoList(place: place) { m in
                    open = false
                    pick(m)
                }
                .environment(store).environment(\.theme, t)
            }
    }
}

/// The Add photo menu's rows (also drawn inline for the review screenshots).
struct AddPlacePhotoList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var place: SuiteLocation
    var pick: (PlacePhotoMode?) -> Void
    @State private var prices: [PlacePhotoMode: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(icon: "upload-simple", title: "Upload photos", line: "From your Mac", price: "Free") { pick(nil) }
            Rectangle().fill(t.roles.hairline).frame(height: 1).padding(.vertical, Space.s2)
            Text("Generate one").scaled(t.scale.caption, t.roles.ink2).padding(.horizontal, Space.s3).padding(.bottom, Space.s1)
            ForEach(PlacePhotoMode.allCases, id: \.self) { m in
                let noPhotos = m == .random && place.images.isEmpty
                row(icon: m == .random ? "shuffle" : m == .description ? "text-aa" : "image", title: m.title,
                    line: noPhotos ? "Add a photo first" : m.line, price: prices[m].map(Places.money) ?? "…", off: noPhotos) { pick(m) }
            }
            Text("You see the price and approve before anything is made.").scaled(t.scale.caption, t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.s3).padding(.top, Space.s3)
        }
        .padding(Space.s2)
        .frame(width: 360)
        .task(id: place.id) {
            for m in PlacePhotoMode.allCases where !(m == .random && place.images.isEmpty) {
                if let e = await store.placePhotoPrice(place, PlacePhotoRequest(mode: m)) { prices[m] = e.estimate }
            }
        }
    }

    private func row(icon: String, title: String, line: String, price: String, off: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Ph(icon, 15).foregroundStyle(t.roles.ink).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                    Text(line).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                }
                Spacer(minLength: Space.s3)
                Text(price).monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
            }
            .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
            .contentShape(Rectangle())
            .opacity(off ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(off)
    }
}

/// One photo, priced first: the Generate button carries the price, and the photo is made only when it's pressed.
struct PlacePhotoSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var place: SuiteLocation
    var mode: PlacePhotoMode
    var done: () -> Void
    @State private var words = ""
    @State private var reference: ImageRef?
    @State private var estimate: PlacePhotoEstimate?
    @State private var priceFailed = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(mode.title).scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
                Text(place.name).scaled(t.scale.caption, t.roles.ink2)
            }
            switch mode {
            case .random:
                Text("Another view of \(place.name) from its photos, in the same light. No people.").scaled(t.scale.body, t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            case .description:
                RField("What it looks like") {
                    RTextBox(placeholder: "The counter from inside, morning", text: $words, lines: 3)
                }
            case .reference:
                HStack(spacing: Space.s4) {
                    MediaFrame(ref: reference, ratio: 4.0 / 3.0, symbol: "image").frame(width: 160)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("A photo you like, rebuilt as this place. People in it are removed.").scaled(t.scale.caption, t.roles.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        RButton(reference == nil ? "Choose picture" : "Choose another", small: true) {
                            Task { if let r = await store.pickPlaceReference() { reference = r } }
                        }
                    }
                }
            }
            if priceFailed {
                InlineNotice("Couldn't get the price · try again", tone: .caution, actionTitle: "Try again") { Task { await price() } }
            }
            HStack(spacing: Space.s2) {
                Spacer()
                RButton("Cancel", kind: .plain) { done() }.keyboardShortcut(.cancelAction)
                RButton(busy ? "Making…" : estimate?.buttonLabel ?? "Generate", kind: .action, off: !ready) { Task { await make() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(Space.s5)
        .frame(width: 440)
        .onAppear { words = place.description }
        .task { await price() }
    }

    private var ready: Bool {
        guard !busy, estimate != nil else { return false }
        switch mode {
        case .random: return true
        case .description: return !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .reference: return reference != nil
        }
    }

    private func request(maxUsd: Double? = nil) -> PlacePhotoRequest {
        let w = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlacePhotoRequest(mode: mode, description: mode == .description && !w.isEmpty ? w : nil, reference: mode == .reference ? reference : nil, maxUsd: maxUsd)
    }

    private func price() async {
        priceFailed = false
        estimate = await store.placePhotoPrice(place, request())
        priceFailed = estimate == nil
    }

    private func make() async {
        guard let e = estimate else { return }
        busy = true
        defer { busy = false }
        // The price on the button is the most it can cost (the server refuses a higher one with the new price).
        if await store.makePlacePhoto(place, request(maxUsd: e.estimate)) { done() } else { await price() }
    }
}

/// An empty Places tab (mockup 6): what places are, one action, and quick starts.
struct PlacesEmpty: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    var opened: (SuiteLocation) -> Void

    var body: some View {
        WorldEmpty(icon: "map-pin", title: "No places yet",
                   message: "Add her apartment, gym, a café… A few photos of each keep the background the same in every video.") {
            RButton("Add a place", kind: .action) {
                guard let name = store.askPlaceName() else { return }
                Task { if let l = await store.newPlace(for: model, name: name) { opened(l) } }
            }
            HStack(spacing: Space.s2) {
                ForEach(Places.starters, id: \.self) { n in
                    ChoiceChip(n) { Task { if let l = await store.newPlace(for: model, name: n) { opened(l) } } }
                }
            }
            .padding(.top, Space.s2)
        }
    }
}

/// The People and Pets tabs until they arrive (mockup 6): what they will hold. No button that does nothing.
struct WorldEmpty<Actions: View>: View {
    @Environment(\.theme) private var t
    var icon: String
    var title: String
    var message: String
    @ViewBuilder var actions: () -> Actions

    init(icon: String, title: String, message: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: Space.s3) {
            Ph(icon, 22).foregroundStyle(t.roles.ink2)
            Text(title).scaled(t.scale.heading, t.roles.ink)
            Text(message).scaled(t.scale.body, t.roles.ink2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 380)
            actions().padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s7 * 2)
    }
}

extension WorldEmpty where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
