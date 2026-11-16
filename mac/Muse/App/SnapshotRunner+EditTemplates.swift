import AppKit
import Foundation
import MuseCore
import SwiftUI

// Edit templates on camera (plans/edit-templates.md §5, mockups 1, 2 and 4; Mac integrator, run 694: the review took no
// shot of the new UI). In review mode, through the real Edit page on a stand-in take, with the demo library
// (FakeEditTemplateAPI: a ready transition, a ready effect, a paid one, a not-ready one):
//   mac_a_edit_templates_library.png   the Templates tab: search, filters, "Made by Claude", caption styles
//   mac_a_edit_template_inspector.png  a picked template: Applies to, its settings, Apply
//   mac_a_edit_template_save.png       Save as template (the sheet)
//   mac_a_edit_template_not_ready.png  Glass shatter: the reason and "Ask Claude to make it for this cut" (and mac_b_…, mockup 2)
// Checks (edit-templates-check.txt; CI fails on any FAIL line or a missing ALL DONE): the library shows its sections, a
// preview doesn't change the saved project, Apply sends exactly one apply, the Save sheet opens, Ask Claude prepares the
// request. Fit (fit-check.txt): the inspector's buttons whole at 1000 × 700 (FITS / CUT).
extension SnapshotRunner {
    /// Where probed parts of the template inspector sit in the window (EditSuiteTemplates.swift `templateFrame`).
    static var templateFrames: [String: CGRect] = [:]

    static func editTemplatesCheck(_ store: AppStore, dir: URL) async {
        let log = dir.appendingPathComponent("edit-templates-check.txt")
        try? Data().write(to: log)
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("edit-templates-check: \(s)")
        }
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            note(ok ? "DONE \(name)" : "FAIL \(name)\(detail().isEmpty ? "" : ": \(detail())")")
        }
        func wait(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if ok() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
            return ok()
        }
        /// A probed part is on screen without scrolling: inside the window's content (SwiftUI global frames are top-left).
        func onScreen(_ name: String, _ w: NSWindow) -> (Bool, String) {
            guard let r = templateFrames[name] else { return (false, "\(name) not drawn") }
            let h = w.contentView?.bounds.height ?? 0
            return (r.minY >= 0 && r.maxY <= h, "\(name) at y \(Int(r.minY))–\(Int(r.maxY)) of \(Int(h)) pt")
        }
        /// The inspector's title is whole: drawn at ≥ 60 % of its one-line width (it may wrap to two lines).
        func titleWhole() -> (Bool, String) {
            guard let p = fitProbes.values.first(where: { $0.name == "template title" }), p.ideal > 0 else { return (false, "title not drawn") }
            return (p.drawn >= 0.6 * p.ideal, "title \(Int(p.drawn)) of \(Int(p.ideal)) pt")
        }
        var fit: [String] = []
        defer {
            let f = dir.appendingPathComponent("fit-check.txt")
            let before = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? (before + fit.joined(separator: "\n") + (fit.isEmpty ? "" : "\n")).write(to: f, atomically: true, encoding: .utf8)
        }
        guard let fake = store.api as? FakeMuseAPI, let w = mainWindow else { note("FAIL not in demo mode (or no window)"); note("ALL DONE"); return }
        store.themeID = .a
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let clip = media.appendingPathComponent("templates.mp4")
        do { try await makeVideo(clip, seconds: 9, fps: 30, width: 360, height: 640, audio: (48_000, 2)) } catch {
            note("FAIL making the test video: \(error.localizedDescription)"); note("ALL DONE"); return
        }
        let raw: [String: Any] = ["id": "rz_templates", "kind": "take", "title": "Templates walk", "videoUrl": clip.absoluteString, "durationSec": 9,
                                  "width": 360, "height": 640, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
        guard let data = try? JSONSerialization.data(withJSONObject: raw), let take = try? JSONDecoder().decode(Take.self, from: data) else {
            note("FAIL decoding the test take"); note("ALL DONE"); return
        }
        store.takes.removeAll { $0.id == take.id }
        store.takes.insert(take, at: 0)
        await fake.adoptTakes([take])
        defer { store.takes.removeAll { $0.id == take.id } }

        store.closeRecreate()
        store.oneClaude.open = false
        state.overlay = nil
        let original = w.frame
        w.setFrame(NSRect(x: original.minX, y: original.maxY - 900, width: 1440, height: 900), display: true)
        note("START open_edit")
        store.openEdit(takeId: take.id)
        guard await wait(25, { store.suite.editCurrent?.isReady == true && store.suite.editCurrent?.take.id == take.id }),
              let s = store.suite.editCurrent else {
            note("FAIL open_edit: the editor didn't open (\(String(describing: store.suite.editCurrent?.phase)))"); note("ALL DONE")
            w.setFrame(original, display: true); return
        }
        _ = await wait(15) { s.live != nil }
        check("owner_live", s.isOwner && s.live != nil, "owner \(s.isOwner), live session \(s.live != nil)")
        // Three clips, so there are cuts to put a transition on.
        _ = s.edit { $0.playhead = 3; return $0.split() }
        _ = s.edit { $0.playhead = 6; return $0.split() }
        check("three_clips", s.project.mainClips.count == 3, "\(s.project.mainClips.count) clips")

        // 1. The library.
        note("START library")
        s.binTab = .templates
        _ = await wait(10) { s.templates.load == .loaded }
        let sections = s.templates.library.sections(filter: .all, query: "")
        check("library_sections", s.templates.load == .loaded && sections.contains { $0.title == "Made by Claude" } && !s.templates.library.captionStyles.isEmpty,
              "load \(s.templates.load), sections \(sections.map(\.title)), caption styles \(s.templates.library.captionStyles.count)")
        try? await Task.sleep(for: .seconds(1.5))
        capture(dir.appendingPathComponent("mac_a_edit_templates_library.png"))

        // 2. A picked template: previewed on the edit (nothing saved), its settings in the inspector.
        note("START inspector")
        let saved = s.project, revision = s.live?.revision
        let second = s.project.mainClips[1].id
        s.view { $0.selection = second }
        guard let window = s.templates.library.templates.first(where: { $0.id == "window-open-next" }) else {
            note("FAIL inspector: the demo library has no window-open-next"); note("ALL DONE"); w.setFrame(original, display: true); return
        }
        s.pickTemplate(window)
        _ = await wait(10) { !s.templates.previewing && s.templates.picked == window.id }
        try? await Task.sleep(for: .seconds(1))
        check("preview_saves_nothing", s.project == saved && s.live?.revision == revision, "project changed \(s.project != saved), revision \(String(describing: revision)) → \(String(describing: s.live?.revision))")
        let target = s.templateTarget
        check("applies_to_the_cut_before_the_selection", target?.target == .cutAfter(s.project.mainClips[0].id), "target \(String(describing: target?.target))")
        s.notice = nil
        try? await Task.sleep(for: .milliseconds(500))
        capture(dir.appendingPathComponent("mac_a_edit_template_inspector.png"))
        let (tw, td) = titleWhole()
        check("inspector_title_whole", tw, td)
        let (av, ad) = onScreen("applies to", w)
        check("applies_to_on_screen_1440x900", av, ad)
        // Fit: the inspector's title, Applies to and the two Apply buttons whole at 1000 × 700 (the media panel folds away).
        for (width, height) in [(1440, 900), (1000, 700)] {
            w.setFrame(NSRect(x: original.minX, y: original.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
            try? await Task.sleep(for: .seconds(1.5))
            let label = "edit template inspector \(width)x\(height)"
            let apply = fitProbes.values.filter { $0.name.hasPrefix("Apply to") }
            let cut = truncatedLabels().filter { $0.hasPrefix("Apply") || $0.hasPrefix("segment Box") || $0.hasPrefix("segment Band") || $0.hasPrefix("segment Column") || $0.hasPrefix("segment Slats") }
            let (whole, why) = titleWhole()
            if !whole { fit.append("CUT \(label) template title (\(why))") }
            if apply.isEmpty { fit.append("CUT \(label): Apply wasn't drawn") }
            else if cut.isEmpty { fit.append("FITS \(label) (Apply, Apply to every cut, the shape segments)") }
            else { fit.append(contentsOf: cut.map { "CUT \(label) \($0)" }) }
            if width == 1000 { capture(dir.appendingPathComponent("mac_a_edit_template_inspector_1000x700.png")) }
        }
        w.setFrame(NSRect(x: original.minX, y: original.maxY - 900, width: 1440, height: 900), display: true)
        try? await Task.sleep(for: .seconds(1))

        // 3. Apply: one apply call with this cut and the settings (the demo's fake records it).
        note("START apply")
        let before = EditSuiteSession.fakeTemplates.applied.count
        await s.applyTemplate()
        let sent = EditSuiteSession.fakeTemplates.applied.dropFirst(before)
        check("apply_sends_one_change", sent.count == 1 && sent.first?.id == window.id && sent.first?.req.dryRun == false,
              "\(sent.count) apply call(s): \(sent.map { "\($0.id) dryRun \($0.req.dryRun)" })")
        check("apply_clears_the_preview", s.templates.previewOf == nil, "still previewing \(String(describing: s.templates.previewOf))")

        // 4. Save as template: the sheet opens on the selected clip.
        note("START save")
        s.notice = nil
        s.view { $0.selection = second }
        check("can_save", s.canSaveTemplate, "selection \(String(describing: s.state.selection)), live \(s.live != nil)")
        s.templates.saving = true
        try? await Task.sleep(for: .seconds(1.5))
        check("save_sheet_opens", w.attachedSheet != nil || NSApp.windows.contains { $0.isSheet && $0.isVisible }, "no sheet on the window")
        // The sheet is its own window (review run 700: the window shot missed it): its content, else the view drawn alone.
        let shot = dir.appendingPathComponent("mac_a_edit_template_save.png")
        if let sheet = w.attachedSheet, let v = sheet.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: shot)
            check("save_sheet_shot", true)
        } else {
            let r = ImageRenderer(content: EditSaveTemplateSheet(session: s).environment(\.theme, store.theme))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: shot)
                check("save_sheet_shot", true)
            } else { check("save_sheet_shot", false, "couldn't draw the sheet") }
        }
        capture(dir.appendingPathComponent("mac_a_edit_template_save_window.png"))
        s.templates.saving = false
        try? await Task.sleep(for: .seconds(1))

        // 5. Not ready: the reason and Ask Claude (it prepares the request; the owner sends it).
        note("START not_ready")
        if let glass = s.templates.library.templates.first(where: { !$0.isReady }) {
            s.notice = nil
            s.pickTemplate(glass)
            try? await Task.sleep(for: .seconds(1.5))
            let (askOn, askWhy) = onScreen("ask claude", w)
            check("ask_claude_on_screen_1440x900", askOn, askWhy)
            capture(dir.appendingPathComponent("mac_a_edit_template_not_ready.png"))
            // Mockup 2 shows this state in theme B (dark).
            store.themeID = .b
            try? await Task.sleep(for: .seconds(1.5))
            capture(dir.appendingPathComponent("mac_b_edit_template_not_ready.png"))
            store.themeID = .a
            try? await Task.sleep(for: .seconds(1))
            s.askClaudeToMake(glass)
            check("ask_claude_prepares_the_request", s.claudeAsk?.contains(glass.id) == true && s.claudeAsk?.contains("template_pack_read") == true,
                  "claudeAsk \(String(describing: s.claudeAsk))")
            try? await Task.sleep(for: .seconds(1.5))
            s.claudeAsk = nil
            s.closeTemplate()
        } else {
            check("not_ready_template", false, "the demo library has no not-ready template")
        }

        s.binTab = .takes
        w.setFrame(original, display: true)
        store.openEdit(takeId: nil)
        try? await Task.sleep(for: .seconds(1))
        note("ALL DONE")
    }
}
