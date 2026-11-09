// Own fonts (Edit suite text): the .ttf/.otf check and name, uploads, the contract's font asset and fontAsset, kits
// dropping it, and the render drawing with the file.
import fs from 'node:fs';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { takes } from '../src/db/schema.js';
import { FontError, fontName } from '../src/editor/font.js';
import { kitOf } from '../src/editor/kit.js';
import * as M from '../src/editor/model.js';
import { FONT_DIR, planRender } from '../src/editor/render.js';
import { makeApp, people, type Client } from './helpers.js';

const figtree = fs.readFileSync(path.join(FONT_DIR, 'figtree_700.ttf'));

function project(): M.EditProject {
  const p = M.fromV1({ version: 1, sourceTakeId: 'take_f', sourceDurationSec: 6, segments: [{ inSec: 0, outSec: 6, speed: 1 }], mute: false }, { width: 1080, height: 1920, fps: 30 });
  p.assets.push({ id: 'fnt', kind: 'font', upload: 'up_font', name: 'Figtree Bold' });
  p.tracks.push({ id: 'txt', kind: 'text', items: [{ id: 't1', startSec: 0, durationSec: 2, text: 'Hello', style: { font: 'sans', weight: 700, sizePct: 0.05, color: '#FFFFFF', align: 'center', fontAsset: 'fnt' } }] });
  return p;
}
const problem = (p: M.EditProject) => { try { M.validate(p, []); return null; } catch (e) { return (e as M.EditProblem).field; } };

describe('own fonts: the file and the contract', () => {
  it('names a TrueType font; refuses anything else', () => {
    expect(fontName(figtree)).toBe('Figtree Bold');
    expect(() => fontName(Buffer.from('wOFF0000000000000000'))).toThrow(FontError);
    expect(() => fontName(Buffer.from('hello'))).toThrow(FontError);
    // A header with no name table still passes, named "Font".
    const bare = Buffer.alloc(12); bare.writeUInt32BE(0x00010000, 0);
    expect(fontName(bare)).toBe('Font');
  });

  it('a text item draws with a font asset; captions, other assets and stray fields are refused', () => {
    expect(problem(project())).toBeNull();
    const img = project(); img.assets.push({ id: 'pic', kind: 'image', upload: 'up_pic' }); (img.tracks[1]!.items[0] as M.TextItem).style.fontAsset = 'pic';
    expect(problem(img)).toBe('edits.tracks.1.items.0.style.fontAsset');
    const missing = project(); (missing.tracks[1]!.items[0] as M.TextItem).style.fontAsset = 'nope';
    expect(problem(missing)).toBe('edits.tracks.1.items.0.style.fontAsset');
    const take = project(); take.assets[1] = { id: 'fnt', kind: 'font', take: 'take_f' };
    expect(problem(take)).toBe('edits.assets.1');
    const sized = project(); sized.assets[1]!.width = 100;
    expect(problem(sized)).toBe('edits.assets.1.width');
    const named = project(); named.assets[1]!.name = '';
    expect(problem(named)).toBe('edits.assets.1.name');
  });

  it('a kit keeps the fallback family, not the asset', () => {
    const k = kitOf(project());
    expect(k.textStyle).toMatchObject({ font: 'sans', weight: 700 });
    expect(k.textStyle!.fontAsset).toBeUndefined();
  });

  it('the render draws with the downloaded file, else the fallback (and says so)', () => {
    const p = project();
    const local = planRender(p, { src: '/tmp/src.mp4', fnt: '/tmp/fonts/mine.ttf' }, { src: { width: 1080, height: 1920, hasAudio: false } }, '/tmp/out.mp4');
    expect(local.args.join(' ')).toContain("fontfile='/tmp/fonts/mine.ttf'");
    expect(local.unsupported).not.toContain('own fonts');
    const none = planRender(p, { src: '/tmp/src.mp4' }, { src: { width: 1080, height: 1920, hasAudio: false } }, '/tmp/out.mp4');
    expect(none.args.join(' ')).toContain('figtree_700.ttf');
    expect(none.unsupported).toContain('own fonts');
    for (const f of [...local.temp, ...none.temp]) fs.rmSync(f, { force: true });
  });
});

describe('own fonts: uploads', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client;
  beforeAll(async () => { a = await makeApp(); ({ owner } = await people(a, 0) as any); });
  afterAll(async () => { await a.close(); });

  const put = async (body: Buffer, contentType = 'font/ttf') => {
    const p = (await owner.req('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType, bytes: body.length })).body;
    const u = new URL(p.url);
    expect((await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': contentType }, payload: body })).statusCode).toBe(200);
    return p.uploadId as string;
  };

  it('presigns, checks and names a font; refuses other files', async () => {
    const id = await put(figtree);
    expect((await owner.req('POST', '/v1/editor/uploads/font-check', { uploadId: id })).body).toEqual({ uploadId: id, name: 'Figtree Bold' });
    const junk = await put(Buffer.from('not a font at all'), 'application/octet-stream');
    const r = await owner.req('POST', '/v1/editor/uploads/font-check', { uploadId: junk });
    expect(r.status).toBe(400); expect(r.body.error).toMatch(/not a TrueType or OpenType font/);
    expect((await owner.req('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType: 'font/woff2' })).status).toBe(400);
    expect((await owner.req('POST', '/v1/editor/uploads/presign', { purpose: 'font', contentType: 'font/ttf', bytes: 11 * 1024 * 1024 })).status).toBe(400);
    // The real font validates as a project asset; a picture can't stand in as one.
    const studio = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
    await a.ctx.db.insert(takes).values({ id: 'take_f', studioId: studio, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: 'c/take_f.mp4', media: { durationSec: 6 }, createdAt: Date.now() });
    const ok = project(); ok.assets[1]!.upload = id;
    expect((await owner.req('POST', '/v1/editor/validate', { project: ok })).body).toMatchObject({ ok: true });
    const pic = (await owner.req('POST', '/v1/editor/uploads/presign', { contentType: 'image/png', bytes: 10 })).body.uploadId;
    const p = project(); p.assets[1]!.upload = pic;
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body.error).toMatch(/upload is not a font/);
    p.assets[1]!.upload = junk;
    expect((await owner.req('POST', '/v1/editor/validate', { project: p })).body.error).toMatch(/^edits\.assets\.1: not a TrueType or OpenType font/);
  });
});
