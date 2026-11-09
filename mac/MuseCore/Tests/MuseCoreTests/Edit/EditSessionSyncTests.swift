import XCTest
@testable import MuseCore

/// Edit sessions shared with Claude, against the in-memory fake (the server's rules): pushes, 409 rebase, remote changes,
/// Claude's badged changes and their undo, paid helpers waiting for the owner, frame and save/export requests.
@MainActor
final class EditSessionSyncTests: XCTestCase {
    typealias E = EditV2

    private func fixture(_ name: String = "pip text image look") throws -> E.Project {
        let c = try XCTUnwrap(editorFixture("projects").array.first { $0["name"].string == name }, name)
        return try c["project"].decode(E.Project.self)
    }

    private func open(_ api: FakeMuseAPI, device: String = "mac-test") async throws -> EditSessionSync {
        let p = try fixture()
        return try await EditSessionSync.open(api: api, takeId: p.sourceTakeId, project: p, device: device)
    }

    private func withText(_ p: E.Project, _ id: String, _ text: String) throws -> E.Project {
        try XCTUnwrap(p.updating(id) { it in if case .text(var t) = it { t.text = text; it = .text(t) } })
    }

    private func withLook(_ p: E.Project, _ lut: String) throws -> E.Project {
        try XCTUnwrap(p.updating("c1") { it in if case .video(var c) = it { c.look = E.Look(lut: lut, strength: 0.7); it = .video(c) } })
    }

    private func nextEdit(_ it: inout AsyncStream<ApiEvent>.Iterator) async -> EditSessionEvent? {
        while let e = await it.next() { if let x = e.edit { return x } }
        return nil
    }

    private func serverProject(_ api: FakeMuseAPI, _ id: String) async throws -> E.Project {
        let r = await api.fakeEditRecord(id)
        return try JSONPatch.decode(E.Project.self, try XCTUnwrap(r).project)
    }

    func testOpenIsOnePerTakeAndPushesALabelledChange() async throws {
        let api = FakeMuseAPI(speed: 0)
        let sync = try await open(api)
        XCTAssertEqual(sync.revision, 0)
        let again = try await open(api, device: "phone")
        XCTAssertEqual(again.sessionId, sync.sessionId)

        let next = try withLook(sync.current, "pack:film-gold")
        sync.localChanged(next)
        XCTAssertEqual(sync.localLabel, "Look")
        XCTAssertTrue(sync.hasUnsent)
        let shown = try await sync.flush()
        XCTAssertNil(shown, "nothing else to show after a clean push")
        XCTAssertEqual(sync.revision, 1)
        XCTAssertFalse(sync.hasUnsent)
        XCTAssertEqual(sync.synced, next)
        XCTAssertEqual(sync.history.first?.label, "Look")
        XCTAssertEqual(sync.history.first?.author, "app:mac-test")
        XCTAssertEqual(sync.history.first?.byClaude, false)
        let server = try await serverProject(api, sync.sessionId)
        XCTAssertEqual(server, next)
        // Back to the server's state: nothing to send.
        sync.localChanged(next)
        XCTAssertFalse(sync.hasUnsent)
    }

    func testStaleRevisionRebasesTheLocalChangeOnTop() async throws {
        let api = FakeMuseAPI(speed: 0)
        let sync = try await open(api)
        let base = sync.current
        // Claude changes the background while the Mac edits a text.
        try await api.fakeClaudePatch(sessionId: sync.sessionId, [.replace("/canvas/background", .string("#111111"))], label: "Background")
        let mine = try withText(base, "t1", "Mine")
        sync.localChanged(mine, label: "Text")
        let shown = try await sync.flush()
        guard case .project(let p, _)? = shown else { return XCTFail("expected the rebased project, got \(String(describing: shown))") }
        XCTAssertEqual(p.canvas.background, "#111111")
        XCTAssertEqual(p.tracks.flatMap(\.items).compactMap(\.textItem).first { $0.id == "t1" }?.text, "Mine")
        XCTAssertEqual(sync.revision, 2)
        XCTAssertFalse(sync.hasUnsent)
        let server = try await serverProject(api, sync.sessionId)
        XCTAssertEqual(server, p)
    }

    func testStaleRevisionKeepsTheServersWhenTheChangeNoLongerFits() async throws {
        let api = FakeMuseAPI(speed: 0)
        let sync = try await open(api)
        let base = sync.current
        let ti = try XCTUnwrap(base.tracks.firstIndex { $0.kind == .text })
        // Claude removes t2; the Mac edits t2.
        var fewer = base
        fewer.tracks[ti].items.removeAll { $0.id == "t2" }
        try await api.fakeClaudePatch(sessionId: sync.sessionId, JSONPatch.diff(try JSONPatch.encode(base), try JSONPatch.encode(fewer)), label: "Removed text")
        sync.localChanged(try withText(base, "t2", "Gone"), label: "Text")
        let shown = try await sync.flush()
        XCTAssertEqual(shown, .project(fewer, entry: nil))
        XCTAssertFalse(sync.hasUnsent)
        XCTAssertEqual(sync.revision, 1)
    }

    func testRemoteClaudeChangeAppliesLiveAndUndoGoesToTheServer() async throws {
        let api = FakeMuseAPI(speed: 0)
        var events = api.events().makeAsyncIterator()
        let sync = try await open(api)
        let before = sync.current
        let look = try withLook(before, "pack:film-gold")
        let patch = JSONPatch.diff(try JSONPatch.encode(before), try JSONPatch.encode(look))
        try await api.fakeClaudePatch(sessionId: sync.sessionId, patch, label: "Look · film-gold 70 %")
        let maybe = await nextEdit(&events)
        let ev = try XCTUnwrap(maybe)
        XCTAssertEqual(ev.op, "patch")
        let u = await sync.handle(ev)
        guard case .project(let p, let entry)? = u else { return XCTFail("expected a project") }
        XCTAssertEqual(p, look)
        XCTAssertEqual(entry?.byClaude, true)
        XCTAssertEqual(entry?.label, "Look · film-gold 70 %")
        XCTAssertEqual(sync.revision, 1)
        XCTAssertEqual(sync.claudeEntries.count, 1)
        // The same event again changes nothing.
        let again = await sync.handle(ev)
        XCTAssertNil(again)

        // Undo Claude's entry: the server applies the inverse as a new change.
        let entryId = try XCTUnwrap(entry?.id)
        let undone = try await sync.undo(entryId: entryId)
        guard case .project(let back, let ue)? = undone else { return XCTFail("expected the project after undo") }
        XCTAssertEqual(back, before)
        XCTAssertEqual(ue?.label, "Undo: Look · film-gold 70 %")
        XCTAssertEqual(sync.revision, 2)
        XCTAssertTrue(sync.history.first { $0.id == entry?.id }?.undone == true)
        do { _ = try await sync.undo(entryId: entryId); XCTFail("undo twice") } catch let e as ApiError { XCTAssertEqual(e.code, "already_undone") }
        // Its own echo (the undo's patch event) is old news.
        let echoEvent = await nextEdit(&events)
        let echo = try XCTUnwrap(echoEvent)
        let none = await sync.handle(echo)
        XCTAssertNil(none)
    }

    func testAMissedRevisionRefetchesAndKeepsTheLocalChange() async throws {
        let api = FakeMuseAPI(speed: 0)
        var events = api.events().makeAsyncIterator()
        let sync = try await open(api)
        try await api.fakeClaudePatch(sessionId: sync.sessionId, [.replace("/canvas/background", .string("#222222"))], label: "A")
        try await api.fakeClaudePatch(sessionId: sync.sessionId, [.replace("/canvas/background", .string("#333333"))], label: "B")
        _ = await nextEdit(&events)
        let secondEvent = await nextEdit(&events)
        let second = try XCTUnwrap(secondEvent)
        sync.localChanged(try withText(sync.current, "t1", "Local"))
        let u = await sync.handle(second)
        guard case .project(let p, let entry)? = u else { return XCTFail("expected a project") }
        XCTAssertEqual(sync.revision, 2)
        XCTAssertEqual(p.canvas.background, "#333333")
        XCTAssertEqual(p.tracks.flatMap(\.items).compactMap(\.textItem).first { $0.id == "t1" }?.text, "Local")
        XCTAssertEqual(entry?.label, "B")
        XCTAssertTrue(sync.hasUnsent)
        try await sync.flush()
        XCTAssertEqual(sync.revision, 3)
    }

    func testPaidHelperWaitsForTheOwnersAnswer() async throws {
        let api = FakeMuseAPI(speed: 0)
        var events = api.events().makeAsyncIterator()
        let sync = try await open(api)
        let p = try await api.fakeClaudePending(sessionId: sync.sessionId, kind: "matte", label: "Remove background", estimateUsd: 0.4)
        let pev = await nextEdit(&events)
        let ev = try XCTUnwrap(pev)
        let u = await sync.handle(ev)
        XCTAssertEqual(u, .pending(p))
        XCTAssertEqual(sync.waiting.map(\.id), [p.id])
        XCTAssertEqual(p.prompt, "Claude wants to run Remove background · about $0.40")
        // The note in the history ("Asked the owner: …").
        let lev = await nextEdit(&events)
        let log = try XCTUnwrap(lev)
        let lu = await sync.handle(log)
        if case .history(let e)? = lu { XCTAssertTrue(e.byClaude); XCTAssertEqual(e.kind, "tool") } else { XCTFail("expected a note") }
        let answered = try await sync.answer(pendingId: p.id, approve: true)
        XCTAssertEqual(answered.status, "running")
        XCTAssertTrue(sync.waiting.isEmpty)
        let rec = await api.fakeEditRecord(sync.sessionId)
        XCTAssertEqual(rec?.pending.first?.status, "running")
        let second = try await api.fakeClaudePending(sessionId: sync.sessionId, kind: "denoise", label: "Noise reduction", estimateUsd: 0.1)
        let declined = try await sync.answer(pendingId: second.id, approve: false)
        XCTAssertEqual(declined.status, "declined")
    }

    func testFrameAndSaveRequestsGoToTheMac() async throws {
        let api = FakeMuseAPI(speed: 0)
        var events = api.events().makeAsyncIterator()
        let sync = try await open(api)
        // Nobody online: nothing to ask.
        let nobody = try await api.fakeFrameRequest(sessionId: sync.sessionId, t: 1)
        XCTAssertNil(nobody)
        let phone = try await open(api, device: "phone-1")
        try await phone.announce(label: "Pixel", platform: "android")
        try await sync.announce(label: "Studio Mac")
        let ridOpt = try await api.fakeFrameRequest(sessionId: sync.sessionId, t: 2.5, width: 320)
        let rid = try XCTUnwrap(ridOpt)
        let fev = await nextEdit(&events)
        let ev = try XCTUnwrap(fev)
        let fu = await sync.handle(ev)
        XCTAssertEqual(fu, .frameRequest(requestId: rid, t: 2.5, width: 320))
        let notMine = await phone.handle(ev)
        XCTAssertNil(notMine, "the Mac renders first")
        let up = try await api.uploadEditFrame(png: Data([0x89, 0x50, 0x4E, 0x47]))
        try await api.answerEditFrame(sessionId: sync.sessionId, requestId: rid, uploadId: up)
        let rec = await api.fakeEditRecord(sync.sessionId)
        XCTAssertEqual(rec?.frameAnswers[rid], up)

        let reqOpt = try await api.fakeAppRequest(sessionId: sync.sessionId, kind: "export",
                                                  preset: ["resolution": .string("1080p"), "aiLabel": .bool(true), "c2pa": .bool(true)])
        let req = try XCTUnwrap(reqOpt)
        XCTAssertEqual(req.preset, ["resolution": .string("1080p")])
        let aevOpt = await nextEdit(&events)
        let aev = try XCTUnwrap(aevOpt)
        let au = await sync.handle(aev)
        XCTAssertEqual(au, .appRequest(req))
        try await api.answerEditAppRequest(sessionId: sync.sessionId, requestId: req.id, .done(versionId: "tk_v2"))
        let rec2 = await api.fakeEditRecord(sync.sessionId)
        XCTAssertEqual(rec2?.requestAnswers[req.id]?.versionId, "tk_v2")
        await sync.leave()
        await phone.leave()
        let gone = try await api.fakeFrameRequest(sessionId: sync.sessionId, t: 1)
        XCTAssertNil(gone)
    }

    func testMembersCannotOpenSessions() async throws {
        let api = FakeMuseAPI(speed: 0)
        _ = try await api.signIn(SignInRequest(email: "m@studio.com", password: "x"))
        await api.setRole("member")
        do { _ = try await open(api); XCTFail("members are refused") } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
    }

    func testEditEventsDecodeFromTheStream() async throws {
        let json = #"{"type":"edit","sessionId":"es_1","op":"patch","revision":4,"baseRevision":3,"patch":[{"op":"replace","path":"/canvas/background","value":null}],"entry":{"id":12,"revision":4,"author":"claude","byClaude":true,"kind":"edit","label":"Look · film-gold 70 %","undone":false,"createdAt":1}}"#
        let e = try JSONDecoder().decode(ApiEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.type, "edit")
        let x = try XCTUnwrap(e.edit)
        XCTAssertEqual(x.revision, 4)
        XCTAssertEqual(x.patch, [.replace("/canvas/background", .null)])
        XCTAssertEqual(x.entry?.byClaude, true)
        let fr = try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"edit","sessionId":"es_1","op":"frame_request","requestId":"fr_1","t":1.5,"width":540,"revision":4,"device":"mac-1"}"#.utf8))
        XCTAssertEqual(fr.edit?.requestId, "fr_1")
        XCTAssertNil(try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"job"}"#.utf8)).edit)
    }

    func testLabelsAndTakeLook() async throws {
        let p = try fixture()
        XCTAssertEqual(EditSessionSync.label(from: p, to: try withLook(p, "pack:film-gold")), "Look")
        XCTAssertEqual(EditSessionSync.label(from: p, to: try withText(p, "t1", "x")), "Text")
        var st = EditSuiteState(p)
        st.playhead = 2
        XCTAssertTrue(st.split())
        XCTAssertEqual(EditSessionSync.label(from: p, to: st.project), "Split")

        // A take graded with a suite look starts with it on the main clip; a take without one is unchanged.
        let fresh = E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: 6), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true))
        var take = Take(id: "tk", kind: "take", title: "Café", label: "HD", status: "test", thumb: ImageRef(asset: "g_front"), createdAt: 1)
        XCTAssertEqual(E.withTakeLook(fresh, take: take), fresh)
        take.look = SuiteLook(id: "film-gold", label: "Film gold", lut: "palette:film-gold")
        let graded = E.withTakeLook(fresh, take: take)
        XCTAssertEqual(graded.mainClips.first?.look, E.Look(lut: "palette:film-gold", strength: 1))
        // Reversible like any look.
        var s = EditSuiteState(fresh)
        s.paletteIds = ["film-gold"]   // the app's shipped suite looks (the validity guard refuses unknown ones)
        s.apply { _ in graded }
        XCTAssertTrue(s.undo())
        XCTAssertNil(s.project.mainClips.first?.look)
    }

    func testExportPresetNeverTouchesDisclosureAndFrameSize() async throws {
        var base = EditSuite.ExportSettings()
        base.labelAI = true
        let s = base.applying(preset: ["ratio": .string("1:1"), "resolution": .string("4k"), "fps": .number(60), "codec": .string("hevc"),
                                       "captions": .string("srt"), "aiLabel": .bool(false), "c2pa": .bool(true)])
        XCTAssertEqual(s.ratio, .square)
        XCTAssertEqual(s.resolution, .k4)
        XCTAssertEqual(s.fps, 60)
        XCTAssertEqual(s.codec, .hevc)
        XCTAssertEqual(s.captions, .srt)
        XCTAssertTrue(s.labelAI)
        XCTAssertFalse(s.c2pa)
        XCTAssertEqual(base.applying(preset: ["fps": .number(25), "resolution": .string("8k")]), base)
        let size = editFrameSize(canvas: E.Canvas(width: 1080, height: 1920, fps: 30), width: 540)
        XCTAssertEqual(size.width, 540)
        XCTAssertEqual(size.height, 960)
        let e = EditHistoryEntry(id: 3, revision: 2, author: "claude", label: "Look · film-gold 70 %")
        XCTAssertEqual(e.claudeToast, "Claude · Look · film-gold 70 %")
        XCTAssertEqual(e.who(thisDevice: "mac-1"), "Claude")
        XCTAssertEqual(EditHistoryEntry(id: 4, revision: 3, author: "app:mac-1", label: "Trim").who(thisDevice: "mac-1"), "This Mac")
    }

    func testLocalUndoOnlyUndoesThisDevicesEdits() async throws {
        let base = try fixture()
        var s = EditSuiteState(base)
        let mine = try withText(base, "t1", "Mine")
        XCTAssertTrue(s.apply { _ in mine })
        // Claude changes the background (a remote patch): not an undo step here.
        var remote = mine
        remote.canvas.background = "#111111"
        XCTAssertTrue(s.applyRemote(remote))
        XCTAssertTrue(s.canUndo)
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.project.canvas.background, "#111111", "undo keeps Claude's change")
        XCTAssertEqual(s.project.tracks.flatMap(\.items).compactMap(\.textItem).first { $0.id == "t1" }?.text,
                       base.tracks.flatMap(\.items).compactMap(\.textItem).first { $0.id == "t1" }?.text)
        XCTAssertFalse(s.canUndo, "nothing of this Mac's left to undo")
        XCTAssertTrue(s.redo())
        XCTAssertEqual(s.project, remote)

        // A local step the remote change no longer fits is dropped (and so is everything older).
        let edited = try withText(base, "t2", "Edited")
        var t = EditSuiteState(base)
        XCTAssertTrue(t.apply { _ in edited })
        let ti = try XCTUnwrap(base.tracks.firstIndex { $0.kind == .text })
        var removed = t.project
        removed.tracks[ti].items.removeAll { $0.id == "t2" }
        XCTAssertTrue(t.applyRemote(removed))
        XCTAssertFalse(t.canUndo, "undoing would bring back t2's old text into a track that no longer has it")
        XCTAssertEqual(t.project, removed)
    }

    func testVersionNameIsTrimmedAndSent() async throws {
        XCTAssertNil(TakeVersionV2Request.versionName("   "))
        XCTAssertNil(TakeVersionV2Request.versionName(nil))
        XCTAssertEqual(TakeVersionV2Request.versionName("  Cut v2 "), "Cut v2")
        XCTAssertEqual(TakeVersionV2Request.versionName(String(repeating: "a", count: 100))?.count, 80)
        let r = TakeVersionV2Request(uploadId: "up_1", edits: try fixture(), durationSec: 8, width: 1080, height: 1920, name: " Cut v2 ")
        guard case .object(let o) = try JSONPatch.encode(r) else { return XCTFail("an object") }
        XCTAssertEqual(o["name"], .string("Cut v2"))
        let unnamed = TakeVersionV2Request(uploadId: "up_1", edits: try fixture(), durationSec: 8, width: 1, height: 1)
        guard case .object(let o2) = try JSONPatch.encode(unnamed) else { return XCTFail("an object") }
        XCTAssertNil(o2["name"])
        let take = try JSONDecoder().decode(Take.self, from: Data(#"{"id":"tk_1","kind":"edit","name":"Cut v2"}"#.utf8))
        XCTAssertEqual(take.name, "Cut v2")
    }

    func testDraftKeptOnThisDeviceIsAskedAboutAndKeptOnTop() async throws {
        let api = FakeMuseAPI(speed: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EditSessionDrafts(directory: dir)
        // This Mac edits, but the change never reaches the server (closed while offline).
        let first = try await open(api)
        let mine = try withText(first.current, "t1", "Mine")
        first.localChanged(mine, label: "Text")
        store.save(first.draft, takeId: first.takeId)
        let saved = try XCTUnwrap(store.load(takeId: first.takeId))
        XCTAssertEqual(saved.project, mine)
        XCTAssertEqual(saved.baseRevision, 0)
        // Meanwhile Claude changed the edit.
        try await api.fakeClaudePatch(sessionId: first.sessionId, [.replace("/canvas/background", .string("#111111"))], label: "Background")

        // Reopening: the draft differs from the latest, so the owner is asked; Keep puts it on top.
        let again = try await open(api)
        XCTAssertTrue(again.conflicts(with: saved))
        let u = try await again.keep(saved)
        guard case .project(let p, _) = u else { return XCTFail("expected a project") }
        XCTAssertEqual(p.canvas.background, "#111111")
        XCTAssertEqual(p.tracks.flatMap(\.items).compactMap(\.textItem).first { $0.id == "t1" }?.text, "Mine")
        XCTAssertEqual(again.revision, 2)
        XCTAssertNil(again.draft, "sent: nothing left to keep")
        store.save(again.draft, takeId: again.takeId)
        XCTAssertNil(store.load(takeId: again.takeId))
        XCTAssertEqual(again.history.first?.label, "Text")
        XCTAssertFalse(again.conflicts(with: EditSessionDraft(takeId: again.takeId, sessionId: again.sessionId, baseRevision: 2, project: again.synced)))

        // "Use the latest": the draft is discarded and the session is unchanged.
        let other = try withText(again.current, "t2", "Other")
        store.save(EditSessionDraft(takeId: again.takeId, sessionId: again.sessionId, baseRevision: 1, project: other), takeId: again.takeId)
        XCTAssertTrue(again.conflicts(with: store.load(takeId: again.takeId)))
        store.remove(takeId: again.takeId)
        XCTAssertNil(store.load(takeId: again.takeId))
        XCTAssertEqual(again.revision, 2)
    }
}
