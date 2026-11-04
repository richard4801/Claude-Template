import AppKit
import MuseCore
import SwiftUI

// Identity LoRA (plans/lora-training.md), per-model social accounts and posts (plans/socials.md), and model edits.

extension AppStore {
    // MARK: Loading

    /// LoRAs, accounts and posts. Each call is allowed to fail on its own, so a server without these endpoints still loads.
    func loadSocial() async {
        let api = self.api
        for m in models {
            if let l = try? await api.lora(modelId: m.id) { loras[m.id] = l }
            if let a = try? await api.listAccounts(modelId: m.id) { accounts[m.id] = a }
        }
        if let p = try? await api.listPosts(state: nil) { posts = p }
    }

    func applyLora(_ l: Lora) {
        let before = loras[l.modelId]
        loras[l.modelId] = l
        let name = models.first { $0.id == l.modelId }?.shortName ?? "Your model"
        if before?.state == "building" && l.state == "review" {
            Sounds.play(.done)
            if screen != .lora { showToast("\(name)'s training set is ready to review", action: "Review") { [weak self] in self?.openLora(l.modelId) } }
        }
        if before?.state == "training" && l.state == "ready" { loraReady(l, name: name) }
        if before?.state == "training" && l.state == "failed" {
            Sounds.play(.error)
            showToast("LoRA training failed for \(name)")
            if notifyFailed { Notifier.shared.post(title: "LoRA training failed", body: "\(name)'s Identity LoRA stopped. Open MUSE to try again.") }
        }
    }

    private func loraReady(_ l: Lora, name: String) {
        Sounds.play(.done)
        showToast("Identity LoRA v\(l.version) is ready", action: "Open") { [weak self] in self?.openLora(l.modelId) }
        if notifyDone {
            Notifier.shared.post(title: "Identity LoRA v\(l.version) is ready",
                                 body: "\(name) · trained on \(l.trainedOn ?? l.kept) shots. New renders use it\(l.use ? "" : " once you switch it on").")
        }
    }

    // MARK: Identity LoRA

    var loraModel: MuseModel? { profileModel }

    func lora(for m: MuseModel?) -> Lora {
        guard let m else { return Lora(modelId: "") }
        return loras[m.id] ?? Lora(modelId: m.id)
    }

    func openLora(_ modelId: String) {
        profileModelId = modelId
        go(.lora)
        perform { [self] in loras[modelId] = try await api.lora(modelId: modelId) }
    }

    /// "Not trained", "Training · 42%", "v1 · in use"…
    func loraLine(_ l: Lora) -> String {
        switch l.state {
        case "building": return "Building training set…"
        case "review": return "Review the training set"
        case "training": return "Training · \(Int(l.progress.rounded()))%"
        case "ready": return "v\(l.version) · \(l.use ? "in use" : "off")"
        case "failed": return "Training failed"
        default: return l.version > 0 ? "v\(l.version) · \(l.use ? "in use" : "off")" : "Not trained"
        }
    }

    func buildTrainingSet(_ m: MuseModel) {
        if m.filled == 0 {
            showToast("Add character-sheet shots first", action: "Open") { [weak self] in self?.openProfile(m.id) }
            return
        }
        if LoraPricing.setCost > balance.balance + 1e-9 {
            Sounds.play(.error)
            showToast("Not enough balance to build the training set", action: "Top up") { [weak self] in self?.go(.credits) }
            return
        }
        Sounds.play(.go)
        perform { [self] in
            let l = try await api.buildLoraCandidates(modelId: m.id)
            if loras[m.id]?.state != "review" { loras[m.id] = l }
            balance = try await api.balance()
        }
    }

    /// Click a shot to drop it or bring it back. Optimistic; the server's answer wins.
    func toggleCandidate(_ m: MuseModel, _ c: LoraCandidate) {
        guard var l = loras[m.id], l.state == "review", let i = l.candidates.firstIndex(where: { $0.id == c.id }) else { return }
        Sounds.play(.tick)
        let keep = !l.candidates[i].keep
        l.candidates[i].keep = keep
        loras[m.id] = l
        perform { [self] in
            let fresh = try await api.setLoraCandidate(modelId: m.id, candidateId: c.id, keep: keep)
            if loras[m.id]?.state == "review" { loras[m.id] = fresh }
        }
    }

    func trainLora(_ m: MuseModel) {
        let l = lora(for: m)
        if l.kept < LoraPricing.minKept {
            showToast("Keep at least \(LoraPricing.minKept) shots so the LoRA learns her well")
            return
        }
        if LoraPricing.trainCost > balance.balance + 1e-9 {
            Sounds.play(.error)
            showToast("Not enough balance to train", action: "Top up") { [weak self] in self?.go(.credits) }
            return
        }
        Sounds.play(.go)
        perform { [self] in
            let fresh = try await api.trainLora(modelId: m.id)
            if loras[m.id]?.state != "ready" { loras[m.id] = fresh }
            balance = try await api.balance()
            showToast("Training both LoRAs · \(Pricing.money(LoraPricing.trainCost)). You'll get a notification when they're ready.")
        }
    }

    func setLoraUse(_ m: MuseModel, _ use: Bool) {
        loras[m.id]?.use = use
        perform { [self] in
            loras[m.id] = try await api.setLoraUse(modelId: m.id, use: use)
            showToast(use ? "New renders use LoRA v\(loras[m.id]?.version ?? 1)" : "Off: new renders use the references only")
        }
    }

    /// "Retrain with more shots": back to the review grid with the same shots (bring back or drop any), then train v{n+1}.
    /// The current version stays in use until the new one is ready.
    func retrainLora(_ m: MuseModel) {
        perform { [self] in loras[m.id] = try await api.retrainLora(modelId: m.id) }
    }

    // MARK: Accounts

    func accounts(for m: MuseModel?) -> [Account] { m.flatMap { accounts[$0.id] } ?? [] }

    func account(_ m: MuseModel?, _ p: Platform) -> Account? { accounts(for: m).first { $0.platform == p } }

    func isConnecting(_ m: MuseModel, _ p: Platform) -> Bool { connecting.contains("\(m.id)/\(p.rawValue)") }

    func connect(_ m: MuseModel, _ p: Platform) {
        let key = "\(m.id)/\(p.rawValue)"
        guard !connecting.contains(key) else { return }
        connecting.insert(key)
        perform { [self] in
            defer { connecting.remove(key) }
            switch try await api.connectAccount(modelId: m.id, platform: p) {
            case .connected(let a):
                var list = accounts[m.id] ?? []
                list.removeAll { $0.platform == p }
                list.append(a)
                accounts[m.id] = Platform.allCases.compactMap { pl in list.first { $0.platform == pl } }
                Sounds.play(.done)
                showToast("\(p.label) connected · \(a.handle)")
            case .authorize(let url):
                // Real OAuth: the platform's sign-in page opens in the browser; the account appears after the redirect.
                NSWorkspace.shared.open(url)
                showToast("Sign in to \(p.label) in your browser, then come back", action: "Refresh") { [weak self] in self?.refreshAccounts(m) }
            }
        }
    }

    func refreshAccounts(_ m: MuseModel) {
        perform { [self] in accounts[m.id] = try await api.listAccounts(modelId: m.id) }
    }

    func disconnect(_ m: MuseModel, _ p: Platform) {
        perform { [self] in
            try await api.disconnectAccount(modelId: m.id, platform: p)
            accounts[m.id]?.removeAll { $0.platform == p }
            showToast("\(p.label) disconnected")
        }
    }

    // MARK: Posts

    /// The model a take belongs to: its job's model, else the studio's current model (photoshoot stills carry no model id).
    func model(for take: Take) -> MuseModel? {
        if let j = job(for: take), let m = models.first(where: { $0.id == j.modelId }) { return m }
        return currentModel
    }

    func take(for post: Post) -> Take? { takes.first { $0.id == post.takeId } }

    func posts(for take: Take) -> [Post] { posts.filter { $0.takeId == take.id } }

    var scheduledPosts: [Post] { posts.filter(\.isScheduled) }
    var postedPosts: [Post] { posts.filter(\.isOut) }

    func openPostSheet(_ take: Take) {
        guard let m = model(for: take) else { return }
        let connected = accounts(for: m).map(\.platform)
        Sounds.play(.tap)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            postDraft = PostDraft(takeId: take.id, modelId: m.id, platforms: Array(connected.prefix(2)), when: PostTime.suggestions()[0])
        }
    }

    func togglePostPlatform(_ p: Platform) {
        guard var d = postDraft else { return }
        if let i = d.platforms.firstIndex(of: p) { d.platforms.remove(at: i) } else { d.platforms.append(p) }
        d.platforms = Platform.allCases.filter { d.platforms.contains($0) }
        postDraft = d
    }

    func connectFromPostSheet() {
        guard let d = postDraft else { return }
        postDraft = nil
        openProfile(d.modelId)
    }

    func submitPost() {
        guard let d = postDraft, !d.busy else { return }
        guard !d.platforms.isEmpty else {
            showToast("Pick at least one account")
            return
        }
        if d.schedule && d.when <= Date() {
            showToast("Pick a time in the future")
            return
        }
        // The labels go out exactly as the user left them; MUSE never turns them on by itself.
        let req = CreatePostRequest(modelId: d.modelId, takeId: d.takeId, platforms: d.platforms, caption: d.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                    aiLabel: d.aiLabel, paidPartnership: d.paidPartnership, when: d.schedule ? PostTime.string(d.when) : "now")
        postDraft?.busy = true
        perform { [self] in
            do {
                let p = try await api.createPost(req)
                if let i = posts.firstIndex(where: { $0.id == p.id }) { posts[i] = p } else { posts.insert(p, at: 0) }
                withAnimation { postDraft = nil }
                Sounds.play(.done)
                if p.isScheduled {
                    let when = p.scheduledDate ?? d.when
                    let who = models.first { $0.id == p.modelId }?.shortName ?? "your model"
                    Notifier.shared.schedulePost(id: p.id, title: "Time to post · \(who)",
                                                 body: "Click to open \(p.platforms.map(\.label).joined(separator: ", ")) with the video saved and the caption copied.", at: when)
                    showToast("Scheduled for \(PostTime.label(when)). We'll remind you.", action: "View posts") { [weak self] in
                        self?.postTab = .scheduled
                        self?.go(.posts)
                    }
                } else {
                    handoff(p)
                }
            } catch {
                postDraft?.busy = false
                throw error
            }
        }
    }

    /// Stage 1 handoff: save and reveal the export, copy the caption, and open each platform's upload page.
    /// The user presses Post there. Once a platform approves MUSE (`canPostDirect`), the server posts instead.
    func handoff(_ p: Post) {
        let direct = p.platforms.filter { pl in account(models.first { $0.id == p.modelId }, pl)?.canPostDirect == true }
        let manual = p.platforms.filter { !direct.contains($0) }
        if !p.caption.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.caption, forType: .string)
        }
        if !manual.isEmpty, let t = take(for: p), let file = exportFile(t) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        for pl in manual { NSWorkspace.shared.open(pl.uploadURL) }
        let first = manual.first ?? p.platforms.first
        let opening = first.map { "Opening \($0.label)\(manual.count > 1 ? " and \(manual.count - 1) more" : "")…" } ?? "Posted"
        showToast(manual.isEmpty ? "Posted" : "\(opening) The video is in Finder\(p.caption.isEmpty ? "" : " and the caption is copied").",
                  action: "View posts") { [weak self] in
            self?.postTab = .posted
            self?.go(.posts)
        }
    }

    /// A scheduled-post notification was clicked.
    func openScheduledPost(_ id: String) {
        perform { [self] in
            if let fresh = try? await api.listPosts(state: nil) { posts = fresh }
            guard let p = posts.first(where: { $0.id == id }) else {
                showToast("That post was cancelled")
                return
            }
            handoff(p)
        }
    }

    func cancelPost(_ p: Post) {
        perform { [self] in
            try await api.deletePost(id: p.id)
            Notifier.shared.cancelPost(id: p.id)
            withAnimation { posts.removeAll { $0.id == p.id } }
            showToast("Scheduled post cancelled")
        }
    }

    // MARK: Export and share

    /// Writes the take to ~/Downloads/MUSE. The mock renders no video, so the still (or its placeholder art) is saved at 1080×1920.
    func exportFile(_ t: Take) -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent("MUSE", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = t.caption.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let base = String((safe.isEmpty ? "MUSE take" : safe).prefix(80))
        if let u = t.thumb.url, u.hasPrefix("file:"), let src = URL(string: u) {
            let dst = dir.appendingPathComponent(base).appendingPathExtension(src.pathExtension.isEmpty ? "jpg" : src.pathExtension)
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: src, to: dst)) != nil { return dst }
        }
        let dst = dir.appendingPathComponent(base).appendingPathExtension("png")
        let size = CGSize(width: 1080, height: 1920)
        let view = MuseImage(ref: t.thumb).frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: view)
        r.proposedSize = ProposedViewSize(size)
        guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        do { try png.write(to: dst) } catch { return nil }
        return dst
    }

    /// The system share sheet (AirDrop, Messages, Photos…) for the exported take.
    func share(_ t: Take) {
        guard let file = exportFile(t), let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [file])
        let anchor = NSRect(x: view.bounds.maxX - 420, y: view.bounds.maxY - 140, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    // MARK: Model edits

    /// Saves the never-add list on the server (PATCH /v1/models/{id}). Kept on this Mac when the server doesn't have the endpoint.
    func saveNeverList(_ m: MuseModel, _ list: [String]) {
        neverOverrides[m.id] = list
        Task { [weak self] in
            guard let self else { return }
            if let updated = try? await self.api.updateModel(id: m.id, UpdateModelRequest(neverAdd: list)) {
                self.replaceModel(updated)
                if self.neverOverrides[m.id] == list { self.neverOverrides[m.id] = nil }
            }
        }
    }

    func deleteModel(_ m: MuseModel) {
        let alert = NSAlert()
        alert.messageText = "Delete \(m.name)?"
        alert.informativeText = "This deletes her character sheet, outfits, Identity LoRA and training set, and disconnects her accounts. Finished takes stay in the Gallery."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in
            try await api.deleteModel(id: m.id)
            models.removeAll { $0.id == m.id }
            outfits.removeAll { $0.modelId == m.id }
            loras[m.id] = nil
            accounts[m.id] = nil
            neverOverrides[m.id] = nil
            if modelId == m.id, let next = models.first(where: { !$0.isDraft }) ?? models.first { modelId = next.id }
            if let next = models.first { profileModelId = next.id }
            go(.models)
            showToast("\(m.name) deleted")
        }
    }
}
