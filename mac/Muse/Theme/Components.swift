import AppKit
import SwiftUI

// Shared controls, styled per theme. The CSS class each one mirrors is noted (desktop.css).

// MARK: Surfaces and shadows

enum ShadowKind { case none, card, button, small }

struct ThemeShadow: ViewModifier {
    @Environment(\.theme) private var t
    var kind: ShadowKind
    var radius: CGFloat

    func body(content: Content) -> some View {
        switch (t.id, kind) {
        case (_, .none):
            content
        case (.c, _):
            let d: CGFloat = kind == .card ? 8 : kind == .button ? 5 : 3
            content
                .shadow(color: Color(red: 120 / 255, green: 105 / 255, blue: 85 / 255).opacity(0.16), radius: d * 1.2, x: d, y: d)
                .shadow(color: .white.opacity(0.8), radius: d, x: -d * 0.75, y: -d * 0.75)
        case (.d, _):
            let d: CGFloat = kind == .card ? 5 : kind == .button ? 3 : 2
            content.background(RoundedRectangle(cornerRadius: radius).fill(Color(hex: 0x111111)).offset(x: d, y: d))
        default:
            content
        }
    }
}

/// `.card`, `.kpi`, `.list`, `.ofset`…: fill, border and the theme's shadow.
struct Surface: ViewModifier {
    @Environment(\.theme) private var t
    var fill: Color?
    var radius: CGFloat?
    var border = true
    var shadow: ShadowKind = .card

    func body(content: Content) -> some View {
        let rad = radius ?? t.cardRadius
        let shape = RoundedRectangle(cornerRadius: rad, style: .continuous)
        let bgFill: Color = fill ?? (t.isA ? .clear : t.isB ? Color(hex: 0x141618) : t.surface)
        content
            .background(shape.fill(bgFill))
            .overlay(shape.strokeBorder(t.isC || !border ? Color.clear : t.strongLine, lineWidth: t.lineWidth))
            .modifier(ThemeShadow(kind: shadow, radius: rad))
    }
}

extension View {
    func surface(_ fill: Color? = nil, radius: CGFloat? = nil, border: Bool = true, shadow: ShadowKind = .card) -> some View {
        modifier(Surface(fill: fill, radius: radius, border: border, shadow: shadow))
    }

    func card(_ padding: CGFloat = 18, fill: Color? = nil) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .topLeading).surface(fill)
    }

    @ViewBuilder func `if`<V: View>(_ cond: Bool, _ transform: (Self) -> V) -> some View {
        if cond { transform(self) } else { self }
    }
}

// MARK: Type

struct H1: View {
    @Environment(\.theme) private var t
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(t.headingsUppercase ? text.uppercased() : text)
            .font(t.h1)
            .tracking(t.isD ? -1.2 : t.isC ? -0.8 : t.isB ? 0.9 : 0)
            .foregroundStyle(t.ink)
            .lineSpacing(t.isA ? -12 : 0)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct H2: View {
    @Environment(\.theme) private var t
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(t.headingsUppercase ? text.uppercased() : text).font(t.h2).foregroundStyle(t.ink).tracking(t.isA ? 0.3 : t.isB ? 0.5 : 0)
    }
}

struct Eyebrow: View {
    @Environment(\.theme) private var t
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        (t.isA ? Text("№ ").foregroundColor(t.accent) : Text(""))
            + Text(text.uppercased()).foregroundColor(t.muted)
    }
}

extension Eyebrow {
    func styled() -> some View { modifier(EyebrowFont()) }
}

private struct EyebrowFont: ViewModifier {
    @Environment(\.theme) private var t
    func body(content: Content) -> some View { content.font(t.mono(11)).tracking(1.3) }
}

/// `.lbl`
struct Lbl: View {
    @Environment(\.theme) private var t
    var text: String
    var color: Color?
    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased()).font(t.label).tracking(t.isD ? 0.7 : 0.9).foregroundStyle(color ?? t.muted)
    }
}

struct Muted: View {
    @Environment(\.theme) private var t
    var text: String
    var size: CGFloat
    init(_ text: String, size: CGFloat = 12) {
        self.text = text
        self.size = size
    }
    var body: some View { Text(text).font(t.body(size)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true) }
}

/// `.ph`: eyebrow + h1 with actions on the right.
struct PageHeader<Trailing: View>: View {
    var eyebrow: String
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(eyebrow).styled()
                H1(title)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 22)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// `.sec-h`: a section title with something on the right; Editorial puts a rule above it.
struct SectionHeader<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var top: CGFloat = 26
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 10) {
            if t.isA { Rectangle().fill(t.ink).frame(height: 1) }
            HStack(alignment: .firstTextBaseline) {
                H2(title)
                Spacer()
                trailing()
            }
        }
        .padding(.top, top)
        .padding(.bottom, 12)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, top: CGFloat = 26) {
        self.init(title: title, top: top) { EmptyView() }
    }
}

// MARK: Buttons

enum ButtonKind { case primary, secondary }
enum ButtonSize { case small, regular, big }

struct MuseButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var size: ButtonSize = .regular
    var off = false
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size, off: off, fill: fill)
    }

    private struct StyledButton: View {
        @Environment(\.theme) private var t
        let configuration: Configuration
        let kind: ButtonKind
        let size: ButtonSize
        let off: Bool
        let fill: Bool
        @State private var hover = false

        var body: some View {
            let h: CGFloat = size == .small ? 32 : size == .big ? 50 : 40
            let radius: CGFloat = t.isA ? 0 : t.isC ? h / 2 : t.isD ? 12 : t.r
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let pri = kind == .primary
            let bg: Color = pri ? t.cta : t.surface
            let fg: Color = pri ? t.ctaInk : t.ink
            let pressed = configuration.isPressed && !off
            configuration.label
                .font(font)
                .tracking(t.isA ? 1 : t.isB && pri ? 1.6 : 0)
                .textCase(t.isA || (t.isB && pri) ? .uppercase : nil)
                .lineLimit(1)
                .foregroundStyle(fg)
                .padding(.horizontal, size == .small ? 12 : 16)
                .frame(height: h)
                .frame(maxWidth: fill || size == .big ? .infinity : nil)
                .background(shape.fill(bg))
                .overlay(shape.strokeBorder(t.isC ? .clear : t.isD ? Color(hex: 0x111111) : (pri ? t.cta : t.line), lineWidth: t.isD ? 2.5 : 1))
                .brightness(hover && !off ? (t.isDark ? 0.04 : -0.03) : 0)
                .modifier(ThemeShadow(kind: pressed && t.isD ? .small : .button, radius: radius))
                .offset(x: pressed && t.isD ? 2 : 0, y: pressed && t.isD ? 2 : 0)
                .scaleEffect(pressed && !t.isD ? 0.98 : 1)
                .opacity(off ? 0.45 : 1)
                .contentShape(shape)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: pressed)
        }

        private var font: Font {
            let s: CGFloat = size == .small ? 13 : size == .big ? 15 : 14
            switch t.id {
            case .a: return t.mono(12, .medium)
            case .b: return kind == .primary ? Fonts.font("Barlow Condensed", 16, .semibold) : t.body(s, .semibold)
            case .c: return t.body(s, .medium)
            case .d: return t.body(s, .heavy)
            }
        }
    }
}

/// `.btn`: icon + title, primary or secondary. `off` keeps it clickable (to explain why) but dimmed, like the prototype.
struct MButton: View {
    var title: String
    var icon: String?
    var kind: ButtonKind = .secondary
    var size: ButtonSize = .regular
    var off = false
    var fill = false
    var action: () -> Void

    init(_ title: String, icon: String? = nil, kind: ButtonKind = .secondary, size: ButtonSize = .regular, off: Bool = false, fill: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.size = size
        self.off = off
        self.fill = fill
        self.action = action
    }

    var body: some View {
        Button {
            Sounds.play(.tap)
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: size == .small ? 12 : 14, weight: .semibold)) }
                Text(title)
            }
        }
        .buttonStyle(MuseButtonStyle(kind: kind, size: size, off: off, fill: fill))
    }
}

/// `.icbtn`
struct IconButton: View {
    @Environment(\.theme) private var t
    var systemName: String
    var help: String = ""
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 15, weight: .medium)).foregroundStyle(t.ink)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(hover ? t.surface2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// The "⋯" button that opens a native menu.
struct MoreMenu<Content: View>: View {
    @Environment(\.theme) private var t
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(t.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 34, height: 34)
        .contentShape(Rectangle())
    }
}

/// Text that acts like a link (`.link`).
struct LinkText: View {
    @Environment(\.theme) private var t
    var text: String
    var size: CGFloat = 12
    var action: () -> Void
    init(_ text: String, size: CGFloat = 12, action: @escaping () -> Void) {
        self.text = text
        self.size = size
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(text).font(t.body(size, .semibold)).foregroundStyle(t.isD ? t.blue : t.accent)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Pills, chips, segmented, toggles

enum PillKind { case neutral, good, warn, acc, yours }

/// `.pill`
struct Pill: View {
    @Environment(\.theme) private var t
    var text: String
    var kind: PillKind = .neutral
    init(_ text: String, _ kind: PillKind = .neutral) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .neutral: return (t.surface2, t.ink)
            case .good: return (t.good.opacity(0.18), t.good)
            case .warn: return (t.warnBg, t.isB ? t.warnInk : Color(hex: 0x6B3F00))
            case .acc: return (t.accent, t.accentInk)
            case .yours: return (t.ink, t.bg)
            }
        }()
        Text(t.isA ? text.uppercased() : text)
            .font(t.isA ? t.mono(10.5, .medium) : t.body(11.5, .semibold))
            .tracking(t.isA ? 0.6 : 0)
            .lineLimit(1)
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(bg).if(t.isA) { _ in Rectangle().fill(bg) })
            .overlay(Group { if t.isD { Capsule().strokeBorder(Color(hex: 0x111111), lineWidth: 1.5) } })
            .fixedSize()
    }
}

/// `.chip`
struct Chip: View {
    @Environment(\.theme) private var t
    var text: String
    var on = false
    var icon: String?
    var action: () -> Void

    init(_ text: String, on: Bool = false, icon: String? = nil, action: @escaping () -> Void) {
        self.text = text
        self.on = on
        self.icon = icon
        self.action = action
    }

    var body: some View {
        let radius: CGFloat = t.isA ? 0 : 16
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let bg: Color = on ? (t.isB || t.isC ? t.accent : t.isD ? t.yellow : t.ink) : t.surface
        let fg: Color = on ? (t.isB ? t.accentInk : t.isC ? .white : t.isD ? Color(hex: 0x111111) : t.bg) : t.ink
        Button {
            Sounds.play(.tap)
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(t.isA ? text.uppercased() : text)
                    .font(t.isA ? t.mono(11.5) : t.isD ? t.body(13, .bold) : t.body(13))
                    .tracking(t.isA ? 0.7 : 0)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(shape.fill(bg))
            .overlay(shape.strokeBorder(on && !t.isD ? bg : t.isD ? Color(hex: 0x111111) : t.line, lineWidth: t.isD ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// A removable chip ("tattoos ✕").
struct RemovableChip: View {
    @Environment(\.theme) private var t
    var text: String
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(t.isA ? text.uppercased() : text).font(t.isA ? t.mono(11.5) : t.body(13, t.isD ? .bold : .regular))
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.6) }.buttonStyle(.plain)
        }
        .foregroundStyle(t.ink)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: t.isA ? 0 : 16).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 16).strokeBorder(t.isD ? Color(hex: 0x111111) : t.line, lineWidth: t.isD ? 2 : 1))
    }
}

/// `.seg`: Editorial draws it as underlined tabs, the others as a segmented pill.
struct Seg<T: Hashable>: View {
    @Environment(\.theme) private var t
    var options: [(T, String)]
    @Binding var selection: T
    var onChange: ((T) -> Void)?

    init(_ options: [(T, String)], selection: Binding<T>, onChange: ((T) -> Void)? = nil) {
        self.options = options
        self._selection = selection
        self.onChange = onChange
    }

    var body: some View {
        if t.isA {
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    ForEach(options.indices, id: \.self) { i in
                        let (v, l) = options[i]
                        let on = v == selection
                        Button { pick(v) } label: {
                            Text(l.uppercased()).font(t.mono(11.5, on ? .semibold : .regular)).tracking(0.9)
                                .foregroundStyle(on ? t.ink : t.muted)
                                .frame(height: 32)
                                .overlay(alignment: .bottom) { Rectangle().fill(on ? t.accent : .clear).frame(height: 2) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                Rectangle().fill(t.line).frame(height: 1)
            }
        } else {
            let outer: CGFloat = t.isC ? 22 : t.r
            HStack(spacing: 3) {
                ForEach(options.indices, id: \.self) { i in
                    let (v, l) = options[i]
                    let on = v == selection
                    Button { pick(v) } label: {
                        Text(l).font(t.body(13, on ? (t.isD ? .heavy : .semibold) : .medium)).lineLimit(1)
                            .foregroundStyle(on ? (t.isD ? Color.white : t.ink) : t.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: t.isC ? 16 : outer * 0.8).fill(on ? (t.isD ? Color(hex: 0x111111) : t.isB ? t.line : t.surface) : .clear)
                                .shadow(color: on && !t.isD ? .black.opacity(0.12) : .clear, radius: 1.5, y: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: outer).fill(t.isD ? Color.white : t.surface2))
            .overlay(RoundedRectangle(cornerRadius: outer).strokeBorder(t.isC ? .clear : t.isD ? Color(hex: 0x111111) : t.line, lineWidth: t.isD ? 2.5 : 1))
            .if(t.isC) { $0.shadow(color: Color(red: 120 / 255, green: 105 / 255, blue: 85 / 255).opacity(0.12), radius: 3, x: 2, y: 2) }
        }
    }

    private func pick(_ v: T) {
        Sounds.play(.tap)
        withAnimation(.easeOut(duration: 0.15)) { selection = v }
        onChange?(v)
    }
}

/// `.tog`: 50×30 track, 24 pt knob inset 3 pt inside the border, per-theme colours.
struct MToggle: View {
    @Environment(\.theme) private var t
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)?

    var body: some View {
        let border: CGFloat = t.isD ? 2.5 : 0
        let knob: CGFloat = 24
        let travel = 50 - 2 * border - 6 - knob
        let track: Color = {
            if isOn { return t.accent }
            switch t.id {
            case .a: return t.line
            case .b: return Color(hex: 0x2C3033)
            case .c: return t.surface2
            case .d: return .white
            }
        }()
        let knobColor: Color = t.isB ? (isOn ? Color(hex: 0x1A1205) : Color(hex: 0xA9A6A0)) : .white
        Button {
            Sounds.play(.tap)
            withAnimation(.easeOut(duration: 0.18)) { isOn.toggle() }
            onChange?(isOn)
        } label: {
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if border > 0 { Capsule().strokeBorder(Color(hex: 0x111111), lineWidth: border) }
                Circle().fill(knobColor)
                    .overlay(Circle().strokeBorder(t.isD ? Color(hex: 0x111111) : .clear, lineWidth: 2))
                    .shadow(color: t.isC ? .black.opacity(0.22) : .clear, radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: border + 3 + (isOn ? travel : 0))
            }
            .frame(width: 50, height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A row with a title, a hint and a trailing control.
struct OptionRow<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var hint: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(t.body(14, .bold)).foregroundStyle(t.ink)
                if let hint { Muted(hint) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// `.num`: − value +
struct NumStepper: View {
    @Environment(\.theme) private var t
    var value: Int
    var dec: () -> Void
    var inc: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { Sounds.play(.tick); dec() }) { Text("−").frame(width: 34, height: 32).background(t.surface2).contentShape(Rectangle()) }.buttonStyle(.plain)
            Text("\(value)").font(t.mono(14)).frame(width: 40)
            Button(action: { Sounds.play(.tick); inc() }) { Text("+").frame(width: 34, height: 32).background(t.surface2).contentShape(Rectangle()) }.buttonStyle(.plain)
        }
        .foregroundStyle(t.ink)
        .font(t.body(15, .semibold))
        .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
    }
}

/// `.note` and `.note.warn`
struct Note: View {
    @Environment(\.theme) private var t
    var icon: String = "sparkle"
    var warn = false
    var text: Text

    init(icon: String = "sparkle", warn: Bool = false, _ text: String) {
        self.icon = icon
        self.warn = warn
        self.text = Text(text)
    }

    init(icon: String = "sparkle", warn: Bool = false, text: Text) {
        self.icon = icon
        self.warn = warn
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            text.font(t.body(13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(warn ? t.warnInk : t.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(warn ? t.warnBg : t.surface2))
    }
}

/// `.prog`
struct ProgressLine: View {
    @Environment(\.theme) private var t
    var value: Double
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(t.surface2)
                Capsule().fill(t.accent).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.4), value: value)
    }
}

/// `.led`
struct LED: View {
    @Environment(\.theme) private var t
    var on: Bool
    @State private var pulse = false
    var body: some View {
        Circle().fill(on ? t.good : t.muted).frame(width: 8, height: 8)
            .background(Circle().fill(t.good.opacity(on ? (pulse ? 0 : 0.25) : 0)).frame(width: pulse ? 22 : 14, height: pulse ? 22 : 14))
            .onAppear { if on { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } } }
    }
}

/// `.kbd`
struct KeyCap: View {
    @Environment(\.theme) private var t
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(t.mono(11)).foregroundStyle(t.muted).padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.line, lineWidth: 1))
    }
}

/// Creator Pop's hand-written sticker (`.stk`). Other themes draw nothing.
struct Sticker: View {
    @Environment(\.theme) private var t
    var text: String
    var rotation: Double = -4
    init(_ text: String, rotation: Double = -4) {
        self.text = text
        self.rotation = rotation
    }
    var body: some View {
        if t.isD {
            Text(text).font(Fonts.font("Permanent Marker", 15, .regular)).foregroundStyle(Color(hex: 0x111111))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.yellow))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0x111111), lineWidth: 2))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x111111)).offset(x: 2, y: 2))
                .rotationEffect(.degrees(rotation))
        }
    }
}

/// `.inp`: text field and text editor chrome.
struct FieldChrome: ViewModifier {
    @Environment(\.theme) private var t
    var multiline = false
    var focused = false

    func body(content: Content) -> some View {
        let radius: CGFloat = t.isA ? 0 : t.isC ? 14 : t.r
        content
            .textFieldStyle(.plain)
            .font(t.body(14))
            .foregroundStyle(t.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 10 : 0)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: radius).fill(t.isC ? t.surface2 : t.surface))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(focused ? t.accent : (t.isC ? .clear : t.strongLine), lineWidth: t.lineWidth))
    }
}

extension View {
    func fieldChrome(multiline: Bool = false, focused: Bool = false) -> some View { modifier(FieldChrome(multiline: multiline, focused: focused)) }
}

/// A multi-line text box with the theme's field chrome.
struct TextBox: View {
    @Environment(\.theme) private var t
    var placeholder: String
    @Binding var text: String
    var lines: Int = 3
    var mono = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(t.body(14)).foregroundStyle(t.muted.opacity(0.8)).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(mono ? t.mono(12) : t.body(14))
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(lines) * 20)
        }
        .fieldChrome(multiline: true)
    }
}

/// Wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 10_000
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// A labelled field group (`.fld`).
struct Field<Content: View>: View {
    var label: String
    var trailing: String?
    var trailingAction: (() -> Void)?
    @ViewBuilder var content: () -> Content

    init(_ label: String, trailing: String? = nil, trailingAction: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.trailing = trailing
        self.trailingAction = trailingAction
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Lbl(label)
                Spacer()
                if let trailing, let trailingAction { LinkText(trailing, action: trailingAction) }
            }
            content()
        }
    }
}

/// Settings-style list (`.list` / `.li`).
struct ListBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }.surface(shadow: .card)
    }
}

struct ListRow<Trailing: View>: View {
    @Environment(\.theme) private var t
    var icon: String?
    var title: String
    var hint: String?
    var last = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let icon { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(t.ink).frame(width: 20) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(t.body(14)).foregroundStyle(t.ink)
                    if let hint { Muted(hint) }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if !last { Rectangle().fill(t.isD ? Color(hex: 0x111111) : t.line).frame(height: t.lineWidth) }
        }
    }
}

/// A mono value on the right of a list row.
struct MonoValue: View {
    @Environment(\.theme) private var t
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(t.mono(13)).foregroundStyle(t.ink) }
}
