"""Claude's orb, Option C (owner, 2026-11-12: "it has no swirling"): B's transparent glass ball with luminous multicolour
LIQUID SMOKE swirling inside it, like ink in water (magenta, violet, blue, cyan and a warm gold accent), curling and
folding into itself: domain-warped fBm turned in a swirl round the centre, in three depth layers (back dim and soft,
front bright with finer wisps), added together with a white-hot core where it is densest. The page behind shows only
as a heavily blurred, dimmed hint near the bottom. Forward-only phase: it never loops. The state drives the smoke.

    python3 design/direction/orb_smoke.py
    → plans/design/claude-panel/orb-smoke-states.png   (256 px, five states, dark and light, text behind)
      plans/design/claude-panel/orb-smoke-small.png    (32 pt over panel text, dark and light)
      plans/design/claude-panel/orb-smoke-preview.mp4  (8 s cycling the states, dark and light side by side)
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

vec3 back(vec2 px) { return texture2D(uBack, clamp(px / uTex, 0.0, 1.0)).rgb; }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + vec2(1.7, 9.2); a *= 0.5; } return v; }
mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

// The smoke's colours: magenta, violet, blue, cyan, with a warm gold accent (error: red, orange, amber).
vec3 dye(float a, float b) {
  vec3 m = vec3(1.0, 0.24, 0.66), v = vec3(0.55, 0.32, 1.0), bl = vec3(0.2, 0.45, 1.0), c = vec3(0.15, 0.9, 0.95), g = vec3(1.0, 0.72, 0.3);
  vec3 col = mix(mix(m, v, smoothstep(0.2, 0.6, a)), mix(bl, c, smoothstep(0.3, 0.8, b)), smoothstep(0.35, 0.75, b));
  col = mix(col, g, smoothstep(0.62, 0.85, a * b * 1.6));
  vec3 err = mix(vec3(1.0, 0.25, 0.12), vec3(1.0, 0.6, 0.15), smoothstep(0.3, 0.8, a));
  return mix(col, err, uDanger);
}

// One layer of smoke: warped fBm, swirled round the centre (faster near it), streaming one way when operating.
vec4 smoke(vec2 uv, float scale, float speed, float seed) {
  float r = length(uv);
  float t = uPhase * speed;
  vec2 p = uv * rot(t * (0.6 + 1.4 * (1.0 - r)) + 2.2 * (1.0 - r)) * scale;
  p.x -= uSpin * uPhase * 0.9;                                   // operating: a current
  vec2 q = vec2(fbm(p + vec2(seed, t * 0.15)), fbm(p + vec2(5.2 + seed, 1.3 - t * 0.12)));
  vec2 w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2) + t * 0.1), fbm(p + 3.0 * q + vec2(8.3, 2.8) - t * 0.08));
  float d = fbm(p + 3.2 * w);
  return vec4(dye(q.x, w.y), d);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - uCenter) / uRadius;
  float r = length(uv);
  if (r >= 1.0) { gl_FragColor = vec4(0.0); return; }           // no halo: the glass ends at its edge
  float nz = sqrt(1.0 - r * r);
  float bright = uBright * (1.0 + 0.6 * uPulse) * (1.0 - 0.3 * uBreath);

  // The page behind: its overall tone, and only a heavily blurred, dimmed hint of it, flipped, near the bottom.
  vec3 avg = vec3(0.0);
  for (int i = 0; i < 8; i++) { float a = float(i) * 0.785; avg += back(uCenter + vec2(cos(a), sin(a)) * uRadius * 0.7); }
  avg /= 8.0;
  vec2 flip = uCenter + vec2(uv.x * 0.6, -uv.y * 0.5 - 0.3) * uRadius;
  vec3 hint = vec3(0.0);
  for (int i = 0; i < 8; i++) { float a = float(i) * 0.785; hint += back(flip + vec2(cos(a), sin(a)) * uRadius * 0.1); }
  hint /= 8.0;
  float hintMask = smoothstep(-0.2, -0.85, uv.y) * 0.5;
  vec3 refr = mix(avg, hint, hintMask);
  float lightPage = uLight;
  float shade = mix(lightPage > 0.5 ? 0.9 : 0.04, lightPage > 0.5 ? 0.97 : 0.3, smoothstep(0.3, -0.9, uv.y));
  vec3 glass = refr * shade + (lightPage > 0.5 ? vec3(-0.02, -0.01, 0.0) : vec3(0.02, 0.02, 0.03));

  // The smoke: three depth layers. It fills about the middle 70 %, denser low and wispier at the top.
  float fill = smoothstep(0.82, 0.3, r) * mix(1.0, 0.6, smoothstep(-0.6, 0.7, uv.y));
  vec4 L0 = smoke(uv, 1.3, 0.55, 0.0);
  vec4 L1 = smoke(uv * 1.05 + vec2(0.07, -0.04), 2.0, 0.8, 3.7);
  vec4 L2 = smoke(uv * 1.1 - vec2(0.05, 0.06), 3.1, 1.1, 7.3);
  float d0 = smoothstep(0.42, 0.85, L0.a) * 0.45, d1 = smoothstep(0.48, 0.82, L1.a) * 0.8, d2 = smoothstep(0.55, 0.8, L2.a) * 1.0;
  // A streamed chunk injects a bright puff that unfurls from just below the centre.
  vec2 puffAt = vec2(0.25 * sin(uTime * 1.7), -0.15 + 0.1 * cos(uTime * 1.3));
  float puff = uPulse * exp(-dot(uv - puffAt, uv - puffAt) / (0.05 + 0.1 * (1.0 - uPulse)));
  vec3 smokeLight = (L0.rgb * d0 + L1.rgb * d1 + L2.rgb * d2) * fill * bright;
  float dense = (d0 + d1 + d2) * fill;
  smokeLight += vec3(1.0, 0.96, 0.98) * pow(clamp(dense * 0.7, 0.0, 1.0), 2.4) * 1.4 * bright;   // white-hot where it is densest
  smokeLight += mix(vec3(1.0), L1.rgb, 0.4) * puff * 1.2;
  // It lights the glass around it and the rim near it.
  vec3 glow = (L0.rgb + L1.rgb) * 0.5 * smoothstep(1.0, 0.2, r) * 0.18 * bright;

  // A thin soft rim, brightest bottom-left and right, with a faint fringe; one broad dim reflection on top.
  float f = pow(1.0 - nz, 3.0);
  float where = 0.35 + 0.65 * max(smoothstep(0.4, -0.9, uv.y) * smoothstep(0.2, -0.8, uv.x), smoothstep(0.3, 0.95, uv.x));
  vec3 rim = vec3(f, pow(f, 1.15), pow(f, 1.3)) * 0.5 * where + (L1.rgb + L0.rgb) * 0.5 * f * 0.35 * bright;
  vec3 spec = vec3(1.0) * exp(-(pow(uv.x + 0.12, 2.0) / 0.22 + pow(uv.y - 0.62, 2.0) / 0.035)) * 0.16;

  vec3 col;
  if (lightPage > 0.5) {
    // On a light page: the dye covers the clear glass (it can't add light to white), so it stays vivid, never grey.
    float a = clamp(dense * 1.5 + puff * 0.6, 0.0, 0.96);
    vec3 dyeC = clamp(smokeLight / max(0.2, max(smokeLight.r, max(smokeLight.g, smokeLight.b))) * 0.92, 0.0, 1.0);
    col = mix(glass + glow * 0.5, mix(dyeC, vec3(1.0), clamp(dense - 0.9, 0.0, 1.0)), a) + rim * 0.6 - vec3(0.06) * f + spec * 0.6;
  } else {
    col = glass + glow + smokeLight + rim + spec;
  }
  float aa = smoothstep(1.0, 0.985, r);
  gl_FragColor = vec4(clamp(col, 0.0, 1.0) * aa, aa);
}
"""

STATES = {
    "idle":      dict(label="Idle", speed=0.25, bright=0.55, width=0, wisps=0, ripple=0, spin=0, danger=0, breath=0),
    "thinking":  dict(label="Thinking, writing", speed=0.9, bright=1.0, width=0, wisps=0, ripple=0, spin=0, danger=0, breath=0, pulse=0.6),
    "operating": dict(label="Operating MUSE", speed=0.8, bright=0.95, width=0, wisps=0, ripple=0, spin=1, danger=0, breath=0, pulse=0.5),
    "waiting":   dict(label="Waiting for you", speed=0.18, bright=1.15, width=0, wisps=0, ripple=0, spin=0, danger=0, breath=3.2),
    "error":     dict(label="Error", speed=0.1, bright=0.9, width=0, wisps=0, ripple=0, spin=0, danger=1, breath=0),
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
  await shot(1500, 760, {json.dumps(STILLS)}, {json.dumps(str(OUT / 'orb-smoke-states.png'))});
  await shot(1100, 220, {json.dumps(SMALL)}, {json.dumps(str(OUT / 'orb-smoke-small.png'))});
  const p = await b.newPage({{ viewport: {{ width: 720, height: 400 }} }}); p.on('pageerror', e => console.error(e));
  await p.goto({json.dumps(html.as_uri())}); await p.evaluate(() => document.fonts.load('13px muse'));
  const frame = {json.dumps(FRAME)};
  for (let f = 0; f < 240; f++) {{ await p.evaluate(`(${{frame}})(${{f}})`); await p.screenshot({{ path: `{frames}/f${{String(f).padStart(3, '0')}}.png` }}); }}
  await b.close(); }})();""")
        subprocess.run(["node", str(js)], check=True, env={**os.environ, "NODE_PATH": root})
        mp4 = OUT / "orb-smoke-preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(frames / "f%03d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "18", "-movflags", "+faststart", str(mp4)], check=True)
        print("wrote", mp4)


if __name__ == "__main__":
    main()
