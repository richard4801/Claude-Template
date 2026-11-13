import AppKit
import MuseCore

/// Live chips check (Mac CI, owner 2026-11-12: "make the chips real-time suggestions that fit what is on screen"). In review
/// mode, through the real Edit page and the one-Claude panel: an edit without captions must offer "Add captions"; once
/// captions are on, the row must change ("Restyle the captions", no "Add captions") within the ~1 s refresh, a chip that
/// stays must keep its place, and the app must have sent what it sees (clips, captions) to the suggestions call. Shots:
/// `mac_a_edit_chips_no_captions.png` and `mac_a_edit_chips_captions.png`. Writes `claude-chips-check.txt`; CI fails on
/// any FAIL line or a missing ALL DONE. (Demo mode answers with MuseCore's copy of the server's Edit rules.)
extension SnapshotRunner {
    static func claudeChipsCheck(_ store: AppStore, dir: URL) async {
        let log = dir.appendingPathComponent("claude-chips-check.txt")
        try? Data().write(to: log)
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("claude-chips-check: \(s)")
        }
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            note(ok ? "DONE \(name)" : "FAIL \(name)\(detail().isEmpty ? "" : ": \(detail())")")
        }
        func wait(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
            return ok()
        }
        guard let fake = store.api as? FakeMuseAPI else { note("FAIL not in demo mode"); note("ALL DONE"); return }
        _ = await wait(15) { ClaudeCodeService.shared.configured }
        let fakeClaude = ClaudeCodeService.shared.api as? FakeClaudeAPI
        store.themeID = .a
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-claude-chips", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let clip = media.appendingPathComponent("chips.mp4")
        do { try await makeVideo(clip, seconds: 6, fps: 30, width: 360, height: 640, audio: (48_000, 2)) } catch {
            note("FAIL making the test video: \(error.localizedDescription)"); note("ALL DONE"); return
        }
        let raw: [String: Any] = ["id": "rz_chips", "kind": "take", "title": "Chips walk", "videoUrl": clip.absoluteString, "durationSec": 6,
                                  "width": 360, "height": 640, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
        guard let data = try? JSONSerialization.data(withJSONObject: raw), let take = try? JSONDecoder().decode(Take.self, from: data) else {
            note("FAIL decoding the test take"); note("ALL DONE"); return
        }
        store.takes.removeAll { $0.id == take.id }
        store.takes.insert(take, at: 0)
        await fake.adoptTakes([take])

        // A clean start (bundle-10 run 617: Recreate and the One Claude panel left open by earlier walks made the page
        // "recreate" and showOneClaude a no-op).
        store.closeRecreate()
        store.oneClaude.open = false
        state.overlay = nil
        note("START open_edit")
        store.openEdit(takeId: take.id)
        guard await wait(25, { store.suite.editCurrent?.isReady == true && store.suite.editCurrent?.take.id == take.id }),
              let s = store.suite.editCurrent else {
            note("FAIL open_edit: the editor didn't open (\(String(describing: store.suite.editCurrent?.phase)))"); note("ALL DONE"); return
        }
        // No platform view (its safe-area chip would lead), no text, no captions, no music.
        s.view { $0.preview.safeArea = false }
        store.showOneClaude()
        if !(await wait(10) { store.oneClaude.chatId != nil }) { await store.startOneClaude() }
        store.claudeChipsChanged(now: true)

        note("START no_captions")
        let before = await wait(10) { store.oneClaude.chips.contains { $0.label == "Add captions" } }
        let first = store.oneClaude.chips.map(\.label)
        check("no_captions_chips", before && !first.contains("Restyle the captions"), "chips \(first)")
        if let fc = fakeClaude {
            let q = fc.suggestionQueries.last
            check("query_sent", q?.page == "edit" && q?.captions == false && (q?.clips ?? 0) > 0, "last query \(q?.queryString ?? "none")")
        }
        try? await Task.sleep(for: .seconds(0.5))   // the crossfade has ended
        capture(dir.appendingPathComponent("mac_a_edit_chips_no_captions.png"))

        note("START captions")
        if let asset = s.project.mainClips.first?.asset {
            s.edit { $0.setCaptions(words: [EditV2.Word(text: "Hello", startSec: 0.2, endSec: 0.6), EditV2.Word(text: "world", startSec: 0.6, endSec: 1.1)], assetId: asset) }
        } else { note("FAIL captions: the edit has no main clip") }
        let changed = await wait(10) { store.oneClaude.chips.contains { $0.label == "Restyle the captions" } }
        let second = store.oneClaude.chips.map(\.label)
        check("captions_chips", changed && !second.contains("Add captions"), "chips \(second)")
        check("chips_changed", first != second, "before \(first), after \(second)")
        // Steady: a chip in both rows keeps its place.
        let kept = first.filter(second.contains)
        check("steady_order", kept.allSatisfy { first.firstIndex(of: $0) == second.firstIndex(of: $0) }, "before \(first), after \(second)")
        check("three_chips", first.count == 3 && second.count == 3, "\(first.count) and \(second.count)")
        try? await Task.sleep(for: .seconds(0.5))
        capture(dir.appendingPathComponent("mac_a_edit_chips_captions.png"))

        store.oneClaude.open = false
        store.go(.home)
        try? await Task.sleep(for: .seconds(1))
        note("ALL DONE")
    }
}
