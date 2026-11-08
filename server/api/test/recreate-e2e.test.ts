// Recreate this edit, end to end on real video (workstream 1). Everything is made locally with ffmpeg; nothing is paid.
// The steps:
// - a reference with hard cuts at known times, and four real takes of different content (the studio's own clips);
// - over HTTP: upload → analyse → match → apply into an edit session;
// - the assembled project is rendered with ffmpeg here (main track: trims, speed, cuts), and the render is analysed again.
// Its cuts must land on the reference's, and its length must match: the timing survives the whole trip.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { takes, uploads, users } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { LOOK_IDS } from '../src/editor/lookpack.js';
import { paletteIds } from '../src/editor/photo.js';
import { FILTERS } from '../src/editor/presets.js';
import { analyzeReference } from '../src/recreate/analyze.js';
import { probe } from '../src/replicate/media.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { ENC, ff, hasFfmpeg } from './recreate-fixture.js';

const W = 180, H = 320, FPS = 30;
/** Four shots of clearly different pictures, cut at 0.8, 1.9 and 3.1 s (4.0 s in all). */
const SHOTS = [
  { src: 'testsrc2', sec: 0.8 }, { src: 'mandelbrot', sec: 1.1 }, { src: 'smptehdbars', sec: 1.2 }, { src: 'rgbtestsrc', sec: 0.9 },
];
const CUTS = [0.8, 1.9, 3.1];
/** The studio's takes: 3 s each, other pictures again (so each cut in the render is a real change of picture). */
const TAKES = [['t_a', 'cellauto=rule=110'], ['t_b', 'life=ratio=0.3:seed=7'], ['t_c', 'gradients=speed=0.02:seed=3:c0=0xff3355:c1=0x22ccff'], ['t_d', 'yuvtestsrc']] as const;

/** A still frame of a lavfi source, held for `sec` (deterministic, like the other recreate fixtures). */
const still = (src: string, sec: number, out: string) =>
  ff('-f', 'lavfi', '-i', `${src}${src.includes('=') ? ':' : '='}s=${W}x${H}:r=${FPS}`, '-vf', `trim=end_frame=1,loop=-1:1:0,setpts=N/${FPS}/TB,scale=${W}:${H},setsar=1`, '-t', String(sec), ...ENC, out);

/**
 * The main track of an edit project, rendered: each clip's take trimmed to [inSec, outSec], played at its speed, scaled
 * to the canvas, joined with cuts (this test's reference has no transitions or ramps).
 */
function renderMain(p: M.EditProject, files: Record<string, string>, out: string) {
  const clips = M.mainTrack(p).items as M.VideoClip[];
  const args: string[] = [], chains: string[] = [];
  clips.forEach((c, i) => {
    const take = p.assets.find(a => a.id === c.asset)!.take!;
    expect(c.speedCurve).toBeUndefined();
    expect(c.transitionIn).toBeUndefined();
    args.push('-i', files[take]!);
    chains.push(`[${i}:v]trim=start=${c.inSec}:end=${c.outSec},setpts=(PTS-STARTPTS)/${c.speed},fps=${FPS},scale=${W}:${H},setsar=1[v${i}]`);
  });
  const filter = `${chains.join(';')};${clips.map((_, i) => `[v${i}]`).join('')}concat=n=${clips.length}:v=1:a=0[v]`;
  ff(...args, '-filter_complex', filter, '-map', '[v]', ...ENC, out);
}

describe.skipIf(!hasFfmpeg)('Recreate · end to end on real video (local files, no spend)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, dir: string, studioId: string;
  const files: Record<string, string> = {};
  let refFile: string;
  beforeAll(async () => {
    a = await makeApp({ RECREATE_POSE: 'false', TESSERACT_PATH: '' });
    ({ owner } = await people(a, 1) as any);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId;
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-recreate-e2e-'));
    // The reference: four stills cut together, with a click track for the beat.
    const parts = SHOTS.map((s, i) => { const f = path.join(dir, `shot${i}.mp4`); still(s.src, s.sec, f); return f; });
    refFile = path.join(dir, 'ref.mp4');
    ff(...parts.flatMap(f => ['-i', f]), '-f', 'lavfi', '-i', "aevalsrc='0.8*sin(2*PI*880*t)*exp(-60*mod(t,0.5))':s=44100:d=4",
      '-filter_complex', `${parts.map((_, i) => `[${i}:v]`).join('')}concat=n=${parts.length}:v=1:a=0[v]`, '-map', '[v]', '-map', `${parts.length}:a`, '-c:a', 'aac', '-shortest', ...ENC, refFile);
    await putObject(a.ctx, { key: 'u/e2e/ref.mp4', body: fs.readFileSync(refFile), studioId, kind: 'clip', contentType: 'video/mp4' });
    // The takes, stored like any finished take, with their real media facts.
    for (const [id, src] of TAKES) {
      const f = path.join(dir, `${id}.mp4`);
      still(src, 3, f);
      files[id] = f;
      const info = await probe('ffprobe', f);
      await putObject(a.ctx, { key: `c/${id}.mp4`, body: fs.readFileSync(f), studioId, kind: 'clip', contentType: 'video/mp4' });
      await a.ctx.db.insert(takes).values({ id, studioId, userId: owner.id, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: id, label: 'HD', engineLabel: '', cost: 0, seed: 0,
        status: 'final', thumb: null, prompt: '', mediaKey: `c/${id}.mp4`, media: { durationSec: info.duration, width: info.width, height: info.height, fps: FPS }, createdAt: Date.now() });
    }
  }, 120_000);
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  it('analyse → match → apply → render: the render cuts where the reference cuts, and is as long', async () => {
    // 1. Analyse (as the app does: an upload, then the background analysis).
    const [up] = await a.ctx.db.select().from(uploads).where(eq(uploads.storageKey, 'u/e2e/ref.mp4'));
    const created = (await owner.req('POST', '/v1/recreate/references', { uploadId: up!.id, name: 'Four cuts' })).body;
    const ref = await until(async () => { const r = (await owner.req('GET', `/v1/recreate/references/${created.id}`)).body; return r.state === 'ready' || r.state === 'failed' ? r : null; }, 90_000);
    expect(ref.state, ref.error).toBe('ready');
    const slots = ref.recipe.slots as { id: string; startSec: number; endSec: number; camera: { motion: string } }[];
    expect(slots).toHaveLength(4);
    slots.slice(1).forEach((s, i) => expect(Math.abs(s.startSec - CUTS[i]!)).toBeLessThanOrEqual(1 / FPS + 0.001));
    expect(ref.recipe.transitions.map((t: { kind: string }) => t.kind)).toEqual(['cut', 'cut', 'cut']);
    expect(slots.map(s => s.camera.motion)).toEqual(['static', 'static', 'static', 'static']);

    // 2. Match: each slot gets one of the takes (all long enough, the right shape, still like the slots).
    const m = (await owner.req('POST', `/v1/recreate/references/${ref.id}/match`, {})).body;
    expect(m.assignment, JSON.stringify(m)).toBeTruthy();
    expect(Object.keys(m.assignment).sort()).toEqual(['s1', 's2', 's3', 's4']);
    expect(new Set(Object.values(m.assignment)).size).toBe(4); // each take once
    const fill = (await owner.req('GET', `/v1/recreate/references/${ref.id}/fill`)).body;
    expect(fill.slots.map((s: { state: string }) => s.state)).toEqual(['matched', 'matched', 'matched', 'matched']);

    // 3. Apply into an edit session, as the app does.
    const session = (await owner.req('POST', '/v1/edit-sessions', { takeId: 't_a' })).body;
    const applied = await owner.req('POST', `/v1/recreate/references/${ref.id}/apply`, { sessionId: session.id, baseRevision: session.revision, slots: m.assignment });
    expect(applied.status, JSON.stringify(applied.body)).toBe(200);
    expect(applied.body.missing).toEqual([]);
    expect(applied.body.match.cuts).toBeGreaterThan(0.95);
    const p = (await owner.req('GET', `/v1/edit-sessions/${session.id}`)).body.project as M.EditProject;
    M.validate(p, FILTERS, LOOK_IDS, paletteIds()); // what the server checks on commit
    const tl = M.timeline(p);
    expect(tl).toHaveLength(4);
    tl.slice(1).forEach((c, i) => expect(Math.abs(c.startSec - slots[i + 1]!.startSec)).toBeLessThan(0.002));
    // Each clip plays its assigned take.
    (M.mainTrack(p).items as M.VideoClip[]).forEach((c, i) => expect(p.assets.find(x => x.id === c.asset)!.take).toBe(m.assignment[`s${i + 1}`]));

    // 4. Render the edit and analyse the render: the same cuts (within a frame) and the same length.
    const out = path.join(dir, 'render.mp4');
    renderMain(p, files, out);
    const rinfo = await probe('ffprobe', out);
    expect(Math.abs(rinfo.duration - ref.recipe.source.durationSec)).toBeLessThanOrEqual(2 / FPS + 0.001);
    const { recipe: again } = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, out);
    expect(again.slots).toHaveLength(4);
    again.slots.slice(1).forEach((s, i) => expect(Math.abs(s.startSec - slots[i + 1]!.startSec), `cut ${i + 1}`).toBeLessThanOrEqual(1 / FPS + 0.001));
  }, 180_000);

  it('the reference file is untouched and private; only the API serves it', async () => {
    const list = (await owner.req('GET', '/v1/recreate/references')).body;
    expect(list).toHaveLength(1);
    const v = await a.app.inject({ method: 'GET', url: `/v1/recreate/references/${list[0].id}/video`, headers: { authorization: `Bearer ${owner.token}` } });
    expect(v.statusCode).toBe(200);
    expect(v.rawPayload.equals(fs.readFileSync(refFile))).toBe(true);
    execFileSync('ffprobe', ['-v', 'error', refFile]); // still a valid file
  });
});
