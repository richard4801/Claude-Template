import MuseCore
import SwiftUI

/// Three-column video studio: source clip + checks · source → model preview with timeline · inspector with Generate.
struct StudioView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { g in
            let narrow = g.size.width < 900
            let side: CGFloat = narrow ? 230 + 310 : 280 + 344
            HStack(spacing: 0) {
                SourceColumn(targeted: dropTargeted).frame(width: narrow ? 230 : 280)
                StudioCenter(width: max(0, g.size.width - side))
                    .frame(maxWidth: .infinity)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let u = urls.first else { return false }
                        store.importClip(u)
                        return true
                    } isTargeted: { dropTargeted = $0 }
                StudioInspector().frame(width: narrow ? 310 : 344)
            }
        }
    }
}

private func clipTime(_ s: Double) -> String {
    let n = Int(s.rounded())
    return "\(n / 60):" + String(format: "%02d", n % 60)
}

struct SourceColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var targeted: Bool
    @State private var localTarget = false

    var body: some View {
        let clip = store.clip
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    H2("Source clip")
                    Spacer()
                    MoreMenu {
                        Button(store.showPrompt ? "Hide prompt" : "Show prompt") { store.showPrompt.toggle() }
                        Button("Save as preset") { store.showToast("Saved as preset \"Dance · \(store.quality.label)\"") }
                        Button("Reset settings") { store.resetStudio() }
                        Button(clip == nil ? "Choose a clip…" : "Change clip…") { store.pickClip() }
                    }
                }
                if let clip {
                    Media(ref: store.clipPoster, caption: "\(clipTime(clip.durationSec)) · \(clip.width)×\(clip.height)", captionIcon: "play.fill",
                          selectedColor: targeted || localTarget ? t.accent : nil)
                        .frame(maxWidth: 180)
                        .frame(maxWidth: .infinity)
                    if targeted || localTarget {
                        Text("Drop to use this clip").font(t.body(12, .semibold)).foregroundStyle(t.accent).frame(maxWidth: .infinity)
                    }
                    MButton("Change clip", icon: "square.and.arrow.up", size: .small, fill: true) { store.pickClip() }
                    if store.clipFile != nil { Muted(clip.name).lineLimit(1) }
                    clipChecks(clip)
                } else {
                    // Nothing uploaded yet: an empty drop zone. The sample clip is demo mode's only.
                    ClipDropZone(targeted: targeted || localTarget) { store.pickClip() }
                        .frame(maxWidth: 180)
                        .frame(maxWidth: .infinity)
                    MButton("Choose a clip", icon: "square.and.arrow.up", size: .small, fill: true) { store.pickClip() }
                    if store.isDemo {
                        LinkText("Use the sample clip") { Task { await store.useSampleClip(bad: false) } }
                    }
                }
            }
            .padding(20)
        }
        .background(t.chrome)
        .overlay(alignment: .trailing) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(width: t.lineWidth) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            store.importClip(u)
            return true
        } isTargeted: { localTarget = $0 }
    }

    private func clipChecks(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Lbl("Clip check")
            VStack(alignment: .leading, spacing: 9) {
                ForEach(clip.checks, id: \.label) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.label).font(t.body(13))
                            Spacer()
                            Pill((c.status == "bad" ? "✕ " : c.status == "good" ? "✓ " : "") + c.value, c.status == "bad" ? .warn : c.status == "good" ? .good : .neutral)
                        }
                        if let fix = c.fix { Text(fix).font(t.body(12)).foregroundStyle(t.warn) }
                    }
                }
            }
            if store.isDemo {
                LinkText(store.clipBad ? "Use the good sample clip" : "Preview: what a failing clip looks like") { store.toggleBadSample() }
            }
        }
    }
}

struct StudioCenter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The column's width: the stage tightens up in a narrower window (a 1280 px window leaves about 360 pt for it).
    var width: CGFloat

    var body: some View {
        @Bindable var store = store
        let outfit = store.currentOutfit
        let model = store.currentModel
        let stage = store.stage
        let avail = max(260, width - 64)
        let compact = avail < 430
        let arrowWidth: CGFloat = compact ? 44 : 96
        let pane = max(90, min(196, (avail - arrowWidth - 28) / 2))
        let keptLine = "Motion, timing and room are kept. The person is replaced."
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Video studio").styled()
                    H1("New video")
                    if t.isB {
                        HStack(spacing: 6) {
                            Text("●").foregroundStyle(t.rec)
                            Text("REF · FACE FRONT · \(store.currentOutfits.count) OUTFITS · OUTPUT 768×1344")
                        }
                        .font(t.mono(11.5)).tracking(0.7).foregroundStyle(t.accent).padding(.top, 8)
                    }
                }
                .padding(.bottom, 8)
                HStack(alignment: .center, spacing: 14) {
                    StageSourcePane().frame(width: pane)
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                            .background(Circle().fill(t.surface)).overlay(Circle().strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                        if !compact {
                            Text(keptLine).font(t.body(12)).foregroundStyle(t.muted).multilineTextAlignment(.center)
                        }
                    }
                    .frame(width: arrowWidth)
                    // Idle: the target. While a render from here runs: its live state; then the take playing (`StudioStage`).
                    StageOutputPane(stage: stage, target: outfit?.front ?? model?.cover, caption: "\(model?.shortName ?? "Model") · \(outfit?.name ?? "No outfit")")
                        .frame(width: pane)
                        .animation(.easeOut(duration: 0.3), value: stage.phase)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, compact || stage.phase != .idle ? 10 : 20)
                if compact {
                    Text(keptLine).font(t.body(12)).foregroundStyle(t.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .padding(.bottom, stage.phase == .idle ? 14 : 8)
                }
                if stage.phase != .idle {
                    StageBar(stage: stage).padding(.bottom, 16)
                }

                if store.clip != nil { Timeline() }

                if store.pro || store.showPrompt {
                    SectionHeader(title: "Prompt") {
                        HStack(spacing: 10) {
                            Muted("Built automatically\(store.pro ? " · pro mode" : "")")
                            MButton("Copy", size: .small) { store.copy(store.videoPrompt) }
                        }
                    }
                    Text(store.videoPrompt)
                        .font(t.mono(11.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
    }
}

struct Timeline: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let dur = store.clip?.durationSec ?? 9.4
        let len = store.spec.lengthSec
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Lbl("Use")
                Spacer()
                // Every option renders the whole clip.
                Text("Whole clip · \(Pricing.trimNum(len))s").font(t.mono(12.5)).foregroundStyle(t.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<10, id: \.self) { i in
                            MuseImage(ref: store.clipPoster).opacity(0.35 + Double(i % 3) * 0.1)
                        }
                    }
                    Color.black.opacity(0.25)
                    RoundedRectangle(cornerRadius: max(2, t.controlRadius * 0.6))
                        .strokeBorder(t.accent, lineWidth: 2)
                        .frame(width: max(8, g.size.width * min(1, len / max(dur, 0.1))))
                        .animation(.easeOut(duration: 0.3), value: len)
                }
                .clipShape(RoundedRectangle(cornerRadius: max(2, t.controlRadius * 0.6)))
            }
            .frame(height: 44)
            HStack {
                ForEach(scale(dur), id: \.self) { s in
                    Text(s).font(t.mono(11)).foregroundStyle(t.muted)
                    if s != scale(dur).last { Spacer() }
                }
            }
            if dur > Pricing.maxClipSec {
                Muted("Videos are up to 15s, so the first 15s of the clip are used.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .surface(t.surface, radius: t.controlRadius)
    }

    private func scale(_ dur: Double) -> [String] {
        let marks = stride(from: 0.0, to: dur - 0.6, by: max(1, (dur / 5).rounded())).map { "\(Int($0))s" }
        return marks + ["\(Pricing.trimNum(dur))s"]
    }
}

struct StudioInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Field("Model") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.models) { m in
                                    ThumbChoice(label: m.shortName, ref: m.cover, initial: m.initial, on: m.id == store.currentModel?.id) { store.selectModel(m) }
                                }
                            }
                        }
                    }
                    Field("Outfit", trailing: "+ New outfit", trailingAction: { store.openOutfitSheet(for: nil) }) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.currentOutfits) { o in
                                    ThumbChoice(label: o.name, ref: o.front, initial: "", on: o.id == store.currentOutfit?.id) { store.selectOutfit(o) }
                                }
                            }
                        }
                        if let never = StudioText.neverAdd(store.neverList(store.currentModel)) { Muted(never) }
                    }
                    QualityPicker()
                    AddOnsPicker()
                    OptionRow(title: "Takes", hint: "Different seeds, compared side by side") {
                        NumStepper(value: store.takeCount, dec: { store.setTakes(store.takeCount - 1) }, inc: { store.setTakes(store.takeCount + 1) })
                    }
                    if store.isEdit {
                        Field("Background") {
                            Seg([("keep", "Keep the room"), ("photo", "New photo")], selection: $store.background)
                            if store.background == "photo" {
                                Seg([("still", "Still"), ("subtle", "Subtly alive"), ("busy", "Busy")], selection: $store.motion)
                                Muted("Vertical photo, same camera height, similar light.")
                            }
                        }
                    }
                    OptionRow(title: "Keep the clip's audio", hint: "Off = a silent take") { MToggle(isOn: $store.keepAudio) }
                    if store.isEdit {
                        OptionRow(title: "Lip sync", hint: "Only when the performer talks or sings · +4 min") { MToggle(isOn: $store.lipSync) }
                    } else {
                        Muted("Keeps the room and the clip's exact length. Lip sync and a new background photo need Edit.")
                    }
                    if !store.pro {
                        LinkText("\(store.showPrompt ? "Hide" : "Show") the prompt") { store.showPrompt.toggle() }
                    }
                }
                .padding(20)
            }
            InspectorFooter()
        }
        .background(t.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(width: t.lineWidth) }
    }
}

/// `.thumbs .t`: a small 3:4 choice with a label.
struct ThumbChoice: View {
    @Environment(\.theme) private var t
    var label: String
    var ref: ImageRef?
    var initial: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let ref { Media(ref: ref, ratio: 0.75, radius: t.isA ? 0 : 8) } else { InitialTile(letter: initial, size: 22) }
                }
                .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 8).strokeBorder(on ? t.accent : .clear, lineWidth: 2))
                Text(label).font(t.body(11.5)).foregroundStyle(t.ink).lineLimit(2)
            }
            .frame(width: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InspectorFooter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let spec = store.spec
        let total = store.totalCost
        let blocked = store.generateBlocked
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                est("Length", spec.isReplicate ? "\(spec.replicateSeconds) s" : "\(Pricing.trimNum(spec.lengthSec)) s")
                est("Cost", Pricing.money(total))
                est("After", Pricing.money(max(0, store.creditUsd - total)))
            }
            if store.clipBad {
                Note(icon: "exclamationmark.triangle", warn: true, text: Text("This clip doesn't meet every recommendation. You can still generate, but results may be weaker: low resolution looks softer, extra people or watermarks can confuse the swap, and only the first 15 s of a longer clip is used."))
            }
            if store.lowBalance {
                if store.isMember {
                    Note(icon: "dollarsign.circle", warn: true, store.notEnoughMessage)
                } else {
                    Note(icon: "creditcard", warn: true, text: Text("Not enough balance for this render. ") + Text("Credit").bold())
                        .onTapGesture { store.go(.credits) }
                }
            }
            MButton(store.generating ? "Starting…" : Pricing.genLabel(spec), kind: .primary, size: .big, off: blocked) {
                store.generate()
            }
            Text("⌘↵ to generate · renders keep running if you close the app").font(t.body(12)).foregroundStyle(t.muted).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(t.chrome)
        .overlay(alignment: .top) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }
    }

    private func est(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Lbl(label)
            Text(value).font(t.mono(15, .medium)).foregroundStyle(t.ink).contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
    }
}

/// Render: Draft / Standard / HD, each with its live price for this clip and takes.
struct QualityPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let f = store.videoFeatures
        VStack(alignment: .leading, spacing: 8) {
            Lbl("Render")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(f.ordered) { o in
                    ChoiceCard(label: o.label, detail: o.available ? o.shownDetail : "Not available right now", price: Pricing.totalCost(store.spec(for: o.videoQuality)),
                               on: store.quality == o.videoQuality, isDefault: o.videoQuality == f.defaultOption, available: o.available, badgeRow: true) {
                        store.setQuality(o.videoQuality)
                    }
                }
            }
            Text(Pricing.priceLine(store.spec)).font(t.mono(12.5)).foregroundStyle(t.ink)
                .contentTransition(.numericText())
                .animation(.snappy, value: store.totalCost)
        }
    }
}

/// Add-ons: Edit and Fast · beta (when available) render the clip; Upscale works on a finished take and is coming soon.
struct AddOnsPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let f = store.videoFeatures
        VStack(alignment: .leading, spacing: 8) {
            Lbl("Add-ons")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(f.shownAddons) { a in
                    if let q = a.videoQuality {
                        ChoiceCard(label: a.label, detail: a.available ? a.shownDetail : "Not available right now", price: Pricing.totalCost(store.spec(for: q)),
                                   on: store.quality == q, isDefault: false, available: a.available) {
                            store.setQuality(store.quality == q ? f.defaultOption : q)
                        }
                    } else {
                        UpscaleCard(addon: a)
                    }
                }
            }
        }
    }
}

/// Upscale in the studio: what it does and its sizes, greyed while it's coming soon. It runs on a finished take (Result → Upscale).
struct UpscaleCard: View {
    @Environment(\.theme) private var t
    var addon: AddonOption

    var body: some View {
        let radius = t.isA ? 0 : t.controlRadius
        // Laid out like the other cards (name, then the price line, then two lines of detail) so a row lines up.
        VStack(alignment: .leading, spacing: 3) {
            Text(addon.label).font(t.body(13, .semibold)).foregroundStyle(t.ink).lineLimit(1).minimumScaleFactor(0.75)
            Text(addon.comingSoon || !addon.available ? "Coming soon" : "On a finished take").font(t.mono(12, .medium)).foregroundStyle(t.muted)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(addon.sizes.map(\.label).joined(separator: " · ") + " · on a finished take").font(t.body(11)).foregroundStyle(t.muted).lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: radius).fill(t.surface2))
        .opacity(addon.available ? 1 : 0.55)
        .help(addon.shownDetail)
        .accessibilityElement(children: .combine)
    }
}

/// One option in the Render or Add-ons picker: its name, a short line and the live price.
struct ChoiceCard: View {
    @Environment(\.theme) private var t
    var label: String
    var detail: String
    var price: Double
    var on: Bool
    var isDefault: Bool
    var available: Bool
    /// Render cards keep a row for the "Default" pill (empty on the others), so the three cards line up.
    var badgeRow = false
    var action: () -> Void

    var body: some View {
        let radius = t.isA ? 0 : t.controlRadius
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(t.body(13, .semibold)).foregroundStyle(t.ink).lineLimit(1).minimumScaleFactor(0.75)
                Text(Pricing.money(price)).font(t.mono(12, .medium)).foregroundStyle(on ? t.accent : t.ink).lineLimit(1).minimumScaleFactor(0.75)
                Text(detail).font(t.body(11)).foregroundStyle(t.muted).lineLimit(2, reservesSpace: true)
                if badgeRow {
                    Text(t.isA ? "DEFAULT" : "Default")
                        .font(t.mono(9.5, .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(on ? t.accent : t.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(on ? t.accent.opacity(0.14) : t.surface))
                        .opacity(isDefault ? 1 : 0)
                        .accessibilityHidden(!isDefault)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius).fill(on ? t.surface : t.surface2))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(on ? t.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.5)
        .help("\(label)\(isDefault ? " (default)" : "") · \(detail) · \(Pricing.money(price))")
        .accessibilityLabel("\(label)\(isDefault ? ", default" : ""), \(detail), \(Pricing.money(price))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
