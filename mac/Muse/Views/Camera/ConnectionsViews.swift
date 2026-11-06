import MuseCore
import SwiftUI

/// Settings → Connections (owner): Claude & MCP (URL, tokens, snippets), Claude on your plan, Add MUSE to Claude, the Blender
/// relay on this Mac, and the in-app chat.
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
        VStack(alignment: .leading, spacing: 0) {
            claudeSection
            // Claude on the owner's plan (Claude Code on this Mac, the API key fallback) and "Add MUSE to Claude".
            ClaudeConnectionsSection()
            blenderSection
            chatSection
        }
        .task {
            model.attach(store)
            await model.loadConnections()
        }
        .confirmationDialog("Revoke this token?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { tok in
            Button("Revoke “\(tok.name)”", role: .destructive) { Task { await model.revoke(tok.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Claude apps using it stop reaching MUSE at once.")
        }
    }

    // MARK: Claude & MCP

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Claude & MCP", top: 0) {
                if let docs = model.connections?.docsUrl, let url = URL(string: docs) { LinkText("Setup guide") { openURL(url) } }
            }
            Muted("Your own Claude (Claude Code or Claude Desktop) can open camera sessions, block them in Blender and leave a Shot draft. It never spends: you press Generate.", size: 13)
            Field("MUSE MCP URL") {
                copyRow(mcpUrl, key: "url")
            }
            Field("Tokens") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Token name, e.g. “MacBook · Claude Code”", text: $tokenName).fieldChrome()
                            .onSubmit(createToken)
                        MButton("New token", icon: "plus", kind: .primary, off: tokenName.trimmingCharacters(in: .whitespaces).isEmpty, action: createToken)
                    }
                    if let e = model.tokenError { Text(e).font(t.body(12)).foregroundStyle(t.accent) }
                    if let nt = model.newToken {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("“\(nt.name)” · copy it now").font(t.body(13, .bold)).foregroundStyle(t.warnInk)
                                Spacer()
                                Text("You won't see it again").font(t.body(12, .semibold)).foregroundStyle(t.warnInk)
                            }
                            copyRow(nt.token, key: "token")
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.warnBg))
                    }
                    if model.tokens.isEmpty {
                        Muted("No tokens yet.")
                    } else {
                        ListBox {
                            ForEach(Array(model.tokens.enumerated()), id: \.element.id) { i, tok in
                                ListRow(icon: "key", title: "\(tok.name) · \(CameraConnectionsText.prefix(tok))", hint: CameraConnectionsText.tokenLine(tok, now: model.now),
                                        last: i == model.tokens.count - 1) {
                                    MButton("Revoke", size: .small) { revoking = tok }
                                }
                            }
                        }
                    }
                }
            }
            Field("Claude Code") {
                VStack(alignment: .leading, spacing: 8) {
                    snippet(CameraConnectionsText.claudeCodeBlender(), key: "cc-blender")
                    snippet(CameraConnectionsText.claudeCode(url: mcpUrl, token: fresh), key: "cc-muse")
                }
            }
            Field("Claude Desktop · claude_desktop_config.json") {
                snippet(CameraConnectionsText.claudeDesktop(url: mcpUrl, token: fresh), key: "desktop")
            }
            if fresh == nil { Muted("The snippets show muse_pat_… until you make a token here; paste your token in its place.") }
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

    // MARK: Blender relay

    private var blenderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Blender relay")
            OptionRow(title: "Run Blender for MUSE on this Mac", hint: "Direct with Claude sends its Blender steps here, and renders in ~/MUSE/CameraSessions/<id>/out/ upload to their session.") {
                MToggle(isOn: $relay.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                statusLine("Mac app", relay.running ? "Online" : relay.enabled ? "Starting… (owner, signed in to a MUSE server)" : "Off", relay.running ? .good : .off)
                statusLine("Blender", relay.blenderConnected ? "Connected\(relay.addonVersion.map { " · add-on \($0)" } ?? "") · localhost:9876" : "Not connected (127.0.0.1:9876)",
                           relay.blenderConnected ? .good : relay.running ? .warn : .off)
                statusLine("Last call", relay.lastCall ?? "—", .neutral)
                if let u = relay.lastUpload { statusLine("Last upload", u, .neutral) }
                if let e = relay.lastError { statusLine("Last error", e, .bad) }
            }
            .padding(14)
            .surface(shadow: .none)
            VStack(alignment: .leading, spacing: 6) {
                Lbl("Install the Blender add-on")
                ForEach(Array(CameraConnectionsText.installSteps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(t.mono(11, .semibold)).foregroundStyle(t.muted)
                        Text(s).font(t.body(13)).foregroundStyle(t.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Muted("The add-on's port has no password: keep it on localhost and never run two Blender MCP servers on 9876.")
            }
        }
    }

    private func statusLine(_ label: String, _ value: String, _ tone: CameraTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(tone == .good ? t.good : tone == .warn ? t.warn : tone == .bad ? t.accent : tone == .off ? t.muted : t.line).frame(width: 7, height: 7)
            Text(label).font(t.body(13, .semibold)).foregroundStyle(t.ink).frame(width: 90, alignment: .leading)
            Text(value).font(t.body(13)).foregroundStyle(tone == .bad ? t.accent : t.ink).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    // MARK: In-app chat

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("In-app chat")
            let on = model.connections?.inAppChat
            HStack(spacing: 8) {
                Circle().fill(on == true ? t.good : t.muted).frame(width: 7, height: 7)
                Text(on.map(CameraConnectionsText.inAppChat) ?? "Checking…").font(t.body(13, .semibold)).foregroundStyle(t.ink)
            }
            if on == false { Muted("Without it you can still direct from your own Claude app with a token above.") }
        }
    }

    // MARK: Copy helpers

    private func copyRow(_ text: String, key: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(t.mono(12)).foregroundStyle(t.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton(text, key: key)
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
    }

    private func snippet(_ text: String, key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(t.mono(11.5)).foregroundStyle(t.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton(text, key: key)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
    }

    private func copyButton(_ text: String, key: String) -> some View {
        MButton(copied == key ? "Copied" : "Copy", icon: copied == key ? "checkmark" : "doc.on.doc", size: .small) {
            CameraModel.copy(text)
            copied = key
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if copied == key { copied = nil }
            }
        }
    }
}
