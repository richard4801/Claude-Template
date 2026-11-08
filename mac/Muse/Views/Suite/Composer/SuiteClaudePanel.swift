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
                           placeholder: "Describe the shot…",
                           suggestions: SuiteAssistClaude.suggestions,
                           emptyHint: SuiteClaudeWords.emptyHint,
                           wrapOutgoing: { [store] text in store.suiteClaudeOutgoing(text) },
                           unwrapShown: SuiteAssistClaude.stripContext, sendShortcut: false)
                .attachments(top: AnyView(SuiteClaudeAttachRow(inComposer: true)), sendBlocked: c.uploading, userImages: SuiteClaudeAttachments.images(in:),
                             takeFiles: { [store] tid in store.suiteClaudeTakeFiles(threadId: tid) },
                             attach: { [store] in SuiteClaudeAttachRow.pick(store) },
                             images: { [store] urls, data in SuiteClaudeAttachRow.take(store, urls: urls, data: data) })
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

/// "Claude wants to generate · $0.16": Decline, or open the Generate confirmation. The row itself never spends.
struct SuiteClaudeAskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var pending: SuitePending

    var body: some View {
        let c = store.suite.claude
        let seconds = c.assist?.request?.duration ?? store.suite.composer.duration
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(SuiteClaudeWords.askTitle).scaled(t.scale.label, t.roles.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(c.priceNote ?? SuiteClaudeWords.askBody).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s2) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Decline", disabled: c.answering) { store.answerSuiteAsk(approve: false) }
                    .accessibilityLabel("Decline Claude's request to generate")
                // Opens the confirmation (where the press approves); the row itself never spends.
                SuiteToolButton(title: SuiteClaudeWords.generate(seconds: seconds, usd: pending.maxUsd), disabled: c.answering) { c.confirmOpen = true }
                    .help("Opens the confirmation. Nothing is made until you press Generate there.")
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
        // The shot's real length: the server's request for the draft, else the composer's.
        let seconds = c.assist?.request?.duration ?? d.duration
        let generate = SuiteClaudeWords.generate(seconds: seconds, usd: pending.maxUsd)
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s2) {
                ClaudeBadge()
                Text(SuiteClaudeWords.askTitle).scaled(t.scale.title, t.roles.ink)
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                let text = d.tokens.promptText()
                Text(text.isEmpty ? "No prompt" : text).scaled(t.scale.body, t.roles.ink).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(SuiteText.tierLabel(d.quality)), \(d.aspect), \(d.duration) seconds, \(d.takes) take\(d.takes == 1 ? "" : "s")")
                    .scaled(t.scale.caption, t.roles.ink2)
            }
            Text(c.priceNote ?? SuiteClaudeWords.askBody)
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Decline", disabled: c.answering) {
                    c.confirmOpen = false
                    store.answerSuiteAsk(approve: false)
                }
                .keyboardShortcut(.cancelAction)
                SuiteToolButton(title: generate, accent: true, disabled: c.answering) {
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

/// Demo mode's chat: the shared chat rows and composer (the same as ClaudeChatView); the replies are stand-ins that fill
/// the composer through the same shared draft and checks.
struct SuiteClaudeDemoChat: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var draft = ""

    var body: some View {
        let c = store.suite.claude
        VStack(spacing: 0) {
            ChatTranscriptView(rows: rows(c), state: ChatTranscriptState(busy: c.demoBusy, emptyHint: SuiteClaudeWords.emptyHint))
            ChatComposerBar(
                text: $draft,
                placeholder: "Describe the shot…",
                busy: false,
                held: c.demoBusy || c.uploading,
                suggestions: SuiteAssistClaude.suggestions,
                top: AnyView(SuiteClaudeAttachRow(inComposer: true)),
                footer: ["Demo: Claude's replies here are stand-ins"],
                commandReturnSends: false,   // ⌘Return is Generate's in the composer
                onSend: send,
                onStop: {},
                onSuggestion: { store.sendSuiteClaudeDemo($0) },
                onAttach: { SuiteClaudeAttachRow.pick(store) },
                onImages: { urls, data in SuiteClaudeAttachRow.take(store, urls: urls, data: data) })
        }
        .onAppear { if SnapshotRunner.probing, let text = SnapshotRunner.state.chatComposerText { draft = text } }
        .onChange(of: SnapshotRunner.state.chatComposerText) { _, v in if SnapshotRunner.probing { draft = v ?? "" } }
    }

    private func rows(_ c: SuiteClaudeBridge) -> [ChatRow] {
        var out: [ChatRow] = []
        // Review mode: the sample thread first, so the Suite's shots show every kind of row.
        if SnapshotRunner.probing, SnapshotRunner.state.chatSample {
            var tr = ClaudeTranscript()
            tr.load(ClaudeChatSample.messages(threadId: "suite_demo", kind: "suite"))
            out = ChatRow.build(tr.items, audience: .owner, unwrap: SuiteAssistClaude.stripContext) { _ in [] }
        }
        for line in c.demoLines {
            let id = line.id.uuidString
            if line.fromClaude {
                out.append(ChatRow(id: id, kind: .assistant(text: ChatLeakFilter.reply(line.text), streaming: false)))
            } else {
                out.append(ChatRow(id: id, kind: .user(text: ChatLeakFilter.userText(line.text), images: line.images.map { ChatImage(ref: $0) }, phone: false)))
            }
        }
        return out
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
    /// Inside the shared chat composer: its "+" attaches and its field takes pasted images, so this row only shows the
    /// images waiting to go (and nothing when there are none).
    var inComposer = false

    var body: some View {
        let c = store.suite.claude
        let full = c.attachments.count >= SuiteClaudeAttachments.maxCount
        if inComposer && c.attachments.isEmpty && c.attachNote == nil {
            EmptyView()
        } else {
            rowBody(c, full: full)
        }
    }

    @ViewBuilder private func rowBody(_ c: SuiteClaudeBridge, full: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                if !inComposer {
                Button(action: { SuiteClaudeAttachRow.pick(store) }) {
                    Ph("plus", 15).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(full ? t.roles.ink2.opacity(0.5) : t.roles.ink2)
                .disabled(full)
                .help("Attach images: up to 4, JPEG, PNG, WebP or HEIC. You can also drop or paste them.")
                .accessibilityLabel("Attach images")
                }
                ForEach(c.attachments) { a in thumb(a) }
                Spacer(minLength: 0)
            }
            .background { if SnapshotRunner.probing && !c.attachments.isEmpty { ComposerBarFrame(key: "claude attachments") } }
            if let note = c.attachNote {
                Text(note).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            // The server couldn't read an image (often HEIC): say so, and offer it again as JPEG.
            ForEach(c.attachments.filter { $0.error != nil }) { a in
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(a.error ?? "").scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    if a.unsupported {
                        Button("Send as JPEG") { store.resendSuiteClaudeAttachmentAsJPEG(a.id) }
                            .buttonStyle(RButtonStyle(kind: .quiet, small: true))
                    }
                }
            }
            // ⌘V: an image on the pasteboard attaches; anything else is passed on to the field as a normal paste.
            // (In the shared composer its own field does this.)
            if !inComposer {
                Button("Paste") { paste() }
                    .keyboardShortcut("v", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
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

    static func pick(_ store: AppStore) {
        // Review mode never opens a modal panel (it would stop the run).
        if SnapshotRunner.probing { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .webP, .heic, .heif]
        panel.message = SuiteClaudeAttachments.refusal
        guard panel.runModal() == .OK else { return }
        store.attachSuiteClaudeImages(urls: panel.urls)
    }

    /// Pasted or dropped on the shared composer: files by their links, image data as it is.
    static func take(_ store: AppStore, urls: [URL], data: [(name: String, data: Data, mime: String)]) {
        if !urls.isEmpty { store.attachSuiteClaudeImages(urls: urls) }
        if !data.isEmpty { store.attachSuiteClaudeImages(data.map { (name: $0.name, data: $0.data, mime: Optional($0.mime)) }) }
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

/// The shared draft's reference images in the composer (Inputs): "Pose", "Style", "Location" or "Outfit" with the image,
/// each with a remove button (the draft goes back without it).
struct SuiteClaudeReferenceChips: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let refs = store.suite.claude.references
        FlowLayout(spacing: Space.s1) {
            ForEach(refs) { r in chip(r) }
        }
        .background { if SnapshotRunner.probing && !refs.isEmpty { ComposerBarFrame(key: "claude references") } }
    }

    private func chip(_ r: SuiteDraftReference) -> some View {
        HStack(spacing: Space.s1) {
            MuseImage(ref: ImageRef(url: r.url), symbol: "photo")
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
            Text(r.title).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
            Button { store.removeSuiteClaudeReference(r) } label: {
                Ph("x", 10).foregroundStyle(t.roles.ink2).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this \(r.use) reference")
            .accessibilityLabel("Remove \(r.title) reference")
        }
        .padding(.leading, 3).padding(.trailing, Space.s1)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
        .help(r.label ?? "\(r.title) reference from Claude")
        .accessibilityElement(children: .contain)
    }
}

/// The words shared with the Android app (workstream 4), so both read the same.
enum SuiteClaudeWords {
    static let askTitle = "Claude wants to generate"
    static let askBody = "Check the composer, then approve. It runs at this price or not at all."
    static let emptyHint = "Describe the shot you want. Claude sets up the composer: the model, the prompt and the rig. You approve the price before anything is made."
    /// "Generate · 8 s · $0.40": the shot's seconds and the price being approved.
    static func generate(seconds: Int, usd: Double) -> String { "Generate · \(seconds) s · \(Pricing.money(usd))" }
}
