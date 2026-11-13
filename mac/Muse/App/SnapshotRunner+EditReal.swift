import AppKit
import AVFoundation
import Foundation
import MuseCore

// Owner report ci_83f9d0dcd92f (2026-11-13 18:39). After a Mac restart, the owner's real Edit project (64 s, 67 main clips,
// 16 overlay clips) kept MUSE at about 80 % of one core while idle, with Edit frozen, WindowServer at about 27 % and
// VTDecoderXPCService at 865 MB. editBigCheck passed at 0 % because it reuses one small 432×768 file 66 times. This check
// builds 20 distinct real 1080p files (H.264 and HEVC, with moving pictures and AAC sound) and spreads them over 67 main
// clips and 16 overlays across a real 64 s. It measures CPU after a 15 s settle, during playback and when paused again, and
// FAILs if idle is above 25 %. Lines go to edit-real-check.txt (PASS / FAIL / INFO, then ALL DONE), and the main thread's
// MUSE frames from each sample are logged as INFO lines.
extension SnapshotRunner {
    static let realClipCount = 20
    static let realClipSeconds = 8.0

    static func editRealMediaCheck(_ store: AppStore, dir: URL) async {
        let file = dir.appendingPathComponent("edit-real-check.txt")
        var lines: [String] = []
        func write() { try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8) }
        func line(_ ok: Bool?, _ name: String, _ detail: String) {
            lines.append("\(ok.map { $0 ? "PASS" : "FAIL" } ?? "INFO") \(name) · \(detail)")
            NSLog("[snapshot] edit real %@ %@", ok.map { $0 ? "PASS" : "FAIL" } ?? "INFO", name)
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
        func frames(_ label: String, _ url: URL) {
            for f in museFrames(url, count: 30) { lines.append("INFO   main (\(label)): " + f) }
            write()
        }
        defer { lines.append("ALL DONE"); write() }

        guard let fake = store.api as? FakeMuseAPI else { line(false, "setup", "not the demo API"); return }

        // 1. Twenty distinct 1080p files: even ones H.264, odd ones HEVC (H.264 if this Mac can't write HEVC), each with sound.
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-real", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let made = Date()
        var urls: [URL] = []
        var hevc = 0
        for k in 0..<realClipCount {
            let url = media.appendingPathComponent("clip\(k).mp4")
            let wantHEVC = k % 2 == 1
            do {
                try await makeVideo(url, seconds: realClipSeconds, fps: 30, width: 1920, height: 1080, audio: (48_000, 2),
                                    codec: wantHEVC ? .hevc : .h264, seed: k + 1)
                if wantHEVC { hevc += 1 }
            } catch {
                do {
                    try await makeVideo(url, seconds: realClipSeconds, fps: 30, width: 1920, height: 1080, audio: (48_000, 2), seed: k + 1)
                } catch {
                    line(false, "setup", "couldn't write real clip \(k): \(error.localizedDescription)"); return
                }
            }
            urls.append(url)
        }
        let bytes = urls.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? nil }.reduce(0, +)
        line(nil, "real media", "\(urls.count) files 1920×1080 30 fps \(Int(realClipSeconds)) s with AAC, \(hevc) HEVC, "
             + "\(bytes / 1_000_000) MB, made in " + String(format: "%.0f s", Date().timeIntervalSince(made)))

        // 2. One take per file (as the owner's project has: many takes and uploads).
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var takes: [Take] = []
        for (k, url) in urls.enumerated() {
            let raw: [String: Any] = ["id": "rx_real\(k)", "kind": "take", "title": "Real \(k + 1)", "videoUrl": url.absoluteString,
                                      "durationSec": realClipSeconds, "width": 1920, "height": 1080, "fps": 30, "createdAt": now - Int64(k)]
            guard let data = try? JSONSerialization.data(withJSONObject: raw), let t = try? JSONDecoder().decode(Take.self, from: data) else {
                line(false, "setup", "take \(k) didn't decode"); return
            }
            takes.append(t)
        }
        let ids = Set(takes.map(\.id))
        store.takes.removeAll { ids.contains($0.id) }
        store.takes.insert(contentsOf: takes, at: 0)
        await fake.adoptTakes(takes)
        defer { store.takes.removeAll { ids.contains($0.id) } }
        guard let project = realProject(takes: takes) else { line(false, "setup", "the real project didn't decode"); return }
        if let bad = EditV2.problem(project) { line(nil, "setup", "the model flags the real project: \(bad.field) \(bad.message)") }

        let w = mainWindow
        let full = w?.frame
        w?.setFrame(NSRect(x: full?.minX ?? 0, y: (full?.maxY ?? 900) - 900, width: 1440, height: 900), display: true)
        defer { if let full { w?.setFrame(full, display: true) } }

        // 3. Open it: Edit on the first take, then Claude's session holding the real project (open_page, as editBigCheck).
        let take0 = takes[0].id
        store.openEdit(takeId: take0)
        let first = await until(30) { store.suite.editCurrent?.isReady == true && store.suite.editCurrent?.take.id == take0 }
        let mine = store.suite.editCurrent
        guard first, let es = try? await fake.openEditSession(EditSessionOpenRequest(takeId: take0, project: project, device: "claude", fresh: true)) else {
            line(false, "setup", "editor ready \(first), the real session refused or not made"); return
        }
        let opened = Date()
        store.performOneClaudeOpen(ClaudeUI(page: "edit", id: es.id, label: "Real cut"))
        let on = await until(60) {
            guard let s = store.suite.editCurrent, s !== mine else { return false }
            return s.isReady && s.draftSessionId == es.id && s.project.mainClips.count == 67
        }
        guard let s = store.suite.editCurrent, on else {
            line(false, "open the real 64 s edit", "not open after 60 s (main clips \(store.suite.editCurrent?.project.mainClips.count ?? 0))")
            store.go(.home); return
        }
        let overlays = s.project.tracks.filter { $0.kind == .video }.reduce(0) { $0 + $1.items.count }
        line(true, "open the real 64 s edit", "67 main clips, \(overlays) overlays, \(realClipCount) files, duration "
             + String(format: "%.1f s, ready after %.1f s", EditV2.durationSec(s.project), Date().timeIntervalSince(opened)))
        capture(dir.appendingPathComponent("mac_edit_real.png"))

        // 4a. The one-off work after open: a filmstrip and a waveform per file (two at a time). Timed, and what it costs.
        let mediaStart = Date()
        var burst: [Double] = []
        while await EditMediaWork.shared.pending > 0, Date().timeIntervalSince(mediaStart) < 120 {
            burst.append(await cpuPercent(over: 2))
        }
        let mediaLeft = await EditMediaWork.shared.pending
        let mediaTime = Date().timeIntervalSince(mediaStart)
        line(mediaLeft == 0 && mediaTime <= 60, "filmstrips and waveforms after open",
             String(format: "%d files done %.0f s after the edit was ready (fails above 60 s), CPU meanwhile %.0f %% of one core on average; ",
                    realClipCount, mediaTime, burst.isEmpty ? 0 : burst.reduce(0, +) / Double(burst.count))
             + "\(mediaLeft) still running; " + systemLoad())

        // 4. Idle after a 15 s settle. The owner's build sat at ~80 % here.
        try? await Task.sleep(for: .seconds(15))
        let rebuilds0 = s.rebuildCount
        let idleSample = dir.appendingPathComponent("edit-real-idle-sample.txt")
        async let sampledIdle: Void = sampleApp(to: idleSample, seconds: 5)
        let idle = await cpuPercent(over: 20)
        _ = await sampledIdle
        line(idle <= 25, "idle CPU with the real edit open", String(format: "%.0f %% of one core over 20 s after a 15 s settle (fails above 25 %%); ", idle)
             + systemLoad())
        line(s.rebuildCount == rebuilds0, "no player rebuilds while idle", "\(s.rebuildCount - rebuilds0) rebuilds in 20 s idle (\(rebuilds0) since open)")
        frames("idle", idleSample)

        // 5. Playback: the playhead keeps time, and what it costs.
        let p0 = s.playhead, t0 = Date()
        s.play(rate: 1)
        let playSample = dir.appendingPathComponent("edit-real-play-sample.txt")
        async let sampledPlay: Void = sampleApp(to: playSample, seconds: 5)
        let playing = await cpuPercent(over: 8)
        _ = await sampledPlay
        let advanced = s.playhead - p0, wall = Date().timeIntervalSince(t0)
        s.pause()
        line(advanced >= wall * 0.8 - 0.5, "playback on the real edit",
             String(format: "playhead +%.1f s in %.1f s, CPU %.0f %% of one core; ", advanced, wall, playing) + systemLoad())
        frames("playing", playSample)

        // 6. Paused again: back to idle (nothing keeps running after playback).
        try? await Task.sleep(for: .seconds(5))
        let after = await cpuPercent(over: 10)
        line(after <= 25, "idle CPU after playback", String(format: "%.0f %% of one core over 10 s, paused (fails above 25 %%); ", after) + systemLoad())

        store.go(.home)
        store.closeRecreate()
        store.oneClaude.open = false
        try? await Task.sleep(for: .seconds(1))
        try? FileManager.default.removeItem(at: media)
    }

    /// The owner's real edit: 67 main clips over 64 s from 20 files, 16 picture-in-picture overlays on two rows, two text rows
    /// and captions, at 1920×1080.
    static func realProject(takes: [Take]) -> EditV2.Project? {
        let n = takes.count
        let d = 64.0 / 67.0
        var main: [[String: Any]] = []
        for i in 0..<67 {
            let a = Double((i * 13) % 70) / 10
            main.append(["id": "m\(i + 1)", "asset": "a\(i % n)", "inSec": a, "outSec": a + d, "speed": 1,
                         "transform": ["x": [0.5, 0.6, 0.4][i % 3], "scale": 1.0]])
        }
        func pips(_ row: Int, _ x: Double) -> [[String: Any]] {
            (0..<8).map { j in
                let k = row * 8 + j
                return ["id": "o\(row)_\(j)", "asset": "a\((k * 3 + 5) % n)", "startSec": Double(j) * 8 + Double(row) * 4, "inSec": Double(k % 4),
                        "outSec": Double(k % 4) + 3, "speed": 1, "fit": "contain", "transform": ["x": x, "y": 0.3, "scale": 0.3]]
            }
        }
        let style: [String: Any] = ["font": "sans", "weight": 900, "sizePct": 0.05, "color": "#FFFFFF", "align": "center", "maxWidthPct": 0.85,
                                    "lineHeight": 1.15, "stroke": ["color": "#000000", "widthPct": 0.12]]
        func texts(_ offset: Double, _ y: Double) -> [[String: Any]] {
            stride(from: offset, to: 62, by: 5).enumerated().map { j, at in
                ["id": "t\(Int(offset))_\(j)", "startSec": at, "durationSec": 2, "text": "Line \(j + 1)", "style": style, "transform": ["y": y]]
            }
        }
        let words: [[String: Any]] = stride(from: 0.2, to: 63.5, by: 0.4).enumerated().map { j, at in
            ["text": ["Okay", "so", "this", "is", "the", "cut", "we", "made"][j % 8], "startSec": at, "endSec": at + 0.3]
        }
        let capStyle: [String: Any] = ["font": "sans", "weight": 900, "sizePct": 0.045, "color": "#FFFFFF", "align": "center", "maxWidthPct": 0.85,
                                       "lineHeight": 1.15, "stroke": ["color": "#000000", "widthPct": 0.12], "preset": "highlight",
                                       "highlightColor": "#FFE600", "y": 0.82, "wordsPerPage": 3, "maxLines": 2]
        let assets: [[String: Any]] = takes.enumerated().map { k, t in
            ["id": "a\(k)", "kind": "video", "take": t.id, "durationSec": realClipSeconds, "width": 1920, "height": 1080, "hasAudio": true,
             "url": t.videoUrl ?? ""]
        }
        let doc: [String: Any] = [
            "version": 2, "sourceTakeId": takes[0].id,
            "canvas": ["width": 1920, "height": 1080, "fps": 30, "background": "#000000"],
            "assets": assets,
            "tracks": [
                ["id": "main", "kind": "main", "items": main],
                ["id": "pipA", "kind": "video", "items": pips(0, 0.8)],
                ["id": "pipB", "kind": "video", "items": pips(1, 0.2)],
                ["id": "txtA", "kind": "text", "items": texts(0, 0.15)],
                ["id": "txtB", "kind": "text", "items": texts(2.5, 0.3)],
                ["id": "cap", "kind": "caption", "items": [], "caption": ["asset": "a0", "words": words, "style": capStyle]],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: doc) else { return nil }
        return try? JSONDecoder().decode(EditV2.Project.self, from: data)
    }

    /// WindowServer's CPU and VTDecoderXPCService's CPU and memory right now (what the owner saw in Activity Monitor).
    static func systemLoad() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "%cpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "ps unavailable" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var ws = 0.0, vtCPU = 0.0, vtKB = 0, vtCount = 0
        for row in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let cpu = Double(f[0]), let rss = Int(f[1]) else { continue }
            if f[2].hasSuffix("WindowServer") { ws += cpu }
            if f[2].contains("VTDecoderXPCService") { vtCPU += cpu; vtKB += rss; vtCount += 1 }
        }
        return String(format: "WindowServer %.0f %%, VTDecoderXPCService ×%d %.0f %% %d MB", ws, vtCount, vtCPU, vtKB / 1024)
    }

    /// The main thread's own frames (the MUSE binary's) in a `sample` report, heaviest first, one line each.
    static func museFrames(_ url: URL, count: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ["(no sample)"] }
        let all = text.components(separatedBy: "\n")
        guard let start = all.firstIndex(where: { $0.contains("com.apple.main-thread") || $0.contains(": Main Thread") }) else {
            return ["(no main thread in the sample)"]
        }
        // The main thread's tree ends at the next thread header ("<n> Thread_…").
        var end = all.count
        for j in (start + 1)..<all.count where all[j].range(of: #"^\s+\d+ Thread_"#, options: .regularExpression) != nil { end = j; break }
        var best: [String: Int] = [:]
        for l in all[(start + 1)..<end] where l.contains("(in MUSE)") {
            let t = l.drop { " +!:|".contains($0) }
            guard let sp = t.firstIndex(of: " "), let n = Int(t[..<sp]) else { continue }
            let rest = t[t.index(after: sp)...]
            let sym = String((rest.range(of: " (in MUSE)").map { rest[..<$0.lowerBound] } ?? rest).prefix(160))
            best[sym] = max(best[sym] ?? 0, n)
        }
        let top = best.sorted { $0.value > $1.value }.prefix(count).map { "\($0.value) \($0.key)" }
        return top.isEmpty ? ["(no MUSE frames on the main thread: it was idle)"] : top
    }
}
