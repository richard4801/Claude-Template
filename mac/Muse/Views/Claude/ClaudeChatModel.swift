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
    /// Images waiting to go with the next message (Edit, Recreate and Camera: kept on this Mac for Claude Code to read),
    /// and videos (uploaded to the server as soon as they are picked: Claude watches them there).
    var localImages: [ChatPendingImage] = []
    var attachNote: String?
    /// Images sent from this Mac, by the words they went with, for the thumbnails in that bubble.
    private(set) var sentLocal: [String: [Data]] = [:]
    /// WS18: this place's chats (newest first), when the server keeps lists.
    private(set) var threads: [ClaudeThread] = []
    private(set) var sessionsAvailable = false

    /// The Suite's own sessions: a new chat is a new shared draft, and opening or deleting one binds its draft to the
    /// composer. nil: Recreate, Edit and Camera, where the chats are about the same context.
    struct SessionHooks {
        var newChat: () async -> Void
        var open: (ClaudeThread) async -> Void
        /// The open chat was deleted; `next` is the newest one left.
        var deleted: (_ next: ClaudeThread?) async -> Void
    }
    @ObservationIgnored var sessionHooks: SessionHooks?
    /// A tool step finished (its name, e.g. `mcp__muse__suite_set_draft`): the Suite reads its draft again.
    @ObservationIgnored var onToolDone: ((String) -> Void)?
    @ObservationIgnored private var removing: Set<String> = []
    /// Videos uploading, by their pending row.
    @ObservationIgnored private var videoUploads: [UUID: Task<Void, Never>] = [:]

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
            var d: ClaudeThreadDetail?
            // WS18: Recreate, Edit and Camera come back to the chat open last time on this Mac (else the newest).
            if contextKind != "suite", let id = Self.remembered(ClaudeSessions.contextKey(kind: contextKind, id: contextId)) {
                d = try? await service.loadThread(id)
                if let t = d?.thread, t.contextKind != contextKind || t.contextId != contextId { d = nil }
            }
            if d == nil {
                do {
                    d = try await service.openThread(contextKind: contextKind, contextId: contextId)
                } catch {
                    guard let fallback else { throw error }
                    d = try await service.openThread(contextKind: fallback.kind, contextId: fallback.id)
                }
            }
            guard let d else { throw ApiError("not_found", "Chat not found") }
            show(d)
            loadError = nil
            offline = false
            await refreshThreads()
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
        guard thread?.id == d.thread.id else { return }
        thread = d.thread
        transcript.load(d.messages)
        remoteTurn = d.activeTurn.flatMap { $0.isOpen ? $0 : nil }
    }

    /// A chat on screen: its messages, its turn still running, and remembered as this place's open chat.
    private func show(_ d: ClaudeThreadDetail) {
        thread = d.thread
        transcript = ClaudeTranscript()
        transcript.load(d.messages)
        remoteTurn = d.activeTurn.flatMap { $0.isOpen ? $0 : nil }
        composer = ""
        dropVideoUploads()
        localImages = []
        attachNote = nil
        if let key = d.thread.contextKey ?? listKey(d.thread) { Self.remember(key, threadId: d.thread.id) }
    }

    // MARK: Sessions (WS18)

    private func listKey(_ t: ClaudeThread) -> String? {
        t.contextKind == "suite" ? nil : ClaudeSessions.contextKey(kind: t.contextKind, id: t.contextId)
    }
    private var key_: String? { thread.flatMap { $0.contextKey ?? listKey($0) } }

    /// The chat open last in each place, on this Mac.
    static func remembered(_ key: String) -> String? { UserDefaults.standard.string(forKey: "claude.chat.\(key)") }
    static func remember(_ key: String, threadId: String) { UserDefaults.standard.set(threadId, forKey: "claude.chat.\(key)") }

    /// The place's list from the server (an older server has none: one chat per place, no switcher).
    func refreshThreads() async {
        guard let service, let key = key_ else { return }
        do {
            var list = try await service.threads(key: key)
            if let t = thread, !list.contains(where: { $0.id == t.id }) { ClaudeSessions.upsert(t, into: &list) }
            threads = list
            sessionsAvailable = true
        } catch {
            if (error as? ApiError)?.code == "not_found" { sessionsAvailable = false }
        }
    }

    /// The open chat has nothing in it yet (New chat on it again does nothing).
    var isEmptyChat: Bool { transcript.items.isEmpty && !busy }

    /// New chat: a fresh conversation in this place. The Suite starts a new shared draft for it.
    func newChat() async {
        guard !busy, !isEmptyChat, let service, let t = thread else { return }
        if let hooks = sessionHooks { await hooks.newChat(); return }
        do {
            let d = try await service.newThread(contextKind: t.contextKind, contextId: t.contextId)
            show(d)
            ClaudeSessions.upsert(d.thread, into: &threads)
        } catch {
            attachNote = "Couldn't start a new chat. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)"
        }
    }

    /// Switch to another chat in the list.
    func open(_ t: ClaudeThread) async {
        guard t.id != thread?.id, let service else { return }
        if let hooks = sessionHooks { await hooks.open(t); return }
        do {
            show(try await service.loadThread(t.id))
        } catch {
            attachNote = "Couldn't open that chat. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)"
            await refreshThreads()
        }
    }

    func rename(_ t: ClaudeThread, to title: String) async {
        guard let service else { return }
        do {
            let n = try await service.renameThread(t.id, title: title)
            ClaudeSessions.upsert(n, into: &threads)
            if thread?.id == n.id { thread = n }
        } catch {
            attachNote = "Couldn't rename the chat. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)"
        }
    }

    func delete(_ t: ClaudeThread) async {
        guard let service else { return }
        do {
            try await service.deleteThread(t.id)
        } catch where (error as? ApiError)?.code != "not_found" {
            attachNote = "Couldn't delete the chat. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)"
            return
        } catch {}
        await removed(t.id)
    }

    /// A chat gone (here or on another device): out of the list; the open one is followed by the newest left.
    private func removed(_ id: String) async {
        // The delete here and its live echo can both arrive: follow it once.
        guard !removing.contains(id) else { return }
        removing.insert(id)
        defer { removing.remove(id) }
        let next = ClaudeSessions.after(deleting: id, in: threads)
        threads.removeAll { $0.id == id }
        guard thread?.id == id, let service, let gone = thread else { return }
        if let hooks = sessionHooks { await hooks.deleted(next); return }
        if let next, let d = try? await service.loadThread(next.id) {
            show(d)
        } else if let d = try? await service.openThread(contextKind: gone.contextKind, contextId: gone.contextId) {
            show(d)
            ClaudeSessions.upsert(d.thread, into: &threads)
        }
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
            toolDone(e)
            if case .done = e { scheduleReload(); Task { await refreshThreads() } }
        case .live(.message(let t, let m)) where t == tid:
            transcript.upsert(m)
        case .live(.event(let t, let turnId, let e)) where t == tid:
            transcript.apply(e)
            toolDone(e)
            if case .done = e {
                if remoteTurn?.id == turnId || turnId == nil { remoteTurn = nil }
                scheduleReload()
            }
        case .live(.turn(let turn)) where turn.threadId == tid:
            remoteTurn = turn.isOpen ? turn : nil
        case .live(.thread(let th)) where th.id == tid:
            thread = th
            ClaudeSessions.upsert(th, into: &threads)
        case .live(.thread(let th)) where th.contextKey != nil && th.contextKey == key_:
            ClaudeSessions.upsert(th, into: &threads)
        case .live(.threadDeleted(let id)):
            Task { await removed(id) }
        case .live(.connected):
            Task { await reload() }
        default:
            break
        }
    }

    private func toolDone(_ e: ClaudeEvent) {
        if case .tool(_, let name, .done, _, _) = e { onToolDone?(name) }
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
        // A video goes by its upload id: it must be on the server first.
        if localImages.contains(where: { $0.video?.uploading == true }) {
            attachNote = "The video is still uploading. Send when it is ready."
            return
        }
        if localImages.contains(where: { $0.video?.error != nil }) {
            attachNote = "A video didn't upload. Remove it, then send."
            return
        }
        guard deliver(text, images: localImages) else { return }
        composer = ""
        localImages = []
        attachNote = nil
    }

    /// Sends `text` (and images kept on this Mac) as a new turn. False when it can't go now.
    @discardableResult
    private func deliver(_ text: String, images: [ChatPendingImage] = []) -> Bool {
        guard !text.isEmpty, !busy, let service, let tid = thread?.id, service.info.ready else { return false }
        // The owner's report (WS18): every message showed twice. The bubble began with the bare words while the runner's
        // echo and the stored copy carry the context line in front, so they never matched. The bubble now begins with the
        // message exactly as it is sent and stored (the files are taken first: the Suite's line names them).
        var files = takeFiles?(tid) ?? []
        let outgoing = wrapOutgoing?(text) ?? text
        transcript.begin(userText: outgoing, source: "mac")
        if !images.isEmpty {
            files += images.filter { $0.video == nil }.compactMap { save($0, threadId: tid) }
            // Videos go by their upload id (Claude calls watch); the server keeps them with the message.
            files += images.compactMap { img -> ClaudeAttachmentFile? in
                guard let v = img.video, let id = v.uploadId else { return nil }
                return ClaudeAttachmentFile.video(uploadId: id, name: img.name, seconds: v.seconds > 0 ? v.seconds : nil)
            }
            sentLocal[ChatLeakFilter.userText(text)] = images.map { img in
                img.video.map { ChatVideoProbe.chip(poster: img.data, seconds: $0.seconds) } ?? img.data
            }
        }
        service.send(threadId: tid, text: outgoing, files: files)
        return true
    }

    /// A suggestion chip: sent as if typed (only when nothing is running). What's in the composer stays there.
    func send(_ text: String) {
        deliver(text)
    }

    /// The last turn ran without Blender's tools: Claude Code reported Blender's server as failed.
    var blenderFailed: Bool {
        guard !busy else { return false }
        for item in transcript.items.reversed() {
            if case .user = item { return false }
            if case .tool(ClaudeCommand.Blender.failedChipId, _, _, .error) = item { return true }
        }
        return false
    }

    /// Retry Blender: fetch Blender's tools again, then send the last message again.
    func retryBlender() {
        guard !busy else { return }
        let warm = BlenderRelayService.shared.warmTools(force: true)
        Task { @MainActor in
            await warm?.value
            retry()
        }
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

    // MARK: Images (and videos) on this Mac

    func addImages(urls: [URL], data: [(name: String, data: Data, mime: String)]) {
        var list = data
        var videos: [URL] = []
        var refusal: String?
        var skipped = 0
        for u in urls {
            if ChatImageInput.isImage(u) {
                if let d = try? Data(contentsOf: u) { list.append((u.lastPathComponent, d, ChatImageInput.mime(u))) }
            } else if ChatImageInput.isVideo(u) {
                let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                if let size, size > ChatImageInput.maxVideoBytes { refusal = ChatImageInput.videoTooLarge } else { videos.append(u) }
            } else if ChatImageInput.isMovie(u) {
                refusal = ChatImageInput.videoUnsupported
            } else {
                skipped += 1
            }
        }
        // Images and videos share the limit.
        var room = max(0, Self.maxLocalImages - localImages.count)
        var full = false
        for f in list where NSImage(data: f.data) != nil {
            guard room > 0 else { full = true; break }
            localImages.append(ChatPendingImage(name: f.name, data: f.data, mime: f.mime))
            room -= 1
        }
        for v in videos {
            guard room > 0 else { full = true; break }
            addVideo(v)
            room -= 1
        }
        if full {
            attachNote = "Up to \(Self.maxLocalImages) images or videos go with one message."
        } else if let refusal {
            attachNote = refusal
        } else if skipped > 0 {
            attachNote = "Only images and videos can go with a message: JPEG, PNG, HEIC, WebP, GIF, TIFF, MP4 or MOV."
        } else {
            attachNote = nil
        }
    }

    /// A video: its poster and length read here, then uploaded to the server (an upload of kind "clip"), so Claude can
    /// watch it by its upload id.
    private func addVideo(_ url: URL) {
        let mime = ChatImageInput.videoMime(url)
        let item = ChatPendingImage(name: url.lastPathComponent, data: Data(), mime: mime, video: ChatPendingVideo(file: url))
        localImages.append(item)
        let id = item.id
        videoUploads[id] = Task { [weak self] in
            guard let info = await ChatVideoProbe.read(url) else {
                self?.setVideo(id) { $0.video?.state = .failed("This video can't be read. \(ChatImageInput.videoUnsupported)") }
                return
            }
            self?.setVideo(id) {
                $0.data = info.poster
                $0.video?.seconds = info.seconds
            }
            guard !Task.isCancelled else { return }
            guard let uploader = self?.service?.api as? any ClaudeVideoUploading else {
                self?.setVideo(id) { $0.video?.state = .failed("Sign in to your MUSE server to send videos.") }
                return
            }
            do {
                let a = try await uploader.uploadClaudeVideo(url, meta: info.meta(name: url.lastPathComponent), contentType: mime, progress: nil)
                self?.setVideo(id) { $0.video?.state = .ready(uploadId: a.uploadId) }
            } catch {
                guard !Task.isCancelled else { return }
                let why = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
                self?.setVideo(id) { $0.video?.state = .failed("Couldn't upload the video. \(why)") }
            }
            self?.videoUploads[id] = nil
        }
    }

    /// Changes a pending row, if it is still there.
    private func setVideo(_ id: UUID, _ change: (inout ChatPendingImage) -> Void) {
        guard let i = localImages.firstIndex(where: { $0.id == id }) else { return }
        change(&localImages[i])
    }

    private func dropVideoUploads() {
        videoUploads.values.forEach { $0.cancel() }
        videoUploads = [:]
    }

    func removeImage(_ id: UUID) {
        videoUploads[id]?.cancel()
        videoUploads[id] = nil
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
        panel.allowedContentTypes = ChatImageInput.types + ChatImageInput.videoTypes
        panel.message = "Choose up to \(Self.maxLocalImages) images or videos for Claude to look at. Videos: MP4 or MOV, 500 MB at most."
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
