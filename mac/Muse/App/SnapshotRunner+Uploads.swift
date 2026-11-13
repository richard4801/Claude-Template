import AppKit
import AVFoundation
import MuseCore
import SwiftUI

/// Edit → Uploads as a media bin (owner, 2026-11-12; mockups plans/design/edit-panels/uploads-{b,a}.png): the media panel
/// drawn on its own at its real size (304 × 760 pt), empty and with six uploads of mixed kinds (three videos, a picture,
/// a song, a short sound), in Camera Body and Editorial: `mac_edit_uploads_{empty,filled}_{b,a}.png`. The six go in
/// through the panel's own path (addFiles, as Add → From this Mac and a drop do), then "+" on a video is checked to put
/// it into the sequence and undone. Runs inside editCheck, while its rx_* takes and test files exist.
extension SnapshotRunner {
    static func uploadsShots(_ store: AppStore, media: URL, dir: URL, note: (String) -> Void) async {
        note("START uploads_bin")
        guard let s = store.makeEditSuiteSession(takeId: "rx_full") else { note("FAIL uploads_bin: no editor session"); return }
        await s.load()
        defer { s.close() }
        s.binTab = .uploads
        for theme in [ThemeID.b, .a] { await drawBin(s, store: store, theme: theme, to: dir.appendingPathComponent("mac_edit_uploads_empty_\(theme.rawValue).png")) }
        if !s.uploads.isEmpty { note("FAIL uploads_bin: a new edit's Uploads isn't empty (\(s.uploads.count))") }

        let picture = media.appendingPathComponent("Studio logo.png"), song = media.appendingPathComponent("Night drive.m4a")
        let blip = media.appendingPathComponent("Click.m4a")
        do {
            try writePicture(picture)
            try writeTone(song, seconds: 40, rate: 44_100, channels: 2)
            try writeTone(blip, seconds: 1.5, rate: 48_000, channels: 1)
        } catch {
            note("FAIL uploads_bin: test files (\(error.localizedDescription))")
            return
        }
        let videos = ["short.mp4", "long.mp4", "turned.mp4"].map { media.appendingPathComponent($0) }
        let mainBefore = s.project.mainClips.count
        await s.addFiles([videos[0], picture, song, videos[1], blip, videos[2]])
        let items = s.uploads
        let chips = EditSuite.UploadBin.filters(items)
        if items.count != 6 { note("FAIL uploads_bin: \(items.count) uploads after adding 6 (\(s.lastError ?? "no error"))") }
        if chips != [.all, .video, .pictures, .audio] { note("FAIL uploads_bin: chips \(chips.map(\.label))") }
        if s.project.mainClips.count != mainBefore { note("FAIL uploads_bin: adding files placed something (\(s.project.mainClips.count) main clips)") }
        for theme in [ThemeID.b, .a] { await drawBin(s, store: store, theme: theme, to: dir.appendingPathComponent("mac_edit_uploads_filled_\(theme.rawValue).png")) }

        // "+" on a video: into the sequence at the playhead, one undo step.
        if let v = items.first(where: { $0.kind == .video }) {
            let before = s.project.mainClips.count
            s.placeUpload(v.id)
            if s.project.mainClips.count != before + 1 { note("FAIL uploads_bin: + didn't place the video") }
            s.undo()
            if s.project.mainClips.count != before { note("FAIL uploads_bin: undo after + left \(s.project.mainClips.count) clips") }
        }
        note("DONE uploads_bin (\(items.count) uploads, chips \(chips.map(\.label).joined(separator: " ")))")
    }

    /// The panel alone in an off-screen window, drawn from its view (the window can sit anywhere on the runner's screen).
    private static func drawBin(_ s: EditSuiteSession, store: AppStore, theme: ThemeID, to url: URL) async {
        let t = Theme.get(theme)
        let size = NSSize(width: EditSuiteEditor.mediaWidth, height: 760)
        let root = EditSuiteBin(session: s, hide: {})
            .frame(width: size.width, height: size.height)
            .environment(store)
            .environment(\.theme, t)
            .font(t.body(14))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        w.orderFrontRegardless()
        // Thumbnails and waveforms are read in the background.
        try? await Task.sleep(for: .seconds(2.5))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        w.orderOut(nil)
    }

    /// A 600 × 600 PNG: a soft square mark on a dark ground (a stand-in logo, no text).
    private static func writePicture(_ url: URL) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw ApiError("edit_check", "Couldn't make the test picture") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 600, height: 600).fill()
        NSColor(calibratedRed: 0.95, green: 0.66, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 170, y: 170, width: 260, height: 260), xRadius: 48, yRadius: 48).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ApiError("edit_check", "Couldn't make the test picture") }
        try data.write(to: url)
    }
}
