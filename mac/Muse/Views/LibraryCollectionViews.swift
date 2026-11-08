import MuseCore
import SwiftUI

// Library collections (plans/api.md "Library collections and the Suite queue"): "Save to collection" (pick one, or
// "New collection…") on feed cards, the large viewer, a take's page and Library's selection; a collection filter in
// Library and in the feed; rename and delete only where `canEdit`.

/// The "Save to collection" list for one or more takes: each collection this person can edit with a check when every
/// take is already in it (a click adds or takes them out), then "New collection…".
struct SaveToCollectionPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var takeIds: [String]
    var onDone: () -> Void
    /// The collections the (single) take is in, read when the panel opens.
    @State private var holding: Set<String> = []
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save to collection").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s2)
            let list = store.editableCollections
            if list.isEmpty {
                Text("Group takes and photos for a client, a campaign or a look. The whole studio sees collections.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s4).padding(.bottom, Space.s2)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { c in row(c) }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider().padding(.vertical, Space.s1)
            if naming {
                HStack(spacing: Space.s2) {
                    TextField("Name the collection", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Button("Save", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            } else {
                Button { naming = true } label: {
                    HStack(spacing: Space.s2) {
                        Ph("plus", 14).foregroundStyle(t.roles.ink2)
                        Text("New collection…").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.s4).frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, Space.s2)
        .frame(width: 300, alignment: .leading)
        .foregroundStyle(t.roles.ink)
        .task {
            await store.loadCollections()
            if takeIds.count == 1, let id = takeIds.first { holding = await store.collections(of: id) }
        }
    }

    private func row(_ c: LibraryCollection) -> some View {
        let inIt = takeIds.count == 1 && holding.contains(c.id)
        return Button {
            store.toggleInCollection(c, takeIds: takeIds, inIt: inIt)
            if inIt { holding.remove(c.id) } else { holding.insert(c.id) }
        } label: {
            HStack(spacing: Space.s2) {
                Ph("checkmark", 11).foregroundStyle(t.roles.accent).opacity(inIt ? 1 : 0).frame(width: 14)
                Text(c.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Spacer(minLength: Space.s2)
                Text("\(c.count)").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
            }
            .padding(.horizontal, Space.s4).frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.name)\(inIt ? ", saved here" : "")")
    }

    private func create() {
        store.createCollection(named: name, takeIds: takeIds)
        name = ""
        naming = false
        onDone()
    }
}

/// A "Save to collection" button that opens the panel (a take's page, Library's selection bar, the large viewer).
struct SaveToCollectionButton<Label: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var takeIds: [String]
    @ViewBuilder var label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open = true } label: { label() }
            .buttonStyle(.plain)
            .help("Save to collection")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SaveToCollectionPanel(takeIds: takeIds) { open = false }.environment(store).environment(\.theme, t)
            }
    }
}

/// Library's collection filter ("All takes ▾" or a collection), with Rename and Delete where `canEdit`.
struct LibraryCollectionBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var renaming = false
    @State private var newName = ""
    @State private var askDelete = false

    var body: some View {
        let current = store.library.collections.first { $0.id == store.library.galleryCollection }
        HStack(spacing: Space.s2) {
            FeedScopeMenu(title: "Collection", allLabel: "All takes", options: store.library.collections.map { ($0.id, $0.name) },
                          selected: store.library.galleryCollection) { store.setGalleryCollection($0) }
            if let c = current, c.canEdit {
                Button("Rename") { newName = c.name; renaming = true }
                    .buttonStyle(.plain).font(t.scale.caption.font).foregroundStyle(t.roles.link)
                    .popover(isPresented: $renaming, arrowEdge: .bottom) {
                        HStack(spacing: Space.s2) {
                            TextField("Name the collection", text: $newName).textFieldStyle(.roundedBorder).frame(width: 200)
                                .onSubmit { store.renameCollection(c, to: newName); renaming = false }
                            Button("Save") { store.renameCollection(c, to: newName); renaming = false }
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(Space.s3)
                    }
                Button("Delete") { askDelete = true }
                    .buttonStyle(.plain).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .confirmationDialog("Delete \(c.name)?", isPresented: $askDelete) {
                        Button("Delete collection", role: .destructive) { store.deleteCollection(c) }
                        Button("Keep", role: .cancel) {}
                    } message: {
                        Text("Its takes and photos stay in the library.")
                    }
            }
        }
        .task { await store.loadCollections() }
    }
}
