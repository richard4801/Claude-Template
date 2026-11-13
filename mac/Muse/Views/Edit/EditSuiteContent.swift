import AppKit
import MuseCore
import SwiftUI

// The edit content library on the Mac (WS8 84df583 / 929bcf2): emoji stickers in Bin → Stickers, sound effects in Bin →
// Music, the in-house looks, caption templates and transition presets as chips in their pickers, and the licences in
// Settings → About. All of it comes from GET /v1/editor/content; nothing shows until the catalog is here.

/// A search field in the bin's style.
struct ContentSearchField: View {
    @Environment(\.theme) private var t
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Space.s2) {
            Ph("magnifying-glass", 13).foregroundStyle(t.roles.ink2)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(t.scale.body.font)
                .foregroundStyle(t.roles.ink)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                SuiteIconButton(systemName: "xmark", label: "Clear the search", size: 24, tint: t.roles.ink2) { text = "" }
            }
        }
        .padding(.horizontal, Space.s3)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
    }
}

/// Category chips of one or more packs ("All" first).
private struct CategoryChips: View {
    var categories: [ContentPack.Category]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip("All", on: selection == nil) { selection = nil }
                ForEach(categories) { c in Chip(c.label, on: selection == c.id) { selection = c.id } }
            }
        }
    }
}

// MARK: - Stickers

/// Bin → Stickers: the catalog's stickers, searchable, by category. A click puts one at the playhead.
struct ContentStickers: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var query = ""
    @State private var category: String?
    private static let shown = 240

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if let c = session.content, !c.packs(.stickers).isEmpty {
                let packs = c.packs(.stickers)
                let all: [(ContentPack, ContentItem)] = packs.flatMap { p in p.items.map { (p, $0) } }
                let hits = all.filter { (category == nil || $0.1.category == category) && $0.1.matches(query) }
                ContentSearchField(prompt: "Search stickers", text: $query)
                CategoryChips(categories: packs.flatMap { $0.categories ?? [] }, selection: $category)
                if hits.isEmpty {
                    Text("No stickers match \u{201C}\(query)\u{201D}.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: Space.s2)], spacing: Space.s2) {
                    ForEach(hits.prefix(Self.shown), id: \.1.id) { pair in
                        StickerTile(session: session, pack: pair.0, item: pair.1)
                    }
                }
                if hits.count > Self.shown {
                    Text("Showing \(Self.shown) of \(hits.count). Search to find more.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
            } else if session.content == nil {
                // Loading: the grid's shape.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: Space.s2)], spacing: Space.s2) {
                    ForEach(0..<12, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field).frame(height: 48)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .task { await session.loadContent() }
    }
}

private struct StickerTile: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var pack: ContentPack
    var item: ContentItem
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        Button { Task { await session.addContentSticker(pack, item) } } label: {
            Group {
                if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(6) } else { Color.clear }
            }
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.surface2 : t.roles.field))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.name.prefix(1).uppercased() + item.name.dropFirst())
        .accessibilityLabel("Add sticker \(item.name)")
        .task(id: item.id) {
            guard image == nil, let path = item.file else { return }
            if let cached = StickerImages.shared.object(forKey: path as NSString) { image = cached; return }
            guard let url = await session.contentFile(path), let img = NSImage(contentsOf: url) else { return }
            StickerImages.shared.setObject(img, forKey: path as NSString)
            image = img
        }
    }
}

/// Sticker images already read, by file path (the grid scrolls back over them).
private enum StickerImages { static let shared: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 600; return c }() }

// MARK: - Sound effects

/// Bin → Music → Sound effects: searchable, by category, with a play button. "Add" puts one at the playhead.
struct ContentSounds: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var query = ""
    @State private var category: String?
    private static let shown = 120

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if let c = session.content, !c.packs(.sfx).isEmpty {
                let packs = c.packs(.sfx)
                let all: [(ContentPack, ContentItem)] = packs.flatMap { p in p.items.map { (p, $0) } }
                let hits = all.filter { (category == nil || $0.1.category == category) && $0.1.matches(query) }
                SuiteLabel("Sound effects")
                ContentSearchField(prompt: "Search sound effects", text: $query)
                CategoryChips(categories: packs.flatMap { $0.categories ?? [] }, selection: $category)
                if hits.isEmpty {
                    Text("No sounds match \u{201C}\(query)\u{201D}.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits.prefix(Self.shown), id: \.1.id) { pair in row(pair.0, pair.1) }
                }
                if hits.count > Self.shown {
                    Text("Showing \(Self.shown) of \(hits.count). Search to find more.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
            }
        }
        .task { await session.loadContent() }
    }

    private func row(_ pack: ContentPack, _ item: ContentItem) -> some View {
        let playing = session.previewingSound == ContentCatalog.ref(pack: pack.id, item: item.id)
        let category = pack.categories?.first { $0.id == item.category }?.label
        return HStack(spacing: Space.s2) {
            SuiteIconButton(systemName: playing ? "pause" : "play", label: playing ? "Stop \(item.name)" : "Play \(item.name)", on: playing, size: 28) {
                Task { await session.previewSound(pack, item) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1)
                if let category { Text(category).font(t.scale.micro.font).foregroundStyle(t.roles.ink2).lineLimit(1) }
            }
            Spacer(minLength: Space.s2)
            if let d = item.durationSec {
                Text(String(format: "%.1f s", d)).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
            }
            SuiteIconButton(systemName: "plus", label: "Add \(item.name) at the playhead", size: 28) {
                Task { await session.addContentSound(pack, item) }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Presets as chips

/// The in-house looks (Filters & LUTs): each one sets the picture's whole look.
struct ContentLookChips: View {
    @Bindable var session: EditSuiteSession
    var visual: EditSuite.Visual

    var body: some View {
        let items = (session.content?.packs(.looks) ?? []).flatMap(\.items).compactMap { (it: ContentItem) -> (ContentItem, EditV2.Look)? in it.lookValue.map { (it, $0) } }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                SuiteLabel("More looks")
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.0.id) { pair in
                        Chip(pair.0.name, on: visual.look == pair.1) { session.applyContentLook(pair.1) }
                            .accessibilityLabel("Look \(pair.0.name)")
                    }
                }
            }
        }
    }
}

/// Caption templates: font, colours, word-by-word style and position in one click.
struct ContentCaptionChips: View {
    @Bindable var session: EditSuiteSession

    var body: some View {
        let items = (session.content?.packs(.captions) ?? []).flatMap(\.items).compactMap { (it: ContentItem) -> (ContentItem, EditV2.CaptionStyle)? in it.captionStyle.map { (it, $0) } }
        let current = session.state.captionStyle
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                SuiteLabel("Templates")
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.0.id) { pair in
                        Chip(pair.0.name, on: current == pair.1) { session.edit { $0.applyCaptionTemplate(pair.1) } }
                            .disabled(current == nil)
                            .accessibilityLabel("Caption template \(pair.0.name)")
                    }
                }
            }
        }
    }
}

/// The transitions beyond the eight tiles, then the transition presets (a kind at a set length).
struct ContentTransitionChips: View {
    @Bindable var session: EditSuiteSession
    var disabled: Bool
    var duration: Double

    var body: some View {
        let current = session.state.selectedVideo?.transitionIn
        let presets = (session.content?.packs(.transitions) ?? []).flatMap(\.items).compactMap { (it: ContentItem) -> (ContentItem, EditV2.Transition)? in it.transitionValue.map { (it, $0) } }
        VStack(alignment: .leading, spacing: Space.s2) {
            FlowLayout(spacing: 6) {
                ForEach(EditV2.moreTransitionLabels, id: \.0) { pair in
                    let kind = EditV2.TransitionKind(rawValue: pair.0), label = pair.1
                    Chip(label, on: current?.kind == kind) {
                        session.edit { $0.setTransition(kind, duration: current?.durationSec ?? duration) }
                    }
                    .disabled(disabled)
                    .accessibilityLabel("Transition \(label)")
                }
            }
            if !presets.isEmpty {
                SuiteLabel("Presets")
                FlowLayout(spacing: 6) {
                    ForEach(presets, id: \.0.id) { pair in
                        let tr = pair.1
                        Chip(pair.0.name, on: current == tr) { session.edit { $0.setTransition(tr.kind, duration: tr.durationSec) } }
                            .disabled(disabled)
                            .help("\(EditV2.transitionLabel(tr.kind)), \(Self.seconds(tr.durationSec))")
                            .accessibilityLabel("Transition preset \(pair.0.name)")
                    }
                }
            }
        }
    }

    static func seconds(_ d: Double) -> String { String(format: d < 1 ? "%.2f s" : "%.1f s", d) }
}

// MARK: - Licences

/// Settings → About → Licences: what the edit content library is and under which licence, from the catalog.
struct ContentLicences: View {
    @Environment(\.theme) private var t
    var catalog: ContentCatalog?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if let c = catalog {
                ForEach(c.attributions) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.title) (\(Self.licenceName(p.licence)))").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        if let a = p.attribution {
                            Text(a).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                Text("MUSE's own looks, caption templates and transition presets are part of MUSE.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The edit content library's licences show here once it has loaded.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            }
        }
    }

    static func licenceName(_ id: String) -> String {
        switch id {
        case "CC-BY-4.0": return "CC BY 4.0"
        case "CC0-1.0": return "CC0 1.0"
        case "OFL-1.1": return "SIL Open Font License 1.1"
        default: return id
        }
    }
}

/// Settings → About → Licences: loads the catalog for its attributions.
struct SettingsContentLicences: View {
    @Environment(AppStore.self) private var store
    @State private var catalog: ContentCatalog?

    var body: some View {
        ContentLicences(catalog: catalog)
            .task { if catalog == nil { catalog = try? await store.api.editorContent() } }
    }
}
