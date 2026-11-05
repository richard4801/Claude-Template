import MuseCore
import SwiftUI

// Workstream 2 entry points (agreed with workstream 1, who owns navigation and Settings rows):
//   CameraStageView()                               the "Camera stage" sidebar destination
//   DirectedModePanel(shotTitle:onApply:)           the "Directed · Blender" body inside the Camera control
//   ConnectionsView()                               Settings → Connections (owner)
// Everything is owner only; a member sees a short note (they never reach these screens through navigation anyway).

/// Camera stage: sessions list (title, cast, length, rev, status, Blender on Mac) + the Directed view of the selected one + New session.
struct CameraStageView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var model = CameraModel()
    @State private var creating = false

    init() {}

    var body: some View {
        OwnerOnly {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(t.line).frame(width: 1)
                if let s = model.selected {
                    DirectedBody(model: model, session: s)
                } else {
                    CameraEmptyState(loading: model.loading, error: model.loadError) { creating = true }
                }
            }
            .background(t.bg)
            .task { model.attach(store) }
            .onDisappear { model.stop() }
            .sheet(isPresented: $creating) { NewCameraSessionSheet(model: model) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Video suite").styled()
                Text("Camera stage").font(t.h2).foregroundStyle(t.ink)
                relayLine
            }
            MButton("New session", icon: "plus", kind: .primary, size: .small, fill: true) { creating = true }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sessions) { s in
                        CameraSessionRow(session: s, selected: s.id == model.selectedId)
                            .onTapGesture { model.select(s.id) }
                            .contextMenu {
                                Button("Copy session id") { CameraModel.copy(s.id) }
                                Button("Delete session", role: .destructive) { Task { await model.delete(s.id) } }
                            }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(t.chrome)
    }

    private var relayLine: some View {
        let r = model.connections?.relay ?? model.selected?.relay
        let row = CameraStatus.blender(r, machine: model.machine)
        let text = r?.blender == true ? "Blender on Mac · connected" : r?.online == true ? "Mac app online · Blender not connected" : "Blender on Mac · offline"
        return HStack(spacing: 6) {
            Circle().fill(row.tone == .good ? t.good : row.tone == .warn ? t.warn : t.muted).frame(width: 7, height: 7)
            Text(text).font(t.body(12)).foregroundStyle(t.muted)
        }
    }
}

/// Directed · Blender inside the Camera control: picks (or creates) a camera session and shows the D6 body. "Use for <shot>"
/// hands back the JSON CameraSpec (`{"mode":"directed","guide":{…}}`) from the session's Shot draft, making one first if needed.
struct DirectedModePanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var model = CameraModel()
    @State private var creating = false
    var shotTitle: String
    var onApply: (String) -> Void

    init(shotTitle: String, onApply: @escaping (String) -> Void) {
        self.shotTitle = shotTitle
        self.onApply = onApply
    }

    var body: some View {
        OwnerOnly {
            VStack(spacing: 0) {
                picker
                    .padding(.horizontal, 28).padding(.vertical, 8)
                if let s = model.selected {
                    DirectedBody(model: model, session: s, useLabel: "Use for \(shotTitle)", onUse: apply)
                } else {
                    CameraEmptyState(loading: model.loading, error: model.loadError) { creating = true }
                }
            }
            .background(t.bg)
            .task { model.attach(store) }
            .onDisappear { model.stop() }
            .sheet(isPresented: $creating) { NewCameraSessionSheet(model: model, defaultTitle: shotTitle) }
        }
    }

    private var picker: some View {
        HStack(spacing: 10) {
            Lbl("Camera session")
            Menu {
                ForEach(model.sessions) { s in
                    Button("\(s.title) · \(CameraText.idChip(s.id)) · rev \(s.revision)") { model.select(s.id) }
                }
                Divider()
                Button("New session…") { creating = true }
            } label: {
                Text(model.selected?.title ?? "Pick a session").font(t.body(13, .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            if model.selected != nil {
                MButton("Use for \(shotTitle)", icon: "checkmark", kind: .primary, size: .small, off: model.applying, action: apply)
                    .help("Put this session's guides and camera on the shot · nothing is generated until you press Generate")
            }
        }
    }

    private func apply() {
        Task {
            if let json = await model.handoff(prompt: shotTitle) { onApply(json) }
        }
    }
}

/// Settings → Connections (owner): Claude & MCP tokens and snippets, the Blender relay switch and status, the in-app chat.
struct ConnectionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var model = CameraModel()

    init() {}

    var body: some View {
        OwnerOnly {
            // Settings pages already scroll (Page): no ScrollView here.
            ConnectionsContent(model: model)
                .onDisappear { model.stop() }
        }
    }
}

// MARK: Shared bits

/// Members never see camera sessions (owner-only API).
private struct OwnerOnly<Content: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @ViewBuilder var content: () -> Content

    var body: some View {
        if store.isOwner || store.isDemo {
            content()
        } else {
            Text("Only the studio owner can use Directed camera sessions.").font(t.body(13)).foregroundStyle(t.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CameraEmptyState: View {
    @Environment(\.theme) private var t
    var loading: Bool
    var error: String?
    var onNew: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "cube.transparent").font(.system(size: 28)).foregroundStyle(t.muted)
                Text("No camera sessions yet").font(t.body(15, .bold)).foregroundStyle(t.ink)
                Text("Block a shot in Blender with Claude: who stands where, how they move, how the camera moves. MUSE keeps the guides and a Shot draft; you press Generate.")
                    .font(t.body(13)).foregroundStyle(t.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
                MButton("New session", icon: "plus", kind: .primary, action: onNew)
            }
            if let error { Text(error).font(t.body(12)).foregroundStyle(t.accent) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
