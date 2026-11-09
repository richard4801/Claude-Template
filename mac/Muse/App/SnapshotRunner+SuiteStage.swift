import AppKit
import MuseCore

// WS19, the owner's Suite stage report, walked in review mode (demo mode: FakeMuseAPI; nothing is spent). Each step writes
// PASS or FAIL to suite-stage-check.txt, which Mac CI reads:
//   photo_generating  Photo × 4: right after Generate the stage shows the generating state, and the run is a job
//   photo_queue_live  that job is in the Queue's active list while it runs
//   photo_carousel    the four stills land on the stage as a carousel (four dots)
//   photo_return      leaving the page and coming back shows the same result
//   photo_restart     with the session's memory gone (a restart), the stage still finds it
//   photo_queue_row   the Queue draws its row
//   shot_*            the same for a video mode (Shot): generating, back after leaving, its Queue row
extension SnapshotRunner {
    static func suiteStageCheck(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        let file = dir.appendingPathComponent("suite-stage-check.txt")
        func write() { try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8) }
        func line(_ ok: Bool, _ name: String, _ detail: String) {
            lines.append("\(ok ? "PASS" : "FAIL") \(name) · \(detail)")
            NSLog("[snapshot] suite stage check %@ %@", ok ? "PASS" : "FAIL", name)
            write()
        }
        func until(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if ok() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return ok()
        }
        func frame(_ key: String) -> Bool { state.composerFrames[key] != nil }
        // "Starting…" (Generate pressed) and the job's own generating state draw under separate keys: one view's
        // onDisappear would clear the other's if they shared one.
        func generating() -> Bool { frame("stage starting") || frame("stage busy") }
        func carousel(_ n: Int) -> Bool { state.composerFrames.keys.contains { $0.hasPrefix("stage carousel ") && $0.hasSuffix("/\(n)") } }
        lines.append("START suite stage check")
        write()
        store.themeID = .a

        // Photo × 4
        store.openPhoto(model: SampleData.demo)
        store.suite.feedOpen = false
        store.suite.photo.count = 4
        await store.estimatePhoto()
        let before = Set(store.jobs.map(\.id))
        store.generatePhoto()
        let busy = await until(3) { generating() }
        let started = await until(5) { store.stageJob(.photo).map { !before.contains($0.id) } ?? false }
        let pj = store.stageJob(.photo)
        line(busy && started && pj?.isPhoto == true, "photo_generating",
             "busy \(busy) · job \(pj?.id ?? "none") \(pj?.state ?? "") \(pj?.phase ?? "")")
        let live = pj.map { j in store.activeJobs.contains { $0.id == j.id } || j.isDone } ?? false
        line(live, "photo_queue_live", "in the active list \(pj.map { j in store.activeJobs.contains { $0.id == j.id } } ?? false), done \(pj?.isDone ?? false)")
        let four = await until(10) { carousel(4) }
        let shown = store.stageJob(.photo).map { store.takes(of: $0).count } ?? 0
        line(four && shown == 4, "photo_carousel", "carousel of 4 \(four) · stills \(shown)")
        capture(dir.appendingPathComponent("mac_a_suite_stage_photo.png"))

        store.go(.home)
        try? await Task.sleep(for: .seconds(1))
        store.openTool(.photo)
        store.suite.feedOpen = false
        let back = await until(5) { carousel(4) }
        line(back && store.stageJob(.photo)?.id == pj?.id, "photo_return", "carousel \(back) · stage job \(store.stageJob(.photo)?.id ?? "none")")

        // A restart: the session's memory is gone; the stage finds the job from what was kept.
        let session = store.suite.stageJobs
        store.suite.stageJobs = [:]
        let found = store.stageJob(.photo)?.id
        store.suite.stageJobs = session
        line(found != nil && found == pj?.id, "photo_restart", "found \(found ?? "none")")

        if let id = pj?.id {
            store.go(.queue)
            let row = await until(5) { frame("queue row \(id)") }
            line(row, "photo_queue_row", "row \(row)")
        } else {
            line(false, "photo_queue_row", "no job")
        }

        // A video mode: Shot
        store.openTool(.shot)
        fillDemoDraft(store)
        store.suite.feedOpen = false
        try? await Task.sleep(for: .milliseconds(800))
        let vBefore = Set(store.jobs.map(\.id))
        store.generateShot()
        let vBusy = await until(3) { generating() }
        let vStarted = await until(6) { store.stageJob(.shot).map { !vBefore.contains($0.id) } ?? false }
        let sj = store.stageJob(.shot)
        line(vBusy && vStarted, "shot_generating", "busy \(vBusy) · job \(sj?.id ?? "none") \(sj?.state ?? "")")
        store.go(.gallery)
        try? await Task.sleep(for: .seconds(1))
        store.openTool(.shot)
        store.suite.feedOpen = false
        let vBack = await until(5) { store.stageJob(.shot)?.id == sj?.id && (frame("stage busy") || (store.stageJob(.shot)?.isDone ?? false)) }
        line(sj != nil && vBack, "shot_return", "stage job \(store.stageJob(.shot)?.id ?? "none")")
        if let id = sj?.id {
            store.go(.queue)
            let row = await until(5) { frame("queue row \(id)") }
            line(row, "shot_queue_row", "row \(row)")
        } else {
            line(false, "shot_queue_row", "no job")
        }
        lines.append("ALL DONE")
        write()
    }
}
