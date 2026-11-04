import AppKit
import MuseCore
import SwiftUI

// User actions, grouped by screen. Everything that touches the backend goes through `api`.

extension AppStore {
    // MARK: Clip

    func pickClip() {
        if let u = MediaImport.pick(MediaImport.videoTypes, multiple: false, prompt: "Use clip").first { importClip(u) }
    }

    func importClip(_ url: URL) {
        guard MediaImport.isVideo(url) else {
            showToast("That isn't a video. Drop an .mp4 or .mov clip.")
            return
        }
        perform { [self] in
            let (meta, thumb) = try await MediaImport.clipInfo(url)
            let c = try await api.uploadClip(meta, file: url)
            clip = c
            clipFile = url
            clipThumb = thumb.map { ImageRef(url: $0.absoluteString) }
            if c.durationSec <= ClipUse.first.sampleSeconds { use = .full }
            if c.ok {
                showToast("Clip checked · \(Pricing.trimNum(c.durationSec))s · \(c.width)×\(c.height). Ready to generate.")
            } else {
                showToast("This clip needs fixing before you can generate. See the clip check.")
            }
        }
    }

    func useSampleClip(bad: Bool, quiet: Bool = false) async {
        do {
            let c = try await api.uploadClip(bad ? SampleData.badMeta : SampleData.sampleMeta, file: nil)
            clip = c
            clipFile = nil
            clipThumb = nil
        } catch {
            if !quiet { showToast((error as? ApiError)?.message ?? error.localizedDescription) }
        }
    }

    func toggleBadSample() {
        let bad = !clipBad
        Task { await useSampleClip(bad: bad) }
    }

    // MARK: Studio

    func setSteps(_ n: Int) {
        let v = Pricing.clampSteps(n)
        guard v != steps else { return }
        steps = v
    }

    func setTakes(_ n: Int) { takeCount = Pricing.clampTakes(n) }

    func resetStudio() {
        steps = defaultSteps
        engine = defaultEngine
        takeCount = 1
        lipSync = false
        keepAudio = true
        background = "keep"
        use = .first
        showToast("Settings reset")
    }

    func selectModel(_ m: MuseModel) {
        if m.isDraft || m.filled == 0 {
            showToast("\(m.shortName) is a draft. Add face close-ups to use her.", action: "Open") { [weak self] in self?.openProfile(m.id) }
            return
        }
        modelId = m.id
        if outfits(for: m).isEmpty { showToast("\(m.shortName) has no outfits yet.", action: "Add outfit") { [weak self] in self?.openOutfitSheet(for: m.id) } }
    }

    /// ⌘↵ and the Generate button. Blocked when the clip fails its checks or the balance is too low.
    func generate() {
        if clipBad {
            showToast("Fix the clip first: one person, no watermark, 15s or less")
            return
        }
        if lowBalance {
            showToast("Not enough balance for this render", action: "Top up") { [weak self] in self?.go(.credits) }
            return
        }
        guard !generating else { return }
        guard let m = currentModel, let o = currentOutfit, let c = clip else {
            showToast("Pick a model, an outfit and a clip first")
            return
        }
        let cost = totalCost
        if warnOverBudget && cost > balance.perJobLimit {
            showToast("This render costs \(Pricing.money(cost)), over your \(Pricing.money(balance.perJobLimit)) per-job cap. Lower the steps or takes.")
            return
        }
        let req = JobRequest(title: "\(m.shortName) · \(o.name)", modelId: m.id, outfitId: o.id, clipId: c.id, engine: engine.rawValue,
                             steps: engine == .viggle ? 4 : steps, use: use.rawValue, takes: takeCount, keepAudio: keepAudio, lipSync: lipSync,
                             background: background, backgroundMotion: motion, clipSeconds: c.durationSec)
        let n = takeCount
        generating = true
        perform { [self] in
            defer { generating = false }
            let j = try await api.createJob(req)
            upsert(j)
            balance = try await api.balance()
            showToast("Rendering \(n > 1 ? "\(n) takes" : "1 take") · \(Pricing.money(cost)). You'll get a notification when it's done.", action: "Open queue") { [weak self] in
                self?.go(.queue)
            }
        }
    }

    func upsert(_ j: Job) {
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) }
    }

    /// Loads a finished job's settings back into the studio ("Retake with changes").
    func loadIntoStudio(_ j: Job) {
        modelId = j.modelId
        outfitIdByModel[j.modelId] = j.outfitId
        engine = j.engine
        steps = Pricing.clampSteps(j.request.steps)
        use = ClipUse(id: j.request.use)
        takeCount = Pricing.clampTakes(j.request.takes)
        keepAudio = j.request.keepAudio
        lipSync = j.request.lipSync
        background = j.request.background
        motion = j.request.backgroundMotion
        go(.studio)
    }

    // MARK: Queue

    func runQueue() {
        perform { [self] in
            try await api.runQueue()
            showToast("GPU starting · about 1–2 min")
        }
    }

    func retry(_ j: Job) {
        perform { [self] in
            let n = try await api.createJob(j.request)
            upsert(n)
            hiddenFailures.insert(j.id)
            balance = try await api.balance()
            showToast("Retrying \(j.title) · \(Pricing.money(n.cost))")
        }
    }

    func dismissFailure(_ j: Job) {
        withAnimation { _ = hiddenFailures.insert(j.id) }
    }

    func runAgain(_ j: Job) {
        perform { [self] in
            let n = try await api.createJob(j.request)
            upsert(n)
            balance = try await api.balance()
            showToast("Added to the queue")
        }
    }

    func removeJob(_ j: Job) {
        guard !j.isRunning else {
            showToast("This job is rendering. It can be removed when it finishes.")
            return
        }
        perform { [self] in
            try await api.removeJob(id: j.id)
            withAnimation { jobs.removeAll { $0.id == j.id } }
        }
    }

    func watch(_ j: Job) {
        if let t = takes.first(where: { $0.jobId == j.id }) { openTake(t.id) } else { showToast(j.isDone ? "No take found for this job" : "Still rendering · \(j.phase)") }
    }

    func copy(_ text: String, toast message: String = "Prompt copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(message)
    }

    // MARK: Gallery and result

    func openTake(_ id: String) {
        guard !id.isEmpty else { return }
        openTakeId = id
        fresh.remove(id)
        go(.result)
    }

    func togglePick(_ id: String) {
        if picked.contains(id) { picked.removeAll { $0 == id } } else { picked = Array((picked + [id]).suffix(4)) }
    }

    func openCompare() {
        guard picked.count >= 2 else { return }
        withAnimation(MotionStyle.of(themeID).animation) { comparing = true }
    }

    func compareFromResult() {
        guard let t = openedTake else { return }
        let others = takes.filter { $0.id != t.id && $0.isVideo == t.isVideo }.prefix(2).map(\.id)
        picked = [t.id] + others
        comparing = true
        go(.gallery)
    }

    func approve(_ t: Take) {
        guard !t.isFinal else { return }
        perform { [self] in
            let u = try await api.setTakeStatus(id: t.id, status: "final")
            if let i = takes.firstIndex(where: { $0.id == u.id }) { takes[i] = u }
            showToast("Moved to Final")
        }
    }

    func unapprove(_ t: Take) {
        perform { [self] in
            let u = try await api.setTakeStatus(id: t.id, status: "test")
            if let i = takes.firstIndex(where: { $0.id == u.id }) { takes[i] = u }
            showToast("Moved back to Tests")
        }
    }

    func discard(_ t: Take) {
        perform { [self] in
            try await api.deleteTake(id: t.id)
            takes.removeAll { $0.id == t.id }
            picked.removeAll { $0 == t.id }
            showToast("Take discarded")
            go(.gallery)
        }
    }

    /// Saves the take to ~/Downloads/MUSE. No label is added: labels are the user's choice when posting (plans/socials.md).
    func export(_ t: Take) {
        let file = exportFile(t)
        showToast("Exported 1080×1920", action: file == nil ? nil : "Show in Finder") {
            if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }

    func retake(_ t: Take) {
        if t.isVideo, let j = job(for: t) {
            loadIntoStudio(j)
        } else if t.isVideo {
            go(.studio)
        } else {
            go(.shoot)
        }
    }

    // MARK: Photoshoot

    func startShoot() {
        guard shootState != .busy, let m = currentModel, let o = currentOutfit else {
            if currentOutfit == nil { showToast("Add an outfit first", action: "Add outfit") { [weak self] in self?.openOutfitSheet(for: nil) } }
            return
        }
        if Pricing.shootCost > balance.balance {
            showToast("Not enough balance for a shoot", action: "Top up") { [weak self] in self?.go(.credits) }
            return
        }
        let prompt = promptOverride ?? shootPromptText
        let req = ShootRequest(modelId: m.id, outfitId: o.id, scene: shoot.effectiveScene, prompt: prompt, seed: shoot.lockSeed ? 48213 : nil)
        withAnimation { shootState = .busy }
        perform { [self] in
            do {
                let shots = try await api.shoot(req)
                for s in shots.reversed() where !takes.contains(where: { $0.id == s.id }) { takes.insert(s, at: 0) }
                lastShots = shots
                fresh.formUnion(shots.map(\.id))
                promptOverride = nil
                balance = try await api.balance()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { shootState = .done }
            } catch {
                shootState = .idle
                throw error
            }
        }
    }

    func resetCamera() {
        shoot.resetCamera()
        showToast("Camera reset")
    }

    // MARK: Profile

    func openProfile(_ id: String) {
        profileModelId = id
        go(.profile)
    }

    func uploadImage(_ url: URL) async throws -> ImageRef {
        let (data, mime) = try MediaImport.imagePayload(url)
        let ref = try await api.uploadImage(name: url.lastPathComponent, data: data, mime: mime)
        if let u = ref.url, u.hasPrefix("file:") || u.hasPrefix("data:"), let img = NSImage(contentsOf: url) { ImageCache.shared.put(u, img) }
        return ref
    }

    func replaceSlot(_ m: MuseModel, _ angle: SheetAngle, with url: URL? = nil) {
        guard let u = url ?? MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use image").first else { return }
        guard MediaImport.isImage(u) else { showToast("That isn't an image"); return }
        perform { [self] in
            let ref = try await uploadImage(u)
            let updated = try await api.setSlot(modelId: m.id, slot: angle.rawValue, SetSlotRequest(image: ref, source: "upload"))
            replaceModel(updated)
            showToast("\(angle.label) replaced")
        }
    }

    func uploadSheet(_ m: MuseModel, urls given: [URL]? = nil) {
        let urls = (given ?? MediaImport.pick(MediaImport.imageTypes, multiple: true, prompt: "Add to sheet")).filter(MediaImport.isImage)
        guard !urls.isEmpty else { return }
        let free = SheetAngle.allCases.filter { m.slot($0.rawValue)?.image == nil }
        var plan = MediaImport.sortIntoSlots(urls, free: free)
        if plan.isEmpty { plan = MediaImport.sortIntoSlots(urls, free: SheetAngle.allCases) }
        perform { [self] in
            var last = m
            for (angle, u) in plan {
                let ref = try await uploadImage(u)
                last = try await api.setSlot(modelId: m.id, slot: angle.rawValue, SetSlotRequest(image: ref, source: "upload"))
            }
            replaceModel(last)
            showToast("Added \(plan.count) image\(plan.count == 1 ? "" : "s") to \(m.shortName)'s sheet")
        }
    }

    func retakeSlot(_ m: MuseModel, _ angle: SheetAngle) {
        perform { [self] in
            // No single-slot endpoint: clear the slot, then "fill missing angles" regenerates just that one ($0.02).
            _ = try await api.setSlot(modelId: m.id, slot: angle.rawValue, SetSlotRequest(image: nil, source: "generated"))
            let r = try await api.fillAngles(modelId: m.id)
            replaceModel(r.model)
            balance = try await api.balance()
            showToast("Retaking \(angle.label.lowercased()) from your other images · \(Pricing.money(r.cost))")
        }
    }

    func replaceModel(_ m: MuseModel) {
        if let i = models.firstIndex(where: { $0.id == m.id }) { models[i] = m } else { models.append(m) }
    }

    func addNever(_ m: MuseModel, _ item: String) {
        let v = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty else { return }
        var list = neverList(m)
        if !list.contains(v) { list.append(v) }
        saveNeverList(m, list)
    }

    func removeNever(_ m: MuseModel, at i: Int) {
        var list = neverList(m)
        guard list.indices.contains(i) else { return }
        list.remove(at: i)
        saveNeverList(m, list)
    }

    func duplicate(_ m: MuseModel) {
        perform { [self] in
            var copy = try await api.createModel(CreateModelRequest(name: "\(m.name) copy", age: m.age, niche: m.niche, personality: m.personality, notes: m.notes))
            for s in m.slots where s.image != nil {
                copy = try await api.setSlot(modelId: copy.id, slot: s.key, SetSlotRequest(image: s.image, source: s.source))
            }
            replaceModel(copy)
            neverOverrides[copy.id] = neverList(m)
            showToast("Model duplicated", action: "Open") { [weak self] in self?.openProfile(copy.id) }
        }
    }

    func shareProfileCard(_ m: MuseModel) {
        let text = "\(m.name) · \(m.niche)\n\(m.personality)\nMade with MUSE · AI-generated character"
        copy(text, toast: "Profile card copied")
    }

    // MARK: New model

    func createNext() {
        withAnimation(MotionStyle.of(themeID).animation) { create.step = 2 }
    }

    func createBack() {
        withAnimation(MotionStyle.of(themeID).animation) { create.step = 1 }
    }

    func cancelCreate() {
        create = CreateDraft()
        go(.models)
    }

    func addDraftImages(_ urls: [URL]) {
        let imgs = urls.filter(MediaImport.isImage)
        guard !imgs.isEmpty else {
            if !urls.isEmpty { showToast("Only images go on the character sheet") }
            return
        }
        let free = SheetAngle.allCases.filter { create.slots[$0] == nil }
        let plan = MediaImport.sortIntoSlots(imgs, free: free)
        if plan.isEmpty { showToast("All six slots are full. Replace one from its menu."); return }
        Task { [weak self] in
            for (angle, u) in plan {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { self?.create.slots[angle] = .local(u) }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            if let self, let id = self.create.modelId {
                for (angle, u) in plan { self.pushDraftSlot(id, angle, u) }
            }
        }
        if plan.count < imgs.count { showToast("\(imgs.count - plan.count) image\(imgs.count - plan.count == 1 ? "" : "s") left over: all slots are full") }
    }

    func setDraftSlot(_ angle: SheetAngle, _ url: URL? = nil) {
        guard let u = url ?? MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use image").first else { return }
        guard MediaImport.isImage(u) else { showToast("That isn't an image"); return }
        withAnimation { create.slots[angle] = .local(u) }
        if let id = create.modelId { pushDraftSlot(id, angle, u) }
    }

    func clearDraftSlot(_ angle: SheetAngle) {
        withAnimation { create.slots[angle] = nil }
        if let id = create.modelId {
            perform { [self] in replaceModel(try await api.setSlot(modelId: id, slot: angle.rawValue, SetSlotRequest(image: nil))) }
        }
    }

    /// "You can move any image to another slot": swaps two slots.
    func moveDraftSlot(_ from: SheetAngle, to: SheetAngle) {
        guard from != to else { return }
        let a = create.slots[from], b = create.slots[to]
        withAnimation {
            create.slots[to] = a
            create.slots[from] = b
        }
        if let id = create.modelId {
            perform { [self] in
                for (angle, slot) in [(to, a), (from, b)] {
                    var req = SetSlotRequest(image: nil)
                    switch slot {
                    case .local(let u)?: req = SetSlotRequest(image: try await uploadImage(u))
                    case .remote(let ref, let ai)?: req = SetSlotRequest(image: ref, source: ai ? "generated" : "upload")
                    case .busy?: continue
                    case nil: break
                    }
                    let updated = try await api.setSlot(modelId: id, slot: angle.rawValue, req)
                    replaceModel(updated)
                }
            }
        }
    }

    private func pushDraftSlot(_ id: String, _ angle: SheetAngle, _ u: URL) {
        perform { [self] in
            let ref = try await uploadImage(u)
            replaceModel(try await api.setSlot(modelId: id, slot: angle.rawValue, SetSlotRequest(image: ref)))
            create.slots[angle] = .remote(ref, ai: false)
        }
    }

    /// Creates the model on the backend (once) and uploads every local slot.
    private func ensureDraftModel() async throws -> String {
        let id: String
        if let existing = create.modelId {
            id = existing
        } else {
            let m = try await api.createModel(CreateModelRequest(name: create.name, age: create.age, niche: create.niche, personality: create.personality, notes: create.notes))
            replaceModel(m)
            create.modelId = m.id
            id = m.id
        }
        for angle in SheetAngle.allCases {
            if case .local(let u) = create.slots[angle] {
                let ref = try await uploadImage(u)
                replaceModel(try await api.setSlot(modelId: id, slot: angle.rawValue, SetSlotRequest(image: ref)))
                create.slots[angle] = .remote(ref, ai: false)
            }
        }
        return id
    }

    func fillMissing() {
        let missing = SheetAngle.allCases.filter { create.slots[$0] == nil }
        guard !missing.isEmpty else { return }
        let cost = Pricing.fillAnglesCost(missing.count)
        if cost > balance.balance { showToast("Not enough balance", action: "Top up") { [weak self] in self?.go(.credits) }; return }
        withAnimation { for a in missing { create.slots[a] = .busy } }
        perform { [self] in
            do {
                let id = try await ensureDraftModel()
                let r = try await api.fillAngles(modelId: id)
                replaceModel(r.model)
                syncDraftSlots(from: r.model)
                balance = try await api.balance()
            } catch {
                for a in missing where create.slots[a] == .busy { create.slots[a] = nil }
                throw error
            }
        }
    }

    /// Model events update the draft's slots (busy → AI images).
    func syncDraftSlots(from m: MuseModel) {
        guard m.id == create.modelId else { return }
        for s in m.slots {
            guard let angle = SheetAngle(rawValue: s.key) else { continue }
            if s.busy {
                create.slots[angle] = .busy
            } else if let img = s.image {
                if case .local = create.slots[angle] { continue }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { create.slots[angle] = .remote(img, ai: s.isAI) }
            }
        }
    }

    func createSave() {
        guard !create.busy else { return }
        let name = create.name.trimmingCharacters(in: .whitespaces).isEmpty ? "New model" : create.name
        let n = create.filled
        perform { [self] in
            let id = try await ensureDraftModel()
            create = CreateDraft()
            showToast("\(name) saved with \(n)/6 shots\(n < 6 ? " · you can add the rest any time" : "")", action: "Open") { [weak self] in self?.openProfile(id) }
            go(.models)
        }
    }

    // MARK: Outfit sets

    func openOutfitSheet(for modelId: String?) {
        guard let id = modelId ?? currentModel?.id else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { outfitSheet = OutfitDraft(modelId: id) }
    }

    func outfitGenerate() {
        guard var d = outfitSheet, d.state != .busy else { return }
        if d.mode == .describe && d.description.trimmingCharacters(in: .whitespaces).isEmpty {
            showToast("Describe the outfit first")
            return
        }
        if d.mode != .describe && d.images.isEmpty {
            showToast(d.mode == .photo ? "Drop a product photo first" : "Drop your angle images first")
            return
        }
        if d.mode != .own && Pricing.outfitSetCost > balance.balance {
            showToast("Not enough balance", action: "Top up") { [weak self] in self?.go(.credits) }
            return
        }
        d.state = .busy
        outfitSheet = d
        let draft = d
        perform { [self] in
            do {
                var refs: [ImageRef] = []
                for u in draft.images { refs.append(try await uploadImage(u)) }
                let name = draft.name.isEmpty ? (draft.mode == .describe ? draft.description : draft.mode == .photo ? "Product look" : "My set") : draft.name
                let o = try await api.createOutfit(CreateOutfitRequest(modelId: draft.modelId, name: String(name.prefix(32)), mode: draft.mode.rawValue,
                                                                       description: draft.description, images: refs))
                if let i = outfits.firstIndex(where: { $0.id == o.id }) { outfits[i] = o } else { outfits.append(o) }
                outfitSheet?.outfitId = o.id
                if o.state == "preview" || o.state == "ready" {
                    outfitSheet?.angles = o.angles
                    outfitSheet?.state = .done
                }
                balance = try await api.balance()
            } catch {
                outfitSheet?.state = .idle
                throw error
            }
        }
    }

    func outfitSave() {
        guard let d = outfitSheet, let oid = d.outfitId else { return }
        perform { [self] in
            let o = try await api.saveOutfit(outfitId: oid)
            if let i = outfits.firstIndex(where: { $0.id == o.id }) { outfits[i] = o } else { outfits.append(o) }
            if let i = models.firstIndex(where: { $0.id == d.modelId }), !models[i].outfitIds.contains(o.id) { models[i].outfitIds.append(o.id) }
            outfitIdByModel[d.modelId] = o.id
            let who = models.first { $0.id == d.modelId }?.shortName ?? "your model"
            withAnimation { outfitSheet = nil }
            showToast("Outfit saved to \(who)")
        }
    }

    // MARK: Credits and developer

    func topUp(method: String) {
        let amount = topUpAmount
        perform { [self] in
            balance = try await api.topUp(TopUpRequest(amount: amount, method: method))
            showToast("\(Pricing.money(amount)) added")
        }
    }

    func setFailNext() {
        perform { [self] in
            try await api.setFailNext(true)
            showToast("The next render will fail at step 3")
        }
    }

    func testConnection() {
        perform { [self] in
            let b = try await api.balance()
            offlineMessage = nil
            showToast("Connected · balance \(Pricing.money(b.balance))")
        }
    }

    // MARK: Command palette

    struct PaletteCommand {
        let title: String
        let icon: String
        let shortcut: String
        let run: () -> Void
    }

    var paletteCommands: [PaletteCommand] {
        let all: [PaletteCommand] = [
            PaletteCommand(title: "New video", icon: "video", shortcut: "⌘N") { [weak self] in self?.go(.studio) },
            PaletteCommand(title: "Photoshoot", icon: "camera", shortcut: "⌘4") { [weak self] in self?.go(.shoot) },
            PaletteCommand(title: "New model", icon: "person.badge.plus", shortcut: "") { [weak self] in self?.go(.create) },
            PaletteCommand(title: "Home", icon: "house", shortcut: "⌘1") { [weak self] in self?.go(.home) },
            PaletteCommand(title: "Models", icon: "person", shortcut: "⌘2") { [weak self] in self?.go(.models) },
            PaletteCommand(title: "Queue", icon: "list.bullet.below.rectangle", shortcut: "⌘5") { [weak self] in self?.go(.queue) },
            PaletteCommand(title: "Gallery", icon: "square.grid.2x2", shortcut: "⌘6") { [weak self] in self?.go(.gallery) },
            PaletteCommand(title: "Posts", icon: "paperplane", shortcut: "⌘7") { [weak self] in self?.go(.posts) },
            PaletteCommand(title: "Identity LoRA", icon: "sparkles", shortcut: "") { [weak self] in
                guard let self, let m = self.profileModel ?? self.currentModel else { return }
                self.openLora(m.id)
            },
            PaletteCommand(title: "Settings", icon: "slider.horizontal.3", shortcut: "⌘,") { [weak self] in self?.go(.settings) },
            PaletteCommand(title: "Credits & top up", icon: "creditcard", shortcut: "") { [weak self] in self?.go(.credits) },
            PaletteCommand(title: "New outfit set", icon: "tshirt", shortcut: "") { [weak self] in self?.openOutfitSheet(for: nil) },
            PaletteCommand(title: "Choose a clip…", icon: "film", shortcut: "") { [weak self] in self?.go(.studio); self?.pickClip() },
            PaletteCommand(title: "Run queue", icon: "play.fill", shortcut: "") { [weak self] in self?.runQueue() },
        ] + ThemeID.allCases.map { id in
            PaletteCommand(title: "Theme: \(id.name)", icon: "paintpalette", shortcut: "") { [weak self] in self?.setTheme(id) }
        } + [
            PaletteCommand(title: "Toggle pro mode (show prompts)", icon: "sparkles", shortcut: "") { [weak self] in
                guard let self else { return }
                self.pro.toggle()
                self.showToast(self.pro ? "Pro mode on: prompts are shown" : "Pro mode off")
            },
        ]
        let q = paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }

    func openPalette() {
        guard user != nil else { return }
        paletteQuery = ""
        paletteIndex = 0
        withAnimation(.easeOut(duration: 0.15)) { paletteOpen = true }
    }

    func closePalette() {
        withAnimation(.easeIn(duration: 0.12)) { paletteOpen = false }
    }

    func runPalette(_ i: Int) {
        let cmds = paletteCommands
        guard cmds.indices.contains(i) else { return }
        closePalette()
        cmds[i].run()
    }
}
