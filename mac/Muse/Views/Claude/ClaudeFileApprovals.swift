import MuseCore
import SwiftUI

/// Files on this Mac (owner, 2026-11-11; Allow always 2026-11-12): the approval cards of one chat, above its composer. Each
/// says exactly what Claude wants to do (read a file, change a file, run a command…) and waits: nothing happens until the
/// person answers, and a stopped or finished turn ends its cards as a no. "Allow always" saves the folder, or the kind of
/// command ("Allow always: ffmpeg commands"), for every chat on this Mac; deleting, moving, network, installs, admin rights,
/// ~/Library and chained commands never offer it and say why in one line.
struct ClaudeFileApprovals: View {
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared
    let threadId: String
    var chatTitle: String?

    var body: some View {
        let asks = service.fileAsks(threadId: threadId)
        if !asks.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                ForEach(asks) { a in ClaudeFileCardView(card: a.card, id: a.id) }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
        }
    }
}

/// One approval card: what Claude wants, then Allow once, Allow always (when offered) and a quiet Deny.
struct ClaudeFileCardView: View {
    @Environment(\.theme) private var t
    let card: ClaudeFileCard
    let id: String
    var answer: (ClaudePermissionAnswer) -> Void = { _ in }

    init(card: ClaudeFileCard, id: String, answer: ((ClaudePermissionAnswer) -> Void)? = nil) {
        self.card = card
        self.id = id
        self.answer = answer ?? { a in ClaudeCodeService.shared.answerFile(id, a) }
    }

    var body: some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Claude asks: \(card.action)").scaled(t.scale.body, r.ink)
            Text(card.detail)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(r.ink)
                .lineLimit(6).truncationMode(.middle).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let why = card.alwaysAsksBecause {
                Text(why).scaled(t.scale.caption, r.ink2).lineLimit(2)
                    .accessibilityIdentifier("claude.card.why")
            } else if let covers = card.alwaysCovers(home: NSHomeDirectory()) {
                Text(covers).scaled(t.scale.caption, r.ink2).lineLimit(2).truncationMode(.middle)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s2) { buttons }
                VStack(alignment: .leading, spacing: Space.s2) { buttons }
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(r.raised))
        .overlay(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).stroke(r.hairline, lineWidth: 1))
    }

    @ViewBuilder private var buttons: some View {
        RButton("Allow once", kind: .action, small: true) { answer(.allowOnce) }
            .accessibilityIdentifier("claude.card.allowOnce")
        if let always = card.alwaysLabel {
            RButton(always, kind: .quiet, small: true) { answer(.always) }
                .fixedSize()
                .accessibilityIdentifier("claude.card.allowAlways")
        }
        RButton("Deny", kind: .plain, small: true) { answer(.deny) }
            .accessibilityIdentifier("claude.card.deny")
    }
}

/// Settings → Account → Claude: files on this Mac (each person's own), the "Always allowed" list (folders and kinds of
/// command, for every chat on this Mac) and "Ask before anything", which pauses the whole list.
struct ClaudeFileSettingsSection: View {
    @Environment(\.theme) private var t
    @ObservedObject private var service: ClaudeCodeService = .shared

    private func short(_ p: String) -> String {
        let home = NSHomeDirectory()
        return ClaudeFilePolicy.inside(p, home) ? "~" + p.dropFirst(home.count) : p
    }

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
        if s.mode == .ask {
            SettingRow("Ask before anything", hint: s.askAll
                       ? "Every file and command asks, and the Always allowed list is paused"
                       : "Folders and commands you always allowed run without asking. Deleting, moving, network, installs and ~/Library always ask.") {
                Toggle("Ask before anything", isOn: Binding(get: { s.askAll }, set: { service.setAskEverything($0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier("settings.claude.askEverything")
            }
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "settings ask before anything") } }
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
        if s.mode == .ask {
            Text(s.askAll ? "Always allowed (paused)" : "Always allowed")
                .scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s3)
                .accessibilityIdentifier("settings.claude.alwaysAllowed")
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "settings always allowed") } }
            if s.allowedFolders.isEmpty && s.rules.isEmpty {
                SettingRow("Nothing yet", hint: "Choose Allow always on a card in a chat") { EmptyView() }
            }
            ForEach(s.allowedFolders, id: \.self) { f in
                SettingRow(short(f), hint: "Folder: Claude reads and writes here in every chat") {
                    RButton("Remove", kind: .plain, small: true) { service.removeAllowedFolder(f) }
                        .accessibilityLabel("Remove \(short(f))")
                }
                .opacity(s.askAll ? 0.6 : 1)
            }
            ForEach(s.rules) { rule in
                SettingRow(rule.label, hint: "Runs without asking inside your allowed folders") {
                    RButton("Remove", kind: .plain, small: true) { service.removeCommandRule(rule.id) }
                        .accessibilityLabel("Remove \(rule.label)")
                }
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "settings rule \(rule.label)") } }
                .opacity(s.askAll ? 0.6 : 1)
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
