import Foundation

// Editor v2 "Looks" (plans/video-editor.md "Looks"): the filter stack of a video/image item. A Swift port of the reference
// server/api/src/editor/look.ts — .cube parsing, LUT sampling, tone curves, the grain hash, vignette and light-leak
// formulas, the CPU renderer (filter thumbnails, tests) and the validation rules — checked against the shared fixture
// Tests/MuseCoreTests/Fixtures/editor/looks.json. Plus the pieces the Core Image renderer bakes on the CPU: the per-item
// colour cube (matrix + curves + LUT + lift), the grain cubes and the vignette/leak maps.
//
// Pipeline per item, on sRGB 0–1, clamped after each step:
//   1 sharpen  2 chromatic aberration  3 colour matrix  4 curves  5 LUT  6 lift  7 halation  8 light leak  9 vignette  10 grain

extension EditV2 {
    // MARK: Types

    /// A tone curve: [x, y] points (2–16, x rising, both 0–1). Kept as arrays so the JSON is the contract's.
    public typealias CurvePoints = [[Double]]

    public struct Curves: Codable, Hashable, Sendable {
        public var rgb: CurvePoints?
        public var r: CurvePoints?
        public var g: CurvePoints?
        public var b: CurvePoints?
        /// Keys that aren't curves (kept only so validation can name them; never written).
        public var unknownKeys: [String] = []

        public init(rgb: CurvePoints? = nil, r: CurvePoints? = nil, g: CurvePoints? = nil, b: CurvePoints? = nil) {
            self.rgb = rgb; self.r = r; self.g = g; self.b = b
        }
        enum CodingKeys: String, CodingKey, CaseIterable { case rgb, r, g, b }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rgb = try c.decodeIfPresent(CurvePoints.self, forKey: .rgb)
            r = try c.decodeIfPresent(CurvePoints.self, forKey: .r)
            g = try c.decodeIfPresent(CurvePoints.self, forKey: .g)
            b = try c.decodeIfPresent(CurvePoints.self, forKey: .b)
            unknownKeys = try LookAnyKey.unknown(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(rgb, forKey: .rgb)
            try c.encodeIfPresent(r, forKey: .r)
            try c.encodeIfPresent(g, forKey: .g)
            try c.encodeIfPresent(b, forKey: .b)
        }
    }

    public struct Grain: Codable, Hashable, Sendable {
        public var amount: Double
        /// 0.5–3 (default 1).
        public var size: Double?
        public init(amount: Double, size: Double? = nil) { self.amount = amount; self.size = size }
    }

    public struct Vignette: Codable, Hashable, Sendable {
        /// −1…1; below 0 lightens the edges.
        public var amount: Double
        /// 0–1 (default 0.45).
        public var size: Double?
        /// 0–1 (default 0.5).
        public var softness: Double?
        public init(amount: Double, size: Double? = nil, softness: Double? = nil) { self.amount = amount; self.size = size; self.softness = softness }
    }

    public struct Halation: Codable, Hashable, Sendable {
        public var amount: Double
        /// 0.05–1 (default 0.5).
        public var radius: Double?
        /// 0–0.99 (default 0.7).
        public var threshold: Double?
        public init(amount: Double, radius: Double? = nil, threshold: Double? = nil) { self.amount = amount; self.radius = radius; self.threshold = threshold }
    }

    /// warm, rose, amber, teal or rainbow. A string-backed value so a project with an unknown kind still decodes and
    /// validation can name the field (as the reference does).
    public struct LeakKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
        public var description: String { rawValue }
        public static let warm = LeakKind(rawValue: "warm")
        public static let rose = LeakKind(rawValue: "rose")
        public static let amber = LeakKind(rawValue: "amber")
        public static let teal = LeakKind(rawValue: "teal")
        public static let rainbow = LeakKind(rawValue: "rainbow")
        public static let all: [LeakKind] = [.warm, .rose, .amber, .teal, .rainbow]
        public var isKnown: Bool { Self.all.contains(self) }
    }

    public struct Leak: Codable, Hashable, Sendable {
        public var kind: LeakKind
        public var amount: Double
        /// Degrees, −360…360 (default 30).
        public var angle: Double?
        public init(kind: LeakKind, amount: Double, angle: Double? = nil) { self.kind = kind; self.amount = amount; self.angle = angle }
    }

    /// A look: every part optional. `lut` = "pack:<id>" (a bundled look) or the id of a project asset of kind "lut".
    public struct Look: Codable, Hashable, Sendable {
        public var lut: String?
        /// 0–1, the LUT blended with the picture (default 1).
        public var strength: Double?
        public var curves: Curves?
        /// 0–1, faded blacks.
        public var lift: Double?
        public var sharpen: Double?
        /// 0–1, chromatic aberration.
        public var chromatic: Double?
        public var halation: Halation?
        public var leak: Leak?
        public var vignette: Vignette?
        public var grain: Grain?
        /// Keys that aren't look settings (kept only so validation can name the first; never written).
        public var unknownKeys: [String] = []

        public init(lut: String? = nil, strength: Double? = nil, curves: Curves? = nil, lift: Double? = nil, sharpen: Double? = nil,
                    chromatic: Double? = nil, halation: Halation? = nil, leak: Leak? = nil, vignette: Vignette? = nil, grain: Grain? = nil) {
            self.lut = lut; self.strength = strength; self.curves = curves; self.lift = lift; self.sharpen = sharpen; self.chromatic = chromatic
            self.halation = halation; self.leak = leak; self.vignette = vignette; self.grain = grain
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case lut, strength, curves, lift, sharpen, chromatic, halation, leak, vignette, grain }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lut = try c.decodeIfPresent(String.self, forKey: .lut)
            strength = try c.decodeIfPresent(Double.self, forKey: .strength)
            curves = try c.decodeIfPresent(Curves.self, forKey: .curves)
            lift = try c.decodeIfPresent(Double.self, forKey: .lift)
            sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen)
            chromatic = try c.decodeIfPresent(Double.self, forKey: .chromatic)
            halation = try c.decodeIfPresent(Halation.self, forKey: .halation)
            leak = try c.decodeIfPresent(Leak.self, forKey: .leak)
            vignette = try c.decodeIfPresent(Vignette.self, forKey: .vignette)
            grain = try c.decodeIfPresent(Grain.self, forKey: .grain)
            unknownKeys = try LookAnyKey.unknown(decoder, known: Set(CodingKeys.allCases.map(\.rawValue)))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(lut, forKey: .lut)
            try c.encodeIfPresent(strength, forKey: .strength)
            try c.encodeIfPresent(curves, forKey: .curves)
            try c.encodeIfPresent(lift, forKey: .lift)
            try c.encodeIfPresent(sharpen, forKey: .sharpen)
            try c.encodeIfPresent(chromatic, forKey: .chromatic)
            try c.encodeIfPresent(halation, forKey: .halation)
            try c.encodeIfPresent(leak, forKey: .leak)
            try c.encodeIfPresent(vignette, forKey: .vignette)
            try c.encodeIfPresent(grain, forKey: .grain)
        }

        /// The bundled look's id when `lut` is "pack:<id>".
        public var packId: String? { lut.flatMap { $0.hasPrefix("pack:") ? String($0.dropFirst(5)) : nil } }
        /// The imported LUT's asset id when `lut` isn't a pack reference.
        public var lutAssetId: String? { lut.flatMap { $0.hasPrefix("pack:") ? nil : $0 } }

        /// The colour-only part (curves, LUT, strength, lift): what the per-item colour cube bakes.
        public var colorPart: ColorPart { ColorPart(lut: lut, strength: strength, curves: curves, lift: lift) }
        public var hasSpatialSteps: Bool {
            (sharpen ?? 0) > 0 || (chromatic ?? 0) > 0 || (halation?.amount ?? 0) > 0 || (leak?.amount ?? 0) > 0
                || (vignette.map { $0.amount != 0 } ?? false) || (grain?.amount ?? 0) > 0
        }

        public struct ColorPart: Hashable, Sendable {
            public var lut: String?
            public var strength: Double?
            public var curves: Curves?
            public var lift: Double?
        }
    }

    /// A parsed 3D LUT (red changes fastest), values as Float like the reference's Float32Array.
    public struct Lut: Hashable, Sendable {
        public var size: Int
        public var title: String?
        public var domainMin: [Double]
        public var domainMax: [Double]
        public var data: [Float]
        public init(size: Int, title: String?, domainMin: [Double], domainMax: [Double], data: [Float]) {
            self.size = size; self.title = title; self.domainMin = domainMin; self.domainMax = domainMax; self.data = data
        }
    }

    public enum LookLimits {
        public static let maxLutSize = 64
        public static let minLutSize = 2
        public static let maxCubeBytes = 12 * 1024 * 1024
        public static let maxCurvePoints = 16
    }

    /// Why a .cube file was refused (the message names the line, as the server's).
    public struct CubeError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
        public var errorDescription: String? { message }
    }

    // MARK: .cube

    /// Parses an Adobe/Resolve .cube 3D LUT (red changes fastest). Throws CubeError with the line on anything invalid.
    public static func parseCube(_ text: String) throws -> Lut {
        let maxB = LookLimits.maxCubeBytes
        if text.utf16.count > maxB { throw CubeError("the file is over \(maxB / 1024 / 1024) MB") }
        var size = 0
        var title: String?
        var dmin: [Double] = [0, 0, 0], dmax: [Double] = [1, 1, 1]
        var data: [Float]?
        var n = 0
        let lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            var text = String(decoding: raw, as: UTF8.self)
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let at = "line \(i + 1)"
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let first = line.unicodeScalars.first!.value
            if first == 95 || (65...90).contains(first) || (97...122).contains(first) {
                let k = parts[0].uppercased()
                let rest = Array(parts.dropFirst())
                if k == "TITLE" {
                    var t = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasPrefix("\"") { t.removeFirst() }
                    if t.hasSuffix("\"") { t.removeLast() }
                    title = String(t.utf16.prefix(120)) ?? String(t.prefix(120))
                } else if k == "LUT_3D_SIZE" {
                    let v = rest.first.flatMap(jsNumber) ?? .nan
                    guard v.isFinite, v.rounded() == v, v >= Double(LookLimits.minLutSize), v <= Double(LookLimits.maxLutSize) else {
                        throw CubeError("\(at): LUT_3D_SIZE must be \(LookLimits.minLutSize)–\(LookLimits.maxLutSize)")
                    }
                    size = Int(v)
                    data = [Float](repeating: 0, count: size * size * size * 3)
                } else if k == "LUT_1D_SIZE" {
                    throw CubeError("\(at): 1D LUTs are not supported, use a 3D .cube")
                } else if k == "DOMAIN_MIN" || k == "DOMAIN_MAX" {
                    let v = rest.map { jsNumber($0) ?? .nan }
                    if v.count != 3 || v.contains(where: { !$0.isFinite }) { throw CubeError("\(at): \(k) needs three numbers") }
                    if k == "DOMAIN_MIN" { dmin = v } else { dmax = v }
                } else if k == "LUT_3D_INPUT_RANGE" {
                    let v = rest.map { jsNumber($0) ?? .nan }
                    if v.count != 2 || v.contains(where: { !$0.isFinite }) { throw CubeError("\(at): LUT_3D_INPUT_RANGE needs two numbers") }
                    dmin = [v[0], v[0], v[0]]
                    dmax = [v[1], v[1], v[1]]
                } // other keywords are ignored
                continue
            }
            guard data != nil else { throw CubeError("\(at): numbers before LUT_3D_SIZE") }
            let v = parts.map { jsNumber($0) ?? .nan }
            if v.count != 3 || v.contains(where: { !$0.isFinite }) { throw CubeError("\(at): expected three numbers") }
            if n >= size * size * size { throw CubeError("\(at): more than \(size)³ entries") }
            data![n * 3] = Float(v[0]); data![n * 3 + 1] = Float(v[1]); data![n * 3 + 2] = Float(v[2])
            n += 1
        }
        guard let data else { throw CubeError("no LUT_3D_SIZE line") }
        if n != size * size * size { throw CubeError("expected \(size)³ = \(size * size * size) entries, found \(n)") }
        for c in 0..<3 where !(dmax[c] > dmin[c]) { throw CubeError("DOMAIN_MAX must be above DOMAIN_MIN") }
        return Lut(size: size, title: title, domainMin: dmin, domainMax: dmax, data: data)
    }

    /// JavaScript's Number() for one whitespace-free token (nil = NaN).
    static func jsNumber(_ s: String) -> Double? {
        let l = s.lowercased()
        if l.contains("inf") || l.contains("nan") { return s == "Infinity" || s == "+Infinity" ? .infinity : s == "-Infinity" ? -.infinity : nil }
        if l.hasPrefix("0x") { return Int(l.dropFirst(2), radix: 16).map(Double.init) }
        return Double(s)
    }

    /// Writes a .cube (4 decimals, red fastest), like the reference's writeCube.
    public static func writeCube(size: Int, title: String, _ fn: (Double, Double, Double) -> SIMD3<Double>) -> String {
        var out = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX 1.0 1.0 1.0"]
        func f(_ v: Double) -> String { String(format: "%.4f", clamp(v, 0, 1)) }
        let m = Double(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            let o = fn(Double(r) / m, Double(g) / m, Double(b) / m)
            out.append("\(f(o.x)) \(f(o.y)) \(f(o.z))")
        } } }
        return out.joined(separator: "\n") + "\n"
    }

    /// Trilinear lookup.
    public static func lutSample(_ l: Lut, _ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> {
        let N = l.size, m = N - 1
        func pos(_ v: Double, _ c: Int) -> Double { clamp((v - l.domainMin[c]) / (l.domainMax[c] - l.domainMin[c]), 0, 1) * Double(m) }
        let fr = pos(r, 0), fg = pos(g, 1), fb = pos(b, 2)
        let r0 = Int(fr.rounded(.down)), g0 = Int(fg.rounded(.down)), b0 = Int(fb.rounded(.down))
        let r1 = min(m, r0 + 1), g1 = min(m, g0 + 1), b1 = min(m, b0 + 1)
        let dr = fr - Double(r0), dg = fg - Double(g0), db = fb - Double(b0)
        var out = SIMD3<Double>(0, 0, 0)
        l.data.withUnsafeBufferPointer { d in
            func at(_ ri: Int, _ gi: Int, _ bi: Int, _ c: Int) -> Double { Double(d[((bi * N + gi) * N + ri) * 3 + c]) }
            for c in 0..<3 {
                let c00 = at(r0, g0, b0, c) * (1 - dr) + at(r1, g0, b0, c) * dr
                let c10 = at(r0, g1, b0, c) * (1 - dr) + at(r1, g1, b0, c) * dr
                let c01 = at(r0, g0, b1, c) * (1 - dr) + at(r1, g0, b1, c) * dr
                let c11 = at(r0, g1, b1, c) * (1 - dr) + at(r1, g1, b1, c) * dr
                out[c] = (c00 * (1 - dg) + c10 * dg) * (1 - db) + (c01 * (1 - dg) + c11 * dg) * db
            }
        }
        return out
    }

    // MARK: Curves

    /// A tone curve through points (x ascending, both 0–1) with monotone cubic (Fritsch–Carlson) interpolation; flat
    /// beyond the end points. nil for fewer than 2 points.
    public static func curveFn(_ pts: CurvePoints?) -> ((Double) -> Double)? {
        guard let pts, pts.count >= 2, pts.allSatisfy({ $0.count == 2 }) else { return nil }
        let xs = pts.map { $0[0] }, ys = pts.map { $0[1] }, n = pts.count
        var d: [Double] = [], m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d.append((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])) }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        let ms = m
        return { x in
            if x <= xs[0] { return ys[0] }
            if x >= xs[n - 1] { return ys[n - 1] }
            var k = 0
            while k < n - 2 && x > xs[k + 1] { k += 1 }
            let h = xs[k + 1] - xs[k], t = (x - xs[k]) / h, t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * ms[k] + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * ms[k + 1]
        }
    }

    /// The four curves applied together (master, then the channel's own), clamped; nil when there is nothing to do.
    public static func curvesFn(_ c: Curves?) -> ((SIMD3<Double>) -> SIMD3<Double>)? {
        guard let c else { return nil }
        let master = curveFn(c.rgb), ch = [curveFn(c.r), curveFn(c.g), curveFn(c.b)]
        if master == nil && ch.allSatisfy({ $0 == nil }) { return nil }
        return { rgb in
            var o = SIMD3<Double>()
            for i in 0..<3 {
                var v = master.map { $0(rgb[i]) } ?? rgb[i]
                if let f = ch[i] { v = f(v) }
                o[i] = clamp(v, 0, 1)
            }
            return o
        }
    }

    // MARK: Noise, vignette, leak

    /// 32-bit integer hash (lowbias32) → 0…1, bit for bit the reference's (Math.imul ⇔ &*).
    public static func hash01(_ x: Int, _ y: Int, _ frame: Int) -> Double {
        var h = (UInt32(truncatingIfNeeded: x) &* 0x27d4_eb2d) ^ (UInt32(truncatingIfNeeded: y) &* 0x1656_67b1) ^ (UInt32(truncatingIfNeeded: frame) &* 0x9e37_79b9)
        h ^= h >> 16; h = h &* 0x7feb_352d
        h ^= h >> 15; h = h &* 0x846c_a68b
        h ^= h >> 16
        return Double(h) / 4_294_967_295
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t) }
    static let lookLuma = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// Vignette amount at u, w (0–1): smoothstep(size, size + softness, r), r = 1 at the corners.
    public static func vignetteMask(_ v: Vignette, _ u: Double, _ w: Double) -> Double {
        let dx = (u - 0.5) * 2, dy = (w - 0.5) * 2, r = (dx * dx + dy * dy).squareRoot() / 2.0.squareRoot()
        let size = clamp(v.size ?? 0.45, 0, 1), soft = max(0.05, clamp(v.softness ?? 0.5, 0, 1))
        return smoothstep(size, size + soft, r)
    }

    static func leakColors(_ k: LeakKind) -> (SIMD3<Double>, SIMD3<Double>) {
        switch k.rawValue {
        case "rose": return (SIMD3(1, 0.35, 0.45), SIMD3(1, 0.7, 0.6))
        case "amber": return (SIMD3(1, 0.65, 0.1), SIMD3(1, 0.9, 0.5))
        case "teal": return (SIMD3(0.2, 0.85, 0.85), SIMD3(0.6, 0.95, 1))
        case "rainbow": return (SIMD3(1, 0.3, 0.3), SIMD3(0.4, 0.6, 1))
        default: return (SIMD3(1, 0.55, 0.2), SIMD3(1, 0.8, 0.45))
        }
    }

    /// Light-leak colour (to screen over the picture) at u, v and time t seconds: a soft blob from one edge that drifts.
    public static func leakColor(_ l: Leak, _ u: Double, _ v: Double, _ t: Double) -> SIMD3<Double> {
        let a = (l.angle ?? 30) * Double.pi / 180 + 0.25 * sin(t * 0.6)
        let cx = 0.5 + 0.75 * cos(a), cy = 0.5 - 0.75 * sin(a)
        let d = ((u - cx) * (u - cx) + (v - cy) * (v - cy)).squareRoot()
        let k = clamp(l.amount, 0, 1) * (1 - smoothstep(0.15, 0.95, d))
        let (c0, c1) = leakColors(l.kind)
        let mix = smoothstep(0.1, 0.8, d)
        return k * (c0 * (1 - mix) + c1 * mix)
    }

    // MARK: Radii

    /// Pixel radii for the spatial steps, from the picture's short side (so they scale with resolution).
    public static func sharpenRadius(_ short: Int) -> Int { max(1, Int(jsRound(Double(short) * 0.0015))) }
    public static func halationRadius(_ short: Int, _ h: Halation) -> Int { max(1, Int(jsRound(Double(short) * 0.04 * clamp(h.radius ?? 0.5, 0.05, 1)))) }
    public static func grainCell(_ short: Int, _ g: Grain) -> Int { max(1, Int(jsRound(Double(short) / 1080 * clamp(g.size ?? 1, 0.5, 3)))) }

    // MARK: CPU renderer

    /// An RGB picture, row-major, values 0–1 (Float, like the reference's Float32Array).
    public struct LookImage: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var data: [Float]
        public init(width: Int, height: Int, data: [Float]) { self.width = width; self.height = height; self.data = data }
        @inline(__always) func px(_ x: Int, _ y: Int, _ c: Int) -> Double {
            Double(data[(min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 3 + c])
        }
        func bilinear(_ fx: Double, _ fy: Double, _ c: Int) -> Double {
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down)), dx = fx - Double(x0), dy = fy - Double(y0)
            return (px(x0, y0, c) * (1 - dx) + px(x0 + 1, y0, c) * dx) * (1 - dy) + (px(x0, y0 + 1, c) * (1 - dx) + px(x0 + 1, y0 + 1, c) * dx) * dy
        }
    }

    /// Box blur, separable, clamp to edge, radius in pixels (≥ 1).
    public static func boxBlur(_ img: LookImage, _ radius: Int) -> LookImage {
        let w = img.width, h = img.height, R = max(1, radius), n = Double(2 * R + 1)
        var tmp = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            var s = 0.0
            for k in -R...R { s += img.px(x + k, y, c) }
            tmp[(y * w + x) * 3 + c] = Float(s / n)
        } } }
        let t = LookImage(width: w, height: h, data: tmp)
        var out = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            var s = 0.0
            for k in -R...R { s += t.px(x, y + k, c) }
            out[(y * w + x) * 3 + c] = Float(s / n)
        } } }
        return LookImage(width: w, height: h, data: out)
    }

    /// Steps 3–6 (colour matrix, curves, LUT, lift) on one colour: what the per-item colour cube holds.
    public static func lookColor(_ rgbIn: SIMD3<Double>, matrix M: [Double]?, curves: ((SIMD3<Double>) -> SIMD3<Double>)?, lut L: Lut?,
                                 strength: Double, lift: Double) -> SIMD3<Double> {
        var rgb = rgbIn
        if let M, M.count == 12 {
            let i = rgb
            rgb = SIMD3((0..<3).map { k in clamp(M[k * 4] * i.x + M[k * 4 + 1] * i.y + M[k * 4 + 2] * i.z + M[k * 4 + 3], 0, 1) })
        }
        if let curves { rgb = curves(rgb) }
        if let L, strength > 0 {
            let t = lutSample(L, rgb.x, rgb.y, rgb.z)
            for k in 0..<3 { rgb[k] = clamp(rgb[k] + (t[k] - rgb[k]) * strength, 0, 1) }
        }
        if lift > 0 { rgb = SIMD3(repeating: lift) + rgb * (1 - lift) }
        return rgb
    }

    /// Renders a look on a picture. `matrix` = the item's colour matrix (colorMatrix, 3×4) or nil; `lut` = the resolved
    /// LUT or nil; `frame`/`fps` animate the grain and leak.
    public static func renderLook(_ img: LookImage, _ look: Look, matrix: [Double]? = nil, lut: Lut? = nil, frame: Int = 0, fps: Double = 30) -> LookImage {
        let w = img.width, h = img.height, short = min(w, h)
        guard w > 0, h > 0 else { return img }
        var src = img
        // 1. sharpen
        let sh = clamp(look.sharpen ?? 0, 0, 1)
        if sh > 0 {
            let bl = boxBlur(src, sharpenRadius(short))
            var d = [Float](repeating: 0, count: src.data.count)
            for i in 0..<d.count { let v = Double(src.data[i]); d[i] = Float(clamp(v + 1.5 * sh * (v - Double(bl.data[i])), 0, 1)) }
            src = LookImage(width: w, height: h, data: d)
        }
        // 2. chromatic aberration (red out, blue in, from the centre)
        let ca = clamp(look.chromatic ?? 0, 0, 1) * 0.006
        let curves = curvesFn(look.curves)
        let strength = clamp(look.strength ?? 1, 0, 1)
        let lift = 0.12 * clamp(look.lift ?? 0, 0, 1)
        var out = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            var rgb: SIMD3<Double>
            if ca > 0 {
                let u = (Double(x) + 0.5) / Double(w) - 0.5, v = (Double(y) + 0.5) / Double(h) - 0.5
                rgb = SIMD3(src.bilinear(Double(x) + u * ca * Double(w), Double(y) + v * ca * Double(h), 0), src.px(x, y, 1),
                            src.bilinear(Double(x) - u * ca * Double(w), Double(y) - v * ca * Double(h), 2))
            } else {
                rgb = SIMD3(src.px(x, y, 0), src.px(x, y, 1), src.px(x, y, 2))
            }
            // 3–6. colour matrix, curves, LUT, lift
            rgb = lookColor(rgb, matrix: matrix, curves: curves, lut: lut, strength: strength, lift: lift)
            let i = (y * w + x) * 3
            out[i] = Float(rgb.x); out[i + 1] = Float(rgb.y); out[i + 2] = Float(rgb.z)
        } }
        // 7. halation: blurred highlights, warm red, screened on
        if let ha = look.halation, ha.amount > 0 {
            let thr = clamp(ha.threshold ?? 0.7, 0, 0.99), k = clamp(ha.amount, 0, 1)
            let bl = boxBlur(LookImage(width: w, height: h, data: out), halationRadius(short, ha))
            let tint: [Double] = [1, 0.35, 0.2]
            for i in 0..<(w * h) {
                let l = lookLuma.x * Double(bl.data[i * 3]) + lookLuma.y * Double(bl.data[i * 3 + 1]) + lookLuma.z * Double(bl.data[i * 3 + 2])
                let hgl = clamp((l - thr) / (1 - thr), 0, 1) * k
                for c in 0..<3 { out[i * 3 + c] = Float(1 - (1 - Double(out[i * 3 + c])) * (1 - tint[c] * hgl)) }
            }
        }
        let t = Double(frame) / fps
        let vg = look.vignette.flatMap { $0.amount != 0 ? $0 : nil }
        let gr = look.grain.flatMap { $0.amount > 0 ? $0 : nil }
        let lk = look.leak.flatMap { $0.amount > 0 ? $0 : nil }
        if vg != nil || gr != nil || lk != nil {
            let cell = gr.map { grainCell(short, $0) } ?? 1, ga = gr.map { clamp($0.amount, 0, 1) * 0.18 } ?? 0, va = vg.map { clamp($0.amount, -1, 1) } ?? 0
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 3, u = (Double(x) + 0.5) / Double(w), v = (Double(y) + 0.5) / Double(h)
                // 8. light leak (screen)
                if let lk {
                    let c = leakColor(lk, u, v, t)
                    for k in 0..<3 { out[i + k] = Float(1 - (1 - Double(out[i + k])) * (1 - c[k])) }
                }
                // 9. vignette
                if let vg {
                    let m = vignetteMask(vg, u, v)
                    for k in 0..<3 { let o = Double(out[i + k]); out[i + k] = Float(va > 0 ? o * (1 - va * m) : o + -va * m * (1 - o)) }
                }
                // 10. grain: mono, strongest in the mid-tones, cells of `cell` px, a new pattern every frame
                if gr != nil {
                    let n = hash01(x / cell, y / cell, frame) - 0.5
                    let l = lookLuma.x * Double(out[i]) + lookLuma.y * Double(out[i + 1]) + lookLuma.z * Double(out[i + 2])
                    let g = ga * n * (1 - abs(2 * l - 1) * 0.5)
                    for k in 0..<3 { out[i + k] = Float(Double(out[i + k]) + g) }
                }
                for k in 0..<3 { out[i + k] = Float(clamp(Double(out[i + k]), 0, 1)) }
            } }
        }
        return LookImage(width: w, height: h, data: out)
    }

    // MARK: Validation (called by validate)

    /// The first problem of an item's look (field relative to the look, "" = the look itself), or nil.
    /// `packIds` empty = any "pack:<id>" is accepted.
    public static func lookProblem(_ look: Look?, assetKinds: [String: AssetKind], packIds: Set<String>) -> EditProblem? {
        guard let l = look else { return nil }
        func num(_ f: String, _ v: Double?, _ lo: Double, _ hi: Double, optional: Bool = true) -> EditProblem? {
            guard let v else { return optional ? nil : EditProblem(f, "must be a number from \(fmtNum(lo)) to \(fmtNum(hi))") }
            return !v.isFinite || v < lo || v > hi ? EditProblem(f, "must be a number from \(fmtNum(lo)) to \(fmtNum(hi))") : nil
        }
        if let lut = l.lut {
            if lut.hasPrefix("pack:") {
                if !packIds.isEmpty && !packIds.contains(String(lut.dropFirst(5))) { return EditProblem("lut", "unknown look") }
            } else if assetKinds[lut] != .lut {
                return EditProblem("lut", "must be \"pack:<id>\" or a lut asset id")
            }
        }
        if let p = num("strength", l.strength, 0, 1) ?? num("lift", l.lift, 0, 1) ?? num("sharpen", l.sharpen, 0, 1) ?? num("chromatic", l.chromatic, 0, 1) {
            return p
        }
        if let c = l.curves {
            // The reference walks the keys in the JSON's order; here the known curves come first, then unknown keys.
            let lists: [(String, CurvePoints?)] = [("rgb", c.rgb), ("r", c.r), ("g", c.g), ("b", c.b)]
            for (k, pts) in lists {
                guard let pts else { continue }
                if pts.count < 2 || pts.count > LookLimits.maxCurvePoints { return EditProblem("curves.\(k)", "2–\(LookLimits.maxCurvePoints) points") }
                var prev = -1.0
                for (i, p) in pts.enumerated() {
                    if p.count != 2 || p.contains(where: { !$0.isFinite || $0 < 0 || $0 > 1 }) { return EditProblem("curves.\(k).\(i)", "must be [x, y], each 0–1") }
                    if p[0] <= prev { return EditProblem("curves.\(k).\(i)", "x must increase") }
                    prev = p[0]
                }
            }
            if let k = c.unknownKeys.first { return EditProblem("curves.\(k)", "unknown curve") }
        }
        if let g = l.grain, let p = num("grain.amount", g.amount, 0, 1, optional: false) ?? num("grain.size", g.size, 0.5, 3) { return p }
        if let v = l.vignette, let p = num("vignette.amount", v.amount, -1, 1, optional: false) ?? num("vignette.size", v.size, 0, 1)
            ?? num("vignette.softness", v.softness, 0, 1) { return p }
        if let h = l.halation, let p = num("halation.amount", h.amount, 0, 1, optional: false) ?? num("halation.radius", h.radius, 0.05, 1)
            ?? num("halation.threshold", h.threshold, 0, 0.99) { return p }
        if let k = l.leak, let p = num("leak.amount", k.amount, 0, 1, optional: false) ?? num("leak.angle", k.angle, -360, 360) { return p }
        if let k = l.leak, !k.kind.isKnown { return EditProblem("leak.kind", "one of " + LeakKind.all.map(\.rawValue).joined(separator: ", ")) }
        if let extra = l.unknownKeys.first { return EditProblem(extra, "is not a look setting") }
        return nil
    }

    static func fmtNum(_ v: Double) -> String { v.rounded() == v && abs(v) < 1e15 ? String(Int(v)) : "\(v)" }
}

/// Any JSON object key, to find the keys a Codable type doesn't know.
struct LookAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    static func unknown(_ decoder: Decoder, known: Set<String>) throws -> [String] {
        try decoder.container(keyedBy: LookAnyKey.self).allKeys.map(\.stringValue).filter { !known.contains($0) }
    }
}
