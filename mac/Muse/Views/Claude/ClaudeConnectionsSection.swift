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
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Claude on your plan")
            Muted("Chats in MUSE run in Anthropic's Claude Code on this Mac, signed in to your Claude subscription. Your phone's chats are answered here while this Mac is on. MUSE never sees your Claude password or keys.", size: 13)
            VStack(alignment: .leading, spacing: 8) {
                line("Claude Code", codeLine, codeTone)
                line("This Mac", service.configured ? (service.answeringFromPhone ? "Answering from your phone" : "Ready for your phone's chats") : "Off (owner, signed in to a MUSE server)",
                     service.configured && service.info.ready ? .good : .off)
                if let m = service.info.model { line("Model", m, .neutral) }
                if let e = service.lastError { line("Last error", e, .bad) }
                HStack(spacing: 8) {
                    if !service.info.installed {
                        MButton("Install", icon: "arrow.down.circle", kind: .primary, size: .small) { service.openInstall() }
                    }
                    if !service.info.signedIn {
                        MButton("Sign in", icon: "person.crop.circle", kind: service.info.installed ? .primary : .secondary, size: .small, off: !service.info.installed) {
                            service.openSignIn()
                        }
                    }
                    MButton(service.checking ? "Checking…" : "Re-check", icon: "arrow.clockwise", size: .small, off: service.checking) {
                        Task { await service.recheck() }
                    }
                }
                if !service.info.installed {
                    Muted("Install opens Terminal and runs Anthropic's official installer. Sign in opens Claude's own sign-in page.")
                }
            }
            .padding(14)
            .surface(shadow: .none)

            OptionRow(title: "Use the studio API key when Claude Code can't answer",
                      hint: fallbackHint) {
                MToggle(isOn: Binding(get: { service.status?.apiFallback.enabled ?? false }, set: { on in
                    savingFallback = true
                    Task {
                        await service.setApiFallback(on)
                        savingFallback = false
                    }
                }))
                .disabled(savingFallback || service.status?.apiFallback.available != true)
            }

            SectionHeader("Add MUSE to Claude")
            Muted("Use MUSE from the Claude apps on your phone and desktop, on your Claude plan.", size: 13)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(t.mono(11, .semibold)).foregroundStyle(t.muted)
                        Text(s).font(t.body(13)).foregroundStyle(t.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Text(connectorUrl).font(t.mono(12)).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MButton(copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc", size: .small) {
                        CameraModel.copy(connectorUrl)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface))
                .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                LinkText("Open claude.ai connector settings") {
                    if let u = URL(string: "https://claude.ai/settings/connectors") { openURL(u) }
                }
            }
        }
        .padding(.bottom, 4)
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
        let v = service.info.version.map { " · \($0)" } ?? ""
        if !service.info.installed { return "Not installed" }
        if !service.info.signedIn { return "Installed\(v) · signed out" }
        return "Signed in\(v)"
    }

    private var codeTone: CameraTone { service.info.ready ? .good : service.info.installed ? .warn : .off }

    private func line(_ label: String, _ value: String, _ tone: CameraTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(tone == .good ? t.good : tone == .warn ? t.warn : tone == .bad ? t.accent : tone == .off ? t.muted : t.line).frame(width: 7, height: 7)
            Text(label).font(t.body(13, .semibold)).foregroundStyle(t.ink).frame(width: 90, alignment: .leading)
            Text(value).font(t.body(13)).foregroundStyle(tone == .bad ? t.accent : t.ink).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}
