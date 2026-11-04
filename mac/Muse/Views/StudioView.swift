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
            HStack(spacing: 0) {
                SourceColumn(targeted: dropTargeted).frame(width: narrow ? 230 : 280)
                StudioCenter()
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
                        Button("Save as preset") { store.showToast("Saved as preset \"\(store.engine == .viggle ? "Fast" : "Dance") · \(store.steps) steps\"") }
                        Button("Reset settings") { store.resetStudio() }
                        Button("Change clip…") { store.pickClip() }
                    }
                }
                Media(ref: store.clipThumb ?? .asset("src_clip"), caption: clip.map { "\(clipTime($0.durationSec)) · \($0.width)×\($0.height)" }, captionIcon: "play.fill",
                      selectedColor: targeted || localTarget ? t.accent : nil)
                    .frame(maxWidth: 180)
                    .frame(maxWidth: .infinity)
                if targeted || localTarget {
                    Text("Drop to use this clip").font(t.body(12, .semibold)).foregroundStyle(t.accent).frame(maxWidth: .infinity)
                }
                MButton("Change clip", icon: "square.and.arrow.up", size: .small, fill: true) { store.pickClip() }
                if let name = clip?.name, store.clipFile != nil { Muted(name).lineLimit(1) }
                VStack(alignment: .leading, spacing: 10) {
                    Lbl("Clip check")
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(clip?.checks ?? [], id: \.label) { c in
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
                    LinkText(store.clipBad ? "Use the good sample clip" : "Preview: what a failing clip looks like") { store.toggleBadSample() }
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
}

struct StudioCenter: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        let outfit = store.currentOutfit
        let model = store.currentModel
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
                    Media(ref: store.clipThumb ?? .asset("src_clip"), caption: "Source · performer").frame(maxWidth: 196)
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                            .background(Circle().fill(t.surface)).overlay(Circle().strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                        Text("Motion, timing and room are kept. The person is replaced.").font(t.body(12)).foregroundStyle(t.muted).multilineTextAlignment(.center)
                    }
                    .frame(width: 96)
                    Media(ref: outfit?.front ?? model?.cover, caption: "\(model?.shortName ?? "Model") · \(outfit?.name ?? "No outfit")").frame(maxWidth: 196)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 20)

                Timeline()

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
        @Bindable var store = store
        let dur = store.clip?.durationSec ?? 9.4
        let len = store.spec.lengthSec
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Lbl("Use")
                Spacer()
                Seg([(ClipUse.first, RenderSpec.useLabel(.first, clipSeconds: dur)), (ClipUse.full, RenderSpec.useLabel(.full, clipSeconds: dur))], selection: $store.use)
                    .frame(width: 420)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<10, id: \.self) { i in
                            MuseImage(ref: store.clipThumb ?? .asset("src_clip")).opacity(0.35 + Double(i % 3) * 0.1)
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
            if dur > Pricing.maxClipSec && store.use == .full {
                Muted("H3 renders up to 15s in one pass, so the full option uses the first 15s.")
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
                        HStack(spacing: 8) {
                            ForEach(store.models) { m in
                                ThumbChoice(label: m.shortName, ref: m.cover, initial: m.initial, on: m.id == store.currentModel?.id) { store.selectModel(m) }
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
                        Muted("Never add: \(store.neverList(store.currentModel).joined(separator: ", ")). Removed automatically.")
                    }
                    Field("Engine") {
                        Seg([(Engine.h3, "Standard"), (Engine.viggle, "Fast · beta")], selection: $store.engine)
                    }
                    StepsControl()
                    OptionRow(title: "Takes", hint: "Different seeds, compared side by side") {
                        NumStepper(value: store.takeCount, dec: { store.setTakes(store.takeCount - 1) }, inc: { store.setTakes(store.takeCount + 1) })
                    }
                    Field("Background") {
                        Seg([("keep", "Keep the room"), ("photo", "New photo")], selection: $store.background)
                        if store.background == "photo" {
                            Seg([("still", "Still"), ("subtle", "Subtly alive"), ("busy", "Busy")], selection: $store.motion)
                            Muted("Vertical photo, same camera height, similar light.")
                        }
                    }
                    OptionRow(title: "Keep the clip's audio", hint: "Off = upload a new track") { MToggle(isOn: $store.keepAudio) }
                    OptionRow(title: "Lip sync", hint: "Only when the performer talks or sings · +4 min") { MToggle(isOn: $store.lipSync) }
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

/// Steps: slider (Editorial, Soft Tactile, Creator Pop) or a dial (Camera Body). Fast · beta has fixed quality.
struct StepsControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let s = store.steps
        VStack(alignment: .leading, spacing: 8) {
            if store.engine == .viggle {
                Note(icon: "exclamationmark.shield", warn: true,
                     "Fast · beta renders in about 2 minutes with exact motion timing, but faces are softer and can warp slightly. Fixed quality, no steps.")
            } else if t.isB {
                HStack(spacing: 18) {
                    Knob(value: s) { store.setSteps($0) }
                    VStack(alignment: .leading, spacing: 4) {
                        Lbl("Steps")
                        Text("\(s)").font(t.mono(34, .medium)).foregroundStyle(t.accent)
                        Text(Pricing.stepsBadge(s, style: .readout)).font(t.mono(11.5)).tracking(0.7).foregroundStyle(t.accent)
                        Muted("Drag the dial · ← → keys")
                    }
                }
                Muted(Pricing.stepsDelta(store.spec))
            } else {
                HStack {
                    Lbl("Steps")
                    Spacer()
                    if t.isD {
                        Sticker(Pricing.stepsBadge(s, style: .sticker))
                    } else {
                        Pill(Pricing.stepsBadge(s), s == Pricing.stepsDefault ? .good : .warn)
                    }
                }
                Text("\(s)").font(t.isA ? Fonts.font("Instrument Serif", 72, .regular) : t.mono(34, .medium)).foregroundStyle(t.ink)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: s)
                StepsSlider(value: s) { store.setSteps($0) }
                HStack {
                    ForEach(["4", "10", "20", "30"], id: \.self) { l in
                        Text(l).font(t.mono(11)).foregroundStyle(t.muted)
                        if l != "30" { Spacer() }
                    }
                }
                Muted(Pricing.stepsDelta(store.spec))
            }
        }
    }
}

struct StepsSlider: View {
    @Environment(\.theme) private var t
    var value: Int
    var onChange: (Int) -> Void

    var body: some View {
        GeometryReader { g in
            let pct = CGFloat(value - Pricing.stepsMin) / CGFloat(Pricing.stepsMax - Pricing.stepsMin)
            ZStack(alignment: .leading) {
                Capsule().fill(t.surface2).frame(height: 6)
                Capsule().fill(t.accent).frame(width: pct * g.size.width, height: 6)
                Circle().fill(t.surface).frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(t.isD ? Color(hex: 0x111111) : t.accent, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: pct * g.size.width - 10)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = max(0, min(1, v.location.x / max(1, g.size.width)))
                onChange(Pricing.stepsMin + Int((f * CGFloat(Pricing.stepsMax - Pricing.stepsMin)).rounded()))
            })
            .animation(.easeOut(duration: 0.12), value: value)
        }
        .frame(height: 28)
    }
}

/// Camera Body's steps dial: drag up/down to turn it.
struct Knob: View {
    @Environment(\.theme) private var t
    var value: Int
    var onChange: (Int) -> Void
    @State private var start: Int?

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0x3A3F44), Color(hex: 0x15171A)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2, endRadius: 60))
                .shadow(color: .black.opacity(0.6), radius: 8, y: 6)
            ForEach(0..<45, id: \.self) { i in
                Rectangle().fill(Color(hex: i % 2 == 0 ? 0x2B2F33 : 0x1D2023)).frame(width: 2, height: 30).offset(y: -21).rotationEffect(.degrees(Double(i) * 8))
            }
            Capsule().fill(t.accent).frame(width: 3, height: 16).offset(y: -26)
        }
        .frame(width: 84, height: 84)
        .rotationEffect(.degrees(Double(value - 17) * 10))
        .animation(.easeOut(duration: 0.15), value: value)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
            let s0 = start ?? value
            if start == nil { start = value }
            onChange(s0 + Int((-v.translation.height / 8).rounded()))
        }.onEnded { _ in start = nil })
        .help("Drag up or down")
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
                est("Time", Pricing.fmtMin(Pricing.totalMin(spec)))
                est("Cost", Pricing.money(total))
                est("After", Pricing.money(max(0, store.creditUsd - total)))
            }
            if store.lowBalance && !store.clipBad {
                if store.isMember {
                    Note(icon: "dollarsign.circle", warn: true, store.notEnoughMessage)
                } else {
                    Note(icon: "creditcard", warn: true, text: Text("Not enough balance for this render. ") + Text("Credit").bold())
                        .onTapGesture { store.go(.credits) }
                }
            }
            if store.studioSettings?.lowBalance == true || store.jobs.contains(where: \.isPaused) {
                Note(icon: "pause.circle", warn: true, "\(Job.pausedLine). New renders wait until it's topped up.")
            }
            MButton(store.clipBad ? "Fix the clip to continue" : store.generating ? "Starting…" : Pricing.genLabel(spec), kind: .primary, size: .big, off: blocked) {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
    }
}
