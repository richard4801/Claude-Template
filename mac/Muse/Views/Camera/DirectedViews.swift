import MuseCore
import SwiftUI

/// The D6 body under the Camera control's header: tabs Blocking · Guides · History, the session strip, the plan / camera view /
/// side view, the legend and the timeline on the left, and Direct with Claude on the right.
struct DirectedBody: View {
    @Environment(\.theme) private var t
    @Bindable var model: CameraModel
    var session: CameraSession
    var useLabel: String?
    var onUse: (() -> Void)?
    @State private var showConnections = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                tabs
                    .padding(.horizontal, 28)
                Rectangle().fill(t.line).frame(height: 1)
                switch model.tab {
                case .blocking: blocking
                case .guides: CameraGuidesTab(session: session).padding(.horizontal, 28).padding(.vertical, 14)
                case .history: CameraHistoryTab(session: session, now: model.now).padding(.horizontal, 28).padding(.vertical, 14)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            DirectChatPanel(model: model, session: session, useLabel: useLabel, onUse: onUse) { showConnections = true }
        }
        .sheet(isPresented: $showConnections) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    MButton("Done", size: .small) { showConnections = false }
                }
                .padding(12)
                ScrollView { ConnectionsContent(model: model).padding(24) }
            }
            .frame(width: 720, height: 640)
            .background(t.bg)
        }
    }

    private var tabs: some View {
        HStack(spacing: 28) {
            ForEach(CameraModel.Tab.allCases, id: \.self) { tab in
                let on = model.tab == tab
                Button { model.tab = tab } label: {
                    VStack(spacing: 9) {
                        Text(tab.rawValue).font(t.body(14, on ? .semibold : .regular)).foregroundStyle(on ? t.ink : t.muted)
                        Rectangle().fill(on ? t.accent : .clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 10)
    }

    private var blocking: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SessionStrip(model: model, session: session)
                Group {
                    switch model.viewMode {
                    case .plan: CameraPlanCanvas(session: session, playhead: model.playhead, projection: .top) { h, p in model.drag(h, to: p) }
                    case .side: CameraPlanCanvas(session: session, playhead: model.playhead, projection: .side, editable: false)
                    case .camera: CameraStillView(session: session, playhead: model.playhead)
                    }
                }
                .frame(minHeight: 260, maxHeight: .infinity)
                .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                CameraPlanLegend(session: session, editable: model.viewMode == .plan)
                if let e = model.applyError, model.tab == .blocking { Text(e).font(t.body(12)).foregroundStyle(t.accent) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 10)
            CameraTimelineView(session: session, playhead: $model.playhead)
        }
    }
}

/// `cs_7Q2M` · title · `9:16 · 24 fps · 6.0 s · rev 4` · Plan | Camera view | Side · Re-render.
struct SessionStrip: View {
    @Environment(\.theme) private var t
    @Bindable var model: CameraModel
    var session: CameraSession

    var body: some View {
        HStack(spacing: 12) {
            Button { CameraModel.copy(session.id) } label: {
                Text(CameraText.idChip(session.id).uppercased()).font(t.mono(11, .medium)).tracking(0.8).foregroundStyle(t.bg)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: t.isA ? 0 : 4).fill(t.ink))
            }
            .buttonStyle(.plain)
            .help("Copy the session id (\(session.id)) · say “Open camera session \(session.id)” to your Claude")
            Text(session.title).font(t.body(14, .bold)).foregroundStyle(t.ink).lineLimit(2)
            Text(CameraText.stripMeta(session)).font(t.mono(11.5)).foregroundStyle(t.muted).lineLimit(1)
            Spacer(minLength: 8)
            Seg(CameraModel.ViewMode.allCases.map { ($0, $0.rawValue) }, selection: $model.viewMode)
                .frame(width: t.isA ? 260 : 300)
            MButton("Re-render", icon: "arrow.clockwise", size: .small, off: model.busy) { model.rerender() }
                .help(model.busy ? CameraText.chatBusy : "Ask Claude to render the guides again for this revision")
        }
        .frame(minHeight: 40)
    }
}

/// Guides tab: every ready asset by kind with its thumbnail or play, size, source and time.
struct CameraGuidesTab: View {
    @Environment(\.theme) private var t
    @Environment(\.openURL) private var openURL
    var session: CameraSession

    var body: some View {
        let items = CameraGuides.items(session.assets)
        let pending = session.assets.filter { $0.state == "pending" }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if pending > 0 {
                    Note(icon: "arrow.up.circle", "\(pending) file\(pending == 1 ? "" : "s") still uploading to MUSE").padding(.bottom, 12)
                }
                if items.isEmpty {
                    Text("No guides yet · ask Claude to render them, or render from Blender into ~/MUSE/CameraSessions/\(session.id)/out/ and the Mac app uploads them.")
                        .font(t.body(13)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(items) { g in
                    HStack(spacing: 14) {
                        GuideThumb(item: g).frame(width: g.isImage ? 40 : 54, height: 70)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g.label).font(t.mono(12, .semibold)).foregroundStyle(t.ink)
                            Text([g.size, "from \(g.source)", g.asset.createdAt.map { CameraText.ago($0, now: Date().timeIntervalSince1970 * 1000) }]
                                .compactMap { $0 }.joined(separator: " · ")).font(t.body(12)).foregroundStyle(t.muted)
                        }
                        Spacer()
                        if let u = g.asset.url, let url = URL(string: u) {
                            MButton(g.isVideo ? "Play" : "Open", icon: g.isVideo ? "play.fill" : "arrow.up.right", size: .small) { openURL(url) }
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }
                }
            }
        }
    }
}

/// History tab: newest first, Claude's steps, notes and uploads, grouped.
struct CameraHistoryTab: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var now: Double

    var body: some View {
        let entries = CameraHistory.entries(session, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty { Text("Nothing yet.").font(t.body(13)).foregroundStyle(t.muted) }
                ForEach(entries) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(e.ok ? t.ink : t.accent).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(t.body(13, .semibold)).foregroundStyle(t.ink)
                            if let d = e.detail { Text(d).font(t.body(12)).foregroundStyle(t.muted).lineLimit(3) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 1) }
                }
            }
        }
    }
}

/// Picking a session: a list row (title, cast, duration, rev, status pill).
struct CameraSessionRow: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var selected: Bool

    var body: some View {
        let pill = CameraText.statusPill(session)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(t.body(13.5, .semibold)).foregroundStyle(t.ink).lineLimit(1)
                Spacer(minLength: 6)
                Pill(pill.text, pill.tone == .good ? .good : pill.tone == .warn ? .warn : pill.tone == .bad ? .acc : .neutral)
            }
            Text(CameraText.cast(session)).font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
            Text("\(CameraText.idChip(session.id)) · \(CameraText.seconds(session.durationSec)) · rev \(session.revision)").font(t.mono(11)).foregroundStyle(t.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(selected ? t.surface2 : .clear))
        .overlay(alignment: .leading) { if selected { Rectangle().fill(t.accent).frame(width: 2) } }
        .contentShape(Rectangle())
    }
}

/// "New session": title, length, aspect and up to 3 of the studio's characters.
struct NewCameraSessionSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    var model: CameraModel
    var defaultTitle = ""
    var onCreated: (CameraSession) -> Void = { _ in }

    @State private var title = ""
    @State private var seconds = 6
    @State private var aspect = "9:16"
    @State private var cast: [String] = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            H2("New camera session")
            Field("Title") { TextField("Café walk-and-talk", text: $title).fieldChrome() }
            HStack(spacing: 24) {
                Field("Length") {
                    NumStepper(value: seconds, dec: { seconds = max(1, seconds - 1) }, inc: { seconds = min(30, seconds + 1) })
                }
                Field("Aspect") { Seg(["9:16", "16:9", "1:1", "4:5"].map { ($0, $0) }, selection: $aspect).frame(width: 300) }
            }
            Field("Cast · up to 3") {
                FlowLayout(spacing: 6) {
                    ForEach(store.models.filter { $0.archivedAt == nil }) { m in
                        Chip(m.name, on: cast.contains(m.id)) {
                            if let i = cast.firstIndex(of: m.id) { cast.remove(at: i) } else if cast.count < 3 { cast.append(m.id) }
                        }
                    }
                }
            }
            Muted("Claude and Blender keep each character to their sheet's height (1.68 m unless set). Keep to one camera move per shot.")
            HStack {
                Spacer()
                MButton("Cancel") { dismiss() }
                MButton("Create session", kind: .primary, off: busy) {
                    busy = true
                    Task {
                        let s = await model.create(title: title.isEmpty ? defaultTitle : title, durationSec: Double(seconds), aspect: aspect, cast: cast)
                        busy = false
                        if let s { onCreated(s); dismiss() }
                    }
                }
            }
            if let e = model.loadError { Text(e).font(t.body(12)).foregroundStyle(t.accent) }
        }
        .padding(24)
        .frame(width: 560)
        .background(t.bg)
        .onAppear { if title.isEmpty { title = defaultTitle } }
    }
}
