// The edit content library (src/editor/content.ts): the catalog, its files, storage seeding, and the lookups the
// server render uses.
import fs from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { takes } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { catalog, CONTENT_DIR, contentFile, contentFont, contentItem, seedContent } from '../src/editor/content.js';
import { makeApp, people, type Client } from './helpers.js';

describe('edit content library', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client;
  beforeAll(async () => { a = await makeApp(); ({ owner } = await people(a, 0) as any); });
  afterAll(async () => { await a.close(); });

  it('the catalog lists every pack with a licence; every file it names exists', () => {
    const c = catalog()!;
    expect(c.version).toMatch(/^[0-9a-f]{12}$/);
    const kinds = Object.fromEntries(c.packs.map(p => [p.id, p.kind]));
    expect(kinds).toMatchObject({ twemoji: 'stickers', uisfx: 'sfx', kenney: 'sfx', fonts: 'fonts' });
    for (const p of c.packs) {
      expect(p.licence, p.id).toMatch(/^(CC-BY-4\.0|CC0-1\.0|OFL-1\.1|MUSE)$/);
      for (const it of p.items) for (const f of [it.file, ...Object.values((it.files as Record<string, string>) ?? {})]) if (typeof f === 'string') expect(fs.existsSync(`${CONTENT_DIR}/${f}`), f).toBe(true);
    }
    expect(c.packs.find(p => p.id === 'twemoji')!.items.length).toBeGreaterThan(1800);
  });

  it('serves the catalog to members and files to anyone; nothing outside the content dir', async () => {
    const r = await owner.req('GET', '/v1/editor/content');
    expect(r.status).toBe(200); expect(r.body.version).toBe(catalog()!.version);
    const png = await a.app.inject({ method: 'GET', url: '/v1/editor/content/files/stickers/twemoji/1f600.png' });
    expect(png.statusCode).toBe(200); expect(png.headers['content-type']).toBe('image/png');
    expect(png.rawPayload.subarray(1, 4).toString()).toBe('PNG');
    expect(png.headers.etag).toBe(`"${catalog()!.version}"`);
    const font = await a.app.inject({ method: 'GET', url: '/v1/editor/content/files/fonts/inter_700.ttf' });
    expect(font.statusCode).toBe(200); expect(font.headers['content-type']).toBe('font/ttf');
    // Nothing outside the content files (a path with .. is normalised before routing and doesn't reach this route).
    for (const bad of ['../catalog.json', 'stickers/../../package.json', 'nope/x.png', 'catalog.json']) expect([401, 404], bad).toContain((await a.app.inject({ method: 'GET', url: `/v1/editor/content/files/${bad}` })).statusCode);
  });

  it('every in-house look, caption template and transition passes the contract', async () => {
    const { IN_HOUSE, validateInHouse } = await import('../src/editor/contentPacks.js');
    await validateInHouse();
    expect(IN_HOUSE.map(p => [p.kind, p.items.length])).toEqual([['looks', 12], ['captions', 10], ['transitions', 12]]);
    // And the catalog carries them as built.
    expect(catalog()!.packs.filter(p => p.licence === 'MUSE').map(p => p.id)).toEqual(['muse-looks', 'muse-captions', 'muse-transitions']);
    await expect(validateInHouse([{ id: 'x', kind: 'transitions', title: 'x', licence: 'MUSE', items: [{ id: 'bad', name: 'Bad', transition: { kind: 'wobble', durationSec: 0.4 } }] }])).rejects.toThrow(/x\/bad/);
  });

  it('looks up refs and font files for the render', () => {
    expect(contentItem('content:twemoji/1f600')!.item.name).toBe('grinning face');
    expect(contentItem('content:twemoji/nope')).toBeNull();
    expect(contentItem('music_upbeat_01')).toBeNull();
    expect(contentFile('content:uisfx/glass-select')).toMatch(/sfx\/uisfx\/glass-select\.m4a$/);
    expect(contentFont('jetbrainsMono', 900)).toMatch(/jetbrainsMono_900\.ttf$/);
    expect(contentFont('caveat', 500)).toMatch(/caveat_400\.ttf$/);
    expect(contentFont('sans', 400)).toBeNull();
  });

  it('saving an edit checks its content refs against the catalog', async () => {
    const studio = ((await a.ctx.db.execute(sql`select studio_id from users limit 1`)) as any).rows[0].studio_id;
    await a.ctx.db.insert(takes).values({ id: 'take_c', studioId: studio, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 't', label: 'HD',
      engineLabel: '', cost: 0, seed: 0, status: 'test', thumb: null, prompt: '', mediaKey: 'c/take_c.mp4', media: { durationSec: 6 }, createdAt: Date.now() });
    const project = (sticker: string, fx = 'content:uisfx/glass-select') => {
      const p = M.fromV1({ version: 1, sourceTakeId: 'take_c', sourceDurationSec: 6, segments: [{ inSec: 0, outSec: 6, speed: 1 }], mute: false }, { width: 1080, height: 1920, fps: 30 });
      p.assets.push({ id: 'st', kind: 'image', library: sticker, width: 160, height: 160 }, { id: 'fx', kind: 'audio', library: fx, durationSec: 0.5 });
      p.tracks.push({ id: 'im', kind: 'image', items: [{ id: 'i1', asset: 'st', startSec: 0, durationSec: 2 }] }, { id: 'sf', kind: 'sfx', items: [{ id: 'a1', asset: 'fx', startSec: 1, inSec: 0, outSec: 0.5 }] } as M.Track);
      return p;
    };
    expect((await owner.req('POST', '/v1/editor/validate', { project: project('content:twemoji/1f600') })).body).toMatchObject({ ok: true });
    expect((await owner.req('POST', '/v1/editor/validate', { project: project('content:twemoji/zzzz') })).body.error).toMatch(/edits\.assets\.1: unknown content/);
    expect((await owner.req('POST', '/v1/editor/validate', { project: project('content:twemoji/1f600', 'content:twemoji/1f600') })).body.error).toMatch(/edits\.assets\.2: unknown content/);
  });

  it('copies the files into storage once', async () => {
    const n = await seedContent(a.ctx);
    expect(n).toBeGreaterThan(2000);
    expect(await a.ctx.storage.head(`content/${catalog()!.version}/stickers/twemoji/1f600.png`)).toBeTruthy();
    expect(await seedContent(a.ctx)).toBe(0);
  }, 120_000);
});
