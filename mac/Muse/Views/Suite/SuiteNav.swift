import MuseCore
import SwiftUI

// AI suite: choosing the Suite's mode (owner decision 2026-11-08). The sidebar no longer lists the modes under Video suite,
// and the composer's title opens this plain menu instead of the big tool and preset browser: the modes in groups, text
// only, no pictures and no presets (presets live in the page's presets strip and its All templates).

/// One row of the mode menu: a composer tool, or Camera stage (its own screen).
enum SuiteMenuItem: Hashable, Identifiable {
    case tool(ComposerTool)
    case cameraStage
    var id: String {
        switch self {
        case .tool(let t): return t.rawValue
        case .cameraStage: return "cameraStage"
        }
    }
    var title: String {
        switch self {
        case .tool(let t): return t.title
        case .cameraStage: return SuiteMode.cameraStage.title
        }
    }

    /// The groups, in order.
    static let groups: [(title: String, items: [SuiteMenuItem])] = [
        ("Make", [.tool(.shot), .tool(.photo), .tool(.talking), .tool(.ugc)]),
        ("Work from a clip", [.tool(.swap), .tool(.recast), .tool(.extend)]),
        ("Plan", [.tool(.storyboard), .cameraStage]),
    ]
}

/// The composer title's menu: anchored under the title, closes on a click outside or Escape.
struct SuiteModeMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { store.suite.browserOpen = false }
                .accessibilityHidden(true)
            panel
                .padding(.leading, Space.s5 - Space.s2)
                .padding(.top, Space.s4 + 36)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SuiteMenuItem.groups.enumerated()), id: \.offset) { i, g in
                if i > 0 { Rectangle().fill(t.roles.hairline).frame(height: 1).padding(.vertical, Space.s1) }
                Text(g.title).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .padding(.horizontal, Space.s3).padding(.top, Space.s2).padding(.bottom, 2)
                // Camera stage is the owner's (CameraStageView is OwnerOnly).
                ForEach(g.items.filter { $0 != .cameraStage || store.isOwner }) { item in row(item) }
            }
            // Escape closes the menu.
            Button("") { store.suite.browserOpen = false }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .padding(.vertical, Space.s1)
        .frame(width: 232, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.raised))
        .overlay(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suite modes")
    }

    private func isOn(_ item: SuiteMenuItem) -> Bool {
        switch item {
        case .tool(let tool): return store.screen == .suite && store.suite.mode != .storyboard && store.suite.mode != .cameraStage && store.suite.composer.tool == tool
        case .cameraStage: return store.screen == .suite && store.suite.mode == .cameraStage
        }
    }

    private func soon(_ item: SuiteMenuItem) -> Bool {
        if case .tool(let tool) = item { return store.isComingSoon(tool) }
        return store.isComingSoon(.cameraStage)
    }

    private func row(_ item: SuiteMenuItem) -> some View {
        let on = isOn(item)
        return Button {
            store.suite.browserOpen = false
            switch item {
            case .tool(let tool): store.openTool(tool)
            case .cameraStage: store.openSuite(.cameraStage)
            }
        } label: {
            HStack(spacing: Space.s2) {
                Text(item.title).font(t.body(14, on ? .semibold : .regular)).foregroundStyle(t.roles.ink).lineLimit(1)
                if soon(item) { Text("Soon").font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
                Spacer(minLength: Space.s2)
                if on { Ph("check", 13).foregroundStyle(t.roles.ink) }
            }
            .padding(.horizontal, Space.s3)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(on ? t.roles.field : .clear).padding(.horizontal, Space.s1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)\(soon(item) ? ", coming soon" : "")\(on ? ", selected" : "")")
    }
}
