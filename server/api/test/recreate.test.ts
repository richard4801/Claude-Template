// Recreate this edit, phase 2 (workstream 1, plans/recreate-edit.md): a reference becomes a recipe. A synthetic
// reference made with ffmpeg: a pan, a hard cut, a slow zoom in, a crossfade, a still shot with a caption and a flash
// frame, over a click track. Then the references API: private per member, ≤ 60 s, kept or expired after 30 days.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { recreateReferences, uploads } from '../src/db/schema.js';
import { analyzeReference, aspectName, MAX_CURVE_POINTS, moveFor, RECIPE_SCHEMA, thin } from '../src/recreate/analyze.js';
import { MAX_TEXT_ITEMS, trackText } from '../src/recreate/text.js';
import { paletteDistance, swatchesOf } from '../src/recreate/frames.js';
import { recreateOf } from '../src/recreate/references.js';
import { putObject } from '../src/storage/objects.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { ENC, FONT, ff, hasFfmpeg, makeReference } from './recreate-fixture.js';

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

describe('Recipe size caps (unit)', () => {
  it('curves and camera keys are thinned (ends kept); at most 100 text items', () => {
    const xs = Array.from({ length: 300 }, (_, i) => i);
    const t = thin(xs, MAX_CURVE_POINTS);
    expect(t.length).toBeLessThanOrEqual(MAX_CURVE_POINTS);
    expect(t[0]).toBe(0);
    expect(t.at(-1)).toBe(299);
    expect(thin([1, 2, 3], 48)).toEqual([1, 2, 3]);
    // 150 captions, one after another, each on screen for 0.5 s.
    const frames = Array.from({ length: 150 * 4 }, (_, f) => ({ t: f / 6, boxes: f % 4 < 3 ? [{ x: 0.1, y: (Math.floor(f / 4) % 2) * 0.4 + 0.1, w: 0.5, h: 0.05, light: true }] : [] }));
    const items = trackText(frames);
    expect(items.length).toBe(MAX_TEXT_ITEMS);
    expect(items[0]).toMatchObject({ id: 'x1', fontId: 'sans', words: null });
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
    expect(r.gaps.map(g => g.key)).toEqual(expect.arrayContaining(['pose', 'text:words']));

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
    const seen: Record<string, any[]> = { owner: [], member: [], other: [] };
    for (const [k, c] of [['owner', owner], ['member', member], ['other', other]] as const)
      a.ctx.hub.subscribe(studioId, (c as any).id, line => { if (line.startsWith('data: ')) { const e = JSON.parse(line.slice(6)); if (e.type === 'recreate') seen[k]!.push(e); } }, k === 'owner' ? 'owner' : 'member');
    const r = await member.req('POST', '/v1/recreate/references', { uploadId: await uploadOf('u/rx/ref.mp4'), name: 'Tuff edit' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ name: 'Tuff edit', state: 'analyzing', keep: false });
    expect(r.body.expiresAt - r.body.createdAt).toBe(30 * 86_400_000);
    const done = await ready(member, r.body.id);
    expect(done.state).toBe('ready');
    expect(done.recipe).toMatchObject({ schema: 'muse.recipe/1', id: r.body.id, referenceId: r.body.id, pacing: { shots: 3 } });
    expect(done.recipe.contactSheet.url).toMatch(new RegExp(`/v1/recreate/references/${r.body.id}/contact-sheet$`));
    expect(done.recipe.contactSheet.times).toHaveLength(3);
    expect(done.recipe.contactSheet.tiles).toHaveLength(3);
    expect(done.recipe.origin).toBe('reference');
    const base = `/v1/recreate/references/${r.body.id}`;
    expect(done).toMatchObject({ videoUrl: `${base}/video`, posterUrl: `${base}/poster` });
    expect(done.recipe.slots.map((x: any) => x.thumbUrl)).toEqual(['s1', 's2', 's3'].map(sl => `${base}/slots/${sl}/thumb`));
    const auth = { authorization: `Bearer ${(member as any).token}` };
    const thumb = await a.app.inject({ method: 'GET', url: `${base}/slots/s2/thumb`, headers: auth });
    expect(thumb.statusCode).toBe(200);
    expect(thumb.headers['content-type']).toBe('image/png');
    expect(await sharp(thumb.rawPayload).metadata()).toMatchObject({ width: 200, height: done.recipe.contactSheet.tiles[1].h });
    expect((await a.app.inject({ method: 'GET', url: `${base}/poster`, headers: auth })).statusCode).toBe(200);
    expect((await member.req('GET', `${base}/slots/s9/thumb`)).status).toBe(404);
    const video = await a.app.inject({ method: 'GET', url: `${base}/video`, headers: auth });
    expect(video.statusCode).toBe(200);
    expect(video.rawPayload.equals(refBytes)).toBe(true);
    expect((await other.req('GET', `${base}/video`)).status).toBe(404);
    expect((await member.req('GET', `${base}/fill`)).body).toEqual({ referenceId: r.body.id, slots: ['s1', 's2', 's3'].map(slotId => ({ slotId, state: 'empty' })) });
    // Live: the member and the owner hear about it (analyzing → ready), another member does not; no recipe in the event.
    expect(seen.member!.map(e => e.reference.state)).toEqual(expect.arrayContaining(['analyzing', 'ready']));
    expect(seen.owner!.length).toBe(seen.member!.length);
    expect(seen.other).toEqual([]);
    expect(seen.member!.at(-1).reference).toMatchObject({ id: r.body.id, slots: 3 });
    expect(seen.member!.at(-1).reference.recipe).toBeUndefined();
    // test/fixtures/recipe-v1.json (for the apps' fakes) has every field the API sends.
    const fx = JSON.parse(fs.readFileSync(new URL('./fixtures/recipe-v1.json', import.meta.url), 'utf8'));
    const missing = (live: any, fix: any, at: string): string[] => !live || typeof live !== 'object' || Array.isArray(live) ? [] :
      Object.keys(live).filter(k => live[k] !== undefined).flatMap(k => (k in fix ? missing(live[k], fix[k], `${at}.${k}`) : [`${at}.${k}`]));
    expect([...missing(done, fx, ''), ...missing(done.recipe.slots[0], fx.recipe.slots[0], 'slot'), ...missing(done.recipe.transitions[0], fx.recipe.transitions[0], 'transition'),
      ...(done.recipe.text[0] ? missing(done.recipe.text[0], fx.recipe.text[0], 'text') : [])]).toEqual([]);

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
