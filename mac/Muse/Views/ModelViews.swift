import MuseCore
import SwiftUI

/// One character-sheet slot: image with a yours/AI tag, hover actions, and a drop target for an image file.
struct SheetSlotTile: View {
    @Environment(\.theme) private var t
    var label: String
    var ref: ImageRef?
    var ai = false
    var busy = false
    var primary = "Replace"
    var secondary: String?
    var onPrimary: () -> Void
    var onSecondary: () -> Void = {}
    var onDrop: (URL) -> Void
    var moveTargets: [SheetAngle] = []
    var onMove: (SheetAngle) -> Void = { _ in }
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if busy {
                    Shimmer()
                } else if let ref {
                    Media(ref: ref, ratio: 0.75, symbol: nil, selectedColor: targeted ? t.accent : nil) {
                        Pill(ai ? "AI" : "yours", ai ? .acc : .yours)
                    }
                    .overlay {
                        if hover || targeted {
                            ZStack {
                                Color.black.opacity(0.45)
                                VStack(spacing: 6) {
                                    if targeted {
                                        Text("Drop to replace").font(t.body(12, .semibold)).foregroundStyle(.white)
                                    } else {
                                        HoverChip(primary, action: onPrimary)
                                        if let secondary { HoverChip(secondary, action: onSecondary) }
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                            .transition(.opacity)
                        }
                    }
                    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
                    .contextMenu {
                        Button(primary, action: onPrimary)
                        if let secondary { Button(secondary, action: onSecondary) }
                        if !moveTargets.isEmpty {
                            Menu("Move to") {
                                ForEach(moveTargets) { a in Button(a.label) { onMove(a) } }
                            }
                        }
                    }
                } else {
                    Button(action: onPrimary) { EmptyTile(text: "Add", targeted: targeted) }.buttonStyle(.plain)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                onDrop(u)
                return true
            } isTargeted: { targeted = $0 }
            Text(label).font(t.body(12)).foregroundStyle(t.ink)
        }
    }
}

struct HoverChip: View {
    var text: String
    var action: () -> Void
    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x111111))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }
}

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var newNever = ""
    @State private var addingNever = false
    @State private var sheetTargeted = false

    var body: some View {
        if let m = store.profileModel {
            Page {
                Breadcrumb(parent: "Models", title: m.name) { store.go(.models) }
                HStack(alignment: .top, spacing: 28) {
                    left(m).frame(width: 300)
                    right(m)
                }
            }
        } else {
            Page { Note("No model yet.") }
        }
    }

    private func left(_ m: MuseModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let c = m.cover { Media(ref: c, ratio: 0.75, radius: t.cardRadius) } else { InitialTile(letter: m.initial, size: 120).surface() }
            }
            HStack(spacing: 10) {
                MButton("New video", icon: "video", kind: .primary, fill: true) {
                    store.selectModel(m)
                    store.go(.studio)
                }
                MButton("Shoot", icon: "camera", fill: true) {
                    store.selectModel(m)
                    store.go(.shoot)
                }
                MoreMenu {
                    Button("Edit character sheet") { store.uploadSheet(m) }
                    Button("Identity LoRA") { store.openLora(m.id) }
                    Button("Add outfit") { store.openOutfitSheet(for: m.id) }
                    Button("Enhance character sheet") { store.openEnhance(m) }
                    Button("Dress up") { store.openDressUp(m) }
                    Button("Previous sheet versions") { store.openVersions(m.id) }
                    Button("Duplicate model") { store.duplicate(m) }
                    Button("Share profile card") { store.shareProfileCard(m) }
                    Divider()
                    if store.isOwner { Button("Archive model…") { store.archiveModel(m) } }
                    Button("Delete model…", role: .destructive) { store.deleteModel(m) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Lbl("Niche")
                Text(m.niche.isEmpty ? "—" : m.niche)
                Lbl("Personality")
                Text(m.personality.isEmpty ? "—" : m.personality).fixedSize(horizontal: false, vertical: true)
                Lbl("Notes")
                Text(m.notes.isEmpty ? "—" : m.notes).font(t.body(13)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }

    private func right(_ m: MuseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Model").styled()
            H1(m.name)
            SectionHeader(title: "Character sheet") {
                HStack(spacing: 10) {
                    Muted("Hover a shot to replace it")
                    LinkText("Versions") { store.openVersions(m.id) }
                    MButton("Upload images", icon: "square.and.arrow.up", size: .small) { store.uploadSheet(m) }
                    if store.toolsFeatures?.enhance.available ?? false {
                        MButton("Enhance", icon: "wand.and.stars", size: .small) { store.openEnhance(m) }
                    }
                    if store.toolsFeatures?.dressUp.available ?? false {
                        MButton("Dress up", icon: "tshirt", size: .small) { store.openDressUp(m) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                sheetGroup(m, "Face close-ups", SheetAngle.faceGroup)
                sheetGroup(m, "Full body", SheetAngle.bodyGroup)
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.uploadSheet(m, urls: urls)
                return true
            }
            if !m.hasBothFaces && m.filled > 0 {
                Note(icon: "exclamationmark.shield", warn: true, "No \(m.slot("face")?.image == nil ? "face" : "profile") close-up yet. Faces come out softer without both close-ups.")
                    .padding(.top, 14)
            }

            VStack(alignment: .leading, spacing: 0) {
                ProfileLoraCard(model: m)
                ProfileAccounts(model: m)
            }

            SectionHeader(title: "Outfits") {
                MButton("Add outfit", icon: "plus", size: .small) { store.openOutfitSheet(for: m.id) }
            }
            let fits = store.outfits(for: m)
            if fits.isEmpty {
                Note(icon: "tshirt", "No outfits yet. Describe one, use a product photo, or upload your own four angles.")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(fits) { o in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(o.name).font(t.body(14, .bold))
                            if o.isDressUp { Pill("Dress up") }
                            Spacer()
                            Muted(o.isDressUp ? "body · then faces" : "front · ¾ · side · back")
                        }
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { i in Media(ref: o.angles.indices.contains(i) ? o.angles[i] : nil, ratio: 0.75) }
                        }
                        if let faces = o.faces, faces.contains(where: { $0 != nil }) {
                            HStack(spacing: 8) {
                                ForEach(0..<faces.count, id: \.self) { i in Media(ref: faces[i], ratio: 0.75) }
                                Spacer()
                            }
                            .frame(maxWidth: 220)
                        }
                    }
                    .padding(12)
                    .surface()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Never add") { Muted("Removed from every render automatically") }
            FlowLayout(spacing: 8) {
                ForEach(Array(store.neverList(m).enumerated()), id: \.offset) { i, item in
                    RemovableChip(text: item) { store.removeNever(m, at: i) }
                }
                if addingNever {
                    TextField("e.g. necklaces", text: $newNever)
                        .textFieldStyle(.plain)
                        .font(t.body(13))
                        .frame(width: 140, height: 32)
                        .padding(.horizontal, 12)
                        .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 16).strokeBorder(t.accent, lineWidth: 1))
                        .onSubmit {
                            store.addNever(m, newNever)
                            newNever = ""
                            addingNever = false
                        }
                } else {
                    Chip("Add", icon: "plus") { addingNever = true }
                }
            }
            }
        }
    }
}

extension ProfileView {
    /// One group of the character sheet (face close-ups, or the full body).
    func sheetGroup(_ m: MuseModel, _ title: String, _ angles: [SheetAngle]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Lbl(title)
            // Four columns for both groups, so every tile is the same size.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), alignment: .leading, spacing: 12) {
                ForEach(angles) { a in
                    let s = m.slot(a.rawValue)
                    SheetSlotTile(label: a.label, ref: s?.image, ai: s?.isAI ?? false, busy: s?.busy ?? false, primary: "Replace", secondary: "Retake with AI",
                                  onPrimary: { store.replaceSlot(m, a) }, onSecondary: { store.retakeSlot(m, a) }, onDrop: { store.replaceSlot(m, a, with: $0) })
                }
            }
        }
    }
}

struct CreateModelView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = store
        let c = store.create
        Page {
            Breadcrumb(parent: "Models", title: "New model") { store.cancelCreate() }
            if c.step == 1 {
                PageHeader(eyebrow: "New model", title: "Basics")
                stepper(1)
                VStack(alignment: .leading, spacing: 18) {
                    Field("Name") { TextField("e.g. Noor", text: $store.create.name).fieldChrome() }
                    Field("Age") {
                        HStack(spacing: 12) {
                            NumStepper(value: c.age, dec: { store.create.age = max(18, c.age - 1) }, inc: { store.create.age = min(70, c.age + 1) })
                            Muted("Characters must be clearly adult (18+).")
                        }
                    }
                    Field("Niche") {
                        FlowLayout {
                            ForEach(Niches.all, id: \.self) { n in Chip(n, on: c.niche == n) { store.create.niche = n } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        (Text("PERSONALITY ").font(t.label).foregroundColor(t.muted) + Text("(optional)").font(t.body(12)).foregroundColor(t.muted))
                        TextField("e.g. warm, a little dry, morning-routine energy", text: $store.create.personality).fieldChrome()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        (Text("NOTES ").font(t.label).foregroundColor(t.muted) + Text("(optional)").font(t.body(12)).foregroundColor(t.muted))
                        TextBox(placeholder: "Anything about the look you want kept", text: $store.create.notes, lines: 3)
                    }
                    HStack {
                        MButton("Cancel") { store.cancelCreate() }
                        MButton("Next: character sheet", kind: .primary) { store.createNext() }
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: 640, alignment: .leading)
            } else {
                PageHeader(eyebrow: "New model · \(c.name.isEmpty ? "Untitled" : c.name)", title: "Character sheet") {
                    MButton("Back") { store.createBack() }
                    MButton("Save model", kind: .primary, off: c.busy) { store.createSave() }
                }
                stepper(2)
                Button {
                    store.addDraftImages(MediaImport.pick(MediaImport.imageTypes, multiple: true, prompt: "Add images"))
                } label: {
                    HStack(spacing: 18) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 22)).frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drop your reference images here").font(t.body(14, .bold))
                            Muted("Or click to choose. We sort them into the slots below, and you can move any image to another slot.")
                        }
                        Spacer()
                        Text("Choose files").font(t.body(14, .semibold)).padding(.horizontal, 16).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface))
                            .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                    }
                    .foregroundStyle(t.ink)
                    .padding(26)
                    .background(RoundedRectangle(cornerRadius: t.cardRadius).fill(dropTargeted ? t.accent.opacity(0.08) : t.surface))
                    .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(dropTargeted ? t.accent : t.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    store.addDraftImages(urls)
                    return true
                } isTargeted: { dropTargeted = $0 }

                SectionHeader(title: "\(c.filled)/\(SheetAngle.allCases.count) shots") { Muted("Two face close-ups give the sharpest face") }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), alignment: .leading, spacing: 12) {
                    ForEach(SheetAngle.faceGroup + SheetAngle.bodyGroup) { a in
                        let slot = c.slots[a]
                        SheetSlotTile(label: a.label, ref: ref(slot), ai: isAI(slot), busy: slot == .busy, primary: "Replace", secondary: "Remove",
                                      onPrimary: { store.setDraftSlot(a) }, onSecondary: { store.clearDraftSlot(a) }, onDrop: { store.setDraftSlot(a, $0) },
                                      moveTargets: SheetAngle.allCases.filter { $0 != a }, onMove: { store.moveDraftSlot(a, to: $0) })
                    }
                }
                if c.faces < 2 && c.filled > 0 {
                    Note(icon: "exclamationmark.shield", warn: true,
                         "No \(c.faces > 0 ? "profile" : "face") close-up yet. You can still save, but faces come out softer without both close-ups.")
                        .padding(.top, 16)
                }
                if c.filled > 0 && c.filled < SheetAngle.allCases.count && !c.busy {
                    let missing = SheetAngle.allCases.count - c.filled
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fill missing angles from your images").font(t.body(14, .bold))
                            Muted("Optional. AI makes the \(missing) empty angle\(missing > 1 ? "s" : "") from what you uploaded · \(PhotoPricing.label(store.sheetAnglesEstimate(missing)))")
                        }
                        Spacer()
                        MButton("Fill \(missing)") { store.fillMissing() }
                    }
                    .card()
                    .padding(.top, 16)
                }
            }
        }
    }

    private func ref(_ s: DraftSlot?) -> ImageRef? {
        switch s {
        case .local(let u)?: return ImageRef(url: u.absoluteString)
        case .remote(let r, _)?: return r
        default: return nil
        }
    }

    private func isAI(_ s: DraftSlot?) -> Bool {
        if case .remote(_, let ai)? = s { return ai }
        return false
    }

    private func stepper(_ step: Int) -> some View {
        HStack(spacing: 10) {
            stepDot(1, "Basics", on: step == 1)
            Rectangle().fill(t.line).frame(width: 40, height: 1)
            stepDot(2, "Character sheet", on: step == 2)
        }
        .padding(.bottom, 22)
    }

    private func stepDot(_ n: Int, _ label: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(t.body(12, .semibold)).frame(width: 26, height: 26)
                .background(Circle().fill(on ? t.accent : .clear))
                .overlay(Circle().strokeBorder(on ? t.accent : t.line, lineWidth: t.lineWidth))
                .foregroundStyle(on ? t.accentInk : t.muted)
            Text(label).font(t.body(14, .semibold)).foregroundStyle(on ? t.ink : t.muted)
        }
    }
}
