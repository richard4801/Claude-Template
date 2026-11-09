// The edit content library (src/editor/content.ts): the catalog, its files, storage seeding, and the lookups the
// server render uses.
import fs from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
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

  it('looks up refs and font files for the render', () => {
    expect(contentItem('content:twemoji/1f600')!.item.name).toBe('grinning face');
    expect(contentItem('content:twemoji/nope')).toBeNull();
    expect(contentItem('music_upbeat_01')).toBeNull();
    expect(contentFile('content:uisfx/glass-select')).toMatch(/sfx\/uisfx\/glass-select\.m4a$/);
    expect(contentFont('jetbrainsMono', 900)).toMatch(/jetbrainsMono_900\.ttf$/);
    expect(contentFont('caveat', 500)).toMatch(/caveat_400\.ttf$/);
    expect(contentFont('sans', 400)).toBeNull();
  });

  it('copies the files into storage once', async () => {
    const n = await seedContent(a.ctx);
    expect(n).toBeGreaterThan(2000);
    expect(await a.ctx.storage.head(`content/${catalog()!.version}/stickers/twemoji/1f600.png`)).toBeTruthy();
    expect(await seedContent(a.ctx)).toBe(0);
  }, 120_000);
});
