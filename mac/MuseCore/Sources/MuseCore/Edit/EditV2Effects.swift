import Foundation

// The effects library (WS8 f7226f2, server/api/src/editor/effects.ts): the reference maths, pixel by pixel. The Mac draws
// the effects with Core Image kernels that follow these steps; this CPU version is checked against the shared fixture
// (functions.json effects) and the kernels against it.

extension EditV2 {
    /// Ken Perlin's permutation (improved noise, 2002).
    public static let effectPerm: [Int] = [151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180]

    static func m256(_ i: Double) -> Int { ((Int(i.rounded(.down)) % 256) + 256) % 256 }
    /// Noise in [0, 1] from three integers: exact on every platform.
    public static func hash3(_ i: Double, _ j: Double, _ k: Double) -> Double {
        Double(effectPerm[m256(Double(effectPerm[m256(Double(effectPerm[m256(i)]) + j)]) + k)]) / 255
    }

    public typealias RGB = SIMD3<Double>
    public typealias Sampler = (Double, Double) -> RGB

    /// One output pixel of `e` at (u, v) of a W×H frame at item-local time t.
    public static func effectPixel(_ e: Effect, t: Double, width W: Double, height H: Double, u: Double, v: Double, sample: Sampler) -> RGB {
        let a = min(1, max(0, e.amount)), s = e.speed ?? 1, ts = t * s
        func fract(_ x: Double) -> Double { x - x.rounded(.down) }
        func c01(_ x: Double) -> Double { min(1, max(0, x)) }
        if a <= 0 { return sample(u, v) }
        switch e.id {
        case "glitch":
            let n = (ts * 12).rounded(.down), b = (v * 16).rounded(.down)
            let u2 = hash3(b, n, 1) > 1 - 0.5 * a ? u + (hash3(b, n, 2) - 0.5) * 0.2 * a : u
            let sp = 0.015 * a
            return RGB(sample(u2 + sp, v).x, sample(u2, v).y, sample(u2 - sp, v).z)
        case "vhs":
            let u2 = u + sin(40 * v + 6 * ts) * 0.004 * a
            let c = RGB(sample(u2 + 0.006 * a, v).x, sample(u2, v).y, sample(u2 - 0.006 * a, v).z)
            let scan = 1 - 0.2 * a * (0.5 + 0.5 * cos(2 * .pi * 240 * v))
            let nz = (hash3((320 * u).rounded(.down), (240 * v).rounded(.down), (24 * ts).rounded(.down)) - 0.5) * 0.1 * a
            return RGB(c01(c.x * scan + nz), c01(c.y * scan + nz), c01(c.z * scan + nz))
        case "film":
            let c = sample(u + sin(7 * ts) * 0.002 * a, v + cos(5 * ts) * 0.002 * a)
            let g = (hash3((480 * u).rounded(.down), (480 * v).rounded(.down), (24 * t).rounded(.down)) - 0.5) * 0.16 * a
            let dust = hash3((160 * u).rounded(.down), (160 * v).rounded(.down), (12 * ts).rounded(.down) + 7) >= 1 - 0.02 * a ? 0.35 : 1
            return RGB(c01((c.x + g) * dust * (1 + 0.05 * a)), c01((c.y + g) * dust), c01((c.z + g) * dust * (1 - 0.05 * a)))
        case "blur":
            let R = 0.02 * a
            let w = (0..<13).map { exp(-0.5 * pow((Double($0) - 6) / 3, 2)) }
            let sum = w.reduce(0, +)
            var out = RGB(0, 0, 0)
            for i in 0..<13 {
                for j in 0..<13 {
                    let k = (w[i] / sum) * (w[j] / sum)
                    out += k * sample(u + ((Double(i) - 6) * R / 6) * H / W, v + (Double(j) - 6) * R / 6)
                }
            }
            return out
        case "zoomBlur":
            var out = RGB(0, 0, 0)
            for k in 0..<10 {
                let z = 1 - 0.15 * a * Double(k) / 9
                out += sample(0.5 + (u - 0.5) * z, 0.5 + (v - 0.5) * z) / 10
            }
            return out
        case "mirror":
            let u2 = u < 0.5 ? u : 1 - u
            let v2 = a >= 0.5 ? (v < 0.5 ? v : 1 - v) : v
            return sample(u2, v2)
        case "pixelate":
            let n = (160 - 150 * a).rounded(), cw = 1 / n, ch = cw * W / H
            return sample(((u / cw).rounded(.down) + 0.5) * cw, ((v / ch).rounded(.down) + 0.5) * ch)
        case "posterize":
            let L = (16 - 13 * a).rounded()
            let c = sample(u, v)
            return RGB((c.x * (L - 1)).rounded() / (L - 1), (c.y * (L - 1)).rounded() / (L - 1), (c.z * (L - 1)).rounded() / (L - 1))
        case "duotone":
            let cs = (e.colors ?? duotoneDefault).map { h -> RGB in let (r, g, b) = hexRgb(h); return RGB(r, g, b) }
            let c = sample(u, v)
            let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let d = cs[0] + (cs[1] - cs[0]) * y
            return c + (d - c) * a
        case "shake":
            let n = (15 * ts).rounded(.down), z = 1 + 0.05 * a
            return sample(0.5 + (u - 0.5) / z + (hash3(n, 3, 0) - 0.5) * 0.04 * a, 0.5 + (v - 0.5) / z + (hash3(n, 4, 0) - 0.5) * 0.04 * a)
        case "flash":
            let f = max(0, 1 - 4 * fract(ts))
            let c = sample(u, v)
            return c + (RGB(1, 1, 1) - c) * f * a
        case "rain":
            let cx = (48 * u).rounded(.down)
            let on = hash3(cx, 5, 0) < 0.6
            let sp = 0.4 + 0.8 * hash3(cx, 6, 0)
            let y0 = fract(hash3(cx, 7, 0) + ts * sp)
            let d = fract(v - y0)
            let i = on && d < 0.08 ? 1 - d / 0.08 : 0
            let c = sample(u + 0.006 * a * i, v)
            return RGB(c01(c.x + 0.12 * a * i), c01(c.y + 0.12 * a * i), c01(c.z + 0.12 * a * i))
        default:
            return sample(u, v)
        }
    }

    /// A sampler over a W×H RGB image (row-major, 0–1): bilinear between pixel centres, clamped at the edges.
    public static func imageSampler(width W: Int, height H: Int, _ px: [RGB]) -> Sampler {
        func at(_ x: Int, _ y: Int) -> RGB { px[min(H - 1, max(0, y)) * W + min(W - 1, max(0, x))] }
        return { u, v in
            let fx = min(Double(W) - 0.5, max(0.5, u * Double(W))) - 0.5, fy = min(Double(H) - 0.5, max(0.5, v * Double(H))) - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down)), dx = fx - Double(x0), dy = fy - Double(y0)
            let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
            return (a * (1 - dx) + b * dx) * (1 - dy) + (c * (1 - dx) + d * dx) * dy
        }
    }
}
