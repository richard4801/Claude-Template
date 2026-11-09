import CoreImage
import Foundation
import MuseCore

/// The effects library on the Mac (WS8 f7226f2): one Core Image kernel that follows effects.ts step for step (EditV2's
/// effectPixel is the CPU reference, checked against the shared fixture). The noise reads Perlin's permutation from a
/// 256×1 image with nearest sampling, so it's exact. Applied in the picture's own frame (origin 0,0), after its look and
/// before its mask and transform.
enum EditV2EffectRenderer {
    /// Perlin's permutation as a 256×1 single-channel image, no colour management (values exact).
    private static let perm: CIImage = {
        let bytes = Data(EditV2.effectPerm.map { UInt8($0) })
        return CIImage(bitmapData: bytes, bytesPerRow: 256, size: CGSize(width: 256, height: 1), format: .R8, colorSpace: nil)
            .samplingNearest()
    }()

    private static let ids: [String: Float] = Dictionary(uniqueKeysWithValues: EditV2.effectIds.enumerated().map { ($0.element, Float($0.offset)) })

    static let kernel: CIKernel? = CIKernel(source: """
        float museP(sampler perm, float i) {
            float x = mod(floor(i), 256.0);
            return floor(sample(perm, samplerTransform(perm, vec2(x + 0.5, 0.5))).r * 255.0 + 0.5);
        }
        float museH(sampler perm, float i, float j, float k) { return museP(perm, museP(perm, museP(perm, i) + j) + k) / 255.0; }
        vec4 museS(sampler src, vec2 size, float u, float v) {
            vec4 c = sample(src, samplerTransform(src, vec2(u * size.x, (1.0 - v) * size.y)));
            return c;
        }
        vec3 museRgb(vec4 c) { return c.a > 0.0001 ? c.rgb / c.a : vec3(0.0); }
        kernel vec4 museEffect(sampler src, sampler perm, vec2 size, float id, float a, float t, float ts, vec3 dark, vec3 light) {
            vec2 d = destCoord();
            float u = d.x / size.x, v = 1.0 - d.y / size.y;
            float W = size.x, H = size.y;
            vec4 base = museS(src, size, u, v);
            float al = base.a;
            vec3 o = museRgb(base);
            if (id < 0.5) { // glitch
                float n = floor(ts * 12.0), b = floor(v * 16.0);
                float u2 = museH(perm, b, n, 1.0) > 1.0 - 0.5 * a ? u + (museH(perm, b, n, 2.0) - 0.5) * 0.2 * a : u;
                float sp = 0.015 * a;
                vec4 g = museS(src, size, u2, v);
                o = vec3(museRgb(museS(src, size, u2 + sp, v)).r, museRgb(g).g, museRgb(museS(src, size, u2 - sp, v)).b);
                al = g.a;
            } else if (id < 1.5) { // vhs
                float u2 = u + sin(40.0 * v + 6.0 * ts) * 0.004 * a;
                vec4 g = museS(src, size, u2, v);
                vec3 c = vec3(museRgb(museS(src, size, u2 + 0.006 * a, v)).r, museRgb(g).g, museRgb(museS(src, size, u2 - 0.006 * a, v)).b);
                float scan = 1.0 - 0.2 * a * (0.5 + 0.5 * cos(6.283185307179586 * 240.0 * v));
                float nz = (museH(perm, floor(320.0 * u), floor(240.0 * v), floor(24.0 * ts)) - 0.5) * 0.1 * a;
                o = clamp(c * scan + nz, 0.0, 1.0);
                al = g.a;
            } else if (id < 2.5) { // film
                vec4 s0 = museS(src, size, u + sin(7.0 * ts) * 0.002 * a, v + cos(5.0 * ts) * 0.002 * a);
                vec3 c = museRgb(s0);
                float g = (museH(perm, floor(480.0 * u), floor(480.0 * v), floor(24.0 * t)) - 0.5) * 0.16 * a;
                float dust = museH(perm, floor(160.0 * u), floor(160.0 * v), floor(12.0 * ts) + 7.0) >= 1.0 - 0.02 * a ? 0.35 : 1.0;
                o = clamp(vec3((c.r + g) * dust * (1.0 + 0.05 * a), (c.g + g) * dust, (c.b + g) * dust * (1.0 - 0.05 * a)), 0.0, 1.0);
                al = s0.a;
            } else if (id < 3.5) { // blur
                float R = 0.02 * a;
                vec4 acc = vec4(0.0);
                float sum = 0.0;
                for (int i = 0; i < 13; i++) { float x = (float(i) - 6.0) / 3.0; sum += exp(-0.5 * x * x); }
                for (int i = 0; i < 13; i++) {
                    float xi = (float(i) - 6.0) / 3.0;
                    float wi = exp(-0.5 * xi * xi) / sum;
                    for (int j = 0; j < 13; j++) {
                        float xj = (float(j) - 6.0) / 3.0;
                        float wj = exp(-0.5 * xj * xj) / sum;
                        acc += wi * wj * museS(src, size, u + ((float(i) - 6.0) * R / 6.0) * H / W, v + (float(j) - 6.0) * R / 6.0);
                    }
                }
                return acc;
            } else if (id < 4.5) { // zoomBlur
                vec4 acc = vec4(0.0);
                for (int k = 0; k < 10; k++) {
                    float z = 1.0 - 0.15 * a * float(k) / 9.0;
                    acc += museS(src, size, 0.5 + (u - 0.5) * z, 0.5 + (v - 0.5) * z) / 10.0;
                }
                return acc;
            } else if (id < 5.5) { // mirror
                float u2 = u < 0.5 ? u : 1.0 - u;
                float v2 = a >= 0.5 ? (v < 0.5 ? v : 1.0 - v) : v;
                return museS(src, size, u2, v2);
            } else if (id < 6.5) { // pixelate
                float n = floor(160.0 - 150.0 * a + 0.5), cw = 1.0 / n, ch = cw * W / H;
                return museS(src, size, (floor(u / cw) + 0.5) * cw, (floor(v / ch) + 0.5) * ch);
            } else if (id < 7.5) { // posterize
                float L = floor(16.0 - 13.0 * a + 0.5);
                o = floor(o * (L - 1.0) + 0.5) / (L - 1.0);
            } else if (id < 8.5) { // duotone
                float y = 0.2126 * o.r + 0.7152 * o.g + 0.0722 * o.b;
                o = mix(o, mix(dark, light, y), a);
            } else if (id < 9.5) { // shake
                float n = floor(15.0 * ts), z = 1.0 + 0.05 * a;
                return museS(src, size, 0.5 + (u - 0.5) / z + (museH(perm, n, 3.0, 0.0) - 0.5) * 0.04 * a,
                             0.5 + (v - 0.5) / z + (museH(perm, n, 4.0, 0.0) - 0.5) * 0.04 * a);
            } else if (id < 10.5) { // flash
                float f = max(0.0, 1.0 - 4.0 * fract(ts));
                o = o + (1.0 - o) * f * a;
            } else { // rain
                float cx = floor(48.0 * u);
                bool on = museH(perm, cx, 5.0, 0.0) < 0.6;
                float sp = 0.4 + 0.8 * museH(perm, cx, 6.0, 0.0);
                float y0 = fract(museH(perm, cx, 7.0, 0.0) + ts * sp);
                float dd = fract(v - y0);
                float i = (on && dd < 0.08) ? 1.0 - dd / 0.08 : 0.0;
                vec4 s0 = museS(src, size, u + 0.006 * a * i, v);
                o = clamp(museRgb(s0) + 0.12 * a * i, 0.0, 1.0);
                al = s0.a;
            }
            return vec4(o * al, al);
        }
        """)

    /// `img` (origin 0,0) with `e` at item-local time `t`; unchanged when the kernel isn't available or the effect is unknown.
    static func apply(_ e: EditV2.Effect, to img: CIImage, t: Double) -> CIImage {
        guard let kernel, let id = ids[e.id] else { return img }
        let a = min(1, max(0, e.amount)), ts = t * (e.speed ?? 1)
        let ext = img.extent
        guard ext.width > 0, ext.height > 0 else { return img }
        let colors = (e.colors ?? EditV2.duotoneDefault).map { EditV2.hexRgb($0) }
        let dark = colors.first ?? (0, 0, 0), light = colors.count > 1 ? colors[1] : (1, 1, 1)
        let src = img.clampedToExtent()
        let out = kernel.apply(extent: ext, roiCallback: { index, rect in index == 1 ? CGRect(x: 0, y: 0, width: 256, height: 1) : ext.insetBy(dx: -ext.width, dy: -ext.height) },
                               arguments: [src, perm, CIVector(x: ext.width, y: ext.height), id, a, t, ts,
                                           CIVector(x: dark.0, y: dark.1, z: dark.2), CIVector(x: light.0, y: light.1, z: light.2)])
        return out ?? img
    }
}
