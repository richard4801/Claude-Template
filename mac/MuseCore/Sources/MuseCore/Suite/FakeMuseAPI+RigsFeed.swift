import Foundation

// AI suite (workstream 1, build step 2) in demo mode: saved rigs, a model's default rig, drafts kept with jobs and takes, and
// the takes feed. Same rules and wording as server/api (suite/rigs.ts, suite/drafts.ts, suite/feed.ts and PATCH
// /v1/models/:id), so the new Suite's UI behaves the same with no server.

extension FakeMuseAPI {
    // MARK: Demo data

    /// The demo model's default rig (applied to rows still on Auto when she's @-mentioned).
    static let demoDefaultRig = SuiteRig(body: "film_35", lens: "warm_vintage", lighting: "window", palette: "golden_warmth", stock: "portrait_negative")

    /// The demo models: `Demo model` carries a default rig.
    static func suiteDemoModels() -> [MuseModel] {
        SampleData.models().map { m0 in
            var m = m0
            if m.id == SampleData.demo { m.defaultRig = demoDefaultRig }
            return m
        }
    }

    /// Two of the owner's rigs and one of a member's (the owner sees all three, the member only hers).
    static let demoRigs: [SuiteRigView] = [
        SuiteRigView(id: "rig_demo_golden", name: "Golden film",
                     rig: SuiteRig(body: "film_35", lens: "anamorphic", focalMm: 50, aperture: "f1.4", height: "eye", shotSize: "mcu", lighting: "golden_hour",
                                   palette: "golden_warmth", genre: "fashion", tempo: "calm", moves: [SuiteRigMove(id: "dolly_in", intensity: 0.4)]),
                     userId: "u1", mine: true, createdAt: 1_762_300_000_000, updatedAt: 1_762_500_000_000),
        SuiteRigView(id: "rig_demo_talking", name: "Talking head",
                     rig: SuiteRig(body: "phone", height: "eye", shotSize: "mcu", lighting: "ring_light", palette: "commercial_clean", genre: "ugc", format: "review"),
                     userId: "u1", mine: true, createdAt: 1_762_300_060_000, updatedAt: 1_762_400_000_000),
        SuiteRigView(id: "rig_demo_neon", name: "Neon night",
                     rig: SuiteRig(body: "cinema_digital", lighting: "neon", palette: "hyper_neon", era: "1980s", tempo: "dynamic",
                                   moves: [SuiteRigMove(id: "orbit_left")]),
                     userId: "u_maya", mine: false, createdAt: 1_762_300_120_000, updatedAt: 1_762_450_000_000),
    ]

    /// The seeded takes and photos with no job are all of the demo model.
    static let demoTakeModels: [String: String] = ["t_g1": SampleData.demo, "t_g4": SampleData.demo, "t_g5": SampleData.demo, "t_g6": SampleData.demo,
                                                   "t_g7": SampleData.demo]

    // MARK: Drafts

    /// The server's `draftOf`: a bad draft is refused ("Invalid draft: …") rather than dropped.
    func suiteCheckDraft(_ d: SuiteDraft?) throws {
        if let p = d?.problem { throw ApiError("bad_request", "Invalid draft: \(p)") }
    }

    /// A swap made through the job pipeline keeps its draft (and the shot's aspect) like a suite shot.
    func keepSuiteDraft(_ d: SuiteDraft?, aspect: String, on job: Job) -> Job {
        suiteJobAspects[job.id] = aspect
        var out = jobs.first { $0.id == job.id } ?? job
        out.draft = d
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].draft = d }
        return out
    }

    // MARK: Saved rigs

    private func rigView(_ r: SuiteRigView) -> SuiteRigView {
        var v = r
        v.mine = r.userId == suiteUserId
        return v
    }

    private func checkRig(_ rig: SuiteRig, field: String = "rig") throws {
        if let p = rig.problem(in: SuiteDemoCatalog.catalog.camera, field: field) { throw ApiError("bad_request", p) }
    }

    /// A rig this person may change: their own, or any for the owner. Anyone else's reads as not found.
    private func editableRig(_ id: String) throws -> Int {
        guard let i = suiteRigList.firstIndex(where: { $0.id == id }), suiteIsOwner || suiteRigList[i].userId == suiteUserId else {
            throw ApiError("not_found", "Rig not found")
        }
        return i
    }

    public func suiteRigs() async throws -> [SuiteRigView] {
        let me = suiteUserId
        let list = suiteRigList.filter { suiteIsOwner || $0.userId == me }.map { rigView($0) }
        // Last changed first; the owner's own before everyone else's.
        return list.sorted { a, b in
            if a.mine != b.mine { return a.mine }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id < b.id
        }
    }

    public func createSuiteRig(name: String, rig: SuiteRig) async throws -> SuiteRigView {
        let clean = try SuiteRigView.cleanName(name).get()
        try checkRig(rig)
        let me = suiteUserId
        if suiteRigList.filter({ $0.userId == me }).count >= SuiteRigView.maxPerUser {
            throw ApiError("too_many_rigs", "You can keep \(SuiteRigView.maxPerUser) rigs · delete one first")
        }
        let now = nowMs()
        let r = SuiteRigView(id: "rig_" + shortId(), name: clean, rig: rig, userId: me, mine: true, createdAt: now, updatedAt: now)
        suiteRigList.append(r)
        return r
    }

    public func updateSuiteRig(id: String, name: String?, rig: SuiteRig?) async throws -> SuiteRigView {
        let clean = try name.map { try SuiteRigView.cleanName($0).get() }
        if let r = rig { try checkRig(r) }
        let i = try editableRig(id)
        if clean == nil && rig == nil { return rigView(suiteRigList[i]) }
        if let n = clean { suiteRigList[i].name = n }
        if let r = rig { suiteRigList[i].rig = r }
        suiteRigList[i].updatedAt = max(nowMs(), suiteRigList[i].updatedAt)
        return rigView(suiteRigList[i])
    }

    public func deleteSuiteRig(id: String) async throws {
        let i = try editableRig(id)
        suiteRigList.remove(at: i)
    }

    // MARK: A model's default rig

    /// Anyone in the studio may set it, like her other fields. nil or an all-Auto rig clears it.
    public func setModelDefaultRig(modelId: String, rig: SuiteRig?) async throws -> MuseModel {
        if let r = rig { try checkRig(r, field: "defaultRig") }
        var m = try model(modelId)
        m.defaultRig = rig.flatMap { $0.isEmpty ? nil : $0 }
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
        return m
    }

    // MARK: The takes feed

    /// The tool a job was made with: its draft's, else from the request (upscale; a suite shot's mode; the video studio's swap).
    func suiteFeedTool(_ j: Job) -> String {
        if let t = j.draft?.tool, !t.isEmpty { return t }
        if j.request.isUpscale { return "upscale" }
        if j.request.engine == "suite" {
            if j.engineText?.hasPrefix("Extend") == true { return "extend" }
            if j.engineText?.hasPrefix("Recast") == true { return "recast" }
            return "shot"
        }
        return "swap"
    }

    /// A take's tool: its own draft's, a still is a photo, else its job's (no job: the video studio's swap).
    func suiteFeedTool(_ t: Take, job: Job?) -> String {
        if let d = t.draft?.tool, !d.isEmpty { return d }
        if t.kind == "shot" { return "photo" }
        return job.map { suiteFeedTool($0) } ?? "swap"
    }

    private func modelName(_ id: String?) -> String? {
        guard let id = id, !id.isEmpty else { return nil }
        return models.first { $0.id == id }?.name
    }

    private func feedItem(_ j: Job) -> SuiteFeedItem {
        let seconds = j.request.clipSeconds.flatMap { $0 > 0 ? $0 : nil }
        let aspect = j.draft?.aspect ?? suiteJobAspects[j.id]
        let takes = max(1, j.request.takes)
        var it = SuiteFeedItem(id: j.id, kind: "job", status: j.state, tool: suiteFeedTool(j), jobId: j.id, title: j.title,
                               modelId: j.modelId.isEmpty ? nil : j.modelId, modelName: j.modelName.isEmpty ? nil : j.modelName, createdAt: j.createdAt,
                               poster: j.thumb, aspect: aspect, durationSec: seconds, price: j.cost,
                               summary: SuiteFeedText.summary(j.draft, aspect: aspect, seconds: seconds, takes: takes))
        it.takes = takes
        it.progress = j.progress
        it.phase = j.phase.isEmpty ? nil : j.phase
        it.secondsLeft = j.isRunning ? j.secondsLeft : nil
        it.blocked = j.blocked
        if j.isFailed {
            it.error = j.error ?? "It didn’t finish"
            it.errorCode = j.errorCode
        }
        it.refunded = j.refunded > 0 ? j.refunded : nil
        it.label = j.engineText
        return it
    }

    private func feedItem(_ t: Take, job: Job?) -> SuiteFeedItem {
        let photo = t.kind == "shot"
        let draft = t.draft ?? job?.draft
        let aspect = SuiteFeedText.aspect(width: t.width.map { Double($0) }, height: t.height.map { Double($0) }) ?? draft?.aspect
            ?? job.flatMap { suiteJobAspects[$0.id] } ?? (photo ? "9:16" : nil)
        let seconds = photo ? nil : (t.durationSec ?? job?.request.clipSeconds).flatMap { $0 > 0 ? $0 : nil }
        let modelId = suiteTakeModels[t.id] ?? job.flatMap { $0.modelId.isEmpty ? nil : $0.modelId }
        let summary = photo
            ? SuiteFeedText.summary(draft, aspect: aspect, count: t.of)
            : SuiteFeedText.summary(draft, aspect: aspect, seconds: job?.request.clipSeconds.flatMap { $0 > 0 ? $0 : nil } ?? seconds,
                                    takes: job.map { max(1, $0.request.takes) } ?? t.of)
        var it = SuiteFeedItem(id: t.id, kind: photo ? "photo" : "take", status: "done", tool: suiteFeedTool(t, job: job), jobId: t.jobId, title: t.title,
                               modelId: modelId, modelName: modelName(modelId), createdAt: t.createdAt, poster: t.thumb, aspect: aspect, durationSec: seconds,
                               price: t.cost, summary: summary, isFinal: t.isFinal)
        it.takeId = t.id
        it.label = t.label
        it.videoUrl = photo ? nil : t.videoUrl
        it.index = t.index
        it.of = t.of
        return it
    }

    public func suiteFeed(_ q: SuiteFeedQuery) async throws -> SuiteFeedPage {
        let tools = q.tool.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let statuses = q.status.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let bad = tools.first(where: { !SuiteDraft.tools.contains($0) }) {
            throw ApiError("bad_request", "Invalid feed query: tool unknown value \"\(bad)\" (one of \(SuiteDraft.tools.joined(separator: ", ")))")
        }
        if let bad = statuses.first(where: { !SuiteFeedQuery.statuses.contains($0) }) {
            throw ApiError("bad_request", "Invalid feed query: status unknown value \"\(bad)\" (one of \(SuiteFeedQuery.statuses.joined(separator: ", ")))")
        }
        let limit = q.limit ?? SuiteFeedQuery.defaultLimit
        guard (1...SuiteFeedQuery.maxLimit).contains(limit) else {
            throw ApiError("bad_request", "Invalid feed query: limit 1–\(SuiteFeedQuery.maxLimit)")
        }
        var cursor: (Int64, String)?
        if let c = q.cursor, !c.isEmpty {
            guard let v = SuiteFeedCursor.decode(c) else { throw ApiError("bad_request", "Invalid cursor") }
            cursor = v
        }
        let model = q.model.flatMap { $0.isEmpty ? nil : $0 }
        let wantPending = ["queued", "running", "failed"].filter { statuses.isEmpty || statuses.contains($0) }
        let wantDone = statuses.isEmpty || statuses.contains("done")
        func older(_ at: Int64, _ id: String) -> Bool {
            guard let c = cursor else { return true }
            return at < c.0 || (at == c.0 && id < c.1)
        }

        var items: [SuiteFeedItem] = []
        for j in jobs where wantPending.contains(j.state) {
            if let m = model, j.modelId != m { continue }
            if !tools.isEmpty && !tools.contains(suiteFeedTool(j)) { continue }
            if !older(j.createdAt, j.id) { continue }
            items.append(feedItem(j))
        }
        if wantDone {
            for t in takes where t.kind == "take" || t.kind == "shot" {
                if let jid = t.jobId, suiteHiddenJobs.contains(jid) { continue }
                let job = t.jobId.flatMap { id in jobs.first { $0.id == id } }
                if let m = model, (suiteTakeModels[t.id] ?? job?.modelId) != m { continue }
                if !tools.isEmpty && !tools.contains(suiteFeedTool(t, job: job)) { continue }
                if !older(t.createdAt, t.id) { continue }
                items.append(feedItem(t, job: job))
            }
        }
        items.sort { a, b in a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id }
        let page = Array(items.prefix(limit))
        let next = items.count > limit ? page.last.map { SuiteFeedCursor.encode($0.createdAt, $0.id) } : nil
        return SuiteFeedPage(items: page, nextCursor: next)
    }
}
