import MuseCore
import SwiftUI

/// Files on this Mac (owner, 2026-11-11): the approval cards of one chat, above its composer. Each says exactly what Claude
/// wants to do (read a file, change a file, run a command…) and waits: nothing happens until the person answers, and a
/// stopped or finished turn ends its cards as a no. Commands never offer "Always".
struct ClaudeFileApprovals: View {
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared
    let threadId: String
    var chatTitle: String?

    var body: some View {
        let asks = service.fileAsks(threadId: threadId)
        if !asks.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(asks) { a in card(a) }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
        }
    }

    private func card(_ a: ClaudeCodeService.FileAsk) -> some View {
        let r = t.roles
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text("Claude asks: \(a.card.action)").scaled(t.scale.body, r.ink)
            Text(a.card.detail)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(r.ink)
                .lineLimit(6).truncationMode(.middle).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let f = a.card.folder { Text("Folder: \(f)").scaled(t.scale.caption, r.ink2).lineLimit(1).truncationMode(.middle) }
            if let why = a.card.alwaysAsksBecause { Text(why).scaled(t.scale.caption, r.ink2) }
            HStack(spacing: Space.s2) {
                RButton("Allow once", kind: .action, small: true) { service.answerFile(a.id, .allowOnce) }
                if let f = a.card.folder {
                    RButton("Always allow in this folder (this chat)", kind: .quiet, small: true) {
                        service.answerFile(a.id, .alwaysFolder(f), chatTitle: chatTitle)
                    }
                }
                RButton("Deny", kind: .plain, small: true) { service.answerFile(a.id, .deny) }
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(r.raised))
        .overlay(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).stroke(r.hairline, lineWidth: 1))
    }
}

/// Settings → Account → Claude: files on this Mac (each person's own), and the folders they always allowed.
struct ClaudeFileSettingsSection: View {
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared

    var body: some View {
        let s = service.fileSettings
        SectionTitle("Claude")
        SettingRow("Files on this Mac", hint: s.mode == .ask
                   ? "Claude asks in the chat before it reads or changes a file or runs a command. Keys, passwords and tokens are never shared."
                   : "Claude can't read, change or run anything on this Mac") {
            Picker("Files on this Mac", selection: Binding(get: { s.mode }, set: { service.setFileMode($0) })) {
                ForEach(ClaudeFileMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        SettingRow("When results arrive", hint: s.resultMode == .look
                   ? "When something you started from a chat finishes, Claude looks at it and tells you in that chat (a notification too)."
                   : "A notification only; Claude looks when you ask") {
            Picker("When results arrive", selection: Binding(get: { s.resultMode }, set: { service.setResultMode($0) })) {
                ForEach(ClaudeResultMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        SettingRow("Let Claude operate MUSE's screen", hint: s.uiOn
                   ? "When no MUSE tool covers what you asked, Claude can press, type and pick in this window (never other apps). A ring shows what it touches; press Esc to stop it. Keys, prices, sign-out, payments and deletes stay yours."
                   : "Claude uses MUSE's own tools only and tells you what to press") {
            Toggle("Let Claude operate MUSE's screen", isOn: Binding(get: { s.uiOn }, set: { service.setUiControl($0) }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("settings.claude.uiControl")
        }
        if !s.folders.isEmpty {
            Text("Always allowed").scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s3)
            ForEach(s.folders) { f in
                SettingRow(f.folder, hint: "In “\(f.chatTitle ?? "a chat")”") {
                    RButton("Remove", kind: .plain, small: true) { service.removeAllowedFolder(f.id) }
                }
            }
        }
    }
}

/// The dot on the Claude button: results arrived while the panel was closed.
struct ClaudeResultDot: View {
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared

    var body: some View {
        if service.unseenResults > 0 {
            Circle().fill(t.roles.accent).frame(width: 7, height: 7).offset(x: -3, y: 3)
                .accessibilityLabel("\(service.unseenResults) result\(service.unseenResults == 1 ? "" : "s") arrived")
        }
    }
}
