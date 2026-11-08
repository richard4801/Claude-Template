import AppKit
import MuseCore
import SwiftUI

// Small controls shared by the Edit suite screens (E1–E4), drawn with the app theme. Every icon-only control carries an
// accessibility label (VoiceOver) as well as a tooltip.

/// The dark stage behind the preview (E1/E3).
let suiteStage = Color(hex: 0x1A1816)

/// The viewer's tone behind the picture (plans/edit-layout.md): near-black in every theme.
extension Theme {
    var editViewer: Color {
        switch id {
        case .c: return Color(hex: 0x1C1E21)
        case .a: return Color(hex: 0x141210)
        case .b: return Color(hex: 0x000000)
        case .d: return Color(hex: 0x111111)
        }
    }
}

/// An icon-only button: tooltip + VoiceOver label. 32 pt target by default (28 pt minimum), Phosphor at 16–20 pt.
struct SuiteIconButton: View {
    @Environment(\.theme) private var t
    var systemName: String
    var label: String
    var on = false
    var disabled = false
    var size: CGFloat = 32
    var tint: Color?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Ph(systemName, min(16, max(12, size * 0.5)))
                .foregroundStyle(disabled ? t.roles.ink2.opacity(0.45) : (on ? t.roles.accent : (tint ?? t.roles.ink)))
                .frame(width: max(28, size), height: max(28, size))
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover && !disabled ? t.roles.field : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hover = $0 }
    }
}

/// A section title in `heading` ("Style", "Hooks"), with an optional `caption` note on the right.
struct SuiteLabel: View {
    @Environment(\.theme) private var t
    var text: String
    var trailing: String?
    init(_ text: String, trailing: String? = nil) { self.text = text; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1) }
        }
    }
}

/// A segmented control (ratio, resolution, format…) on the `field` track; the chosen segment is `raised`.
struct EditSeg<T: Hashable>: View {
    @Environment(\.theme) private var t
    var options: [(T, String)]
    var selection: T?
    var mono = true // kept for old call sites: sentence case in the text face everywhere (design direction)
    var height: CGFloat = 32
    var small = false
    var action: (T) -> Void

    var body: some View {
        let r = t.roles
        let inner = RoundedRectangle(cornerRadius: max(0, t.radii.control - 2), style: .continuous)
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (v, l) = options[i]
                let on = v == selection
                Button { action(v) } label: {
                    Text(l)
                        .font(small ? t.scale.caption.font : t.scale.label.font)
                        .lineLimit(1)
                        .fitProbe("segment \(l)")
                        .foregroundStyle(on ? r.ink : r.ink2)
                        .padding(.horizontal, small ? Space.s2 + 2 : Space.s3)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(24, height - 4))
                        .background(inner.fill(on ? (t.isDark ? r.hairline : r.raised) : .clear))
                        .overlay(inner.strokeBorder(r.selection, lineWidth: on && t.isD ? 2 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(r.field))
    }
}

/// A labelled slider (label and value above, the track below). Dragging shows the value; the change is applied once, when
/// the drag ends, so one drag is one undo step.
struct SuiteSlider: View {
    @Environment(\.theme) private var t
    var label: String
    var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var onCommit: (Double) -> Void
    @State private var draft: Double?

    init(_ label: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String, onCommit: @escaping (Double) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.format = format
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                Spacer(minLength: 4)
                Text(format(draft ?? value)).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
            }
            Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range, onEditingChanged: { editing in
                if !editing, let d = draft {
                    draft = nil
                    if abs(d - value) > 1e-9 { onCommit(d) }
                }
            })
            .controlSize(.small)
            .tint(t.accent)
            .accessibilityLabel(label)
            .accessibilityValue(format(draft ?? value))
        }
    }
}

/// Title + hint + a switch.
struct SuiteToggleRow: View {
    @Environment(\.theme) private var t
    var title: String
    var hint: String?
    var isOn: Bool
    var busy = false
    var trailingNote: String?
    var action: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                if let hint { Text(hint).font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
            }
            Spacer(minLength: 6)
            if let trailingNote { Text(trailingNote).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2) }
            if busy { ProgressView().controlSize(.small) }
            MToggle(isOn: Binding(get: { isOn }, set: { action($0) }))
                .accessibilityLabel(title)
                .accessibilityValue(isOn ? "On" : "Off")
                .disabled(busy)
        }
    }
}

/// A text button with an optional icon (Ripple, Cut silences, Import…): `field` by default, `filled` (ink) when a toggle is
/// on, `accent` for the one action, `plain` without a fill. 32 pt tall, `label` type, Phosphor at 18–20 pt.
struct SuiteToolButton: View {
    @Environment(\.theme) private var t
    var title: String
    var icon: String?
    var filled = false
    var accent = false
    var disabled = false
    var plain = false
    /// Icon only (the title becomes the tooltip and the accessibility label).
    var iconOnly = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let r = t.roles
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        let bg: Color = accent ? r.action : filled ? r.ink : plain ? (hover && !disabled ? r.field : .clear) : r.field
        let fg: Color = disabled ? r.ink2.opacity(0.5) : accent ? r.onAction : filled ? r.canvas : r.ink
        let button = Button(action: action) {
            HStack(spacing: Space.s2) {
                if let icon { Ph(icon, 15) }
                if !iconOnly { Text(title).font(t.scale.label.font).lineLimit(1).fitProbe(title) }
            }
            .foregroundStyle(fg)
            .padding(.horizontal, iconOnly ? 0 : Space.s3)
            .frame(minWidth: iconOnly ? 32 : nil)
            .frame(height: 32)
            .background(shape.fill(bg))
            .overlay(shape.strokeBorder(r.ink, lineWidth: accent && t.isD ? 2 : 0))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
        if iconOnly {
            button.help(title).accessibilityLabel(title)
        } else {
            button
        }
    }
}

/// A hairline in the theme's colour.
struct SuiteRule: View {
    @Environment(\.theme) private var t
    var vertical = false
    var body: some View {
        Rectangle().fill(t.roles.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A colour swatch that opens the system colour picker (#RRGGBB in and out).
struct SuiteSwatch: View {
    @Environment(\.theme) private var t
    var hex: String
    var label: String
    var onPick: (String) -> Void

    var body: some View {
        ColorPicker(selection: Binding(get: { Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0) }, set: { onPick(SuiteSwatch.hex($0)) }),
                    supportsOpacity: false) { EmptyView() }
            .labelsHidden()
            .frame(width: 34, height: 30)
            .help(label)
            .accessibilityLabel(label)
    }

    static func hex(_ c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int((ns.redComponent * 255).rounded()), g = Int((ns.greenComponent * 255).rounded()), b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

/// An inspector group (E2): a `heading` title and its settings, grouped by space (no box, no rule).
struct EditPanel<Content: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text(title).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Spacer()
                if let trailing { Text(trailing).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1) }
            }
            content()
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
    }
}

// MARK: Fit probe (review mode)

extension View {
    /// Review mode only (`MUSE_SNAPSHOT_DIR`): reports this single-line label when it's drawn narrower than its text needs,
    /// i.e. truncated. The fit check writes a CUT line for each (SnapshotRunner.editLayoutShots). A no-op otherwise.
    @ViewBuilder func fitProbe(_ name: String) -> some View {
        if SnapshotRunner.probing { modifier(FitProbe(name: name)) } else { self }
    }
}

/// Measures the label as drawn and its ideal width (a hidden fixed-size copy).
struct FitProbe: ViewModifier {
    let name: String
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { SnapshotRunner.fitNote(id, name, drawn: g.size.width) }
                    .onChange(of: g.size.width) { _, w in SnapshotRunner.fitNote(id, name, drawn: w) }
            })
            .background(
                content.fixedSize().hidden().allowsHitTesting(false).accessibilityHidden(true)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { SnapshotRunner.fitNote(id, name, ideal: g.size.width) }
                            .onChange(of: g.size.width) { _, w in SnapshotRunner.fitNote(id, name, ideal: w) }
                    })
            )
            .onDisappear { SnapshotRunner.fitProbes[id] = nil }
    }
}
