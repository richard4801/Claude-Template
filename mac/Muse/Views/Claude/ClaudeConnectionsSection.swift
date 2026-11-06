import MuseCore
import SwiftUI

/// Settings → Connections (owner): "Claude on your plan" (Claude Code on this Mac: Install / Sign in / Re-check, the studio
/// API key fallback, off by default) and "Add MUSE to Claude" (the custom connector for the Claude apps).
struct ClaudeConnectionsSection: View {
    @Environment(\.theme) private var t
    @Environment(\.openURL) private var openURL
    @ObservedObject var service: ClaudeCodeService = .shared
    @State private var copied = false
    @State private var savingFallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionTitle("Claude on your plan", top: 0)
            Text("Chats in MUSE run in Anthropic's Claude Code on this Mac, signed in to your Claude subscription. Your phone's chats are answered here while this Mac is on. MUSE never sees your Claude password or keys.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Space.s2)
            line("Claude Code", codeLine, codeTone)
            line("This Mac", service.configured ? (service.answeringFromPhone ? "Answering from your phone" : "Ready for your phone's chats") : "Off (owner, signed in to a MUSE server)",
                 service.configured && service.info.ready ? .good : .off)
            if let m = service.info.model { line("Model", m, .neutral) }
            if let e = service.lastError { line("Last error", e, .bad) }
            HStack(spacing: Space.s2) {
                if !service.info.installed {
                    RButton("Install Claude Code", kind: .action, small: true) { service.openInstall() }
                }
                if !service.info.signedIn {
                    RButton("Sign in", kind: service.info.installed ? .action : .quiet, small: true, off: !service.info.installed) {
                        service.openSignIn()
                    }
                }
                RButton(service.checking ? "Checking…" : "Check again", kind: .plain, small: true, off: service.checking) {
                    Task { await service.recheck() }
                }
            }
            .padding(.top, Space.s2)
            if !service.info.installed {
                Text("Install opens Terminal and runs Anthropic's official installer. Sign in opens Claude's own sign-in page.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }

            SettingRow("Use the studio API key when Claude Code can't answer", hint: fallbackHint) {
                RSwitch(label: "Use the studio API key when Claude Code can't answer", isOn: Binding(get: { service.status?.apiFallback.enabled ?? false }, set: { on in
                    savingFallback = true
                    Task {
                        await service.setApiFallback(on)
                        savingFallback = false
                    }
                }))
                .disabled(savingFallback || service.status?.apiFallback.available != true)
            }
            .padding(.top, Space.s3)

            SectionTitle("Add MUSE to Claude")
            Text("Use MUSE from the Claude apps on your phone and desktop, on your Claude plan.")
                .scaled(t.scale.caption, t.roles.ink2).padding(.bottom, Space.s2)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text("\(i + 1)").monospacedDigit().scaled(t.scale.caption, t.roles.ink2).frame(width: 14, alignment: .leading)
                    Text(s).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.s2) {
                Text(connectorUrl).scaled(t.scale.body, t.roles.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RButton(copied ? "Copied" : "Copy URL", small: true) {
                    CameraModel.copy(connectorUrl)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
            }
            .padding(.leading, Space.s3).padding(.trailing, Space.s1).frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
            .padding(.top, Space.s2)
            RButton("Open claude.ai connector settings", kind: .plain, small: true) {
                if let u = URL(string: "https://claude.ai/settings/connectors") { openURL(u) }
            }
        }
        .padding(.bottom, Space.s1)
        .task { await service.refreshStatus() }
    }

    private var steps: [String] {
        ["On claude.ai, open Settings → Connectors.",
         "Choose Add custom connector and paste the URL below.",
         "Sign in with your MUSE owner account when Claude asks.",
         "MUSE then shows up in the Claude apps on your phone and desktop."]
    }

    private var connectorUrl: String { service.status?.connectorUrl.isEmpty == false ? service.status!.connectorUrl : "…/mcp" }

    private var fallbackHint: String {
        switch service.status?.apiFallback.available {
        case true?: return "Off by default. Billed per use to the studio's Anthropic API key, for when your Mac is off."
        case false?: return "Needs ANTHROPIC_API_KEY on the server. Billed per use."
        case nil: return "Billed per use."
        }
    }

    private var codeLine: String {
        if service.checking && !service.checkedOnce { return "Checking…" }
        let v = service.info.version.map { " (\($0))" } ?? ""
        if !service.info.installed { return "Not installed" }
        if !service.info.signedIn { return "Installed\(v), signed out" }
        return "Signed in\(v)"
    }

    private var codeTone: CameraTone { service.info.ready ? .good : service.info.installed ? .warn : .off }

    private func line(_ label: String, _ value: String, _ tone: CameraTone) -> some View {
        // State colour only with state: the value carries it; no dot.
        let r = t.roles
        let color: Color = tone == .good ? r.positive : tone == .warn ? r.caution : tone == .bad ? r.danger : tone == .off ? r.ink2 : r.ink
        return HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text(label).scaled(t.scale.caption, r.ink2).frame(width: 96, alignment: .leading)
            Text(value).scaled(t.scale.body, color).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}
