import MuseCore
import SwiftUI

/// The Claude panel as a floating panel over the page (owner, 2026-11-12; plans/design/claude-panel/float-*.png): rounded,
/// a soft shadow, and the living edge that glows with Claude's orb. It never reflows the page. Moved by its header,
/// resized from the lower-left corner (it hangs from the top-right), and its place and size are remembered.
struct FloatingClaudePanel: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Distance from the window's right and top edges, the width, and the height (0: the window's height less margins).
    @AppStorage("claudePanel.right") private var right: Double = Double(Space.s4)
    @AppStorage("claudePanel.top") private var top: Double = Double(Space.s4)
    @AppStorage("claudePanel.width") private var width: Double = 400
    @AppStorage("claudePanel.height") private var height: Double = 0
    @State private var moving: CGSize = .zero
    @State private var sizing: CGSize = .zero

    static let minSize = CGSize(width: 340, height: 420)
    static let margin: CGFloat = Space.s4

    var body: some View {
        GeometryReader { g in
            let f = frame(in: g.size)
            let radius = t.radii.container + 4
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            OneClaudePanel(onDrag: { d, ended in
                if ended { commitMove(d, in: g.size) } else { moving = d }
            })
            .frame(width: f.width, height: f.height)
            .background(t.roles.canvas)
            .clipShape(shape)
            .overlay(ClaudeLivingEdge(cornerRadius: radius))
            .overlay(alignment: .bottomLeading) { resizeHandle(in: g.size) }
            // A soft shadow lifts it off the page (the one `float` shadow; dark themes get a deeper, neutral one).
            .shadow(color: .black.opacity(t.isDark ? 0.55 : 0.18), radius: 32, y: 16)
            .position(x: g.size.width - f.right - f.width / 2, y: f.top + f.height / 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: g.size)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude")
    }

    /// The panel's frame now (stored values, the drag in progress, kept inside the window).
    private func frame(in s: CGSize) -> (right: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
        let m = Self.margin
        var w = CGFloat(width) - sizing.width
        var h = (height > 0 ? CGFloat(height) : s.height - 2 * m) + sizing.height
        w = min(max(w, Self.minSize.width), max(Self.minSize.width, s.width - 2 * m))
        h = min(max(h, Self.minSize.height), max(Self.minSize.height, s.height - 2 * m))
        var r = CGFloat(right) - moving.width
        var y = CGFloat(top) + moving.height
        r = min(max(r, m), max(m, s.width - w - m))
        y = min(max(y, m), max(m, s.height - h - m))
        return (r, y, w, h)
    }

    private func commitMove(_ d: CGSize, in s: CGSize) {
        moving = d
        let f = frame(in: s)
        right = Double(f.right); top = Double(f.top)
        moving = .zero
    }

    /// The lower-left corner: drag to resize (left widens, down makes it taller). Double-click returns to full height.
    private func resizeHandle(in s: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(t.roles.ink2.opacity(0.7))
            .rotationEffect(.degrees(90))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { sizing = CGSize(width: $0.translation.width, height: $0.translation.height) }
                .onEnded { v in
                    sizing = CGSize(width: v.translation.width, height: v.translation.height)
                    let f = frame(in: s)
                    width = Double(f.width); height = Double(f.height)
                    sizing = .zero
                })
            .onTapGesture(count: 2) { height = 0 }
            .help("Drag to resize. Double-click for full height.")
            .accessibilityLabel("Resize the Claude panel")
    }
}
