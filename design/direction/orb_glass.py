"""Claude's orb, Option B (owner's close-up, 2026-11-12): a transparent glass sphere that REFRACTS what is behind it (the
panel's text, bent and magnified like a water drop), smoky in its upper half, with one thin very bright light band
across the middle (white-hot centre, iridescent edges: gold on one side, cyan, blue and violet on the other). The
band lights the lower half, a crisp Fresnel rim with a chromatic fringe runs round the edge, and there's a soft specular
highlight on top. The band is what moves: it tilts, twists, spins and ripples by state, and wisps peel off it when busy.
Option A (the vortex) is design/direction/orb_shader.py.

    python3 design/direction/orb_glass.py
    → plans/design/claude-panel/orb-glass-states.png   (256 px, five states, dark and light, text behind)
      plans/design/claude-panel/orb-glass-small.png    (32 pt over panel text, dark and light)
      plans/design/claude-panel/orb-glass-preview.mp4  (8 s cycling the states, dark and light side by side)
"""
import json, os, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans/design/claude-panel"
FONT = (REPO / "android/app/src/main/res/font/barlow_400.ttf").as_uri()

FRAG = r"""
precision highp float;
uniform sampler2D uBack; uniform vec2 uTex, uCenter; uniform float uRadius;
uniform float uPhase, uTime, uBright, uWidth, uWisps, uRipple, uSpin, uDanger, uPulse, uBreath, uLight;

vec3 rotX(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z); }
vec3 rotZ(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z); }

// The band's colour round its ring: gold → white → cyan → violet → gold (error: red → orange).
vec3 iris(float h) {
  h = fract(h);
  vec3 g = vec3(1.0, 0.68, 0.28), w = vec3(1.0, 0.96, 0.92), c = vec3(0.3, 0.84, 1.0), v = vec3(0.62, 0.45, 1.0);
  vec3 col = h < 0.25 ? mix(g, w, h * 4.0) : h < 0.5 ? mix(w, c, h * 4.0 - 1.0) : h < 0.75 ? mix(c, v, h * 4.0 - 2.0) : mix(v, g, h * 4.0 - 3.0);
  return mix(col, mix(vec3(1.0, 0.32, 0.2), vec3(1.0, 0.65, 0.22), 0.5 + 0.5 * sin(h * 6.283)), uDanger);
}
vec3 back(vec2 px) { return texture2D(uBack, clamp(px / uTex, 0.0, 1.0)).rgb; }

// One band: a great circle of light on the sphere, tilted by `n`. Returns light and (in .a) its strength for the tint.
vec4 band(vec3 P, vec3 n, float width, float spin, float ripple) {
  vec3 e1 = normalize(cross(n, vec3(0.0, 0.0, 1.0) + vec3(0.001, 0.0, 0.0)));
  vec3 e2 = cross(n, e1);
  float ang = atan(dot(P, e2), dot(P, e1));
  float d = dot(P, n) + ripple * 0.045 * sin(5.0 * ang - uTime * 5.0) + ripple * 0.02 * sin(9.0 * ang + uTime * 3.0);
  float w = width;
  float core = exp(-pow(d / (0.22 * w), 2.0));
  float glow = exp(-pow(d / w, 2.0));
  float wide = exp(-pow(d / (3.5 * w), 2.0));
  vec3 col = iris(ang / 6.2832 + spin);
  vec3 light = vec3(1.0, 0.97, 0.94) * core * 1.2 + col * glow * 0.9 + col * wide * 0.25;
  return vec4(light, glow);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - uCenter) / uRadius;
  float r = length(uv);
  float bright = uBright * (1.0 + 0.7 * uPulse) * (1.0 - 0.3 * uBreath);
  // The band's plane: tilted so the ring is seen in perspective, slowly tilting and twisting with the phase.
  vec3 n = normalize(rotZ(rotX(vec3(0.0, 1.0, 0.0), 0.32 + 0.22 * sin(uPhase * 0.7)), 0.18 * sin(uPhase * 0.53) - 0.08));
  float spin = uPhase * uSpin * 0.25;
  float width = (0.045 + 0.04 * uWidth) * (1.0 + 0.5 * uPulse);
  vec3 outC = vec3(0.0); float outA = 0.0;
  if (r < 1.0) {
    float nz = sqrt(1.0 - r * r);
    vec3 Pf = vec3(uv, nz), Pb = vec3(uv, -nz);
    // The content behind, refracted: magnified in the middle, bent at the edge, with a slight chromatic split.
    float k = 0.55 + 0.32 * r * r;
    vec2 base = uCenter;
    vec3 refr = vec3(back(base + uv * uRadius * k).r, back(base + uv * uRadius * k * (1.0 + 0.02 * r * r)).g, back(base + uv * uRadius * k * (1.0 + 0.04 * r * r)).b);
    // Front and back of the band (the back seen through the glass: dimmer, softer), and wisps peeling off it.
    vec4 bf = band(Pf, n, width, spin, uRipple);
    vec4 bb = band(Pb, n, width * 1.6, spin + 0.5, uRipple);
    vec3 light = bf.rgb + bb.rgb * 0.35;
    float tw = bf.a + 0.35 * bb.a;
    if (uWisps > 0.0) {
      vec3 n2 = normalize(rotZ(rotX(n, 0.28 * sin(uPhase * 0.9)), 0.35 + 0.2 * sin(uPhase * 0.6)));
      vec3 n3 = normalize(rotZ(rotX(n, -0.3 * sin(uPhase * 0.8 + 1.0)), -0.4 + 0.2 * cos(uPhase * 0.5)));
      light += band(Pf, n2, width * 0.35, spin + 0.3, 0.0).rgb * 0.45 * uWisps;
      light += band(Pf, n3, width * 0.3, spin + 0.6, 0.0).rgb * 0.35 * uWisps;
    }
    vec3 avg = iris(spin + 0.15);
    // Smoky upper half, the lower half lit by the band (warm grey, spilling down and fading).
    float side = dot(Pf, n);
    float lower = smoothstep(0.15, -0.55, side);
    vec3 glass = refr * mix(0.24, 0.62, lower) + vec3(0.02, 0.02, 0.035);
    glass += mix(vec3(0.75, 0.66, 0.56), avg, 0.35) * exp(-max(-side, 0.0) / 0.55) * step(side, 0.0) * 0.3 * bright;
    // A crisp Fresnel rim, strongest at the sides and bottom, with a chromatic fringe; one soft highlight on top.
    float f = pow(1.0 - nz, 2.6);
    vec3 rim = vec3(f, pow(f, 1.12), pow(f, 1.25)) * (0.55 + 0.45 * clamp(0.4 - uv.y * 0.8, 0.0, 1.0));
    float spec = exp(-(pow(uv.x + 0.28, 2.0) / 0.045 + pow(uv.y - 0.6, 2.0) / 0.012)) * 0.55;
    vec3 col = glass + light * bright + rim * (0.6 + 0.25 * mix(vec3(1.0), avg, 0.5)) + spec;
    col = 1.0 - exp(-col * 1.25) * 1.0;
    col = mix(col, glass + light * bright + rim * 0.7 + spec, 0.35);
    float aa = smoothstep(1.0, 0.985, r);
    outC = col * aa; outA = aa;
  }
  // Light spill: a faint halo outside, tinted by the band.
  vec3 haloC = iris(spin + 0.15) * exp(-pow(max(r - 1.0, 0.0) / 0.12, 2.0)) * 0.22 * bright * step(1.0, r + 0.015);
  float haloA = clamp(max(haloC.r, max(haloC.g, haloC.b)), 0.0, 1.0) * (uLight > 0.5 ? 0.6 : 1.0);
  outC += haloC * (1.0 - outA); outA += haloA * (1.0 - outA);
  gl_FragColor = vec4(clamp(outC, 0.0, 1.0), clamp(outA, 0.0, 1.0));
}
"""

STATES = {
    "idle":      dict(label="Idle", speed=0.22, bright=0.7, width=0.35, wisps=0, ripple=0, spin=0.3, danger=0, breath=0),
    "thinking":  dict(label="Thinking, writing", speed=0.8, bright=1.0, width=1.0, wisps=0.8, ripple=1, spin=0.6, danger=0, breath=0, pulse=0.35),
    "operating": dict(label="Operating MUSE", speed=0.7, bright=0.95, width=0.8, wisps=0.5, ripple=0.3, spin=3.0, danger=0, breath=0, pulse=0.6),
    "waiting":   dict(label="Waiting for you", speed=0.12, bright=1.1, width=0.7, wisps=0, ripple=0, spin=0.1, danger=0, breath=3.2),
    "error":     dict(label="Error", speed=0.1, bright=0.85, width=0.6, wisps=0, ripple=0, spin=0.1, danger=1, breath=0),
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
  for (const n of ['uBack','uTex','uCenter','uRadius','uPhase','uTime','uBright','uWidth','uWisps','uRipple','uSpin','uDanger','uPulse','uBreath','uLight']) U[n] = gl.getUniformLocation(prog, n);
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
  const ctx = window._ctx, t = f / 30, keys = Object.keys(STATES), k = Math.min(4, Math.floor(t / 1.6)), st = STATES[keys[k]], local = t - k * 1.6;
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
  await shot(1500, 760, {json.dumps(STILLS)}, {json.dumps(str(OUT / 'orb-glass-states.png'))});
  await shot(1100, 220, {json.dumps(SMALL)}, {json.dumps(str(OUT / 'orb-glass-small.png'))});
  const p = await b.newPage({{ viewport: {{ width: 720, height: 400 }} }}); p.on('pageerror', e => console.error(e));
  await p.goto({json.dumps(html.as_uri())}); await p.evaluate(() => document.fonts.load('13px muse'));
  const frame = {json.dumps(FRAME)};
  for (let f = 0; f < 240; f++) {{ await p.evaluate(`(${{frame}})(${{f}})`); await p.screenshot({{ path: `{frames}/f${{String(f).padStart(3, '0')}}.png` }}); }}
  await b.close(); }})();""")
        subprocess.run(["node", str(js)], check=True, env={**os.environ, "NODE_PATH": root})
        mp4 = OUT / "orb-glass-preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(frames / "f%03d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "18", "-movflags", "+faststart", str(mp4)], check=True)
        print("wrote", mp4)


if __name__ == "__main__":
    main()
