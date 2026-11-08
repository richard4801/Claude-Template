import AVFoundation
import AppKit
import CoreGraphics

// Review mode (SnapshotRunner.recreateShots): a patterned demo take for Recreate's built edit, and a check that a rendered
// frame has picture detail (not a flat fill).
extension SnapshotRunner {
    /// Diagonal stripes with a light square that moves left to right, the colours drifting over time (H.264, no sound).
    static func writePatternVideo(_ url: URL, seconds: Double, fps: Int32, width w: Int, height h: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        let side = w / 3
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                let row = CVPixelBufferGetBytesPerRow(pb)
                let p = Double(i) / Double(max(1, frames - 1))
                let sx = Int(p * Double(w - side)), sy = h / 2 - side / 2
                for y in 0..<h {
                    let line = base + y * row
                    for x in 0..<w {
                        let stripe = ((x + y + i * 4) / 24) % 2 == 0
                        var r = stripe ? 200 : 60, g = stripe ? 120 + Int(p * 100) : 40, b = stripe ? 80 : 150 - Int(p * 80)
                        if x >= sx && x < sx + side && y >= sy && y < sy + side { r = 245; g = 235; b = 210 }
                        line[x * 4] = UInt8(clamping: b)
                        line[x * 4 + 1] = UInt8(clamping: g)
                        line[x * 4 + 2] = UInt8(clamping: r)
                        line[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// The spread of a frame's brightness (0–255 standard deviation over a 64 × 64 sample): about 0 for a flat fill.
    static func frameDetail(_ img: CGImage) -> Double {
        let n = 64
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return 0 }
        var lum: [Double] = []
        for k in 0..<(n * n) { lum.append(0.299 * Double(px[k * 4]) + 0.587 * Double(px[k * 4 + 1]) + 0.114 * Double(px[k * 4 + 2])) }
        let mean = lum.reduce(0, +) / Double(lum.count)
        return (lum.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lum.count)).squareRoot()
    }
}
