import AppKit
import MuseCore
import SwiftUI

/// Edit pipeline skill in Settings (owner idea 2026-11-16): Settings → Account → Claude scrolled to "Edit pipeline skill"
/// at 1000 × 700, with the demo skill (FakeClaudeAPI): version 3, a small change in the changelog and a big change waiting
/// (Approve / Decline, before struck through). Fit check: the heading, the waiting change and its buttons, and each
/// version's Roll back sit whole inside the window. Shots `mac_<theme>_pipeline_skill_settings.png` (A and C). Writes
/// `pipeline-skill-check.txt`; CI fails on any FAIL line or a missing ALL DONE.
extension SnapshotRunner {
    static func pipelineSkillCheck(_ store: AppStore, dir: URL) async {
        let log = dir.appendingPathComponent("pipeline-skill-check.txt")
        try? Data().write(to: log)
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("pipeline-skill-check: \(s)")
        }
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            note(ok ? "DONE \(name)" : "FAIL \(name)\(detail().isEmpty ? "" : ": \(detail())")")
        }
        func wait(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
            return ok()
        }
        guard let w = mainWindow else { note("FAIL no window"); note("ALL DONE"); return }
        note("START setup")
        _ = await wait(15) { ClaudeCodeService.shared.configured }
        guard let api = ClaudeCodeService.shared.api as? any PipelineSkillAPI else {
            note("FAIL the Claude API has no pipeline skill calls"); note("ALL DONE"); return
        }
        let skill = try? await api.pipelineSkill()
        check("demo_skill", skill?.pending.count == 1 && (skill?.version ?? 0) >= 3, "version \(skill?.version ?? 0), waiting \(skill?.pending.count ?? -1)")
        let versions = (try? await api.pipelineVersions()) ?? []
        check("demo_changelog_small", versions.contains { $0.changelog.contains { $0.kind == "small" } }, "\(versions.map(\.version))")

        let full = w.frame
        w.setFrame(NSRect(x: full.minX, y: full.maxY - 700, width: 1000, height: 700), display: true)
        defer { w.setFrame(full, display: true); state.scrollTo = nil; store.themeID = .a }
        store.oneClaude.open = false
        for theme in [ThemeID.a, .c] {
            note("START settings \(theme.rawValue)")
            store.themeID = theme
            store.openSettings(.account)
            try? await Task.sleep(for: .seconds(1.5))
            state.scrollTo = nil
            try? await Task.sleep(for: .seconds(0.3))
            state.scrollTo = "settings.claude.pipeline"
            try? await Task.sleep(for: .seconds(1.5))
            state.probeTick += 1
            try? await Task.sleep(for: .seconds(0.5))
            let frames = state.composerFrames
            let height = w.contentView?.bounds.height ?? 0, width = w.contentView?.bounds.width ?? 0
            func fits(_ key: String) -> (Bool, String) {
                guard let f = frames[key] else { return (false, "not drawn; pipeline frames \(frames.keys.filter { $0.hasPrefix("pipeline") }.sorted())") }
                return (f.width > 10 && f.height > 0 && f.minX >= 0 && f.maxX <= width && f.minY >= 0 && f.maxY <= height,
                        "at x \(Int(f.minX))–\(Int(f.maxX)), y \(Int(f.minY))–\(Int(f.maxY)) in \(Int(width)) × \(Int(height))")
            }
            for key in ["pipeline heading", "pipeline undo", "pipeline pending pp_demo1", "pipeline approve", "pipeline decline"] {
                let r = fits(key)
                check("\(theme.rawValue)_fits_\(key.replacingOccurrences(of: " ", with: "_"))", r.0, r.1)
            }
            // Each older version's Roll back that is drawn on screen sits whole (the list runs on below the window).
            for v in versions.dropFirst() {
                if let f = frames["pipeline rollback \(v.version)"], f.maxY <= height {
                    check("\(theme.rawValue)_rollback_\(v.version)_whole", f.minX >= 0 && f.maxX <= width, "at x \(Int(f.minX))–\(Int(f.maxX)) in \(Int(width))")
                }
            }
            capture(dir.appendingPathComponent("mac_\(theme.rawValue)_pipeline_skill_settings.png"))
        }
        note("ALL DONE")
    }
}
