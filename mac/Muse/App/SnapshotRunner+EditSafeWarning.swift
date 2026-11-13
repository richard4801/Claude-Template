import AppKit
import Foundation
import MuseCore

// Edit's safe-area warning line on camera (coordinator, run 595: the review take had no captions, so the warning never
// showed). A stand-in take with word captions placed low on the frame (y 0.86, under TikTok's caption and buttons), the
// TikTok view with its red box, at 1440 × 900 and 1280 × 800, light and dark:
//   mac_editpreview_warning_<a|b>_<w>x<h>.png
// The warning line ("Captions sit under TikTok's caption and buttons (…)") and its "Move into the safe area" must be drawn
// and whole: FITS or CUT lines in fit-check.txt (a CUT fails Mac CI). The line sits under the viewer on the page
// background, never over the picture (Android's pill over the stage had to be made opaque).
extension SnapshotRunner {
    /// Posted to Edit's preview in review mode: give the open edit word captions low on the frame.
    static let reviewLowCaptions = Notification.Name("muse.review.edit.lowCaptions")

    static func editSafeWarningShots(_ store: AppStore, dir: URL) async {
        var lines: [String] = []
        defer {
            let f = dir.appendingPathComponent("fit-check.txt")
            let before = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? (before + lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: f, atomically: true, encoding: .utf8)
        }
        // editCheck's 15 s stereo take (its MP4 stays in the temporary folder), as the Edit layout shots use.
        let long = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check/long.mp4")
        guard FileManager.default.fileExists(atPath: long.path), let w = mainWindow else {
            lines.append("CUT edit safe warning not drawn (no test video or window)")
            return
        }
        let raw: [String: Any] = ["id": "rx_safewarn", "kind": "take", "title": "Kitchen order", "videoUrl": long.absoluteString,
                                  "durationSec": 15, "width": 432, "height": 768, "fps": 30, "createdAt": Int64(Date().timeIntervalSince1970 * 1000)]
        guard let data = try? JSONSerialization.data(withJSONObject: raw), let take = try? JSONDecoder().decode(Take.self, from: data) else { return }
        defer { store.takes.removeAll { $0.id == take.id } }
        let original = w.frame
        for theme in [ThemeID.a, .b] {
            store.themeID = theme
            state.editPreview = nil
            state.claudeTab = nil
            if !store.takes.contains(where: { $0.id == take.id }) { store.takes.insert(take, at: 0) }
            store.openEdit(takeId: take.id)
            try? await Task.sleep(for: .seconds(8))
            state.editPreview = EditPreview(view: .tiktok, safeArea: true)
            NotificationCenter.default.post(name: reviewLowCaptions, object: nil)
            try? await Task.sleep(for: .seconds(1.5))
            for (width, height) in [(1440, 900), (1280, 800)] {
                NSLog("[snapshot] edit safe warning %dx%d %@", width, height, theme.rawValue)
                w.setFrame(NSRect(x: original.minX, y: original.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
                try? await Task.sleep(for: .seconds(1.5))
                capture(dir.appendingPathComponent("mac_editpreview_warning_\(theme.rawValue)_\(width)x\(height).png"))
                let probes = fitProbes.values.filter { $0.name.hasPrefix("safe warning") }
                let cut = truncatedLabels().filter { $0.hasPrefix("safe warning") }
                let label = "edit safe warning \(width)x\(height) \(theme.rawValue)"
                if probes.count < 2 {
                    lines.append("CUT \(label): the warning line wasn't drawn (\(probes.count) of 2 parts)")
                } else if cut.isEmpty {
                    lines.append("FITS \(label) (line and fix whole)")
                } else {
                    lines.append(contentsOf: cut.map { "CUT \(label) \($0)" })
                }
            }
            state.editPreview = nil
            w.setFrame(original, display: true)
            store.openEdit(takeId: nil)
            try? await Task.sleep(for: .seconds(1))
        }
        store.themeID = .a
    }
}
