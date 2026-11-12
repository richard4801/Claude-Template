"""Claude's orb, Option C2 alive (owner, 2026-11-12: "the orb itself moves subtly in time with the swirling inside"): C2's smoke,
and the glass body follows it: a soft-body wobble of the silhouette (bulging where the smoke presses), a breathing scale
with the emission (a pop per chunk, a bump per action), a tiny drift and a tilt of the reflections with the flow (leaning
into the current when operating). The rim and highlight deform with the silhouette. No glint and no added lines (owner):
the densest smoke is the light. Reduce Motion freezes the shape.
Based on Option C2 (owner, 2026-11-12: "smoke with depth; right now it moves in a pattern"): B's glass ball with
real 3D volumetric smoke inside. A ray is marched through the ball (front to back, with absorption) in a 3D density
field: domain-warped 3D noise advected by a slowly evolving flow (time as the fourth dimension) — plumes rise, curl,
fold, split and drift toward and away from the viewer; nothing rotates as a whole. It is emissive (magenta, violet,
blue, cyan, a gold accent), white-hot where dense, fading to clear wisps, with soft self-shadow so it reads as volume.

    python3 design/direction/orb_volume.py
    → plans/design/claude-panel/orb-alive-states.png   (256 px, five states, dark and light, text behind)
      plans/design/claude-panel/orb-alive-small.png    (32 pt over panel text, dark and light)
      plans/design/claude-panel/orb-alive-preview.mp4  (10 s: 3 s idle, 3 s thinking, then the others; dark and light)
"""
import json, os, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans/design/claude-panel"
FONT = (REPO / "android/app/src/main/res/font/barlow_400.ttf").as_uri()

FRAG = r"""
precision highp float;
uniform sampler2D uBack; uniform vec2 uTex, uCenter; uniform float uRadius;
uniform float uPhase, uTime, uBright, uWidth, uWisps, uRipple, uSpin, uDanger, uPulse, uBreath, uLight, uWobble, uPop;
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

// Density: 3D noise warped by a flow that evolves with time (a fourth dimension), rising; a current when operating.
float density(vec3 p, out vec3 q) {
  float t = uPhase;
  vec3 w = vec3(fbm3(p * 1.1 + vec3(0.0, -t * 0.18, t * 0.07)), fbm3(p * 1.1 + vec3(5.2, 1.3 - t * 0.2, -t * 0.05)), fbm3(p * 1.1 + vec3(2.7, 8.1, t * 0.09)));
  q = p + (w - 0.5) * 1.3 + vec3(-uSpin * t * 0.5, -t * 0.12, 0.0);
  float d = fbm4(q * 2.8 + vec3(0.0, 0.0, t * 0.04));
  float edge = smoothstep(0.86, 0.45, length(p));                  // fills about the middle 70 %
  float low = mix(1.15, 0.6, smoothstep(-0.6, 0.7, p.y));           // denser low, wispier at the top
  float thick = mix(0.5, 0.42, uDanger) - 0.04 * uBright;
  d = smoothstep(thick, thick + 0.2, d) * edge * low;
  // A streamed chunk: a bright plume rising from below and unfurling.
  float age = 1.0 - uPulse;
  vec3 c = vec3(0.18 * sin(uTime * 1.3), -0.55 + 0.55 * age, 0.1 * cos(uTime * 1.1));
  d += uPulse * smoothstep(0.32 + 0.2 * age, 0.0, length((p - c) * vec3(1.0, 0.7, 1.0)) - 0.15 * (fbm3(p * 4.0 + t) - 0.5));
  return d;
}


void main() {
  vec2 px = (gl_FragCoord.xy - uCenter) / uRadius;
  // The living glass: a tiny drift and lean with the flow, a breathing scale, and a soft-body wobble of the silhouette
  // (low-frequency noise over the surface angle, bulging where the dense smoke presses). Everything below works in the
  // ball's own deformed coordinates, so the rim and the reflections deform with it.
  vec2 drift = vec2(0.012 * sin(uPhase * 0.31) + 0.015 * uSpin, 0.01 * cos(uPhase * 0.27));
  float ang = atan(px.y - drift.y, px.x - drift.x);
  vec3 dir = vec3(cos(ang), sin(ang), 0.0);
  float press = fbm3(dir * 0.9 + vec3(0.0, -uPhase * 0.12, uPhase * 0.05));          // where the smoke leans
  float wob = (fbm3(dir * 1.4 + vec3(uPhase * 0.2, 3.0, -uPhase * 0.15)) - 0.5) * 2.0;
  float shape = (1.0 + uPop) * (1.0 + uWobble * (0.6 * wob + 0.8 * (press - 0.45)));
  vec2 uv = (px - drift) / shape;
  float r = length(uv);
  if (r >= 1.0) { gl_FragColor = vec4(0.0); return; }
  float nz = sqrt(1.0 - r * r);
  float bright = uBright * (1.0 + 0.5 * uPulse) * (1.0 - 0.3 * uBreath);

  // The page behind: its tone, and only a blurred, dimmed, flipped hint near the bottom.
  vec3 avg = vec3(0.0);
  for (int i = 0; i < 6; i++) { float a = float(i) * 1.047; avg += back(uCenter + vec2(cos(a), sin(a)) * uRadius * 0.7); }
  avg /= 6.0;
  vec3 hint = back(uCenter + vec2(uv.x * 0.6, -uv.y * 0.5 - 0.3) * uRadius);
  vec3 refr = mix(avg, hint, smoothstep(-0.2, -0.85, uv.y) * 0.15);
  bool light = uLight > 0.5;
  float shade = mix(light ? 0.9 : 0.03, light ? 0.97 : 0.3, smoothstep(0.3, -0.9, uv.y));
  vec3 glass = refr * shade + (light ? vec3(0.0) : vec3(0.015, 0.015, 0.025));

  // March the ray through the volume, front to back: emission with absorption and a soft self-shadow.
  float z0 = nz * 0.9, z1 = -nz * 0.9, dz = (z0 - z1) / float(STEPS);
  vec3 acc = vec3(0.0); float T = 1.0;
  for (int i = 0; i < STEPS; i++) {
    float z = z0 - (float(i) + 0.5) * dz;
    vec3 p = vec3(uv, z);
    vec3 q;
    float d = density(p, q);
    if (d > 0.01) {
      vec3 qs;
      float sh = density(p + vec3(-0.12, 0.16, 0.12), qs);          // toward the light: denser there, darker here
      vec3 col = dye(q);
      float hot = smoothstep(0.45, 0.95, d);
      vec3 e = mix(col, vec3(1.0, 0.97, 0.95), hot * 0.85) * d * (1.0 + 0.5 * hot) * (1.0 - 0.45 * clamp(sh, 0.0, 1.0));
      e *= mix(0.55, 1.0, (z - z1) / max(z0 - z1, 1e-3));          // farther smoke is dimmer
      acc += T * e * dz * 6.5 * bright;
      T *= exp(-d * dz * 4.5);
      if (T < 0.03) break;
    }
  }
  float dense = 1.0 - T;

  // B's glass: a thin soft rim (bottom-left and right brightest) with a chromatic fringe, lit by the smoke near it;
  // a broad dim reflection on top.
  float f = pow(1.0 - nz, 3.0);
  float where = 0.35 + 0.65 * max(smoothstep(0.4, -0.9, uv.y) * smoothstep(0.2, -0.8, uv.x), smoothstep(0.3, 0.95, uv.x));
  vec3 smokeTint = acc / max(0.15, max(acc.r, max(acc.g, acc.b)));
  vec3 rim = vec3(f, pow(f, 1.15), pow(f, 1.3)) * 0.55 * where + smokeTint * f * 0.5 * clamp(dense * 2.0, 0.0, 1.0) * bright;
  float tiltA = 0.07 * sin(uPhase * 0.23) + 0.09 * uSpin;                         // the ball turns a little with the flow
  vec2 su = vec2(cos(tiltA) * uv.x - sin(tiltA) * uv.y, sin(tiltA) * uv.x + cos(tiltA) * uv.y);
  vec3 spec = vec3(1.0) * exp(-(pow(su.x + 0.12, 2.0) / 0.22 + pow(su.y - 0.62, 2.0) / 0.035)) * 0.16;


  vec3 col;
  if (light) {
    // On a light page the smoke is dye over the clear glass (light can't brighten white): vivid, never grey.
    float a = clamp(dense * 1.25, 0.0, 0.95);
    vec3 dyeC = clamp(acc / max(0.2, max(acc.r, max(acc.g, acc.b))), 0.0, 1.0);
    col = mix(glass, dyeC, a) + rim * 0.55 - vec3(0.05) * f + spec * 0.6;
  } else {
    vec3 lit = 1.0 - exp(-acc * 1.15);                                                // soft tone map: bright, never blown out
    col = glass * T + lit + rim + spec;
  }
  float aa = smoothstep(1.0, 0.985, r);
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
  for (const n of ['uBack','uTex','uCenter','uRadius','uPhase','uTime','uBright','uWidth','uWisps','uRipple','uSpin','uDanger','uPulse','uBreath','uLight','uWobble','uPop']) U[n] = gl.getUniformLocation(prog, n);
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
  gl.uniform1f(U.uWobble, st.wobble); gl.uniform1f(U.uPop, 0.006 * Math.sin(time * 0.7) + 0.035 * pulse + 0.02 * breath);
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
  await shot(1500, 760, {json.dumps(STILLS)}, {json.dumps(str(OUT / 'orb-alive-states.png'))});
  await shot(1100, 220, {json.dumps(SMALL)}, {json.dumps(str(OUT / 'orb-alive-small.png'))});
  const p = await b.newPage({{ viewport: {{ width: 720, height: 400 }} }}); p.on('pageerror', e => console.error(e));
  await p.goto({json.dumps(html.as_uri())}); await p.evaluate(() => document.fonts.load('13px muse'));
  const frame = {json.dumps(FRAME)};
  for (let f = 0; f < 300; f++) {{ await p.evaluate(`(${{frame}})(${{f}})`); await p.screenshot({{ path: `{frames}/f${{String(f).padStart(3, '0')}}.png` }}); }}
  await b.close(); }})();""")
        subprocess.run(["node", str(js)], check=True, env={**os.environ, "NODE_PATH": root})
        mp4 = OUT / "orb-alive-preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(frames / "f%03d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "18", "-movflags", "+faststart", str(mp4)], check=True)
        print("wrote", mp4)


if __name__ == "__main__":
    main()
