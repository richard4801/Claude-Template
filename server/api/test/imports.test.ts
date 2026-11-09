// Import a video from a link (WS12; plans/api.md "Import a video from a link"). The device downloads and uploads; the
// server checks the link against the studio's rules, the file against the import limits, stores a Library clip with a
// poster and dedupes per member by link. The server-side fallback replays fixtures through a fake yt-dlp (no platform
// is ever called).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { putObject } from '../src/storage/objects.js';
import { recreateOf } from '../src/recreate/references.js';
import { IMPORT_MAX_SEC } from '../src/imports/service.js';
import { makeApp, people, type Client } from './helpers.js';
import { ENC, ff, hasFfmpeg, makeReference } from './recreate-fixture.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/links');
const fx = (f: string) => fs.readFileSync(path.join(FIX, f), 'utf8');

/** A fake yt-dlp: metadata from the fixtures by link, the test video for downloads, every call logged. */
function fakeYtDlp(dir: string, video: string) {
  const log = path.join(dir, 'calls.jsonl'), bin = path.join(dir, 'yt-dlp');
  const byUrl: Record<string, { info?: string; stderr?: string }> = {
    'https://www.tiktok.com/@muse.studio/video/7431234567890123456': { info: path.join(FIX, 'tiktok-public.info.json') },
    'https://www.tiktok.com/@muse.studio/video/7431234567890000003': { info: path.join(FIX, 'tiktok-second.info.json') },
    'https://www.youtube.com/shorts/HugeShort01': { info: path.join(FIX, 'youtube-huge.info.json') },
    'https://www.youtube.com/shorts/BigShort020': { info: path.join(FIX, 'youtube-big-short.info.json') },
    'https://www.youtube.com/shorts/AgeGated123': { info: path.join(FIX, 'youtube-age.info.json') },
    'https://www.instagram.com/reel/C9xBlocked1/': { stderr: "ERROR: [Instagram] C9xBlocked1: Requested content is not available, rate-limit reached or login required" },
  };
  fs.writeFileSync(bin, `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ args }) + '\\n');
const byUrl = ${JSON.stringify(byUrl)};
if (args.includes('--dump-single-json')) {
  const f = byUrl[args[args.length - 1]];
  if (!f) { process.stderr.write('ERROR: Unsupported URL: ' + args[args.length - 1] + '\\n'); process.exit(1); }
  if (f.stderr) { process.stderr.write(f.stderr + '\\n'); process.exit(1); }
  process.stdout.write(fs.readFileSync(f.info, 'utf8'));
} else if (args.includes('--load-info-json')) {
  fs.copyFileSync(${JSON.stringify(video)}, args[args.indexOf('-o') + 1].replace('%(ext)s', 'mp4'));
}
`, { mode: 0o755 });
  const calls = () => fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l) as { args: string[] }) : [];
  return { bin, calls };
}

describe.skipIf(!hasFfmpeg)('Import a video from a link', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client, dir: string, video: string, long: string, fake: ReturnType<typeof fakeYtDlp>;
  let studioId = '';
  const pages: string[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-imports-'));
    video = makeReference(dir);
    long = path.join(dir, 'long.mp4');
    ff('-f', 'lavfi', '-i', `testsrc2=s=90x160:r=10`, '-t', String(IMPORT_MAX_SEC + 2), ...ENC.filter((_, i, l) => !(l[i - 1] === '-r' || l[i] === '-r')), '-r', '10', long);
    fake = fakeYtDlp(dir, video);
    a = await makeApp({ YTDLP_PATH: fake.bin, RECREATE_POSE: 'false' });
    ({ owner, members: [member, other] } = await people(a, 2) as any);
    recreateOf(a.ctx).fetchPage = async url => { pages.push(url); return fx(url.endsWith('7431234567890000003') ? 'tiktok-page-downloads-off.html' : 'tiktok-page-downloads-on.html'); };
  }, 120_000);
  afterAll(async () => { await a?.close(); if (dir) fs.rmSync(dir, { recursive: true, force: true }); });

  /** The device's upload: presign (the normal flow), then the bytes arrive (as the PUT would put them). */
  const upload = async (c: Client, file = video) => {
    const p = await c.req('POST', '/v1/uploads/presign', { kind: 'clip', contentType: 'video/mp4' });
    expect(p.status).toBe(200);
    const [row] = ((await a.ctx.db.execute(sql`select storage_key, studio_id from uploads where id = ${p.body.uploadId}`)) as any).rows;
    studioId = row.studio_id;
    await a.ctx.storage.put(row.storage_key, fs.readFileSync(file), 'video/mp4');
    return p.body.uploadId as string;
  };

  it('settings: the studio\'s link rules with the import limits (swap sources, 30 s), and the reference limits', async () => {
    const s = (await member.req('GET', '/v1/links/settings')).body;
    expect(s).toMatchObject({ strictLinks: true, platforms: ['tiktok', 'instagram', 'youtube'], tiktokDownloadsOff: 'refuse', maxSec: 30, maxMb: 150, cookies: false, canEdit: false,
      reference: { maxSec: 60, maxMb: 80 } });
    expect(IMPORT_MAX_SEC).toBe(30);
    expect((await owner.req('GET', '/v1/links/settings')).body.canEdit).toBe(true);
  });

  it('the link check, for imports and (as before) references', async () => {
    const ok = await member.req('POST', '/v1/links/check', { url: 'https://youtu.be/AbCdEfGhIjK?si=x' });
    expect(ok.body).toEqual({ allowed: true, url: 'https://www.youtube.com/watch?v=AbCdEfGhIjK', platform: 'youtube', purpose: 'import' });
    const no = await member.req('POST', '/v1/links/check', { url: 'https://vimeo.com/123' });
    expect(no.body).toMatchObject({ allowed: false, code: 'link_unsupported' });
    const ref = await member.req('POST', '/v1/links/check', { url: 'https://youtu.be/AbCdEfGhIjK', purpose: 'reference' });
    expect(ref.body).toMatchObject({ allowed: true, purpose: 'reference', platform: 'youtube' });
    expect((await member.req('POST', '/v1/recreate/links/check', { url: 'https://youtu.be/AbCdEfGhIjK' })).body).toMatchObject({ allowed: true, platform: 'youtube' });
    expect((await member.req('POST', '/v1/links/check', { url: 'https://youtu.be/AbCdEfGhIjK', purpose: 'post' })).status).toBe(400);
  });

  it('a video the device fetched becomes a Library clip with a poster; the same link again is the same clip', async () => {
    const link = 'https://www.instagram.com/reels/C9xDevice01/?igsh=abc';
    const uploadId = await upload(member);
    const r = await member.req('POST', '/v1/imports', { uploadId, sourceUrl: link });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({ source: 'import', name: 'Instagram video', sourceUrl: 'https://www.instagram.com/reel/C9xDevice01/', platform: 'instagram', uploadId,
      width: 180, height: 320 });
    expect(r.body.durationSec).toBeCloseTo(4.4, 0);
    expect(r.body.posterUrl).toMatch(/^\/uploads\/c\/clip_.*_poster\.jpg$/);
    expect(r.body.videoUrl).toBe(`/uploads/${r.body.videoKey}`);
    expect(r.body.checks.map((c: any) => c.label)).toContain('One person in frame');
    expect(fake.calls()).toHaveLength(0); // nothing fetched on the server
    // The poster and the file are served like any upload.
    const poster = await a.app.inject({ method: 'GET', url: r.body.posterUrl });
    expect([poster.statusCode, poster.headers['content-type']]).toEqual([200, 'image/jpeg']);
    // A retry of the same upload → the same import; the same link with a new upload → the cached one (the new file is dropped).
    expect((await member.req('POST', '/v1/imports', { uploadId, sourceUrl: link })).body.id).toBe(r.body.id);
    const second = await upload(member);
    const again = await member.req('POST', '/v1/imports', { uploadId: second, sourceUrl: 'https://instagram.com/reel/C9xDevice01' });
    expect(again.body).toMatchObject({ id: r.body.id, cached: true });
    expect(((await a.ctx.db.execute(sql`select count(*)::int as n from uploads where id = ${second}`)) as any).rows[0].n).toBe(0);
    // Known by its link now: the device can skip the download.
    expect((await member.req('POST', '/v1/links/check', { url: link })).body.cached).toMatchObject({ id: r.body.id, cached: true });
    // Another member's import from the same link is their own.
    const theirs = await other.req('POST', '/v1/imports', { uploadId: await upload(other), sourceUrl: link, name: 'Mine' });
    expect(theirs.body).toMatchObject({ name: 'Mine' });
    expect(theirs.body.id).not.toBe(r.body.id);
    // Usable as the swap's clip: the clips row the jobs read.
    const [clip] = ((await a.ctx.db.execute(sql`select storage_key from clips where id = ${r.body.id}`)) as any).rows;
    expect(clip.storage_key).toBe(r.body.videoKey);
  }, 60_000);

  it('a 29.97 fps video (most phone and platform videos) comes back with a whole-number fps the apps can read', async () => {
    const ntsc = path.join(dir, 'ntsc.mp4');
    ff('-f', 'lavfi', '-i', 'testsrc2=s=90x160:r=30000/1001', '-t', '2', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-threads', '1', ntsc);
    const r = await member.req('POST', '/v1/imports', { uploadId: await upload(member, ntsc), sourceUrl: 'https://www.tiktok.com/@muse.studio/video/7431234567890002997' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.fps).toBe(30);
    expect((await member.req('GET', '/v1/imports')).body.every((i: any) => Number.isInteger(i.fps))).toBe(true);
    expect((await member.req('POST', '/v1/links/check', { url: 'https://www.tiktok.com/@muse.studio/video/7431234567890002997' })).body.cached.fps).toBe(30);
    expect((await member.req('DELETE', `/v1/imports/${r.body.id}`)).status).toBe(204);
  }, 60_000);

  it('lists: a member sees their own imports, the owner all; rename and delete', async () => {
    const mine = (await member.req('GET', '/v1/imports')).body;
    expect(mine).toHaveLength(1);
    expect((await owner.req('GET', '/v1/imports')).body).toHaveLength(2);
    expect((await other.req('GET', `/v1/imports/${mine[0].id}`)).status).toBe(404);
    expect((await member.req('PATCH', `/v1/imports/${mine[0].id}`, { name: 'Walk-in' })).body.name).toBe('Walk-in');
    const theirs = (await other.req('GET', '/v1/imports')).body[0];
    // In use by a queued job → refused; then deleted with its file and poster.
    await a.ctx.db.execute(sql`insert into jobs (id, studio_id, kind, title, model_id, model_name, request, state, cost, seed, created_at)
      values ('job_busy', ${studioId}, 'render', 't', 'm', 'M', ${JSON.stringify({ clipId: theirs.id })}::jsonb, 'queued', 0, 1, ${Date.now()})`);
    expect((await other.req('DELETE', `/v1/imports/${theirs.id}`)).body.code).toBe('import_in_use');
    await a.ctx.db.execute(sql`update jobs set state = 'done' where id = 'job_busy'`);
    expect((await other.req('DELETE', `/v1/imports/${theirs.id}`)).status).toBe(204);
    expect(await a.ctx.storage.head(theirs.videoKey)).toBeNull();
    expect((await owner.req('GET', '/v1/imports')).body).toHaveLength(1);
  }, 30_000);

  it('device refusals: too long for a swap source, too big, a link outside the rules, not a video, used upload', async () => {
    const tooLong = await member.req('POST', '/v1/imports', { uploadId: await upload(member, long) });
    expect([tooLong.status, tooLong.body.code, tooLong.body.error]).toEqual([400, 'too_long', `Imports can be up to 30 s (this one is ${IMPORT_MAX_SEC + 2} s)`]);
    expect((await member.req('POST', '/v1/imports', { uploadId: await upload(member), sourceUrl: 'https://vimeo.com/1234' })).body.code).toBe('link_unsupported');
    const mb = a.ctx.config.IMPORT_MAX_MB;
    (a.ctx.config as any).IMPORT_MAX_MB = 0.001;
    try { expect((await member.req('POST', '/v1/imports', { uploadId: await upload(member) })).body.code).toBe('link_too_big'); }
    finally { (a.ctx.config as any).IMPORT_MAX_MB = mb; }
    const img = await member.req('POST', '/v1/uploads/presign', { kind: 'image', contentType: 'image/png' });
    expect((await member.req('POST', '/v1/imports', { uploadId: img.body.uploadId })).status).toBe(400);
    const pending = await member.req('POST', '/v1/uploads/presign', { kind: 'clip', contentType: 'video/mp4' });
    expect((await member.req('POST', '/v1/imports', { uploadId: pending.body.uploadId })).body.code).toBe('upload_missing');
    // Another member reusing an upload that is already someone's import.
    expect((await other.req('POST', '/v1/imports', { uploadId: (await member.req('GET', '/v1/imports')).body[0].uploadId })).body.code).toBe('upload_used');
    // With no link at all it's a plain import (a file the member saved).
    const plain = await member.req('POST', '/v1/imports', { uploadId: await upload(member), name: 'Saved file' });
    expect(plain.body).toMatchObject({ name: 'Saved file', source: 'import' });
    expect(plain.body.sourceUrl).toBeUndefined();
  }, 60_000);

  it('server fallback: the guardrails of Recreate links, the import limits, plain codes', async () => {
    const r = await member.req('POST', '/v1/imports', { url: 'https://www.tiktok.com/@Muse.Studio/video/7431234567890123456?is_from_webapp=1' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body).toMatchObject({ source: 'import', platform: 'tiktok', name: 'outfit check but make it a transition', sourceUrl: 'https://www.tiktok.com/@muse.studio/video/7431234567890123456' });
    expect(r.body.posterUrl).toBeTruthy();
    expect(pages).toEqual(['https://www.tiktok.com/@muse.studio/video/7431234567890123456']);
    const calls = fake.calls();
    expect(calls).toHaveLength(2); // metadata once, then the download from it
    for (const c of calls) expect(c.args).toEqual(expect.arrayContaining(['--ignore-config', '--no-cookies', '--no-cookies-from-browser', '--no-playlist']));
    expect(r.body.thumb).toEqual({ url: r.body.posterUrl });
    // The Mac's spelling ({sourceUrl} with no upload) is the same server fetch.
    expect((await member.req('POST', '/v1/imports', { sourceUrl: 'https://www.tiktok.com/@muse.studio/video/7431234567890123456' })).body).toMatchObject({ id: r.body.id, cached: true });
    // Cached by link, no new fetch.
    expect((await member.req('POST', '/v1/imports', { url: 'https://m.tiktok.com/@muse.studio/video/7431234567890123456' })).body).toMatchObject({ id: r.body.id, cached: true });
    expect(fake.calls()).toHaveLength(2);
    const cases: [string, number, string][] = [
      ['https://www.tiktok.com/@muse.studio/video/7431234567890000003', 422, 'link_downloads_off'],
      ['https://youtube.com/shorts/HugeShort01', 400, 'too_long'],
      ['https://youtube.com/shorts/BigShort020', 422, 'link_too_big'],
      ['https://youtube.com/shorts/AgeGated123', 422, 'link_private'],
      ['https://www.instagram.com/reel/C9xBlocked1/', 502, 'link_blocked'],
      ['https://example.com/v.mp4', 422, 'link_unsupported'],
    ];
    for (const [url, status, code] of cases) {
      const x = await member.req('POST', '/v1/imports', { url });
      expect([url, x.status, x.body.code]).toEqual([url, status, code]);
    }
    expect((await member.req('POST', '/v1/imports', { url: 'https://youtube.com/shorts/HugeShort01' })).body.error).toBe('Imports can be up to 30 s for now (this one is 40 s)');
    expect(fake.calls().filter(c => c.args.includes('--load-info-json'))).toHaveLength(1); // nothing else was downloaded
    // Server fetching off: the plain fallback.
    (a.ctx.config as any).RECREATE_LINKS = false;
    try { expect((await member.req('POST', '/v1/imports', { url: 'https://youtube.com/shorts/BigShort020' })).body.code).toBe('link_blocked'); }
    finally { (a.ctx.config as any).RECREATE_LINKS = true; }
  }, 60_000);
});
