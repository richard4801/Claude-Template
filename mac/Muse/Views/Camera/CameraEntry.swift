import SwiftUI

// Entry points for workstream 2 (Camera stage, Directed mode, Connections). Stubs: workstream 2 replaces this file at merge.

/// Video suite → Camera stage.
struct CameraStageView: View {
    init() {}
    var body: some View {
        ContentUnavailableView("Camera stage", systemImage: "cube.transparent", description: Text("Block a shot in Blender and use it as the camera."))
    }
}

/// The camera bag's Directed · Blender tab. `onApply` gets a CameraSpec as JSON.
struct DirectedModePanel: View {
    let shotTitle: String
    let onApply: (String) -> Void
    init(shotTitle: String, onApply: @escaping (String) -> Void) {
        self.shotTitle = shotTitle
        self.onApply = onApply
    }
    var body: some View {
        ContentUnavailableView("Directed · Blender", systemImage: "move.3d", description: Text("Direct \(shotTitle) with a greybox from the Camera stage."))
    }
}

/// Settings → Connections (owner): Claude & MCP · Blender relay.
struct ConnectionsView: View {
    init() {}
    var body: some View {
        ContentUnavailableView("Connections", systemImage: "link", description: Text("Claude & MCP · Blender relay"))
    }
}
