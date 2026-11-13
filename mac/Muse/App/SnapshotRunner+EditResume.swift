import AppKit
import MuseCore

/// Continue a draft check (Mac CI, owner 2026-11-12: "When you click on Edit, you should see the last draft you were
/// editing"; owner decision the same day: Edit opens on a choice, "New" or "Continue draft"). In review mode only, through
/// the real Edit page: a take is opened, the editor is moved (playhead, zoom, inspector tab, Uploads bin, platform view off)
/// and left; clicking Edit again must show the choice (no editor opens by itself) with that edit as the draft, and Continue
/// draft must reopen it exactly there. Then an edit whose take was deleted must open anyway with its clips marked missing,
/// and New must start a blank project. Writes `edit-resume-check.txt`; CI fails on any FAIL line or a missing ALL DONE.
extension SnapshotRunner {
    static func editResumeCheck(_ store: AppStore, dir: URL) async {
        let log = dir.appendingPathComponent("edit-resume-check.txt")
        try? Data().write(to: log)
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("edit-resume-check: \(s)")
        }
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            note(ok ? "DONE \(name)" : "FAIL \(name)\(detail().isEmpty ? "" : ": \(detail())")")
        }
        /// Sessions this check opened an editor on (their views are this check's own, not late saves).
        var openedHere: Set<String> = []
        /// Waits for the Edit page's editor to be ready on `takeId` (nil: any).
        func editorReady(_ takeId: String?, seconds: Double = 25) async -> EditSuiteSession? {
            let end = Date().addingTimeInterval(seconds)
            defer { if let id = store.suite.editCurrent?.draftSessionId { openedHere.insert(id) } }
            while Date() < end {
                // Ready and put back where it was left (restoreView ran).
                if let s = store.suite.editCurrent, s.isReady, s.viewTracking, takeId == nil || s.take.id == takeId { return s }
                if let s = store.suite.editCurrent, case .failed = s.phase { return s }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return nil
        }
        guard let fake = store.api as? FakeMuseAPI else { note("FAIL not in demo mode"); note("ALL DONE"); return }
        store.themeID = .a
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let clip = media.appendingPathComponent("resume.mp4")
        do { try await makeVideo(clip, seconds: 6, fps: 30, width: 360, height: 640, audio: (48_000, 2)) } catch {
            note("FAIL making the test video: \(error.localizedDescription)"); note("ALL DONE"); return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let raw: [[String: Any]] = [
            ["id": "rz_resume", "kind": "take", "title": "Beach walk", "videoUrl": clip.absoluteString, "durationSec": 6, "width": 360, "height": 640, "fps": 30, "createdAt": now],
            ["id": "rz_gone", "kind": "take", "title": "Deleted later", "videoUrl": clip.absoluteString, "durationSec": 6, "width": 360, "height": 640, "fps": 30, "createdAt": now - 1],
        ]
        let made = raw.compactMap { r -> Take? in
            guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
            return try? JSONDecoder().decode(Take.self, from: data)
        }
        guard made.count == 2 else { note("FAIL decoding the test takes"); note("ALL DONE"); return }
        store.takes.removeAll { $0.id.hasPrefix("rz_") }
        store.takes.insert(contentsOf: made, at: 0)
        await fake.adoptTakes(made)
        // Sessions earlier checks left open (the rx_* takes, ops_red…) would compete for "last worked on" (runs 604/607: their
        // views carried later times than this check's). They're closed here so the check is about its own edit; whether any of
        // them is still stamped while this check runs (a background save after its editor closed) is reported at the end.
        let started = Date().timeIntervalSince1970 * 1000
        let leftovers = (try? await fake.recentEditSessions(limit: 50)) ?? []
        for s in leftovers { try? await fake.closeEditSession(id: s.id) }
        try? FileManager.default.removeItem(at: EditRecentStore.standard.file)
        note("NOTE closed \(leftovers.count) edit sessions left open by earlier checks: " +
             leftovers.prefix(8).map { "\($0.takeId) view \($0.view?.at.map { String(Int64($0)) } ?? "-") updated \(Int64($0.updatedAt ?? 0))" }.joined(separator: ", ") +
             " (this check started \(Int64(started)))")

        // 1. Open a take, move the editor, leave Edit.
        note("START open_and_move")
        store.openEdit(takeId: "rz_resume")
        guard let first = await editorReady("rz_resume"), first.isReady else {
            note("FAIL open_and_move: the editor didn't open (\(String(describing: store.suite.editCurrent?.phase)))"); note("ALL DONE"); return
        }
        first.view { $0.zoom = 150; $0.tab = .audio; $0.preview.safeArea = false }
        first.binTab = .uploads
        first.seek(2.5)
        try? await Task.sleep(for: .seconds(2))   // the view is saved after a short pause
        let sid = first.draftSessionId
        check("session_shared", sid != nil, "no edit session")
        store.go(.home)
        try? await Task.sleep(for: .seconds(1.5))
        var ourAt: Double?
        if let sid, let s = try? await fake.editSession(id: sid) {
            ourAt = s.view?.at
            note("NOTE left rz_resume: its view.at \(ourAt.map { String(Int64($0)) } ?? "none") at \(Int64(Date().timeIntervalSince1970 * 1000))")
            check("view_on_server", s.view?.zoom == 150 && s.view?.binTab == "uploads" && s.view?.safeArea == "off",
                  "server view \(String(describing: s.view))")
        } else { note("FAIL view_on_server: session not readable") }

        // 2. Click Edit: the choice shows (nothing opens by itself), Continue draft names that edit, and reopens it there.
        note("START choice")
        store.openEdit(takeId: nil)
        try? await Task.sleep(for: .seconds(3))
        check("no_auto_open", store.suite.editCurrent == nil, "an editor opened by itself on \(store.suite.editCurrent?.take.id ?? "?")")
        let draft = store.suite.recentEdits.first
        let fresh = draft?.takeId == "rz_resume" ? [] : await store.loadRecentEdits()   // only to tell a stale home from a wrong order
        check("choice_continue_draft", draft?.takeId == "rz_resume" && draft?.title == "Beach walk",
              "fresh load's first is \(fresh.first.map { "\($0.takeId) at \(Int64($0.lastEditedAt))" } ?? "-"); " +
              "Continue draft is \(draft.map { "\($0.title) (\($0.takeId))" } ?? "missing"); " +
              "ours (rz_resume) view \(ourAt.map { String(Int64($0)) } ?? "-"); order: " + store.suite.recentEdits.prefix(4).map { "\($0.takeId) at \(Int64($0.lastEditedAt)) view \($0.view?.at.map { String(Int64($0)) } ?? "-")" }.joined(separator: ", "))
        capture(dir.appendingPathComponent("mac_a_edit_choice.png"))
        note("START reopen_last")
        if let draft { store.suite.editResume = draft }
        if let s = await editorReady("rz_resume"), s.isReady {
            check("reopen_last", true)
            check("reopen_playhead", abs(s.state.playhead - 2.5) < 0.05, "playhead \(s.state.playhead)")
            check("reopen_zoom", abs(s.state.zoom - 150) < 0.01, "zoom \(s.state.zoom)")
            check("reopen_tab", s.state.tab == .audio, "tab \(s.state.tab)")
            check("reopen_bin_uploads", s.binTab == .uploads, "bin \(s.binTab)")
            check("reopen_platform_view_off", !s.state.preview.safeArea, "preview \(s.state.preview)")
            capture(dir.appendingPathComponent("mac_a_edit_resumed.png"))
        } else {
            note("FAIL reopen_last: Continue draft opened \(store.suite.editCurrent?.take.id ?? "nothing"), not the last edit")
        }

        // 3. The Edit home lists Recent edits (the editor's Back).
        note("START recent_list")
        store.suite.editHomeRequest = UUID()
        try? await Task.sleep(for: .seconds(2))
        check("back_to_home", store.suite.editCurrent == nil, "the editor is still open")
        let recent = await store.loadRecentEdits()
        check("draft_still_first", recent.first?.takeId == "rz_resume", "first is \(recent.first.map { "\($0.title) (\($0.takeId))" } ?? "none")")
        try? await Task.sleep(for: .seconds(1))
        capture(dir.appendingPathComponent("mac_a_edit_recent.png"))

        // 4. An edit whose take was deleted opens anyway; its clips are marked missing.
        note("START missing_media")
        do {
            let p = EditV2.fromV1(EditList(sourceTakeId: "rz_gone", sourceDurationSec: 6), EditV2.SourceFacts(width: 360, height: 640, fps: 30, hasAudio: true))
            let s = try await fake.openEditSession(EditSessionOpenRequest(takeId: "rz_gone", project: p, device: "phone"))
            try await fake.saveEditSessionView(sessionId: s.id, EditSessionView(playhead: 1, title: "Deleted later"))
            store.takes.removeAll { $0.id == "rz_gone" }
            let items = await store.loadRecentEdits()
            guard let gone = items.first(where: { $0.sessionId == s.id }) else {
                note("FAIL missing_media: the edit isn't in Recent edits"); throw CancellationError()
            }
            store.suite.editResume = gone
            if let ed = await editorReady("rz_gone") {
                check("missing_media_opens", ed.isReady, "phase \(ed.phase)")
                try? await Task.sleep(for: .seconds(2))
                check("missing_media_marked", !ed.missing.isEmpty, "no clip marked missing")
                capture(dir.appendingPathComponent("mac_a_edit_missing.png"))
            } else {
                note("FAIL missing_media_opens: the editor didn't open")
            }
        } catch is CancellationError {
        } catch {
            note("FAIL missing_media: \(error.localizedDescription)")
        }

        // 5. New starts a blank project (the choice's other way in).
        note("START new_edit")
        store.suite.editHomeRequest = UUID()
        try? await Task.sleep(for: .seconds(1))
        store.suite.editNewRequest = UUID()
        if let b = await editorReady(EditV2.blankSourceId) {
            check("new_edit_blank", b.isReady && b.project.mainClips.isEmpty, "phase \(b.phase)")
        } else { note("FAIL new_edit_blank: no blank project") }
        store.suite.editHomeRequest = UUID()
        try? await Task.sleep(for: .seconds(1))
        store.suite.editTakeId = nil
        store.go(.home)
        try? await Task.sleep(for: .seconds(1))
        store.takes.removeAll { $0.id.hasPrefix("rz_") }
        // A closed editor must not keep saving its view: an earlier check's session stamped after this check started is one.
        var late: [String] = []
        for old in leftovers where !openedHere.contains(old.id) {
            if let v = (try? await fake.editSession(id: old.id))?.view?.at, v > started, v != old.view?.at { late.append("\(old.takeId) at \(Int64(v))") }
        }
        check("no_late_views", late.isEmpty, "views saved after their editor closed: \(late.joined(separator: ", ")) (check started \(Int64(started)))")
        note("ALL DONE")
    }
}
