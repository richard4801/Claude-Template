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
                    if store.fillingOutfits.contains(o.id) || store.remakingOutfit[o.id] != nil {
                        StateTag("Making pictures", .onMedia)
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

/// An outfit open: its 7 pictures (the four angles, then its three face close-ups with its own hair, make-up and face
/// accessories; plans/outfit-faces.md) and its actions. Click the name to rename it (Enter saves, Escape cancels); click a
/// picture to view it full size and slide between all 7; hover one to Redo it. Close returns to the same page of folders.
struct OutfitOpenView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var editing = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool


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
                    // Body angles, then its face close-ups under the first three columns (grouped by space, no boxes).
                    ForEach([Array(0..<4), Array(4..<7)], id: \.self) { row in
                        HStack(alignment: .top, spacing: Space.s4) {
                            ForEach(row, id: \.self) { k in
                                VStack(alignment: .leading, spacing: Space.s2) {
                                    picture(o, k, items: items, filling: filling)
                                        .dropDestination(for: String.self) { got, _ in dropped(o, on: k, got) }
                                    Text(OutfitPictures.captions[k]).scaled(t.scale.caption, t.roles.ink2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if row.count < 4 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                    }
                    let remaking = store.remakingOutfit[o.id] != nil
                    if o.madeAngles < 4 && !filling && !remaking && o.front != nil && store.canChange(o) {
                        InlineNotice("\(o.madeAngles) of 4 angles. The others came back empty.", tone: .caution,
                                     actionTitle: "Make missing angles · \(Pricing.money(store.outfitFillEstimate(o)))") { store.fillOutfit(o) }
                    } else if filling {
                        InlineNotice("Making the missing angles from the front.")
                    } else if o.madeFaces < 3 && !remaking && o.front != nil {
                        if store.canChange(o) {
                            InlineNotice(o.madeFaces == 0 ? "No face close-ups yet. Shots with this outfit use her base face." : "\(3 - o.madeFaces) of its face close-ups came back empty.",
                                         tone: .caution, actionTitle: "Add face close-ups · \(Pricing.money(store.outfitFacesEstimate(o)))") { store.addOutfitFaces(o) }
                        } else if o.madeFaces == 0 {
                            InlineNotice("No face close-ups yet. Shots with this outfit use her base face.")
                        }
                    }
                    HStack(spacing: Space.s3) {
                        if store.canChange(o) {
                            RButton("Delete…", kind: .danger, off: filling || remaking) { store.deleteOutfit(o) }
                        }
                        Spacer(minLength: Space.s3)
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

    /// One of its 7 pictures (0–3 angles, 4–6 faces): click views it full size; hover (or right-click) to Redo.
    @ViewBuilder private func picture(_ o: Outfit, _ k: Int, items: [LightboxItem], filling: Bool) -> some View {
        let ref = OutfitPictures.refs(o)[k]
        let label = OutfitPictures.viewerLabels[k]
        let busy = store.remakingOutfit[o.id]?.contains(k) == true || (filling && k < 4 && ref == nil)
        if busy {
            SkeletonBlock(ratio: 0.75, radius: t.radii.container)
        } else if let ref, let at = items.firstIndex(where: { $0.ref == ref && $0.label == label }) {
            let free = store.canChange(o) && !filling && store.remakingOutfit[o.id] == nil
            OutfitPictureTile(ref: ref, label: label,
                              redo: free ? "Redo · \(Pricing.money(store.outfitRedoEstimate(k)))" : nil,
                              moves: free ? OutfitPictures.moveTargets(o, from: k).map { OutfitMoveTarget(index: $0.index, title: $0.title) } : [],
                              dragPayload: free ? Self.payload(o.id, k) : nil,
                              onMove: { store.moveOutfitPicture(o, from: k, to: $0) },
                              open: { withAnimation(.easeOut(duration: 0.15)) { store.openOutfitViewing = at } },
                              onRedo: { store.redoOutfitPicture(o, k) })
        } else {
            Color.clear.aspectRatio(0.75, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.field))
                .accessibilityLabel("\(label) missing")
        }
    }

    /// Drag and drop between slots: the dragged picture is "<outfit id>#<slot index>"; dropping it on another slot swaps them.
    static func payload(_ outfitId: String, _ k: Int) -> String { "\(outfitId)#\(k)" }
    private func dropped(_ o: Outfit, on k: Int, _ got: [String]) -> Bool {
        guard let s = got.first, let hash = s.lastIndex(of: "#"), String(s[..<hash]) == o.id,
              let from = Int(s[s.index(after: hash)...]), from != k, store.canChange(o) else { return false }
        store.moveOutfitPicture(o, from: from, to: k)
        return true
    }

    /// The pictures that exist, in order, for the full-size viewer ("Face side  7 of 7").
    static func items(_ o: Outfit) -> [LightboxItem] {
        OutfitPictures.shown(o).map { LightboxItem(label: $0.label, ref: $0.ref) }
    }
}

/// One outfit picture: the image, a Redo button on hover (owner or maker; its price in the tooltip), the same in its menu.
/// A "Move to…" entry: the slot (0–6) and its title ("Swap with Back", "Move to Face side").
struct OutfitMoveTarget: Hashable {
    var index: Int
    var title: String
}

/// One outfit picture: the image, a Redo button on hover (owner or maker; its price in the tooltip), and in its menu Redo
/// and "Move to…" (the other 6 slots). Drag it onto another slot to swap them.
struct OutfitPictureTile: View {
    var ref: ImageRef
    var label: String
    /// "Redo · $0.03", or nil when this person can't change the outfit.
    var redo: String?
    var moves: [OutfitMoveTarget] = []
    /// Set when it may be dragged to another slot.
    var dragPayload: String?
    var onMove: (Int) -> Void = { _ in }
    var open: () -> Void
    var onRedo: () -> Void
    @State private var hover = false

    var body: some View {
        withDrag(Button(action: open) { MediaFrame(ref: ref, ratio: 0.75) }
            .buttonStyle(.plain)
            .help("View \(label.lowercased()) full size")
            .accessibilityLabel("View \(label.lowercased()) full size")
            .overlay(alignment: .topTrailing) {
                if let redo, hover {
                    RIconButton(systemName: "arrow.clockwise", help: redo, action: onRedo).padding(Space.s2)
                }
            }
            .onHover { hover = $0 }
            .contextMenu {
                if let redo { Button(redo, action: onRedo) }
                if !moves.isEmpty {
                    Menu("Move to…") {
                        ForEach(moves, id: \.self) { m in Button(m.title) { onMove(m.index) } }
                    }
                }
            })
    }

    @ViewBuilder private func withDrag<V: View>(_ v: V) -> some View {
        if let dragPayload { v.draggable(dragPayload) { MediaFrame(ref: ref, ratio: 0.75).frame(width: 90) } } else { v }
    }
}
