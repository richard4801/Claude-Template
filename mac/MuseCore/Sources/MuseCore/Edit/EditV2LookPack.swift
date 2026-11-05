import Foundation

// The bundled look pack (server/api/assets/lookpack/looks: looks.json + 17³ .cube files; the Mac app ships that folder as
// the `looks` resource folder) and the CPU-baked tables the Core Image renderer uses for a look: one colour cube per item
// (matrix + curves + LUT + lift), the grain cubes, and the vignette / light-leak maps.

extension EditV2 {
    /// The 32 bundled looks, in the pack's order (validation accepts "pack:<id>" for these).
    public static let lookPackIds: [String] = [
        "natural-clean", "natural-glow", "natural-soft", "natural-pop", "natural-bright",
        "film-gold", "film-pastel", "film-cine", "film-chrome",
        "moody-teal", "moody-forest", "moody-night", "moody-shadow",
        "warm-sunset", "warm-honey", "warm-peach", "warm-amber",
        "cool-ice", "cool-mint", "cool-blue-hour", "cool-crisp",
        "bw-classic", "bw-contrast", "bw-soft", "bw-sepia",
        "vintage-70s", "vintage-instant", "vintage-faded",
        "cine-teal-orange", "cine-bleach", "cine-noir", "cine-golden",
    ]

    /// looks.json of the bundled pack.
    public struct LookPack: Codable, Hashable, Sendable {
        public struct Entry: Codable, Hashable, Sendable, Identifiable {
            public var id: String
            public var name: String
            /// natural, film, moody, warm, cool, bw, vintage or cinematic.
            public var category: String
            /// The .cube file name in the pack folder.
            public var file: String
            /// What choosing it sets: { lut: "pack:<id>", strength: 1, …its default effects }.
            public var look: Look
        }
        public var version: Int
        public var cubeSize: Int
        public var looks: [Entry]

        public static let fileName = "looks.json"
        public static let categories = ["natural", "film", "moody", "warm", "cool", "bw", "vintage", "cinematic"]

        public static func decode(_ data: Data) throws -> LookPack { try JSONDecoder().decode(LookPack.self, from: data) }
        /// Reads looks.json from the pack folder.
        public static func load(directory: URL) throws -> LookPack { try decode(Data(contentsOf: directory.appendingPathComponent(fileName))) }

        public func entry(_ id: String) -> Entry? { looks.first { $0.id == id } }
        /// The look to set when the user picks a bundled look (nil for an unknown id).
        public func packLook(_ id: String) -> Look? { entry(id)?.look }
        public func cubeURL(_ id: String, in directory: URL) -> URL? { entry(id).map { directory.appendingPathComponent($0.file) } }
        /// Parses one look's .cube from the pack folder.
        public func lut(_ id: String, in directory: URL) throws -> Lut {
            guard let url = cubeURL(id, in: directory) else { throw CubeError("unknown look \(id)") }
            return try parseCube(String(decoding: Data(contentsOf: url), as: UTF8.self))
        }
        public var ids: [String] { looks.map(\.id) }
    }

    /// The look to set when the user picks bundled look `id` from `pack`.
    public static func packLook(_ id: String, pack: LookPack) -> Look? { pack.packLook(id) }

    // MARK: Tables for the GPU renderer

    /// True when steps 3–6 change nothing (no matrix, curves, LUT or lift): the cube can be skipped.
    public static func lookColorIsIdentity(matrix: [Double]?, look: Look?, lut: Lut?) -> Bool {
        let noMatrix = matrix.map { isIdentity($0) } ?? true
        guard let look else { return noMatrix }
        let noLut = lut == nil || clamp(look.strength ?? 1, 0, 1) <= 0
        return noMatrix && curvesFn(look.curves) == nil && noLut && clamp(look.lift ?? 0, 0, 1) <= 0
    }

    /// RGBA float data (alpha 1, red fastest, then green, then blue) of a `size`³ colour cube holding steps 3–6 of the
    /// pipeline — the colour matrix, curves, LUT (blended by strength) and lift — for Core Image's
    /// CIColorCubeWithColorSpace (sRGB).
    public static func lookCube(matrix: [Double]?, look: Look?, lut: Lut?, size: Int = 33) -> [Float] {
        let curves = curvesFn(look?.curves)
        let strength = clamp(look?.strength ?? 1, 0, 1), lift = 0.12 * clamp(look?.lift ?? 0, 0, 1)
        let m = matrix.flatMap { isIdentity($0) ? nil : $0 }
        var out = [Float](repeating: 1, count: size * size * size * 4)
        let n = Double(size - 1)
        var i = 0
        for bi in 0..<size { for gi in 0..<size { for ri in 0..<size {
            let o = lookColor(SIMD3(Double(ri) / n, Double(gi) / n, Double(bi) / n), matrix: m, curves: curves, lut: lut, strength: strength, lift: lift)
            out[i] = Float(o.x); out[i + 1] = Float(o.y); out[i + 2] = Float(o.z)
            i += 4
        } } }
        return out
    }

    /// The two colour cubes the GPU grain blends between with the noise as the mask: v ∓ 0.09·amount·w(luma),
    /// w = 1 − |2·luma − 1|/2 (so mix(darker, lighter, n) = v + 0.18·amount·(n − 0.5)·w, the reference's grain).
    public static func grainCubes(amount: Double, size: Int = 17) -> (darker: [Float], lighter: [Float]) {
        let a = clamp(amount, 0, 1) * 0.18 / 2
        var dk = [Float](repeating: 1, count: size * size * size * 4), lt = dk
        let n = Double(size - 1)
        var i = 0
        for bi in 0..<size { for gi in 0..<size { for ri in 0..<size {
            let v = SIMD3(Double(ri) / n, Double(gi) / n, Double(bi) / n)
            let l = (lookLuma * v).sum()
            let g = a * (1 - abs(2 * l - 1) * 0.5)
            for c in 0..<3 {
                dk[i + c] = Float(clamp(v[c] - g, 0, 1))
                lt[i + c] = Float(clamp(v[c] + g, 0, 1))
            }
            i += 4
        } } }
        return (dk, lt)
    }

    /// A `w`×`h` RGBA float map (row 0 = the TOP of the picture) of the vignette's per-pixel factor, sampled at pixel
    /// centres: amount > 0 → the multiplier 1 − a·m (multiply it on); amount < 0 → the lift |a|·m (screen it on).
    public static func vignetteMap(_ v: Vignette, width w: Int, height h: Int) -> [Float] {
        let a = clamp(v.amount, -1, 1)
        var out = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let m = vignetteMask(v, (Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h))
            let f = Float(a > 0 ? 1 - a * m : -a * m)
            let i = (y * w + x) * 4
            out[i] = f; out[i + 1] = f; out[i + 2] = f
        } }
        return out
    }

    /// A `w`×`h` RGBA float map (row 0 = the TOP) of the light leak's colour at time t, to screen over the picture.
    public static func leakMap(_ l: Leak, t: Double, width w: Int, height h: Int) -> [Float] {
        var out = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let c = leakColor(l, (Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h), t)
            let i = (y * w + x) * 4
            out[i] = Float(c.x); out[i + 1] = Float(c.y); out[i + 2] = Float(c.z)
        } }
        return out
    }

    /// The halation's highlight image as an affine colour map of the BLURRED picture (Core Image: CIColorMatrix then a
    /// clamp to 0…max, then screen): channel c = clamp(tint_c·k·(luma − thr)/(1 − thr), 0, tint_c·k).
    public static func halationMatrix(_ h: Halation) -> (rows: [[Double]], bias: [Double], max: [Double]) {
        let thr = clamp(h.threshold ?? 0.7, 0, 0.99), k = clamp(h.amount, 0, 1)
        let tint: [Double] = [1, 0.35, 0.2]
        let rows = tint.map { t in [lookLuma.x, lookLuma.y, lookLuma.z].map { $0 * t * k / (1 - thr) } }
        let bias = tint.map { t in -thr * t * k / (1 - thr) }
        return (rows, bias, tint.map { $0 * k })
    }
}
