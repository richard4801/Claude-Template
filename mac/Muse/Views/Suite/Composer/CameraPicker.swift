import AppKit
import MuseCore
import SwiftUI

// AI suite (workstream 1): the Camera picker's steps (C2, C3). Setup: four three-card wheels (Camera, Lens, Focal,
// Aperture) that scroll with the mouse wheel, drag, ↑/↓ or the chevrons. Angle: Height and Framing wheels with line
// diagrams drawn in code. Movement: category chips + search over a 4-column grid; a move goes into the prompt as #move.

// MARK: Setup

struct CameraSetupStep: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        let cams = ComposerWheels.cameras(c), lenses = ComposerWheels.lenses(c), focals = ComposerWheels.focals(c), aps = ComposerWheels.apertures(c)
        HStack(alignment: .top, spacing: 15) {
            WheelColumn(title: "Camera", items: cams, selected: Wheel.index(of: s.body, in: cams, options: c.bodies), plate: .render) { v in
                store.suite.pickerSettings.body = v
            }
            WheelColumn(title: "Lens", items: lenses, selected: Wheel.index(of: s.lens, in: lenses, options: c.lenses), plate: .render) { v in
                store.suite.pickerSettings.lens = v
            }
            WheelColumn(title: "Focal", items: focals, selected: ComposerWheels.focalIndex(s.focalMm, in: focals), plate: .focal) { v in
                store.suite.pickerSettings.focalMm = v.flatMap { Double($0) }
            }
            WheelColumn(title: "Aperture", items: aps, selected: Wheel.index(of: s.aperture, in: aps, options: c.apertures), plate: .iris) { v in
                store.suite.pickerSettings.aperture = v
            }
        }
        .padding(.horizontal, 22).padding(.top, 18)
    }
}

// MARK: Angle

struct CameraAngleStep: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        let heights = ComposerWheels.heights(c), framings = ComposerWheels.framings(c)
        HStack(alignment: .top, spacing: 15) {
            WheelColumn(title: "Height", items: heights, selected: Wheel.index(of: s.height, in: heights, options: c.heights), plate: .height, width: 200) { v in
                store.suite.pickerSettings.height = v
            }
            WheelColumn(title: "Framing", items: framings, selected: Wheel.index(of: s.shotSize, in: framings, options: c.shotSizes), plate: .framing, width: 200) { v in
                store.suite.pickerSettings.shotSize = v
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.top, 18)
    }
}

// MARK: Wheels

/// What a wheel card shows above its name: a hardware render or a diagram drawn in code.
enum WheelPlate { case render, focal, iris, height, framing, format }

/// One wheel: exactly three cards (previous, selected and next), the selection centred and outlined.
struct WheelColumn: View {
    @Environment(\.theme) private var t
    var title: String
    var items: [WheelItem]
    var selected: Int
    var plate: WheelPlate
    var width: CGFloat = 143
    /// The picked value (nil = Auto).
    var onPick: (String?) -> Void
    @State private var scroll = WheelScroll()
    @State private var dragSteps = 0
    @FocusState private var focused: Bool

    private var plateHeight: CGFloat { 84 }

    var body: some View {
        let win = Wheel.window(items, selected: selected)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(t.mono(11, .medium)).tracking(1.4)
                Spacer(minLength: 4)
                Text(Wheel.position(selected, count: items.count)).font(t.mono(10.5)).foregroundStyle(t.muted)
                chevron("chevron.up", -1)
                chevron("chevron.down", 1)
            }
            .frame(height: 18)
            VStack(spacing: 14) {
                card(win?.previous, side: true).scaleEffect(0.8, anchor: .bottom).onTapGesture { step(-1) }
                card(win?.selected, side: false)
                card(win?.next, side: true).scaleEffect(0.8, anchor: .top).onTapGesture { step(1) }
            }
            .frame(width: width)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.028)).padding(.vertical, 118).padding(.horizontal, -8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6).onChanged { g in
                let n = Int((-g.translation.height / 60).rounded())
                if n != dragSteps {
                    step(n - dragSteps)
                    dragSteps = n
                }
            }.onEnded { _ in dragSteps = 0 })
            .onHover { h in scroll.set(hovering: h) { step($0) } }
            .onChange(of: selected) { scroll.update { step($0) } }
            .onDisappear { scroll.set(hovering: false) { _ in } }
        }
        .frame(width: width)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(win?.selected.name ?? "Auto")")
        .accessibilityValue(Wheel.position(selected, count: items.count))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ d: Int) {
        guard d != 0, !items.isEmpty else { return }
        let i = Wheel.step(selected, by: d, count: items.count)
        if i != selected { withAnimation(.easeOut(duration: 0.16)) { onPick(items[i].value) } }
    }

    private func chevron(_ icon: String, _ d: Int) -> some View {
        Button { step(d) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.muted).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(d < 0 ? "Previous" : "Next")
    }

    @ViewBuilder private func card(_ item: WheelItem?, side: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let item { plateView(item, on: !side) } else { Color.clear }
                if !side && item != nil { PickCheck().padding(7) }
            }
            .frame(width: width, height: plateHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(!side && item != nil ? t.accent : .clear, lineWidth: 2).padding(-4))
            .shadow(color: !side && item != nil ? t.accent.opacity(0.14) : .clear, radius: 18, y: 10)
            Text(item?.name ?? " ").font(t.body(14, .semibold)).lineLimit(1).padding(.top, 10)
            Text(item?.caption ?? " ").font(t.body(12)).foregroundStyle(t.muted).lineLimit(2).frame(height: 31, alignment: .top).padding(.top, 2)
        }
        .opacity(side ? (item == nil ? 0 : 0.4) : 1)
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder private func plateView(_ item: WheelItem, on: Bool) -> some View {
        if item.value == nil {
            ZStack {
                Color(hex: 0x121315)
                Image(systemName: "sparkles").font(.system(size: 20, weight: .light)).foregroundStyle(t.muted)
            }
        } else {
            switch plate {
            case .render: HardwareImage(name: item.render).background(Color(hex: 0x101112))
            case .focal: FocalDiagram(mm: Double(item.value ?? "") ?? 50, on: on)
            case .iris: IrisPlate(render: item.render, stop: Double(item.value?.dropFirst() ?? "") ?? 2.8)
            // Angles: the rendered still when bundled, else the line diagram.
            case .height:
                if let img = PreviewFiles.image(item.preview) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { HeightDiagram(id: item.value ?? "eye", on: on) }
            case .framing:
                if let img = PreviewFiles.image(item.preview) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { FramingDiagram(id: item.value ?? "ms", on: on) }
            case .format:
                // Style cards: big type until their stills exist.
                LinearGradient(colors: [Color(hex: 0x23262A), Color(hex: 0x141518)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .bottomLeading) {
                        Text(item.name).font(Fonts.font("Instrument Serif", 30, .regular)).foregroundStyle(on ? amber : lineInk)
                            .lineLimit(1).minimumScaleFactor(0.6).padding(12)
                    }
            }
        }
    }
}

/// Routes mouse-wheel events to the wheel under the pointer (local event monitor while hovering).
final class WheelScroll {
    private var monitor: Any?
    private var acc: CGFloat = 0
    private var onStep: ((Int) -> Void)?

    func set(hovering: Bool, onStep: @escaping (Int) -> Void) {
        if hovering {
            self.onStep = onStep
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self else { return e }
                self.acc += e.scrollingDeltaY
                let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 28 : 0.9
                if abs(self.acc) >= threshold {
                    let d = self.acc > 0 ? -1 : 1
                    self.acc = 0
                    let f = self.onStep
                    MainActor.assumeIsolated { f?(d) }
                }
                return nil
            }
        } else {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            acc = 0
            self.onStep = nil
        }
    }

    /// The newest step handler (it knows the current selection).
    func update(_ onStep: @escaping (Int) -> Void) {
        if monitor != nil { self.onStep = onStep }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

// MARK: Diagrams drawn in code

private let lineInk = Color(hex: 0xECEAE5)
private let amber = Color(hex: 0xF2A93B)

/// A field-of-view wedge for a focal length (C2's Focal wheel).
struct FocalDiagram: View {
    var mm: Double
    var on: Bool
    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
        .background(Color(hex: 0x121315))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        var grid = Path()
        var y: CGFloat = 8
        while y < h { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: w, y: y)); y += 12 }
        ctx.stroke(grid, with: .color(lineInk.opacity(0.05)), lineWidth: 1)
        let half = min(ComposerWheels.fieldOfView(mm) / 2, 60) * .pi / 180
        let cx = w / 2, cy = h - 13, len = h - 26
        let dx = len * CGFloat(tan(half))
        var wedge = Path()
        wedge.move(to: CGPoint(x: cx, y: cy))
        wedge.addLine(to: CGPoint(x: cx - dx, y: cy - len))
        wedge.addLine(to: CGPoint(x: cx + dx, y: cy - len))
        wedge.closeSubpath()
        let col = on ? amber : lineInk
        ctx.fill(wedge, with: .color(on ? amber.opacity(0.16) : lineInk.opacity(0.08)))
        var edges = Path()
        edges.move(to: CGPoint(x: cx - dx, y: cy - len))
        edges.addLine(to: CGPoint(x: cx, y: cy))
        edges.addLine(to: CGPoint(x: cx + dx, y: cy - len))
        ctx.stroke(edges, with: .color(col.opacity(0.9)), lineWidth: 1.5)
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 4.5, y: cy - len + 4.5, width: 9, height: 9)), with: .color(lineInk))
        ctx.fill(Path(roundedRect: CGRect(x: cx - 5, y: cy - 2, width: 10, height: 12), cornerRadius: 2), with: .color(lineInk.opacity(0.75)))
        ctx.draw(Text("\(Int(ComposerWheels.fieldOfView(mm).rounded()))°").font(.system(size: 9.5, design: .monospaced)).foregroundColor(Color(hex: 0xA9A6A0)),
                 at: CGPoint(x: min(cx + dx + 14, w - 14), y: cy - len + 8))
    }
}

/// The iris render with a hexagonal opening sized by the f-stop.
struct IrisPlate: View {
    var render: String?
    var stop: Double
    var body: some View {
        ZStack {
            HardwareImage(name: render ?? "optic-01-iris").scaleEffect(1.25)
            Canvas { ctx, size in draw(&ctx, size) }
        }
        .clipped()
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let k: CGFloat = stop <= 1.6 ? 0.40 : (stop <= 3.2 ? 0.27 : (stop <= 6.4 ? 0.15 : 0.09))
        let r = size.height * k
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        var hex = Path()
        for k in 0..<6 {
            let a = (30 + Double(k) * 60) * .pi / 180
            let p = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            if k == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
        }
        hex.closeSubpath()
        var mask = Path(CGRect(origin: .zero, size: size))
        mask.addPath(hex)
        ctx.fill(mask, with: .color(Color(hex: 0x080809, alpha: 0.58)), style: FillStyle(eoFill: true))
        ctx.stroke(hex, with: .color(lineInk.opacity(0.55)), lineWidth: 1)
    }
}

/// Camera height: a figure and a camera at that height, with its line of sight.
struct HeightDiagram: View {
    var id: String
    var on: Bool
    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
        .background(Color(hex: 0x121315))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let ground = h - 10
        var floor = Path()
        floor.move(to: CGPoint(x: 8, y: ground)); floor.addLine(to: CGPoint(x: w - 8, y: ground))
        ctx.stroke(floor, with: .color(lineInk.opacity(0.3)), lineWidth: 1)
        // The figure on the right.
        let fx = w * 0.7, top = ground - (h - 22)
        let fh = ground - top
        ctx.fill(Path(ellipseIn: CGRect(x: fx - 5, y: top, width: 10, height: 10)), with: .color(lineInk.opacity(0.85)))
        var figure = Path()
        figure.move(to: CGPoint(x: fx, y: top + 10)); figure.addLine(to: CGPoint(x: fx, y: top + fh * 0.6))
        figure.move(to: CGPoint(x: fx, y: top + fh * 0.6)); figure.addLine(to: CGPoint(x: fx - 6, y: ground))
        figure.move(to: CGPoint(x: fx, y: top + fh * 0.6)); figure.addLine(to: CGPoint(x: fx + 6, y: ground))
        figure.move(to: CGPoint(x: fx - 9, y: top + fh * 0.3)); figure.addLine(to: CGPoint(x: fx + 9, y: top + fh * 0.3))
        ctx.stroke(figure, with: .color(lineInk.opacity(0.85)), lineWidth: 1.6)
        // The camera on the left at the height.
        let frac: Double = {
            switch id {
            case "overhead": return 1.15
            case "high": return 1.0
            case "eye": return 0.9
            case "shoulder": return 0.78
            case "hip": return 0.5
            case "low": return 0.32
            case "worm": return 0.06
            case "ground": return 0.02
            default: return 0.9
            }
        }()
        let camX = id == "overhead" ? fx - 4 : w * 0.24
        let camY = max(8, ground - fh * CGFloat(frac))
        let col = on ? amber : lineInk
        ctx.fill(Path(roundedRect: CGRect(x: camX - 7, y: camY - 5, width: 14, height: 10), cornerRadius: 2), with: .color(col))
        var sight = Path()
        sight.move(to: CGPoint(x: camX + (id == "overhead" ? 0 : 7), y: camY + (id == "overhead" ? 5 : 0)))
        sight.addLine(to: CGPoint(x: fx, y: top + fh * 0.25))
        ctx.stroke(sight, with: .color(col.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
    }
}

/// Framing: how much of a figure a shot size shows (the frame drawn around it).
struct FramingDiagram: View {
    var id: String
    var on: Bool
    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
        .background(Color(hex: 0x121315))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        // The figure, always the same size; the frame tightens around it.
        let fx = w / 2, top: CGFloat = 10, fh = h - 16
        var fig = Path()
        fig.addEllipse(in: CGRect(x: fx - 5, y: top, width: 10, height: 10))
        fig.move(to: CGPoint(x: fx, y: top + 10)); fig.addLine(to: CGPoint(x: fx, y: top + fh * 0.6))
        fig.move(to: CGPoint(x: fx, y: top + fh * 0.6)); fig.addLine(to: CGPoint(x: fx - 6, y: top + fh))
        fig.move(to: CGPoint(x: fx, y: top + fh * 0.6)); fig.addLine(to: CGPoint(x: fx + 6, y: top + fh))
        fig.move(to: CGPoint(x: fx - 9, y: top + fh * 0.3)); fig.addLine(to: CGPoint(x: fx + 9, y: top + fh * 0.3))
        ctx.stroke(fig, with: .color(lineInk.opacity(0.7)), lineWidth: 1.4)
        if id == "two_shot" || id == "ots" {
            let ox = id == "ots" ? fx - 26 : fx + 24
            var b = Path()
            b.addEllipse(in: CGRect(x: ox - 5, y: top + (id == "ots" ? 6 : 0), width: id == "ots" ? 16 : 10, height: id == "ots" ? 16 : 10))
            ctx.stroke(b, with: .color(lineInk.opacity(0.5)), lineWidth: 1.4)
        }
        // The frame: (top, bottom) as fractions of the figure.
        let span: (Double, Double, Double) = {
            switch id {
            case "els": return (-0.25, 1.25, 2.6)
            case "ls": return (-0.12, 1.08, 1.5)
            case "full": return (-0.06, 1.04, 1.0)
            case "cowboy": return (-0.05, 0.72, 0.9)
            case "ms": return (-0.05, 0.55, 0.8)
            case "mcu": return (-0.04, 0.4, 0.7)
            case "cu": return (-0.03, 0.22, 0.6)
            case "ecu": return (0.0, 0.08, 0.45)
            case "insert": return (0.25, 0.45, 0.45)
            case "two_shot": return (-0.08, 0.6, 1.3)
            case "ots": return (-0.06, 0.5, 1.2)
            case "pov": return (0.1, 0.9, 1.3)
            default: return (-0.05, 0.55, 0.8)
            }
        }()
        let y0 = top + fh * CGFloat(span.0), y1 = top + fh * CGFloat(span.1)
        let fhgt = max(8, y1 - y0)
        let fw = min(w - 6, fhgt * CGFloat(span.2) * 0.9)
        let shift: CGFloat = id == "ots" ? -8 : (id == "two_shot" ? 12 : 0)
        let rect = CGRect(x: fx - fw / 2 + shift, y: max(3, y0), width: fw, height: min(h - 6, fhgt))
        ctx.stroke(Path(rect), with: .color(on ? amber : lineInk), style: StrokeStyle(lineWidth: 1.5, dash: id == "pov" ? [4, 3] : []))
    }
}

// MARK: Movement

struct CameraMovementStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var query: String
    @State private var group = ComposerMoves.featured

    var body: some View {
        let c = store.suite.camera
        let moves = ComposerMoves.list(c, group: group, query: query)
        let talk = store.suite.composer.speaking == .on
        let inPrompt = Set(store.suite.composer.tokens.moves.compactMap { $0.move?.id })
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Click to add to your prompt").font(t.body(13))
                Text("·").foregroundStyle(t.muted)
                HStack(spacing: 4) {
                    Text("or type").foregroundStyle(t.muted)
                    Text("#").font(t.mono(11, .medium)).padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.line, lineWidth: 1))
                }
                .font(t.body(13))
                Text("·").foregroundStyle(t.muted)
                Text("up to \(PromptTokens.maxMoves) moves").font(t.body(13)).foregroundStyle(t.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ComposerMoves.groups(c)) { g in
                        let on = g.id == group && query.isEmpty
                        Button {
                            group = g.id
                            query = ""
                        } label: {
                            Text(g.label).font(t.body(13, .semibold)).foregroundStyle(on ? t.bg : t.muted)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(Capsule().fill(on ? t.ink : t.surface2))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(g.label)\(on ? ", selected" : "")")
                    }
                }
            }
            ScrollView {
                if moves.isEmpty {
                    Text("No move matches “\(query)”").font(t.body(13)).foregroundStyle(t.muted).padding(.top, 30).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 4), alignment: .leading, spacing: 16) {
                    ForEach(moves) { m in
                        MoveTile(move: m, talkSafeBadge: talk && m.talkSafe, inPrompt: inPrompt.contains(m.id)) { store.insertMove(m) }
                    }
                }
                .padding(.bottom, 18)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 22).padding(.top, 16)
    }
}

/// A move's tile: the neutral still (or its loop, on hover) with the move's arrow, badges and the name.
struct MoveTile: View {
    @Environment(\.theme) private var t
    var move: SuiteMoveOption
    var talkSafeBadge: Bool
    var inPrompt: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topLeading) {
                    // The rendered loop plays while the tile is on screen; the drawn arrow only where there's no preview.
                    let pv = PickerPreview.move(move)
                    PreviewView(preview: pv, autoplay: true)
                        .overlay { if !pv.hasRender { MoveArrow(move: move) } }
                    VStack(alignment: .leading, spacing: 4) {
                        if talkSafeBadge { badge("Talk-safe", icon: "text.bubble") }
                        if move.editorBetter { badge("Better in Edit", icon: "scissors") }
                    }
                    .padding(8)
                }
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(inPrompt ? t.accent : .clear, lineWidth: 2).padding(-3))
                Text(move.label).font(t.body(14, .semibold)).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(move.description)
        .accessibilityLabel("\(move.label)\(talkSafeBadge ? ", talk-safe" : "")\(move.editorBetter ? ", better done in Edit" : "")\(inPrompt ? ", in the prompt" : "")")
    }

    private func badge(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text.uppercased()).font(Fonts.font("JetBrains Mono", 9.5, .medium)).tracking(0.6)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(Color(hex: 0xECEAE5))
        .padding(.leading, 6).padding(.trailing, 8).frame(height: 20)
        .background(Capsule().fill(Color(hex: 0x0D0E0F, alpha: 0.74)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
