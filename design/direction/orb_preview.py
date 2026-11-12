"""Claude's orb, second pass (owner, 2026-11-12): multicolour liquid light in a dark glass sphere. Renders the five state
stills in three themes and a 6 s preview cycling through the states, from the SAME maths as MuseCore's ClaudeOrbLiquid
(ported to JavaScript below; keep the two in step).

    python3 design/direction/orb_preview.py
    → plans/design/claude-panel/orb-states-{b,a,c}.png, orb-preview.mp4

Needs Playwright's Chromium (preinstalled) and ffmpeg.
"""
import json, os, subprocess, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "plans/design/claude-panel"
FONTS = REPO / "android/app/src/main/res/font"
THEMES = {"b": dict(canvas="#0D0E0F", ink="#ECEAE5", ink2="#A9A6A0", font="barlow_500"),
          "a": dict(canvas="#EFEBE3", ink="#141210", ink2="#67605A", font="archivo_500"),
          "c": dict(canvas="#E7E2D9", ink="#23262A", ink2="#5E5C57", font="outfit_500")}

# MuseCore ClaudeOrb.look + ClaudeOrbLiquid, in JavaScript.
JS = r"""
const PALETTE = [0xFF3DA8, 0x8E5BFF, 0x3B82FF, 0x2FE0C0], ERR = [0xFF4D3D, 0xFF8A2B, 0xD9302B, 0xFFB347];
const LOOKS = {
  idle:      {swirl: .12, band: .45, glow: .10, breath: 6,   depth: .35, sweep: false, flashes: false, danger: false},
  thinking:  {swirl: .65, band: .85, glow: .28, breath: 0,   depth: 0,   sweep: false, flashes: true,  danger: false},
  operating: {swirl: .45, band: .80, glow: .35, breath: 0,   depth: 0,   sweep: true,  flashes: true,  danger: false},
  waiting:   {swirl: .10, band: .95, glow: .45, breath: 3.2, depth: .20, sweep: false, flashes: false, danger: false},
  error:     {swirl: .06, band: .70, glow: .30, breath: 0,   depth: 0,   sweep: false, flashes: false, danger: true},
};
const mix = (a, b, t) => a + (b - a) * t;
function lattice(seed, i) { const v = Math.sin(i * 127.1 + seed * 311.7) * 43758.5453; return (v - Math.floor(v)) * 2 - 1; }
function noise(seed, x) { const i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f); return mix(lattice(seed, i), lattice(seed, i + 1), u); }
function blobs(phase, time, look, pulse) {
  const colors = look.danger ? ERR : PALETTE;
  const sweepAt = ((time * 0.45) % 1) * 2.6 - 1.3;
  return [0, 1, 2, 3].map(i => {
    const s = i * 17;
    let x = 0.6 * noise(s + 1, phase * 0.9), y = 0.6 * noise(s + 5, phase * 0.75);
    if (look.sweep) { const lane = (i - 1.5) / 1.5; x = mix(x, sweepAt + 0.35 * lane, 0.65); y = mix(y, 0.25 * lane, 0.4); }
    const radius = 0.62 + 0.18 * noise(s + 9, phase * 0.6) + 0.18 * pulse;
    const alpha = Math.max(0, Math.min(0.9, look.band * (0.6 + 0.25 * noise(s + 13, phase * 0.5)) + 0.18 * pulse));
    const c = colors[i];
    return {x, y, radius, alpha, r: (c >> 16) & 255, g: (c >> 8) & 255, b: c & 255};
  });
}
function glowOf(look, time, pulse) {
  let g = look.glow;
  if (look.breath > 0) g *= 1 - look.depth * 0.5 * (1 - Math.cos(2 * Math.PI * time / look.breath));
  if (look.flashes) g += (1 - g) * 0.6 * pulse;
  return Math.min(1, Math.max(0, g));
}
// One orb, as the Mac draws it (ClaudeOrbView): halo, dark glass, additive blobs, inner shadow, rim and highlight.
function drawOrb(ctx, cx, cy, R, look, phase, time, pulse) {
  const glow = glowOf(look, time, pulse);
  const halo = look.danger ? [255, 90, 60] : [150, 110, 255];
  let h = ctx.createRadialGradient(cx, cy, R * 0.8, cx, cy, R * 1.6);
  h.addColorStop(0, `rgba(${halo},${0.15 + 0.6 * glow})`); h.addColorStop(1, `rgba(${halo},0)`);
  ctx.fillStyle = h; ctx.beginPath(); ctx.arc(cx, cy, R * 1.6, 0, 7); ctx.fill();
  ctx.save(); ctx.beginPath(); ctx.arc(cx, cy, R, 0, 7); ctx.clip();
  let base = ctx.createRadialGradient(cx, cy + R * 0.25, 0, cx, cy, R * 1.05);
  base.addColorStop(0, '#17181d'); base.addColorStop(1, '#040406');
  ctx.fillStyle = base; ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R);
  ctx.globalCompositeOperation = 'lighter';
  for (const b of blobs(phase, time, look, pulse)) {
    const bx = cx + b.x * R, by = cy + b.y * R, br = b.radius * R;
    const gr = ctx.createRadialGradient(bx, by, 0, bx, by, br);
    gr.addColorStop(0, `rgba(${b.r},${b.g},${b.b},${b.alpha})`);
    gr.addColorStop(0.45, `rgba(${b.r},${b.g},${b.b},${b.alpha * 0.45})`);
    gr.addColorStop(1, `rgba(${b.r},${b.g},${b.b},0)`);
    ctx.fillStyle = gr; ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R);
  }
  ctx.globalCompositeOperation = 'source-over';
  let inner = ctx.createRadialGradient(cx, cy, R * 0.62, cx, cy, R);
  inner.addColorStop(0, 'rgba(0,0,0,0)'); inner.addColorStop(1, 'rgba(0,0,0,0.55)');
  ctx.fillStyle = inner; ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R);
  let hi = ctx.createRadialGradient(cx - R * 0.3, cy - R * 0.55, 0, cx - R * 0.3, cy - R * 0.55, R * 0.45);
  hi.addColorStop(0, 'rgba(255,255,255,0.32)'); hi.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = hi; ctx.fillRect(cx - R, cy - R, 2 * R, 2 * R);
  ctx.restore();
  let rim = ctx.createLinearGradient(cx, cy - R, cx, cy + R);
  rim.addColorStop(0, 'rgba(255,255,255,0.55)'); rim.addColorStop(0.5, 'rgba(255,255,255,0.08)'); rim.addColorStop(1, 'rgba(255,255,255,0.22)');
  ctx.strokeStyle = rim; ctx.lineWidth = Math.max(1, R * 0.03); ctx.beginPath(); ctx.arc(cx, cy, R - ctx.lineWidth / 2, 0, 7); ctx.stroke();
}
"""

STILLS = r"""
<canvas id=c></canvas><script>%JS%
document.fonts.load('15px muse').then(() => {
const W = %W%, H = %H%, dpr = 2, c = document.getElementById('c');
c.width = W * dpr; c.height = H * dpr; c.style.width = W + 'px'; c.style.height = H + 'px';
const ctx = c.getContext('2d'); ctx.scale(dpr, dpr);
ctx.fillStyle = '%CANVAS%'; ctx.fillRect(0, 0, W, H);
const S = [['idle', 'Idle', 'Slow drift, low light'], ['thinking', 'Thinking, writing', 'Faster flow, swells per chunk'],
           ['operating', 'Operating MUSE', 'Sweeps across, flash per action'], ['waiting', 'Waiting for you', 'Steady glow, slow pulse'],
           ['error', 'Error', 'Red and orange, slowed']];
const pulses = {thinking: 0.55, operating: 0.8};
S.forEach(([k, label, note], i) => {
  const cx = 90 + i * 180;
  drawOrb(ctx, cx, 78, 34, LOOKS[k], 2.7 + i * 1.3, 0.9 + i * 0.37, pulses[k] || 0);
  ctx.textAlign = 'center'; ctx.fillStyle = '%INK%'; ctx.font = '500 15px muse'; ctx.fillText(label, cx, 150);
  ctx.fillStyle = '%INK2%'; ctx.font = '500 12px muse'; ctx.fillText(note, cx, 170);
});
});
</script>"""

PREVIEW = r"""
<canvas id=c></canvas><script>%JS%
const W = 480, H = 480, c = document.getElementById('c'); c.width = W; c.height = H;
const ctx = c.getContext('2d');
// 6 s: idle → thinking (a chunk every 0.15 s) → operating (an action every 0.4 s) → waiting → error. 1.2 s each.
const ORDER = [['idle', 'Idle'], ['thinking', 'Thinking, writing'], ['operating', 'Operating MUSE'], ['waiting', 'Waiting for you'], ['error', 'Error']];
let phase = 0, last = 0, lastPulse = -9;
window.frame = (t) => {
  const k = Math.min(4, Math.floor(t / 1.2)), [state, label] = ORDER[k], look = LOOKS[state];
  const local = t - k * 1.2;
  if (state === 'thinking' && Math.floor(local / 0.15) !== Math.floor((local - 1 / 30) / 0.15)) lastPulse = t;
  if (state === 'operating' && Math.floor(local / 0.4) !== Math.floor((local - 1 / 30) / 0.4)) lastPulse = t;
  const u = (t - lastPulse) / 0.6, pulse = look.flashes && u < 1 ? (1 - u) * (1 - u) : 0;
  phase += Math.min(0.25, Math.max(0, t - last)) * Math.max(0.02, look.swirl); last = t;
  ctx.fillStyle = '#0D0E0F'; ctx.fillRect(0, 0, W, H);
  drawOrb(ctx, W / 2, 210, 110, look, phase, t, pulse);
  ctx.textAlign = 'center'; ctx.fillStyle = '#ECEAE5'; ctx.font = '500 22px muse'; ctx.fillText(label, W / 2, 420);
};
</script>"""


def font_face(t):
    return f'<style>@font-face{{font-family:muse;src:url("{(FONTS / (t["font"] + ".ttf")).as_uri()}")}}body{{margin:0;background:{t["canvas"]}}}</style>'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        jobs = []
        for k, t in THEMES.items():
            html = font_face(t) + STILLS.replace("%JS%", JS).replace("%W%", "900").replace("%H%", "200").replace("%CANVAS%", t["canvas"]) \
                .replace("%INK%", t["ink"]).replace("%INK2%", t["ink2"])
            f = tmp / f"stills-{k}.html"; f.write_text(html)
            jobs.append({"html": f.as_uri(), "png": str(OUT / f"orb-states-{k}.png"), "w": 900, "h": 200})
        prev = tmp / "preview.html"; prev.write_text(font_face(THEMES["b"]) + PREVIEW.replace("%JS%", JS))
        frames = tmp / "frames"; frames.mkdir()
        js = tmp / "shot.js"
        js.write_text("""const { chromium } = require('playwright');
(async () => { const [jobs, prev, dir] = JSON.parse(process.argv[2]); const b = await chromium.launch();
  for (const j of jobs) { const p = await b.newPage({ viewport: { width: j.w, height: j.h }, deviceScaleFactor: 2 });
    await p.goto(j.html); await p.waitForTimeout(300); await p.screenshot({ path: j.png }); await p.close(); console.log('wrote', j.png); }
  const p = await b.newPage({ viewport: { width: 480, height: 480 } }); await p.goto(prev); await p.evaluate(() => document.fonts.load('22px muse')); await p.waitForTimeout(300);
  for (let f = 0; f < 180; f++) { await p.evaluate(t => window.frame(t), f / 30);
    await p.screenshot({ path: `${dir}/f${String(f).padStart(3, '0')}.png` }); }
  await b.close(); })();""")
        subprocess.run(["node", str(js), json.dumps([jobs, prev.as_uri(), str(frames)])], check=True, env={**os.environ, "NODE_PATH": root})
        mp4 = OUT / "orb-preview.mp4"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(frames / "f%03d.png"), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-crf", "20", "-movflags", "+faststart", str(mp4)], check=True)
        print("wrote", mp4)


if __name__ == "__main__":
    main()
