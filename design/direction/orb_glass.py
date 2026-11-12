"""Claude's orb, Option B (owner's close-up, 2026-11-12): a transparent glass sphere that REFRACTS what is behind it (the
panel's text, bent and magnified like a water drop), smoky in its upper half, with one short thick crescent of light
(a caustic glint just below the centre, white-hot, its ends split into spectrum: gold on the left, cyan and violet on the
right) that lights the glass around it. A real ball lens: the page behind comes through upside down and squeezed to the
bottom; dark smoky top; a thin soft rim; a broad dim reflection on top; no halo. The glint is what moves, by state.
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

vec3 back(vec2 px) { return texture2D(uBack, clamp(px / uTex, 0.0, 1.0)).rgb; }

// A ray through a solid glass ball (index n): in at the front, out at the back, on to the page behind. The image comes
// out upside down and squeezed toward the bottom, as through a real glass ball. Returns where it lands, in radii.
vec2 throughBall(vec2 uv, float nz, float n) {
  vec3 p1 = vec3(uv, nz);
  vec3 t1 = refract(vec3(0.0, 0.0, -1.0), p1, 1.0 / n);
  vec3 p2 = p1 - 2.0 * dot(p1, t1) * t1;
  vec3 t2 = refract(t1, -p2, n);
  if (dot(t2, t2) < 1e-4) t2 = reflect(t1, -p2);               // total internal reflection at the very edge
  float s = (-3.2 - p2.z) / min(t2.z, -0.05);                   // the page sits behind the ball, past its focus
  return (p2.xy + s * t2.xy) * 0.55;
}

// The glint's spectrum: warm orange and gold at its left end, cyan, blue and violet at its right (error: red, orange).
vec3 spectrum(float x) {
  vec3 l = mix(vec3(1.0, 0.78, 0.45), vec3(1.0, 0.45, 0.15), clamp(-x, 0.0, 1.0));
  vec3 r = mix(vec3(0.45, 0.85, 1.0), mix(vec3(0.3, 0.5, 1.0), vec3(0.62, 0.42, 1.0), clamp(x * 2.0 - 1.0, 0.0, 1.0)), clamp(x * 1.6, 0.0, 1.0));
  vec3 c = mix(mix(l, vec3(1.0, 0.95, 0.9), smoothstep(-0.6, 0.0, x)), r, smoothstep(0.0, 0.6, x));
  return mix(c, mix(vec3(1.0, 0.35, 0.2), vec3(1.0, 0.65, 0.25), clamp(0.5 - x, 0.0, 1.0)), uDanger);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - uCenter) / uRadius;
  float r = length(uv);
  if (r >= 1.0) { gl_FragColor = vec4(0.0); return; }           // no halo: the glass ends at its edge
  float nz = sqrt(1.0 - r * r);
  float bright = uBright * (1.0 + 0.7 * uPulse) * (1.0 - 0.3 * uBreath);

  // The page behind, through the ball (a slight chromatic split from three indices).
  // Soft, like thick glass: four taps a little apart.
  vec2 q = throughBall(uv, nz, 1.5), qr = throughBall(uv, nz, 1.49), qb = throughBall(uv, nz, 1.51);
  float bl = 0.014 * uRadius;
  vec2 c0 = uCenter + q * uRadius;
  vec3 refr = vec3(back(uCenter + qr * uRadius).r, back(c0).g, back(uCenter + qb * uRadius).b) * 0.36
            + (back(c0 + vec2(bl, 0.0)) + back(c0 - vec2(bl, 0.0)) + back(c0 + vec2(0.0, bl)) + back(c0 - vec2(0.0, bl))) * 0.16;
  // Right at the edge the ball shows mostly a blur of the page around it.
  refr = mix(refr, back(uCenter + uv * uRadius * 1.1), smoothstep(0.85, 1.0, r) * 0.3);
  // Smoky glass: dark on top, clearer through the middle, lightest at the bottom where the inverted page shows.
  float top = uLight > 0.5 ? 0.45 : 0.1, bottom = uLight > 0.5 ? 0.95 : 0.85;
  float shade = mix(top, bottom, smoothstep(0.1, -0.85, uv.y)) * (0.7 + 0.3 * smoothstep(1.0, 0.6, r));
  vec3 col = refr * shade + (uLight > 0.5 ? vec3(0.0) : vec3(0.03, 0.03, 0.035) * (0.5 + 0.5 * smoothstep(0.9, -0.9, uv.y)));

  // The glint: one short thick crescent just below the centre, bulging up, white-hot and widest in the middle, tapering
  // and fading well before the rim; its ends split into spectrum. It drifts, slides and tilts with the state.
  float slide = 0.06 * sin(uPhase * 0.9) + uSpin * 0.32 * sin(uPhase * 1.3);
  float tilt = 0.08 * sin(uPhase * 0.7) + uSpin * 0.18 * sin(uPhase * 1.3 + 0.6);
  vec2 g = uv - vec2(slide, -0.16);
  g = vec2(cos(tilt) * g.x + sin(tilt) * g.y, -sin(tilt) * g.x + cos(tilt) * g.y);
  float halfLen = (0.6 + 0.2 * uWidth) * (1.0 + 0.25 * uPulse);
  float x = g.x / halfLen;
  float taper = clamp(1.0 - x * x, 0.0, 1.0);
  float curve = 0.07 * (1.0 - x * x) - 0.03;                 // bulges upward in the middle
  float ripple = uRipple * 0.012 * sin(x * 9.0 - uTime * 6.0);
  float d = g.y - curve - ripple;
  float w = (0.055 + 0.05 * uWidth) * pow(taper, 0.7) + 0.004;
  float core = exp(-pow(d / (0.45 * w), 2.0)) * pow(taper, 1.6);
  float body = exp(-pow(d / w, 2.0)) * pow(taper, 1.1);
  float ends = smoothstep(0.25, 0.9, abs(x)) * taper;          // the spectrum lives toward the ends
  vec3 glint = vec3(1.0, 0.98, 0.95) * core * 2.0 * (1.0 - 0.5 * ends) + spectrum(x) * body * (0.45 + 1.6 * ends)
             + spectrum(x * 1.2 + 0.08 * sin(uTime * 3.0) * uWisps) * exp(-pow(d / (2.2 * w), 2.0)) * taper * ends * 0.8 * (1.0 + uWisps);
  // It lights the glass: a soft glow just above and below it, fading smoothly.
  vec3 spill = mix(vec3(0.95, 0.88, 0.78), spectrum(x), 0.4) * exp(-pow(d / 0.24, 2.0)) * pow(taper, 0.7) * 0.45;
  spill += vec3(0.8, 0.76, 0.72) * exp(-pow(max(-d, 0.0) / 0.45, 1.5)) * step(d, 0.0) * taper * 0.08;
  col += (glint + spill) * bright;

  // A thin soft rim, brightest bottom-left and right, with a rainbow fringe where the glint's ends meet it.
  float f = pow(1.0 - nz, 3.0);
  float ang = atan(uv.y, uv.x);
  float where = 0.35 + 0.65 * max(smoothstep(0.4, -0.9, uv.y) * smoothstep(0.2, -0.8, uv.x), smoothstep(0.3, 0.95, uv.x));
  vec3 fringe = vec3(f, pow(f, 1.15), pow(f, 1.3));
  float nearGlintL = exp(-pow((ang - 3.4) / 0.35, 2.0)), nearGlintR = exp(-pow((ang + 0.3) / 0.35, 2.0));
  col += fringe * 0.5 * where + (spectrum(-0.9) * nearGlintL + spectrum(0.9) * nearGlintR) * f * 0.55 * bright;

  // A broad, soft, dim reflection on top.
  col += vec3(1.0) * exp(-(pow(uv.x + 0.12, 2.0) / 0.22 + pow(uv.y - 0.62, 2.0) / 0.035)) * 0.16;

  float aa = smoothstep(1.0, 0.985, r);
  gl_FragColor = vec4(clamp(col, 0.0, 1.0) * aa, aa);
}
"""

STATES = {
    "idle":      dict(label="Idle", speed=0.22, bright=0.75, width=0.35, wisps=0, ripple=0, spin=0, danger=0, breath=0),
    "thinking":  dict(label="Thinking, writing", speed=0.8, bright=1.0, width=1.0, wisps=1, ripple=1, spin=0, danger=0, breath=0, pulse=0.35),
    "operating": dict(label="Operating MUSE", speed=0.9, bright=0.95, width=0.7, wisps=0.4, ripple=0.2, spin=1, danger=0, breath=0, pulse=0.6),
    "waiting":   dict(label="Waiting for you", speed=0.12, bright=1.05, width=0.7, wisps=0, ripple=0, spin=0, danger=0, breath=3.2),
    "error":     dict(label="Error", speed=0.1, bright=0.85, width=0.55, wisps=0, ripple=0, spin=0, danger=1, breath=0),
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
