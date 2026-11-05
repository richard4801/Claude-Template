import AppKit
import CoreImage
import MuseCore

// Editor v2 "Looks" on the Mac (plans/video-editor.md "Looks"): the bundled look pack (the `looks` resource folder =
// server/api/assets/lookpack/looks), .cube import, the Core Image version of the filter stack used by the compositor,
// and filter thumbnails drawn with MuseCore's CPU renderer (EditV2.renderLook).

/// The bundled look pack: looks.json and its 17³ .cube files, parsed once.
final class EditV2LookLibrary: @unchecked Sendable {
    typealias E = EditV2
    static let shared = EditV2LookLibrary()

    /// The `looks` folder in the app bundle.
    let directory: URL?
    private let lock = NSLock()
    private var loaded = false
    private var cachedPack: E.LookPack?
    private var luts: [String: E.Lut] = [:]

    init(directory: URL? = Bundle.main.url(forResource: "looks", withExtension: nil)) { self.directory = directory }

    /// looks.json (nil when the folder is missing from the bundle).
    var pack: E.LookPack? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            cachedPack = directory.flatMap { try? E.LookPack.load(directory: $0) }
        }
        return cachedPack
    }

    /// What choosing bundled look `id` sets on an item.
    func packLook(_ id: String) -> E.Look? { pack?.packLook(id) }

    /// A bundled look's LUT (parsed on first use).
    func lut(packId id: String) -> E.Lut? {
        lock.lock()
        if let l = luts[id] { lock.unlock(); return l }
        lock.unlock()
        guard let pack, let directory, let l = try? pack.lut(id, in: directory) else { return nil }
        lock.lock()
        luts[id] = l
        lock.unlock()
        return l
    }

    /// The LUT a look's `lut` names: "pack:<id>" from the bundle, else an imported asset's (by asset id).
    func lut(for ref: String?, imported: [String: E.Lut]) -> E.Lut? {
        guard let ref else { return nil }
        if ref.hasPrefix("pack:") { return lut(packId: String(ref.dropFirst(5))) }
        return imported[ref]
    }

    // MARK: Import

    /// What the user's .cube holds: shown before it is uploaded (presign purpose "lut") and added as a lut asset.
    struct ImportedCube: Sendable {
        let size: Int
        let title: String?
        let lut: E.Lut
    }

    /// Reads and parses a .cube file (3D, size 2–64, ≤ 12 MB) the way the server will; the error names the bad line.
    static func readCube(_ url: URL) throws -> E.Lut {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if bytes > E.LookLimits.maxCubeBytes { throw E.CubeError("the file is over \(E.LookLimits.maxCubeBytes / 1024 / 1024) MB") }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw E.CubeError("couldn't read the file") }
        return try E.parseCube(String(decoding: data, as: UTF8.self))
    }

    /// Import of a user .cube: its size and title, or why it can't be used.
    static func importCube(_ url: URL) -> Result<ImportedCube, E.CubeError> {
        do {
            let lut = try readCube(url)
            return .success(ImportedCube(size: lut.size, title: lut.title, lut: lut))
        } catch let e as E.CubeError {
            return .failure(e)
        } catch {
            return .failure(E.CubeError(error.localizedDescription))
        }
    }
}

/// The filter stack in Core Image, per item (on the item's own picture, after crop and chroma key, before it is fitted
/// and placed), in the contract's order:
///   1 sharpen (CIUnsharpMask, Gaussian of the box blur's spread)  2 chromatic aberration (red/blue planes scaled about the
///   centre, recombined with CIMaximumCompositing)  3–6 colour matrix + curves + LUT + lift baked into ONE 33³
///   CIColorCubeWithColorSpace (sRGB) from MuseCore's CPU functions, cached  7 halation (blur → affine highlight map →
///   clamp → screen)  8 light leak (a 64² map of leakColor for the frame's time, scaled up, screened)  9 vignette (a 128²
///   mask map, multiplied or screened)  10 grain (CIRandomGenerator cells as the mask between two 17³ grain cubes).
/// Thread-safe (preview and export may draw at once).
final class EditV2LookRenderer: @unchecked Sendable {
    typealias E = EditV2
    private let library: EditV2LookLibrary
    private let imported: [String: E.Lut]
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var cubes: [CubeKey: Data] = [:]
    private var grains: [Double: (darker: Data, lighter: Data)] = [:]
    private var vignettes: [E.Vignette: CIImage] = [:]

    private struct CubeKey: Hashable {
        let matrix: [Double]
        let tone: E.Tone?
        let color: E.Look.ColorPart?
    }
    private var masks: [E.Mask: CIImage] = [:]
    static let maskMapSize = 256

    static let cubeSize = 33
    static let grainCubeSize = 17
    static let leakMapSize = 64
    static let vignetteMapSize = 128

    init(imported: [String: E.Lut], library: EditV2LookLibrary = .shared) {
        self.imported = imported
        self.library = library
    }

    /// Applies the item's colour matrix and look to `src` (extent at 0,0). `frame` = the output frame number (grain);
    /// `fps` turns it into the leak's time.
    func apply(_ look: E.Look?, matrix m: [Double], tone: E.Tone? = nil, to src: CIImage, frame: Int, fps: Double) -> CIImage {
        let ext = src.extent
        guard ext.width >= 1, ext.height >= 1, ext.width.isFinite, ext.height.isFinite else { return src }
        guard let look else { return colorOnly(src, matrix: m, tone: tone, look: nil, lut: nil) }
        let short = max(1, Int(min(ext.width, ext.height).rounded()))
        var img = src

        // 1. sharpen: v + 1.5·s·(v − blur(v))
        let sh = clamp01(look.sharpen ?? 0)
        if sh > 0 {
            img = img.clampedToExtent()
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: sigma(E.sharpenRadius(short)), kCIInputIntensityKey: 1.5 * sh])
                .cropped(to: ext)
                .applyingFilter("CIColorClamp")
        }

        // 2. chromatic aberration: red sampled at c + (p − c)(1 + k), blue at c + (p − c)(1 − k)
        let ca = clamp01(look.chromatic ?? 0) * 0.006
        if ca > 0 {
            let base = img
            func scaled(_ k: CGFloat) -> CIImage {
                let tf = CGAffineTransform(translationX: -ext.midX, y: -ext.midY)
                    .concatenating(CGAffineTransform(scaleX: k, y: k))
                    .concatenating(CGAffineTransform(translationX: ext.midX, y: ext.midY))
                return base.clampedToExtent().transformed(by: tf).cropped(to: ext)
            }
            let red = channel(scaled(1 / (1 + CGFloat(ca))), 0)
            let green = channel(base, 1)
            let blue = channel(scaled(1 / (1 - CGFloat(ca))), 2)
            img = red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
                .cropped(to: ext)
        }

        // 3–6. colour matrix, curves, LUT, lift: one colour cube
        img = colorOnly(img, matrix: m, tone: tone, look: look, lut: library.lut(for: look.lut, imported: imported))

        // 7. halation: blurred highlights above the threshold, tinted warm red, screened on
        if let ha = look.halation, ha.amount > 0 {
            let (rows, bias, mx) = E.halationMatrix(ha)
            let blurred = img.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma(E.halationRadius(short, ha))])
                .cropped(to: ext)
            let glow = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: rows[0][0], y: rows[0][1], z: rows[0][2], w: 0),
                "inputGVector": CIVector(x: rows[1][0], y: rows[1][1], z: rows[1][2], w: 0),
                "inputBVector": CIVector(x: rows[2][0], y: rows[2][1], z: rows[2][2], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0),
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: mx[0], y: mx[1], z: mx[2], w: 1),
            ])
            img = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
        }

        // 8. light leak, screened (its time = frame / fps, like the CPU renderer)
        if let lk = look.leak, lk.amount > 0 {
            let n = Self.leakMapSize
            let t = Double(frame) / (fps > 0 ? fps : 30)
            if let map = mapImage(E.leakMap(lk, t: t, width: n, height: n), n, n, to: ext) {
                img = map.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
            }
        }

        // 9. vignette: multiply by 1 − a·m (darken) or screen a·m (lighten)
        if let vg = look.vignette, vg.amount != 0, let map = vignette(vg, to: ext) {
            let mode = vg.amount > 0 ? "CIMultiplyCompositing" : "CIScreenBlendMode"
            img = map.applyingFilter(mode, parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
        }

        // 10. grain: mix(v − g/2, v + g/2, noise), g = 0.18·amount·(1 − |2·luma − 1|/2), cells of `cell` px, new every frame
        if let gr = look.grain, gr.amount > 0 {
            let (dk, lt) = grainCubes(gr.amount)
            let n = Self.grainCubeSize
            let darker = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": n, "inputCubeData": dk, "inputColorSpace": srgb])
            let lighter = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": n, "inputCubeData": lt, "inputColorSpace": srgb])
            if let noise = noise(frame: frame, cell: E.grainCell(short, gr), extent: ext) {
                img = lighter.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: darker, kCIInputMaskImageKey: noise]).cropped(to: ext)
            }
        }
        return img.applyingFilter("CIColorClamp")
    }

    // MARK: Pieces

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// The Gaussian σ with the spread of a (2r+1)-wide box (the reference blurs with boxes).
    private func sigma(_ r: Int) -> Double { (Double(r * (r + 1)) / 3).squareRoot() }

    /// One channel of `img` (the others 0, alpha kept).
    private func channel(_ img: CIImage, _ c: Int) -> CIImage {
        func v(_ k: Int) -> CIVector { k == c ? CIVector(x: c == 0 ? 1 : 0, y: c == 1 ? 1 : 0, z: c == 2 ? 1 : 0, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0) }
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v(0), "inputGVector": v(1), "inputBVector": v(2),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    /// Steps 3–6: the matrix alone (CIColorMatrix) when the look has no colour part, else the baked colour cube.
    private func colorOnly(_ img: CIImage, matrix m: [Double], tone: E.Tone? = nil, look: E.Look?, lut: E.Lut?) -> CIImage {
        if E.lookColorIsIdentity(matrix: m, tone: tone, look: look, lut: lut) { return img }
        if tone == nil, look == nil || E.lookColorIsIdentity(matrix: nil, look: look, lut: lut) {
            return img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[4], y: m[5], z: m[6], w: 0),
                "inputBVector": CIVector(x: m[8], y: m[9], z: m[10], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: m[3], y: m[7], z: m[11], w: 0),
            ]).applyingFilter("CIColorClamp")
        }
        let data = cube(matrix: m, tone: tone, look: look, lut: lut)
        return img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": Self.cubeSize, "inputCubeData": data, "inputColorSpace": srgb,
        ])
    }

    private func cube(matrix m: [Double], tone: E.Tone?, look: E.Look?, lut: E.Lut?) -> Data {
        let key = CubeKey(matrix: m, tone: tone, color: look?.colorPart)
        lock.lock()
        if let d = cubes[key] { lock.unlock(); return d }
        lock.unlock()
        let d = E.lookCube(matrix: m, tone: tone, look: look, lut: lut, size: Self.cubeSize).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if cubes.count > 64 { cubes.removeAll() }
        cubes[key] = d
        lock.unlock()
        return d
    }

    private func grainCubes(_ amount: Double) -> (Data, Data) {
        lock.lock()
        if let g = grains[amount] { lock.unlock(); return (g.darker, g.lighter) }
        lock.unlock()
        let (dk, lt) = E.grainCubes(amount: amount, size: Self.grainCubeSize)
        let g = (darker: dk.withUnsafeBufferPointer { Data(buffer: $0) }, lighter: lt.withUnsafeBufferPointer { Data(buffer: $0) })
        lock.lock()
        if grains.count > 32 { grains.removeAll() }
        grains[amount] = g
        lock.unlock()
        return (g.darker, g.lighter)
    }

    /// An RGBA float map (row 0 = top) stretched over `ext` with bilinear sampling.
    private func mapImage(_ px: [Float], _ w: Int, _ h: Int, to ext: CGRect) -> CIImage? {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        // No colour space: the values are used as they are (the context works on sRGB values).
        let map = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        return map.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: ext.width / CGFloat(w), y: ext.height / CGFloat(h))
                .concatenating(CGAffineTransform(translationX: ext.minX, y: ext.minY)))
            .cropped(to: ext)
    }

    private func vignette(_ v: E.Vignette, to ext: CGRect) -> CIImage? {
        let n = Self.vignetteMapSize
        lock.lock()
        let cached = vignettes[v]
        lock.unlock()
        let base: CIImage
        if let cached { base = cached } else {
            let data = E.vignetteMap(v, width: n, height: n).withUnsafeBufferPointer { Data(buffer: $0) }
            base = CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
            lock.lock()
            if vignettes.count > 32 { vignettes.removeAll() }
            vignettes[v] = base
            lock.unlock()
        }
        return base.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: ext.width / CGFloat(n), y: ext.height / CGFloat(n))
                .concatenating(CGAffineTransform(translationX: ext.minX, y: ext.minY)))
            .cropped(to: ext)
    }

    /// Edit suite: the item's mask (maskAlpha, row 0 = the top of the item) multiplied into `src`'s alpha.
    func applyMask(_ m: E.Mask, to src: CIImage) -> CIImage {
        let ext = src.extent
        guard ext.width >= 1, ext.height >= 1, ext.width.isFinite, ext.height.isFinite else { return src }
        let n = Self.maskMapSize
        lock.lock()
        let cached = masks[m]
        lock.unlock()
        let base: CIImage
        if let cached { base = cached } else {
            let a = E.maskMap(m, width: n, height: n)
            var px = [Float](repeating: 1, count: n * n * 4)
            for i in 0..<(n * n) { px[i * 4 + 3] = Float(a[i]) / 255 }
            let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
            base = CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
            lock.lock()
            if masks.count > 32 { masks.removeAll() }
            masks[m] = base
            lock.unlock()
        }
        let mask = base.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: ext.width / CGFloat(n), y: ext.height / CGFloat(n))
                .concatenating(CGAffineTransform(translationX: ext.minX, y: ext.minY)))
            .cropped(to: ext)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: ext)
        return src.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask]).cropped(to: ext)
    }

    /// Mono uniform noise 0…1 in cells of `cell` px, a different pattern every frame.

    private func noise(frame: Int, cell: Int, extent ext: CGRect) -> CIImage? {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        // Whole-pixel offsets keep the generator's pixels intact; they move the pattern per frame.
        let ox = CGFloat(Int(E.hash01(frame, 17, 3) * 8192)), oy = CGFloat(Int(E.hash01(frame, 29, 5) * 8192))
        let mono = random.transformed(by: CGAffineTransform(translationX: -ox, y: -oy)).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let c = CGFloat(max(1, cell))
        return mono.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: c, y: c).concatenating(CGAffineTransform(translationX: ext.minX, y: ext.minY)))
            .cropped(to: ext)
    }
}

/// Filter thumbnails: every bundled look drawn on the current frame (downscaled so its short side is ~96 px) with
/// MuseCore's CPU renderer, off the main thread.
enum EditV2LookThumbnails {
    typealias E = EditV2

    /// Thumbnails by look id. `matrix` = the item's own colour matrix (adjust/filter), so the tiles show the result.
    static func render(frame: CGImage, matrix: [Double]? = nil, shortSide: Int = 96, library: EditV2LookLibrary = .shared) async -> [String: CGImage] {
        await Task.detached(priority: .userInitiated) {
            EditV2LookThumbnails.renderNow(frame: frame, matrix: matrix, shortSide: shortSide, library: library)
        }.value
    }

    /// The same, on the calling thread.
    static func renderNow(frame: CGImage, matrix: [Double]?, shortSide: Int, library: EditV2LookLibrary) -> [String: CGImage] {
        guard let pack = library.pack, let small = lookImage(frame, shortSide: shortSide) else { return [:] }
        let looks = pack.looks
        let lock = NSLock()
        var out: [String: CGImage] = [:]
        DispatchQueue.concurrentPerform(iterations: looks.count) { i in
            let e = looks[i]
            let lut = library.lut(packId: e.id)
            let img = E.renderLook(small, e.look, matrix: matrix, lut: lut, frame: 0, fps: 30)
            guard let cg = cgImage(img) else { return }
            lock.lock()
            out[e.id] = cg
            lock.unlock()
        }
        return out
    }

    /// One look on a picture (e.g. the tile for the item's current look, or an imported LUT's preview).
    static func renderOne(frame: CGImage, look: E.Look, lut: E.Lut?, matrix: [Double]? = nil, shortSide: Int = 96) -> CGImage? {
        guard let small = lookImage(frame, shortSide: shortSide) else { return nil }
        return cgImage(E.renderLook(small, look, matrix: matrix, lut: lut, frame: 0, fps: 30))
    }

    /// The picture downscaled (short side `shortSide`, never enlarged) as sRGB floats.
    static func lookImage(_ cg: CGImage, shortSide: Int) -> E.LookImage? {
        let w0 = cg.width, h0 = cg.height
        guard w0 > 0, h0 > 0 else { return nil }
        let k = min(1, Double(shortSide) / Double(min(w0, h0)))
        let w = max(1, Int((Double(w0) * k).rounded())), h = max(1, Int((Double(h0) * k).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var data = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            // Opaque frames; a transparent pixel reads as black.
            data[i * 3] = Float(bytes[i * 4]) / 255
            data[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
            data[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
        }
        return E.LookImage(width: w, height: h, data: data)
    }

    /// An sRGB CGImage of a rendered picture.
    static func cgImage(_ img: E.LookImage) -> CGImage? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, img.data.count == w * h * 3 else { return nil }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { bytes[i * 4 + c] = UInt8(max(0, min(255, (img.data[i * 3 + c] * 255).rounded()))) }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
