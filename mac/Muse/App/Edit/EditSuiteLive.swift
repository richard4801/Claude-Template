import AVFoundation
import AppKit
import MuseCore

// Claude in the Edit suite (workstream 3, plans/claude-editing.md A): for the studio owner, the editor shares its edit live
// with Claude through the take's edit session (MuseCore EditSessionSync). Local changes are pushed (debounced 0.5 s), remote
// ones (Claude's, the phone's) are shown at once with a "Claude edited this" toast, presence is announced every 30 s, and
// Claude's requests are answered here: exact frames rendered with the same engine as the preview, Save to Gallery, the export
// sheet with Claude's preset (the disclosure switches stay the owner's), and paid helpers wait for the owner's yes.
// Members never get here: their editor stays local.
extension EditSuiteSession {
    static let presenceEvery: UInt64 = 30_000_000_000
    static let pushAfter: UInt64 = 500_000_000

    /// "Studio MacBook Pro": how this Mac shows in the session's online list.
    static let hostLabel: String = Host.current().localizedName ?? "Mac"

    // MARK: Open / close

    /// Opens (or creates) the take's session and starts listening. Failing leaves the editor local (it says so once).
    func startLive() async {
        guard isOwner, live == nil else { return }
        do {
            let sync: EditSessionSync
            if let id = attachSessionId {
                sync = try await EditSessionSync.attach(api: api, sessionId: id, device: device, paletteIds: EditV2LookLibrary.shared.paletteIds)
            } else {
                sync = try await EditSessionSync.open(api: api, takeId: sourceTakeId, project: project, device: device,
                                                      paletteIds: EditV2LookLibrary.shared.paletteIds)
            }
            live = sync
            liveConnected = true
            // The session is the live copy: when it already holds other changes (Claude's, the phone's), they show here.
            if sync.synced != project { showRemote(sync.synced) }
            // Edits this Mac made but never got to the server (closed, offline): ask before anything replaces them.
            // A blank project is new every time: no kept drafts (they are per take).
            let saved = project.isBlank ? nil : drafts.load(takeId: sourceTakeId)
            if let d = saved, sync.conflicts(with: d) { draftAsk = d } else { drafts.remove(takeId: sourceTakeId) }
            mirrorLive()
            if let p = sync.waiting.first { askPending = p }
            listen(sync)
        } catch {
            liveConnected = false
            notice = "Editing on this Mac only · couldn't share the edit with Claude"
        }
    }

    func stopLive() {
        liveTasks.forEach { $0.cancel() }
        liveTasks = []
        flushTask?.cancel()
        flushTask = nil
        ClaudeEditNotice.shared.clear(if: self)
        guard let sync = live else { return }
        live = nil
        liveConnected = false
        // The last change still goes out, then this Mac leaves the online list.
        let drafts = self.drafts, takeId = sourceTakeId, asking = draftAsk != nil || project.isBlank
        Task { @MainActor in
            _ = try? await sync.flush()
            // Whatever still couldn't be sent stays on this Mac for next time.
            if !asking { drafts.save(sync.draft, takeId: takeId) }
            await sync.leave()
        }
    }

    private func listen(_ sync: EditSessionSync) {
        let stream = api.events()
        let events = Task { @MainActor [weak self] in
            for await e in stream {
                guard let self, !Task.isCancelled else { return }
                if e.type == ApiEvent.connected {
                    // The stream (re)connected: whatever was missed is fetched.
                    if let u = try? await sync.refresh() { await self.handleLive(u) }
                    continue
                }
                guard let x = e.edit else { continue }
                if let u = await sync.handle(x) { await self.handleLive(u) }
            }
        }
        let presence = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await sync.announce(label: Self.hostLabel, platform: "mac", canRender: true, preview: self.state.preview)
                try? await Task.sleep(nanoseconds: Self.presenceEvery)
            }
        }
        liveTasks = [events, presence]
    }

    func mirrorLive() {
        liveHistory = live?.history ?? []
        if let a = askPending, live?.waiting.contains(where: { $0.id == a.id }) != true { askPending = nil }
    }

    // MARK: Changes

    /// Called on every local change: queued for the session and pushed after a short pause.
    func liveLocalChange() {
        guard let sync = live else { return }
        let label = nextChangeLabel
        nextChangeLabel = nil
        sync.localChanged(project, label: label)
        saveDraft()
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pushAfter)
            guard let self, !Task.isCancelled else { return }
            await self.pushLive()
        }
    }

    func pushLive() async {
        guard let sync = live else { return }
        do {
            if let u = try await sync.flush() { await handleLive(u) }
        } catch {
            lastError = (error as? ApiError)?.message ?? "Couldn't share that change with Claude"
        }
        saveDraft()
        mirrorLive()
    }

    /// Keeps the unsent change on this Mac (removed once it reached the server).
    func saveDraft() {
        guard let sync = live, draftAsk == nil, !project.isBlank else { return }
        drafts.save(sync.draft, takeId: sourceTakeId)
    }

    /// The owner's answer to "Keep this device's changes / Use the latest".
    func resolveDraft(keep: Bool) {
        guard let d = draftAsk else { return }
        draftAsk = nil
        guard keep, let sync = live else { drafts.remove(takeId: sourceTakeId); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let u = try await sync.keep(d)
                await self.handleLive(u)
                self.notice = "Kept this Mac's changes on top of the latest edit"
            } catch {
                self.lastError = (error as? ApiError)?.message ?? "Couldn't send this Mac's changes"
            }
            self.saveDraft()
            self.mirrorLive()
        }
    }

    /// Undoes one change of the session's history (Claude's or any app's) on the server.
    func undoLive(_ entry: EditHistoryEntry) async {
        guard let sync = live else { return }
        await pushLive()
        do {
            if let u = try await sync.undo(entryId: entry.id) { await handleLive(u) }
            notice = "Undid “\(entry.label)”"
        } catch {
            lastError = (error as? ApiError)?.message ?? "Couldn't undo that"
        }
        mirrorLive()
    }

    // MARK: Events

    func handleLive(_ u: EditSessionSync.Update) async {
        switch u {
        case .project(let p, let entry):
            showRemote(p)
            if let e = entry, e.byClaude {
                claudeToast = e.notice.map { "Claude · \($0)" } ?? e.claudeToast
                if e.notice != nil { ClaudeEditNotice.shared.post(e, from: self) }
            }
        case .history:
            break
        case .pending(let p):
            if p.isWaiting { askPending = p } else if askPending?.id == p.id { askPending = nil }
        case .frameRequest(let rid, let t, let width):
            await answerFrame(requestId: rid, t: t, width: width)
        case .appRequest(let r):
            runAppRequest(r)
        case .closed:
            liveTasks.forEach { $0.cancel() }
            liveTasks = []
            live = nil
            liveConnected = false
            notice = "Claude's edit session ended · editing on this Mac"
        }
        mirrorLive()
    }

    // MARK: Paid helpers

    /// The owner's answer on the confirmation sheet ("Claude wants to run … · about $X").
    func answerPending(_ p: EditPending, approve: Bool) async {
        askPending = nil
        guard let sync = live else { return }
        do {
            _ = try await sync.answer(pendingId: p.id, approve: approve)
            notice = approve ? "\(p.label) started · Claude's change lands when it's done" : "Told Claude not now"
        } catch {
            lastError = (error as? ApiError)?.message ?? "Couldn't answer Claude"
        }
        mirrorLive()
    }

    // MARK: Frames

    /// Renders the exact frame at `t` (timeline seconds) with the preview's engine (composition + video composition, so looks,
    /// text, captions and overlays are all there), uploads it as a PNG and hands it to Claude.
    func answerFrame(requestId: String, t: Double, width: Int) async {
        guard let sync = live else { return }
        do {
            let png = try await renderFramePNG(at: t, width: width)
            let up = try await api.uploadEditFrame(png: png)
            try await api.answerEditFrame(sessionId: sync.sessionId, requestId: requestId, uploadId: up)
        } catch {
            // Claude falls back to the server's approximate frame after its wait.
        }
    }

    func renderFramePNG(at t: Double, width: Int) async throws -> Data {
        let p = project
        let missing = files.filter { id, _ in sources.media[id] == nil && sources.images[id] == nil && sources.luts[id] == nil }
        if !missing.isEmpty {
            let more = try await EditV2Engine.load(p, files: missing)
            sources.media.merge(more.media) { a, _ in a }
            sources.images.merge(more.images) { a, _ in a }
            sources.luts.merge(more.luts) { a, _ in a }
        }
        let built = try EditV2Engine.build(p, sources: sources)
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let size = editFrameSize(canvas: p.canvas, width: width)
        gen.maximumSize = CGSize(width: size.width, height: size.height)
        let end = max(0, built.plan.durationSec - 1 / max(1, p.canvas.fps))
        let at = CMTime(seconds: min(max(0, t), end), preferredTimescale: EditV2Engine.timescale)
        let image = try await gen.image(at: at).image
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ApiError("frame_failed", "Couldn't make the frame") }
        return png
    }

    // MARK: Save / export

    /// Claude's save (Save to Gallery as today) or export (the export sheet with Claude's preset; the owner confirms).
    func runAppRequest(_ r: EditAppRequest) {
        switch r.kind {
        case "save":
            guard !busy else { answerRequest(r, .failed("The Mac is busy exporting · try again in a moment")); return }
            var settings = state.export
            // Disclosure is chosen per export and starts off every time (owner rule); never Claude's.
            settings.labelAI = false
            settings.c2pa = false
            if project.captionTrack == nil { settings.captions = .burnIn }
            notice = "Claude asked to save · making the video on this Mac"
            export(settings, saveFileTo: nil, request: r) { [weak self] t in self?.onVersionSaved?(t) }
        case "export":
            var base = state.export
            base.labelAI = false
            base.c2pa = false
            exportAskRequest = r
            exportAsk = base.applying(preset: r.preset)
        default:
            answerRequest(r, .failed("This Mac can't do that"))
        }
    }

    /// The export sheet Claude opened was closed without exporting.
    func exportAskClosed(started: Bool) {
        if !started, let r = exportAskRequest { answerRequest(r, .failed("The owner closed the export")) }
        exportAskRequest = nil
        exportAsk = nil
    }

    func answerRequest(_ r: EditAppRequest, _ a: EditAppRequestAnswer) {
        guard let sessionId = live?.sessionId else { return }
        let api = self.api
        Task { try? await api.answerEditAppRequest(sessionId: sessionId, requestId: r.id, a) }
    }
}
