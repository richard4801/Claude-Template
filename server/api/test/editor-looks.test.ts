// Editor v2 Looks (plans/video-editor.md "Looks", plans/api.md "Editor v2" → Looks): the baked pack, the endpoints,
// .cube import, and the same look on photos (shoot `filter`, template `afterEffects.look`).
import fs from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { takes } from '../src/db/schema.js';
import * as K from '../src/editor/look.js';
import { LOOKS, LOOK_IDS, grade, packLook } from '../src/editor/lookpack.js';
import { applyLookToImage, packLut } from '../src/editor/photo.js';
import * as M from '../src/editor/model.js';
import { bakeAll, LOOK_DIR } from '../scripts/editor-looks.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type A = Awaited<ReturnType<typeof makeApp>>;

describe('the look pack', () => {
  it('the committed .cube files and looks.json are what scripts/editor-looks.ts bakes', () => {
    const files = bakeAll();
    expect(Object.keys(files)).toHaveLength(LOOKS.length + 1);
    for (const [n, body] of Object.entries(files)) expect(fs.readFileSync(path.join(LOOK_DIR, n), 'utf8'), `${n}: run npx tsx scripts/editor-looks.ts`).toBe(body);
    expect(fs.readdirSync(LOOK_DIR).filter(f => f.endsWith('.cube'))).toHaveLength(LOOKS.length);
  });
  it('~30 looks in every group, unique ids, each parses at 17³ and matches its grade', () => {
    expect(LOOKS.length).toBeGreaterThanOrEqual(30);
    expect(new Set(LOOKS.map(l => l.category))).toEqual(new Set(['natural', 'film', 'moody', 'warm', 'cool', 'bw', 'vintage', 'cinematic']));
    expect(LOOK_IDS.size).toBe(LOOKS.length);
    for (const l of LOOKS) {
      const lut = packLut(`pack:${l.id}`)!;
      expect(lut.size).toBe(17);
      const g = grade(l.grade), c: [number, number, number] = [0.5, 0.375, 0.25];
      const got = K.lutSample(lut, ...c), want = g(...c);
      for (let i = 0; i < 3; i++) expect(Math.abs(got[i]! - want[i]!), l.id).toBeLessThan(0.002); // on a lattice point
    }
  });
  it('looks keep skin natural: a mid skin tone stays in the skin hue range and keeps its brightness order', () => {
    const skins: [number, number, number][] = [[241, 194, 167], [198, 134, 103], [110, 74, 52]].map(c => c.map(v => v / 255) as [number, number, number]);
    for (const l of LOOKS.filter(x => x.category !== 'bw')) {
      const lut = packLut(`pack:${l.id}`)!;
      const out = skins.map(s => K.lutSample(lut, ...s));
      for (const o of out) expect(o[0]!, `${l.id}: red stays the strongest channel on skin`).toBeGreaterThan(o[2]!);
      const L = out.map(o => 0.2126 * o[0]! + 0.7152 * o[1]! + 0.0722 * o[2]!);
      expect(L[0]!, l.id).toBeGreaterThan(L[1]!); expect(L[1]!, l.id).toBeGreaterThan(L[2]!);
    }
  });
  it('photo rendering is the reference renderer', async () => {
    const png = await sharp({ create: { width: 40, height: 30, channels: 3, background: { r: 198, g: 134, b: 103 } } }).png().toBuffer();
    const look = { ...packLook('film-gold')!, grain: undefined };
    const out = await sharp(await applyLookToImage(png, look)).raw().toBuffer();
    const f = new Float32Array(40 * 30 * 3).fill(0).map((_, i) => [198, 134, 103][i % 3]! / 255);
    const ref = K.renderLook({ width: 40, height: 30, data: f }, look, { lut: packLut('pack:film-gold') });
    for (let i = 0; i < out.length; i += 97) expect(Math.abs(out[i]! - Math.round(ref.data[i]! * 255))).toBeLessThanOrEqual(1);
  });
});

describe('looks API, .cube import and photos', () => {
  let a: A, owner: Client;
  beforeAll(async () => { a = await makeApp(); ({ owner } = await people(a, 0) as any); });
  afterAll(async () => { await a.close(); });
  const putCube = async (text: string) => {
    const p = (await owner.req('POST', '/v1/editor/uploads/presign', { purpose: 'lut', contentType: 'text/plain', bytes: text.length })).body;
    const u = new URL(p.url);
    expect((await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': 'text/plain' }, payload: text })).statusCode).toBe(200);
    return p.uploadId as string;
  };

  it('lists the pack and serves its .cube files', async () => {
    const l = (await owner.req('GET', '/v1/editor/looks')).body;
    expect(l.looks).toHaveLength(LOOKS.length);
    expect(l.looks[0]).toMatchObject({ id: 'natural-clean', file: 'natural-clean.cube', look: { lut: 'pack:natural-clean', strength: 1 } });
    const c = await a.app.inject({ method: 'GET', url: '/v1/editor/looks/film-gold.cube', headers: { authorization: `Bearer ${owner.token}` } });
    expect(c.statusCode).toBe(200);
    expect(K.parseCube(c.body).size).toBe(17);
    expect((await owner.req('GET', '/v1/editor/looks/nope.cube')).status).toBe(404);
    expect((await owner.req('GET', '/v1/editor/looks/..%2Fx.cube')).status).toBe(404);
  });

  it('imports a .cube: validated, then usable as a lut asset; a broken one names its line', async () => {
    const good = await putCube(K.writeCube(9, 'mine', (r, g, b) => [r * 0.9, g, b * 1.05]));
    expect((await owner.req('POST', '/v1/editor/luts/validate', { uploadId: good })).body).toEqual({ uploadId: good, size: 9, title: 'mine' });
    const bad = await putCube('LUT_3D_SIZE 2\n0 0 0\n1 x 0\n');
    const r = await owner.req('POST', '/v1/editor/luts/validate', { uploadId: bad });
    expect(r.status).toBe(400);
    expect(r.body.error).toMatch(/line 3/);
    expect((await owner.req('POST', '/v1/editor/uploads/presign', { purpose: 'lut', contentType: 'image/png' })).status).toBe(400);

    const studio = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
    await a.ctx.db.insert(takes).values({ id: 'take_lk', studioId: studio, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: 'c/take_lk.mp4', media: { durationSec: 10 }, createdAt: Date.now() });
    const p = M.fromV1({ version: 1, sourceTakeId: 'take_lk', sourceDurationSec: 10, segments: [{ inSec: 0, outSec: 10, speed: 1 }], mute: false }, { width: 1080, height: 1920, fps: 30 });
    p.assets.push({ id: 'cube', kind: 'lut', upload: good });
    (p.tracks[0]!.items[0] as M.VideoClip).look = { lut: 'cube', strength: 0.7, grain: { amount: 0.2 } };
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body).toMatchObject({ ok: true });
    p.assets[1]!.upload = bad;
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body.error).toMatch(/^edits\.assets\.1: \.cube: line 3/);
    (p.tracks[0]!.items[0] as M.VideoClip).look = { lut: 'pack:nope' };
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body.error).toMatch(/look\.lut: unknown look/);
  });

  it('a shoot with `filter` gets the look on its stills; bad filters are refused', async () => {
    const m = await demoModel(owner);
    const plain = (await owner.req('POST', '/v1/shoots', { modelId: m.id, count: 1 })).body;
    const bw = (await owner.req('POST', '/v1/shoots', { modelId: m.id, count: 1, filter: { lut: 'pack:bw-classic', strength: 1 } })).body;
    expect(bw[0].thumb.url).toMatch(/\/uploads\/g\/fx_/);
    expect(bw[0].thumb.url).not.toBe(plain[0].thumb.url);
    const img = await a.app.inject({ method: 'GET', url: new URL(bw[0].thumb.url, 'http://x').pathname });
    const { data } = await sharp(img.rawPayload).raw().toBuffer({ resolveWithObject: true });
    let maxDiff = 0;
    for (let i = 0; i < data.length; i += 3 * 17) maxDiff = Math.max(maxDiff, Math.abs(data[i]! - data[i + 1]!), Math.abs(data[i + 1]! - data[i + 2]!));
    expect(maxDiff).toBeLessThanOrEqual(6); // black and white (JPEG noise aside)
    expect((await owner.req('POST', '/v1/shoots', { modelId: m.id, count: 1, filter: { lut: 'pack:nope' } })).body.error).toMatch(/^filter\.lut/);
    expect((await owner.req('POST', '/v1/shoots', { modelId: m.id, count: 1, filter: { lut: 'my-own' } })).body.error).toMatch(/^filter\.lut/);
    expect((await owner.req('POST', '/v1/shoots', { modelId: m.id, count: 1, filter: { vignette: { amount: 3 } } })).body.error).toMatch(/^filter\.vignette\.amount/);
  });

  it('templates keep a look in afterEffects and apply it to their stills', async () => {
    const t = (await owner.req('POST', '/v1/templates', { name: 'Gold', layers: { scene: 'a street', afterEffects: { grain: 0.1, look: packLook('film-gold') } } })).body;
    expect(t.layers.afterEffects.look).toMatchObject({ lut: 'pack:film-gold' });
    expect((await owner.req('POST', '/v1/templates', { name: 'Bad', layers: { afterEffects: { look: { lift: 5 } } } })).body.error).toMatch(/afterEffects\.look\.lift/);
    const m = await demoModel(owner);
    const shots = (await owner.req('POST', '/v1/shoots', { modelId: m.id, count: 1, templateId: t.id })).body;
    expect(shots[0].thumb.url).toMatch(/\/uploads\/g\/fx_/);
  });
});
