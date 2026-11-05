import SwiftUI

/// Developer view of the Blender relay (owner only). The real switch and status live in Settings → Connections
/// (`ConnectionsView`, Views/Camera); this compact one stays for Settings → Developer if wanted. Uses the theme tokens.
struct BlenderRelayDebugView: View {
    @Environment(\.theme) private var t
    @ObservedObject var service: BlenderRelayService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionRow(title: "Blender relay", hint: "Runs Blender steps for MUSE on this Mac (127.0.0.1:9876).") {
                MToggle(isOn: $service.enabled)
            }
            if service.enabled {
                line("Relay", service.running ? "On" : "Off (owner, signed in to a MUSE server)")
                line("Blender", service.blenderConnected ? "Connected\(service.addonVersion.map { " · add-on \($0)" } ?? "")" : "Not connected (127.0.0.1:9876)")
                line("Last call", service.lastCall ?? "—")
                if let u = service.lastUpload { line("Last upload", u) }
                if let e = service.lastError { line("Last error", e, error: true) }
            }
        }
    }

    private func line(_ label: String, _ value: String, error: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Lbl(label).frame(width: 90, alignment: .leading)
            Text(value).font(t.mono(12)).foregroundStyle(error ? t.accent : t.ink).textSelection(.enabled).lineLimit(3)
        }
    }
}
