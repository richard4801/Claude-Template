import MuseCore
import SwiftUI

// Opt-in controls for the restyled screens (plans/design-direction.md): role colours, the type scale, Space and radii.
// The older components in Components.swift keep their behaviour for the screens that still use them.

extension View {
    /// A scale step in a role colour.
    func scaled(_ s: TypeScale.Style, _ color: Color) -> some View { typeStep(s).foregroundStyle(color) }
}

// MARK: Page and headings

/// A scrolling screen with the 32 pt Mac gutter.
struct ScreenPage<Content: View>: View {
    var maxWidth: CGFloat?
    @ViewBuilder var content: () -> Content

    init(maxWidth: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: maxWidth ?? .infinity, alignment: .leading)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.s5)
                .padding(.bottom, Space.s7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The one screen title (`display`, sentence case), an optional line under it, and the screen's actions on the right.
struct ScreenTitle<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title).scaled(t.scale.display, t.roles.ink).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s4)
            HStack(spacing: Space.s2) { trailing() }
        }
        .padding(.bottom, Space.s6)
    }
}

extension ScreenTitle where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A section heading (`heading` in ink, sentence case) with something quiet on the right.
struct SectionTitle<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var top: CGFloat
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, top: CGFloat = Space.s6, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.top = top
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text(title).scaled(t.scale.heading, t.roles.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s3)
            trailing()
        }
        .padding(.top, top)
        .padding(.bottom, Space.s3)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, top: CGFloat = Space.s6) {
        self.init(title, top: top) { EmptyView() }
    }
}

/// "Parent › Title" above a detail screen.
struct Crumb: View {
    @Environment(\.theme) private var t
    var parent: String
    var title: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: Space.s1) {
            Button(action: action) { Text(parent).foregroundStyle(t.roles.link) }
                .buttonStyle(.plain)
                .help("Back to \(parent)")
            Text("›").foregroundStyle(t.roles.ink2)
            Text(title).foregroundStyle(t.roles.ink2).lineLimit(1)
        }
        .typeStep(t.scale.caption)
        .padding(.bottom, Space.s3)
    }
}

// MARK: Buttons

/// `action`: the one filled button per screen. `quiet`: a tonal secondary. `plain`: a text link. `danger`: destructive text.
enum RKind { case action, quiet, plain, danger }

struct RButtonStyle: ButtonStyle {
    var kind: RKind = .quiet
    var small = false
    var fill = false
    var off = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, small: small, fill: fill, off: off)
    }

    private struct Styled: View {
        @Environment(\.theme) private var t
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let kind: RKind
        let small: Bool
        let fill: Bool
        let off: Bool
        @State private var hover = false

        var body: some View {
            let r = t.roles
            let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
            let dim = off || !enabled
            let bg: Color = kind == .action ? r.action : kind == .quiet ? r.field : .clear
            let fg: Color = kind == .action ? r.onAction : kind == .danger ? r.danger : kind == .plain ? r.link : r.ink
            let tint: Double = hover && !dim && kind != .action ? (t.isDark ? 0.08 : 0.06) : 0
            configuration.label
                .font(t.scale.label.font)
                .lineLimit(1)
                .foregroundStyle(fg)
                .padding(.horizontal, kind == .plain || kind == .danger ? Space.s2 : small ? Space.s3 : Space.s4)
                .frame(minHeight: small ? 28 : 32)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(shape.fill(bg))
                .background(shape.fill(r.ink.opacity(tint)))
                .overlay(shape.strokeBorder(r.ink, lineWidth: kind == .action && t.isD ? 2 : 0))
                .overlay(shape.strokeBorder(r.selection, lineWidth: focused ? 2 : 0).padding(-3))
                .brightness(kind == .action && hover && !dim ? (t.isDark ? 0.05 : -0.04) : 0)
                .opacity(dim ? 0.45 : configuration.isPressed ? 0.8 : 1)
                .contentShape(shape)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// A text button in the role styles. `off` keeps it clickable (to explain why) but dimmed, like MButton.
struct RButton: View {
    var title: String
    var kind: RKind
    var small: Bool
    var fill: Bool
    var off: Bool
    var action: () -> Void

    init(_ title: String, kind: RKind = .quiet, small: Bool = false, fill: Bool = false, off: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.small = small
        self.fill = fill
        self.off = off
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(RButtonStyle(kind: kind, small: small, fill: fill, off: off))
    }
}

/// An icon-only button: 28 pt target, tooltip and accessibility label always.
struct RIconButton: View {
    @Environment(\.theme) private var t
    var systemName: String
    var help: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Ph(systemName, 14).foregroundStyle(t.roles.ink)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.roles.field : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

// MARK: Media

/// A tile is a picture plus its caption, not a box (§4). The selection is one outline in `selection`.
struct MediaTile<Badge: View>: View {
    @Environment(\.theme) private var t
    var ref: ImageRef?
    var ratio: CGFloat
    var caption: String?
    var meta: String?
    var selected: Bool
    var symbol: String?
    @ViewBuilder var badge: () -> Badge

    init(ref: ImageRef?, ratio: CGFloat = 9.0 / 16.0, caption: String? = nil, meta: String? = nil, selected: Bool = false, symbol: String? = nil,
         @ViewBuilder badge: @escaping () -> Badge) {
        self.ref = ref
        self.ratio = ratio
        self.caption = caption
        self.meta = meta
        self.selected = selected
        self.symbol = symbol
        self.badge = badge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            MediaFrame(ref: ref, ratio: ratio, selected: selected, symbol: symbol, badge: badge)
            if caption != nil || (meta?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 2) {
                    if let caption { Text(caption).scaled(t.scale.caption, t.roles.ink).lineLimit(1) }
                    if let meta, !meta.isEmpty { Text(meta).monospacedDigit().scaled(t.scale.micro, t.roles.ink2).lineLimit(1) }
                }
            }
        }
    }
}

extension MediaTile where Badge == EmptyView {
    init(ref: ImageRef?, ratio: CGFloat = 9.0 / 16.0, caption: String? = nil, meta: String? = nil, selected: Bool = false, symbol: String? = nil) {
        self.init(ref: ref, ratio: ratio, caption: caption, meta: meta, selected: selected, symbol: symbol) { EmptyView() }
    }
}

/// Just the picture: container radius, a hairline edge on light canvases, no frame decoration.
struct MediaFrame<Badge: View>: View {
    @Environment(\.theme) private var t
    var ref: ImageRef?
    var ratio: CGFloat = 9.0 / 16.0
    var selected = false
    var symbol: String?
    @ViewBuilder var badge: () -> Badge

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(MuseImage(ref: ref, symbol: symbol))
            .overlay(alignment: .topLeading) { badge().padding(Space.s2) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: t.isDark || t.isD ? 0 : 1))
            .overlay(shape.strokeBorder(t.roles.selection, lineWidth: selected ? 2 : 0).padding(-4))
    }
}

extension MediaFrame where Badge == EmptyView {
    init(ref: ImageRef?, ratio: CGFloat = 9.0 / 16.0, selected: Bool = false, symbol: String? = nil) {
        self.init(ref: ref, ratio: ratio, selected: selected, symbol: symbol) { EmptyView() }
    }
}

/// A small label on media or beside a value (`micro`, chip radius). Tone colours only with state.
struct StateTag: View {
    enum Tone { case neutral, positive, caution, danger, onMedia }
    @Environment(\.theme) private var t
    var text: String
    var tone: Tone = .neutral

    init(_ text: String, _ tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        let r = t.roles
        let fg: Color = {
            switch tone {
            case .neutral: return r.ink2
            case .positive: return r.positive
            case .caution: return r.caution
            case .danger: return r.danger
            case .onMedia: return .white
            }
        }()
        Text(text).scaled(t.scale.micro, fg).lineLimit(1)
            .padding(.horizontal, Space.s2)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(tone == .onMedia ? Color.black.opacity(0.55) : r.field))
            .fixedSize()
    }
}

// MARK: States

/// Loading: a block in the `field` tone, shaped like what it replaces. It breathes gently unless Reduce Motion is on.
struct SkeletonBlock: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var ratio: CGFloat?
    var width: CGFloat?
    var height: CGFloat?
    var radius: CGFloat?
    @State private var dim = false

    init(ratio: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil, radius: CGFloat? = nil) {
        self.ratio = ratio
        self.width = width
        self.height = height
        self.radius = radius
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? t.radii.chip, style: .continuous)
        Group {
            if let ratio {
                Color.clear.aspectRatio(ratio, contentMode: .fit).background(shape.fill(t.roles.field))
            } else {
                shape.fill(t.roles.field).frame(width: width, height: height ?? 12)
            }
        }
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityHidden(true)
    }
}

/// A grid of tile skeletons (picture plus a caption line).
struct SkeletonGrid: View {
    @Environment(\.theme) private var t
    var columns: Int
    var count: Int
    var ratio: CGFloat = 9.0 / 16.0
    var caption = true
    var spacing: CGFloat = Space.s4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), alignment: .leading, spacing: spacing) {
            ForEach(0..<count, id: \.self) { i in
                VStack(alignment: .leading, spacing: Space.s2) {
                    SkeletonBlock(ratio: ratio, radius: t.radii.container)
                    if caption { SkeletonBlock(width: i % 2 == 0 ? 90 : 64, height: 10) }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// Rows of list skeletons (thumbnail plus two lines).
struct SkeletonRows: View {
    var count: Int = 4
    var thumb = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: Space.s3) {
                    if thumb { SkeletonBlock(width: 44, height: 58) }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        SkeletonBlock(width: i % 2 == 0 ? 220 : 160, height: 12)
                        SkeletonBlock(width: i % 2 == 0 ? 140 : 190, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// Empty: what this is, plus one action to start.
struct EmptyState: View {
    @Environment(\.theme) private var t
    var title: String
    var message: String
    var actionTitle: String?
    var actionKind: RKind
    var action: (() -> Void)?

    init(_ title: String, _ message: String, actionTitle: String? = nil, actionKind: RKind = .quiet, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionKind = actionKind
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).scaled(t.scale.heading, t.roles.ink)
            Text(message).scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            if let actionTitle, let action {
                RButton(actionTitle, kind: actionKind, action: action).padding(.top, Space.s2)
            }
        }
        .padding(.vertical, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Error: what happened, plus how to fix it.
struct ErrorState: View {
    @Environment(\.theme) private var t
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, _ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).scaled(t.scale.heading, t.roles.danger)
            Text(message).scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            if let actionTitle, let action {
                RButton(actionTitle, kind: .quiet, action: action).padding(.top, Space.s2)
            }
        }
        .padding(.vertical, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inline notice on a `field` tone: no icon, no box shadow. Caution and danger colour the text only.
struct InlineNotice: View {
    enum Tone { case neutral, caution, danger }
    @Environment(\.theme) private var t
    var text: Text
    var tone: Tone
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ text: String, tone: Tone = .neutral, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = Text(text)
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    init(text: Text, tone: Tone = .neutral, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.tone = tone
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        let r = t.roles
        HStack(alignment: .center, spacing: Space.s3) {
            text.scaled(t.scale.caption, tone == .caution ? r.caution : tone == .danger ? r.danger : r.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action { RButton(actionTitle, kind: .plain, small: true, action: action) }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(r.field))
    }
}

// MARK: Controls

/// A segmented control on the `field` track; the selected segment is `raised` (and outlined in Creator Pop).
struct RSeg<T: Hashable>: View {
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
        let r = t.roles
        let inner = RoundedRectangle(cornerRadius: max(0, t.radii.control - 2), style: .continuous)
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (v, l) = options[i]
                let on = v == selection
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { selection = v }
                    onChange?(v)
                } label: {
                    Text(l).font(t.scale.label.font).lineLimit(1)
                        .foregroundStyle(on ? r.ink : r.ink2)
                        .padding(.horizontal, Space.s3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
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

/// The Mac switch, tinted with the accent.
struct RSwitch: View {
    @Environment(\.theme) private var t
    var label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(t.isD ? t.roles.ink : t.roles.accent)
            .accessibilityLabel(label)
    }
}

/// Input chrome: `field` fill, a hairline border, the selection colour when focused.
struct RFieldChrome: ViewModifier {
    @Environment(\.theme) private var t
    var focused = false
    var multiline = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(t.scale.body.font)
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, multiline ? Space.s2 : 0)
            .frame(minHeight: 32)
            .background(shape.fill(t.roles.field))
            .overlay(shape.strokeBorder(focused ? t.roles.selection : t.roles.hairline, lineWidth: focused ? 2 : 1))
    }
}

extension View {
    func roleField(focused: Bool = false, multiline: Bool = false) -> some View { modifier(RFieldChrome(focused: focused, multiline: multiline)) }
}

/// A one-line text field with the role chrome and its own focus mark.
struct RTextField: View {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .onSubmit(onSubmit)
            .roleField(focused: focused)
    }
}

/// A label above a control (`label` in ink2, sentence case).
struct RField<Content: View>: View {
    @Environment(\.theme) private var t
    var label: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    init(_ label: String, hint: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.hint = hint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(label).scaled(t.scale.label, t.roles.ink)
                if let hint { Text(hint).scaled(t.scale.caption, t.roles.ink2) }
            }
            content()
        }
    }
}

/// A settings row: title and hint on the left, the control on the right. Grouped by space; no box, no divider.
struct SettingRow<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var hint: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, hint: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.hint = hint
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaled(t.scale.body, t.roles.ink)
                if let hint { Text(hint).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.s4)
            trailing()
        }
        .frame(minHeight: 36)
        .padding(.vertical, Space.s1)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(_ title: String, hint: String? = nil) {
        self.init(title, hint: hint) { EmptyView() }
    }
}

/// A value on the right of a row: the text face with tabular figures, not mono.
struct RowValue: View {
    @Environment(\.theme) private var t
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).monospacedDigit().scaled(t.scale.body, t.roles.ink).textSelection(.enabled) }
}

/// A thin progress bar: field track, ink fill (accent is for selection).
struct RProgress: View {
    @Environment(\.theme) private var t
    var value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(t.roles.field)
                Capsule().fill(t.roles.ink).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.4), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((max(0, min(1, value)) * 100).rounded())) percent")
    }
}

/// A choice chip (chip radius). Off: `field`. On: the one selection outline, ink text.
struct ChoiceChip: View {
    @Environment(\.theme) private var t
    var text: String
    var on: Bool
    var action: () -> Void

    init(_ text: String, on: Bool = false, action: @escaping () -> Void) {
        self.text = text
        self.on = on
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
        Button(action: action) {
            Text(text).font(t.scale.label.font).lineLimit(1)
                .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                .padding(.horizontal, Space.s3)
                .frame(height: 28)
                .background(shape.fill(t.roles.field))
                .overlay(shape.strokeBorder(t.roles.selection, lineWidth: on ? 2 : 0))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A tag with a remove button ("tattoos ×").
struct RemovableTag: View {
    @Environment(\.theme) private var t
    var text: String
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Space.s1) {
            Text(text).font(t.scale.label.font).foregroundStyle(t.roles.ink)
            Button(action: onRemove) {
                Ph("xmark", 10).foregroundStyle(t.roles.ink2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.leading, Space.s3)
        .padding(.trailing, Space.s1)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
    }
}

/// A multi-line text box with the role chrome.
struct RTextBox: View {
    @Environment(\.theme) private var t
    var placeholder: String
    @Binding var text: String
    var lines: Int = 3
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(t.scale.body.font).foregroundStyle(t.roles.ink2).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(t.scale.body.font)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(height: CGFloat(lines) * 21)
        }
        .roleField(focused: focused, multiline: true)
    }
}

/// A drop target for files: a dashed hairline on `field` (the dash means "drop here"), the selection colour while targeted.
struct DropZone: View {
    @Environment(\.theme) private var t
    var title: String
    var hint: String
    var buttonTitle: String?
    var targeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
        HStack(spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                Text(hint).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s3)
            if let buttonTitle {
                Text(buttonTitle).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    .padding(.horizontal, Space.s4).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.raised))
            }
        }
        .padding(Space.s5)
        .background(shape.fill(t.roles.field))
        .overlay(shape.strokeBorder(targeted ? t.roles.selection : t.roles.hairline, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4])))
        .contentShape(shape)
    }
}
