import AppKit
import Foundation
import MuseCore
import Observation

// Claude in the AI Suite (owner only). One draft is shared by Claude and the composer (POST /v1/suite/assist): Claude edits it
// on the server with its suite tools; every change comes back as a `suiteAssist` live event (or a GET) and the bridge lays
// `assist.draft` over the composer the way Reuse settings does, after checking each value against the composer's own options
// (MuseCore SuiteAssistDraft). "Claude set Camera, Light…" with Undo follows. The owner's own edits go back with PATCH so
// Claude sees them on its next turn, and each chat message also carries the composer as it is now.
//
// Money: Claude never generates. Its `suite_request_shot` is a pending ask; the bridge shows it as the composer's Generate · $x
// confirmation, and only the owner's press there approves it (the server runs it at the approved price).

/// The bridge's state, kept on SuiteState.
@MainActor
@Observable
final class SuiteClaudeBridge {
    /// The panel beside the rail (in the picture's place).
    var open = false
    var assist: SuiteAssist?
    /// WS18: the mode's chat list the shared draft belongs to (`suite:photo`…). Each mode returns to its own latest chat.
    var key: String?
    var creating = false
    /// Why there is no shared draft (an older server, a member).
    var error: String?
    /// The newest revision applied here or sent from here; older ones and our own echoes are ignored.
    var revision = 0
    /// The composer as the shared draft last had it (nil: not synced yet). The owner's edits are what differs from it.
    var synced: ComposerDraft?
    /// What the composer couldn't take from Claude's last draft, with the reasons.
    var rejected: [SuiteDraftRejection] = []
    /// Claude's paid ask, shown as the Generate confirmation. Nothing runs without the owner's press.
    var ask: SuitePending?
    /// The Generate confirmation is up (it opens by itself for a new ask, except in review mode, where nothing may spend).
    var confirmOpen = false
    var answering = false
    /// "The price changed to $x": shown in the confirmation after a `409 price_changed`.
    var priceNote: String?
    /// Demo mode's chat (no Claude Code there): the lines and whether a stand-in reply is on its way.
    var demoLines: [DemoLine] = []
    var demoBusy = false
    @ObservationIgnored var pushTask: Task<Void, Never>?
    /// Reference images waiting to go with the next message (up to 4), each uploaded as soon as it is attached.
    var attachments: [Attachment] = []
    /// "Up to 4 images (JPEG, PNG, WebP or HEIC), 10 MB each" after something was left out.
    var attachNote: String?
    /// Links of the images that went with the message being sent (for its context line).
    @ObservationIgnored var sentImages: [(uploadId: String?, url: String)] = []
    /// The draft's reference images (pose, style, location, outfit): chips in the composer, each removable.
    var references: [SuiteDraftReference] = []
    /// A reference was removed (or put back) here: the next PATCH carries the list even when the composer is unchanged.
    var refsDirty = false

    struct DemoLine: Identifiable, Equatable {
        let id = UUID()
        var fromClaude: Bool
        var text: String
        var images: [ImageRef] = []
    }

    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var data: Data
        var mime: String
        /// Once uploaded: its upload id and address.
        var uploaded: ClaudeAttachment?
        var error: String?
        /// The server couldn't read it (`415 unsupported_image`): offered again as JPEG.
        var unsupported = false
        var uploading: Bool { uploaded == nil && error == nil }
        var ref: ImageRef? { uploaded?.url.map { ImageRef(url: $0) } }
    }

    var uploading: Bool { attachments.contains(where: \.uploading) }

    /// A new draft (another tool, signed out): the chat starts again with it.
    func reset(keepOpen: Bool = false) {
        pushTask?.cancel()
        pushTask = nil
        if !keepOpen { open = false }
        assist = nil
        key = nil
        error = nil
        revision = 0
        synced = nil
        rejected = []
        ask = nil
        confirmOpen = false
        answering = false
        priceNote = nil
        demoLines = []
        demoBusy = false
        attachments = []
        attachNote = nil
        sentImages = []
        references = []
        refsDirty = false
    }
}

extension AppStore {
    var suiteAssistAPI: (any SuiteAssistAPI)? { api as? any SuiteAssistAPI }

    /// What the composer offers, for checking Claude's draft.
    var suiteDraftOptions: SuiteDraftOptions {
        SuiteDraftOptions(catalog: suite.catalog,
                          characters: Dictionary(models.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a }),
                          outfits: Dictionary(outfits.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                          locations: Dictionary(suite.locations.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: Open and close

    func toggleSuiteClaude() {
        let c = suite.claude
        if c.open { c.open = false; return }
        guard isOwner else { return }
        c.open = true
        suite.feedOpen = false
        Task {
            await ensureSuiteAssist()
            // Edits made while the panel was closed go to the same draft now, so Claude sees the composer as it is.
            suiteComposerChanged(now: true)
        }
    }

    /// The composer switched tools: a new shared draft for the new tool.
    func suiteClaudeToolChanged() {
        let c = suite.claude
        guard c.assist != nil || c.error != nil else { return }
        let lines = c.demoLines
        c.reset(keepOpen: true)
        c.demoLines = lines
        if c.open { Task { await ensureSuiteAssist() } }
    }

    /// The mode's list of chats (the composer's tool).
    var suiteClaudeKey: String { ClaudeSessions.suiteKey(suite.composer.tool.rawValue) }

    /// Opens Claude for the composer's mode (WS18): its latest chat (the one open last on this Mac, else the newest on the
    /// server) with that chat's shared draft laid over the composer, so the chat, its context line and the composer are one
    /// draft. A mode with no chat yet shares the composer as it is (POST /v1/suite/assist) and starts one.
    func ensureSuiteAssist() async {
        let c = suite.claude
        let key = suiteClaudeKey
        guard c.assist == nil || c.key != key, !c.creating else { return }
        guard let api = suiteAssistAPI else {
            c.error = "This server doesn't have Claude in the Suite yet. Update the server, then open this panel again."
            return
        }
        c.creating = true
        defer { c.creating = false }
        let chats = ClaudeCodeService.shared
        if chats.configured, let list = try? await chats.threads(key: key),
           let latest = ClaudeSessions.pick(list, preferred: ClaudeChatModel.remembered(key)),
           await bindSuiteChat(latest, api: api, key: key) {
            return
        }
        await newSuiteAssist(api: api, key: key)
    }

    /// A chat picked from the mode's list: its shared draft becomes the composer's (with Undo). False when the draft is gone.
    @discardableResult
    func bindSuiteChat(_ t: ClaudeThread, api: any SuiteAssistAPI, key: String) async -> Bool {
        guard t.contextKind == "suite", let a = try? await api.suiteAssist(id: t.contextId) else { return false }
        let c = suite.claude
        let lines = c.demoLines
        c.reset(keepOpen: true)
        c.demoLines = lines
        c.key = key
        c.assist = a
        c.revision = 0
        c.synced = nil
        takeSuiteAssist(a, force: true)
        ClaudeChatModel.remember(key, threadId: t.id)
        return true
    }

    /// A new chat in this mode: a new shared draft from the composer as it is now (the composer stays).
    func newSuiteAssist(api: any SuiteAssistAPI, key: String) async {
        let c = suite.claude
        if c.assist != nil {
            let lines = c.demoLines
            c.reset(keepOpen: true)
            c.demoLines = lines
        }
        let mine = suite.composer
        do {
            let a = try await api.createSuiteAssist(SuiteAssistCreate(draft: ComposerDrafts.draft(mine)))
            c.error = nil
            c.key = key
            c.assist = a
            c.revision = a.revision
            c.synced = mine
            updateSuiteAsk(a)
            // Edits made while it was being created go up now.
            if suite.composer != mine { suiteComposerChanged() }
        } catch let e as ApiError {
            switch e.code {
            case "not_found": c.error = "This server doesn't have Claude in the Suite yet. Update the server, then open this panel again."
            case "owner_only": c.error = "Claude in the Suite is for the studio owner."
            default: c.error = "Couldn't share the composer with Claude. \(e.friendlyMessage)"
            }
        } catch {
            c.error = "Couldn't share the composer with Claude. \(error.localizedDescription)"
        }
    }

    /// The chat's sessions in the Suite (WS18): New chat is a new shared draft; switching or deleting binds another chat's.
    var suiteChatHooks: ClaudeChatModel.SessionHooks {
        ClaudeChatModel.SessionHooks(
            newChat: { [weak self] in
                guard let self, let api = self.suiteAssistAPI else { return }
                await self.newSuiteAssist(api: api, key: self.suiteClaudeKey)
            },
            open: { [weak self] t in
                guard let self, let api = self.suiteAssistAPI else { return }
                if !(await self.bindSuiteChat(t, api: api, key: self.suiteClaudeKey)) {
                    self.showToast("That chat's shot is gone. Start a new chat.")
                }
            },
            deleted: { [weak self] next in
                guard let self, let api = self.suiteAssistAPI else { return }
                let key = self.suiteClaudeKey
                if let next, await self.bindSuiteChat(next, api: api, key: key) { return }
                await self.newSuiteAssist(api: api, key: key)
            })
    }

    /// A tool step of Claude's finished: a draft change is read again and laid over the composer at once, even if the live
    /// `suiteAssist` event was missed (WS18: the owner saw "I set the rig" and an unchanged composer).
    func suiteClaudeToolDone(_ name: String) {
        guard name.hasSuffix("suite_set_draft") || name.hasSuffix("suite_add_reference") || name.hasSuffix("suite_request_shot") else { return }
        Task { await refreshSuiteAssist() }
    }

    /// The shared draft read again (GET) and laid over the composer when it is newer than what the composer shows.
    func refreshSuiteAssist() async {
        guard let api = suiteAssistAPI, let id = suite.claude.assist?.id, let n = try? await api.suiteAssist(id: id) else { return }
        takeSuiteAssist(n)
    }

    // MARK: Claude's changes → the composer

    /// A `suiteAssist` live event.
    func suiteAssistEvent(_ a: SuiteAssist) {
        guard isOwner, suite.claude.assist?.id == a.id else { return }
        takeSuiteAssist(a)
    }

    /// Lays the shared draft over the composer: only values the composer offers, then "Claude set …" with Undo. Our own
    /// echoes and older revisions are ignored (`force` re-applies the current one).
    func takeSuiteAssist(_ a: SuiteAssist, force: Bool = false) {
        let c = suite.claude
        guard c.assist?.id == a.id || c.assist == nil else { return }
        guard force || a.revision > c.revision else { return }
        c.assist = a
        c.revision = max(c.revision, a.revision)
        updateSuiteAsk(a)
        guard let d = a.draft else { return }
        let before = suite.composer
        let refsBefore = c.references
        let r = SuiteAssistDraft.apply(d, to: before, options: suiteDraftOptions)
        var changed = r.changed
        // Reference images Claude added (a pose, style, location or outfit): chips in the composer.
        let refs = SuiteAssistDraft.references(d)
        if refs != refsBefore {
            c.references = refs
            if refs.count > refsBefore.count || !refs.isEmpty { changed.append("References") }
        }
        c.rejected = r.rejected
        if r.composer != before {
            // A character Claude picked keeps Claude's rig: no default rig is laid on top (as Reuse settings).
            if r.composer.tokens.characterId != before.tokens.characterId { suite.restoredCharacterId = r.composer.tokens.characterId }
            suite.composer = r.composer
        }
        if let text = SuiteAssistDraft.toast(changed) {
            showToast(text, action: "Undo") { [weak self] in
                guard let self else { return }
                self.suite.composer = before
                if self.suite.claude.references != refsBefore {
                    self.suite.claude.references = refsBefore
                    self.suite.claude.refsDirty = true
                    self.suiteComposerChanged(now: true)
                }
            }
        }
        c.synced = suite.composer
        // Values the composer refused: the shared draft goes back to what the composer shows, so Claude sees it.
        if !r.rejected.isEmpty { c.synced = nil; suiteComposerChanged() }
    }

    /// A reference chip's remove button: the draft goes back without it.
    func removeSuiteClaudeReference(_ ref: SuiteDraftReference) {
        let c = suite.claude
        c.references.removeAll { $0.id == ref.id }
        c.refsDirty = true
        suiteComposerChanged(now: true)
    }

    // MARK: Attached images

    /// Files from the attach button, a drop or ⌘V: JPEG, PNG, WebP or HEIC up to 10 MB while there is room (4), each
    /// uploaded right away with the normal image upload (HEIC and WebP go up as JPEG). Demo mode keeps them on this Mac.
    func attachSuiteClaudeImages(_ files: [(name: String, data: Data, mime: String?)]) {
        let c = suite.claude
        let (take, refusal) = SuiteClaudeAttachments.check(existing: c.attachments.count, picked: files.map { (name: $0.name, mime: $0.mime, bytes: Optional($0.data.count)) })
        c.attachNote = refusal
        guard let uploader = suiteAssistAPI else {
            if !take.isEmpty { c.attachNote = "This server can't take images for Claude yet." }
            return
        }
        for i in take {
            let f = files[i]
            var mime = SuiteClaudeAttachments.mime(name: f.name, mime: f.mime) ?? "image/jpeg"
            var data = f.data
            var name = f.name
            if mime == "image/heic" || mime == "image/webp", let jpeg = Self.jpeg(data) {
                data = jpeg
                mime = "image/jpeg"
                name = ((f.name as NSString).deletingPathExtension) + ".jpg"
            }
            let a = SuiteClaudeBridge.Attachment(name: name, data: data, mime: mime)
            c.attachments.append(a)
            uploadSuiteClaudeAttachment(a, with: uploader)
        }
    }

    private func uploadSuiteClaudeAttachment(_ a: SuiteClaudeBridge.Attachment, with uploader: any SuiteAssistAPI) {
        let c = suite.claude
        Task { [self] in
            do {
                let up = try await uploader.uploadClaudeImage(name: a.name, data: a.data, mime: a.mime)
                if let k = c.attachments.firstIndex(where: { $0.id == a.id }) { c.attachments[k].uploaded = up }
            } catch let e as ApiError where e.code == "unsupported_image" {
                if let k = c.attachments.firstIndex(where: { $0.id == a.id }) {
                    c.attachments[k].error = "\(a.name) couldn't be read. Send it as JPEG instead."
                    c.attachments[k].unsupported = true
                }
            } catch {
                if let k = c.attachments.firstIndex(where: { $0.id == a.id }) {
                    c.attachments[k].error = (error as? ApiError)?.friendlyMessage ?? "Couldn't upload \(a.name)"
                }
            }
        }
    }

    /// "Send as JPEG" after `415 unsupported_image`: the image converted on this Mac and uploaded again.
    func resendSuiteClaudeAttachmentAsJPEG(_ id: UUID) {
        let c = suite.claude
        guard let k = c.attachments.firstIndex(where: { $0.id == id }), let uploader = suiteAssistAPI else { return }
        guard let jpeg = Self.jpeg(c.attachments[k].data) else {
            c.attachments[k].error = "\(c.attachments[k].name) can't be opened on this Mac either. Try another image."
            c.attachments[k].unsupported = false
            return
        }
        var a = c.attachments[k]
        a.data = jpeg
        a.mime = "image/jpeg"
        a.name = ((a.name as NSString).deletingPathExtension) + ".jpg"
        a.error = nil
        a.unsupported = false
        c.attachments[k] = a
        uploadSuiteClaudeAttachment(a, with: uploader)
    }

    /// HEIC or WebP as JPEG (the Mac decodes both).
    private static func jpeg(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    func attachSuiteClaudeImages(urls: [URL]) {
        var files: [(name: String, data: Data, mime: String?)] = []
        for u in urls {
            // Only an allowed type is read; anything else is passed on empty so the refusal names it.
            let ok = SuiteClaudeAttachments.mime(name: u.lastPathComponent) != nil
            let data = ok ? ((try? Data(contentsOf: u)) ?? Data()) : Data()
            files.append((name: u.lastPathComponent, data: data, mime: nil))
        }
        attachSuiteClaudeImages(files)
    }

    func removeSuiteClaudeAttachment(_ id: UUID) {
        suite.claude.attachments.removeAll { $0.id == id }
        suite.claude.attachNote = nil
    }

    /// The uploaded attachments go with this message and leave the row (failed ones stay so they can be removed).
    private func takeSuiteClaudeAttachments() -> [SuiteClaudeBridge.Attachment] {
        let c = suite.claude
        let ready = c.attachments.filter { $0.uploaded != nil }
        c.attachments.removeAll { $0.uploaded != nil }
        c.attachNote = nil
        return ready
    }

    /// Sending on this Mac: the attached images saved where Claude Code can Read them (Caches/MUSE/claude/<thread>/), with
    /// their upload ids; the turn's prompt lists them and the mirrored message carries the ids. Their links also go on
    /// the message's context line, for the thumbnails until the thread is read again.
    func suiteClaudeTakeFiles(threadId: String) -> [ClaudeAttachmentFile] {
        let taken = takeSuiteClaudeAttachments()
        suite.claude.sentImages = taken.compactMap { a in a.uploaded.flatMap { u in u.url.map { (uploadId: Optional(u.uploadId), url: $0) } } }
        return taken.compactMap { a in a.uploaded.flatMap { ClaudeAttachmentCache.save(a.data, attachment: $0, threadId: threadId) } }
    }

    /// The message Claude gets: the context line (with the attached images' addresses and upload ids), then the text.
    func suiteClaudeOutgoing(_ text: String) -> String {
        let images = suite.claude.sentImages
        suite.claude.sentImages = []
        var line = suiteClaudeContext()
        if let part = SuiteClaudeAttachments.contextPart(images), line.hasSuffix("]") {
            line = String(line.dropLast()) + " · " + part + "]"
        }
        return SuiteAssistClaude.message(text, context: line)
    }

    private func updateSuiteAsk(_ a: SuiteAssist) {
        let c = suite.claude
        guard let w = a.waiting else {
            if !c.answering { c.ask = nil; c.priceNote = nil; c.confirmOpen = false }
            return
        }
        if c.ask?.id != w.id && SnapshotRunner.dir == nil { c.confirmOpen = true }
        if c.ask != w { c.ask = w }
    }

    // MARK: The owner's edits → the shared draft

    /// The composer changed (by hand, Undo, a picker): send it after a short pause.
    func suiteComposerChanged(now: Bool = false) {
        let c = suite.claude
        guard c.assist != nil, c.open || c.refsDirty, suite.composer != c.synced || c.refsDirty else { return }
        c.pushTask?.cancel()
        c.pushTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 700_000_000) }
            guard !Task.isCancelled else { return }
            await self?.pushSuiteDraft()
        }
    }

    /// PATCH with the revision we last saw. On `409 stale`: read the newer draft and keep the owner's edits row by row.
    func pushSuiteDraft(attempt: Int = 0) async {
        let c = suite.claude
        guard let api = suiteAssistAPI, let a = c.assist else { return }
        let mine = suite.composer
        guard mine != c.synced || c.refsDirty else { return }
        // The draft's references ride along (the composer doesn't hold them); a removed one is left out.
        let draft = SuiteAssistDraft.with(c.references, in: ComposerDrafts.draft(mine))
        do {
            let n = try await api.patchSuiteAssist(id: a.id, SuiteAssistPatch(draft: draft, baseRevision: c.revision))
            c.assist = n
            c.revision = max(c.revision, n.revision)
            c.synced = mine
            c.refsDirty = false
            updateSuiteAsk(n)
        } catch let e as ApiError where e.code == "stale" && attempt < 2 {
            guard let latest = try? await api.suiteAssist(id: a.id) else { return }
            let base = c.synced ?? mine
            let theirs = latest.draft.map { SuiteAssistDraft.apply($0, to: base, options: suiteDraftOptions).composer } ?? base
            let merged = SuiteAssistDraft.merge(base: base, mine: suite.composer, theirs: theirs)
            c.assist = latest
            c.revision = max(c.revision, latest.revision)
            updateSuiteAsk(latest)
            if merged != suite.composer { suite.composer = merged }
            c.synced = theirs
            await pushSuiteDraft(attempt: attempt + 1)
        } catch {
            // Not shown: the next edit tries again, and each chat message carries the composer anyway.
        }
    }

    /// The line in front of each chat message: the shared draft and the composer as it is now.
    func suiteClaudeContext() -> String {
        let c = suite.claude
        let d = suite.composer
        return SuiteAssistClaude.context(assistId: c.assist?.id, revision: c.assist?.revision, composer: d, camera: suite.camera,
                                         characterName: d.tokens.characterId.flatMap { character($0)?.shortName }, rejected: c.rejected)
    }

    // MARK: Generate (only with the owner's press)

    /// The owner's answer in the Generate confirmation. Approve runs the shot at the price shown; a changed price asks again.
    func answerSuiteAsk(approve: Bool) {
        let c = suite.claude
        guard !c.answering else { return }
        guard let p = c.ask, let a = c.assist, let api = suiteAssistAPI else { c.ask = nil; return }
        c.answering = true
        Task { [self] in
            do {
                let r = try await api.answerSuitePending(assistId: a.id, pendingId: p.id, approve: approve)
                c.answering = false
                c.ask = nil
                c.priceNote = nil
                if approve, let jid = r.jobId {
                    if let s = try? await self.api.suiteShot(id: jid) { upsert(s.job) }
                    suite.shotJobIds.append(jid)
                    if let b = try? await self.api.balance() { balance = b }
                    showToast("Rendering · \(Pricing.money(p.maxUsd)). You'll get a notification when it's done.", action: "Open queue") { [weak self] in self?.go(.queue) }
                } else if !approve {
                    showToast("Told Claude not now")
                }
                if let n = try? await api.suiteAssist(id: a.id) { takeSuiteAssist(n) }
            } catch let e as ApiError where e.code == "price_changed" {
                c.answering = false
                c.priceNote = e.message
                if let n = try? await api.suiteAssist(id: a.id) { takeSuiteAssist(n, force: true) }
            } catch let e as ApiError {
                c.answering = false
                c.ask = nil
                handle(e)
                // A failed run is marked on the ask with its reason (shown in the panel).
                if let n = try? await api.suiteAssist(id: a.id) { takeSuiteAssist(n, force: true) }
            } catch {
                c.answering = false
                c.ask = nil
                showToast(error.localizedDescription)
            }
        }
    }

    // MARK: Demo mode

    /// Demo mode has no Claude Code: a stand-in reply fills the composer from the typed words through the same shared
    /// draft and checks, and "go" makes the same paid ask (approved in the same confirmation; demo money only).
    func sendSuiteClaudeDemo(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = suite.claude
        guard !text.isEmpty, !c.demoBusy, !c.uploading else { return }
        let taken = takeSuiteClaudeAttachments()
        let images = taken.compactMap(\.ref)
        let uploads = taken.compactMap(\.uploaded)
        c.demoLines.append(.init(fromClaude: false, text: shownDemoText(text), images: images))
        c.demoBusy = true
        Task { [self] in
            defer { c.demoBusy = false }
            await ensureSuiteAssist()
            try? await Task.sleep(nanoseconds: 500_000_000)
            var reply = SuiteAssistClaude.demoReply(to: text, composer: suite.composer, options: suiteDraftOptions)
            // Attached images: the stand-in adds them to the draft as references (as suite_add_reference does): pose,
            // style, location or outfit from the words, style when none is named. At most 3.
            if !uploads.isEmpty {
                let low = text.lowercased()
                let use = SuiteDraftReference.uses.first { low.contains($0) } ?? "style"
                let added = uploads.map { SuiteDraftReference(uploadId: $0.uploadId, url: $0.url ?? "", use: use) }
                let refs = Array((c.references + added).suffix(SuiteDraftReference.maxCount))
                reply.draft = SuiteAssistDraft.with(refs, in: reply.draft ?? SuiteAssistDraft.with(c.references, in: ComposerDrafts.draft(suite.composer)))
                reply.text += uploads.count == 1 ? " I added your image as a \(use) reference." : " I added your \(uploads.count) images as \(use) references."
            } else if let d = reply.draft {
                reply.draft = SuiteAssistDraft.with(c.references, in: d)
            }
            guard let fake = api as? FakeMuseAPI, let a = c.assist else {
                c.demoLines.append(.init(fromClaude: true, text: c.error ?? "The composer isn't shared yet. Close this panel and open it again."))
                return
            }
            do {
                let n = try await fake.demoClaudeAssist(id: a.id, draft: reply.draft, generate: reply.generate)
                takeSuiteAssist(n)
                c.demoLines.append(.init(fromClaude: true, text: reply.text))
            } catch let e as ApiError {
                c.demoLines.append(.init(fromClaude: true, text: "I can't ask to generate it yet: \(e.friendlyMessage)"))
            } catch {
                c.demoLines.append(.init(fromClaude: true, text: error.localizedDescription))
            }
        }
    }

    /// A 240 × 320 still in one colour with a soft lighter band (review shots only).
    private static func reviewPNG(_ color: NSColor) -> Data? {
        let size = NSSize(width: 240, height: 320)
        let img = NSImage(size: size, flipped: false) { r in
            color.setFill()
            r.fill()
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSRect(x: 0, y: r.height * 0.55, width: r.width, height: r.height * 0.2).fill()
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A chip's long instruction shows as its label.
    private func shownDemoText(_ text: String) -> String {
        SuiteAssistClaude.suggestions.first { $0.prompt == text }?.label ?? text
    }

    /// Review mode (SnapshotRunner): the panel open with the composer filled by the stand-in. The first time the chip is
    /// sent; after that the shared draft is laid over the composer again.
    func showSuiteClaudeForReview(ask: Bool = false, attach: Bool = false) {
        let c = suite.claude
        c.open = true
        suite.feedOpen = false
        if attach && c.attachments.isEmpty {
            // Two drawn stills stand in for the owner's images (uploaded to demo mode's store, nothing charged).
            let files = [("pose.png", NSColor(calibratedRed: 0.78, green: 0.58, blue: 0.44, alpha: 1)), ("location.png", NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.55, alpha: 1))]
                .compactMap { name, color in Self.reviewPNG(color).map { (name: name, data: $0, mime: Optional("image/png")) } }
            attachSuiteClaudeImages(files)
        }
        if c.demoLines.isEmpty {
            sendSuiteClaudeDemo(SuiteAssistClaude.fillPrompt)
        } else if let a = c.assist {
            takeSuiteAssist(a, force: true)
        }
        if ask && c.ask == nil {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.sendSuiteClaudeDemo("Pose reference. Go")
            }
        }
    }
}
