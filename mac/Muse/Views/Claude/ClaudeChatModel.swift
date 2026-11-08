import AppKit
import Foundation
import MuseCore
import Observation

/// State of one ClaudeChatView: the thread of a camera, edit, recreate or suite context, its transcript (stored messages +
/// the live turn), the composer, images waiting to go, Stop and Try again. Turns run on this Mac through ClaudeCodeService;
/// the phone's turns show up live as well.
@MainActor
@Observable
final class ClaudeChatModel {
    private(set) var thread: ClaudeThread?
    private(set) var transcript = ClaudeTranscript()
    /// A turn queued or running somewhere else (the phone's, before this Mac picks it up, or the API fallback).
    private(set) var remoteTurn: ClaudeTurn?
    var composer = ""
    private(set) var loading = false
    /// The thread couldn't open, in plain words; `offline` when it was the connection.
    private(set) var loadError: String?
    private(set) var offline = false
    /// Images waiting to go with the next message (Edit, Recreate and Camera: kept on this Mac for Claude Code to read).
    var localImages: [ChatPendingImage] = []
    var attachNote: String?
    /// Images sent from this Mac, by the words they went with, for the thumbnails in that bubble.
    private(set) var sentLocal: [String: [Data]] = [:]

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private weak var service: ClaudeCodeService?
    @ObservationIgnored private var lastContext: (kind: String, id: String, fallback: (kind: String, id: String)?)?
    /// Review mode: the sample thread is on screen (reloads leave it alone).
    @ObservationIgnored private var sampleKey: String?

    /// What each message sent from this Mac carries in front (Recreate: a line naming the reference and the edit session).
    @ObservationIgnored var wrapOutgoing: ((String) -> String)?
    /// How a stored message is shown without what `wrapOutgoing` put in front.
    @ObservationIgnored var unwrapShown: ((String) -> String)?
    /// The Suite: images attached for this message, saved for Claude Code (thread id in, files out). Taken at send.
    @ObservationIgnored var takeFiles: ((String) -> [ClaudeAttachmentFile])?

    static let maxLocalImages = 4

    init() {}

    /// The view went away.
    func detach() {
        feedTask?.cancel()
        reloadTask?.cancel()
        feedTask = nil
        key = nil
    }

    /// Called from the view's `.task(id:)`. A different context (or a restarted service) loads afresh.
    /// `fallback`: a context to use when the server doesn't accept the first one (Recreate asks for its own "recreate"
    /// context and falls back to the edit session's "edit" thread on a server that doesn't have it yet).
    func attach(_ service: ClaudeCodeService, contextKind: String, contextId: String, fallback: (kind: String, id: String)? = nil) async {
        let k = "\(ObjectIdentifier(service))|\(service.baseURL?.absoluteString ?? "demo")|\(contextKind)|\(contextId)|\(fallback?.kind ?? "")|\(fallback?.id ?? "")"
        lastContext = (contextKind, contextId, fallback)
        guard service.configured, k != key || thread == nil else {
            applySample(kind: contextKind)
            return
        }
        key = k
        self.service = service
        feedTask?.cancel()
        let feed = service.feed()
        feedTask = Task { [weak self] in
            for await f in feed {
                guard let self, !Task.isCancelled else { break }
                self.handle(f)
            }
        }
        thread = nil
        transcript = ClaudeTranscript()
        remoteTurn = nil
        loading = true
        defer { loading = false }
        do {
            let d: ClaudeThreadDetail
            do {
                d = try await service.openThread(contextKind: contextKind, contextId: contextId)
            } catch {
                guard let fallback else { throw error }
                d = try await service.openThread(contextKind: fallback.kind, contextId: fallback.id)
            }
            thread = d.thread
            transcript.load(d.messages)
            remoteTurn = d.activeTurn.flatMap { $0.isOpen ? $0 : nil }
            loadError = nil
            offline = false
        } catch {
            let code = (error as? ApiError)?.code ?? ""
            let raw = (error as? ApiError)?.message ?? error.localizedDescription
            offline = code == "offline" || code == "network" || (error as? URLError) != nil
            loadError = offline ? "The chat comes back when the connection does." : ChatLeakFilter.errorWords(raw)
            key = nil
        }
        sampleKey = nil
        applySample(kind: contextKind)
    }

    /// Try again after the thread couldn't open.
    func retryLoad() async {
        guard let service, let c = lastContext else { return }
        key = nil
        await attach(service, contextKind: c.kind, contextId: c.id, fallback: c.fallback)
    }

    func reload() async {
        guard sampleKey == nil, let service, let id = thread?.id, let d = try? await service.threadDetail(id) else { return }
        thread = d.thread
        transcript.load(d.messages)
        remoteTurn = d.activeTurn.flatMap { $0.isOpen ? $0 : nil }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func handle(_ f: ClaudeCodeService.Feed) {
        guard let tid = thread?.id else { return }
        switch f {
        case .local(let t, _, let e) where t == tid:
            transcript.apply(e)
            if case .done = e { scheduleReload() }
        case .live(.message(let t, let m)) where t == tid:
            transcript.upsert(m)
        case .live(.event(let t, let turnId, let e)) where t == tid:
            transcript.apply(e)
            if case .done = e {
                if remoteTurn?.id == turnId || turnId == nil { remoteTurn = nil }
                scheduleReload()
            }
        case .live(.turn(let turn)) where turn.threadId == tid:
            remoteTurn = turn.isOpen ? turn : nil
        case .live(.thread(let th)) where th.id == tid:
            thread = th
        case .live(.connected):
            Task { await reload() }
        default:
            break
        }
    }

    // MARK: Actions

    var runningHere: Bool { thread.map { service?.isRunning(threadId: $0.id) ?? false } ?? false }
    var answeringPhone: Bool { thread.map { service?.isAnsweringPhone(threadId: $0.id) ?? false } ?? false }
    var busy: Bool { runningHere || transcript.streaming || remoteTurn?.isOpen == true }

    /// The last turn's failure in plain words (nil while running or when it went well).
    var turnError: String? {
        guard !busy, let e = transcript.lastError else { return nil }
        return ChatLeakFilter.errorWords(e)
    }

    func send() {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard deliver(text, images: localImages) else { return }
        composer = ""
        localImages = []
        attachNote = nil
    }

    /// Sends `text` (and images kept on this Mac) as a new turn. False when it can't go now.
    @discardableResult
    private func deliver(_ text: String, images: [ChatPendingImage] = []) -> Bool {
        guard !text.isEmpty, !busy, let service, let tid = thread?.id, service.info.ready else { return false }
        transcript.begin(userText: text, source: "mac")
        var files = takeFiles?(tid) ?? []
        if !images.isEmpty {
            files += images.compactMap { save($0, threadId: tid) }
            sentLocal[ChatLeakFilter.userText(text)] = images.map(\.data)
        }
        service.send(threadId: tid, text: wrapOutgoing?(text) ?? text, files: files)
        return true
    }

    /// A suggestion chip: sent as if typed (only when nothing is running). What's in the composer stays there.
    func send(_ text: String) {
        deliver(text)
    }

    /// Try again: the last message, sent again as it was typed.
    func retry() {
        guard !busy else { return }
        for item in transcript.items.reversed() {
            if case .user(_, let text, _) = item {
                deliver(unwrapShown?(text) ?? text)
                return
            }
        }
    }

    func stop() {
        guard let service, let tid = thread?.id else { return }
        service.stop(threadId: tid, remoteTurnId: remoteTurn?.id)
    }

    // MARK: Images on this Mac

    func addImages(urls: [URL], data: [(name: String, data: Data, mime: String)]) {
        var list = data
        for u in urls where ChatImageInput.isImage(u) {
            if let d = try? Data(contentsOf: u) { list.append((u.lastPathComponent, d, ChatImageInput.mime(u))) }
        }
        let skipped = urls.count - urls.filter(ChatImageInput.isImage).count
        let room = max(0, Self.maxLocalImages - localImages.count)
        for f in list.prefix(room) where NSImage(data: f.data) != nil {
            localImages.append(ChatPendingImage(name: f.name, data: f.data, mime: f.mime))
        }
        if list.count > room {
            attachNote = "Up to \(Self.maxLocalImages) images go with one message."
        } else if skipped > 0 {
            attachNote = "Only images can go with a message: JPEG, PNG, HEIC, WebP, GIF or TIFF."
        } else {
            attachNote = nil
        }
    }

    func removeImage(_ id: UUID) {
        localImages.removeAll { $0.id == id }
        attachNote = nil
    }

    func pickImages() {
        // Review mode never opens a modal panel (it would stop the run): a stand-in image is attached instead.
        if SnapshotRunner.probing {
            addImages(urls: [], data: [(name: "Reference.png", data: Self.swatch(0.85, 0.62, 0.42), mime: "image/png")])
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ChatImageInput.types
        panel.message = "Choose up to \(Self.maxLocalImages) images for Claude to look at."
        guard panel.runModal() == .OK else { return }
        addImages(urls: panel.urls, data: [])
    }

    private func save(_ img: ChatPendingImage, threadId: String) -> ClaudeAttachmentFile? {
        let ext = ClaudeAttachmentCache.ext(mime: img.mime, url: nil)
        let a = ClaudeAttachment(id: "local-\(img.id.uuidString.prefix(8).lowercased())", uploadId: "", mimeType: img.mime)
        guard var f = ClaudeAttachmentCache.save(img.data, attachment: a, threadId: threadId) else { return nil }
        if !f.path.hasSuffix(".\(ext)") { f.path += ".\(ext)" }
        f.uploadId = ""
        return f
    }

    // MARK: Review mode

    /// Review screenshots: the sample thread (every kind of row, with plumbing that must not show), optionally mid-reply,
    /// with the composer text and images the shot asks for. Nothing here runs in a normal launch.
    private func applySample(kind: String) {
        let s = SnapshotRunner.state
        guard SnapshotRunner.probing, s.chatSample else { return }
        let k = "\(kind)|\(s.chatStreaming)|\(s.chatComposerText ?? "")|\(s.chatAttach)"
        guard k != sampleKey else { return }
        sampleKey = k
        var tr = ClaudeTranscript()
        tr.load(ClaudeChatSample.messages(threadId: thread?.id ?? "sample", kind: kind))
        if s.chatStreaming { for e in ClaudeChatSample.liveEvents { tr.apply(e) } }
        transcript = tr
        loadError = nil
        composer = s.chatComposerText ?? ""
        localImages = s.chatAttach ? [ChatPendingImage(name: "Reference 1.png", data: Self.swatch(0.85, 0.62, 0.42), mime: "image/png"),
                                      ChatPendingImage(name: "Reference 2.png", data: Self.swatch(0.35, 0.45, 0.62), mime: "image/png")] : []
    }

    /// A plain colour swatch (review mode's stand-in image).
    static func swatch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: r, green: g, blue: b, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
