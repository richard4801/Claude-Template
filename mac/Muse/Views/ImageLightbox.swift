import MuseCore
import SwiftUI

/// One image in the lightbox: a short label ("Front") and the image.
struct LightboxItem: Hashable {
    var label: String
    var ref: ImageRef
}

/// A full-window image viewer (owner request 2026-11-08: view a new outfit full size). The image fits the window; zoom
/// with a pinch, double-click, the − / + buttons or the − / = keys (0 fits again); drag to pan when zoomed. ← and → move
/// through the set, Escape closes. Media stays the hero: a dark scrim, quiet white controls on it.
/// The image is laid out at its zoomed size (not scaled up), so MuseImage decodes it at the size it's drawn: sharp at 4×.
struct ImageLightbox: View {
    @Environment(\.theme) private var t
    var items: [LightboxItem]
    @Binding var index: Int?
    /// The images' width ÷ height (outfit angles are 3:4).
    var ratio: CGFloat = 0.75

    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?

    static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4]

    var body: some View {
        if let i = index, items.indices.contains(i) {
            let item = items[i]
            ZStack {
                Color.black.opacity(0.9).ignoresSafeArea()
                    .onTapGesture { close() }
                GeometryReader { g in
                    let area = CGSize(width: max(1, g.size.width - 160), height: max(1, g.size.height - 140))
                    let fit = Self.fitSize(ratio: ratio, in: area)
                    let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
                    let o = Self.clamp(offset, image: size, view: g.size)
                    MuseImage(ref: item.ref)
                        .frame(width: size.width, height: size.height)
                        .offset(o)
                        .frame(width: g.size.width, height: g.size.height)
                        .contentShape(Rectangle())
                        .gesture(pan(image: size, view: g.size))
                        .simultaneousGesture(pinch)
                        .onTapGesture(count: 2) { setZoom(zoom > 1 ? 1 : 2) }
                        .accessibilityElement()
                        .accessibilityLabel("\(item.label), \(i + 1) of \(items.count)")
                        .accessibilityAddTraits(.isImage)
                }
                .clipped()
                chrome(i, item)
            }
            .transition(.opacity)
            .onChange(of: index) { _, _ in setZoom(1) }
        }
    }

    // MARK: Controls

    private func chrome(_ i: Int, _ item: LightboxItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                Text(item.label).scaled(t.scale.heading, .white)
                Text("\(i + 1) of \(items.count)").monospacedDigit().scaled(t.scale.caption, .white.opacity(0.7))
                Spacer(minLength: Space.s3)
                LightboxButton(icon: "xmark", help: "Close (Esc)") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Space.s5)
            .padding(.top, Space.s4)
            Spacer(minLength: 0)
            HStack {
                LightboxButton(icon: "chevron.left", help: "Previous (←)", size: 40, off: items.count < 2) { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer(minLength: 0)
                LightboxButton(icon: "chevron.right", help: "Next (→)", size: 40, off: items.count < 2) { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(.horizontal, Space.s5)
            Spacer(minLength: 0)
            HStack(spacing: Space.s2) {
                LightboxButton(icon: "minus", help: "Zoom out (−)", off: zoom <= 1) { stepZoom(-1) }
                    .keyboardShortcut("-", modifiers: [])
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().scaled(t.scale.caption, .white)
                    .frame(width: 52)
                LightboxButton(icon: "plus", help: "Zoom in (=)", off: zoom >= Self.zoomSteps.last!) { stepZoom(1) }
                    .keyboardShortcut("=", modifiers: [])
                Button("Fit") { setZoom(1) }
                    .buttonStyle(.plain)
                    .typeStep(t.scale.label)
                    .foregroundStyle(zoom == 1 ? .white.opacity(0.4) : .white)
                    .frame(height: 28)
                    .padding(.horizontal, Space.s2)
                    .disabled(zoom == 1)
                    .keyboardShortcut("0", modifiers: [])
                    .help("Fit to the window (0)")
            }
            .padding(.horizontal, Space.s3)
            .background(Capsule().fill(.white.opacity(0.12)))
            .padding(.bottom, Space.s5)
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let start = pinchStart ?? zoom
                if pinchStart == nil { pinchStart = zoom }
                zoom = min(Self.zoomSteps.last!, max(1, start * v.magnification))
            }
            .onEnded { _ in
                pinchStart = nil
                if zoom < 1.05 { setZoom(1) }
            }
    }

    private func pan(image: CGSize, view: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard zoom > 1 else { return }
                let start = dragStart ?? Self.clamp(offset, image: image, view: view)
                if dragStart == nil { dragStart = start }
                offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
            }
            .onEnded { _ in
                offset = Self.clamp(offset, image: image, view: view)
                dragStart = nil
            }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { index = nil }
    }

    private func step(_ d: Int) {
        guard let i = index, items.count > 1 else { return }
        index = (i + d + items.count) % items.count
    }

    private func stepZoom(_ d: Int) {
        let steps = Self.zoomSteps
        let next = d > 0 ? steps.first { $0 > zoom + 0.01 } : steps.last { $0 < zoom - 0.01 }
        setZoom(next ?? (d > 0 ? steps.last! : 1))
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = z
            if z == 1 { offset = .zero }
        }
    }

    // MARK: Geometry

    /// The largest size with this width ÷ height that fits the area.
    static func fitSize(ratio: CGFloat, in area: CGSize) -> CGSize {
        let w = min(area.width, area.height * ratio)
        return CGSize(width: w, height: w / ratio)
    }

    /// Keeps the zoomed image covering the view where it can: no pan past its edges, centred on an axis it doesn't fill.
    static func clamp(_ o: CGSize, image: CGSize, view: CGSize) -> CGSize {
        let mx = max(0, (image.width - view.width) / 2), my = max(0, (image.height - view.height) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }
}

/// A round icon button on the dark scrim: white glyph, a faint disc, brighter on hover.
private struct LightboxButton: View {
    var icon: String
    var help: String
    var size: CGFloat = 32
    var off = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Ph(icon, size > 32 ? 18 : 14).foregroundStyle(.white.opacity(off ? 0.35 : 1))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hover && !off ? 0.22 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(off)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
