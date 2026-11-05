import AppKit
import AVFoundation
import MuseCore
import UniformTypeIdentifiers
import UserNotifications

/// Native notifications: finished and failed jobs, low balance, a trained LoRA, and scheduled posts.
/// Every notification uses `UNNotificationSound.default`, also while MUSE is in front.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    private var authorized = false
    /// Called on the main actor when the user clicks a scheduled-post notification.
    var onOpenPost: (@MainActor (String) -> Void)?

    /// UNUserNotificationCenter needs a real app bundle (it crashes in a bare test host).
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        // Older builds registered a warm-GPU warning category; there are no actionable categories any more.
        c.setNotificationCategories([])
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in self.authorized = ok }
    }

    func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Stage 1 scheduling: a notification at the chosen time; clicking it opens the post handoff.
    func schedulePost(id: String, title: String, body: String, at date: Date) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        content.userInfo = ["postId": id]
        let trigger: UNNotificationTrigger
        if date.timeIntervalSinceNow > 1 {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "post-\(id)", content: content, trigger: trigger))
    }

    func cancelPost(id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["post-\(id)"])
    }

    /// Show banners with the default notification sound even while MUSE is the active app.
    /// Notifications are the only thing in MUSE that makes a sound.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// System Settings → Notifications, where the user chooses MUSE's alert style and sound.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["postId"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                MainActor.assumeIsolated { self.onOpenPost?(id) }
            }
        }
        completionHandler()
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
            (.profile, ["profile", "side-face", "sideface"]), (.faceTq, ["face34", "face-34", "face_34", "facetq", "face-tq", "face_tq", "face-quarter"]), (.face, ["face", "headshot", "portrait", "closeup", "close-up"]),
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

/// Window-level keys the menus don't cover: Esc closes overlays, ↑/↓/↩ drive the palette.
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
        switch e.keyCode {
        case 53: // Esc
            if warmPrompt != nil { answerWarmPrompt(turnOn: false); return true }
            if paletteOpen { closePalette(); return true }
            if outfitSheet != nil { outfitSheet = nil; return true }
            if postDraft != nil { postDraft = nil; return true }
            if comparing { comparing = false; return true }
            if toast != nil { toast = nil; return true }
            return false
        case 126, 125: // ↑ ↓
            guard paletteOpen else { return false }
            let n = paletteCommands.count
            if n > 0 { paletteIndex = (paletteIndex + (e.keyCode == 125 ? 1 : -1) + n) % n }
            return true
        case 36, 76: // Return
            if warmPrompt != nil { return true } // spending needs a click on "Keep it ready", not a stray Return
            if paletteOpen && mods.isEmpty { runPalette(paletteIndex); return true }
            return false
        default:
            return false
        }
    }
}
