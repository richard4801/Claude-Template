import MuseCore
import SwiftUI

// The Video suite redesign (owner-approved 2026-11-14; plans/design/suite-redesign/README.md and its five PNGs):
// - One header on every Suite page: "Video suite" in the display face and the tabs Shot · Photo · Swap · Storyboard ·
//   Recreate on the field track (the open one raised). The tools without a tab (Extend, Talking, UGC ad, Camera stage)
//   are in the More menu at the end, so nothing the old mode menu reached is lost.
// - The stage is a `field` panel; the panel on the right is `raised` with a hairline edge. Rows are icon, name, value and
//   a caret, divided by hairlines. Bottom bar pills sit on `field`.
// - Dark (Camera Body) uses the lifted tokens measured off the approved dark frame (DesignTokens.suite), on every Suite
//   page (owner decision 4). Light themes keep their own tokens.

extension View {
    /// The Suite's tokens: Camera Body's lifted dark (DesignTokens.suite); every other theme unchanged.
    func suiteTokens() -> some View { modifier(SuiteTokens()) }
}

private struct SuiteTokens: ViewModifier {
    @Environment(\.theme) private var t
    func body(content: Content) -> some View {
        var s = t
        if t.isB && t.rolesOverride == nil { s.rolesOverride = Roles(DesignTokens.suite("b")) }
        return content.environment(\.theme, s)
    }
}

/// The header's tabs.
enum SuiteTab: String, CaseIterable, Identifiable {
    case shot, photo, swap, storyboard, recreate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shot: return "Shot"
        case .photo: return "Photo"
        case .swap: return "Swap"
        case .storyboard: return "Storyboard"
        case .recreate: return "Recreate"
        }
    }

    var icon: String {
        switch self {
        case .shot: return "video-camera"
        case .photo: return "camera"
        case .swap: return "arrows-left-right"
        case .storyboard: return "squares-four"
        case .recreate: return "arrows-clockwise"
        }
    }

    /// The tab of the page on screen (nil: Home, or a tool that lives in More).
    @MainActor static func current(_ store: AppStore) -> SuiteTab? {
        if store.screen == .edit && store.recreate.open { return .recreate }
        guard store.screen == .suite else { return nil }
        switch store.suite.mode {
        case .storyboard: return .storyboard
        case .hub, .cameraStage: return nil
        default: break
        }
        switch store.suite.composer.tool {
        case .shot: return .shot
        case .photo: return .photo
        case .swap, .recast: return .swap
        default: return nil
        }
    }

    /// Opens the tab's page. Recreate keeps its own page inside Edit (unchanged).
    @MainActor func open(_ store: AppStore) {
        switch self {
        case .shot: store.openTool(.shot)
        case .photo: store.openTool(.photo)
        case .swap: store.openTool(.swap)
        case .storyboard: store.openSuite(.storyboard)
        case .recreate:
            store.openEdit()
            store.openRecreate()
        }
    }
}

/// "Video suite", the tabs, and the page's own quiet controls on the right.
struct SuitePageHeader<Trailing: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Space.s5) {
            Button { store.openSuite(.hub) } label: {
                Text("Video suite").font(t.isA ? Fonts.font("Instrument Serif", 32, .regular) : t.scale.display.font)
                    .foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Video suite home")
            .accessibilityLabel("Video suite home")
            .accessibilityAddTraits(.isHeader)
            SuiteTabs()
            Spacer(minLength: Space.s3)
            trailing()
        }
        .frame(height: 36)
    }
}

extension SuitePageHeader where Trailing == EmptyView {
    init() { self.init { EmptyView() } }
}

/// The tabs on the field track; More lists the tools that have no tab.
struct SuiteTabs: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let on = SuiteTab.current(store)
        ViewThatFits(in: .horizontal) {
            track(on, labels: true)
            track(on, labels: false)
        }
    }

    private func track(_ on: SuiteTab?, labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(SuiteTab.allCases) { tab in item(tab, on: tab == on, label: labels) }
            SuiteMoreMenu()
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: t.radii.control + 2).fill(t.roles.field))
        .fixedSize()
    }

    private func item(_ tab: SuiteTab, on: Bool, label: Bool) -> some View {
        Button { tab.open(store) } label: {
            HStack(spacing: 6) {
                Ph(tab.icon, 14).frame(width: 18, height: 18)
                if label { Text(tab.title).font(t.body(13.5, on ? .semibold : .regular)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
            .padding(.horizontal, label ? 11 : 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(on ? t.roles.raised : .clear))
            .overlay { if on && !t.isA { RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel("\(tab.title)\(on ? ", selected" : "")")
        .accessibilityIdentifier("suite.tab.\(tab.rawValue)")
    }
}

/// The tools without a tab: Extend & upscale, Recast, Talking, UGC ad, Camera stage (owner).
struct SuiteMoreMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let tool = store.suite.composer.tool
        let inMore = store.screen == .suite && (store.suite.mode == .cameraStage
            || ([.extend, .talking, .ugc].contains(tool) && store.suite.mode != .storyboard && store.suite.mode != .hub))
        Menu {
            Button("Extend & upscale") { store.openTool(.extend) }
            Button("Recast") { store.openTool(.recast) }
            Button(store.isComingSoon(ComposerTool.talking) ? "Talking (coming soon)" : "Talking") { store.openTool(.talking) }
            Button(store.isComingSoon(ComposerTool.ugc) ? "UGC ad (coming soon)" : "UGC ad") { store.openTool(.ugc) }
            if store.isOwner {
                Divider()
                Button("Camera stage") { store.openSuite(.cameraStage) }
            }
        } label: {
            Image(nsImage: Ph.menuImage("dots-three", 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30, height: 30)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(inMore ? t.roles.raised : .clear))
        .foregroundStyle(inMore ? t.roles.ink : t.roles.ink2)
        .help("More tools: Extend & upscale, Recast, Talking, UGC ad")
        .accessibilityLabel("More tools")
    }
}

// MARK: Surfaces

extension View {
    /// The stage: media on the field tone (the frame is the hero, no border).
    func suiteStagePanel(_ t: Theme) -> some View {
        background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.field))
    }

    /// The panel on the right: raised, with a hairline edge.
    func suitePanel(_ t: Theme) -> some View {
        background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.raised))
            .overlay(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(t.roles.hairline, lineWidth: 1))
    }
}

/// A panel's title row: the title (heading face, larger), an optional tag and a trailing control.
struct SuitePanelTitle<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    var tag: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Text(title).font(t.body(19, .semibold)).foregroundStyle(t.roles.ink).lineLimit(1)
                if let tag {
                    Text(tag).font(t.scale.micro.font).foregroundStyle(t.roles.ink2)
                        .padding(.horizontal, 6).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: t.radii.chip).strokeBorder(t.roles.hairline, lineWidth: 1))
                }
                Spacer(minLength: Space.s2)
                trailing()
            }
            if let subtitle {
                Text(subtitle).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small section label inside a panel ("Changes", "Inputs", "Sound"), with a hairline under it.
struct SuitePanelSection: View {
    @Environment(\.theme) private var t
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            Rectangle().fill(t.roles.hairline).frame(height: 1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// One list row: icon, name, the value and a caret; a hairline under it. The value is quiet while on Auto.
struct SuiteRow: View {
    @Environment(\.theme) private var t
    var icon: String
    var name: String
    var value: String
    var quiet = false
    var thumb: ImageRef? = nil
    /// An empty frame: a dashed square in place of the thumbnail.
    var emptyThumb = false
    var enabled = true
    var help: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Ph(icon, 15).frame(width: 18, height: 18).foregroundStyle(t.roles.ink)
                Text(name).font(t.scale.label.font).foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                    .frame(minWidth: 84, alignment: .leading)
                HStack(spacing: Space.s2) {
                    if let thumb {
                        MuseImage(ref: thumb).frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                    } else if emptyThumb {
                        RoundedRectangle(cornerRadius: t.radii.chip).strokeBorder(t.roles.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 22, height: 22)
                    }
                    Text(value).font(t.body(13.5, quiet ? .regular : .medium)).foregroundStyle(quiet ? t.roles.ink2 : t.roles.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: Space.s2)
                Ph("caret-down", 12).foregroundStyle(t.roles.ink2)
            }
            .frame(minHeight: 34)
            .padding(.vertical, 1)
            .overlay(alignment: .bottom) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help ?? "\(name): \(value)")
        .accessibilityLabel("\(name), \(value)")
    }
}

/// A bottom-bar pill: icon and value on the field tone (it opens its list).
struct SuitePillLabel: View {
    @Environment(\.theme) private var t
    var icon: String
    var value: String
    var open = false

    var body: some View {
        HStack(spacing: 6) {
            Ph(icon, 13).frame(width: 16, height: 16).foregroundStyle(t.roles.ink2)
            Text(value).font(t.body(13, .medium)).monospacedDigit().foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(open ? t.roles.hairline : t.roles.field))
        .contentShape(Rectangle())
    }
}

// MARK: Test render (owner decision 5)

/// Beside Generate: whether this render is a free test render. Today that is the server's mode (SUITE_MODE=mock makes every
/// render a free test render): on, Generate reads "Test render · Free"; live, the switch isn't shown (no switch that
/// changes nothing). Either way the button always shows what a click costs.
struct SuiteTestRenderSwitch: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if store.suite.catalog?.test == true {
            HStack(spacing: Space.s2) {
                Text("Test render").font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                Toggle("Test render", isOn: .constant(true)).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .disabled(true)
            }
            .fixedSize()
            .help(store.isOwner ? "The server makes free test-pattern renders (SUITE_MODE=mock). Switch the server to live for real renders."
                                : "Renders here are free test patterns for now")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Test render on: renders are free test patterns")
        }
    }
}
