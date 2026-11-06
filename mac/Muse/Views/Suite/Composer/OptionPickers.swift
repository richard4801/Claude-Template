import MuseCore
import SwiftUI

// AI suite (workstream 1): the Style (Genre, Era, Tempo), Look (Palette / Film stock + "Grade the take with this look")
// and Lighting pickers (C4). Grids of tiles, Auto first, only the catalogue's visible options; a tap applies at once.

/// A 4-column grid of option tiles with Auto as the first tile.
struct OptionGrid: View {
    var options: [SuiteOption]
    var selected: String?
    var autoLine = "Matches the scene"
    var swatches = false
    var tileHeight: CGFloat = 96
    /// The Auto tile's rendered still (`camera.autoPreviews`), when the catalog has one.
    var autoPreview: PickerPreview? = nil
    var onPick: (String?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), alignment: .leading, spacing: 18) {
            PickerOptionTile(name: "Auto", line: autoLine, preview: autoPreview, auto: true, swatches: [], selected: selected == nil, height: tileHeight) { onPick(nil) }
            ForEach(ComposerCatalog.visible(options)) { o in
                PickerOptionTile(name: o.label, line: o.description, preview: .option(o), swatches: swatches ? o.swatches : [],
                                 selected: selected == o.id || ComposerCatalog.survivor(options, selected) == o.id, height: tileHeight) { onPick(o.id) }
            }
        }
    }
}

/// Era as a decade slider: Auto off the left end, then the catalog's eras in order; the thumb snaps to each.
struct EraSlider: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let c = store.suite.camera
        let pos = ComposerEras.position(store.suite.pickerSettings.era, c)
        let top = ComposerEras.maxPosition(c)
        let stops = ComposerEras.stops(c)
        VStack(alignment: .leading, spacing: 18) {
            // The era's own still (design/previews/eras), as on Android; nothing for Auto.
            if pos > 0, let img = PreviewFiles.image(stops[pos - 1].preview?.poster) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity).frame(height: 150).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ERA").font(t.mono(10.5, .medium)).tracking(1.2).foregroundStyle(t.muted)
                Text(ComposerEras.label(at: pos, c)).font(Fonts.font("Instrument Serif", 46, .regular))
                Text(pos == 0 ? "Today · the scene decides" : (stops[pos - 1].description.isEmpty ? "Sets, clothes and colour of the time" : stops[pos - 1].description))
                    .font(t.body(13)).foregroundStyle(t.muted)
            }
            if top > 0 {
                Slider(value: Binding(get: { Double(pos) }, set: { store.suite.pickerSettings.era = ComposerEras.era(at: $0, c) }),
                       in: 0...Double(top), step: 1) { Text("Era") }
                    .labelsHidden()
                    .accessibilityValue(ComposerEras.label(at: pos, c))
                HStack(spacing: 0) {
                    ForEach(0...top, id: \.self) { i in
                        Button { store.suite.pickerSettings.era = ComposerEras.era(at: Double(i), c) } label: {
                            Text(ComposerEras.label(at: i, c)).font(t.mono(10.5, i == pos ? .semibold : .regular))
                                .foregroundStyle(i == pos ? t.accent : t.muted)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, -18)
            } else {
                Muted("This server has no eras yet.")
            }
        }
        .padding(.horizontal, 30).padding(.top, 20)
        .frame(maxWidth: 640, alignment: .leading)
    }
}

struct StyleStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var step: String

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        ScrollView {
            Group {
                switch step {
                case "format":
                    VStack(alignment: .leading, spacing: 14) {
                        Text("How the ad plays out. Genre, era and tempo still apply on top.").font(t.body(13)).foregroundStyle(t.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        OptionGrid(options: c.ugcFormats, selected: s.format, autoLine: "Picks the format from your prompt", tileHeight: 70) {
                            store.suite.pickerSettings.format = $0
                        }
                    }
                case "era": EraSlider()
                case "tempo": OptionGrid(options: c.tempos, selected: s.tempo, autoLine: "The scene sets the pace", tileHeight: 70) { store.suite.pickerSettings.tempo = $0 }
                default: OptionGrid(options: c.genres, selected: s.genre, autoLine: "From your prompt", tileHeight: 70) { store.suite.pickerSettings.genre = $0 }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
    }
}

struct LookStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var tab = "palette"

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        let list = tab == "palette" ? c.palettes : c.looks
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 3) {
                    seg("palette", "Palette")
                    seg("stock", "Film stock")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10).fill(t.surface2))
                Spacer()
                Text(tab == "palette" ? "\(ComposerCatalog.visible(c.palettes).count) palettes · each with an exact grade" : "\(ComposerCatalog.visible(c.looks).count) film stocks")
                    .font(t.body(12)).foregroundStyle(t.muted)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)
            ScrollView {
                OptionGrid(options: list, selected: tab == "palette" ? s.palette : s.stock, swatches: true) { id in
                    if tab == "palette" { store.suite.pickerSettings.palette = id } else { store.suite.pickerSettings.stock = id }
                }
                .padding(.horizontal, 22).padding(.top, 5).padding(.bottom, 18)
            }
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 12) {
                MToggle(isOn: Binding(get: { store.suite.pickerSettings.gradeLook }, set: { store.suite.pickerSettings.gradeLook = $0 }))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grade the take with this look").font(t.body(14, .semibold))
                    Text("Exact colour, reversible in Edit").font(t.body(12)).foregroundStyle(t.muted)
                }
                Spacer()
                if let name = ComposerCatalog.label(c.palettes, s.palette) ?? ComposerCatalog.label(c.looks, s.stock) {
                    Text(s.gradeLook ? "\(name) · applied" : "\(name) · prompt only").font(t.body(12)).foregroundStyle(t.muted)
                }
            }
            .padding(.horizontal, 24).frame(height: 58)
            .background(t.surface)
        }
    }

    private func seg(_ id: String, _ label: String) -> some View {
        let on = tab == id
        return Button { tab = id } label: {
            Text(label).font(t.body(13, .semibold)).foregroundStyle(on ? t.bg : t.muted)
                .padding(.horizontal, 14).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? t.ink : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(on ? ", selected" : "")")
    }
}

struct LightingStep: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            OptionGrid(options: store.suite.camera.lighting, selected: store.suite.pickerSettings.lighting, autoLine: "The scene's own light",
                       autoPreview: PickerPreview.auto(store.suite.camera.autoPreviews.lighting)) {
                store.suite.pickerSettings.lighting = $0
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
    }
}
