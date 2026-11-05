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
final class EditV2Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.muse.edit2.compositor", qos: .userInitiated)
    private let lock = NSLock()
    private var context: AVVideoCompositionRenderContext?
    private var generation = 0

    #if compiler(>=6.0)
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    #else
    let sourcePixelBufferAttributes: [String: Any]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    #endif

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

/// Everything needed to draw any frame of one built project; thread-safe (preview and export may draw at once).
final class EditV2Scene: @unchecked Sendable {
    typealias E = EditV2
    let project: E.Project
    let plan: E.RenderPlan
    let laneTracks: [Int: CMPersistentTrackID]
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

    init(project: E.Project, plan: E.RenderPlan, laneTracks: [Int: CMPersistentTrackID], sources: EditV2Engine.Sources, burnCaptions: Bool = true) {
        self.burnCaptions = burnCaptions
        self.project = project
        self.plan = plan
        self.laneTracks = laneTracks
        self.sources = sources
        pages = E.captionPages(project)
        size = CGSize(width: plan.width, height: plan.height)
        looks = EditV2LookRenderer(imported: sources.luts)
        // Colour work (the item matrices, the chroma cube, blending) on sRGB values, as the contract defines it.
        ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    }

    private func color(_ hex: String, alpha: Double = 1) -> CIColor {
        let (r, g, b) = E.hexRgb(hex)
        return CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: srgb) ?? CIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private var canvas: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Frame

    func render(_ request: AVAsynchronousVideoCompositionRequest, into out: CVPixelBuffer) {
        let t = request.compositionTime.seconds
        let fps = plan.fps > 0 ? plan.fps : 30
        let frameNo = Int((t * fps).rounded())
        var image = CIImage(color: color(plan.background)).cropped(to: canvas)

        // Main track (bottom layer).
        let main = E.mainFrame(project, plan: plan, at: t)
        if let dip = main.dip { image = CIImage(color: color(dip)).cropped(to: canvas).composited(over: image) }
        let clips = project.mainClips
        for layer in main.layers {
            guard let i = layer.segment.mainIndex, i < clips.count, let frame = sourceImage(request, layer.segment) else { continue }
            let c = clips[i]
            let pl = E.placement(c, local: t - layer.segment.timelineStart)
            image = draw(frame, crop: c.crop, fit: c.fit ?? .cover, placement: pl, state: layer.state, adjust: c.adjust, filter: c.filter, look: c.look,
                         chroma: c.chroma, mask: c.mask, frame: frameNo, fps: fps, over: image)
        }

        // Other tracks, bottom to top.
        for (ti, track) in project.tracks.enumerated() where track.kind != .main && track.hidden != true {
            switch track.kind {
            case .video:
                for seg in plan.video where seg.layer == ti && seg.contains(t) {
                    guard let c = track.item(seg.itemId)?.videoClip, let frame = sourceImage(request, seg) else { continue }
                    let pl = E.placement(c, local: t - seg.timelineStart)
                    image = draw(frame, crop: c.crop, fit: c.fit ?? .contain, placement: pl, state: E.LayerState(), adjust: c.adjust, filter: c.filter,
                                 look: c.look, chroma: c.chroma, mask: c.mask, frame: frameNo, fps: fps, over: image)
                }
            case .image:
                for case .image(let im) in track.items where t >= im.startSec && t < im.startSec + im.durationSec {
                    guard let pic = sources.images[im.asset] else { continue }
                    image = draw(pic, crop: im.crop, fit: im.fit ?? .contain, placement: E.placement(im, local: t - im.startSec), state: E.LayerState(),
                                 adjust: im.adjust, filter: im.filter, look: im.look, chroma: nil, mask: im.mask, frame: frameNo, fps: fps, over: image)
                }
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
        ci.render(image.cropped(to: canvas), to: out, bounds: canvas, colorSpace: srgb)
    }

    private func sourceImage(_ request: AVAsynchronousVideoCompositionRequest, _ seg: E.VideoSegment) -> CIImage? {
        guard let id = laneTracks[seg.lane], let buf = request.sourceFrame(byTrackID: id) else { return nil }
        let orient = sources.media[seg.assetId]?.orient ?? .identity
        return CIImage(cvPixelBuffer: buf).transformed(by: orient)
    }

    // MARK: Pictures

    /// Draws a picture (origin 0,0): crop → chroma key → look (sharpen, chromatic, colour matrix + curves + LUT + lift,
    /// halation, leak, vignette, grain; just the colour matrix without a look) → fit → scale/rotate/move → opacity, over `base`.
    private func draw(_ src: CIImage, crop: E.Crop?, fit: E.Fit, placement pl: E.Placement, state: E.LayerState, adjust: E.Adjust?, filter: E.FilterRef?,
                      look: E.Look?, chroma: E.Chroma?, mask: E.Mask? = nil, frame: Int, fps: Double, over base: CIImage) -> CIImage {
        let opacity = pl.opacity * state.opacity
        guard opacity > 0.001 else { return base }
        var img = src
        let e = src.extent
        if let c = crop {
            let l = c.left ?? 0, r = c.right ?? 0, tp = c.top ?? 0, b = c.bottom ?? 0
            let rect = CGRect(x: e.minX + e.width * l, y: e.minY + e.height * b, width: e.width * max(0.1, 1 - l - r), height: e.height * max(0.1, 1 - tp - b))
            img = img.cropped(to: rect)
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return base }
        if let chroma, let cube = cube(chroma) {
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 32, "inputCubeData": cube])
        }
        img = looks.apply(look, matrix: E.colorMatrix(adjust, filter), tone: E.Tone(adjust), to: img, frame: frame, fps: fps)
        // Edit suite: the mask multiplies the alpha (after the chroma key).
        if let mask { img = looks.applyMask(mask, to: img) }
        let (fw, _) = E.fittedSize(width: Double(w), height: Double(h), crop: nil, fit: fit, canvasWidth: Double(size.width), canvasHeight: Double(size.height))
        let s = CGFloat(fw / Double(w) * pl.scale * state.scale)
        let cx = CGFloat(pl.x + state.dx) * size.width, cy = size.height - CGFloat(pl.y + state.dy) * size.height
        let tf = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
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
    private func place(_ img: CIImage, x: Double, y: Double, scale: Double, rotation: Double, opacity: Double, over base: CIImage) -> CIImage {
        guard opacity > 0.001 else { return base }
        let w = img.extent.width, h = img.extent.height
        let tf = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
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
        let key = "t|\(tx.id)|\(k)|\(text.hashValue)|\(tx.style.hashValue)"
        let fontSize = CGFloat(tx.style.sizePct) * size.height * CGFloat(k)
        let wrap = CGFloat(tx.style.maxWidthPct ?? 0.85) * size.width * CGFloat(k)
        guard let img = cachedText(key, {
            EditV2TextRenderer.render([.init(text: text, color: tx.style.color)], style: tx.style, fontSize: fontSize, wrapWidth: wrap)
        }) else { return base }
        return place(img, x: pl.x, y: pl.y, scale: pl.scale / k, rotation: pl.rotation, opacity: pl.opacity, over: base)
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
        let key = "c|\(at.page)|\(at.word)|\(st.hashValue)"
        let fontSize = CGFloat(st.sizePct) * size.height
        let wrap = CGFloat(st.maxWidthPct ?? 0.85) * size.width
        guard let img = cachedText(key, { EditV2TextRenderer.render(runs, style: st.textStyle, fontSize: fontSize, wrapWidth: wrap) }) else { return base }
        // `single` (and `pop` on each new page) pops in.
        var scale = 1.0, opacity = 1.0
        if st.preset == .single || st.preset == .pop {
            let a = E.animState(durationSec: max(0.2, page.endSec - page.startSec), animIn: E.Anim(kind: .pop, durationSec: 0.2), animOut: nil, text: nil, t - page.startSec)
            scale = a.scale
            opacity = a.opacity
        }
        return place(img, x: 0.5, y: st.y ?? 0.72, scale: scale, rotation: 0, opacity: opacity, over: base)
    }
}
