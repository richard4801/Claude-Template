// Recreate this edit, phase 2 (workstream 1, plans/recreate-edit.md): a reference becomes a recipe. A synthetic
// reference made with ffmpeg: a pan, a hard cut, a slow zoom in, a crossfade, a still shot with a caption and a flash
// frame, over a click track. Then the references API: private per member, ≤ 60 s, kept or expired after 30 days.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { recreateReferences, uploads } from '../src/db/schema.js';
import { analyzeReference, aspectName, moveFor, RECIPE_SCHEMA } from '../src/recreate/analyze.js';
import { paletteDistance, swatchesOf } from '../src/recreate/frames.js';
import { recreateOf } from '../src/recreate/references.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const FONT = ['/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'].find(f => fs.existsSync(f));
const ENC = ['-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-r', '30', '-threads', '1'];
const ff = (...args: string[]) => execFileSync('ffmpeg', ['-y', '-v', 'error', ...args]);

/** The synthetic reference (4.4 s): pan 0–1.5 · cut · zoom in 1.5–2.4 · crossfade 2.4–2.9 · still with a caption 3.1–4.1 and a flash at 3.73. */
function makeReference(dir: string) {
  const a = path.join(dir, 'a.mp4'), b = path.join(dir, 'b.mp4'), c = path.join(dir, 'c.mp4'), out = path.join(dir, 'ref.mp4');
  ff('-f', 'lavfi', '-i', 'testsrc2=s=960x640:r=30', '-vf', "trim=end_frame=1,loop=-1:1:0,setpts=N/30/TB,crop=360:640:x='100+t*120':y=0,scale=180:320", '-t', '1.5', ...ENC, a);
  ff('-f', 'lavfi', '-i', 'mandelbrot=s=720x1280:r=30', '-vf', "trim=end_frame=1,loop=-1:1:0,setpts=N/30/TB,zoompan=z='1+0.006*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=180x320:fps=30", '-t', '1.5', ...ENC, b);
  const text = FONT ? `drawtext=fontfile=${FONT}:text='SUMMER':fontsize=28:fontcolor=white:borderw=2:bordercolor=black:x=(w-tw)/2:y=h*0.7:enable='between(t,0.7,1.7)',` : '';
  ff('-f', 'lavfi', '-i', 'gradients=s=180x320:r=30:d=2:speed=0.01:nb_colors=2:c0=0xFFD27A:c1=0x7AC8FF:seed=1', '-vf', `${text}drawbox=c=white:t=fill:enable='eq(n,40)'`, '-t', '2', ...ENC, c);
  ff('-i', a, '-i', b, '-i', c, '-f', 'lavfi', '-i', "aevalsrc='0.8*sin(2*PI*880*t)*exp(-60*mod(t,0.5))':s=44100:d=4.4",
    '-filter_complex', '[0]fps=30,settb=1/30[a];[1]fps=30,settb=1/30[b];[2]fps=30,settb=1/30[c];[a][b]concat=n=2:v=1,fps=30,settb=1/30[ab];[ab][c]xfade=transition=fade:duration=0.5:offset=2.4[v]',
    '-map', '[v]', '-map', '3:a', '-c:a', 'aac', '-shortest', ...ENC, out);
  return out;
}

describe('Recipe helpers (unit)', () => {
  it('names the shape, maps camera motion to a Suite move, compares palettes', () => {
    expect([aspectName(1080, 1920), aspectName(1920, 1080), aspectName(1080, 1350)]).toEqual(['9:16', '16:9', '4:5']);
    const cam = (motion: any, x = 0, y = 0, scale = 1) => ({ motion, shake: 0, keys: [{ t: 0, x: 0, y: 0, scale: 1 }, { t: 1, x, y, scale }], confidence: 0.6 });
    expect(moveFor(cam('pan', -0.4))).toEqual([{ id: 'pan_right' }]);
    expect(moveFor(cam('pan', 0.4))).toEqual([{ id: 'pan_left' }]);
    expect(moveFor(cam('tilt', 0, -0.3))).toEqual([{ id: 'tilt_down' }]);
    expect(moveFor(cam('zoom_in', 0, 0, 1.3))).toEqual([{ id: 'zoom_in' }]);
    expect(moveFor(cam('shake'))).toEqual([{ id: 'handheld' }]);
    expect(moveFor(cam('mixed'))).toEqual([]);
    expect(paletteDistance(['#000000', '#FFFFFF'], ['#000000', '#FFFFFF'])).toBe(0);
    expect(paletteDistance(['#000000'], ['#FFFFFF'])).toBe(1);
    const red = { t: 0, width: 2, height: 1, rgb: new Uint8Array([255, 0, 0, 250, 5, 5]) };
    expect(swatchesOf([red], 2)).toHaveLength(2);
  });
});

describe.skipIf(!hasFfmpeg)('Recreate this edit · the analysis (synthetic reference)', () => {
  let dir: string, ref: string;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-recreate-')); ref = makeReference(dir); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('slots, camera moves, transitions, text, grade, sound and the contact sheet', async () => {
    const { recipe: r, contactSheetPng } = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe' }, ref);
    expect(r.schema).toBe(RECIPE_SCHEMA);
    expect(r.source).toMatchObject({ width: 180, height: 320, fps: 30, aspect: '9:16', hasAudio: true });
    expect(r.source.durationSec).toBeCloseTo(4.4, 1);

    // Three shots: the cut at 1.5 s (frame-accurate) and the crossfade's middle (2.65 s).
    expect(r.slots.map(s => s.id)).toEqual(['s1', 's2', 's3']);
    expect(r.slots[0]!.startSec).toBe(0);
    expect(Math.abs(r.slots[1]!.startSec - 1.5)).toBeLessThanOrEqual(1 / 30 + 0.001);
    expect(Math.abs(r.slots[2]!.startSec - 2.65)).toBeLessThanOrEqual(0.1);
    expect(r.slots.at(-1)!.endSec).toBeCloseTo(4.4, 1);
    expect(r.slots.map(s => s.camera.motion)).toEqual(['pan', 'zoom_in', 'static']);
    expect(r.slots.map(s => s.rig?.moves?.[0]?.id)).toEqual(['pan_right', 'zoom_in', 'static']);
    expect(r.slots[0]!.camera.keys.at(-1)!.x).toBeLessThan(-0.3); // the content slides left: the camera pans right
    expect(r.slots[1]!.camera.keys.at(-1)!.scale).toBeGreaterThan(1.05);
    for (const s of r.slots) {
      expect(s.keyframeSec).toBeGreaterThan(s.startSec);
      expect(s.keyframeSec).toBeLessThan(s.endSec);
      expect(s.pose).toEqual({ status: 'pending' });
      expect(s.brief).toBeNull();
      expect(s.speed.curve.length).toBeGreaterThan(0);
    }

    expect(r.transitions.map(t => [t.kind, t.from, t.to])).toEqual([['cut', 's1', 's2'], ['crossfade', 's2', 's3'], ['flash', 's3', 's3']]);
    expect(r.transitions[1]!.durationSec).toBeCloseTo(0.5, 1);
    expect(Math.abs(r.transitions[2]!.atSec - 3.733)).toBeLessThanOrEqual(0.07);

    if (FONT) {
      expect(r.text).toHaveLength(1);
      expect(r.text[0]).toMatchObject({ words: null, color: '#FFFFFF' });
      expect(Math.abs(r.text[0]!.startSec - 3.1)).toBeLessThanOrEqual(0.2);
      expect(Math.abs(r.text[0]!.endSec - 4.1)).toBeLessThanOrEqual(0.2);
      expect(r.text[0]!.box.y).toBeGreaterThan(0.6);
      expect(r.text[0]!.box.y).toBeLessThan(0.8);
    }

    expect(r.grade.swatches).toHaveLength(5);
    expect(r.grade.look?.kind).toBe('palette');
    expect(r.grade.grade).toBeTruthy();
    expect(r.sound!.beats.length).toBeGreaterThanOrEqual(4);
    expect(r.sound!.bpm).toBeGreaterThan(0);
    expect(r.pacing).toMatchObject({ shots: 3 });
    expect(r.pacing.energy.values.length).toBeGreaterThan(10);
    expect(r.gaps.map(g => g.what)).toContain('pose');

    const meta = await sharp(contactSheetPng!).metadata();
    expect(meta.width).toBe(600); // 3 keyframes, 200 px each
  }, 60_000);
});

describe.skipIf(!hasFfmpeg)('Recreate this edit · references API', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client, dir: string, refBytes: Buffer, studioId: string;
  beforeAll(async () => {
    a = await makeApp({});
    ({ owner, members: [member, other] } = await people(a, 2) as any);
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-recreate-api-'));
    refBytes = fs.readFileSync(makeReference(dir));
    const long = path.join(dir, 'long.mp4');
    ff('-f', 'lavfi', '-i', 'color=c=gray:s=64x112:r=10:d=62', ...ENC, long);
    const [o] = await a.ctx.db.execute((await import('drizzle-orm')).sql`select studio_id from users where id = ${owner.id}`).then((r: any) => r.rows ?? r);
    studioId = o.studio_id;
    for (const [key, body, type] of [['u/rx/ref.mp4', refBytes, 'video/mp4'], ['u/rx/ref2.mp4', refBytes, 'video/mp4'], ['u/rx/long.mp4', fs.readFileSync(long), 'video/mp4'], ['u/rx/still.png', Buffer.from('png'), 'image/png']] as const)
      await putObject(a.ctx, { key, body: body as Buffer, studioId, kind: 'clip', contentType: type });
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const uploadOf = async (key: string) => (await a.ctx.db.select().from(uploads).where(eq(uploads.storageKey, key)))[0]!.id;
  const ready = (c: Client, id: string) => until(async () => { const r = (await c.req('GET', `/v1/recreate/references/${id}`)).body; return r.state === 'ready' || r.state === 'failed' ? r : null; }, 60_000);

  it('a video upload becomes a recipe; private to its member (the owner sees all); the contact sheet only through the API', async () => {
    const r = await member.req('POST', '/v1/recreate/references', { uploadId: await uploadOf('u/rx/ref.mp4'), name: 'Tuff edit' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ name: 'Tuff edit', state: 'analyzing', keep: false });
    expect(r.body.expiresAt - r.body.createdAt).toBe(30 * 86_400_000);
    const done = await ready(member, r.body.id);
    expect(done.state).toBe('ready');
    expect(done.recipe).toMatchObject({ schema: 'muse.recipe/1', id: r.body.id, referenceId: r.body.id, pacing: { shots: 3 } });
    expect(done.recipe.contactSheet.url).toMatch(new RegExp(`/v1/recreate/references/${r.body.id}/contact-sheet$`));
    expect(done.recipe.contactSheet.times).toHaveLength(3);

    const sheet = await member.req('GET', `/v1/recreate/references/${r.body.id}/contact-sheet`);
    expect(sheet.status).toBe(200);
    expect((await owner.req('GET', `/v1/recreate/references/${r.body.id}/contact-sheet`)).status).toBe(200);
    expect((await other.req('GET', `/v1/recreate/references/${r.body.id}/contact-sheet`)).status).toBe(404);
    expect((await other.req('GET', `/v1/recreate/references/${r.body.id}`)).status).toBe(404);
    const [row] = await a.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, r.body.id));
    expect((await a.app.inject({ method: 'GET', url: `/uploads/${row!.contactSheetKey}` })).statusCode).toBe(404); // not public by key

    expect((await member.req('GET', '/v1/recreate/references')).body.map((x: any) => x.id)).toEqual([r.body.id]);
    expect((await other.req('GET', '/v1/recreate/references')).body).toEqual([]);
    expect((await owner.req('GET', '/v1/recreate/references')).body[0]).toMatchObject({ id: r.body.id, slots: 3 });
  }, 90_000);

  it('refuses a clip over 60 s, a still, a missing upload and unknown fields', async () => {
    const long = await member.req('POST', '/v1/recreate/references', { uploadId: await uploadOf('u/rx/long.mp4') });
    expect(long.status).toBe(400);
    expect(long.body.error).toMatch(/up to 60 s for now \(this one is 62 s\)/);
    expect((await member.req('POST', '/v1/recreate/references', { uploadId: await uploadOf('u/rx/still.png') })).body.error).toMatch(/must be a video/);
    expect((await member.req('POST', '/v1/recreate/references', { uploadId: 'up_nope' })).status).toBe(404);
    expect((await member.req('POST', '/v1/recreate/references', { uploadId: 'x', url: 'https://tiktok.com/x' })).status).toBe(400);
  });

  it('kept references stay; the rest lose their video and contact sheet after 30 days (the recipe stays); delete removes everything', async () => {
    const kept = (await owner.req('POST', '/v1/recreate/references', { uploadId: await uploadOf('u/rx/ref2.mp4') })).body;
    await ready(owner, kept.id);
    const k = await owner.req('PATCH', `/v1/recreate/references/${kept.id}`, { keep: true, name: 'Keeper' });
    expect(k.body).toMatchObject({ keep: true, name: 'Keeper', expiresAt: null });
    const first = (await member.req('GET', '/v1/recreate/references')).body[0];
    // 31 days later.
    const swept = await recreateOf(a.ctx).sweep(Date.now() + 31 * 86_400_000, true);
    expect(swept).toBe(1);
    const gone = (await member.req('GET', `/v1/recreate/references/${first.id}`));
    expect(gone.status).toBe(404); // expired references leave the lists
    const [row] = await a.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, first.id));
    expect(row).toMatchObject({ state: 'expired', storageKey: null, contactSheetKey: null });
    expect(row!.recipe?.slots).toHaveLength(3);
    expect(await a.ctx.storage.head('u/rx/ref.mp4')).toBeFalsy();
    expect((await owner.req('GET', `/v1/recreate/references/${kept.id}`)).body.state).toBe('ready');
    expect(await a.ctx.storage.head('u/rx/ref2.mp4')).toBeTruthy();

    expect((await owner.req('DELETE', `/v1/recreate/references/${kept.id}`)).status).toBe(204);
    expect(await a.ctx.storage.head('u/rx/ref2.mp4')).toBeFalsy();
    expect((await owner.req('GET', `/v1/recreate/references/${kept.id}`)).status).toBe(404);
  }, 90_000);
});
