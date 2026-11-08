import AppKit
import MuseCore
import SwiftUI

/// Recipes (plans/learning-editor-ui.md §2–3, the owner-approved design): every analysed reference and finished edit, so
/// the owner can find what worked. Search, All · References · Your edits, Newest · Most viewed (segmented, no menus), the
/// eight most-used tags, a grid of pictures with captions, and at the bottom the effects MUSE can't make yet. The detail
/// is a right-hand panel when the page is wide enough (a window of about 1180 pt), otherwise it replaces the grid.
struct LearnRecipesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The page width from which the detail sits beside the grid (about a 1180 pt window with the sidebar).
    static let panelFrom: CGFloat = 1000
    static let panelWidth: CGFloat = 380

    var body: some View {
        let l = store.learn
        GeometryReader { g in
            let wide = g.size.width >= Self.panelFrom
            HStack(spacing: 0) {
                if l.selectedId == nil || wide {
                    grid
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if l.selectedId != nil {
                    if wide { SuiteRule(vertical: true) }
                    LearnRecipeDetail(pushed: !wide)
                        .frame(width: wide ? Self.panelWidth : nil)
                        .frame(maxWidth: wide ? nil : .infinity, maxHeight: .infinity)
                        .background(t.roles.raised)
                }
            }
        }
        .background(t.roles.canvas)
        .sheet(isPresented: Binding(get: { store.learn.askDeleteRecipe }, set: { store.learn.askDeleteRecipe = $0 })) {
            LearnConfirm(title: "Delete this recipe?", note: "The reference and the take stay.", action: "Delete recipe",
                         keep: { store.learn.askDeleteRecipe = false }, confirm: { Task { await store.confirmDeleteRecipe() } })
        }
    }

    private var grid: some View {
        let l = store.learn
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Space.s3) {
                    SuiteIconButton(systemName: "caret-left", label: "Back to Edit") { store.closeLearn() }
                    Text("Recipes").scaled(t.scale.display, t.roles.ink).lineLimit(1).fitProbe("recipes title")
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.bottom, Space.s5)
                Group {
                    if let e = l.recipesError, l.recipes == nil {
                        LearnErrorLine(text: e) { Task { await store.loadRecipes() } }
                    } else if l.recipes == nil {
                        filters
                        SkeletonGrid(columns: 4, count: 6).padding(.top, Space.s5).frame(maxWidth: 4 * 196)
                    } else if l.recipes?.isEmpty == true {
                        EmptyState("No recipes yet", "Recreate an edit or finish one in Edit, and it's saved here.",
                                   actionTitle: "Recreate an edit", actionKind: .action) { store.openRecreate() }
                    } else {
                        filters
                        results
                        gaps
                    }
                }
                .padding(.leading, 40)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.s5)
            .padding(.bottom, Space.s7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Filters

    private var filters: some View {
        let l = store.learn
        return VStack(alignment: .leading, spacing: Space.s3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s3) { search.frame(width: 240); originSeg; sortSeg }
                VStack(alignment: .leading, spacing: Space.s3) {
                    search.frame(maxWidth: 360)
                    HStack(spacing: Space.s3) { originSeg; sortSeg }
                }
            }
            let tags = l.topTags
            if !tags.isEmpty {
                FlowLayout(spacing: Space.s2) {
                    ForEach(tags, id: \.self) { tag in LearnTagChip(text: tag, on: l.tag == tag) { store.toggleTag(tag) } }
                }
            }
        }
    }

    private var search: some View {
        HStack(spacing: Space.s2) {
            Ph("magnifying-glass", 13).foregroundStyle(t.roles.ink2)
            TextField("Search recipes", text: Binding(get: { store.learn.query }, set: { store.learn.query = $0 }))
                .textFieldStyle(.plain)
                .font(t.scale.body.font)
                .foregroundStyle(t.roles.ink)
                .accessibilityLabel("Search recipes")
        }
        .padding(.horizontal, Space.s3)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
    }

    private var originSeg: some View {
        RSeg([(LearnOrigin.all, "All"), (.reference, "References"), (.edit, "Your edits")],
             selection: Binding(get: { store.learn.origin }, set: { store.learn.origin = $0 }))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Which recipes")
    }

    private var sortSeg: some View {
        RSeg([(LearnSort.newest, "Newest"), (.mostViewed, "Most viewed")],
             selection: Binding(get: { store.learn.sort }, set: { store.learn.sort = $0 }))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Order")
    }

    // MARK: Grid

    @ViewBuilder private var results: some View {
        let l = store.learn
        let list = l.filtered
        if list.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(noResults).scaled(t.scale.body, t.roles.ink2)
                RButton("Clear filters", kind: .quiet) { store.learn.clearFilters() }
            }
            .padding(.top, Space.s5)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: Space.s4)], alignment: .leading, spacing: Space.s5) {
                ForEach(list) { r in
                    Button { Task { await store.selectRecipe(r.id) } } label: { LearnRecipeTile(recipe: r, selected: l.selectedId == r.id) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(r.name)")
                }
            }
            .padding(.top, Space.s5)
        }
    }

    private var noResults: String {
        let l = store.learn
        let q = l.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return "Nothing matches “\(q)”" }
        if let tag = l.tag { return "Nothing matches “\(tag)”" }
        return "Nothing matches these filters"
    }

    @ViewBuilder private var gaps: some View {
        let list = store.learn.gaps
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text("Effects MUSE can't make yet").scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
                ForEach(list) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LearnText.gap(g)).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                        if let ex = g.examples.first, !ex.note.isEmpty {
                            Text("Latest: \(ex.note)").scaled(t.scale.caption, t.roles.ink2).lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, Space.s6)
        }
    }
}

/// A recipe tile: the picture (9:16, its length and cuts in the corner) and its caption. No box.
struct LearnRecipeTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var recipe: LearnRecipe
    var selected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s2) {
            LearnPictureView(picture: store.learnPicture(recipe))
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let b = LearnText.badge(recipe) {
                        Text(b).monospacedDigit().scaled(t.scale.micro, .white).lineLimit(1).fixedSize()
                            .padding(.horizontal, Space.s2).frame(height: 20)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(Space.s2)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: t.isDark || t.isD ? 0 : 1))
                .overlay(shape.strokeBorder(t.roles.selection, lineWidth: selected ? 2 : 0).padding(-4))
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                let line = LearnText.tileCaption(recipe)
                if !line.isEmpty { Text(line).scaled(t.scale.caption, t.roles.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .contentShape(Rectangle())
    }
}

/// A recipe's picture: the take's thumbnail, the reference's poster (authenticated), a bundled demo still, or `field`
/// with a film-strip icon. Never a sample person.
struct LearnPictureView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var picture: LearnPicture
    @State private var poster: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                switch picture {
                case .take(let ref): MuseImage(ref: ref, symbol: "film")
                case .bundled(let path):
                    if let img = PreviewFiles.image(path) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                case .poster:
                    if let poster { Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill) } else { placeholder }
                case .none: placeholder
                }
            }
            .clipped()
            .task(id: picture) {
                guard case .poster(let link) = picture else { return }
                poster = await RecreateMediaLoader.image(store.recreateMedia(link))
            }
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            t.roles.field
            Ph("film-strip", 20).foregroundStyle(t.roles.ink2)
        }
    }
}

/// A tag chip that filters the grid: toggled by the selection outline and ink text, never a fill colour.
struct LearnTagChip: View {
    @Environment(\.theme) private var t
    var text: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
        Button(action: action) {
            Text(text).font(t.scale.label.font).lineLimit(1).fixedSize().fitProbe("tag \(text)")
                .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                .padding(.horizontal, Space.s3)
                .frame(height: 28)
                .background(shape.fill(t.roles.field))
                .overlay(shape.strokeBorder(t.roles.selection, lineWidth: on ? 1.5 : 0))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "\(text), filtering" : text)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Show every recipe" : "Show recipes tagged \(text)")
    }
}

// MARK: Detail

/// The recipe's detail: name (rename inline), summary and origin; the shape of the edit; the Look; performance for posted
/// edits; tags; the three closest recipes; then "Use in Recreate" or "Open edit", and a quiet "Delete recipe".
struct LearnRecipeDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// Shown in place of the grid (a narrow page): a back button instead of the close button.
    var pushed = false
    @State private var renaming = false
    @State private var name = ""
    @State private var addingTag = false
    @State private var newTag = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var tagFocused: Bool

    var body: some View {
        let l = store.learn
        VStack(spacing: 0) {
            if let d = l.detail {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(d)
                        if let rec = d.recipe {
                            section("Shape of the edit") {
                                VStack(alignment: .leading, spacing: Space.s2) {
                                    LearnShapeStrip(recipe: rec)
                                    let line = LearnText.shape(rec)
                                    if !line.isEmpty { Text(line).monospacedDigit().scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true) }
                                }
                            }
                            look(rec)
                        } else if l.loadingDetail {
                            SkeletonBlock(height: 40).padding(.top, Space.s5)
                        }
                        if let p = d.performance, p.posts > 0 { performance(p) }
                        tags(d)
                        closest
                    }
                    .padding(Space.s5)
                    .frame(maxWidth: pushed ? 640 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SuiteRule()
                footer(d)
            } else {
                Spacer()
            }
        }
        .onChange(of: l.selectedId) { _, _ in
            renaming = false
            addingTag = false
            newTag = ""
        }
    }

    private func header(_ d: LearnRecipe) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .center, spacing: Space.s2) {
                if pushed {
                    SuiteIconButton(systemName: "caret-left", label: "Back to recipes", size: 28) { store.closeRecipe() }
                }
                if renaming {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onExitCommand { renaming = false }
                        .roleField(focused: nameFocused)
                        .accessibilityLabel("Recipe name")
                    RButton("Done", kind: .quiet, small: true) { commitName() }
                } else {
                    Text(d.name).scaled(t.scale.title, t.roles.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Space.s2)
                    SuiteIconButton(systemName: "pencil-simple", label: "Rename recipe", size: 28) {
                        name = d.name
                        renaming = true
                        nameFocused = true
                    }
                }
                if !pushed && !renaming {
                    SuiteIconButton(systemName: "x", label: "Close recipe", size: 28) { store.closeRecipe() }
                }
            }
            if !d.summary.isEmpty {
                Text(d.summary).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
            }
            Text(LearnText.origin(d)).scaled(t.scale.caption, t.roles.ink2)
        }
    }

    private func commitName() {
        renaming = false
        let n = name
        Task { await store.renameRecipe(n) }
    }

    private func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s2)
                if let trailing { Text(trailing).scaled(t.scale.caption, t.roles.ink2).lineLimit(1) }
            }
            content()
        }
        .padding(.top, Space.s5)
    }

    @ViewBuilder private func look(_ rec: Recipe) -> some View {
        let soft = RecreateSwatches.soften(rec.grade?.swatches ?? [])
        if !soft.isEmpty {
            section("Look", trailing: rec.grade?.look?.label) {
                HStack(spacing: 0) { ForEach(soft.indices, id: \.self) { i in Color(swatch: soft[i]) } }
                    .frame(height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel(rec.grade?.look?.label.map { "Look: \($0)" } ?? "Look")
            }
        }
    }

    private func performance(_ p: LearnPerformance) -> some View {
        let pairs = LearnText.performance(p)
        let rows = stride(from: 0, to: pairs.count, by: 2).map { Array(pairs[$0..<min($0 + 2, pairs.count)]) }
        return section("Performance") {
            Grid(alignment: .leading, horizontalSpacing: Space.s4, verticalSpacing: Space.s2) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        ForEach(rows[i].indices, id: \.self) { j in
                            Text(rows[i][j].0).scaled(t.scale.caption, t.roles.ink2).lineLimit(1).fixedSize()
                            Text(rows[i][j].1).monospacedDigit().scaled(t.scale.body, t.roles.ink).lineLimit(1).fixedSize()
                                .fitProbe("performance \(rows[i][j].0)")
                                .gridColumnAlignment(.trailing)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func tags(_ d: LearnRecipe) -> some View {
        section("Tags") {
            FlowLayout(spacing: Space.s2) {
                ForEach(d.tags, id: \.self) { tag in
                    HStack(spacing: Space.s1) {
                        Text(tag).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                        Button { Task { await store.removeRecipeTag(tag) } } label: {
                            Ph("x", 10).foregroundStyle(t.roles.ink2).frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove tag \(tag)")
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                    .padding(.leading, Space.s3)
                    .padding(.trailing, Space.s1)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
                }
                if addingTag {
                    TextField("New tag", text: $newTag)
                        .focused($tagFocused)
                        .onSubmit {
                            let tag = newTag
                            newTag = ""
                            addingTag = false
                            Task { await store.addRecipeTag(tag) }
                        }
                        .onExitCommand { addingTag = false; newTag = "" }
                        .roleField(focused: tagFocused)
                        .frame(width: 140)
                        .accessibilityLabel("New tag")
                } else {
                    Button("+ Tag") { addingTag = true; tagFocused = true }
                        .buttonStyle(RButtonStyle(kind: .plain, small: true))
                        .fixedSize()
                        .fitProbe("+ Tag")
                        .accessibilityLabel("Add a tag")
                }
            }
        }
    }

    @ViewBuilder private var closest: some View {
        let near = store.learn.nearest
        if !near.isEmpty {
            section("Closest recipes") {
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(near.prefix(3)) { n in
                        Button { Task { await store.selectRecipe(n.id) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                LearnPictureView(picture: store.learnPicture(n))
                                    .aspectRatio(4 / 3, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
                                    .padding(.bottom, Space.s1)
                                Text(n.name).scaled(t.scale.caption, t.roles.ink).lineLimit(1)
                                Text(LearnText.closeness(n.distance)).scaled(t.scale.micro, t.roles.ink2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(n.name), \(LearnText.closeness(n.distance).lowercased())")
                    }
                    ForEach(0..<max(0, 3 - near.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    private func footer(_ d: LearnRecipe) -> some View {
        HStack(spacing: Space.s3) {
            Button("Delete recipe") { store.learn.askDeleteRecipe = true }
                .buttonStyle(RButtonStyle(kind: .danger, small: true))
                .fixedSize()
                .fitProbe("Delete recipe")
            Spacer(minLength: Space.s2)
            if d.isReference {
                if store.learn.referenceUsable {
                    primary("Use in Recreate", icon: "arrows-clockwise") { store.useRecipeInRecreate() }
                } else if !store.learn.loadingDetail {
                    Text("The reference video has expired").scaled(t.scale.caption, t.roles.ink2).lineLimit(1).fixedSize()
                }
            } else {
                primary("Open edit", icon: "scissors") { store.openRecipeEdit() }
            }
        }
        .padding(.horizontal, Space.s5)
        .frame(height: 60)
    }

    private func primary(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s2) { Ph(icon, 14); Text(title).fixedSize().fitProbe(title) }
        }
        .buttonStyle(RButtonStyle(kind: .action))
        .accessibilityLabel(title)
    }
}

/// The shape of the edit: each shot as a bar as long as it lasts (on `field`, cut apart by hairline gaps), with the
/// transitions marked above by their icon. A plain cut has no icon.
struct LearnShapeStrip: View {
    @Environment(\.theme) private var t
    var recipe: Recipe

    var body: some View {
        let slots = recipe.slots
        let total = max(0.1, slots.reduce(0) { $0 + $1.length })
        GeometryReader { g in
            let gap: CGFloat = 2
            let usable = max(0, g.size.width - gap * CGFloat(max(0, slots.count - 1)))
            let widths = slots.map { CGFloat($0.length / total) * usable }
            ZStack(alignment: .topLeading) {
                HStack(spacing: gap) {
                    ForEach(slots.indices, id: \.self) { i in
                        Rectangle().fill(t.roles.field)
                            .overlay(Rectangle().fill(t.roles.ink.opacity(i % 2 == 0 ? 0.0 : 0.06)))
                            .frame(width: max(1, widths[i]), height: 32)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous))
                .offset(y: 22)
                ForEach(Array(recipe.transitions.enumerated()), id: \.offset) { _, tr in
                    if let icon = LearnText.transitionIcon(tr.kind), let k = boundary(tr, slots) {
                        let x = widths.prefix(k + 1).reduce(0, +) + gap * CGFloat(k) + gap / 2
                        Ph(icon, 12).foregroundStyle(t.roles.ink2)
                            .help(RecreateText.transition(tr.kind))
                            .position(x: x, y: 8)
                    }
                }
            }
        }
        .frame(height: 54)
        .accessibilityElement()
        .accessibilityLabel(LearnText.shape(recipe))
    }

    /// The index of the shot a transition comes after.
    private func boundary(_ tr: Recipe.Transition, _ slots: [Recipe.Slot]) -> Int? {
        if let from = tr.from, let i = slots.firstIndex(where: { $0.id == from }), i < slots.count - 1 { return i }
        return slots.indices.dropLast().min { abs(slots[$0].endSec - tr.atSec) < abs(slots[$1].endSec - tr.atSec) }
    }
}
