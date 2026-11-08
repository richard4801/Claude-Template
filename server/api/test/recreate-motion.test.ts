// workstream 1 · the owner's slideshow bug (prod, 2026-11-08): a 29.7 s, 7-shot, 182 BPM TikTok recreated with the
// studio's own video takes came out as one still frame per shot sliding to the beat. End to end on real, MOVING takes:
// analyse → match → apply → the server's own render; every slot of the render must move (its frames change), never a still.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { takes, uploads, users } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { probe } from '../src/replicate/media.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

const W = 270, H = 480, FPS = 30;
/** 7 shots, 29.7 s (182 BPM): a long near-still wide first shot, then fast stylised shots. */
const SHOTS: { src: string; sec: number; still?: boolean }[] = [
  { src: 'testsrc2', sec: 10.6, still: true }, { src: 'mandelbrot', sec: 2.6 }, { src: 'life=ratio=0.3:seed=3:mold=8', sec: 3.3 },
  { src: 'cellauto=rule=30', sec: 2.0 }, { src: 'gradients=speed=0.08:seed=5:c0=0xff3355:c1=0x22ccff', sec: 4.6 }, { src: 'testsrc2', sec: 3.3 }, { src: 'life=ratio=0.5:seed=11', sec: 3.3 },
];
/** The studio's video takes: 12 s each, every one moving all the way through. */
const TAKES = [['t_m1', 'life=ratio=0.2:seed=1:mold=4'], ['t_m2', 'cellauto=rule=110'], ['t_m3', 'gradients=speed=0.06:seed=2'], ['t_m4', 'life=ratio=0.4:seed=21'],
  ['t_m5', 'cellauto=rule=90:random_fill_ratio=0.5'], ['t_m6', 'gradients=speed=0.09:seed=8:c0=0x33ff99:c1=0x9933ff'], ['t_m7', 'life=ratio=0.6:seed=33:mold=2']] as const;

/** A moving lavfi source; `still` holds its first frame with a slow drift (a person standing still). */
function shot(src: string, sec: number, out: string, still = false) {
  const s = `${src}${src.includes('=') ? ':' : '='}s=${W}x${H}:r=${FPS}`;
  ff('-f', 'lavfi', '-i', s, '-vf', still ? `trim=end_frame=1,loop=-1:1:0,setpts=N/${FPS}/TB,scale=${W + 20}:${H + 20},crop=${W}:${H}:x='10+4*sin(t)':y=10,setsar=1` : `scale=${W}:${H},setsar=1`,
    '-t', String(sec), ...ENC, out);
}
/** Mean absolute difference (0–255) between the grey frames at a and b seconds of `file`. */
function diffAt(file: string, a: number, b: number) {
  const grab = (t: number) => execFileSync('ffmpeg', ['-v', 'error', '-ss', t.toFixed(3), '-i', file, '-frames:v', '1', '-vf', 'scale=64:114,format=gray', '-f', 'rawvideo', 'pipe:1']);
  const x = grab(a), y = grab(b);
  let s = 0;
  for (let i = 0; i < Math.min(x.length, y.length); i++) s += Math.abs(x[i]! - y[i]!);
  return s / Math.max(1, Math.min(x.length, y.length));
}

describe.skipIf(!hasFfmpeg)('Recreate · built edits move (no slideshow)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, dir: string, studioId: string, refFile: string;
  beforeAll(async () => {
    a = await makeApp({ RECREATE_POSE: 'false', TESSERACT_PATH: '' });
    ({ owner } = await people(a, 0) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId;
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rx-motion-'));
    const parts = SHOTS.map((s, i) => { const f = path.join(dir, `s${i}.mp4`); shot(s.src, s.sec, f, s.still); return f; });
    refFile = path.join(dir, 'ref.mp4');
    const dur = SHOTS.reduce((x, s) => x + s.sec, 0);
    ff(...parts.flatMap(f => ['-i', f]), '-f', 'lavfi', '-i', `aevalsrc='0.8*sin(2*PI*90*t)*exp(-40*mod(t,60/182))':s=44100:d=${dur}`,
      // A two-frame white flash on the cut into shot 3 (13.2 s): the built edit gets a transition after earlier cuts.
      '-filter_complex', `${parts.map((_, i) => `[${i}:v]`).join('')}concat=n=${parts.length}:v=1:a=0,drawbox=c=white:t=fill:enable='between(n,396,397)'[v]`, '-map', '[v]', '-map', `${parts.length}:a`, '-c:a', 'aac', '-shortest', ...ENC, refFile);
    await putObject(a.ctx, { key: 'u/motion/ref.mp4', body: fs.readFileSync(refFile), studioId, kind: 'clip', contentType: 'video/mp4' });
    for (const [id, src] of TAKES) {
      const f = path.join(dir, `${id}.mp4`);
      shot(src, 12, f);
      const info = await probe('ffprobe', f);
      await putObject(a.ctx, { key: `c/${id}.mp4`, body: fs.readFileSync(f), studioId, kind: 'clip', contentType: 'video/mp4' });
      await a.ctx.db.insert(takes).values({ id, studioId, userId: owner.id, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: id, label: 'HD', engineLabel: '', cost: 0, seed: 0,
        status: 'final', thumb: null, prompt: '', mediaKey: `c/${id}.mp4`, media: { durationSec: info.duration, width: info.width, height: info.height, fps: FPS }, createdAt: Date.now() });
    }
    // A photo of the studio (kind "shot"): never a candidate for a video slot.
    await a.ctx.db.insert(takes).values({ id: 's_photo', studioId, userId: owner.id, kind: 'shot', jobId: null, modelId: null, index: 1, of: 1, title: 'photo', label: '', engineLabel: '', cost: 0, seed: 0,
      status: 'final', thumb: null, prompt: '', mediaKey: 'u/motion/photo.jpg', media: { width: 1080, height: 1920 }, createdAt: Date.now() });
  }, 300_000);
  afterAll(async () => { await a?.close(); if (dir) fs.rmSync(dir, { recursive: true, force: true }); });

  it('analyse → match → apply → render: every clip is a video take, and every slot of the render moves', async () => {
    const [up] = await a.ctx.db.select().from(uploads).where(eq(uploads.storageKey, 'u/motion/ref.mp4'));
    const created = (await owner.req('POST', '/v1/recreate/references', { uploadId: up!.id, name: 'Fast stylised' })).body;
    const ref = await until(async () => { const r = (await owner.req('GET', `/v1/recreate/references/${created.id}`)).body; return r.state === 'ready' || r.state === 'failed' ? r : null; }, 180_000);
    expect(ref.state, ref.error).toBe('ready');
    const slots = ref.recipe.slots as { id: string; startSec: number; endSec: number; speed: { ramp: string } }[];
    console.info('slots', slots.map(s => `${s.startSec.toFixed(2)}–${s.endSec.toFixed(2)} ${s.speed.ramp}`).join(' | '));
    expect(slots).toHaveLength(SHOTS.length); // the flash didn't merge or split shots
    expect((ref.recipe.transitions as { kind: string; atSec: number }[]).some(t => t.kind === 'flash' && Math.abs(t.atSec - 13.2) < 0.1)).toBe(true);

    const m = (await owner.req('POST', `/v1/recreate/references/${ref.id}/match`, {})).body;
    expect(Object.values(m.assignment ?? {})).not.toContain('s_photo');
    for (const s of m.slots) for (const c of s.candidates ?? []) expect(c.takeId).not.toBe('s_photo');
    const session = (await owner.req('POST', '/v1/edit-sessions', { takeId: 't_m1' })).body;
    const applied = await owner.req('POST', `/v1/recreate/references/${ref.id}/apply`, { sessionId: session.id, baseRevision: session.revision, slots: m.assignment });
    expect(applied.status, JSON.stringify(applied.body)).toBe(200);
    const p = (await owner.req('GET', `/v1/edit-sessions/${session.id}`)).body.project as M.EditProject;
    const clips = M.mainTrack(p).items as M.VideoClip[];
    expect(clips).toHaveLength(slots.length);
    for (const c of clips) {
      const asset = p.assets.find(x => x.id === c.asset)!;
      expect(asset.kind, JSON.stringify(asset)).toBe('video');
      expect(asset.take).toMatch(/^t_m/);
      // The clip plays real source time: at least a third of a second of the take for each second on screen.
      const shown = M.clipLength(c), used = c.outSec - c.inSec;
      expect(used / shown, JSON.stringify(c)).toBeGreaterThan(0.3);
    }

    // The server's own render of the built edit (what Compare and the export show).
    await owner.req('POST', `/v1/edit-sessions/${session.id}/preview`, {});
    const ready = await until(async () => { const r = (await owner.req('GET', `/v1/edit-sessions/${session.id}/preview`)).body; return r.state === 'ready' || r.state === 'failed' ? r : null; }, 240_000);
    // It used to fail here whenever a transition came after the second shot (xfade after concat: timebases differed).
    expect(clips.slice(2).some(c => c.transitionIn)).toBe(true);
    expect(ready.state, JSON.stringify(ready)).toBe('ready');
    const u = new URL(ready.url, 'http://x');
    const got = await a.app.inject({ method: 'GET', url: u.pathname + u.search, headers: { authorization: `Bearer ${owner.token}` } });
    const file = path.join(dir, 'preview.mp4');
    fs.writeFileSync(file, got.rawPayload);
    for (const s of slots) {
      const a0 = s.startSec + 0.15, b0 = Math.min(s.endSec - 0.15, a0 + 1.0);
      const d = diffAt(file, a0, b0);
      expect(d, `${s.id} ${s.startSec}–${s.endSec}: the picture must change inside the slot`).toBeGreaterThan(2);
    }
  }, 600_000);
});
