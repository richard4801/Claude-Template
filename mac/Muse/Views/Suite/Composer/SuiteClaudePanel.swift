import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

// Claude in the AI Suite (owner only): the header's "Claude" opens this panel in the picture's place, beside the Setup rail,
// so the rows Claude fills stay in view. It is the editor's chat (ClaudeChatView) on a "suite" thread for the shared draft,
// with the chips; demo mode has no Claude Code, so a stand-in chat fills the composer the same way. Claude's paid asks wait
// in the panel and open the Generate confirmation; nothing runs without the owner's press there.

struct SuiteClaudePanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let c = store.suite.claude
        VStack(spacing: 0) {
            HStack(spacing: Space.s2) {
                ClaudeBadge()
                Text("Fills in this composer").scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                Spacer(minLength: Space.s2)
                SuiteIconButton(systemName: "xmark", label: "Hide Claude", size: 26) { store.toggleSuiteClaude() }
            }
            .padding(.horizontal, Space.s3)
            .frame(height: 44)
            SuiteRule()
            if let p = c.ask { SuiteClaudeAskRow(pending: p) }
            if c.ask == nil, let f = c.assist?.failed {
                InlineNotice("The shot Claude asked for didn't run. \(f.error ?? "It couldn't start.")", tone: .danger)
                    .padding(.horizontal, Space.s3)
                    .padding(.top, Space.s2)
            }
            if !c.rejected.isEmpty { rejectedNotice(c.rejected) }
            chat(c)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.raised))
        .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
        .overlay(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(t.roles.hairline, lineWidth: 1))
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "claude panel") } }
        .accessibilityElement(children: .contain)
        // Reference images dropped anywhere on the panel attach to the next message.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            store.attachSuiteClaudeImages(urls: files)
            if files.count < urls.count { store.suite.claude.attachNote = SuiteClaudeAttachments.refusal }
            return !files.isEmpty
        }
    }

    @ViewBuilder private func chat(_ c: SuiteClaudeBridge) -> some View {
        if store.isDemo {
            SuiteClaudeDemoChat()
        } else if let e = c.error {
            VStack(alignment: .leading, spacing: Space.s3) {
                InlineNotice(e, tone: .caution)
                RButton("Try again", kind: .plain, small: true) { c.error = nil; Task { await store.ensureSuiteAssist() } }
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let a = c.assist {
            ClaudeChatView(contextKind: "suite", contextId: a.id, title: "Claude", showsHeader: false,
                           placeholder: "Describe the shot you want…",
                           suggestions: SuiteAssistClaude.suggestions,
                           emptyHint: "Tell Claude the shot you want. It fills in the character, the prompt and every Setup row with options the composer offers, and says what it set. You can change anything by hand; Claude sees it. Nothing is generated until you confirm the price.",
                           wrapOutgoing: { [store] text in store.suiteClaudeOutgoing(text) },
                           unwrapShown: SuiteAssistClaude.stripContext, sendShortcut: false)
                .attachments(top: AnyView(SuiteClaudeAttachRow()), sendBlocked: c.uploading, userImages: SuiteClaudeAttachments.images(in:))
        } else {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Sharing the composer with Claude…").scaled(t.scale.caption, t.roles.ink2)
                SkeletonBlock(width: 220, height: 10)
                SkeletonBlock(width: 160, height: 10)
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// What the composer didn't take from Claude's last draft, with the reason (Claude gets the same list next turn).
    private func rejectedNotice(_ list: [SuiteDraftRejection]) -> some View {
        let shown = list.prefix(3).map(\.text).joined(separator: ". ")
        let more = list.count > 3 ? ". And \(list.count - 3) more." : "."
        return InlineNotice("Left as they were: \(shown)\(more)", tone: .caution)
            .padding(.horizontal, Space.s3)
            .padding(.top, Space.s2)
    }
}

/// "Claude wants to generate this shot · $0.16": Decline, or open the Generate confirmation. The row itself never spends.
struct SuiteClaudeAskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var pending: SuitePending

    var body: some View {
        let c = store.suite.claude
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text("Claude wants to generate this shot").scaled(t.scale.label, t.roles.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s2)
                Text(Pricing.money(pending.maxUsd)).font(t.scale.label.font).monospacedDigit().foregroundStyle(t.roles.ink)
            }
            if let note = c.priceNote { Text(note).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Space.s2) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Decline", disabled: c.answering) { store.answerSuiteAsk(approve: false) }
                    .accessibilityLabel("Decline Claude's request to generate")
                SuiteToolButton(title: "Review price", accent: true, disabled: c.answering) { c.confirmOpen = true }
                    .help("Opens the Generate confirmation. Nothing is spent until you press Generate there.")
            }
        }
        .padding(Space.s3)
        .background(t.roles.field)
        .accessibilityElement(children: .contain)
    }
}

/// The composer's Generate confirmation for Claude's ask: the shot, its price and "Generate · $x". Only this press approves.
struct SuiteClaudeGenerateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var pending: SuitePending

    var body: some View {
        let c = store.suite.claude
        let d = store.suite.composer
        let price = Pricing.money(pending.maxUsd)
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s2) {
                ClaudeBadge()
                Text("Claude is asking").scaled(t.scale.caption, t.roles.ink2)
            }
            Text("Generate this shot for \(price)?").scaled(t.scale.title, t.roles.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s1) {
                let text = d.tokens.promptText()
                Text(text.isEmpty ? "No prompt" : text).scaled(t.scale.body, t.roles.ink).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(SuiteText.tierLabel(d.quality)), \(d.aspect), \(d.duration) seconds, \(d.takes) take\(d.takes == 1 ? "" : "s")")
                    .scaled(t.scale.caption, t.roles.ink2)
            }
            Text(c.priceNote ?? "It's charged to the studio like any shot, and a take that fails is refunded.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Decline", disabled: c.answering) {
                    c.confirmOpen = false
                    store.answerSuiteAsk(approve: false)
                }
                .keyboardShortcut(.cancelAction)
                SuiteToolButton(title: "Generate · \(price)", accent: true, disabled: c.answering) {
                    c.confirmOpen = false
                    store.answerSuiteAsk(approve: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s5)
        .frame(width: 440, alignment: .leading)
        .background(t.roles.canvas)
    }
}

/// Demo mode's chat: the same chips and composer field; the replies are stand-ins that fill the composer through the same
/// shared draft and checks.
struct SuiteClaudeDemoChat: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var draft = ""

    var body: some View {
        let c = store.suite.claude
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        if c.demoLines.isEmpty {
                            Text("Tell Claude the shot you want. It fills in the character, the prompt and every Setup row, and says what it set. You can change anything by hand. Nothing is generated until you confirm the price.")
                                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(c.demoLines) { line in
                            if line.fromClaude { claude(line.text) } else { owner(line.text, images: line.images) }
                        }
                        if c.demoBusy {
                            VStack(alignment: .leading, spacing: Space.s2) {
                                SkeletonBlock(width: 200, height: 10)
                                SkeletonBlock(width: 140, height: 10)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s3)
                }
                .onChange(of: c.demoLines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
            composer(c)
        }
    }

    private func owner(_ text: String, images: [ImageRef]) -> some View {
        VStack(alignment: .trailing, spacing: Space.s1) {
            Text("You").scaled(t.scale.micro, t.roles.ink2)
            if !images.isEmpty {
                HStack(spacing: Space.s1) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, ref in
                        MuseImage(ref: ref, symbol: "photo")
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous))
                            .accessibilityLabel("Attached image")
                    }
                }
            }
            Text(text).scaled(t.scale.body, t.roles.ink)
                .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func claude(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("Claude").scaled(t.scale.micro, t.roles.ink2)
            Text(text).scaled(t.scale.body, t.roles.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composer(_ c: SuiteClaudeBridge) -> some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Space.s2) {
            FlowLayout(spacing: Space.s1) {
                ForEach(SuiteAssistClaude.suggestions) { s in
                    Button { store.sendSuiteClaudeDemo(s.prompt) } label: { Text(s.label).fixedSize() }
                        .buttonStyle(RButtonStyle(kind: .quiet, small: true, off: c.demoBusy))
                        .disabled(c.demoBusy)
                        .help(s.prompt)
                        .accessibilityLabel(s.label)
                }
            }
            SuiteClaudeAttachRow()
            HStack(alignment: .bottom, spacing: Space.s2) {
                TextField("Describe the shot you want…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .onSubmit(send)
                    .roleField(multiline: true)
                Button(action: send) { Ph("paperplane.fill", 14) }
                    .buttonStyle(RButtonStyle(kind: .action, off: empty || c.demoBusy || c.uploading))
                    .frame(width: 40)
                    .disabled(empty || c.demoBusy || c.uploading)
                    .help("Send to Claude")
                    .accessibilityLabel("Send to Claude")
                    // No ⌘Return here: in the composer that is Generate's.
            }
            Text("Demo: Claude's replies here are stand-ins").scaled(t.scale.micro, t.roles.ink2).lineLimit(1)
        }
        .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s4)
        .overlay(alignment: .top) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
    }

    private func send() {
        let text = draft
        draft = ""
        store.sendSuiteClaudeDemo(text)
    }
}

/// Over the chat's field: "Attach images" and the images waiting to go with the next message, each removable. Up to 4,
/// JPEG, PNG, WebP or HEIC; anything else is refused in plain words. ⌘V with an image on the pasteboard attaches it (text
/// pastes as usual); a drop on the panel does too.
struct SuiteClaudeAttachRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let c = store.suite.claude
        let full = c.attachments.count >= SuiteClaudeAttachments.maxCount
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Button(action: pick) {
                    Ph("plus", 15).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(full ? t.roles.ink2.opacity(0.5) : t.roles.ink2)
                .disabled(full)
                .help("Attach images: up to 4, JPEG, PNG, WebP or HEIC. You can also drop or paste them.")
                .accessibilityLabel("Attach images")
                ForEach(c.attachments) { a in thumb(a) }
                Spacer(minLength: 0)
            }
            .background { if SnapshotRunner.probing && !c.attachments.isEmpty { ComposerBarFrame(key: "claude attachments") } }
            if let note = c.attachNote {
                Text(note).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            // ⌘V: an image on the pasteboard attaches; anything else is passed on to the field as a normal paste.
            Button("Paste") { paste() }
                .keyboardShortcut("v", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func thumb(_ a: SuiteClaudeBridge.Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = NSImage(data: a.data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(t.roles.field)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous))
            .overlay {
                if a.uploading { ProgressView().controlSize(.small) }
                if a.error != nil { Ph("warning", 14).foregroundStyle(t.roles.danger) }
            }
            Button { store.removeSuiteClaudeAttachment(a.id) } label: {
                Ph("x", 10).foregroundStyle(t.roles.ink)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(t.roles.raised))
                    .overlay(Circle().strokeBorder(t.roles.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove \(a.name)")
            .accessibilityLabel("Remove \(a.name)")
        }
        .help(a.error ?? a.name)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .webP, .heic, .heif]
        panel.message = SuiteClaudeAttachments.refusal
        guard panel.runModal() == .OK else { return }
        store.attachSuiteClaudeImages(urls: panel.urls)
    }

    private func paste() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            store.attachSuiteClaudeImages(urls: urls)
            return
        }
        if pb.string(forType: .string) == nil {
            if let png = pb.data(forType: .png) {
                store.attachSuiteClaudeImages([(name: "Pasted image.png", data: png, mime: "image/png")])
                return
            }
            if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                store.attachSuiteClaudeImages([(name: "Pasted image.png", data: png, mime: "image/png")])
                return
            }
        }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
    }
}
