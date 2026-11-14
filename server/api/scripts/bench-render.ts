// Local benchmark: one edit render (the render test's project: cut, fade, speed curve, zoom, Look, text, music) at export
// size and quality, under the SMALL (Trial) and LARGE media profiles (lib/resources.ts). No database, no network.
//   npx tsx scripts/bench-render.ts [seconds per clip, default 6] [runs, default 2]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import * as M from '../src/editor/model.js';
import { renderProject } from '../src/editor/render.js';
import { detectResources, mediaProfile, setMediaResources } from '../src/lib/resources.js';

const SEC = Number(process.argv[2] ?? 6), RUNS = Number(process.argv[3] ?? 2);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-bench-'));
const ff = (...a: string[]) => execFileSync('ffmpeg', ['-y', '-v', 'error', ...a]);
const files: Record<string, string> = {};
for (const [id, src] of [['a', 'testsrc2'], ['b', 'mandelbrot'], ['c', 'smptehdbars']] as const) {
  files[id] = path.join(dir, `${id}.mp4`);
  ff('-f', 'lavfi', '-i', `${src}=s=1080x1920:r=30`, '-f', 'lavfi', '-i', `sine=frequency=440:duration=${SEC}`, '-t', String(SEC), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-c:a', 'aac', files[id]!);
}
files.m = path.join(dir, 'm.m4a');
ff('-f', 'lavfi', '-i', `sine=frequency=220:duration=${SEC * 3}`, '-c:a', 'aac', files.m!);

const project = (): M.EditProject => ({
  version: 2, sourceTakeId: 'ta', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
  assets: [{ id: 'a', kind: 'video', take: 'ta', durationSec: SEC }, { id: 'b', kind: 'video', take: 'tb', durationSec: SEC }, { id: 'c', kind: 'video', take: 'tc', durationSec: SEC }, { id: 'm', kind: 'audio', upload: 'up_m', durationSec: SEC * 3 }],
  tracks: [
    { id: 'main', kind: 'main', items: [
      { id: 'c1', asset: 'a', inSec: 0, outSec: SEC, speed: 1 } as M.VideoClip,
      { id: 'c2', asset: 'b', inSec: 0, outSec: SEC, speed: 1, transitionIn: { kind: 'fade', durationSec: 0.4 }, speedCurve: { preset: 'custom', points: [[0, 1], [0.5, 0.5], [1, 1]] } } as M.VideoClip,
      { id: 'c3', asset: 'c', inSec: 0, outSec: SEC, speed: 1, keyframes: { scale: [{ t: 0, v: 1 }, { t: SEC, v: 2 }] }, look: { lut: 'pack:bw-classic', strength: 1 } } as M.VideoClip,
    ] },
    { id: 'text', kind: 'text', items: [{ id: 'x1', startSec: 0.2, durationSec: SEC, text: 'HELLO', style: { font: 'sans', weight: 900, sizePct: 0.08, color: '#FFFFFF', align: 'center', stroke: { color: '#000000', widthPct: 0.08 } }, transform: { x: 0.5, y: 0.5 } } as M.TextItem] },
    { id: 'mus', kind: 'music', items: [{ id: 'mu', asset: 'm', startSec: 0, inSec: 0, outSec: SEC * 3 } as M.AudioClip] },
  ],
});

const host = detectResources({});
const one = async (tag: string) => {
  const t0 = Date.now();
  const r = await renderProject({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, project(), files, path.join(dir, `${tag}.mp4`), { quality: 'export' });
  return { ms: Date.now() - t0, sec: r.durationSec };
};
const out: string[] = [`host: ${host.cpus} CPUs, ${host.memMB} MB; edit ${SEC * 3}s at 1080×1920, export quality`];
for (const [name, res] of [['SMALL (trial)', { cpus: host.cpus, memMB: 1024 }], ['LARGE', host]] as const) {
  setMediaResources(res);
  const p = mediaProfile();
  const times: number[] = [];
  let sec = 0;
  for (let i = 0; i < RUNS; i++) { const r = await one(`${p.name}${i}`); times.push(r.ms); sec = r.sec; }
  // Two renders at the profile's render budget (one after the other on SMALL, side by side on LARGE ≥ 4 GB).
  const t0 = Date.now();
  if (p.renderConcurrency >= 2) await Promise.all([one(`${p.name}p0`), one(`${p.name}p1`)]);
  else { await one(`${p.name}p0`); await one(`${p.name}p1`); }
  const pair = Date.now() - t0;
  out.push(`${name}: enc ${p.name === 'small' ? 2 : p.encodeThreads} thr, sliced=${p.x264Sliced}, renders×${p.renderConcurrency} | single render ${times.map(t => (t / 1000).toFixed(1)).join(' / ')} s for ${sec.toFixed(1)} s of edit | two renders ${(pair / 1000).toFixed(1)} s`);
}
fs.rmSync(dir, { recursive: true, force: true });
console.log(out.join('\n'));
