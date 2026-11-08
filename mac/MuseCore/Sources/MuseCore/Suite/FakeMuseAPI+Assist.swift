import Foundation

// Demo mode's Suite assist (same rules and wording as the server): the shared draft, its revision, `409 stale` on a PATCH
// that is behind, and Claude's paid asks, which run only on the owner's approve. `demoClaudeAssist` stands in for Claude's
// MCP tools (suite_set_draft, suite_request_shot with confirm).
extension FakeMuseAPI: SuiteAssistAPI {
    private func assistOwnerOnly() throws {
        guard suiteIsOwner else { throw ApiError("owner_only", "Claude in the Suite is for the studio owner") }
    }

    private func storedAssist(_ id: String) throws -> SuiteAssist {
        guard let a = suiteAssists[id] else { throw ApiError("not_found", "Draft not found") }
        return a
    }

    /// What Generate would send for this draft.
    private func assistRequest(_ d: SuiteDraft) -> ShotRequest {
        let c = ComposerDrafts.restore(d, into: ComposerDraft())
        var r = composerRequest(c.tokens, c.settings, quality: c.quality, aspectRatio: c.aspect, duration: c.duration, takes: c.takes,
                                speaking: c.speaking.value, title: c.title)
        r.audio = c.sound
        if r.modelId != nil, r.outfitId == nil { r.outfitId = c.outfitId }
        r.draft = d
        return r
    }

    private func savedAssist(_ a: SuiteAssist, draft: SuiteDraft?) -> SuiteAssist {
        var n = a
        if let d = draft {
            n.draft = d
            let r = assistRequest(d)
            n.request = r
            n.warnings = FakeRigCheck.check(prompt: r.prompt, camera: r.camera, speaking: r.speaking ?? false)
        }
        n.revision += 1
        n.updatedAt = max(nowMs(), a.updatedAt + 1)
        suiteAssists[n.id] = n
        emitAssist(n)
        return n
    }

    /// The live `suiteAssist` event, as the server sends it on every change.
    private func emitAssist(_ a: SuiteAssist) {
        var e = ApiEvent(type: "suiteAssist")
        e.assist = a
        hub.emit(e)
    }

    public func createSuiteAssist(_ body: SuiteAssistCreate) async throws -> SuiteAssist {
        try assistOwnerOnly()
        var d = body.draft
        if d == nil, let j = body.fromJobId {
            guard let job = jobs.first(where: { $0.id == j }) else { throw ApiError("not_found", "Job not found") }
            d = job.draft
        }
        if let p = d?.problem { throw ApiError("bad_request", "Invalid draft: \(p)") }
        let draft = d ?? SuiteDraft(tool: "shot", quality: "draft", aspect: "9:16", duration: 8, takes: 1, sound: true)
        return savedAssist(SuiteAssist(id: "sa_" + shortId(), draft: draft, revision: 0, updatedAt: nowMs()), draft: draft)
    }

    public func suiteAssist(id: String) async throws -> SuiteAssist {
        try assistOwnerOnly()
        return try storedAssist(id)
    }

    public func patchSuiteAssist(id: String, _ body: SuiteAssistPatch) async throws -> SuiteAssist {
        try assistOwnerOnly()
        let a = try storedAssist(id)
        if let b = body.baseRevision, b != a.revision { throw ApiError("stale", "The draft changed since revision \(b). Read it again.") }
        if let p = body.draft.problem { throw ApiError("bad_request", "Invalid draft: \(p)") }
        return savedAssist(a, draft: body.draft)
    }

    public func answerSuitePending(assistId: String, pendingId: String, approve: Bool) async throws -> SuitePending {
        try assistOwnerOnly()
        var a = try storedAssist(assistId)
        guard let i = a.pending.firstIndex(where: { $0.id == pendingId }), a.pending[i].isWaiting else {
            throw ApiError("not_found", "Waiting request not found")
        }
        if approve {
            guard let req = a.request else { throw ApiError("bad_request", "Nothing to generate") }
            let now = try await suiteEstimate(req).estimate
            // Never above the price the owner saw (maxUsd), as on the server.
            if now > a.pending[i].maxUsd + 0.005 {
                throw ApiError("price_changed", "This shot now costs about \(Pricing.money(now)) · ask Claude to price it again")
            }
            do {
                let job = try await suiteCreateShot(req)
                a = try storedAssist(assistId)
                a.pending[i].status = "done"
                a.pending[i].jobId = job.id
            } catch {
                a = try storedAssist(assistId)
                a.pending[i].status = "failed"
                a.pending[i].error = (error as? ApiError)?.message ?? "Couldn’t start the shot"
                a.revision += 1
                suiteAssists[a.id] = a
                emitAssist(a)
                throw error
            }
        } else {
            a.pending[i].status = "declined"
        }
        a.revision += 1
        a.updatedAt = max(nowMs(), a.updatedAt + 1)
        suiteAssists[a.id] = a
        emitAssist(a)
        return a.pending[i]
    }

    /// Demo mode only: Claude sets the draft (suite_set_draft) and/or asks to generate it (suite_request_shot with confirm),
    /// which adds a waiting ask priced like the shot. Nothing is held.
    public func demoClaudeAssist(id: String, draft: SuiteDraft?, generate: Bool) async throws -> SuiteAssist {
        try assistOwnerOnly()
        var a = savedAssist(try storedAssist(id), draft: draft)
        if generate {
            guard let req = a.request else { throw ApiError("bad_request", "Nothing to generate") }
            let e = try await suiteEstimate(req)
            if let p = e.problem { throw ApiError(e.code ?? "bad_request", p) }
            a = try storedAssist(id)
            for k in a.pending.indices where a.pending[k].isWaiting { a.pending[k].status = "declined" }
            let title = req.title.flatMap { $0.isEmpty ? nil : $0 } ?? "this shot"
            a.pending.append(SuitePending(id: "sp_" + shortId(), label: "Generate \(title) · \(Pricing.money(e.estimate))", estimateUsd: e.estimate,
                                          maxUsd: e.estimate, createdAt: nowMs()))
            a.revision += 1
            suiteAssists[a.id] = a
            emitAssist(a)
        }
        return a
    }
}
