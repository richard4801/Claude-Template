import SwiftUI

/// Debug-only switch and status for the Blender relay (owner only; place it in Settings → Developer).
struct BlenderRelayDebugView: View {
    @ObservedObject var service: BlenderRelayService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Blender relay (debug)", isOn: $service.enabled)
            if service.enabled {
                line("Relay", service.running ? "On" : "Off (owner, signed in to a MUSE server)")
                line("Blender", service.blenderConnected ? "Connected\(service.addonVersion.map { " · add-on \($0)" } ?? "")" : "Not connected (127.0.0.1:9876)")
                line("Last call", service.lastCall ?? "—")
                if let u = service.lastUpload { line("Last upload", u) }
                if let e = service.lastError { line("Last error", e) }
            }
        }
        .font(.system(size: 12))
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}
