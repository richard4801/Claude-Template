import AppKit
import QuartzCore
import MuseCore
import SwiftUI

// The drum wheel for every hardware choice in the rig (design/drum-wheels-prototype.html, styled like
// plans/design-direction/picker-b.png). The maths lives in MuseCore (Suite/RigDrumMath.swift) and is tested there; this
// file only draws the drum and turns the pointer, trackpad and keyboard into positions.

/// One vertical drum: its label above, five rows with the pick centred in one selection band, and the pick's name and
/// caption under it.
///
/// ```swift
/// let cams = ComposerWheels.cameras(c)
/// RigDrum(label: "Camera", items: cams, selected: Wheel.index(of: s.body, in: cams, options: c.bodies)) { item in
///     settings.body = item.value          // nil is Auto
/// }
/// ```
/// - `items`: Auto (value nil) is drawn as the aperture mark on a disc; others draw their `render` (`hardware/<render>`)
///   or `preview` poster, or, with `face: .focal` / `.aperture`, their number ("50", "2.8").
/// - `selected`: the index in `items`. Change it from outside (Reset all, a preset) and the drum turns to it.
/// - `onSelect` runs once when the drum comes to rest on a different item, never for the items it passes on the way.
/// - Drums with 5 or more items loop; shorter ones stop and rubber-band at the ends.
/// - The camera bag is always dark: put drums on `RigDrum.Bag.raised` (the drum draws no panel of its own). Several
///   drums side by side with no spacing make one continuous selection band, as in Camera → Setup.
struct RigDrum: View {
    /// How an item that isn't Auto is drawn.
    enum Face { case render, focal, aperture }

    /// The camera bag's palette (design-direction §9, design/direction/render.py BAG), the same in every theme.
    enum Bag {
        static let raised = Color(hex: 0x141414)
        static let field = Color(hex: 0x1E1F21)
        static let ink = Color(hex: 0xECEAE5)
        static let ink2 = Color(hex: 0xA9A6A0)
        static let hairline = Color(hex: 0x2C3033)
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
    let onSelect: (WheelItem) -> Void

    /// One detent (row) and the picture inside it.
    static let rowHeight: CGFloat = 68
    static let picture: CGFloat = 64
    static let rows: CGFloat = 5

    init(label: String, items: [WheelItem], selected: Int, face: Face = .render, onSelect: @escaping (WheelItem) -> Void) {
        self.label = label
        self.items = items
        self.selected = selected
        self.face = face
        self.onSelect = onSelect
        let n = items.count
        let start = n > 0 ? min(max(selected, 0), n - 1) : 0
        _model = State(initialValue: RigDrumModel(position: Double(start), count: n))
    }

    private var count: Int { items.count }
    private var near: Int { RigDrumMath.nearest(model.pos, count: count, loop: model.loop) }
    private var current: WheelItem? { items.indices.contains(near) ? items[near] : nil }

    var body: some View {
        VStack(spacing: 8) {
            Text(label).font(t.body(13)).foregroundStyle(Bag.ink2).lineLimit(1)
            drum
            VStack(spacing: 2) {
                Text(current?.name ?? " ").font(t.body(14, .medium)).foregroundStyle(Bag.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(current?.caption ?? " ").font(t.body(13)).foregroundStyle(Bag.ink2)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 36, alignment: .top)
            }
            .padding(.horizontal, 6)
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

    private var drum: some View {
        let h = Self.rowHeight
        let loop = model.loop
        let pos = model.pos
        let band = near
        return ZStack {
            // The one selection mark: a hairline band with a faint field tint.
            Rectangle().fill(Bag.field.opacity(0.6))
                .overlay(alignment: .top) { Rectangle().fill(Bag.hairline).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Bag.hairline).frame(height: 1) }
                .frame(height: h)
            ForEach(Array(items.indices), id: \.self) { i in
                let look = RigDrumMath.look(delta: RigDrumMath.delta(item: i, pos: pos, count: count, loop: loop),
                                            itemHeight: Double(h), selected: i == band)
                if look.visible {
                    itemFace(items[i])
                        .frame(height: h)
                        .scaleEffect(CGFloat(look.scale))
                        .rotation3DEffect(.degrees(look.rotationDegrees), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                        .colorMultiply(Color(white: look.brightness))
                        .opacity(look.opacity)
                        .offset(y: CGFloat(look.y))
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: h * Self.rows)
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                   .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
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
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(t.accent, lineWidth: 2)
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

    @ViewBuilder private func itemFace(_ item: WheelItem) -> some View {
        let side = Self.picture
        if item.value == nil {
            // Auto: the aperture mark on a field disc, the size of a render.
            ZStack {
                Circle().fill(Bag.field)
                Ph("aperture", 26).foregroundStyle(Bag.ink2)
            }
            .frame(width: side, height: side)
        } else if face == .focal || face == .aperture {
            Text(numeral(item)).font(t.body(26, .semibold)).monospacedDigit().foregroundStyle(Bag.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: side * 1.6, height: side)
        } else if let render = item.render {
            HardwareImage(name: render).frame(width: side, height: side).mask { Self.softEdge(side) }
        } else if let img = PreviewFiles.image(item.preview) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: side, height: side).clipped().mask { Self.softEdge(side) }
        } else {
            Text(item.name).font(t.body(14, .medium)).foregroundStyle(Bag.ink)
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                .frame(width: side * 1.8, height: side)
        }
    }

    /// The renders sit unboxed on the bag: their corners fade out.
    private static func softEdge(_ side: CGFloat) -> RadialGradient {
        RadialGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                       center: .center, startRadius: 0, endRadius: side * 0.72)
    }

    /// "50" for 50 mm, "2.8" for f/2.8.
    private func numeral(_ item: WheelItem) -> String {
        if face == .aperture {
            return item.name.hasPrefix("f/") ? String(item.name.dropFirst(2)) : item.name
        }
        return item.value ?? item.name
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
    @ObservationIgnored private var itemHeight: Double = 68
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let model = self else { return e }
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
