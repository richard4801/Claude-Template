import MuseCore
import SwiftUI

// AI suite · the Photo tool's composer pieces (workstream 3, plans/video-composer.md "Photo tool"; plans/design-direction.md):
// the slot row (Character, Outfit, Product, References, each with its own sentence-case label), the references panel
// (Photoshoot's reference UI: up to 3, each guiding the pose, the look or the scene) and the Photo preset row (the photo
// templates). The bottom bar's Photos pill and Generate live in ComposerBottomBar (workstream 1's file). Tokens only, one
// selection mark (accent), no filled buttons here: Generate is the one primary action.

/// Character, Outfit, Product (optional) and References (optional).
struct PhotoSlotRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var size: CGFloat = 96

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column("Character") { PhotoCharacterCard(size: size) }
            column("Outfit") { PhotoOutfitCard(size: size) }
            column("Product", optional: true) { productCard }
            column("References", optional: true) { PhotoReferencesCard(size: size) }
        }
    }

    private func column<C: View>(_ label: String, optional: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(t.body(13, .medium)).foregroundStyle(t.ink).lineLimit(1).minimumScaleFactor(0.85)
            content().frame(width: size, height: size)
            Text(optional ? "Optional" : " ").font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
                .accessibilityHidden(!optional)
        }
        .frame(width: size, alignment: .leading)
    }

    /// The composer's image slot is the product photo (as in UGC ad).
    @ViewBuilder private var productCard: some View {
        let model = store.suite.composerSlots
        let id = SlotId(.image)
        if let v = model.slots[id] {
            InputSlotTile(id: id, value: v, compact: true) { model.pick(id, api: store.api) } onClear: { model.clear(id) }
        } else {
            PhotoAddCard(help: "Add a product photo") { model.pick(id, api: store.api) }
        }
    }
}

/// An empty slot: a field-toned square with a plus. The label sits above it.
struct PhotoAddCard: View {
    @Environment(\.theme) private var t
    var help: String
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 16))
                .foregroundStyle(disabled ? t.muted.opacity(0.5) : t.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(t.surface2)
                .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A filled slot: the picture, one caption on a scrim, and a small remove button.
private struct PhotoFilledCard: View {
    @Environment(\.theme) private var t
    var image: ImageRef?
    var caption: String
    var removeLabel: String?
    var onTap: () -> Void
    var onRemove: () -> Void = {}

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Button(action: onTap) {
                MuseImage(ref: image, symbol: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).clipped().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(caption), change")
            LinearGradient(colors: [.clear, Color.black.opacity(0.6)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
            Text(caption).font(t.body(12, .medium)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 8).padding(.bottom, 6).allowsHitTesting(false)
            if let removeLabel {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Color.black.opacity(0.55)))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(removeLabel)
                .accessibilityLabel(removeLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
    }
}

/// Character: the studio's real characters.
struct PhotoCharacterCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var size: CGFloat
    @State private var open = false

    var body: some View {
        Group {
            if let m = store.composerCharacter {
                PhotoFilledCard(image: m.cover, caption: m.shortName, removeLabel: "Remove \(m.shortName)") { open = true } onRemove: {
                    store.setComposerCharacter(nil)
                }
            } else {
                PhotoAddCard(help: "Pick a character") { open = true }
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PhotoCastList(onPick: { open = false }).environment(store).environment(\.theme, t)
        }
    }
}

private struct PhotoCastList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your cast").font(t.body(13, .medium)).foregroundStyle(t.muted).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            if store.suiteCharacters.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make a model with a character sheet to cast her.").font(t.body(13)).foregroundStyle(t.muted)
                    LinkText("New model", size: 13) {
                        onPick()
                        store.go(.create)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            ForEach(store.suiteCharacters) { m in
                let on = m.id == store.composerCharacter?.id
                Button {
                    store.setComposerCharacter(m)
                    onPick()
                } label: {
                    HStack(spacing: 10) {
                        MuseImage(ref: m.cover).frame(width: 32, height: 40).clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                        Text(m.name).font(t.body(14, on ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.accent) }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.name)\(on ? ", selected" : "")")
            }
        }
        .padding(.bottom, 8)
        .frame(width: 280, alignment: .leading)
        .foregroundStyle(t.ink)
    }
}

/// Outfit: her ready outfits; waits for a character.
struct PhotoOutfitCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var size: CGFloat
    @State private var open = false

    var body: some View {
        let m = store.composerCharacter
        let outfits = store.outfits(for: m)
        let current = outfits.first { $0.id == (store.suite.composer.tokens.outfitId ?? store.suite.composer.outfitId) } ?? outfits.first
        Group {
            if m == nil {
                PhotoAddCard(help: "Pick a character first", disabled: true) {}
            } else if let o = current {
                PhotoFilledCard(image: o.angles.compactMap { $0 }.first, caption: o.name, removeLabel: nil) { open = true }
            } else {
                PhotoAddCard(help: "Make an outfit set") { store.openOutfitSheet(for: m?.id) }
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Outfits").font(t.body(13, .medium)).foregroundStyle(t.muted).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                ForEach(outfits) { o in
                    let on = o.id == current?.id
                    Button {
                        store.suite.composer.outfitId = o.id
                        open = false
                    } label: {
                        HStack(spacing: 10) {
                            MuseImage(ref: o.angles.compactMap { $0 }.first).frame(width: 32, height: 40).clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                            Text(o.name).font(t.body(14, on ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 0)
                            if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.accent) }
                        }
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(o.name)\(on ? ", selected" : "")")
                }
                LinkText("New outfit set", size: 13) {
                    open = false
                    store.openOutfitSheet(for: m?.id)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(width: 260, alignment: .leading)
            .foregroundStyle(t.ink)
            .environment(\.theme, t)
        }
    }
}

/// References: the first one's picture and "2 of 3"; opens the references panel.
struct PhotoReferencesCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var size: CGFloat
    @State private var open = false

    var body: some View {
        let refs = store.suite.photo.references
        Group {
            if let first = refs.first {
                PhotoFilledCard(image: first.image, caption: "\(refs.count) of \(ShootRef.max)", removeLabel: nil) { open = true }
            } else {
                PhotoAddCard(help: "Add reference photos") { open = true }
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PhotoReferencesPanel().environment(store).environment(\.theme, t)
        }
    }
}

/// Up to 3 reference images that guide the pose, the look or the scene (Photoshoot's references, on the composer).
struct PhotoReferencesPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var targeted = false

    var body: some View {
        let refs = store.suite.photo.references
        let feature = store.photoRefsFeature
        VStack(alignment: .leading, spacing: 12) {
            Text("References").font(t.body(16, .semibold))
            Text("Up to \(ShootRef.max) photos to copy a pose, a look or a place. Her face, body, hair and outfit always come from her own references.")
                .font(t.body(13)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    VStack(alignment: .leading, spacing: 8) {
                        PhotoFilledCard(image: ref.image, caption: "Reference \(i + 1)", removeLabel: "Remove reference \(i + 1)") {} onRemove: {
                            store.removePhotoRef(i)
                        }
                        .frame(width: 96, height: 128)
                        ForEach(ShootGuide.allCases, id: \.self) { g in
                            Toggle(feature.label(g), isOn: Binding(get: { ref.guides.contains(g) }, set: { _ in store.togglePhotoRefGuide(i, g) }))
                                .toggleStyle(.checkbox)
                                .font(t.body(13))
                        }
                    }
                    .frame(width: 96, alignment: .leading)
                }
                ForEach(0..<store.suite.photoRefsUploading, id: \.self) { _ in
                    // Loading: a skeleton the shape of the picture it becomes.
                    RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2).frame(width: 96, height: 128)
                        .accessibilityLabel("Uploading a reference")
                }
                if !store.photoRefsFull {
                    PhotoAddCard(help: "Add a reference, or drop photos here") { store.pickPhotoRefs() }
                        .frame(width: 96, height: 128)
                        .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(targeted ? t.accent : .clear, lineWidth: 2))
                }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .foregroundStyle(t.ink)
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter(MediaImport.isImage)
            guard !images.isEmpty, !store.photoRefsFull else { return false }
            store.addPhotoRefs(images)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// "Start from a preset" for Photo: the photo templates (GET /v1/templates). Choosing one sends `presetId`; choosing it
/// again goes back to the chips.
struct PhotoPresetsRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let list = store.templates
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Start from a preset").font(t.body(16, .semibold)).foregroundStyle(t.ink)
                Spacer(minLength: 8)
                LinkText("All templates", size: 13) { store.openTemplates() }
            }
            if list.isEmpty {
                Text("No photo presets yet. Save a photo as a template and it shows up here.").font(t.body(13)).foregroundStyle(t.muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(list) { tpl in PhotoPresetTile(template: tpl, selected: store.suite.photo.presetId == tpl.id) { store.choosePhotoPreset(tpl) } }
                    }
                    .padding(4)
                }
                .padding(-4)
            }
        }
        .task { if store.templates.isEmpty { await store.loadTemplates() } }
    }
}

/// A preset tile: the template's cover and its name under it. The selected one carries the accent outline.
struct PhotoPresetTile: View {
    @Environment(\.theme) private var t
    var template: MuseTemplate
    var selected: Bool
    var width: CGFloat = 112
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                MuseImage(ref: template.cover, symbol: "photo")
                    .frame(width: width, height: width * 4 / 3).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                    .overlay(RoundedRectangle(cornerRadius: t.imageRadius).strokeBorder(selected ? t.accent : .clear, lineWidth: 2).padding(-3))
                Text(template.name).font(t.body(13, selected ? .semibold : .regular)).foregroundStyle(t.ink).lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Back to your own settings" : "Start from \(template.name)")
        .accessibilityLabel("\(template.name) preset\(selected ? ", selected" : "")")
    }
}
