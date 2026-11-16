// Long imports (owner 2026-11-16: "import up to 1 hr long, about 2 GB max … edit file videos needed to make an edit").
// The limits and their copy; the Suite's 30 s rule applied when a long Library clip is used (never at import); large
// files end to end: multipart presign (resumable), the local-storage PUT streamed to disk, the temp-disk check.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { clips } from '../src/db/schema.js';
import { lengthText, limitText, requireTempSpace, sizeText, suiteSourceTooLong, SUITE_SOURCE_MAX_SEC, tooBigError, tooLongError } from '../src/imports/limits.js';
import { checkInfo } from '../src/recreate/links.js';
import { LocalStorage, PART_BYTES } from '../src/storage/index.js';
import { MAX_VIDEO_BYTES } from '../src/camera/claudeAttachments.js';
import { makeApp, people, type Client } from './helpers.js';
import { hasFfmpeg, makeReference } from './recreate-fixture.js';

describe('import limits (edit footage: 60 min, 2 GB)', () => {
  it('words: lengths, sizes, the limit line', () => {
    expect([lengthText(42), lengthText(119), lengthText(725), lengthText(3600), lengthText(3725)]).toEqual(['42 s', '119 s', '12 min', '1 h', '1 h 2 min']);
    expect([sizeText(5e5), sizeText(150 * 1048576), sizeText(2048 * 1048576), sizeText(2.5 * 1024 ** 3)]).toEqual(['1 MB', '150 MB', '2 GB', '2.5 GB']);
    expect(limitText(3600, 2048)).toBe('Up to 60 minutes and 2 GB');
  });
  it('errors name the limit that was hit', () => {
    const l = tooLongError(3725, 3600, 2048), b = tooBigError(2.5 * 1024 ** 3, 2048, 3600);
    expect([l.status, l.code, l.message]).toEqual([400, 'too_long', 'This video is 1 h 2 min long · the limit is 60 minutes (imports: up to 60 minutes and 2 GB)']);
    expect([b.status, b.code, b.message]).toEqual([422, 'link_too_big', 'This video is 2.5 GB · the limit is 2 GB (imports: up to 60 minutes and 2 GB)']);
    // A link's metadata: the import's own messages; references keep theirs.
    const o = { maxSec: 3600, maxBytes: 2048 * 1048576, tooLong: (s: number) => tooLongError(s, 3600, 2048), tooBig: (x: number) => tooBigError(x, 2048, 3600) };
    expect(() => checkInfo({ duration: 3000, filesize: 1.5 * 1024 ** 3 }, o)).not.toThrow();
    expect(() => checkInfo({ duration: 3725 }, o)).toThrow('the limit is 60 minutes');
    expect(() => checkInfo({ duration: 600, requested_formats: [{ filesize: 2.4 * 1024 ** 3 }, { filesize: 1e8 }] }, o)).toThrow('the limit is 2 GB');
    expect(() => checkInfo({ duration: 61 }, { maxSec: 60, maxBytes: 1e8 })).toThrow('References can be up to 60 s for now');
  });
  it('the Suite\'s 30 s rule applies at use: a plain reason and the numbers for the trim', () => {
    expect(SUITE_SOURCE_MAX_SEC).toBe(30);
    expect(suiteSourceTooLong(30, 'Swap')).toBeNull();
    expect(suiteSourceTooLong(null, 'Swap')).toBeNull();
    const e = suiteSourceTooLong(1800, 'Recast')! as any;
    expect([e.status, e.code, e.message, e.extra]).toEqual([400, 'clip_too_long', 'This clip is 30 min · Recast takes up to 30 s: trim it in Edit first, or pick the part in New Swap',
      { tool: 'recast', maxSeconds: 30, clipSeconds: 1800 }]);
    expect(suiteSourceTooLong(45, 'Swap')!.message).toBe('This clip is 45 s · Swap takes up to 30 s: pick the part to use in New Swap, or trim it in Edit first');
  });
  it('temp disk: a plain error when the server is short of space', () => {
    expect(() => requireTempSpace(1024 ** 3, 512, () => 10 * 1024 ** 3)).not.toThrow();
    expect(() => requireTempSpace(1024 ** 3, 512, () => null)).not.toThrow(); // unknown: not refused
    try { requireTempSpace(1024 ** 3, 512, () => 800 * 1048576); expect.unreachable(); } catch (e: any) {
      expect([e.status, e.code, e.message]).toEqual([507, 'server_disk_full', 'The server is short of temporary space for this video (1 GB needs 1.5 GB free, 800 MB left) · try again in a few minutes, or import a shorter video']);
    }
  });
  it('Claude takes edit footage up to 2 GB', () => { expect(MAX_VIDEO_BYTES).toBe(2 * 1024 ** 3); });
});

describe('local storage streams large bodies', () => {
  let dir: string, s: LocalStorage;
  beforeAll(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-lstore-')); s = new LocalStorage(dir, () => 'http://x'); });
  afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));
  it('putFrom writes in chunks with the md5 and refuses past the cap (nothing left behind)', async () => {
    const chunks = Array.from({ length: 64 }, (_, i) => Buffer.alloc(1024 * 1024, i)); // 64 MB, never one buffer
    const want = crypto.createHash('md5'); for (const c of chunks) want.update(c);
    const r = await s.putFrom('c/big.mp4', Readable.from(chunks), 2 * 1024 ** 3);
    expect(r).toEqual({ etag: want.digest('hex'), size: 64 * 1048576 });
    expect((await s.head('c/big.mp4'))!.size).toBe(64 * 1048576);
    await expect(s.putFrom('c/over.mp4', Readable.from(chunks), 10 * 1048576)).rejects.toMatchObject({ tooLarge: true });
    expect(await s.head('c/over.mp4')).toBeNull();
    expect(fs.readdirSync(path.join(dir, 'c')).filter(f => f.includes('.part'))).toEqual([]);
  });
});

describe('large uploads end to end (local storage)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client, studioId = '';
  beforeAll(async () => {
    a = await makeApp({ RECREATE_POSE: 'false', SUITE_MODE: 'mock' });
    ({ owner, members: [member, other] } = await people(a, 2) as any);
  }, 60_000);
  afterAll(async () => { await a?.close(); });
  const put = (url: string, body: Buffer | Readable, ct = 'video/mp4') => a.app.inject({ method: 'PUT', url: url.replace(/^https?:\/\/[^/]+/, ''), headers: { 'content-type': ct }, payload: body as any });
  const presign = async (c: Client) => {
    const p = await c.req('POST', '/v1/uploads/presign', { kind: 'clip', contentType: 'video/mp4' });
    const [row] = ((await a.ctx.db.execute(sql`select storage_key, studio_id from uploads where id = ${p.body.uploadId}`)) as any).rows;
    studioId = row.studio_id;
    return { ...p.body, key: row.storage_key as string };
  };

  it('a single presigned PUT is streamed to disk (any content type), with its ETag', async () => {
    const p = await presign(member);
    const body = crypto.randomBytes(3 * 1048576);
    const r = await put(p.url, body);
    expect(r.statusCode).toBe(200);
    expect(r.headers.etag).toBe(`"${crypto.createHash('md5').update(body).digest('hex')}"`);
    expect((await a.ctx.storage.head(p.key))!.size).toBe(body.length);
    expect((await put(p.url.replace(/sig=[^&]+/, 'sig=nope'), body)).statusCode).toBe(403);
  });

  it('multipart: parts PUT to presigned URLs, resumed from what arrived, completed; others can\'t touch it', async () => {
    const p = await presign(member);
    const bytes = PART_BYTES + 5 * 1048576;
    const start = await member.req('POST', `/v1/uploads/${p.uploadId}/multipart`, { bytes });
    expect(start.status, JSON.stringify(start.body)).toBe(200);
    expect(start.body).toMatchObject({ uploadId: p.uploadId, partSize: PART_BYTES, partCount: 2 });
    expect(start.body.parts.map((x: any) => x.n)).toEqual([1, 2]);
    const mp = start.body.multipartId;
    expect((await other.req('GET', `/v1/uploads/${p.uploadId}/multipart?multipartId=${mp}`)).status).toBe(404);
    const part1 = crypto.randomBytes(PART_BYTES), part2 = crypto.randomBytes(5 * 1048576);
    const r1 = await put(start.body.parts[0].url, part1);
    expect(r1.statusCode).toBe(200);
    // The connection dropped: what arrived, and fresh URLs for the rest.
    const resume = await member.req('GET', `/v1/uploads/${p.uploadId}/multipart?multipartId=${mp}`);
    expect(resume.body.done).toEqual([{ n: 1, etag: String(r1.headers.etag).replace(/"/g, ''), size: PART_BYTES }]);
    expect(resume.body.parts.map((x: any) => x.n)).toEqual([2]);
    // A part URL is good for its own part only.
    expect((await put(resume.body.parts[0].url.replace('part=2', 'part=3'), part2)).statusCode).toBe(403);
    const r2 = await put(resume.body.parts[0].url, part2);
    expect((await member.req('POST', `/v1/uploads/${p.uploadId}/multipart/complete`, { multipartId: mp, parts: [{ n: 1, etag: r1.headers.etag }] })).body.code).toBe('bad_request');
    expect((await member.req('POST', `/v1/uploads/${p.uploadId}/multipart/complete`, { multipartId: mp, parts: [{ n: 1, etag: r1.headers.etag }, { n: 2, etag: 'wrong' }] })).body.code).toBe('upload_part_missing');
    const done = await member.req('POST', `/v1/uploads/${p.uploadId}/multipart/complete`, { multipartId: mp, parts: [{ n: 2, etag: r2.headers.etag }, { n: 1, etag: r1.headers.etag }] });
    expect(done.body).toEqual({ uploadId: p.uploadId, bytes });
    const got = await a.ctx.storage.get(p.key);
    const h = crypto.createHash('md5');
    for await (const c of got!.body) h.update(c as Buffer);
    expect(h.digest('hex')).toBe(crypto.createHash('md5').update(part1).update(part2).digest('hex'));
    expect(fs.readdirSync(path.join((a.ctx.storage as any).dir, 'c')).filter(f => f.includes('.mp-'))).toEqual([]);
  }, 60_000);

  it('multipart refusals: over 2 GB, unknown or cancelled uploads', async () => {
    const p = await presign(member);
    expect((await member.req('POST', `/v1/uploads/${p.uploadId}/multipart`, { bytes: 2 * 1024 ** 3 + 1 })).body.code).toBe('too_big');
    expect((await member.req('POST', '/v1/uploads/up_nope/multipart', { bytes: 10 })).status).toBe(404);
    const s = await member.req('POST', `/v1/uploads/${p.uploadId}/multipart`, { bytes: 10 });
    expect((await member.req('DELETE', `/v1/uploads/${p.uploadId}/multipart?multipartId=${s.body.multipartId}`)).status).toBe(204);
    expect((await member.req('GET', `/v1/uploads/${p.uploadId}/multipart?multipartId=${s.body.multipartId}`)).body.code).toBe('upload_missing');
    expect((await put(s.body.parts[0].url, Buffer.from('0123456789'))).body).toContain('upload_missing');
  });

  it.skipIf(!hasFfmpeg)('a multipart upload imports like any other; the edit editor presign takes 2 GB videos', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-mpimp-'));
    try {
      const video = fs.readFileSync(makeReference(dir));
      const p = await presign(member);
      const s = await member.req('POST', `/v1/uploads/${p.uploadId}/multipart`, { bytes: video.length });
      const r = await put(s.body.parts[0].url, video);
      await member.req('POST', `/v1/uploads/${p.uploadId}/multipart/complete`, { multipartId: s.body.multipartId, parts: [{ n: 1, etag: r.headers.etag }] });
      const imp = await member.req('POST', '/v1/imports', { uploadId: p.uploadId, name: 'Footage' });
      expect(imp.status, JSON.stringify(imp.body)).toBe(200);
      expect(imp.body).toMatchObject({ name: 'Footage', source: 'import', bytes: video.length });
      // Edit's own presign: a 2 GB video may start a multipart upload too.
      const e = await member.req('POST', '/v1/editor/uploads/presign', { contentType: 'video/mp4', bytes: 2 * 1024 ** 3 });
      expect(e.status).toBe(200);
      expect((await member.req('POST', `/v1/uploads/${e.body.uploadId}/multipart`, { bytes: 2 * 1024 ** 3 })).body.partCount).toBe(32);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  }, 60_000);

  it('a long Library clip picked for Swap or Recast is refused plainly there (with the trim numbers), never at import', async () => {
    await presign(owner);
    const id = 'clip_long_test';
    await a.ctx.db.insert(clips).values({ id, studioId, name: 'Hour', durationSec: 1800, width: 1080, height: 1920, fps: 30, meta: { source: 'import' }, checks: [],
      storageKey: 'c/long.mp4', createdBy: owner.id, createdAt: Date.now() });
    const rc = await owner.req('POST', '/v1/suite/shots/estimate', { mode: 'recast', clipId: id, cast: [{ characterId: 'm_nope' }], quality: 'standard' });
    expect([rc.status, rc.body.code, rc.body.maxSeconds, rc.body.clipSeconds, rc.body.tool]).toEqual([400, 'clip_too_long', 30, 1800, 'recast']);
    const sw = await owner.req('POST', '/v1/jobs', { modelId: 'm_nope', clipId: id, engine: 'h3' });
    expect([sw.status, sw.body.code, sw.body.error]).toEqual([400, 'clip_too_long', 'This clip is 30 min · Swap takes up to 30 s: pick the part to use in New Swap, or trim it in Edit first']);
  });
});
