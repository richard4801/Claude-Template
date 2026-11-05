import AppKit
import MuseCore
import SwiftUI

// Small controls shared by the Edit suite screens (E1–E4), drawn with the app theme. Every icon-only control carries an
// accessibility label (VoiceOver) as well as a tooltip.

/// The dark stage behind the preview (E1/E3).
let suiteStage = Color(hex: 0x1A1816)

/// An icon-only button: tooltip + VoiceOver label.
struct SuiteIconButton: View {
    @Environment(\.theme) private var t
    var systemName: String
    var label: String
    var on = false
    var disabled = false
    var size: CGFloat = 30
    var tint: Color?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(disabled ? t.muted.opacity(0.45) : (on ? t.accent : (tint ?? t.ink)))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(hover && !disabled ? t.surface2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
        .onHover { hover = $0 }
    }
}

/// Upper-case section label ("STYLE", "POSITION").
struct SuiteLabel: View {
    @Environment(\.theme) private var t
    var text: String
    var trailing: String?
    init(_ text: String, trailing: String? = nil) { self.text = text; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text.uppercased()).font(t.mono(11, .medium)).tracking(1.1).foregroundStyle(t.ink)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(t.body(12)).foregroundStyle(t.muted) }
        }
    }
}

/// A row of boxed choices (ratio, resolution, format…): the chosen one filled with ink.
struct SuiteSeg<T: Hashable>: View {
    @Environment(\.theme) private var t
    var options: [(T, String)]
    var selection: T?
    var mono = true
    var height: CGFloat = 30
    var action: (T) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (v, l) = options[i]
                let on = v == selection
                Button { action(v) } label: {
                    Text(mono ? l.uppercased() : l)
                        .font(mono ? t.mono(11.5, on ? .semibold : .regular) : t.body(13, on ? .semibold : .regular))
                        .tracking(mono ? 0.8 : 0)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(on ? t.bg : t.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .padding(.horizontal, 6)
                        .background(Rectangle().fill(on ? t.ink : t.surface))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if i < options.count - 1 { Rectangle().fill(t.line).frame(width: 1, height: height) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 6).strokeBorder(t.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: t.isA ? 0 : 6))
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
                Text(label.uppercased()).font(t.mono(11)).tracking(1).foregroundStyle(t.ink)
                Spacer(minLength: 4)
                Text(format(draft ?? value)).font(t.mono(11.5)).foregroundStyle(t.ink)
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
                Text(title).font(t.body(13.5, .semibold)).foregroundStyle(t.ink)
                if let hint { Text(hint).font(t.body(12)).foregroundStyle(t.muted) }
            }
            Spacer(minLength: 6)
            if let trailingNote { Text(trailingNote).font(t.mono(11)).foregroundStyle(t.muted) }
            if busy { ProgressView().controlSize(.small) }
            MToggle(isOn: Binding(get: { isOn }, set: { action($0) }))
                .accessibilityLabel(title)
                .accessibilityValue(isOn ? "On" : "Off")
                .disabled(busy)
        }
    }
}

/// A small text button with a border (Ripple, Cut silences…), optionally filled.
struct SuiteToolButton: View {
    @Environment(\.theme) private var t
    var title: String
    var icon: String?
    var filled = false
    var accent = false
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11.5, weight: .semibold)) }
                Text(title).font(t.body(12.5, .medium)).lineLimit(1)
            }
            .foregroundStyle(disabled ? t.muted.opacity(0.5) : (accent ? t.accentInk : filled ? t.bg : t.ink))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: t.isA ? 0 : 6).fill(accent ? t.accentFill : (filled ? t.ink : t.surface)))
            .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 6).strokeBorder(filled || accent ? .clear : t.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// A divider line in the theme's colour.
struct SuiteRule: View {
    @Environment(\.theme) private var t
    var vertical = false
    var body: some View {
        Rectangle().fill(t.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
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

/// "MUST"-style corner card title used by the inspector panels (E2): a title row and the panel's content.
struct SuitePanel<Content: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var trailing: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(t.body(14.5, .semibold)).foregroundStyle(t.ink)
                Spacer()
                if let trailing { Text(trailing).font(t.body(12)).foregroundStyle(t.muted) }
            }
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { SuiteRule() }
    }
}
