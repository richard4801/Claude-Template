// Claude's orb (owner, 2026-11-12: Option C2 "alive"; plans/design/claude-panel/orb-alive-*.png, orb-alive-preview.mp4):
// a glass ball with luminous 3D smoke inside. A ray is marched through the ball (front to back, with absorption) in a
// density field of domain-warped 3D noise advected by a slowly evolving flow; it is emissive (magenta, violet, blue,
// cyan, a gold accent), white-hot where dense, with a soft self-shadow. The glass lives with it: a soft-body wobble of
// the silhouette, a breathing scale, a tiny drift and a tilt of the reflections; the rim and highlight deform with it.
// No glint, no halo. The same shader as design/direction/orb_alive.py (GLSL), line for line: keep them in step. Used
// through SwiftUI's colorEffect (ShaderLibrary.claudeOrb); the page behind is passed as its tone (pageColor).
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant int STEPS = 22;

struct Orb { float phase, time, bright, spin, danger, pulse, breath, light, wobble, pop; };

// smoothstep that also takes falling edges (Metal leaves edge0 >= edge1 undefined; the GLSL preview relies on it).
static float sstep(float e0, float e1, float x) { float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

static float hash3(float3 p) { return fract(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453); }
static float noise3(float3 p) {
    float3 i = floor(p), f = fract(p); float3 u = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash3(i), hash3(i + float3(1, 0, 0)), u.x), mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), u.x), u.y);
    float b = mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), u.x), mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), u.x), u.y);
    return mix(a, b, u.z);
}
static float fbm4(float3 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise3(p); p = p * 2.07 + float3(1.7, 9.2, 4.1); a *= 0.5; } return v; }
static float fbm3(float3 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { v += a * noise3(p); p = p * 2.07 + float3(1.7, 9.2, 4.1); a *= 0.5; } return v; }

// The smoke's colour where it is: magenta, violet, blue, cyan regions with a gold accent (error: red, orange, amber).
static float3 dye(float3 p, Orb o) {
    float h = fbm3(p * 0.9 + float3(11.0, 3.0, o.phase * 0.05));
    float g = sstep(0.62, 0.75, fbm3(p * 1.3 + float3(-4.0, 7.0, 2.0)));
    float3 m = float3(1.0, 0.24, 0.66), v = float3(0.56, 0.33, 1.0), bl = float3(0.22, 0.48, 1.0), c = float3(0.15, 0.9, 0.95);
    float t = clamp((h - 0.3) * 2.5, 0.0, 1.0) * 3.0;
    float3 col = t < 1.0 ? mix(m, v, t) : t < 2.0 ? mix(v, bl, t - 1.0) : mix(bl, c, t - 2.0);
    col = mix(col, float3(1.0, 0.72, 0.3), g * 0.8);
    float3 err = mix(float3(1.0, 0.25, 0.1), float3(1.0, 0.62, 0.15), clamp((h - 0.35) * 3.0, 0.0, 1.0));
    return mix(col, err, o.danger);
}

// Density: 3D noise warped by a flow that evolves with time (a fourth dimension), rising; a current when operating.
static float density(float3 p, thread float3 &q, Orb o) {
    float t = o.phase;
    float3 w = float3(fbm3(p * 1.1 + float3(0.0, -t * 0.18, t * 0.07)), fbm3(p * 1.1 + float3(5.2, 1.3 - t * 0.2, -t * 0.05)), fbm3(p * 1.1 + float3(2.7, 8.1, t * 0.09)));
    q = p + (w - 0.5) * 1.3 + float3(-o.spin * t * 0.5, -t * 0.12, 0.0);
    float d = fbm4(q * 2.8 + float3(0.0, 0.0, t * 0.04));
    float edge = sstep(0.86, 0.45, length(p));
    float low = mix(1.15, 0.6, sstep(-0.6, 0.7, p.y));
    float thick = mix(0.5, 0.42, o.danger) - 0.04 * o.bright;
    d = sstep(thick, thick + 0.2, d) * edge * low;
    // A streamed chunk: a bright plume rising from below and unfurling.
    float age = 1.0 - o.pulse;
    float3 c = float3(0.18 * sin(o.time * 1.3), -0.55 + 0.55 * age, 0.1 * cos(o.time * 1.1));
    d += o.pulse * sstep(0.32 + 0.2 * age, 0.0, length((p - c) * float3(1.0, 0.7, 1.0)) - 0.15 * (fbm3(p * 4.0 + t) - 0.5));
    return d;
}

[[ stitchable ]] half4 claudeOrb(float2 position, half4 color, float2 size, float scale, float phase, float time, float brightIn,
                                 float spin, float danger, float pulse, float breath, float lightPage, float wobble, float pop, half4 page) {
    Orb o = { phase, time, brightIn, spin, danger, pulse, breath, lightPage, wobble, pop };
    // Metal's y runs down; the preview's runs up: flip so both draw the same picture.
    float2 px = float2(position.x - 0.5 * size.x, 0.5 * size.y - position.y) / (0.5 * min(size.x, size.y)) * scale;
    // The living glass: drift and lean with the flow, a breathing scale, a soft-body wobble bulging where the smoke presses.
    float2 drift = float2(0.012 * sin(phase * 0.31) + 0.015 * spin, 0.01 * cos(phase * 0.27));
    float ang = atan2(px.y - drift.y, px.x - drift.x);
    float3 dir = float3(cos(ang), sin(ang), 0.0);
    float press = fbm3(dir * 0.9 + float3(0.0, -phase * 0.12, phase * 0.05));
    float wob = (fbm3(dir * 1.4 + float3(phase * 0.2, 3.0, -phase * 0.15)) - 0.5) * 2.0;
    float shape = (1.0 + pop) * (1.0 + wobble * (0.6 * wob + 0.8 * (press - 0.45)));
    float2 uv = (px - drift) / shape;
    float r = length(uv);
    if (r >= 1.0) { return half4(0.0); }
    float nz = sqrt(1.0 - r * r);
    float bright = brightIn * (1.0 + 0.5 * pulse) * (1.0 - 0.3 * breath);

    // The page behind: its tone (the preview also shows a faint flipped hint; at panel sizes it is invisible).
    bool light = lightPage > 0.5;
    float shade = mix(light ? 0.9 : 0.03, light ? 0.97 : 0.3, sstep(0.3, -0.9, uv.y));
    float3 glass = float3(page.rgb) * shade + (light ? float3(0.0) : float3(0.015, 0.015, 0.025));

    // March the ray through the volume, front to back: emission with absorption and a soft self-shadow.
    float z0 = nz * 0.9, z1 = -nz * 0.9, dz = (z0 - z1) / float(STEPS);
    float3 acc = float3(0.0); float T = 1.0;
    for (int i = 0; i < STEPS; i++) {
        float z = z0 - (float(i) + 0.5) * dz;
        float3 p = float3(uv, z);
        float3 q;
        float d = density(p, q, o);
        if (d > 0.01) {
            float3 qs;
            float sh = density(p + float3(-0.12, 0.16, 0.12), qs, o);
            float3 col = dye(q, o);
            float hot = sstep(0.45, 0.95, d);
            float3 e = mix(col, float3(1.0, 0.97, 0.95), hot * 0.85) * d * (1.0 + 0.5 * hot) * (1.0 - 0.45 * clamp(sh, 0.0, 1.0));
            e *= mix(0.55, 1.0, (z - z1) / max(z0 - z1, 1e-3));
            acc += T * e * dz * 6.5 * bright;
            T *= exp(-d * dz * 4.5);
            if (T < 0.03) break;
        }
    }
    float dense = 1.0 - T;

    // The glass: a thin soft rim (bottom-left and right brightest) with a chromatic fringe, lit by the smoke near it;
    // a broad dim reflection on top that turns a little with the flow.
    float f = pow(1.0 - nz, 3.0);
    float where = 0.35 + 0.65 * max(sstep(0.4, -0.9, uv.y) * sstep(0.2, -0.8, uv.x), sstep(0.3, 0.95, uv.x));
    float3 smokeTint = acc / max(0.15, max(acc.r, max(acc.g, acc.b)));
    float3 rim = float3(f, pow(f, 1.15), pow(f, 1.3)) * 0.55 * where + smokeTint * f * 0.5 * clamp(dense * 2.0, 0.0, 1.0) * bright;
    float tiltA = 0.07 * sin(phase * 0.23) + 0.09 * spin;
    float2 su = float2(cos(tiltA) * uv.x - sin(tiltA) * uv.y, sin(tiltA) * uv.x + cos(tiltA) * uv.y);
    float3 spec = float3(1.0) * exp(-(pow(su.x + 0.12, 2.0) / 0.22 + pow(su.y - 0.62, 2.0) / 0.035)) * 0.16;

    float3 col;
    if (light) {
        // On a light page the smoke is dye over the clear glass (light can't brighten white): vivid, never grey.
        float a = clamp(dense * 1.25, 0.0, 0.95);
        float3 dyeC = clamp(acc / max(0.2, max(acc.r, max(acc.g, acc.b))), 0.0, 1.0);
        col = mix(glass, dyeC, a) + rim * 0.55 - float3(0.05) * f + spec * 0.6;
    } else {
        float3 lit = 1.0 - exp(-acc * 1.15);
        col = glass * T + lit + rim + spec;
    }
    float aa = sstep(1.0, 0.985, r);
    return half4(half3(clamp(col, 0.0, 1.0) * aa), half(aa));
}
