import AppKit
import Foundation
import MuseCore

// Owner bug, build 597 (reports ci_57299a84fa74, ci_c1b1648bea86): Claude's open_page on its edit session (canvas 1920×1080)
// while Edit was already open on that take left the editor on its own local copy: shape bar 9:16, "New project", the 16:9
// op a no-op, playback frozen, no controls in ui_snapshot. The editAttach task's open() cleared editAttach, which cancelled
// that very task half-way through the load (the attach to Claude's session never finished). Lines go to claude-chat-check.txt.
extension SnapshotRunner {
    static func openPageOnOpenTake(_ store: AppStore, fakeMuse: FakeMuseAPI,
                                   until: (Double, () -> Bool) async -> Bool, line: (Bool, String, String) -> Void) async {
        // A blank project (the owner's case: Claude's blank edit made 16:9) and, when editCheck left its MP4, a video take.
        var cases: [(name: String, take: Take?)] = [("blank", nil)]
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        if FileManager.default.fileExists(atPath: long.path) {
            let raw: [String: Any] = ["id": "rx_openpage", "kind": "take", "title": "Rooftop dance", "videoUrl": long.absoluteString,
                                      "durationSec": 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
            if let data = try? JSONSerialization.data(withJSONObject: raw), let t = try? JSONDecoder().decode(Take.self, from: data) {
                cases.append(("video", t))
            }
        }
        defer { store.takes.removeAll { $0.id == "rx_openpage" } }
        for c in cases {
            let name = "open_page on an open take (\(c.name))"
            let takeId = c.take?.id ?? EditV2.blankSourceId
            if let t = c.take {
                store.takes.removeAll { $0.id == t.id }
                store.takes.insert(t, at: 0)
                fakeMuse.adoptTakes([t])
            }
            // 1. Edit is open on the take (its own session).
            store.openEdit(takeId: takeId)
            let first = await until(20) { store.suite.editCurrent?.isReady == true && store.suite.editCurrent?.take.id == takeId }
            let mine = store.suite.editCurrent
            // 2. Claude's own session on the same take, made 16:9.
            guard first, let es = try? await fakeMuse.openEditSession(EditSessionOpenRequest(takeId: takeId, device: "claude", fresh: true)) else {
                line(false, name, "setup: editor ready \(first), Claude's session not made")
                continue
            }
            _ = try? await fakeMuse.fakeClaudePatch(sessionId: es.id, [.replace("/canvas/width", .number(1920)), .replace("/canvas/height", .number(1080))],
                                                    label: "Ratio 16:9")
            // 3. Claude opens it.
            let opened = Date()
            store.performOneClaudeOpen(ClaudeUI(page: "edit", id: es.id, label: "Claude's edit"))
            let on = await until(20) {
                guard let s = store.suite.editCurrent, s !== mine else { return false }
                return s.isReady && s.draftSessionId == es.id && s.liveConnected && s.project.canvas.width == 1920
            }
            let s = store.suite.editCurrent
            let canvas = s.map { "\($0.project.canvas.width)×\($0.project.canvas.height)" } ?? "none"
            let ratio = s.map { EditSuite.Ratio.nearest(width: $0.project.canvas.width, height: $0.project.canvas.height).rawValue } ?? "none"
            line(on && s?.loadWasCancelled == false, name,
                 "editor on Claude's session \(s?.draftSessionId == es.id), live \(s?.liveConnected == true), canvas \(canvas), shape bar \(ratio), "
                 + "title \"\(s?.title ?? "none")\", load cancelled \(s?.loadWasCancelled == true) after "
                 + String(format: "%.1f s", Date().timeIntervalSince(opened)))
            guard let s, on else { store.go(.home); continue }
            // Playback advances (a video take only: a blank has nothing to play).
            if c.take != nil {
                let from = s.playhead
                s.play(rate: 1)
                try? await Task.sleep(for: .seconds(1.5))
                let to = s.playhead
                s.pause()
                line(to > from + 0.5, name + ": playback", String(format: "playhead %.2f → %.2f s in 1.5 s", from, to))
            }
            // The shape buttons work, and reach Claude's session.
            await s.setRatio(.portrait)
            let portrait = s.project.canvas.height > s.project.canvas.width
            await s.setRatio(.landscape)
            let landscape = s.project.canvas.width > s.project.canvas.height
            let synced = await until(10) {
                guard let doc = fakeMuse.fakeEditRecord(es.id)?.project, let p = try? JSONPatch.decode(EditV2.Project.self, doc) else { return false }
                return p.canvas.width > p.canvas.height
            }
            line(portrait && landscape && synced, name + ": shape buttons",
                 "9:16 \(portrait), back to 16:9 \(landscape) (\(s.project.canvas.width)×\(s.project.canvas.height)), on Claude's session \(synced)")
            store.go(.home)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
