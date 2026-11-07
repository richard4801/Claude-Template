import AppKit
import QuartzCore
import MuseCore
import SwiftUI

// The drum wheel for every hardware choice in the rig: a faithful port of the owner-approved prototype
// (design/drum-wheels-prototype.html), the same numbers as the Android port (RigDrum.kt): unboxed hardware renders with a
// soft vignette, the focal wedge, the amber iris and the dashed "A" for Auto, the same 3D tilt, scale and fade, 84 pt rows
// (112 when wide) and one band across all four drums. The maths lives in MuseCore (Suite/RigDrumMath.swift) and is tested
// there; this file only draws the drum and turns the pointer, trackpad and keyboard into positions.

/// The prototype's camera-bag colours (its :root): the panel matches the renders' own backdrop so they sit unboxed.
enum DrumBag {
    static let panel = Color(hex: 0x141414)
    static let band = Color.white.opacity(0.055)
    static let hair = Color.white.opacity(0.14)
    static let ink = Color(hex: 0xECE8E1)
    static let dim = Color(hex: 0x8F8A82)
    static let amber = Color(hex: 0xE7A54A)
}

/// One vertical drum: its label above, five rows with the pick centred in the selection band, and the pick's name and
/// caption under it.
///
/// ```swift
/// let cams = ComposerWheels.cameras(c)
/// RigDrum(label: "Camera", items: cams, selected: Wheel.index(of: s.body, in: cams, options: c.bodies)) { item in
///     settings.body = item.value          // nil is Auto
/// }
/// ```
/// - `items`: Auto (value nil) is the dashed circle with an "A"; others draw their `render` (`hardware/<render>`) or
///   `preview` poster unboxed, or, with `face: .focal` / `.aperture`, the field-of-view wedge / the iris.
/// - `selected`: the index in `items`. Change it from outside (Reset all, a preset) and the drum turns to it.
/// - `onSelect` runs once when the drum comes to rest on a different item, never for the items it passes on the way.
/// - Drums with 5 or more items loop; shorter ones stop and rubber-band at the ends.
/// - `rowHeight`: one detent, `RigDrum.row(wide:)` (84, or 112 when the drums are 720 pt wide or more).
/// - `band`: draws the selection band for a drum on its own; `RigDrums` draws one band across all of them instead
///   (pass `band: false` there).
struct RigDrum: View {
    /// How an item that isn't Auto is drawn.
    enum Face { case render, focal, aperture }

    /// The camera bag's colours: the shared design tokens' `Roles.bag`, dark in every theme (design-direction §9).
    /// Kept for older call sites; the drums themselves draw with `DrumBag`.
    enum Bag {
        static var raised: Color { Roles.bag.raised }
        static var field: Color { Roles.bag.field }
        static var ink: Color { Roles.bag.ink }
        static var ink2: Color { Roles.bag.ink2 }
        static var hairline: Color { Roles.bag.hairline }
    }

    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("rigDrumClick") private var clickOn = false
    @FocusState private var focused: Bool
    @State private var model: RigDrumModel

    let label: String
    let items: [WheelItem]
    let selected: Int
    let face: Face
    let rowHeight: CGFloat
    let band: Bool
    let onSelect: (WheelItem) -> Void

    /// Visible rows.
    static let rows: CGFloat = 5
    /// The label's line and the gaps around the drum (the prototype's .col gap).
    static let labelHeight: CGFloat = 18
    static let gap: CGFloat = 10
    /// From this drums-area width up the rows are 112 pt (the prototype's 720 px breakpoint).
    static let wideWidth: CGFloat = 720

    /// One detent: 84 pt, 112 when wide (the prototype's --item).
    static func row(wide: Bool) -> CGFloat { wide ? 112 : 84 }

    init(label: String, items: [WheelItem], selected: Int, face: Face = .render, rowHeight: CGFloat = 84, band: Bool = true,
         onSelect: @escaping (WheelItem) -> Void) {
        self.label = label
        self.items = items
        self.selected = selected
        self.face = face
        self.rowHeight = rowHeight
        self.band = band
        self.onSelect = onSelect
        let n = items.count
        let start = n > 0 ? min(max(selected, 0), n - 1) : 0
        _model = State(initialValue: RigDrumModel(position: Double(start), count: n))
    }

    private var count: Int { items.count }
    private var near: Int { RigDrumMath.nearest(model.pos, count: count, loop: model.loop) }
    private var current: WheelItem? { items.indices.contains(near) ? items[near] : nil }
    private var wide: Bool { rowHeight > 100 }

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(Fonts.font(t.scale.textFamily, wide ? 13 : 12, .regular))
                .foregroundStyle(DrumBag.dim)
                .lineLimit(1)
                .frame(height: Self.labelHeight)
            drum
                .padding(.vertical, Self.gap)
            nameBlock
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            model.reduceMotion = reduceMotion
            model.setCount(count, selected: selected)
        }
        .onDisappear { model.tearDown() }
        .onChange(of: reduceMotion) { _, v in model.reduceMotion = v }
        .onChange(of: count) { _, n in model.setCount(n, selected: selected) }
        .onChange(of: selected) { _, v in model.turn(to: v) }
        .onChange(of: model.settleToken) { _, _ in commit() }
        .onChange(of: model.detent) { _, _ in tick() }
    }

    /// The name in the band's item and its caption, cross-fading as the drum turns (the prototype's .name).
    private var nameBlock: some View {
        let i = near
        let item = current
        let caption = item?.caption ?? ""
        return ZStack(alignment: .top) {
            VStack(spacing: 3) {
                Text(item?.name ?? " ")
                    .font(Fonts.font("Barlow Condensed", wide ? 14.5 : 13, .semibold))
                    .foregroundStyle(DrumBag.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if !caption.isEmpty {
                    Text(caption)
                        .font(Fonts.font(t.scale.textFamily, wide ? 10.5 : 9.5, .regular))
                        .foregroundStyle(DrumBag.dim)
                        .lineLimit(2)
                        .lineSpacing(1)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .id(i)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: i)
        .accessibilityHidden(true)
    }

    private var drum: some View {
        let h = rowHeight
        let loop = model.loop
        let pos = model.pos
        let sel = near
        let showBand = band
        return GeometryReader { g in
            // The prototype's picture box: 96 % of the row high, at most 92 % of the column wide.
            let box = CGSize(width: min(h * 0.96, g.size.width * 0.92), height: h * 0.96)
            ZStack {
                if showBand { DrumBandView(height: h) }
                ForEach(Array(items.indices), id: \.self) { i in
                    drumItem(i, pos: pos, loop: loop, selectedIndex: sel, rowHeight: h, box: box)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: h * Self.rows)
        .clipped()
        // The drum fades into the panel at the top and bottom (the prototype's mask).
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22),
                                   .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in model.drag(translation: Double(g.translation.height), itemHeight: Double(h)) }
            .onEnded { g in
                focused = true
                model.endDrag(tapOffset: Double(g.location.y - h * Self.rows / 2), itemHeight: Double(h))
            })
        .onHover { inside in model.hover(inside, itemHeight: Double(h)) }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { model.hitFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in model.hitFrame = f }
        })
        .overlay {
            // The prototype's focus-visible ring: an amber inset outline.
            RoundedRectangle(cornerRadius: 12).strokeBorder(DrumBag.amber, lineWidth: 2)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { model.step(-1); return .handled }
        .onKeyPress(.downArrow) { model.step(1); return .handled }
        .help("\(label): scroll, drag or use the arrow keys")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(current.map { $0.caption.isEmpty ? $0.name : "\($0.name), \($0.caption)" } ?? "")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: model.step(1)
            case .decrement: model.step(-1)
            @unknown default: break
            }
        }
    }

    /// One item on the drum, placed by the prototype's 3D: y = R·sin, translateZ = R(cos − 1) under a 700 pt perspective,
    /// scale (0.78 + 0.22·cos), opacity cos^2.2, a tilt about the x axis, and dimmed off the band.
    @ViewBuilder
    private func drumItem(_ i: Int, pos: Double, loop: Bool, selectedIndex: Int, rowHeight h: CGFloat, box: CGSize) -> some View {
        let d = RigDrumMath.delta(item: i, pos: pos, count: count, loop: loop)
        let look = RigDrumMath.look(delta: d, itemHeight: Double(h), selected: i == selectedIndex)
        if abs(d) <= 2.6 && look.visible {
            let persp = Self.perspective(delta: d, rowHeight: Double(h))
            itemFace(items[i], box: box)
                .scaleEffect(CGFloat(look.scale * persp))
                .rotation3DEffect(.degrees(look.rotationDegrees), axis: (x: 1, y: 0, z: 0),
                                  perspective: min(1, max(box.width, box.height) / 700))
                .colorMultiply(Color(white: look.brightness))
                .opacity(look.opacity)
                .offset(y: CGFloat(look.y * persp))
                .accessibilityHidden(true)
        }
    }

    /// 700 / (700 − z) with z = R(cos − 1): the prototype's translateZ under its `perspective: 700px`.
    static func perspective(delta d: Double, rowHeight h: Double) -> Double {
        let r = h / (2 * sin(RigDrumMath.stepDegrees * .pi / 360))
        let z = r * (cos(d * RigDrumMath.stepDegrees * .pi / 180) - 1)
        return 700 / (700 - z)
    }

    @ViewBuilder
    private func itemFace(_ item: WheelItem, box: CGSize) -> some View {
        if item.value == nil {
            Canvas { ctx, size in DrumGlyphs.auto(&ctx, size) }
                .frame(width: box.width, height: box.height)
        } else if face == .focal {
            let mm = Double(item.value ?? "") ?? 50
            Canvas { ctx, size in DrumGlyphs.focal(&ctx, size, mm: mm) }
                .frame(width: box.width, height: box.height)
        } else if face == .aperture {
            let f = DrumGlyphs.fNumber(item)
            Canvas { ctx, size in DrumGlyphs.iris(&ctx, size, f: f) }
                .frame(width: box.width, height: box.height)
        } else if let img = HardwareRenders.image(item.render) ?? PreviewFiles.image(item.preview) {
            // Unboxed: aspect-fit, with the prototype's radial mask (solid to 62 % of the closest side, clear at 100 %).
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: box.width, height: box.height)
                .mask {
                    RadialGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62),
                                           .init(color: .clear, location: 1)],
                                   center: .center, startRadius: 0, endRadius: min(box.width, box.height) / 2)
                }
        } else {
            Text(item.name)
                .font(Fonts.font("Barlow Condensed", wide ? 14.5 : 13, .semibold))
                .foregroundStyle(DrumBag.ink)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                .frame(width: box.width, height: box.height)
        }
    }

    private func commit() {
        let i = model.settled
        guard items.indices.contains(i), i != selected else { return }
        onSelect(items[i])
    }

    /// The optional soft click per detent (off by default).
    private func tick() {
        guard clickOn else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        RigDrumModel.playClick()
    }
}

/// The one selection band: a faint fill with hairlines top and bottom.
struct DrumBandView: View {
    var height: CGFloat
    var body: some View {
        Rectangle().fill(DrumBag.band)
            .overlay(alignment: .top) { Rectangle().fill(DrumBag.hair).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(DrumBag.hair).frame(height: 1) }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The rig's hardware drums side by side on the camera-bag panel under one selection band (the prototype's .bag):
/// four equal columns, no gap. Each drum passes `rowHeight` and `band: false`.
struct RigDrums<Content: View>: View {
    var rowHeight: CGFloat
    @ViewBuilder var content: Content

    static var paddingTop: CGFloat { 14 }

    var body: some View {
        let bandTop = Self.paddingTop + RigDrum.labelHeight + RigDrum.gap + 2 * rowHeight
        HStack(alignment: .top, spacing: 0) { content }
            .padding(.top, Self.paddingTop)
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
            .background {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 18).fill(DrumBag.panel)
                    DrumBandView(height: rowHeight).offset(y: bandTop)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera setup wheels")
    }
}

/// The prototype's live rig line: an amber tally dot and the four picks ("35mm film  ·  Warm vintage  ·  35 mm  ·  f/2.8").
struct RigLine: View {
    @Environment(\.theme) private var t
    var names: [String]

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(RadialGradient(colors: [DrumBag.amber.opacity(0.45), DrumBag.amber.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: 7))
                Circle().fill(DrumBag.amber).frame(width: 7, height: 7)
            }
            .frame(width: 14, height: 14)
            line
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your rig: \(names.joined(separator: ", "))")
    }

    private var line: Text {
        let family = t.scale.textFamily
        var out = Text(verbatim: "")
        for (i, n) in names.enumerated() {
            if i > 0 {
                out = out + Text(verbatim: "  ·  ").font(Fonts.font(family, 13, .regular)).foregroundColor(DrumBag.dim)
            }
            out = out + Text(verbatim: n).font(Fonts.font(family, 13, .medium)).foregroundColor(DrumBag.ink)
        }
        return out
    }
}

/// The prototype's drawings for the items without a render, in a 100-unit box centred in the frame.
enum DrumGlyphs {
    private static func unit(_ size: CGSize) -> (u: CGFloat, o: CGPoint) {
        let u = min(size.width, size.height) / 100
        return (u, CGPoint(x: (size.width - 100 * u) / 2, y: (size.height - 100 * u) / 2))
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// Auto: a dashed circle with an "A", drawn as strokes so it sits exactly in the circle.
    static func auto(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let (u, o) = unit(size)
        let c = CGPoint(x: o.x + 50 * u, y: o.y + 50 * u)
        ctx.stroke(circle(c, 30 * u), with: .color(DrumBag.ink.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 2 * u, dash: [4 * u, 5 * u]))
        var a = Path()
        a.move(to: CGPoint(x: o.x + 43 * u, y: o.y + 59 * u))
        a.addLine(to: CGPoint(x: o.x + 50 * u, y: o.y + 41 * u))
        a.addLine(to: CGPoint(x: o.x + 57 * u, y: o.y + 59 * u))
        a.move(to: CGPoint(x: o.x + 45.6 * u, y: o.y + 53 * u))
        a.addLine(to: CGPoint(x: o.x + 54.4 * u, y: o.y + 53 * u))
        ctx.stroke(a, with: .color(DrumBag.ink.opacity(0.8)), lineWidth: 1.8 * u)
    }

    /// Focal length: the horizontal field-of-view wedge from a small camera block; narrower as the focal length grows.
    static func focal(_ ctx: inout GraphicsContext, _ size: CGSize, mm: Double) {
        let (u, o) = unit(size)
        let half = atan(36 / (2 * max(mm, 1)))
        let a = min(half, 1.2)
        let l: CGFloat = 64
        let apex = CGPoint(x: o.x + 18 * u, y: o.y + 50 * u)
        var wedge = Path()
        wedge.move(to: apex)
        // y points down: from −a to +a through 0 is the arc on the right, as the SVG's sweep flag 1.
        wedge.addArc(center: apex, radius: l * u, startAngle: .radians(-a), endAngle: .radians(a), clockwise: false)
        wedge.closeSubpath()
        ctx.fill(wedge, with: .color(DrumBag.amber.opacity(0.16)))
        ctx.stroke(wedge, with: .color(DrumBag.amber.opacity(0.8)), lineWidth: 1.6 * u)
        let block = Path(roundedRect: CGRect(x: o.x + 8 * u, y: o.y + 42 * u, width: 12 * u, height: 16 * u), cornerRadius: 2 * u)
        ctx.fill(block, with: .color(DrumBag.ink.opacity(0.85)))
    }

    /// Aperture: the amber iris; its seven blades open wider at small f-numbers.
    static func iris(_ ctx: inout GraphicsContext, _ size: CGSize, f: Double) {
        let (u, o) = unit(size)
        let c = CGPoint(x: o.x + 50 * u, y: o.y + 50 * u)
        let open = CGFloat(6 + 30 * (1.4 / max(f, 0.1)).squareRoot())
        ctx.stroke(circle(c, 38 * u), with: .color(DrumBag.ink.opacity(0.7)), lineWidth: 2 * u)
        for k in 0..<7 {
            let t = Double(k) * 2 * Double.pi / 7
            var blade = Path()
            blade.move(to: CGPoint(x: c.x + open * CGFloat(cos(t)) * u, y: c.y + open * CGFloat(sin(t)) * u))
            blade.addLine(to: CGPoint(x: c.x + 38 * CGFloat(cos(t + 1.1)) * u, y: c.y + 38 * CGFloat(sin(t + 1.1)) * u))
            ctx.stroke(blade, with: .color(DrumBag.ink.opacity(0.5)), lineWidth: 1.4 * u)
        }
        let pupil = circle(c, open * u)
        ctx.fill(pupil, with: .color(DrumBag.amber.opacity(0.22)))
        ctx.stroke(pupil, with: .color(DrumBag.amber), lineWidth: 1.6 * u)
    }

    /// The f-number of an aperture item: "f2.8" (its value) or "f/2.8" (its name) → 2.8.
    static func fNumber(_ item: WheelItem) -> Double {
        for s in [item.value ?? "", item.name] {
            let digits = String(s.drop(while: { !$0.isNumber }))
            if let f = Double(digits) { return f }
        }
        return 4
    }
}

/// The drum's motion: the position (in items, unwrapped while looping), the momentum, the settle spring and the
/// trackpad / mouse-wheel routing. Runs a 60 Hz timer only while something moves.
@MainActor @Observable
final class RigDrumModel {
    /// The continuous position: 2.0 has item 2 in the band.
    var pos: Double
    /// The item in the band; changes once per detent passed (the click).
    private(set) var detent: Int
    /// The item the drum last came to rest on, and a counter that changes each time it does.
    private(set) var settled: Int
    private(set) var settleToken = 0

    @ObservationIgnored private(set) var count: Int
    @ObservationIgnored var reduceMotion = false

    private enum Motion {
        case idle
        case spring(target: Double, x: Double, v: Double)
        case fling(start: Double, target: Double, elapsed: Double)
        case scroll(lastEvent: CFTimeInterval)
        case drag
    }

    @ObservationIgnored private var motion: Motion = .idle
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var monitor: Any?
    /// The drum's frame in its window (SwiftUI global space: top-left origin) and that window. The scroll monitor only
    /// takes events inside it, so it can never swallow the app's scrolling (owner blocker 2026-11-07).
    @ObservationIgnored var hitFrame: CGRect = .null
    @ObservationIgnored private weak var hitWindow: NSWindow?
    @ObservationIgnored private var itemHeight: Double = 84
    @ObservationIgnored private var dragStart: Double = 0
    @ObservationIgnored private var dragMoved: Double = 0
    @ObservationIgnored private var history: [(t: CFTimeInterval, p: Double)] = []

    init(position: Double, count: Int) {
        pos = position
        self.count = count
        let i = RigDrumMath.nearest(position, count: count, loop: RigDrumMath.loops(count))
        detent = i
        settled = i
    }

    var loop: Bool { RigDrumMath.loops(count) }

    // MARK: Outside changes

    func setCount(_ n: Int, selected: Int) {
        if n == count && isMoving { return }
        stop()
        count = n
        let i = n > 0 ? min(max(selected, 0), n - 1) : 0
        pos = Double(i)
        detent = i
        settled = i
    }

    /// The selection changed outside the drum (Reset all, a preset): turn to it the short way round.
    func turn(to index: Int) {
        guard count > 0 else { return }
        switch motion {
        case .drag, .scroll: return
        default: break
        }
        let i = min(max(index, 0), count - 1)
        if !isMoving && RigDrumMath.nearest(pos, count: count, loop: loop) == i { return }
        settled = i  // already the selection: settling there commits nothing
        snap(to: pos + RigDrumMath.delta(item: i, pos: pos, count: count, loop: loop))
    }

    // MARK: Keyboard and accessibility

    func step(_ d: Int) {
        guard count > 0 else { return }
        let from: Double
        switch motion {
        case .spring(let target, _, _): from = target
        case .fling(_, let target, _): from = target
        default: from = RigDrumMath.roundHalfUp(pos)
        }
        snap(to: from + Double(d))
    }

    // MARK: Pointer

    func drag(translation dy: Double, itemHeight h: Double) {
        guard count > 0 else { return }
        if case .drag = motion {} else {
            stop()
            motion = .drag
            dragStart = pos
            dragMoved = 0
            history = []
        }
        dragMoved = max(dragMoved, abs(dy))
        setPos(RigDrumMath.clampSoft(dragStart - dy / h, count: count, loop: loop))
        let now = CACurrentMediaTime()
        history.append((t: now, p: pos))
        while history.count > 2, let first = history.first, now - first.t > 0.1 { history.removeFirst() }
    }

    /// Release: a click (barely moved) goes to the row under the pointer; a drag settles or flings with its velocity.
    func endDrag(tapOffset: Double, itemHeight h: Double) {
        guard count > 0 else { return }
        if case .drag = motion {} else { return }
        motion = .idle
        if dragMoved < 4 {
            // Which row was clicked: invert the drum's y = R·sin(angle).
            let r = h / (2 * sin(RigDrumMath.stepDegrees * .pi / 360))
            let s = min(max(tapOffset / r, -1), 1)
            let rows = asin(s) * 180 / .pi / RigDrumMath.stepDegrees
            snap(to: RigDrumMath.roundHalfUp(pos) + RigDrumMath.roundHalfUp(rows))
            return
        }
        var v = 0.0
        if let a = history.first, let b = history.last, b.t - a.t > 0 { v = (b.p - a.p) / (b.t - a.t) }
        let outside = !loop && (pos < 0 || pos > Double(count - 1))
        if outside || abs(v) < 0.8 { snap(to: RigDrumMath.roundHalfUp(pos)) } else { fling(v) }
    }

    // MARK: Trackpad and mouse wheel

    /// While the pointer is over the drum, scroll events turn it (and don't scroll the page behind).
    func hover(_ inside: Bool, itemHeight h: Double) {
        itemHeight = h
        if inside {
            guard monitor == nil else { return }
            hitWindow = NSApp.keyWindow ?? NSApp.mainWindow
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let model = self else { return e }
                // Only scrolls over this drum, in its own visible window. Anything else passes through, and a monitor
                // left behind (the drum went away without a hover-out, e.g. a sheet closed under the pointer) removes itself.
                let owns = MainActor.assumeIsolated { model.owns(e) }
                guard owns else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { model.removeMonitor() } }
                    return e
                }
                let dy = Double(e.scrollingDeltaY), dx = Double(e.scrollingDeltaX)
                guard abs(dy) >= abs(dx) else { return e }
                let precise = e.hasPreciseScrollingDeltas
                let momentum = !e.momentumPhase.isEmpty
                let ended = e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled)
                MainActor.assumeIsolated { model.scroll(dy: dy, precise: precise, momentum: momentum, ended: ended) }
                return nil
            }
        } else {
            removeMonitor()
        }
    }

    private func scroll(dy: Double, precise: Bool, momentum: Bool, ended: Bool) {
        guard count > 0 else { return }
        if ended {
            settleScroll()
            return
        }
        if !precise {
            // A mouse wheel notch is one detent.
            guard dy != 0 else { return }
            step(dy > 0 ? -1 : 1)
            return
        }
        if reduceMotion && momentum { return }  // no momentum under Reduce Motion
        switch motion {
        case .scroll: break
        default: stop()
        }
        motion = .scroll(lastEvent: CACurrentMediaTime())
        setPos(RigDrumMath.clampSoft(pos - dy / itemHeight * 0.9, count: count, loop: loop))
        startTimer()
    }

    private func settleScroll() {
        guard case .scroll = motion else { return }
        motion = .idle
        snap(to: RigDrumMath.roundHalfUp(pos))
    }

    // MARK: Motion

    private var isMoving: Bool {
        if case .idle = motion { return false }
        return true
    }

    /// Settle on a detent with the critically damped spring (at once under Reduce Motion).
    private func snap(to target: Double, velocity: Double = 0) {
        guard count > 0 else { return }
        let t = loop ? target : min(max(target, 0), Double(count - 1))
        if reduceMotion {
            stop()
            setPos(t)
            finish()
            return
        }
        motion = .spring(target: t, x: pos - t, v: velocity)
        startTimer()
    }

    private func fling(_ v: Double) {
        if reduceMotion {
            snap(to: RigDrumMath.roundHalfUp(pos))
            return
        }
        motion = .fling(start: pos, target: RigDrumMath.flingTarget(pos: pos, velocity: v, count: count, loop: loop), elapsed: 0)
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let model = self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { model.tick() }
        }
        // .common so the drum keeps moving while AppKit tracks the mouse or the trackpad.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        switch motion {
        case .idle, .drag:
            stopTimer()
        case .scroll(let last):
            if now - last > 0.12 { settleScroll() }
        case .fling(let start, let target, let elapsed):
            let e = elapsed + dt
            let p = RigDrumMath.decay(start: start, target: target, elapsed: e)
            setPos(p)
            if abs(target - p) < 0.06 {
                // Hand over to the spring for the last bit, carrying the decay's speed.
                motion = .spring(target: target, x: p - target, v: (target - p) / 0.325)
            } else {
                motion = .fling(start: start, target: target, elapsed: e)
            }
        case .spring(let target, let x, let v):
            let s = RigDrumMath.springStep(x: x, v: v, dt: dt)
            if RigDrumMath.settled(x: s.x, v: s.v) {
                setPos(target)
                finish()
            } else {
                setPos(target + s.x)
                motion = .spring(target: target, x: s.x, v: s.v)
            }
        }
    }

    private func setPos(_ p: Double) {
        pos = p
        let i = RigDrumMath.nearest(p, count: count, loop: loop)
        if i != detent { detent = i }
    }

    /// At rest: keep the looping position small, then report where the drum stopped.
    private func finish() {
        motion = .idle
        stopTimer()
        let i = RigDrumMath.nearest(pos, count: count, loop: loop)
        pos = Double(i)
        detent = i
        settled = i
        settleToken &+= 1
    }

    private func stop() {
        motion = .idle
        stopTimer()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// Whether a scroll event is over this drum: same window, window on screen, pointer inside the drum's frame.
    private func owns(_ e: NSEvent) -> Bool {
        guard let w = hitWindow, e.window === w, w.isVisible, let content = w.contentView, !hitFrame.isNull, !hitFrame.isEmpty else { return false }
        let p = content.convert(e.locationInWindow, from: nil)
        let top = content.isFlipped ? p.y : content.bounds.height - p.y
        return hitFrame.contains(CGPoint(x: p.x, y: top))
    }

    func tearDown() {
        removeMonitor()
        if isMoving {
            // Land where it was heading, so a closed picker doesn't lose the pick.
            switch motion {
            case .spring(let target, _, _), .fling(_, let target, _): setPos(target)
            default: setPos(RigDrumMath.roundHalfUp(pos))
            }
            finish()
        }
        stopTimer()
    }

    // MARK: The click

    private static let click: NSSound? = {
        let s = NSSound(named: "Tink")
        s?.volume = 0.15
        return s
    }()

    static func playClick() {
        guard let s = click else { return }
        if s.isPlaying { s.stop() }
        s.play()
    }
}
