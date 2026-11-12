"""Claude's orb, frosted (owner, 2026-11-12: "frosted glass in the spirit of Apple's Liquid Glass", orb AND panel; "the smoke
glows through the frost, softened: vivid in the centre, diffused toward the edge"). C2 alive's living smoke and living
glass (wobble, pop, drift, tilt, the five states) with a frosted shell instead of clear glass: the backdrop behind it
blurred and lightened (the system material on the Mac), a milky diffuse body, crisp refractive edges with a slight
chromatic split that slide with the wobble, a broad soft highlight, and the smoke scattered through the frost (finer and
brighter in the core, wider, softer and lower in contrast toward the rim). Dark and light.

    python3 design/direction/orb_frost.py            # FROST_STILLS=1 skips the MP4
    → plans/design/claude-panel/orb-frost-states.png   (256 px, five states, dark and light, text behind)
      plans/design/claude-panel/orb-frost-small.png    (32 pt over panel text, dark and light)
      plans/design/claude-panel/orb-frost-preview.mp4  (10 s: 3 s idle, 3 s thinking, then the others; dark and light)
"""
import json, os, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans/design/claude-panel"
FONT = (REPO / "android/app/src/main/res/font/barlow_400.ttf").as_uri()

FRAG = r"""
precision highp float;
uniform sampler2D uBack; uniform vec2 uTex, uCenter; uniform float uRadius;
uniform float uPhase, uTime, uBright, uWidth, uWisps, uRipple, uSpin, uDanger, uPulse, uBreath, uLight, uWobble, uPop, uOverlay;
const int STEPS = 22;

vec3 back(vec2 px) { return texture2D(uBack, clamp(px / uTex, 0.0, 1.0)).rgb; }
float hash3(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise3(vec3 p) {
  vec3 i = floor(p), f = fract(p); vec3 u = f * f * (3.0 - 2.0 * f);
  float a = mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), u.x), mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), u.x), u.y);
  float b = mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), u.x), mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), u.x), u.y);
  return mix(a, b, u.z);
}
float fbm4(vec3 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise3(p); p = p * 2.07 + vec3(1.7, 9.2, 4.1); a *= 0.5; } return v; }
float fbm3(vec3 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { v += a * noise3(p); p = p * 2.07 + vec3(1.7, 9.2, 4.1); a *= 0.5; } return v; }

// The smoke's colour where it is: magenta, violet, blue, cyan regions with a gold accent (error: red, orange, amber).
vec3 dye(vec3 p) {
  float h = fbm3(p * 0.9 + vec3(11.0, 3.0, uPhase * 0.05));
  float g = smoothstep(0.62, 0.75, fbm3(p * 1.3 + vec3(-4.0, 7.0, 2.0)));
  vec3 m = vec3(1.0, 0.24, 0.66), v = vec3(0.56, 0.33, 1.0), bl = vec3(0.22, 0.48, 1.0), c = vec3(0.15, 0.9, 0.95);
  float t = clamp((h - 0.3) * 2.5, 0.0, 1.0) * 3.0;
  vec3 col = t < 1.0 ? mix(m, v, t) : t < 2.0 ? mix(v, bl, t - 1.0) : mix(bl, c, t - 2.0);
  col = mix(col, vec3(1.0, 0.72, 0.3), g * 0.8);
  vec3 err = mix(vec3(1.0, 0.25, 0.1), vec3(1.0, 0.62, 0.15), clamp((h - 0.35) * 3.0, 0.0, 1.0));
  return mix(col, err, uDanger);
}

// ---- Frost (owner, 2026-11-12: Liquid Glass in spirit). The ball is two layers, as on the Mac:
//  1. the MATERIAL under it: the backdrop blurred and lightened. On the Mac this is the system's glass material (the
//     orb sits on the panel's .glassEffect / .ultraThinMaterial); here material() fakes it. MOCKUP ONLY.
//  2. the OVERLAY this shader draws over it (premultiplied): a milky body, the smoke scattered through the frost (sharp
//     and vivid in the core, wider and softer toward the rim), crisp refractive edges with a slight chromatic split that
//     ride the wobble, a broad soft highlight. ClaudeOrb.metal is this overlay, line for line.
vec3 material(vec2 px, bool light) {
  vec3 s = vec3(0.0); float n = 0.0;
  for (int i = 0; i < 64; i++) {
    float a = float(i) * 2.39996, rr = sqrt((float(i) + 0.5) / 64.0);
    vec2 o = vec2(cos(a), sin(a)) * rr * max(uRadius * 0.45, 14.0);
    s += back(uCenter + px * uRadius + o); n += 1.0;
  }
  s /= n;
  float l = dot(s, vec3(0.299, 0.587, 0.114));
  s = mix(vec3(l), s, 1.5);                                                   // the system material saturates a little
  return light ? mix(s, vec3(1.0), 0.45) : mix(s, vec3(0.92, 0.94, 1.0), 0.10) + 0.03;
}

// Scattering: how much frost a ray from inside crosses here (more toward the rim, where the shell is seen edge-on).
float scatterAt(float r) { return smoothstep(0.15, 0.97, r); }

float densityF(vec3 p, float s, out vec3 q) {
  float t = uPhase;
  vec3 w = vec3(fbm3(p * 1.1 + vec3(0.0, -t * 0.18, t * 0.07)), fbm3(p * 1.1 + vec3(5.2, 1.3 - t * 0.2, -t * 0.05)), fbm3(p * 1.1 + vec3(2.7, 8.1, t * 0.09)));
  q = p + (w - 0.5) * 1.3 + vec3(-uSpin * t * 0.5, -t * 0.12, 0.0);
  // Through the frost the fine detail goes first: blend toward a coarser field and widen the threshold with s.
  float fine = fbm4(q * 2.8 + vec3(0.0, 0.0, t * 0.04));
  float coarse = fbm3(q * 1.5 + vec3(3.1, 0.0, t * 0.03));
  float d = mix(fine, coarse, 0.75 * s);
  float edge = smoothstep(0.88, 0.40, length(p));
  float low = mix(1.15, 0.6, smoothstep(-0.6, 0.7, p.y));
  float thick = mix(0.5, 0.42, uDanger) - 0.04 * uBright;
  d = smoothstep(thick - 0.10 * s, thick + 0.2 + 0.28 * s, d) * edge * low;
  float age = 1.0 - uPulse;
  vec3 c = vec3(0.18 * sin(uTime * 1.3), -0.55 + 0.55 * age, 0.1 * cos(uTime * 1.1));
  d += uPulse * smoothstep(0.32 + 0.2 * age + 0.15 * s, 0.0, length((p - c) * vec3(1.0, 0.7, 1.0)) - 0.15 * (fbm3(p * 4.0 + t) - 0.5));
  return d;
}

vec4 overlay(vec2 uv, float r, float nz, vec3 dir, float wob, float bright, bool light) {
  float s = scatterAt(r);
  // The smoke, marched as before but through the frost.
  float z0 = nz * 0.9, z1 = -nz * 0.9, dz = (z0 - z1) / float(STEPS);
  vec3 acc = vec3(0.0); float T = 1.0;
  for (int i = 0; i < STEPS; i++) {
    float z = z0 - (float(i) + 0.5) * dz;
    vec3 p = vec3(uv, z);
    vec3 q;
    float d = densityF(p, s, q);
    if (d > 0.01) {
      vec3 qs;
      float sh = densityF(p + vec3(-0.12, 0.16, 0.12), s, qs);
      vec3 col = dye(q);
      float hot = smoothstep(0.45, 0.95, d) * (1.0 - 0.6 * s);                       // white-hot only in the clear core
      vec3 e = mix(col, vec3(1.0, 0.97, 0.95), hot * 0.85) * d * (1.0 + 0.5 * hot) * (1.0 - 0.45 * clamp(sh, 0.0, 1.0));
      e *= mix(0.55, 1.0, (z - z1) / max(z0 - z1, 1e-3));
      acc += T * e * dz * 6.5 * bright;
      T *= exp(-d * dz * 4.5);
      if (T < 0.03) break;
    }
  }
  // The glow the frost spreads: five probes of the smoke near the middle, each a soft lamp whose light the frost carries
  // outward (wider and weaker toward the rim). This is what makes the colour reach the edge as a haze.
  vec3 glow = vec3(0.0);
  for (int i = 0; i < 5; i++) {
    float a = float(i) * 1.2566 + uPhase * 0.05;
    vec3 pp = i == 0 ? vec3(0.0, -0.1, 0.0) : vec3(cos(a) * 0.38, sin(a) * 0.38 - 0.05, 0.0);
    vec3 q;
    float d = densityF(pp, 0.4, q);
    float k = exp(-dot(uv - pp.xy, uv - pp.xy) / 0.55);
    glow += dye(q) * d * k;
  }
  glow *= bright * 0.32;
  float dense = 1.0 - T;

  // The milky body: a soft diffuse white that thickens toward the rim (the frost seen edge-on).
  float body = light ? 0.20 + 0.30 * pow(1.0 - nz, 1.5) : 0.07 + 0.20 * pow(1.0 - nz, 1.5);
  vec3 milk = light ? vec3(1.0) : vec3(0.86, 0.89, 0.96);

  // The refractive edge: a crisp bright line just inside the silhouette, split slightly by colour, brightest where the
  // light meets it (top-left, and the bounce bottom-right); the wobble tilts the edge normal so the highlight slides.
  vec2 nrm = normalize(uv / max(r, 1e-3) + vec2(-dir.y, dir.x) * wob * uWobble * 6.0);
  float facing = pow(abs(dot(nrm, normalize(vec2(-0.55, 0.83)))), 3.0);
  float edgeI = 0.15 + 0.85 * facing;
  vec3 split = vec3(smoothstep(0.955, 0.99, r * 1.006) * smoothstep(1.0, 0.988, r * 1.006),
                    smoothstep(0.955, 0.99, r) * smoothstep(1.0, 0.988, r),
                    smoothstep(0.955, 0.99, r * 0.994) * smoothstep(1.0, 0.988, r * 0.994));
  vec3 edge = split * edgeI * (light ? 0.75 : 0.95);
  float inner = smoothstep(0.70, 0.97, r) * (0.06 + 0.10 * facing);              // the thick-glass band inside the edge

  // A broad soft highlight up top that turns with the flow, and a faint bounce low.
  float tiltA = 0.07 * sin(uPhase * 0.23) + 0.09 * uSpin;
  vec2 su = vec2(cos(tiltA) * uv.x - sin(tiltA) * uv.y, sin(tiltA) * uv.x + cos(tiltA) * uv.y);
  float hi = exp(-(pow(su.x + 0.15, 2.0) / 0.30 + pow(su.y - 0.55, 2.0) / 0.07)) * (light ? 0.30 : 0.20)
           + exp(-(pow(su.x - 0.2, 2.0) / 0.25 + pow(su.y + 0.78, 2.0) / 0.02)) * 0.06;

  // Compose the overlay (premultiplied): milk, then the smoke over it, then light on top.
  float a = body;
  vec3 c = milk * body;
  if (light) {
    // On a light page the smoke is dye in the frost: vivid in the core, a pastel haze toward the rim.
    vec3 dyeC = clamp(acc / max(0.2, max(acc.r, max(acc.g, acc.b))), 0.0, 1.0);
    dyeC = mix(dyeC, vec3(1.0), 0.35 * s);
    float da = clamp(dense * 1.2, 0.0, 0.92) * (1.0 - 0.45 * s);
    c = c * (1.0 - da) + dyeC * da; a = a + da * (1.0 - a);
    vec3 g = clamp(glow, 0.0, 1.0); float ga = clamp(max(g.r, max(g.g, g.b)), 0.0, 1.0) * 0.55 * (1.0 - da);
    c = c * (1.0 - ga) + mix(g / max(ga, 1e-3) * 0.55, vec3(1.0), 0.3) * ga; a = a + ga * (1.0 - a);
    c += hi * vec3(1.0) + edge * 0.9 + inner; a = clamp(a + hi + max(edge.r, max(edge.g, edge.b)) * 0.5 + inner, 0.0, 1.0);
  } else {
    vec3 lit = (1.0 - exp(-acc * 0.95)) * (1.0 - 0.30 * s) * 0.9;
    c = c * T + lit + glow * (0.5 + 0.8 * s) + edge + vec3(inner) + vec3(hi);
    a = clamp(a + dense * 0.6, 0.0, 1.0);
  }
  return vec4(c, a);
}

void main() {
  vec2 px = (gl_FragCoord.xy - uCenter) / uRadius;
  vec2 drift = vec2(0.012 * sin(uPhase * 0.31) + 0.015 * uSpin, 0.01 * cos(uPhase * 0.27));
  float ang = atan(px.y - drift.y, px.x - drift.x);
  vec3 dir = vec3(cos(ang), sin(ang), 0.0);
  float press = fbm3(dir * 0.9 + vec3(0.0, -uPhase * 0.12, uPhase * 0.05));
  float wob = (fbm3(dir * 1.4 + vec3(uPhase * 0.2, 3.0, -uPhase * 0.15)) - 0.5) * 2.0;
  float shape = (1.0 + uPop) * (1.0 + uWobble * (0.6 * wob + 0.8 * (press - 0.45)));
  vec2 uv = (px - drift) / shape;
  float r = length(uv);
  bool light = uLight > 0.5;
  if (r >= 1.0) {
    // Liquid Glass sits on the page with a soft contact shadow (light pages only; on dark it would read as a halo).
    float sh = light ? 0.10 * exp(-pow(max(length(uv + vec2(0.0, 0.06)) - 0.98, 0.0) / 0.08, 2.0)) : 0.0;
    gl_FragColor = vec4(0.0, 0.0, 0.0, sh);
    return;
  }
  float nz = sqrt(1.0 - r * r);
  float bright = uBright * (1.0 + 0.5 * uPulse) * (1.0 - 0.3 * uBreath);
  vec4 o = overlay(uv, r, nz, dir, wob, bright, light);
  float aa = smoothstep(1.0, 0.985, r);
  if (uOverlay > 0.5) { gl_FragColor = vec4(clamp(o.rgb, 0.0, 1.0), clamp(o.a, 0.0, 1.0)) * aa; return; }
  vec3 m = material(uv, light);
  vec3 col = m * (1.0 - o.a) + o.rgb;
  gl_FragColor = vec4(clamp(col, 0.0, 1.0) * aa, aa);
}
"""

STATES = {
    "idle":      dict(label="Idle", speed=0.35, bright=0.85, width=0, wisps=0, ripple=0, spin=0, danger=0, breath=0, wobble=0.02),
    "thinking":  dict(label="Thinking, writing", speed=0.9, bright=1.1, width=0, wisps=0, ripple=0, spin=0, danger=0, breath=0, pulse=0.55, wobble=0.05),
    "operating": dict(label="Operating MUSE", speed=0.8, bright=1.0, width=0, wisps=0, ripple=0, spin=1.6, danger=0, breath=0, pulse=0.4, wobble=0.045),
    "waiting":   dict(label="Waiting for you", speed=0.25, bright=1.15, width=0, wisps=0, ripple=0, spin=0, danger=0, breath=3.2, wobble=0.025),
    "error":     dict(label="Error", speed=0.15, bright=0.9, width=0, wisps=0, ripple=0, spin=0, danger=1, breath=0, wobble=0.015),
}

TEXT = ["Swap the outfit to a hoodie, keep the same scene", "and mood, and give me a quick plan.", "",
        "Plan: outfit swap", "Watch the clip and lock her look", "Swap the outfit to a hoodie, same light",
        "Render a 15 s preview for review", "", "Clip analysis: three moments in your clip", "0:00–0:03  Establishing shot",
        "0:04–0:10  Face toward camera, best for the swap", "0:11–0:15  Closing shot", "", "What I changed",
        "Background → Describe it          Undo", "Outfit → Hoodie                   Undo", "", "Generate · 15 s · $1.17"]

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>@font-face{font-family:muse;src:url("%FONT%")}body{margin:0}</style>
<body><canvas id=gl></canvas>
<script>
const FRAG = %FRAG%, STATES = %STATES%, TEXT = %TEXT%;
const VERT = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }';
let gl, prog, U = {}, tex, bd, W, H, dpr;
function init(w, h, d) {
  W = w; H = h; dpr = d;
  const c = document.getElementById('gl'); c.width = W * dpr; c.height = H * dpr; c.style.width = W + 'px'; c.style.height = H + 'px';
  bd = document.createElement('canvas'); bd.width = W * dpr; bd.height = H * dpr;
  gl = c.getContext('webgl', { premultipliedAlpha: true, preserveDrawingBuffer: true });
  const sh = (t, s) => { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); if (!gl.getShaderParameter(x, gl.COMPILE_STATUS)) throw gl.getShaderInfoLog(x); return x; };
  const mk = (fs) => { const p = gl.createProgram(); gl.attachShader(p, sh(gl.VERTEX_SHADER, VERT)); gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs)); gl.linkProgram(p); return p; };
  prog = mk(FRAG);
  window.copy = mk('precision highp float; uniform sampler2D uBack; uniform vec2 uTex; void main(){ gl_FragColor = texture2D(uBack, gl_FragCoord.xy / uTex); }');
  const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
  tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  for (const n of ['uBack','uTex','uCenter','uRadius','uPhase','uTime','uBright','uWidth','uWisps','uRipple','uSpin','uDanger','uPulse','uBreath','uLight','uWobble','uPop','uOverlay']) U[n] = gl.getUniformLocation(prog, n);
  const ctx = bd.getContext('2d'); ctx.scale(dpr, dpr); return ctx;
}
function attr(p) { gl.useProgram(p); const loc = gl.getAttribLocation(p, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0); }
// Paint the backdrop canvas onto the GL canvas, and keep it as the texture the glass refracts.
function present() {
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true); gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bd);
  gl.disable(gl.BLEND); gl.viewport(0, 0, W * dpr, H * dpr); attr(window.copy);
  gl.uniform2f(gl.getUniformLocation(window.copy, 'uTex'), W * dpr, H * dpr); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); attr(prog);
}
// Chat text behind the orb (what the glass bends).
function panelText(ctx, x, y, w, h, bg, ink, ink2, size) {
  ctx.fillStyle = bg; ctx.fillRect(x, y, w, h);
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  ctx.font = `${size}px muse`; let yy = y + size * 1.4;
  for (let i = 0; yy < y + h + size; i++) { const t = TEXT[i % TEXT.length]; ctx.fillStyle = i % TEXT.length < 2 ? ink : (t.startsWith('Plan') || t.startsWith('What') || t.startsWith('Clip') || t.startsWith('Generate')) ? ink : ink2;
    ctx.fillText(t, x + size, yy); yy += size * 1.45; }
  ctx.restore();
}
function orb(cx, cy, radius, st, phase, time, pulse, light) {
  const pad = radius * 0.4, x0 = (cx - radius - pad) * dpr, y0 = (H - cy - radius - pad) * dpr, s = (2 * radius + 2 * pad) * dpr;
  gl.viewport(x0, y0, s, s);
  gl.uniform1i(U.uBack, 0); gl.uniform2f(U.uTex, W * dpr, H * dpr); gl.uniform2f(U.uCenter, cx * dpr, (H - cy) * dpr); gl.uniform1f(U.uRadius, radius * dpr);
  gl.uniform1f(U.uPhase, phase); gl.uniform1f(U.uTime, time); gl.uniform1f(U.uBright, st.bright); gl.uniform1f(U.uWidth, st.width);
  gl.uniform1f(U.uWisps, st.wisps); gl.uniform1f(U.uRipple, st.ripple * (0.4 + pulse)); gl.uniform1f(U.uSpin, st.spin); gl.uniform1f(U.uDanger, st.danger);
  gl.uniform1f(U.uPulse, pulse); gl.uniform1f(U.uBreath, st.breath > 0 ? 0.5 - 0.5 * Math.cos(2 * Math.PI * time / st.breath) : 0); gl.uniform1f(U.uLight, light);
  const breath = st.breath > 0 ? 0.5 - 0.5 * Math.cos(2 * Math.PI * time / st.breath) : 0;
  gl.uniform1f(U.uWobble, st.wobble); gl.uniform1f(U.uOverlay, window._overlay ? 1 : 0); gl.uniform1f(U.uPop, 0.006 * Math.sin(time * 0.7) + 0.035 * pulse + 0.02 * breath);
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
}
const THEMES = [{ bg: '#17191B', ink: '#ECEAE5', ink2: '#A9A6A0', light: 0 }, { bg: '#F8F5EF', ink: '#141210', ink2: '#67605A', light: 1 }];
</script>"""


def page():
    return PAGE.replace("%FONT%", FONT).replace("%FRAG%", json.dumps(FRAG)).replace("%STATES%", json.dumps(STATES)).replace("%TEXT%", json.dumps(TEXT))


STILLS = r"""async () => {
  await document.fonts.load('14px muse');
  const ctx = init(1500, 760, 2), keys = Object.keys(STATES);
  THEMES.forEach((th, row) => keys.forEach((k, i) => {
    panelText(ctx, i * 300, row * 380, 300, 340, th.bg, th.ink, th.ink2, 13);
    ctx.fillStyle = th.bg; ctx.fillRect(i * 300, row * 380 + 340, 300, 40);
    ctx.fillStyle = th.ink; ctx.font = '16px muse'; ctx.textAlign = 'center'; ctx.fillText(STATES[k].label, i * 300 + 150, row * 380 + 366); ctx.textAlign = 'left';
  }));
  present();
  THEMES.forEach((th, row) => keys.forEach((k, i) => { const st = STATES[k];
    orb(i * 300 + 150, row * 380 + 170, 128, st, 2.2 + i * 1.3, 1.2 + i * 0.5, st.pulse || 0, th.light); }));
}"""

SMALL = r"""async () => {
  await document.fonts.load('13px muse');
  const ctx = init(1100, 220, 2), keys = Object.keys(STATES);
  THEMES.forEach((th, row) => {
    keys.forEach((k, i) => { panelText(ctx, i * 220, row * 110, 220, 110, th.bg, th.ink, th.ink2, 12); ctx.fillStyle = th.bg; ctx.fillRect(i * 220 + 50, row * 110 + 40, 168, 30);
      ctx.fillStyle = th.ink; ctx.font = '13px muse'; ctx.fillText(`${STATES[k].label}, 32 pt`, i * 220 + 56, row * 110 + 60); }); });
  present();
  THEMES.forEach((th, row) => keys.forEach((k, i) => { const st = STATES[k]; orb(i * 220 + 26, row * 110 + 55, 16, st, 2.2 + i * 1.3, 1.2 + i * 0.5, st.pulse || 0, th.light); }));
}"""

FRAME = r"""(f) => {
  if (!window._ctx) { window._ctx = init(720, 400, 1); window._phase = 0; window._last = 0; window._pulseAt = -9; }
  const ctx = window._ctx, t = f / 30, keys = Object.keys(STATES), starts = [0, 3, 6, 7.33, 8.67], k = t < 3 ? 0 : t < 6 ? 1 : t < 7.33 ? 2 : t < 8.67 ? 3 : 4, st = STATES[keys[k]], local = t - starts[k];
  const every = keys[k] === 'thinking' ? 0.15 : keys[k] === 'operating' ? 0.4 : 0;
  if (every && Math.floor(local / every) !== Math.floor((local - 1 / 30) / every)) window._pulseAt = t;
  const u = (t - window._pulseAt) / 0.6, pulse = every && u < 1 ? (1 - u) * (1 - u) : 0;
  window._phase += Math.min(0.25, t - window._last) * st.speed * 3; window._last = t;
  THEMES.forEach((th, i) => { panelText(ctx, i * 360, 0, 360, 400, th.bg, th.ink, th.ink2, 13);
    ctx.fillStyle = th.bg; ctx.fillRect(i * 360, 350, 360, 50); ctx.fillStyle = th.ink; ctx.font = '18px muse'; ctx.textAlign = 'center';
    ctx.fillText(st.label, i * 360 + 180, 382); ctx.textAlign = 'left'; });
  present();
  THEMES.forEach((th, i) => orb(i * 360 + 180, 175, 100, st, window._phase, t, pulse, th.light));
}"""


OVERLAY = r"""async (spec) => {
  // The overlay layer alone (premultiplied, transparent around it): what ClaudeOrb.metal draws over the system material.
  window._overlay = true;
  const ctx = init(spec.w, spec.h, 2);
  gl.viewport(0, 0, W * dpr, H * dpr); gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
  gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); attr(prog);
  spec.orbs.forEach(o => { const st = STATES[o.state]; orb(o.x, o.y, o.r, st, o.phase, o.time, st.pulse || 0, spec.light); });
}"""


def overlays(out_dir, size_r, light, states=("idle", "thinking", "operating")):
    """Writes <state>-<light|dark>.png overlays (radius size_r at 2x), each in its own square with the room the wobble needs."""
    root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp); html = tmp / "o.html"; html.write_text(page())
        side = int(size_r * 2 * 1.1) + 2
        jobs = [{"png": str(out_dir / f"{k}-{'light' if light else 'dark'}.png"), "spec": {"w": side, "h": side, "light": 1 if light else 0,
                 "orbs": [{"x": side / 2, "y": side / 2, "r": size_r, "state": k, "phase": 2.2 + i * 1.3, "time": 1.2 + i * 0.5}]}} for i, k in enumerate(states)]
        js = tmp / "o.js"
        js.write_text(f"""const {{ chromium }} = require('playwright');
(async () => {{ const b = await chromium.launch({{ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] }});
  for (const j of {json.dumps(jobs)}) {{ const p = await b.newPage({{ viewport: {{ width: j.spec.w, height: j.spec.h }}, deviceScaleFactor: 2 }});
    p.on('pageerror', e => console.error(e)); await p.goto({json.dumps(html.as_uri())});
    await p.evaluate('(' + {json.dumps(OVERLAY)} + ')(' + JSON.stringify(j.spec) + ')'); await p.screenshot({{ path: j.png, omitBackground: true }}); await p.close(); }}
  await b.close(); }})();""")
        subprocess.run(["node", str(js)], check=True, env={**os.environ, "NODE_PATH": root})
    return out_dir


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        html = tmp / "glass.html"; html.write_text(page())
        frames = tmp / "frames"; frames.mkdir()
        js = tmp / "run.js"
        js.write_text(f"""const {{ chromium }} = require('playwright');
(async () => {{ const b = await chromium.launch({{ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] }});
  const shot = async (w, h, fn, png) => {{ const p = await b.newPage({{ viewport: {{ width: w, height: h }}, deviceScaleFactor: 2 }});
    p.on('pageerror', e => console.error(e)); p.on('console', m => console.log(m.text()));
    await p.goto({json.dumps(html.as_uri())}); await p.evaluate('(' + fn + ')()'); await p.waitForTimeout(200);
    await p.screenshot({{ path: png }}); await p.close(); console.log('wrote', png); }};
  await shot(1500, 760, {json.dumps(STILLS)}, {json.dumps(str(OUT / 'orb-frost-states.png'))});
  await shot(1100, 220, {json.dumps(SMALL)}, {json.dumps(str(OUT / 'orb-frost-small.png'))});
  if (process.env.FROST_STILLS) {{ await b.close(); return; }}
  const p = await b.newPage({{ viewport: {{ width: 720, height: 400 }} }}); p.on('pageerror', e => console.error(e));
  await p.goto({json.dumps(html.as_uri())}); await p.evaluate(() => document.fonts.load('13px muse'));
  const frame = {json.dumps(FRAME)};
  for (let f = 0; f < 300; f++) {{ await p.evaluate(`(${{frame}})(${{f}})`); await p.screenshot({{ path: `{frames}/f${{String(f).padStart(3, '0')}}.png` }}); }}
  await b.close(); }})();""")
        subprocess.run(["node", str(js)], check=True, env={**os.environ, "NODE_PATH": root})
        if os.environ.get("FROST_STILLS"): return
        mp4 = OUT / "orb-frost-preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(frames / "f%03d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "18", "-movflags", "+faststart", str(mp4)], check=True)
        print("wrote", mp4)


if __name__ == "__main__":
    main()
