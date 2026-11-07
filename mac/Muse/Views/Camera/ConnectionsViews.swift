import MuseCore
import SwiftUI

/// Settings → Connections (owner): a normal Settings detail pane (plans/design-direction.md). New token first, then the MCP URL
/// and the snippets for Claude Code and Claude Desktop, Claude on your plan, Add MUSE to Claude, the Blender relay on this Mac,
/// and the in-app chat. Code (URL, tokens, snippets) is the one place for the monospaced face, in a padded code block.
struct ConnectionsContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.openURL) private var openURL
    @Bindable var model: CameraModel
    @ObservedObject var relay: BlenderRelayService = .shared

    @State private var tokenName = ""
    @State private var revoking: McpToken?
    @State private var copied: String?

    private var mcpUrl: String { model.connections?.mcpUrl ?? "…/mcp" }
    private var fresh: String? { model.newToken?.token }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            tokensSection
            claudeSection
            // Claude on the owner's plan (Claude Code on this Mac, the API key fallback) and "Add MUSE to Claude".
            ClaudeConnectionsSection().padding(.top, Space.s6)
            blenderSection.id("connections.blender")
            chatSection
        }
        .task {
            model.attach(store)
            await model.loadConnections()
        }
        .confirmationDialog("Revoke this token?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { tok in
            Button("Revoke “\(tok.name)”", role: .destructive) { Task { await model.revoke(tok.id) } }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text("Claude apps using it stop reaching MUSE at once.")
        }
    }

    // MARK: Tokens (first: the owner comes here for a new token)

    private var tokensSection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionTitle("Tokens", top: 0) {
                if let docs = model.connections?.docsUrl, let url = URL(string: docs) {
                    RButton("Setup guide", kind: .plain, small: true) { openURL(url) }
                }
            }
            Text("Your own Claude (Claude Code or Claude Desktop) uses a token to open camera sessions, block them in Blender and leave a Shot draft. It never spends: you press Generate.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            RField("New token") {
                HStack(spacing: Space.s2) {
                    RTextField(placeholder: "Name it, for example “MacBook · Claude Code”", text: $tokenName, onSubmit: createToken)
                    RButton("New token", kind: .action, off: tokenName.trimmingCharacters(in: .whitespaces).isEmpty, action: createToken)
                }
            }
            .padding(.top, Space.s2)
            if let e = model.tokenError { InlineNotice(e, tone: .danger) }
            if let nt = model.newToken {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Copy “\(nt.name)” now. You won't see it again.").scaled(t.scale.label, t.roles.caution)
                    codeLine(nt.token, key: "token")
                }
                .padding(.top, Space.s2)
            }
            if model.tokens.isEmpty {
                Text("No tokens yet.").scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s2)
            } else {
                ForEach(model.tokens, id: \.id) { tok in
                    SettingRow("\(tok.name) · \(CameraConnectionsText.prefix(tok))", hint: CameraConnectionsText.tokenLine(tok, now: model.now)) {
                        RButton("Revoke", kind: .plain, small: true) { revoking = tok }
                    }
                }
            }
        }
    }

    private func createToken() {
        let name = tokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            await model.createToken(name: name)
            if model.tokenError == nil { tokenName = "" }
        }
    }

    // MARK: Claude & MCP

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionTitle("Claude and MCP")
            RField("MUSE MCP URL") { codeLine(mcpUrl, key: "url") }
            RField("Claude Code") {
                VStack(alignment: .leading, spacing: Space.s2) {
                    codeBlock(CameraConnectionsText.claudeCodeBlender(), key: "cc-blender")
                    codeBlock(CameraConnectionsText.claudeCode(url: mcpUrl, token: fresh), key: "cc-muse")
                }
            }
            RField("Claude Desktop", hint: "claude_desktop_config.json") {
                codeBlock(CameraConnectionsText.claudeDesktop(url: mcpUrl, token: fresh), key: "desktop")
            }
            if fresh == nil {
                Text("The snippets show muse_pat_… until you make a token above; paste your token in its place.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Blender relay

    private var blenderSection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionTitle("Blender relay")
            SettingRow("Run Blender for MUSE on this Mac", hint: "Direct with Claude sends its Blender steps here, and renders in ~/MUSE/CameraSessions/<id>/out/ upload to their session.") {
                RSwitch(label: "Run Blender for MUSE on this Mac", isOn: $relay.enabled)
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                statusLine("Mac app", relay.running ? "Online" : relay.enabled ? "Starting… (owner, signed in to a MUSE server)" : "Off", relay.running ? .good : .off)
                statusLine("Blender", relay.blenderConnected ? "Connected\(relay.addonVersion.map { ", add-on \($0)" } ?? ""), localhost:9876" : "Not connected (127.0.0.1:9876)",
                           relay.blenderConnected ? .good : relay.running ? .warn : .off)
                statusLine("Last call", relay.lastCall ?? "None yet", .neutral)
                if let u = relay.lastUpload { statusLine("Last upload", u, .neutral) }
                if let e = relay.lastError { statusLine("Last error", e, .bad) }
            }
            .padding(.vertical, Space.s2)
            Text("Install the Blender add-on").scaled(t.scale.heading, t.roles.ink).padding(.top, Space.s3)
            ForEach(Array(CameraConnectionsText.installSteps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text("\(i + 1)").monospacedDigit().scaled(t.scale.caption, t.roles.ink2).frame(width: 14, alignment: .leading)
                    Text(s).scaled(t.scale.body, t.roles.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("The add-on's port has no password: keep it on localhost and never run two Blender MCP servers on 9876.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLine(_ label: String, _ value: String, _ tone: CameraTone) -> some View {
        let c: Color = tone == .good ? t.roles.positive : tone == .warn ? t.roles.caution : tone == .bad ? t.roles.danger : t.roles.ink2
        return HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Circle().fill(c).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(label).scaled(t.scale.label, t.roles.ink).frame(width: 96, alignment: .leading)
            Text(value).scaled(t.scale.body, tone == .bad ? t.roles.danger : t.roles.ink).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    // MARK: In-app chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionTitle("In-app chat")
            let on = model.connections?.inAppChat
            HStack(spacing: Space.s2) {
                Circle().fill(on == true ? t.roles.positive : t.roles.ink2).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(on.map(CameraConnectionsText.inAppChat) ?? "Checking…").scaled(t.scale.label, t.roles.ink)
            }
            if on == false {
                Text("Without it you can still direct from your own Claude app with a token above.").scaled(t.scale.caption, t.roles.ink2)
            }
        }
    }

    // MARK: Code

    /// One line of code (the URL, a fresh token): monospaced, padded, on the field tone, with Copy.
    private func codeLine(_ text: String, key: String) -> some View {
        HStack(spacing: Space.s2) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(t.roles.ink)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton(text, key: key)
        }
        .padding(.leading, Space.s3).padding(.trailing, Space.s2).padding(.vertical, Space.s2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
    }

    /// A snippet: monospaced, wraps, padded on every side, on the field tone, with Copy at the top right.
    private func codeBlock(_ text: String, key: String) -> some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(t.roles.ink).lineSpacing(2)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton(text, key: key)
        }
        .padding(Space.s3)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
    }

    private func copyButton(_ text: String, key: String) -> some View {
        RButton(copied == key ? "Copied" : "Copy", kind: .plain, small: true) {
            CameraModel.copy(text)
            copied = key
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copied == key { copied = nil }
            }
        }
    }
}
