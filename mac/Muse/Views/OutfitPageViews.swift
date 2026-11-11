import AppKit
import MuseCore
import SwiftUI

/// Her outfits on the character page (plans/outfit-head-looks.md §4): one folder per outfit (its front, name and date),
/// 8 per page in four columns that fill the width, newest first, and "‹ 1 of 3 ›" under the grid. ← / → turn the page
/// when no text box has the cursor.
struct OutfitFolders: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    @State private var keys: Any?

    var body: some View {
        let all = store.outfitFolders(for: model)
        let page = store.outfitPageIndex(for: model)
        let pages = OutfitPages.count(all.count)
        VStack(alignment: .leading, spacing: Space.s4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s4, alignment: .top), count: 4), alignment: .leading, spacing: Space.s5) {
                ForEach(OutfitPages.slice(all, page: page)) { o in OutfitFolderTile(outfit: o) }
            }
            if pages > 1 {
                HStack(spacing: Space.s3) {
                    Spacer(minLength: 0)
                    RIconButton(systemName: "chevron.left", help: "Previous page (←)") { store.stepOutfitPage(model, by: -1) }
                        .disabled(page == 0)
                        .opacity(page == 0 ? 0.35 : 1)
                    Text(OutfitPages.label(page, items: all.count)).monospacedDigit().scaled(t.scale.label, t.roles.ink)
                        .accessibilityLabel("Page \(OutfitPages.label(page, items: all.count))")
                    RIconButton(systemName: "chevron.right", help: "Next page (→)") { store.stepOutfitPage(model, by: 1) }
                        .disabled(page >= pages - 1)
                        .opacity(page >= pages - 1 ? 0.35 : 1)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { listen() }
        .onDisappear { stopListening() }
    }

    /// ← / → page through the folders; never while typing, or while an outfit, the new-outfit sheet or a viewer is open.
    private func listen() {
        stopListening()
        let id = model.id
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] e in
            let key = e.keyCode, plain = e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            guard key == 123 || key == 124, plain else { return e }
            let used = MainActor.assumeIsolated { Self.page(store, modelId: id, back: key == 123) }
            return used ? nil : e
        }
    }

    @MainActor private static func page(_ store: AppStore, modelId id: String, back: Bool) -> Bool {
        guard !TextInputFocus.isTyping, store.openOutfitId == nil, store.outfitSheet == nil, store.profileModelId == id,
              let m = store.models.first(where: { $0.id == id }), OutfitPages.count(store.outfitFolders(for: m).count) > 1 else { return false }
        store.stepOutfitPage(m, by: back ? -1 : 1)
        return true
    }

    private func stopListening() {
        if let k = keys { NSEvent.removeMonitor(k) }
        keys = nil
    }
}

/// One outfit folder: the front only, its name and date (same-named outfits stay apart). Click opens it; right-click
/// renames or deletes.
struct OutfitFolderTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var outfit: Outfit

    var body: some View {
        let o = outfit
        Button { store.openOutfit(o) } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                MediaFrame(ref: o.front, ratio: 0.75) {
                    if store.fillingOutfits.contains(o.id) {
                        StateTag("Making angles", .onMedia)
                    } else if o.madeAngles < 4 {
                        StateTag("\(o.madeAngles) of 4 angles", .onMedia)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.name).scaled(t.scale.label, t.roles.ink).lineLimit(1).truncationMode(.tail)
                    if let d = OutfitNaming.folderDate(o.createdAt) { Text(d).scaled(t.scale.caption, t.roles.ink2) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(o.name)")
        .accessibilityLabel(o.name)
        .contextMenu {
            Button("Open") { store.openOutfit(o) }
            Button("Use in Photo") { store.openPhoto(model: o.modelId, outfit: o.id) }
            if store.canChange(o) {
                Button("Rename…") { store.askRenameOutfit(o) }
                Divider()
                Button("Delete…", role: .destructive) { store.deleteOutfit(o) }
            }
        }
    }
}

/// An outfit open: its four angles large and its actions. Click the name to rename it (Enter saves, Escape cancels);
/// click an angle to view it full size and slide between the angles. Close returns to the same page of folders.
struct OutfitOpenView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var editing = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    static let labels = ["Front", "¾", "Side", "Back"]
    static let viewerLabels = ["Front", "Three-quarter", "Side", "Back"]

    var body: some View {
        if let o = store.openedOutfit {
            let model = store.models.first { $0.id == o.modelId }
            let filling = store.fillingOutfits.contains(o.id)
            let items = Self.items(o)
            ZStack {
                Color.black.opacity(0.38).onTapGesture { store.closeOutfit() }
                VStack(alignment: .leading, spacing: Space.s5) {
                    HStack(alignment: .top, spacing: Space.s3) {
                        VStack(alignment: .leading, spacing: 2) {
                            title(o)
                            Text(subtitle(o, model)).scaled(t.scale.caption, t.roles.ink2)
                        }
                        Spacer(minLength: Space.s3)
                        RIconButton(systemName: "xmark", help: "Close (Esc)") { store.closeOutfit() }
                            .keyboardShortcut(store.openOutfitViewing == nil && !editing ? .cancelAction : nil)
                    }
                    HStack(alignment: .top, spacing: Space.s4) {
                        ForEach(0..<4, id: \.self) { i in
                            VStack(alignment: .leading, spacing: Space.s2) {
                                angle(o, i, items: items, filling: filling)
                                Text(Self.labels[i]).scaled(t.scale.caption, t.roles.ink2)
                            }
                        }
                    }
                    if let faces = o.faces, faces.contains(where: { $0 != nil }) {
                        HStack(spacing: Space.s2) {
                            ForEach(0..<faces.count, id: \.self) { i in MediaFrame(ref: faces[i], ratio: 0.75) }
                        }
                        .frame(maxWidth: 260)
                    }
                    if o.madeAngles < 4 && !filling && o.front != nil && store.canChange(o) {
                        InlineNotice("\(o.madeAngles) of 4 angles. The others came back empty.", tone: .caution,
                                     actionTitle: "Make missing angles · \(Pricing.money(store.outfitFillEstimate(o)))") { store.fillOutfit(o) }
                    } else if filling {
                        InlineNotice("Making the missing angles from the front.")
                    }
                    HStack(spacing: Space.s3) {
                        if store.canChange(o) {
                            RButton("Delete…", kind: .danger, off: filling) { store.deleteOutfit(o) }
                        }
                        Spacer(minLength: Space.s3)
                        if let m = model, store.toolsFeatures?.dressUp.available ?? false {
                            RButton("Dress up") {
                                store.closeOutfit()
                                store.openDressUp(m)
                            }
                        }
                        RButton("Use in Photo", kind: .action) {
                            store.closeOutfit()
                            store.openPhoto(model: o.modelId, outfit: o.id)
                        }
                        .keyboardShortcut(store.openOutfitViewing == nil && !editing ? .defaultAction : nil)
                    }
                }
                .padding(Space.s6)
                .floatingPanel(width: 880)
                ImageLightbox(items: items, index: Binding(get: { store.openOutfitViewing }, set: { store.openOutfitViewing = $0 }))
            }
            .onChange(of: o.id) { _, _ in editing = false }
        }
    }

    @ViewBuilder private func title(_ o: Outfit) -> some View {
        if editing {
            TextField("Outfit name", text: $name)
                .textFieldStyle(.plain)
                .typeStep(t.scale.title)
                .focused($nameFocused)
                .roleField(focused: nameFocused)
                .frame(maxWidth: 420)
                .onAppear { nameFocused = true }
                .onSubmit {
                    store.renameOutfit(o, to: name)
                    editing = false
                }
                .onExitCommand { editing = false }
                .onChange(of: name) { _, v in if v.count > OutfitNaming.maxLength { name = String(v.prefix(OutfitNaming.maxLength)) } }
        } else if store.canChange(o) {
            Button {
                name = o.name
                editing = true
            } label: {
                Text(o.name).scaled(t.scale.title, t.roles.ink).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Rename")
            .accessibilityLabel("\(o.name), rename")
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(o.name).scaled(t.scale.title, t.roles.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }

    private func subtitle(_ o: Outfit, _ m: MuseModel?) -> String {
        let who = m.map { "For \($0.shortName)" } ?? "Outfit"
        guard let d = OutfitNaming.folderDate(o.createdAt) else { return who }
        return "\(who), made \(d)"
    }

    @ViewBuilder private func angle(_ o: Outfit, _ i: Int, items: [LightboxItem], filling: Bool) -> some View {
        let ref = o.angles.indices.contains(i) ? o.angles[i] : nil
        if let ref, let at = items.firstIndex(where: { $0.ref == ref && $0.label == Self.viewerLabels[i] }) {
            Button { withAnimation(.easeOut(duration: 0.15)) { store.openOutfitViewing = at } } label: {
                MediaFrame(ref: ref, ratio: 0.75)
            }
            .buttonStyle(.plain)
            .help("View \(Self.viewerLabels[i].lowercased()) full size")
            .accessibilityLabel("View \(Self.viewerLabels[i].lowercased()) full size")
        } else if filling {
            SkeletonBlock(ratio: 0.75, radius: t.radii.container)
        } else {
            Color.clear.aspectRatio(0.75, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.field))
                .accessibilityLabel("\(Self.viewerLabels[i]) missing")
        }
    }

    /// The angles that have a picture, in order, for the full-size viewer ("Front  1 of 4").
    static func items(_ o: Outfit) -> [LightboxItem] {
        (0..<4).compactMap { i in
            guard o.angles.indices.contains(i), let r = o.angles[i] else { return nil }
            return LightboxItem(label: viewerLabels[i], ref: r)
        }
    }
}
