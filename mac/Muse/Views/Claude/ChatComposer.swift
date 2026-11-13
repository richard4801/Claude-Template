import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// An image (or a video) waiting to go with the next message (Edit, Recreate and Camera keep images on this Mac; the Suite
/// uploads its own). A video's `data` is its poster frame (PNG), empty until it is read.
struct ChatPendingImage: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var data: Data
    var mime: String
    var video: ChatPendingVideo? = nil
    /// An image's upload on the MUSE server (started when it is attached), so Claude can use it in a shot by its id
    /// (suite_add_reference, set_sent_images). nil until it lands; the image still goes to Claude as a file without it.
    var uploadId: String? = nil
}

/// A video waiting to go: uploaded to the MUSE server as soon as it is picked (Claude watches it there, by its upload id).
struct ChatPendingVideo: Equatable {
    enum State: Equatable {
        case uploading
        case ready(uploadId: String)
        case failed(String)
    }
    var file: URL
    /// Its length in seconds (0 until read).
    var seconds: Double = 0
    var state: State = .uploading

    var uploading: Bool { state == .uploading }
    var uploadId: String? { if case .ready(let id) = state { return id }; return nil }
    var error: String? { if case .failed(let e) = state { return e }; return nil }
}

/// What the composer does with images (and videos) pasted or dropped on it.
enum ChatImageInput {
    static let types: [UTType] = [.jpeg, .png, .webP, .heic, .heif, .tiff, .gif]
    /// Videos Claude can watch: MP4 and MOV, 500 MB at most.
    static let videoTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]
    static let maxVideoBytes = 500 * 1024 * 1024
    static let videoTooLarge = "That video is too large (500 MB at most)."
    static let videoUnsupported = "Only MP4 or MOV videos."

    /// Image files and image data on a pasteboard (and, with `videos`, movie files). Empty when it holds none (then text
    /// pastes as usual).
    static func read(_ pb: NSPasteboard, videos: Bool = false) -> (urls: [URL], data: [(name: String, data: Data, mime: String)]) {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter { isImage($0) || (videos && isMovie($0)) }
            if !images.isEmpty { return (images, []) }
        }
        // Image data only when there's no text: a rich-text copy carries both, and then it's a text paste.
        guard pb.string(forType: .string) == nil else { return ([], []) }
        if let png = pb.data(forType: .png) { return ([], [(name: "Pasted image.png", data: png, mime: "image/png")]) }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return ([], [(name: "Pasted image.png", data: png, mime: "image/png")])
        }
        return ([], [])
    }

    static func isImage(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Any movie file (one that isn't MP4 or MOV is refused in plain words).
    static func isMovie(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie)
    }

    /// An MP4 or MOV file.
    static func isVideo(_ url: URL) -> Bool {
        url.isFileURL && ["mp4", "mov"].contains(url.pathExtension.lowercased())
    }

    static func videoMime(_ url: URL) -> String {
        url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
    }

    static func mime(_ url: URL) -> String {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "image/jpeg"
    }
}

/// The composer's text area: grows with the text up to `maxLines`, then scrolls. Return sends, Shift-Return (or
/// Option-Return) makes a new line, ⌘Return sends too where the surface allows it, Esc stops a running reply. Pasted or
/// dropped image files and image data go to `onImages`; anything else pastes as text.
struct ChatTextArea: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont
    var textColor: NSColor
    var caretColor: NSColor
    var placeholder: String
    var maxLines = 8
    /// Bumped to put the caret in the field (⌘K, after a suggestion).
    var focusToken = 0
    var commandReturnSends = true
    var onSubmit: () -> Void
    var onEscape: () -> Bool
    var onImages: ((_ urls: [URL], _ data: [(name: String, data: Data, mime: String)]) -> Void)?
    /// Pasted or dropped movie files go to `onImages` too (the chats that take videos).
    var acceptsVideo = false

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextArea
        var lastFocus = 0
        var lastWidth: CGFloat = 0
        var observer: NSObjectProtocol?
        init(_ p: ChatTextArea) { parent = p }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        /// A narrower window wraps more lines: measure again when the width changes.
        func watch(_ tv: NSTextView) {
            tv.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) { [weak self, weak tv] _ in
                guard let self, let tv, abs(tv.frame.width - self.lastWidth) > 0.5 else { return }
                self.lastWidth = tv.frame.width
                self.measure(tv)
            }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? ComposerTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            measure(tv)
        }

        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = lm.defaultLineHeight(for: parent.font)
            let used = max(line, lm.usedRect(for: tc).height)
            let inset = tv.textContainerInset.height * 2
            let h = min(used, line * CGFloat(parent.maxLines)) + inset
            let rounded = (h * 2).rounded() / 2
            if abs(rounded - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = rounded }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none

        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        // Owner bug (build 530): the system's Writing Tools badge sat on the + at the field's leading edge.
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = tv
        context.coordinator.watch(tv)
        apply(tv, context: context)
        tv.string = text
        DispatchQueue.main.async { context.coordinator.measure(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        apply(tv, context: context)
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
            context.coordinator.measure(tv)
        }
        if focusToken != context.coordinator.lastFocus {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    private func apply(_ tv: ComposerTextView, context: Context) {
        if tv.font != font {
            tv.font = font
            tv.typingAttributes[.font] = font
            context.coordinator.measure(tv)
        }
        tv.textColor = textColor
        tv.typingAttributes[.foregroundColor] = textColor
        tv.insertionPointColor = caretColor
        tv.setAccessibilityPlaceholderValue(placeholder)
        tv.setAccessibilityLabel(placeholder)
        tv.commandReturnSends = commandReturnSends
        tv.onSubmit = onSubmit
        tv.onEscape = onEscape
        tv.onImages = onImages
        tv.acceptsVideo = acceptsVideo
    }
}

final class ComposerTextView: NSTextView {
    var commandReturnSends = true
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Bool)?
    var onImages: ((_ urls: [URL], _ data: [(name: String, data: Data, mime: String)]) -> Void)?
    var acceptsVideo = false

    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = e.keyCode == 36 || e.keyCode == 76
        if isReturn, !hasMarkedText() {
            if flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            if flags.contains(.command) && !commandReturnSends {
                super.keyDown(with: e)
                return
            }
            onSubmit?()
            return
        }
        if e.keyCode == 53, !hasMarkedText(), onEscape?() == true { return }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // ⌘Return reaches keyDown only if no menu or button claims it first.
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, (e.keyCode == 36 || e.keyCode == 76), flags == .command, commandReturnSends {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    override func paste(_ sender: Any?) {
        if let onImages {
            let found = ChatImageInput.read(.general, videos: acceptsVideo)
            if !found.urls.isEmpty || !found.data.isEmpty {
                onImages(found.urls, found.data)
                return
            }
        }
        pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onImages != nil, !ChatImageInput.read(sender.draggingPasteboard, videos: acceptsVideo).urls.isEmpty { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onImages {
            let found = ChatImageInput.read(sender.draggingPasteboard, videos: acceptsVideo)
            if !found.urls.isEmpty || !found.data.isEmpty {
                onImages(found.urls, found.data)
                return true
            }
        }
        return super.performDragOperation(sender)
    }
}

/// The composer bar every Claude chat shares: suggestions, the images waiting to go, the growing field with attach, and
/// Send (or Stop while Claude answers); a line under it for the mode or the surface's own note.
/// What the composer's attach buttons add (one-Claude panel).
enum ChatAttachKind: String, CaseIterable, Identifiable {
    case file, image, video, document
    var id: String { rawValue }
    var icon: String { switch self { case .file: "paperclip"; case .image: "image"; case .video: "video-camera"; case .document: "file-text" } }
    var label: String { switch self { case .file: "Attach a file"; case .image: "Attach a photo"; case .video: "Attach a video"; case .document: "Attach a document" } }
}

struct ChatComposerBar: View {
    @Environment(\.theme) private var t
    @Binding var text: String
    var placeholder: String
    var busy: Bool
    /// Why Send is held (no thread yet, images uploading): nil when it can send.
    var held: Bool
    var suggestions: [RecreateClaude.Suggestion] = []
    /// Over the field: the Suite's attachment row (uploads), or nil for the local images row.
    var top: AnyView?
    var localImages: [ChatPendingImage] = []
    var onRemoveLocal: ((UUID) -> Void)?
    var attachNote: String?
    var footer: [String] = []
    var footerHelp: String?
    var commandReturnSends = true
    var onSend: () -> Void
    var onStop: () -> Void
    var onSuggestion: (String) -> Void
    var onAttach: (() -> Void)?
    var onImages: ((_ urls: [URL], _ data: [(name: String, data: Data, mime: String)]) -> Void)?
    /// One-Claude panel: the page's quick-action chips over the field, and four attach buttons under it.
    var chips: [ClaudeChip] = []
    var onPick: ((ChatAttachKind) -> Void)?
    @State private var height: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focus = 0
    @State private var focused = false

    /// Claude's own chat box: Claude never types or sends here through the window (MuseCore UiRefusal "claude.chat").
    var body: some View {
        content.accessibilityElement(children: .contain).accessibilityIdentifier("claude.chat.composer")
    }

    private var content: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = !empty && !held && !busy
        let font = Fonts.nsFont(t.scale.textFamily, t.scale.body.size, .regular) ?? NSFont.systemFont(ofSize: t.scale.body.size)
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        // One row height (owner, build 520: + sat low, send was short): the single-line field's height. + and send are
        // squares of it, so on one line all three share a centre, and as the field grows they stay on its bottom line.
        let lineH = ceil(font.boundingRectForFont.height) + 12
        let rowH = lineH + 2 * Space.s1
        return VStack(alignment: .leading, spacing: Space.s2) {
            if !suggestions.isEmpty {
                FlowLayout(spacing: Space.s1) {
                    ForEach(suggestions) { s in
                        Button { onSuggestion(s.prompt); focus += 1 } label: { Text(s.label).fixedSize() }
                            .buttonStyle(RButtonStyle(kind: .quiet, small: true, off: busy || held))
                            .disabled(busy || held)
                            .help(s.label)
                            .accessibilityLabel("Ask Claude: \(s.label)")
                            .transition(.opacity)
                    }
                }
                // Live chips change with the screen: a short crossfade, none with Reduce Motion.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: suggestions)
            }
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { c in
                            Button { onSuggestion(c.prompt); focus += 1 } label: {
                                HStack(spacing: 4) { Ph(c.icon, 13); Text(c.label).fixedSize() }
                                    .font(t.scale.micro.font).foregroundStyle(t.roles.ink)
                                    .padding(.horizontal, Space.s2).frame(minHeight: 28)
                                    .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy || held)
                            .help(c.prompt)
                            .accessibilityLabel("Ask Claude: \(c.label)")
                            .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chips)
                }
            }
            if let top { top }
            if !localImages.isEmpty { localRow }
            if let attachNote { Text(attachNote).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true) }
            HStack(alignment: .bottom, spacing: Space.s2) {
                if let onAttach, onPick == nil {
                    Button(action: onAttach) { Ph("plus", 16).frame(width: rowH, height: rowH).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .foregroundStyle(t.roles.ink2)
                        .help(takesVideo ? "Attach images or videos (MP4 or MOV). You can also paste or drop them here."
                                         : "Attach images. You can also paste or drop them here.")
                        .accessibilityLabel(takesVideo ? "Attach images or videos" : "Attach images")
                }
                ZStack(alignment: .topLeading) {
                    ChatTextArea(text: $text, height: $height, font: font, textColor: NSColor(t.roles.ink), caretColor: NSColor(t.roles.ink),
                                 placeholder: placeholder, focusToken: focus, commandReturnSends: commandReturnSends,
                                 onSubmit: { if canSend { onSend() } },
                                 onEscape: { if busy { onStop(); return true }; return false },
                                 onImages: onImages, acceptsVideo: takesVideo)
                        .frame(height: max(height, lineH))
                    if text.isEmpty {
                        Text(placeholder).font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                            .lineLimit(1)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1)
                .background(shape.fill(t.roles.field))
                .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: 1))
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "chat field") } }
                if onPick == nil { sendOrStop(canSend: canSend, side: rowH, shape: shape) }
            }
            if let onPick {
                // The panel's attach row (reference, 2026-11-12): file, photo, video, document, then Send on the right.
                HStack(spacing: Space.s1) {
                    ForEach(ChatAttachKind.allCases) { k in
                        Button { onPick(k) } label: { Ph(k.icon, 16).frame(width: 28, height: 28).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(t.roles.ink2)
                            .disabled(held)
                            .help(k.label).accessibilityLabel(k.label)
                    }
                    Spacer(minLength: 0)
                    sendOrStop(canSend: canSend, side: 32, shape: shape)
                }
            }
            if !footer.isEmpty {
                VStack(alignment: .leading, spacing: Space.s1) {
                    ForEach(footer, id: \.self) { line in
                        Text(line).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help(footerHelp ?? "")
                // Lines up with the field's text, not with the + button.
                .padding(.leading, (onAttach != nil && onPick == nil ? rowH + Space.s2 : 0) + Space.s3)
            }
            // ⌘K puts the caret in the field.
            Button("") { focus += 1 }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s3)
        // The bar keeps its height at any window size; the transcript above gives way.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .overlay(alignment: .top) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "chat composer") } }
        .onChange(of: SnapshotRunner.state.chatFocusTick) { _, _ in focus += 1 }
    }

    /// The chats whose own attach takes videos too (the Suite's attachment row, `top`, takes images only).
    private var takesVideo: Bool { top == nil && onAttach != nil }

    /// Send (or Stop while Claude works): a square the height of the single-line field, with the field's corner radius.
    @ViewBuilder private func sendOrStop(canSend: Bool, side: CGFloat, shape: RoundedRectangle) -> some View {
        if busy {
            Button(action: onStop) {
                Ph("stop", 15).frame(width: side, height: side)
                    .background(shape.fill(t.roles.field)).overlay(shape.strokeBorder(t.roles.hairline, lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(.plain).foregroundStyle(t.roles.ink)
            .help("Stop Claude (Esc)")
            .accessibilityLabel("Stop Claude")
            .keyboardShortcut(".", modifiers: .command)
        } else {
            Button(action: onSend) {
                Ph("paper-plane-right", 15).frame(width: side, height: side)
                    .background(shape.fill(canSend ? t.roles.action : t.roles.field))
                    .overlay(shape.strokeBorder(canSend ? Color.clear : t.roles.hairline, lineWidth: 1))
                    .contentShape(shape)
            }
            .buttonStyle(.plain).foregroundStyle(canSend ? t.roles.onAction : t.roles.ink2)
            .disabled(!canSend)
            .help("Send (Return). Shift-Return starts a new line.")
            .accessibilityLabel("Send to Claude")
        }
    }

    private var localRow: some View {
        HStack(spacing: Space.s2) {
            ForEach(localImages) { img in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let v = img.video {
                            videoTile(img, v)
                        } else if let ns = NSImage(data: img.data) {
                            Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(t.roles.field)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: min(t.radii.control, 8), style: .continuous))   // an image, never a pill
                    Button { onRemoveLocal?(img.id) } label: {
                        Ph("x", 10).foregroundStyle(t.roles.ink)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(t.roles.raised))
                            .overlay(Circle().strokeBorder(t.roles.hairline))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Remove \(img.name)")
                    .accessibilityLabel("Remove \(img.name)")
                }
                .help(tileHelp(img))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(tileHelp(img))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.s1)
    }

    /// A video waiting to go: its poster frame (or a film mark) with its length; a spinner while it uploads, a warning
    /// mark when it didn't.
    @ViewBuilder private func videoTile(_ img: ChatPendingImage, _ v: ChatPendingVideo) -> some View {
        ZStack {
            if let ns = NSImage(data: img.data) {
                Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(t.roles.field)
                Ph("film-strip", 16).foregroundStyle(t.roles.ink2)
            }
            if v.uploading {
                Rectangle().fill(Color.black.opacity(0.35))
                ProgressView().controlSize(.small)
            } else if v.error != nil {
                Rectangle().fill(Color.black.opacity(0.45))
                Ph("warning", 14).foregroundStyle(Color.white)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if v.seconds > 0 {
                Text(ClaudeAttachmentPrompt.length(v.seconds))
                    .monospacedDigit()
                    .scaled(t.scale.micro, Color.white)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.black.opacity(0.6)))
                    .padding(2)
            }
        }
    }

    /// What a tile is, in plain words (hover and VoiceOver).
    private func tileHelp(_ img: ChatPendingImage) -> String {
        guard let v = img.video else { return img.name }
        let len = v.seconds > 0 ? ", \(ClaudeAttachmentPrompt.length(v.seconds))" : ""
        if let e = v.error { return "Video \(img.name)\(len). \(e)" }
        if v.uploading { return "Video \(img.name)\(len). Uploading." }
        return "Video \(img.name)\(len)"
    }
}
