import MuseCore
import SwiftUI

// AI suite (workstream 1): the Video suite screen (Screen.suite). It loads the catalog, shows the suite-off state when the
// server has it switched off, and otherwise the hub (D1), the composer (Shot, Character swap, Talking, UGC ad, Extend),
// the storyboard or the camera stage. Pickers open over it, always dark.

struct SuiteRootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        ZStack {
            content
            // The storyboard's look lock opens the same picker shell (the composer has its own host).
            if store.suite.mode == .storyboard { ComposerPickerHost() }
        }
        .task(id: store.serverKey) { await store.loadSuite() }
    }

    @ViewBuilder private var content: some View {
        let s = store.suite
        if s.catalog == nil {
            if let err = s.catalogError {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The Video suite couldn't load").font(t.display(24))
                    Muted(err, size: 13)
                    MButton("Try again", icon: "arrow.clockwise", size: .small) { Task { await store.loadSuite(force: true) } }
                }
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Muted("Loading the Video suite…", size: 13)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !s.enabled {
            SuiteOffView()
        } else {
            switch s.mode {
            case .hub: SuiteHubView()
            case .shot, .swap, .talking, .ugc, .extend, .photo: ComposerView()
            case .storyboard: StoryboardView()
            case .cameraStage: CameraStageView()
            }
        }
    }
}

/// D1: mode tiles, the camera stage, saved rigs, recent takes and the studio's cast.
struct SuiteHubView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The tile grid's width, for balanced columns (6 tiles read 3 + 3, not 5 + 1).
    @State private var tilesWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                tiles
                // Recent takes get the room; the camera stage link sits under the cast (it is one line).
                HStack(alignment: .top, spacing: 28) {
                    recent.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 26) {
                        cast
                        stage
                    }
                    .frame(width: 260, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text((store.user?.studioName ?? "MUSE Studio").uppercased()).font(t.mono(11)).tracking(1.6).foregroundStyle(t.muted)
                Text("Video suite").font(t.isA ? Fonts.font("Instrument Serif", 56, .regular) : t.display(40))
                Text("Make a shot, swap your character into a clip, or plan a whole story — with your cast and a real camera.").font(t.body(14)).foregroundStyle(t.muted)
            }
            Spacer(minLength: 12)
            SuiteTestBadge()
            MButton("New shot · ⌘N", kind: .primary, size: .big) { store.openSuite(.shot) }
        }
    }

    private var tiles: some View {
        let modes = SuiteMode.group.filter { $0 != .cameraStage }
        let n = SuiteLayout.balancedColumns(count: modes.count, width: Double(tilesWidth), minimum: 200, spacing: 12)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: n), spacing: 12) {
            ForEach(modes) { m in
                Button { store.openSuite(m) } label: { tile(m) }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in Color.clear.preference(key: HubTilesWidthKey.self, value: g.size.width) })
        .onPreferenceChange(HubTilesWidthKey.self) { tilesWidth = $0 }
    }

    private func tile(_ m: SuiteMode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HardwareImage(name: m.tileRender).frame(height: 128).clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(m.title).font(t.body(15, .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if store.isComingSoon(m) { SuiteTag(text: SuiteText.comingSoon) }
                }
                Text(m.tileLine).font(t.body(12.5)).foregroundStyle(t.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        }
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: t.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(t.line, lineWidth: 1))
        .opacity(store.isComingSoon(m) ? 0.82 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(m.title)\(store.isComingSoon(m) ? ", coming soon" : "")")
    }

    // MARK: Recent takes

    private var recentJobs: [Job] {
        let suiteJobs = store.jobs.filter { $0.request.engine == "suite" }
        return Array((suiteJobs.isEmpty ? store.jobs : suiteJobs).sorted { $0.createdAt > $1.createdAt }.prefix(4))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SuiteSectionHead(title: "Recent takes") { LinkText("See all in Queue →") { store.go(.queue) } }
            if recentJobs.isEmpty {
                Muted("Your takes show up here as they render.")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(recentJobs) { j in recentTile(j) }
                }
            }
        }
    }

    private func recentTile(_ j: Job) -> some View {
        let state = SuiteResultState.of(j)
        let take = store.takes(of: j).first
        return Button {
            if let take { store.openTake(take.id) } else { store.go(.queue) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay(MuseImage(ref: take?.thumb ?? j.thumb).blur(radius: state == .ready ? 0 : 10))
                    .overlay(overlay(state))
                    .clipped()
                Text(j.title.uppercased()).font(t.mono(10)).tracking(0.6).lineLimit(1)
                stateTag(state)
            }
            .frame(maxWidth: 110)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(j.title), \(stateWords(state))")
    }

    private func stateWords(_ s: SuiteResultState) -> String {
        switch s {
        case .ready: return "ready"
        case .rendering(let p, _): return "rendering \(p) percent"
        case .queued: return s.queueLine
        case .failed: return "failed"
        case .empty: return ""
        }
    }

    @ViewBuilder private func overlay(_ s: SuiteResultState) -> some View {
        switch s {
        case .ready: Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9))
        case .rendering(let p, _): Text("\(p)%").font(t.isA ? Fonts.font("Instrument Serif", 30, .regular) : t.display(24)).foregroundStyle(.white)
        case .queued: Text(s.queueLine.uppercased()).font(t.mono(9.5)).foregroundStyle(.white).padding(4).background(Color.black.opacity(0.8))
        case .failed: Text("RETRY FREE").font(t.mono(9.5, .semibold)).foregroundStyle(.white).padding(4).background(t.rec)
        case .empty: EmptyView()
        }
    }

    @ViewBuilder private func stateTag(_ s: SuiteResultState) -> some View {
        switch s {
        case .ready: SuiteTag(text: "Ready", color: t.goodInk)
        case .rendering: SuiteTag(text: "Rendering", color: t.rec)
        // Short: the picture above already says "Waiting to start" / "#2 in line" (the long line overflowed the tile).
        case .queued: SuiteTag(text: "In line")
        case .failed: SuiteTag(text: "Failed", color: t.rec)
        case .empty: EmptyView()
        }
    }

    // MARK: Camera stage (camera-bag entry points paused for the composer redesign)

    private var stage: some View {
        VStack(alignment: .leading, spacing: 12) {
            SuiteSectionHead(title: "Camera stage") { LinkText("Open →") { store.openSuite(.cameraStage) } }
            Muted("Block a shot in Blender, then use it as the camera (Directed mode).")
        }
    }

    // MARK: Cast

    private var cast: some View {
        VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Your cast") { LinkText("+ New model") { store.go(.create) } }
            if store.suiteCharacters.isEmpty { Muted("Make a model with a character sheet to cast her.") }
            ForEach(store.suiteCharacters) { m in
                Button { store.openProfile(m.id) } label: { castRow(m) }.buttonStyle(.plain)
            }
        }
    }

    private func castRow(_ m: MuseModel) -> some View {
        let faces = m.slot("face")?.image != nil && m.slot("profile")?.image != nil
        return HStack(alignment: .top, spacing: 10) {
            MuseImage(ref: m.cover).frame(width: 40, height: 50).clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(m.name).font(t.body(13.5, .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    SuiteTag(text: faces ? "Locked" : "Needs close-ups", color: faces ? t.goodInk : t.warnInk)
                }
                HStack(spacing: 2) {
                    ForEach(m.slots.filter { $0.image != nil }.prefix(7), id: \.key) { s in
                        MuseImage(ref: s.image).frame(width: 18, height: 22).clipped()
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }
    }
}

private struct HubTilesWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
