import AppKit
import AVFoundation
import MuseCore

/// A video picked for a Claude chat message (plans/claude-video-vision.md): its length, size and frame rate (the upload's
/// clip meta) and a poster frame at about half a second; and the picture its bubble shows once sent.
enum ChatVideoProbe {
    struct Info: Sendable {
        var seconds: Double
        var width: Int
        var height: Int
        var fps: Int
        /// PNG, empty when no frame could be read.
        var poster: Data

        func meta(name: String) -> ClipMeta {
            ClipMeta(name: String(name.prefix(200)), durationSec: seconds, width: width, height: height, fps: fps)
        }
    }

    /// nil when the file isn't a readable video.
    static func read(_ url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first else { return nil }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let rate = (try? await track.load(.nominalFrameRate)) ?? 0
        let shown = natural.applying(transform)
        let width = max(1, Int(abs(shown.width).rounded()))
        let height = max(1, Int(abs(shown.height).rounded()))
        let fps = max(1, Int(Double(rate).rounded()))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let at = CMTime(seconds: min(0.5, seconds / 2), preferredTimescale: 600)
        var poster = Data()
        if let frame = try? await generator.image(at: at).image {
            poster = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) ?? Data()
        }
        return Info(seconds: seconds, width: width, height: height, fps: fps, poster: poster)
    }

    /// The bubble's picture of a sent video: its poster frame (or a plain tile that says "Video") with its length in the
    /// corner. PNG.
    static func chip(poster: Data, seconds: Double) -> Data {
        let side: CGFloat = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return poster }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let box = NSRect(x: 0, y: 0, width: side, height: side)
        if let img = NSImage(data: poster), img.size.width > 0, img.size.height > 0 {
            // Fill the square, cropped from the middle.
            let scale = max(side / img.size.width, side / img.size.height)
            let w = side / scale, h = side / scale
            let from = NSRect(x: (img.size.width - w) / 2, y: (img.size.height - h) / 2, width: w, height: h)
            img.draw(in: box, from: from, operation: .copy, fraction: 1)
        } else {
            NSColor(white: 0.22, alpha: 1).setFill()
            box.fill()
            let word = NSAttributedString(string: "Video", attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium),
                                                                         .foregroundColor: NSColor(white: 0.9, alpha: 1)])
            let ws = word.size()
            word.draw(at: NSPoint(x: (side - ws.width) / 2, y: (side - ws.height) / 2))
        }
        if seconds > 0 {
            let label = NSAttributedString(string: ClaudeAttachmentPrompt.length(seconds),
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                                                        .foregroundColor: NSColor.white])
            let ls = label.size()
            let pill = NSRect(x: 6, y: 6, width: ls.width + 10, height: ls.height + 2)
            NSColor(white: 0, alpha: 0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 1))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? poster
    }
}
