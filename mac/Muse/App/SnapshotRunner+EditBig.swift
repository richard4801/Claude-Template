import AppKit
import Darwin
import Foundation
import MuseCore

// Owner bugs on a real 16:9 edit (build 597; the CPU one in 582 too). Reports ci_3091ae6f4a46 and ci_ae3955ee8fe7:
// 66 shots and 4 overlays at 1920×1080, MUSE at 99.7 % CPU from launch for 8+ min, frozen playback, Shape clicks landing
// minutes late, and each 16:9 ↔ 9:16 flip leaving clip x where it was. Earlier: open_page on Claude's session left the
// editor on its local copy (SnapshotRunner+EditOpenPage.swift). This walk builds a project like that, opens it the way
// Claude does, and measures it. Lines go to edit-big-check.txt (PASS / FAIL / INFO, then ALL DONE); Mac CI fails on FAIL.
// The main thread's sample while idle goes to edit-big-sample.txt.
extension SnapshotRunner {
    static func editBigCheck(_ store: AppStore, dir: URL) async {
        let file = dir.appendingPathComponent("edit-big-check.txt")
        var lines: [String] = []
        func write() { try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8) }
        func line(_ ok: Bool?, _ name: String, _ detail: String) {
            lines.append("\(ok.map { $0 ? "PASS" : "FAIL" } ?? "INFO") \(name) · \(detail)")
            NSLog("[snapshot] edit big %@ %@", ok.map { $0 ? "PASS" : "FAIL" } ?? "INFO", name)
            write()
        }
        func until(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if ok() { return true }
                try? await Task.sleep(for: .seconds(0.2))
            }
            return ok()
        }
        defer { lines.append("ALL DONE"); write() }

        guard let fake = store.api as? FakeMuseAPI else { line(false, "setup", "not the demo API"); return }
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        guard FileManager.default.fileExists(atPath: long.path) else { line(false, "setup", "editCheck's 15 s video is missing"); return }
        let raw: [String: Any] = ["id": "rx_big", "kind": "take", "title": "Brand film cut", "videoUrl": long.absoluteString,
                                  "durationSec": 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
        guard let data = try? JSONSerialization.data(withJSONObject: raw), let take = try? JSONDecoder().decode(Take.self, from: data) else {
            line(false, "setup", "the take didn't decode"); return
        }
        store.takes.removeAll { $0.id == take.id }
        store.takes.insert(take, at: 0)
        await fake.adoptTakes([take])
        defer { store.takes.removeAll { $0.id == "rx_big" } }
        guard let project = bigProject(takeId: take.id, videoUrl: long.absoluteString) else { line(false, "setup", "the big project didn't decode"); return }
        if let bad = EditV2.problem(project) { line(nil, "setup", "the model flags the big project: \(bad.field) \(bad.message)") }

        let w = mainWindow
        let full = w?.frame
        w?.setFrame(NSRect(x: full?.minX ?? 0, y: (full?.maxY ?? 900) - 900, width: 1440, height: 900), display: true)
        defer { if let full { w?.setFrame(full, display: true) } }

        // 1. Edit already open on the take (its own session), 2. Claude's session with the big edit, 3. open_page.
        store.openEdit(takeId: take.id)
        let first = await until(30) { store.suite.editCurrent?.isReady == true && store.suite.editCurrent?.take.id == take.id }
        let mine = store.suite.editCurrent
        guard first, let es = try? await fake.openEditSession(EditSessionOpenRequest(takeId: take.id, project: project, device: "claude", fresh: true)) else {
            line(false, "setup", "editor ready \(first), Claude's big session refused or not made"); return
        }
        let opened = Date()
        store.performOneClaudeOpen(ClaudeUI(page: "edit", id: es.id, label: "Brand film cut"))
        let on = await until(40) {
            guard let s = store.suite.editCurrent, s !== mine else { return false }
            return s.isReady && s.draftSessionId == es.id && s.liveConnected && s.project.mainClips.count == 66
        }
        guard let s = store.suite.editCurrent else { line(false, "open_page big 16:9", "no editor"); return }
        let tracks = s.project.tracks.map { "\($0.kind.rawValue) \($0.kind == .caption ? ($0.caption?.words.count ?? 0) : $0.items.count)" }
        line(on && !s.loadWasCancelled && s.project.canvas.width == 1920 && s.project.canvas.height == 1080, "open_page big 16:9",
             "on Claude's session \(s.draftSessionId == es.id), live \(s.liveConnected), canvas \(s.project.canvas.width)×\(s.project.canvas.height), "
             + "shape bar \(EditSuite.Ratio.nearest(width: s.project.canvas.width, height: s.project.canvas.height).rawValue), "
             + "tracks [\(tracks.joined(separator: ", "))], load cancelled \(s.loadWasCancelled), after "
             + String(format: "%.1f s", Date().timeIntervalSince(opened)))
        guard on else { store.go(.home); return }
        capture(dir.appendingPathComponent("mac_edit_big_16x9.png"))

        // 4. Idle: Edit open, nothing playing. The owner's build sat at 99.7 % here.
        try? await Task.sleep(for: .seconds(10))
        let sampleFile = dir.appendingPathComponent("edit-big-sample.txt")
        async let sampled: Void = sampleApp(to: sampleFile, seconds: 5)
        let idle = await cpuPercent(over: 20)
        _ = await sampled
        line(idle <= 40, "idle CPU with the big edit open", String(format: "%.0f %% of one core over 20 s (fails above 40 %%)", idle))
        for f in mainThreadTop(sampleFile, count: 25) { lines.append("INFO   main: " + f) }
        write()

        // 4b. Coordinator, run 604: the owner's 99.7 % came with Claude working, its reply streaming in Edit's Claude panel
        // (runs 595 and 604 hung on a streaming chat: the transcript's follow-scroll fed itself). Claude's panel streams a
        // reply over the big edit for about 10 s while it plays: FAIL above 60 % of one core or if the playhead lags.
        let service = ClaudeCodeService.shared
        if service.configured, service.isDemo {
            state.claudeTab = 0
            defer { state.claudeTab = nil }
            try? await Task.sleep(for: .seconds(2))
            let delay = ClaudeCodeService.demoLineDelay
            ClaudeCodeService.demoLineDelay = 1.2
            defer { ClaudeCodeService.demoLineDelay = delay }
            if let d = try? await service.openThread(contextKind: "edit", contextId: es.id) {
                service.send(threadId: d.thread.id, text: "Tighten the cuts so every shot lands on the beat")
                var running = false
                for _ in 0..<40 where !running {
                    try? await Task.sleep(for: .seconds(0.1))
                    running = service.isRunning(threadId: d.thread.id)
                }
                // Paused: what the streaming reply alone costs (run 607 measured it during playback, which is ~110 % itself).
                let streamSample = dir.appendingPathComponent("edit-big-stream-sample.txt")
                async let sampledStream: Void = sampleApp(to: streamSample, seconds: 4)
                let cpu = await cpuPercent(over: 8)
                _ = await sampledStream
                let stillPaused = service.isRunning(threadId: d.thread.id)
                line(running && stillPaused && cpu <= 60, "CPU while Claude's reply streams in Edit",
                     String(format: "%.0f %% of one core over 8 s, paused (fails above 60 %%), ", cpu)
                     + "reply streaming at start \(running), still at the end \(stillPaused)")
                for f in mainThreadTop(streamSample, count: 25) { lines.append("INFO   main (streaming): " + f) }
                write()
                // Playing while it streams: the playhead keeps time.
                let p0 = s.playhead, t0 = Date()
                s.play(rate: 1)
                let both = await cpuPercent(over: 6)
                let advanced = s.playhead - p0, wall = Date().timeIntervalSince(t0)
                let stillPlaying = service.isRunning(threadId: d.thread.id)
                s.pause()
                capture(dir.appendingPathComponent("mac_edit_big_streaming.png"))
                line(advanced >= wall * 0.8 - 0.5, "playback keeps time while Claude's reply streams",
                     String(format: "playhead +%.1f s in %.1f s, CPU %.0f %% (playing and streaming), ", advanced, wall, both)
                     + "still streaming \(stillPlaying)")
                for _ in 0..<100 where service.isRunning(threadId: d.thread.id) { try? await Task.sleep(for: .seconds(0.1)) }
            } else {
                line(false, "CPU while Claude's reply streams in Edit", "the edit's Claude thread didn't open")
            }
            s.seek(0)
        } else {
            line(false, "CPU while Claude's reply streams in Edit", "demo Claude not configured (configured \(service.configured), demo \(service.isDemo))")
        }

        // 5. Playback advances, and what it costs.
        let from = s.playhead
        s.play(rate: 1)
        let playing = await cpuPercent(over: 3)
        let to = s.playhead
        s.pause()
        line(to > from + 2, "playback on the big edit", String(format: "playhead %.2f → %.2f s in 3 s, CPU %.0f %%", from, to, playing))

        // 6. Shape: 9:16 and straight back to 16:9 puts every clip back; each switch is timed (face framing on 66 clips).
        let before = s.project
        var t0 = Date()
        await s.setRatio(.portrait)
        let toPortrait = Date().timeIntervalSince(t0)
        let portrait = s.project.canvas.height > s.project.canvas.width
        let moved = zip(before.mainClips, s.project.mainClips).filter { $0.transform != $1.transform }.count
        t0 = Date()
        await s.setRatio(.landscape)
        let toLandscape = Date().timeIntervalSince(t0)
        let diffs = zip(before.mainClips, s.project.mainClips).filter { $0.transform != $1.transform }
        let sample = diffs.prefix(3).map { "\($0.0.id) x \($0.0.transform?.x.map { String($0) } ?? "nil") → \($0.1.transform?.x.map { String($0) } ?? "nil")" }
        line(portrait && s.project.canvas == before.canvas && diffs.isEmpty, "shape 16:9 → 9:16 → 16:9 puts the clips back",
             "9:16 \(portrait) (\(moved) clips re-framed), back to \(s.project.canvas.width)×\(s.project.canvas.height), "
             + "\(diffs.count) clips not back\(sample.isEmpty ? "" : " (\(sample.joined(separator: "; ")))")")
        line(toPortrait < 20 && toLandscape < 2, "shape switch time on 66 clips",
             String(format: "to 9:16 %.1f s (faces found, fails above 20 s), straight back to 16:9 %.1f s (fails above 2 s)", toPortrait, toLandscape))
        var synced = false
        for _ in 0..<50 where !synced {
            if let doc = await fake.fakeEditRecord(es.id)?.project, let p = try? JSONPatch.decode(EditV2.Project.self, doc) {
                synced = p.canvas == before.canvas && p.mainClips.map(\.transform) == before.mainClips.map(\.transform)
            }
            if !synced { try? await Task.sleep(for: .seconds(0.2)) }
        }
        line(synced, "shape round trip on Claude's session", "the session holds the 16:9 project as it was: \(synced)")
        store.go(.home)
        store.closeRecreate()
        store.oneClaude.open = false
        try? await Task.sleep(for: .seconds(1))
    }

    /// The owner's shape of edit: 66 short main shots, two picture-in-picture rows, two text rows, captions; 1920×1080.
    static func bigProject(takeId: String, videoUrl: String) -> EditV2.Project? {
        var main: [[String: Any]] = []
        for i in 0..<66 {
            let d = [0.6, 0.8, 1.0, 1.2][i % 4]
            let a = Double((i * 7) % 130) / 10
            main.append(["id": "s\(i + 1)", "asset": "src", "inSec": a, "outSec": min(15, a + d), "speed": 1,
                         "transform": ["x": [0.5, 0.667, 0.333][i % 3], "scale": 1.5]])
        }
        let total = main.reduce(0.0) { $0 + (($1["outSec"] as! Double) - ($1["inSec"] as! Double)) }
        func pips(_ offset: Double, _ x: Double) -> [[String: Any]] {
            stride(from: offset, to: total - 4, by: 8).enumerated().map { n, at in
                ["id": "p\(Int(offset))_\(n)", "asset": "src", "startSec": at, "inSec": Double(n % 10), "outSec": Double(n % 10) + 3, "speed": 1,
                 "fit": "contain", "transform": ["x": x, "y": 0.3, "scale": 0.3]]
            }
        }
        let style: [String: Any] = ["font": "sans", "weight": 900, "sizePct": 0.05, "color": "#FFFFFF", "align": "center", "maxWidthPct": 0.85,
                                    "lineHeight": 1.15, "stroke": ["color": "#000000", "widthPct": 0.12]]
        func texts(_ offset: Double, _ y: Double) -> [[String: Any]] {
            stride(from: offset, to: total - 2, by: 5).enumerated().map { n, at in
                ["id": "t\(Int(offset))_\(n)", "startSec": at, "durationSec": 2, "text": "Shot \(n + 1)", "style": style, "transform": ["y": y]]
            }
        }
        let words: [[String: Any]] = stride(from: 0.2, to: total - 0.5, by: 0.4).enumerated().map { n, at in
            ["text": ["Okay", "so", "this", "is", "the", "cut", "we", "made"][n % 8], "startSec": at, "endSec": at + 0.3]
        }
        let capStyle: [String: Any] = ["font": "sans", "weight": 900, "sizePct": 0.045, "color": "#FFFFFF", "align": "center", "maxWidthPct": 0.85,
                                       "lineHeight": 1.15, "stroke": ["color": "#000000", "widthPct": 0.12], "preset": "highlight",
                                       "highlightColor": "#FFE600", "y": 0.82, "wordsPerPage": 3, "maxLines": 2]
        let doc: [String: Any] = [
            "version": 2, "sourceTakeId": takeId,
            "canvas": ["width": 1920, "height": 1080, "fps": 30, "background": "#000000"],
            "assets": [["id": "src", "kind": "video", "take": takeId, "durationSec": 15, "width": 1920, "height": 1080, "hasAudio": true, "url": videoUrl]],
            "tracks": [
                ["id": "main", "kind": "main", "items": main],
                ["id": "pipA", "kind": "video", "items": pips(0, 0.8)],
                ["id": "pipB", "kind": "video", "items": pips(4, 0.2)],
                ["id": "txtA", "kind": "text", "items": texts(0, 0.15)],
                ["id": "txtB", "kind": "text", "items": texts(2.5, 0.3)],
                ["id": "cap", "kind": "caption", "items": [], "caption": ["asset": "src", "words": words, "style": capStyle]],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: doc) else { return nil }
        return try? JSONDecoder().decode(EditV2.Project.self, from: data)
    }

    /// This process's CPU (user + system, all threads) over `seconds`, as % of one core (what `ps -o %cpu` shows).
    static func cpuPercent(over seconds: Double) async -> Double {
        func used() -> Double {
            var r = rusage()
            getrusage(RUSAGE_SELF, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        let c0 = used(), t0 = Date()
        try? await Task.sleep(for: .seconds(seconds))
        return 100 * (used() - c0) / max(0.001, Date().timeIntervalSince(t0))
    }

    /// `/usr/bin/sample` of this app (off the main thread), into `to`.
    static func sampleApp(to url: URL, seconds: Int) async {
        let pid = ProcessInfo.processInfo.processIdentifier
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            p.arguments = ["\(pid)", "\(seconds)", "-file", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }.value
    }

    /// The main thread's heaviest frames in a `sample` report: its call tree's first lines (counts and symbols).
    static func mainThreadTop(_ url: URL, count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ["(no sample)"] }
        let all = text.components(separatedBy: "\n")
        guard let i = all.firstIndex(where: { $0.contains("com.apple.main-thread") || $0.contains(": Main Thread") }) else { return ["(no main thread in the sample)"] }
        return all[(i + 1)...].prefix(count).map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
    }
}
