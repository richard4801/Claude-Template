"""Claude's orb, third pass (owner, 2026-11-12): a luminous vortex, not a ball. Twisting ribbons of light spiral round a
bright core in 3D (perspective, depth-sorted: front bright and sharp, back dim and soft), white-hot at their centre with
iridescent edges, a faint Fresnel shimmer where the light meets the boundary and a halo tinted by the ribbons. No opaque
disc and no rim line: the shape is the light. The same fragment shader (GLSL here, Metal in the app:
mac/Muse/Resources/ClaudeOrb.metal) is driven by ClaudeOrb's phase and state.

    python3 design/direction/orb_shader.py
    → plans/design/claude-panel/orb-vortex-states.png (256 px, the five states on the dark and the light theme)
      plans/design/claude-panel/orb-vortex-small.png  (28–36 pt in the panel, both themes)
      plans/design/claude-panel/orb-vortex-preview.mp4 (8 s cycling the states, dark and light side by side)
"""
import json, os, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans/design/claude-panel"
FONT = (REPO / "android/app/src/main/res/font/barlow_500.ttf").as_uri()

# The fragment shader. Mirrors ClaudeOrb.metal line for line (keep them in step).
FRAG = r"""
precision highp float;
uniform vec2 uRes, uOrigin; uniform float uScale, uPhase, uTime, uCount, uBright, uAlign, uDanger, uPulse, uBreath, uLight;
const float PI = 3.14159265;
const int RIBBONS = 4; const int SEG = 40;

vec3 rotX(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z); }
vec3 rotY(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z); }
vec3 rotZ(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z); }

// Iridescent colour along a ribbon: magenta → violet → blue → cyan (error: red → orange).
vec3 iris(float h) {
  h = fract(h);
  vec3 a = vec3(1.0, 0.24, 0.66), b = vec3(0.56, 0.36, 1.0), c = vec3(0.23, 0.51, 1.0), d = vec3(0.18, 0.88, 0.75);
  vec3 col = h < 0.25 ? mix(a, b, h * 4.0) : h < 0.5 ? mix(b, c, h * 4.0 - 1.0) : h < 0.75 ? mix(c, d, h * 4.0 - 2.0) : mix(d, a, h * 4.0 - 3.0);
  vec3 err = mix(vec3(1.0, 0.3, 0.22), vec3(1.0, 0.62, 0.2), 0.5 + 0.5 * sin(h * 6.283));
  return mix(col, err, uDanger);
}

// A point of ribbon k at s (0…1): a spiral arm in a tilted plane, wobbling, turning with the phase; then perspective.
vec3 ribbon(int k, float s) {
  float fk = float(k);
  float th = s * 2.4 * PI + uPhase * (1.0 + 0.25 * fk) + fk * 2.0 * PI / max(uCount, 1.0);
  float r = 0.10 + 0.78 * pow(s, 0.85);
  vec3 p = vec3(r * cos(th), r * sin(th), 0.16 * sin(2.0 * th + uPhase * 1.3 + fk));
  float tilt = mix(1.05 + 0.35 * sin(fk * 1.7 + uPhase * 0.21), 1.15, uAlign);
  p = rotX(p, tilt);
  p = rotY(p, mix(0.5 * sin(fk * 2.3 + uPhase * 0.17), 0.0, uAlign));
  p = rotZ(p, mix(fk * 0.9 + uPhase * 0.12, uPhase * 0.6, uAlign));
  float persp = 3.0 / (3.0 - p.z);
  return vec3(p.xy * persp * 0.78, p.z);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - uOrigin - 0.5 * uRes) / (0.5 * min(uRes.x, uRes.y)) * uScale;
  float len = length(uv);
  vec3 light = vec3(0.0);
  vec3 tint = vec3(0.0); float tintW = 0.0;
  float bright = uBright * (1.0 + 0.6 * uPulse) * (1.0 - 0.25 * uBreath);
  for (int k = 0; k < RIBBONS; k++) {
    if (float(k) >= uCount) break;
    // Thin parts (white core, coloured glow) from the nearest point of the ribbon: crisp, no beads. The wide light from
    // a line integral along it (each segment weighted by its length): one smooth field, no seams.
    float best = 1e3, bs = 0.0, bz = 0.0;
    vec3 wideAcc = vec3(0.0);
    vec3 a = ribbon(k, 0.0);
    for (int i = 1; i <= SEG; i++) {
      float s1 = float(i) / float(SEG);
      vec3 b = ribbon(k, s1);
      vec2 ab = b.xy - a.xy, ap = uv - a.xy;
      float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
      float d = length(ap - ab * t);
      float sm = s1 - (1.0 - t) / float(SEG);
      float z = mix(a.z, b.z, t);
      if (d < best) { best = d; bs = sm; bz = z; }
      float fr = clamp(0.5 + 0.9 * z, 0.0, 1.0), tp = pow(sin(PI * clamp(sm, 0.0, 1.0)), 0.9);
      float ww = 4.0 * (0.03 + 0.055 * tp) * mix(1.9, 0.8, fr);
      wideAcc += iris(0.12 * float(k) + 0.55 * sm + 0.05 * uPhase) * exp(-pow(d / ww, 2.0)) * length(ab) / (ww * 1.772) * tp * mix(0.35, 1.0, fr);
      a = b;
    }
    float front = clamp(0.5 + 0.9 * bz, 0.0, 1.0);          // 0 back … 1 front
    float taper = pow(sin(PI * clamp(bs, 0.0, 1.0)), 0.9);   // thick in the middle, fine at the ends
    float w = (0.03 + 0.055 * taper) * mix(1.9, 0.8, front) * (1.0 + 0.35 * uPulse);
    float core = exp(-pow(best / (0.28 * w), 2.0));
    float glow = exp(-pow(best / w, 2.0));
    vec3 col = iris(0.12 * float(k) + 0.55 * bs + 0.05 * uPhase);
    float br = bright * taper * mix(0.35, 1.0, front);
    light += (vec3(1.0, 0.97, 1.0) * core * 0.8 + col * glow * 0.85) * br + wideAcc * 0.4 * bright;
    tint += col * glow * br + wideAcc * bright; tintW += glow * br + dot(wideAcc, vec3(0.333)) * bright;
  }
  vec3 avg = tintW > 0.0 ? tint / tintW : vec3(0.55, 0.45, 1.0);
  // The bright core the ribbons turn round.
  light += mix(vec3(1.0), avg, 0.35) * exp(-len * len / 0.018) * 0.9 * bright;
  light += avg * exp(-len * len / 0.15) * 0.35 * bright;
  // A faint glassy boundary: a Fresnel shimmer, only where the light reaches the edge.
  float rim = exp(-pow((len - 0.92) / 0.06, 2.0));
  light += avg * rim * 0.07 * bright * (0.4 + 0.6 * clamp(tintW, 0.0, 1.0));
  // The halo, tinted by the ribbons, bleeding into the page.
  light += avg * exp(-pow(max(len - 0.35, 0.0) / 0.45, 2.0)) * 0.12 * bright;
  light *= smoothstep(1.25, 0.85, len);
  vec3 c = 1.0 - exp(-light * 1.4);                        // soft tone map
  float alpha = clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0);
  // On a light page the light needs a little shade behind it to read: a soft, transparent pool (never a disc).
  float pool = uLight * 0.38 * exp(-len * len / 0.42) * clamp(0.35 + bright, 0.0, 1.0);
  vec3 shade = vec3(0.09, 0.07, 0.17);
  float outA = alpha + pool * (1.0 - alpha);
  vec3 outC = c + shade * pool * (1.0 - alpha);
  gl_FragColor = vec4(outC, outA);                         // premultiplied
}
"""

# MuseCore ClaudeOrb looks, as shader uniforms (ClaudeOrbView maps them the same way).
STATES = {
    "idle":      dict(label="Idle", count=2, speed=0.25, bright=0.55, align=0, danger=0, breath=6),
    "thinking":  dict(label="Thinking, writing", count=4, speed=1.1, bright=1.0, align=0, danger=0, breath=0, pulse=0.15),
    "operating": dict(label="Operating MUSE", count=4, speed=0.9, bright=0.95, align=1, danger=0, breath=0, pulse=0.4),
    "waiting":   dict(label="Waiting for you", count=1, speed=0.18, bright=1.1, align=0, danger=0, breath=3.2),
    "error":     dict(label="Error", count=3, speed=0.12, bright=0.8, align=0, danger=1, breath=0),
}

PAGE = r"""<!doctype html><meta charset=utf-8>
<style>@font-face{font-family:muse;src:url("%FONT%")}body{margin:0;font-family:muse}</style>
<body><canvas id=gl></canvas><canvas id=tx style="position:absolute;left:0;top:0"></canvas>
<script>
const FRAG = %FRAG%, STATES = %STATES%;
const VERT = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }';
let gl, prog, U = {};
function init(W, H, dpr) {
  const c = document.getElementById('gl'); c.width = W * dpr; c.height = H * dpr; c.style.width = W + 'px'; c.style.height = H + 'px';
  const t = document.getElementById('tx'); t.width = W * dpr; t.height = H * dpr; t.style.width = W + 'px'; t.style.height = H + 'px';
  gl = c.getContext('webgl', { premultipliedAlpha: true, preserveDrawingBuffer: true });
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw gl.getShaderInfoLog(s); return s; };
  prog = gl.createProgram(); gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG)); gl.linkProgram(prog);
  gl.useProgram(prog);
  const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  for (const n of ['uRes','uOrigin','uScale','uPhase','uTime','uCount','uBright','uAlign','uDanger','uPulse','uBreath','uLight']) U[n] = gl.getUniformLocation(prog, n);
  gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); gl.enable(gl.SCISSOR_TEST);
  return t.getContext('2d');
}
const hex = h => [parseInt(h.slice(1,3),16)/255, parseInt(h.slice(3,5),16)/255, parseInt(h.slice(5,7),16)/255];
function rect(x, y, w, h, bg, dpr, H) { const [r,g,b] = hex(bg); gl.scissor(x*dpr, (H-y-h)*dpr, w*dpr, h*dpr); gl.clearColor(r,g,b,1); gl.clear(gl.COLOR_BUFFER_BIT); }
function orb(x, y, size, st, phase, time, pulse, light, dpr, H) {
  const pad = size * 0.35, s = size + 2 * pad;  // room for the halo
  const vx = (x - pad) * dpr, vy = (H - y - size - pad) * dpr;
  gl.viewport(vx, vy, s * dpr, s * dpr); gl.scissor(vx, vy, s * dpr, s * dpr);
  gl.uniform2f(U.uRes, s * dpr, s * dpr); gl.uniform2f(U.uOrigin, vx, vy); gl.uniform1f(U.uScale, s / size); gl.uniform1f(U.uPhase, phase); gl.uniform1f(U.uTime, time);
  gl.uniform1f(U.uCount, st.count); gl.uniform1f(U.uBright, st.bright); gl.uniform1f(U.uAlign, st.align); gl.uniform1f(U.uDanger, st.danger);
  gl.uniform1f(U.uPulse, pulse); gl.uniform1f(U.uBreath, st.breath > 0 ? 0.5 - 0.5 * Math.cos(2 * Math.PI * time / st.breath) : 0); gl.uniform1f(U.uLight, light);
  // The orb fills the inner square; the shader's uv is ±1 over the whole viewport, so scale it: draw at s with the orb at size.
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4); gl.finish();
  if (gl.isContextLost()) console.log('CONTEXT LOST'); const e = gl.getError(); if (e) console.log('GL ERROR ' + e);
}
window.STATES = STATES;
</script>"""


def page():
    return PAGE.replace("%FONT%", FONT).replace("%FRAG%", json.dumps(FRAG)).replace("%STATES%", json.dumps(STATES))


STILLS_JS = r"""async () => {
  await document.fonts.load('14px muse');
  const W = 1280, H = 640, dpr = 2, tx = init(W, H, dpr); tx.scale(dpr, dpr);
  const keys = Object.keys(STATES), bgs = [['#0D0E0F', '#ECEAE5', 0], ['#EFEBE3', '#141210', 1]];
  bgs.forEach(([bg, ink, light], row) => {
    rect(0, row * 320, W, 320, bg, dpr, H);
    keys.forEach((k, i) => { const st = STATES[k];
      orb(48 + i * 248, row * 320 + 26, 180, st, 2.4 + i * 1.7, 1.1 + i * 0.6, st.pulse || 0, light, dpr, H);
      tx.fillStyle = ink; tx.font = '15px muse'; tx.textAlign = 'center'; tx.fillText(st.label, 138 + i * 248, row * 320 + 296); });
  });
}"""

SMALL_JS = r"""async () => {
  await document.fonts.load('14px muse');
  const W = 1000, H = 200, dpr = 2, tx = init(W, H, dpr); tx.scale(dpr, dpr);
  const keys = Object.keys(STATES), bgs = [['#17191B', '#ECEAE5', 0], ['#F8F5EF', '#141210', 1]];
  bgs.forEach(([bg, ink, light], row) => {
    rect(0, row * 100, W, 100, bg, dpr, H);
    keys.forEach((k, i) => { const st = STATES[k], size = [28, 32, 36, 32, 28][i];
      orb(24 + i * 196, row * 100 + 50 - size / 2, size, st, 2.4 + i * 1.7, 1.1 + i * 0.6, st.pulse || 0, light, dpr, H);
      tx.fillStyle = ink; tx.font = '13px muse'; tx.textAlign = 'left'; tx.fillText(`${st.label}, ${size} pt`, 24 + i * 196 + size + 12, row * 100 + 55); });
  });
}"""

# The preview: 8 s, 1.6 s per state; chunks every 0.15 s while thinking and an action every 0.4 s while operating flash.
FRAME_JS = r"""(f) => {
  const W = 720, H = 400, dpr = 1;
  if (!window._tx) { window._tx = init(W, H, dpr); window._phase = 0; window._last = 0; window._pulseAt = -9; }
  const tx = window._tx, t = f / 30, keys = Object.keys(STATES), k = Math.min(4, Math.floor(t / 1.6)), st = STATES[keys[k]], local = t - k * 1.6;
  const every = keys[k] === 'thinking' ? 0.15 : keys[k] === 'operating' ? 0.4 : 0;
  if (every && Math.floor(local / every) !== Math.floor((local - 1 / 30) / every)) window._pulseAt = t;
  const u = (t - window._pulseAt) / 0.6, pulse = every && u < 1 ? (1 - u) * (1 - u) : 0;
  window._phase += Math.min(0.25, t - window._last) * st.speed; window._last = t;
  tx.clearRect(0, 0, W, H);
  [['#0D0E0F', '#ECEAE5', 0], ['#EFEBE3', '#141210', 1]].forEach(([bg, ink, light], i) => {
    rect(i * 360, 0, 360, H, bg, dpr, H);
    orb(i * 360 + 80, 60, 200, st, window._phase, t, pulse, light, dpr, H);
    tx.fillStyle = ink; tx.font = '18px muse'; tx.textAlign = 'center'; tx.fillText(st.label, i * 360 + 180, 370);
  });
}"""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        html = tmp / "orb.html"; html.write_text(page())
        frames = tmp / "frames"; frames.mkdir()
        js = tmp / "run.js"
        js.write_text(f"""const {{ chromium }} = require('playwright');
(async () => {{ const b = await chromium.launch({{ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] }});
  const shot = async (w, h, fn, png) => {{ const p = await b.newPage({{ viewport: {{ width: w, height: h }}, deviceScaleFactor: 2 }});
    p.on('pageerror', e => console.error(e)); p.on('console', m => console.log(m.text()));
    await p.goto({json.dumps(html.as_uri())});
    await p.evaluate('(' + fn + ')()'); await p.waitForTimeout(200); await p.screenshot({{ path: png }}); await p.close(); console.log('wrote', png); }};
  await shot(1280, 640, {json.dumps(STILLS_JS)}, {json.dumps(str(OUT / 'orb-vortex-states.png'))});
  await shot(1000, 200, {json.dumps(SMALL_JS)}, {json.dumps(str(OUT / 'orb-vortex-small.png'))});
  const p = await b.newPage({{ viewport: {{ width: 720, height: 400 }}, deviceScaleFactor: 1 }});
  await p.goto({json.dumps(html.as_uri())}); await p.evaluate(() => document.fonts.load('18px muse'));
  const frame = {json.dumps(FRAME_JS)};
  for (let f = 0; f < 240; f++) {{ await p.evaluate(`(${{frame}})(${{f}})`); await p.screenshot({{ path: `{frames}/f${{String(f).padStart(3, '0')}}.png` }}); }}
  await b.close(); }})();""")
        subprocess.run(["node", str(js)], check=True, env={**os.environ, "NODE_PATH": root})
        mp4 = OUT / "orb-vortex-preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(frames / "f%03d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "18", "-movflags", "+faststart", str(mp4)], check=True)
        print("wrote", mp4)


if __name__ == "__main__":
    main()
