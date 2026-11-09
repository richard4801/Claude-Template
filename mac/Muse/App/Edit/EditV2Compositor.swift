import AppKit
import AVFoundation
import CoreImage
import MuseCore

/// One stretch of the timeline where the same source tracks play; every instruction shares the project's EditV2Scene.
final class EditV2Instruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackIDs: [CMPersistentTrackID]
    let scene: EditV2Scene

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], scene: EditV2Scene) {
        self.timeRange = timeRange
        self.trackIDs = trackIDs
        requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs.map { NSNumber(value: $0) }
        self.scene = scene
    }
}

/// The custom compositor: each frame is drawn by the instruction's scene with Core Image (background, main A/B layers
/// with their transition, overlays, pictures, text and captions) into a buffer from the render context.
class EditV2Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.muse.edit2.compositor", qos: .userInitiated)
    private let lock = NSLock()
    private var context: AVVideoCompositionRenderContext?
    private var generation = 0

    /// XL HDR export: the HDR subclass reads and writes 10-bit / half-float frames; this one 8-bit BGRA.
    class var hdr: Bool { false }
    private static let sdrFormats = [kCVPixelFormatType_32BGRA]
    private static let hdrSource = [kCVPixelFormatType_64RGBAHalf]
    private static let hdrOutput = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]

    #if compiler(>=6.0)
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.hdr ? Self.hdrSource : Self.sdrFormats]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.hdr ? Self.hdrOutput : Self.sdrFormats]
    }
    #else
    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.hdr ? Self.hdrSource : Self.sdrFormats]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.hdr ? Self.hdrOutput : Self.sdrFormats]
    }
    #endif
    var supportsWideColorSourceFrames: Bool { Self.hdr }
    var supportsHDRSourceFrames: Bool { Self.hdr }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        lock.lock()
        context = newRenderContext
        lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = gen != self.generation
            let ctx = self.context
            self.lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? EditV2Instruction, let ctx, let out = ctx.newPixelBuffer() else {
                request.finish(with: ApiError("edit_render_failed", "Couldn't draw a frame of this edit"))
                return
            }
            autoreleasepool { instruction.scene.render(request, into: out) }
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}

/// The compositor for HDR export (HEVC 10-bit HLG): HDR and wide-colour sources come in as half floats, frames go out as
/// 10-bit 4:2:0 tagged BT.2020 / HLG.
final class EditV2HDRCompositor: EditV2Compositor {
    override class var hdr: Bool { true }
}

/// Everything needed to draw any frame of one built project; thread-safe (preview and export may draw at once).
final class EditV2Scene: @unchecked Sendable {
    typealias E = EditV2
    let project: E.Project
    let plan: E.RenderPlan
    let laneTracks: [Int: CMPersistentTrackID]
    /// Remove background: the matte track of each lane, and the "<lane>/<itemId>" segments that have their matte there.
    let matteTracks: [Int: CMPersistentTrackID]
    let matted: Set<String>
    let sources: EditV2Engine.Sources
    let pages: [E.CaptionPage]
    let size: CGSize
    private let ci: CIContext
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var textCache: [String: CIImage] = [:]
    private var cubeCache: [E.Chroma: Data] = [:]
    /// The items' looks (filter stack) in Core Image.
    private let looks: EditV2LookRenderer
    /// Edit suite: false when captions go out as an .srt instead of being drawn.
    let burnCaptions: Bool
    /// XL HDR export: colour work on extended sRGB values (highlights above 1 survive the matrices), frames out in HLG.
    let hdr: Bool
    private let outSpace: CGColorSpace

    init(project: E.Project, plan: E.RenderPlan, laneTracks: [Int: CMPersistentTrackID], matteTracks: [Int: CMPersistentTrackID] = [:],
         matted: Set<String> = [], sources: EditV2Engine.Sources, burnCaptions: Bool = true, hdr: Bool = false) {
        self.burnCaptions = burnCaptions
        self.hdr = hdr
        outSpace = hdr ? (CGColorSpace(name: CGColorSpace.itur_2100_HLG) ?? CGColorSpace(name: CGColorSpace.sRGB)!) : CGColorSpace(name: CGColorSpace.sRGB)!
        self.matteTracks = matteTracks
        self.matted = matted
        self.project = project
        self.plan = plan
        self.laneTracks = laneTracks
        self.sources = sources
        pages = E.captionPages(project)
        size = CGSize(width: plan.width, height: plan.height)
        looks = EditV2LookRenderer(imported: sources.luts)
        // Colour work (the item matrices, the chroma cube, blending) on sRGB values, as the contract defines it.
        // HDR: the same sRGB primaries, extended (values beyond 0–1 kept), so the contract's maths is unchanged for SDR-range
        // colours; LUT looks still clip at 1.
        let working = hdr ? (CGColorSpace(name: CGColorSpace.extendedSRGB) ?? CGColorSpace(name: CGColorSpace.sRGB)!) : CGColorSpace(name: CGColorSpace.sRGB)!
        var opts: [CIContextOption: Any] = [.workingColorSpace: working, .outputColorSpace: outSpace]
        if hdr { opts[.workingFormat] = NSNumber(value: CIFormat.RGBAh.rawValue) }
        ci = CIContext(options: opts)
    }

    private func color(_ hex: String, alpha: Double = 1) -> CIColor {
        let (r, g, b) = E.hexRgb(hex)
        return CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: srgb) ?? CIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private var canvas: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Frame

    func render(_ request: AVAsynchronousVideoCompositionRequest, into out: CVPixelBuffer) {
        let t = request.compositionTime.seconds
        let fps = plan.fps.isFinite && plan.fps > 0 ? plan.fps : 30
        let frameNo = EditSuite.int((t * fps).rounded()) ?? 0   // never Int(NaN / inf) (owner blocker 2026-11-07)
        var image = CIImage(color: color(plan.background)).cropped(to: canvas)

        // Main track (bottom layer).
        let main = E.mainFrame(project, plan: plan, at: t)
        if project.canvas.fill == .blur, project.mainTrack?.hidden != true, let pick = E.blurFillClip(project, t),
           let layer = main.layers.first(where: { $0.segment.itemId == pick.clipId }) ?? main.layers.first,
           let i = layer.segment.mainIndex, i < project.mainClips.count, let frame = sourceImage(request, layer.segment) {
            image = blurFill(frame, clip: project.mainClips[i], local: t - layer.segment.timelineStart, frame: frameNo, fps: fps).composited(over: image)
        }
        if let dip = main.dip { image = CIImage(color: color(dip)).cropped(to: canvas).composited(over: image) }
        let clips = project.mainClips
        for layer in main.layers {
            guard let i = layer.segment.mainIndex, i < clips.count, let frame = sourceImage(request, layer.segment) else { continue }
            let c = clips[i]
            let pl = E.placement(c, local: t - layer.segment.timelineStart)
            image = draw(frame, crop: c.crop, fit: c.fit ?? .cover, placement: pl, state: layer.state, adjust: E.adjustAt(c.adjust, c.keyframes, t - layer.segment.timelineStart),
                         colorKeyed: E.hasColorKeys(c.keyframes), filter: c.filter, look: E.lookAt(c.look, c.keyframes, t - layer.segment.timelineStart),
                         chroma: c.chroma, matte: matteImage(request, layer.segment, c), mask: E.maskAt(c.mask, c.keyframes, t - layer.segment.timelineStart), frame: frameNo, fps: fps, flip: c.transform,
                         effect: c.effect, effectTime: t - layer.segment.timelineStart, over: image)
        }

        // Other tracks, bottom to top: pictures first (video and image tracks), then the adjustment layers' colour over the
        // whole picture, then text and captions above everything (contract, WS8 3e20288; as Android draws text).
        for (ti, track) in project.tracks.enumerated() where track.kind != .main && track.hidden != true {
            switch track.kind {
            case .video:
                for seg in plan.video where seg.layer == ti && seg.contains(t) {
                    guard let item = track.item(seg.itemId), let c = item.videoClip, let frame = sourceImage(request, seg) else { continue }
                    var pl = E.placement(c, local: t - seg.timelineStart)
                    pl.opacity *= E.overlayFade(project, track, item, t)   // cross-dissolve between overlays (WS8 3d62419)
                    image = draw(frame, crop: c.crop, fit: c.fit ?? .contain, placement: pl, state: E.LayerState(), adjust: E.adjustAt(c.adjust, c.keyframes, t - seg.timelineStart),
                                 colorKeyed: E.hasColorKeys(c.keyframes), filter: c.filter,
                                 look: E.lookAt(c.look, c.keyframes, t - seg.timelineStart), chroma: c.chroma, matte: matteImage(request, seg, c),
                                 mask: E.maskAt(c.mask, c.keyframes, t - seg.timelineStart), frame: frameNo, fps: fps,
                                 flip: c.transform, blend: c.blend, effect: c.effect, effectTime: t - seg.timelineStart, over: image)
                }
            case .image:
                for item in track.items {
                    guard case .image(let im) = item, t >= im.startSec, t < im.startSec + im.durationSec, let pic = sources.images[im.asset] else { continue }
                    var pl = E.placement(im, local: t - im.startSec)
                    pl.opacity *= E.overlayFade(project, track, item, t)
                    image = draw(pic, crop: im.crop, fit: im.fit ?? .contain, placement: pl, state: E.LayerState(),
                                 adjust: E.adjustAt(im.adjust, im.keyframes, t - im.startSec), colorKeyed: E.hasColorKeys(im.keyframes), filter: im.filter, look: E.lookAt(im.look, im.keyframes, t - im.startSec), chroma: nil,
                                 mask: E.maskAt(im.mask, im.keyframes, t - im.startSec), frame: frameNo, fps: fps,
                                 flip: im.transform, blend: im.blend, effect: im.effect, effectTime: t - im.startSec, over: image)
                }
            default:
                break
            }
        }
        if let m = E.adjustLayerMatrix(project, t) {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[4], y: m[5], z: m[6], w: 0),
                "inputBVector": CIVector(x: m[8], y: m[9], z: m[10], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: m[3], y: m[7], z: m[11], w: 0),
            ]).applyingFilter("CIColorClamp").cropped(to: canvas)
        }
        for track in project.tracks where track.hidden != true {
            switch track.kind {
            case .text:
                for case .text(let tx) in track.items where t >= tx.startSec && t < tx.startSec + tx.durationSec {
                    image = drawText(tx, local: t - tx.startSec, over: image)
                }
            case .caption:
                if burnCaptions, let ct = track.caption { image = drawCaption(ct, at: t, over: image) }
            default:
                break
            }
        }
        ci.render(image.cropped(to: canvas), to: out, bounds: canvas, colorSpace: outSpace)
    }

    private func sourceImage(_ request: AVAsynchronousVideoCompositionRequest, _ seg: E.VideoSegment) -> CIImage? {
        guard let id = laneTracks[seg.lane], let buf = request.sourceFrame(byTrackID: id) else { return nil }
        let orient = sources.media[seg.assetId]?.orient ?? .identity
        return CIImage(cvPixelBuffer: buf).transformed(by: orient)
    }

    /// The clip's alpha matte frame at this time (upright, as its own file stores it; inverted when asked), or nil.
    private func matteImage(_ request: AVAsynchronousVideoCompositionRequest, _ seg: E.VideoSegment, _ c: E.VideoClip) -> CIImage? {
        guard let m = c.alphaMatte, matted.contains("\(seg.lane)/\(seg.itemId)"), let id = matteTracks[seg.lane],
              let buf = request.sourceFrame(byTrackID: id) else { return nil }
        let orient = sources.media[m.asset]?.orient ?? .identity
        let img = CIImage(cvPixelBuffer: buf).transformed(by: orient)
        return m.invert == true ? img.applyingFilter("CIColorInvert") : img
    }

    // MARK: Pictures

    /// Draws a picture (origin 0,0): crop → chroma key → look (sharpen, chromatic, colour matrix + curves + LUT + lift,
    /// halation, leak, vignette, grain; just the colour matrix without a look) → fit → scale/rotate/move → opacity, over `base`.
    private func draw(_ src: CIImage, crop: E.Crop?, fit: E.Fit, placement pl: E.Placement, state: E.LayerState, adjust: E.Adjust?, colorKeyed: Bool = false, filter: E.FilterRef?,
                      look: E.Look?, chroma: E.Chroma?, matte: CIImage? = nil, mask: E.Mask? = nil, frame: Int, fps: Double,
                      flip: E.Transform? = nil, blend: E.BlendMode? = nil, effect: E.Effect? = nil, effectTime: Double = 0, over base: CIImage) -> CIImage {
        let opacity = pl.opacity * state.opacity
        guard opacity > 0.001 else { return base }
        var img = src
        let e = src.extent
        // The matte, stretched over the picture's own frame (a matte made at another size still lines up), cropped with it.
        var alpha: CIImage?
        if let matte, matte.extent.width > 0, matte.extent.height > 0, e.width > 0, e.height > 0 {
            alpha = matte.transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY)
                .concatenating(CGAffineTransform(scaleX: e.width / matte.extent.width, y: e.height / matte.extent.height))
                .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
        }
        if let c = crop {
            let l = c.left ?? 0, r = c.right ?? 0, tp = c.top ?? 0, b = c.bottom ?? 0
            let rect = CGRect(x: e.minX + e.width * l, y: e.minY + e.height * b, width: e.width * max(0.1, 1 - l - r), height: e.height * max(0.1, 1 - tp - b))
            img = img.cropped(to: rect)
            alpha = alpha?.cropped(to: rect)
        }
        let origin = CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)
        img = img.transformed(by: origin)
        alpha = alpha?.transformed(by: origin)
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return base }
        if let chroma, let cube = cube(chroma) {
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 32, "inputCubeData": cube])
        }
        // Remove background: the matte's luma is the alpha (white = keep), before the look, mask and transform.
        if let alpha {
            img = img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: img.extent),
                kCIInputMaskImageKey: alpha,
            ]).cropped(to: img.extent)
        }
        img = looks.apply(look, matrix: E.colorMatrix(adjust, filter), tone: E.Tone(adjust), keyed: colorKeyed, to: img, frame: frame, fps: fps)
        // The effects library (WS8 f7226f2): after the look, before the mask and transform, in the picture's own frame.
        if let effect, effect.amount > 0 { img = EditV2EffectRenderer.apply(effect, to: img, t: effectTime) }
        // Edit suite: the mask multiplies the alpha (after the chroma key).
        if let mask { img = looks.applyMask(mask, to: img) }
        let (fw, _) = E.fittedSize(width: Double(w), height: Double(h), crop: nil, fit: fit, canvasWidth: Double(size.width), canvasHeight: Double(size.height))
        let s = CGFloat(fw / Double(w) * pl.scale * state.scale)
        let cx = CGFloat(pl.x + state.dx) * size.width, cy = size.height - CGFloat(pl.y + state.dy) * size.height
        // Wave 1 mirror: about the picture's centre, after the crop and before scale and rotation.
        let fx: CGFloat = flip?.flipX == true ? -1 : 1, fy: CGFloat = flip?.flipY == true ? -1 : 1
        let tf = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: s * fx, y: s * fy))
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(pl.rotation + state.rotation) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        img = img.transformed(by: tf)
        // Edit suite transitions: motion blur along the move (whip) and a red/blue split (glitch).
        if state.blur > 0.001 {
            let placed = img.extent
            img = img.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: state.blur * 0.04 * Double(size.width), kCIInputAngleKey: 0])
                .cropped(to: placed)
        }
        if state.rgbSplit > 0.001 {
            img = rgbSplit(img, offset: CGFloat(state.rgbSplit * 0.02) * size.width)
        }
        // Wave 1 blend modes (overlays): the reference's blendPixel on straight sRGB, mixed in by alpha × opacity.
        if let blend, blend != .normal, let k = Self.blendKernel,
           let out = k.apply(extent: base.extent, arguments: [img, base, Self.blendIndex(blend), opacity]) {
            return out
        }
        return faded(img, opacity).composited(over: base)
    }

    /// Red moved right and blue left by `offset` px, green in place (alpha = the widest of the three).
    private func rgbSplit(_ img: CIImage, offset: CGFloat) -> CIImage {
        func channel(_ c: Int, dx: CGFloat) -> CIImage {
            func v(_ k: Int) -> CIVector { k == c ? CIVector(x: c == 0 ? 1 : 0, y: c == 1 ? 1 : 0, z: c == 2 ? 1 : 0, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0) }
            return img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v(0), "inputGVector": v(1), "inputBVector": v(2),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ]).transformed(by: CGAffineTransform(translationX: dx, y: 0))
        }
        return channel(0, dx: offset)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(1, dx: 0)])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(2, dx: -offset)])
    }

    /// The image at `opacity` (premultiplied, so a dissolve to clear is exact).
    private func faded(_ img: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return img }
        return img.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: img.extent),
            kCIInputTimeKey: 1 - max(0, opacity),
        ]).cropped(to: img.extent)
    }

    /// The wave-1 blend modes as one colour kernel (plans/video-editor.md, model.ts blendChannel): straight colours, W3C formulas.
    static let blendKernel: CIColorKernel? = CIColorKernel(source: """
        float ov(float b, float s) { return b <= 0.5 ? 2.0 * b * s : 1.0 - 2.0 * (1.0 - b) * (1.0 - s); }
        float sl(float b, float s) {
            if (s <= 0.5) { return b - (1.0 - 2.0 * s) * b * (1.0 - b); }
            float d = b <= 0.25 ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
            return b + (2.0 * s - 1.0) * (d - b);
        }
        kernel vec4 museBlend(__sample top, __sample below, float mode, float op) {
            float a = clamp(top.a * op, 0.0, 1.0);
            vec3 s = top.a > 0.0001 ? top.rgb / top.a : vec3(0.0);
            vec3 b = below.a > 0.0001 ? below.rgb / below.a : vec3(0.0);
            vec3 r = s;
            if (mode > 0.5 && mode < 1.5) { r = b * s; }
            else if (mode < 2.5 && mode > 1.5) { r = b + s - b * s; }
            else if (mode < 3.5 && mode > 2.5) { r = vec3(ov(b.r, s.r), ov(b.g, s.g), ov(b.b, s.b)); }
            else if (mode < 4.5 && mode > 3.5) { r = vec3(sl(b.r, s.r), sl(b.g, s.g), sl(b.b, s.b)); }
            else if (mode < 5.5 && mode > 4.5) { r = min(b, s); }
            else if (mode < 6.5 && mode > 5.5) { r = max(b, s); }
            else if (mode > 6.5) { r = min(vec3(1.0), b + s); }
            r = clamp(r, 0.0, 1.0);
            vec3 o = b + (r - b) * a;
            return vec4(o * below.a, below.a);
        }
        """)

    static func blendIndex(_ m: E.BlendMode) -> Float {
        switch m {
        case .normal: return 0
        case .multiply: return 1
        case .screen: return 2
        case .overlay: return 3
        case .softLight: return 4
        case .darken: return 5
        case .lighten: return 6
        case .add: return 7
        }
    }

    /// Wave 1 blur fill: the main clip's frame (its crop and look, not its transform) cover-fitted, box-blurred and darkened,
    /// drawn over the background colour (blurFillRadius, BLUR_FILL_DARKEN).
    private func blurFill(_ frame: CIImage, clip c: E.VideoClip, local: Double, frame frameNo: Int, fps: Double) -> CIImage {
        var img = frame
        let e = img.extent
        if let cr = c.crop {
            let l = cr.left ?? 0, r = cr.right ?? 0, tp = cr.top ?? 0, b = cr.bottom ?? 0
            img = img.cropped(to: CGRect(x: e.minX + e.width * l, y: e.minY + e.height * b, width: e.width * max(0.1, 1 - l - r), height: e.height * max(0.1, 1 - tp - b)))
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return CIImage(color: color(plan.background)).cropped(to: canvas) }
        let adj = E.adjustAt(c.adjust, c.keyframes, local)
        img = looks.apply(E.lookAt(c.look, c.keyframes, local), matrix: E.colorMatrix(adj, c.filter), tone: E.Tone(adj), keyed: E.hasColorKeys(c.keyframes), to: img, frame: frameNo, fps: fps)
        let k = max(size.width / w, size.height / h)
        img = img.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: (size.width - w * k) / 2, y: (size.height - h * k) / 2)))
        let radius = E.blurFillRadius(width: Int(size.width), height: Int(size.height))
        let d = CGFloat(E.blurFillDarken)
        return img.clampedToExtent()
            .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: Double(radius)])
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: d, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: d, z: 0, w: 0),
                                                          "inputBVector": CIVector(x: 0, y: 0, z: d, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .cropped(to: canvas)
    }

    private func cube(_ c: E.Chroma) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let d = cubeCache[c] { return d }
        let d = E.chromaCube(c, size: 32).withUnsafeBufferPointer { Data(buffer: $0) }
        cubeCache[c] = d
        return d
    }

    // MARK: Text and captions

    private func cachedText(_ key: String, _ make: () -> CGImage?) -> CIImage? {
        lock.lock()
        if let c = textCache[key] { lock.unlock(); return c }
        lock.unlock()
        guard let cg = make() else { return nil }
        let img = CIImage(cgImage: cg)
        lock.lock()
        if textCache.count > 400 { textCache.removeAll() }
        textCache[key] = img
        lock.unlock()
        return img
    }

    /// Places a rendered text image: its centre at the placement, scaled and rotated.
    private func place(_ img: CIImage, x: Double, y: Double, scale: Double, rotation: Double, opacity: Double, flip: E.Transform? = nil, over base: CIImage) -> CIImage {
        guard opacity > 0.001 else { return base }
        let w = img.extent.width, h = img.extent.height
        let fx: CGFloat = flip?.flipX == true ? -1 : 1, fy: CGFloat = flip?.flipY == true ? -1 : 1
        let tf = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: CGFloat(scale) * fx, y: CGFloat(scale) * fy))
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: CGFloat(x) * size.width, y: size.height - CGFloat(y) * size.height))
        return faded(img.transformed(by: tf), opacity).composited(over: base)
    }

    private func drawText(_ tx: E.TextItem, local: Double, over base: CIImage) -> CIImage {
        let pl = E.placement(tx, local: local)
        // Drawn at the static scale (sharp), animated/keyframed scale on top of that.
        let k = max(1, tx.transform?.scale ?? 1)
        var text = tx.text
        if let n = pl.chars { text = String(String.UnicodeScalarView(text.unicodeScalars.prefix(n))) }
        guard !text.isEmpty else { return base }
        let key = "t|\(tx.id)|\(k)|\(text.hashValue)|\(tx.style.hashValue)|\(EditV2TextRenderer.fontGeneration)"
        let fontSize = CGFloat(tx.style.sizePct) * size.height * CGFloat(k)
        let wrap = CGFloat(tx.style.maxWidthPct ?? 0.85) * size.width * CGFloat(k)
        guard let img = cachedText(key, {
            EditV2TextRenderer.render([.init(text: text, color: tx.style.color)], style: tx.style, fontSize: fontSize, wrapWidth: wrap)
        }) else { return base }
        return place(img, x: pl.x, y: pl.y, scale: pl.scale / k, rotation: pl.rotation, opacity: pl.opacity, flip: tx.transform, over: base)
    }

    private func drawCaption(_ ct: E.CaptionTrack, at t: Double, over base: CIImage) -> CIImage {
        guard let at = E.captionAt(pages, t) else { return base }
        let page = pages[at.page]
        let st = ct.style
        let runs: [EditV2TextRenderer.Run] = page.words.enumerated().map { k, w in
            let active = k == at.word
            var run = EditV2TextRenderer.Run(text: w.text, color: st.color)
            switch st.preset {
            case .plain: break
            case .highlight: if active { run.color = st.highlightColor }
            case .box: if active { run.box = st.highlightColor }
            case .karaoke: if k <= at.word { run.color = st.highlightColor }
            case .pop: if active { run.color = st.highlightColor; run.scale = 1.15 }
            case .single: run.color = st.highlightColor
            case .highlighter: if active { run.marker = st.highlightColor }
            case .neon: if active { run.color = st.highlightColor }
            }

            return run
        }
        let key = "c|\(at.page)|\(at.word)|\(st.hashValue)|\(EditV2TextRenderer.fontGeneration)"
        let fontSize = CGFloat(st.sizePct) * size.height
        let wrap = CGFloat(st.maxWidthPct ?? 0.85) * size.width
        // Neon draws its glow with the style's own shadow colour (coordinator, 2026-11-09: server, Android and Mac match).
        let textStyle = st.textStyle
        let joiner = E.captionJoiner(ct.language), rtl = E.isRtlLanguage(ct.language)
        guard let img = cachedText(key + "|\(ct.language ?? "")", {
            EditV2TextRenderer.render(runs, style: textStyle, fontSize: fontSize, wrapWidth: wrap, joiner: joiner, rtl: rtl)
        }) else { return base }
        // As Android's core RenderPlan: `pop` is the active word at 1.15× (above); `single` (one word a page) pops in,
        // 0.6 → 1 over 0.15 s, easing out, at full opacity. No other preset scales the page.
        var scale = 1.0
        if st.preset == .single {
            scale = 0.6 + 0.4 * E.ease(.easeOut, min(1, max(0, (t - page.startSec) / 0.15)))
        }
        return place(img, x: 0.5, y: st.y ?? 0.72, scale: scale, rotation: 0, opacity: 1, over: base)
    }
}
