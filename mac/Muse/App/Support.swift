import AppKit
import AVFoundation
import MuseCore
import UniformTypeIdentifiers
import UserNotifications

/// Native notifications when a mock job finishes or fails.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var authorized = false

    func requestAuthorization() {
        // UNUserNotificationCenter needs a real app bundle (it crashes in a bare test host).
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in self.authorized = ok }
    }

    func post(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Show banners even while MUSE is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Small interface sounds, a different set per theme (system sounds; no audio files bundled).
enum Sounds {
    enum Kind { case tap, nav, go, done, tick, theme, error }
    static var enabled = true
    static var theme: ThemeID = .a

    static func play(_ k: Kind) {
        guard enabled else { return }
        let name: String
        switch (k, theme) {
        case (.tap, _), (.tick, _): return // keep clicks silent; only meaningful moments make a sound
        case (.nav, .b): name = "Tink"
        case (.nav, _): return
        case (.go, .a): name = "Pop"
        case (.go, .b): name = "Morse"
        case (.go, .c): name = "Bottle"
        case (.go, .d): name = "Hero"
        case (.done, .a), (.done, .c): name = "Glass"
        case (.done, .b): name = "Ping"
        case (.done, .d): name = "Funk"
        case (.theme, _): name = "Submarine"
        case (.error, _): name = "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

enum MediaImport {
    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .webP, .image]
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    @MainActor
    static func pick(_ types: [UTType], multiple: Bool, prompt: String = "Choose") -> [URL] {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = multiple
        p.canChooseDirectories = false
        p.prompt = prompt
        return p.runModal() == .OK ? p.urls : []
    }

    static func isImage(_ url: URL) -> Bool { (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false }
    static func isVideo(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .movie) || t.conforms(to: .video)
    }

    /// Bytes and MIME type for upload. Large images are re-encoded as JPEG to keep uploads small.
    static func imagePayload(_ url: URL) throws -> (Data, String) {
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        if data.count > 6_000_000 || type == .heic || type == .tiff, let img = NSImage(data: data), let jpeg = jpegData(img, maxSide: 2048) {
            return (jpeg, "image/jpeg")
        }
        return (data, type?.preferredMIMEType ?? "image/jpeg")
    }

    static func jpegData(_ img: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    /// Reads duration, size and frame rate with AVFoundation and grabs a poster frame.
    /// People and watermark detection happen on the server (mocked there), so they are left at their defaults.
    static func clipInfo(_ url: URL) async throws -> (ClipMeta, URL?) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ApiError("bad_clip", "That file has no video track")
        }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        let w = Int(abs(r.width).rounded()), h = Int(abs(r.height).rounded())
        let meta = ClipMeta(name: url.deletingPathExtension().lastPathComponent, durationSec: (duration * 10).rounded() / 10, width: w, height: h,
                            fps: Int(fps.rounded()))
        var thumbURL: URL?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        if let frame = try? await gen.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)),
           let jpeg = NSBitmapImageRep(cgImage: frame.image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("muse-clip-\(UUID().uuidString).jpg")
            try? jpeg.write(to: f)
            thumbURL = f
        }
        return (meta, thumbURL)
    }

    /// Sorts dropped reference images into character-sheet slots by file name ("face", "profile", "back"…), then fills the rest in order.
    static func sortIntoSlots(_ urls: [URL], free: [SheetAngle]) -> [(SheetAngle, URL)] {
        let hints: [(SheetAngle, [String])] = [
            (.profile, ["profile", "side-face", "sideface"]), (.face, ["face", "headshot", "portrait", "closeup", "close-up"]),
            (.back, ["back", "rear", "behind"]), (.tq, ["34", "3-4", "three", "quarter", "tq"]), (.side, ["side"]), (.front, ["front", "full", "body"]),
        ]
        var open = free
        var out: [(SheetAngle, URL)] = []
        var rest: [URL] = []
        for u in urls {
            let n = u.deletingPathExtension().lastPathComponent.lowercased()
            if let hit = hints.first(where: { h in open.contains(h.0) && h.1.contains { n.contains($0) } }) {
                out.append((hit.0, u))
                open.removeAll { $0 == hit.0 }
            } else {
                rest.append(u)
            }
        }
        for u in rest {
            guard let next = open.first else { break }
            out.append((next, u))
            open.removeFirst()
        }
        return out
    }
}

/// Window-level keys the menus don't cover: Esc closes overlays, ↑/↓/↩ drive the palette, ←/→ change steps in the video studio.
@MainActor
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var token: Any?

    func install(_ store: AppStore) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] e in
            guard let store else { return e }
            let handled = MainActor.assumeIsolated { store.handleKey(e) }
            return handled ? nil : e
        }
    }
}

extension AppStore {
    /// Returns true when the key was handled.
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let typing = NSApp.keyWindow?.firstResponder is NSTextView
        switch e.keyCode {
        case 53: // Esc
            if paletteOpen { closePalette(); return true }
            if outfitSheet != nil { outfitSheet = nil; return true }
            if comparing { comparing = false; return true }
            if toast != nil { toast = nil; return true }
            return false
        case 126, 125: // ↑ ↓
            guard paletteOpen else { return false }
            let n = paletteCommands.count
            if n > 0 { paletteIndex = (paletteIndex + (e.keyCode == 125 ? 1 : -1) + n) % n }
            return true
        case 36, 76: // Return
            if paletteOpen && mods.isEmpty { runPalette(paletteIndex); return true }
            return false
        case 123, 124: // ← →
            guard !typing, mods.isEmpty, user != nil, screen == .studio, engine == .h3, !paletteOpen, outfitSheet == nil else { return false }
            setSteps(steps + (e.keyCode == 124 ? 1 : -1))
            return true
        default:
            return false
        }
    }
}
