// Recreate this edit · references from links (workstream 1; the owner's decision in
// plans/research/platform-download-rules.md). A fake yt-dlp replays the fixtures in test/fixtures/links (no platform is
// ever called): public only, no cookies, downloads-off respected, one fetch per link, the 60 s and size checks before
// the download, cached by link, private storage, plain error codes.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { recreateReferences } from '../src/recreate/schema.js';
import { BASE_ARGS, checkInfo, errorFor, FALLBACK, normalizeLink, tiktokDownloadsOff, ytDlp } from '../src/recreate/links.js';
import { recreateOf } from '../src/recreate/references.js';
import { makeApp, people, until, type Client } from './helpers.js';
import { hasFfmpeg, makeReference } from './recreate-fixture.js';

const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures/links');
const fx = (f: string) => fs.readFileSync(path.join(FIX, f), 'utf8');

describe('Links (unit)', () => {
  it('normalizes TikTok, Instagram Reel and YouTube links; refuses the rest', () => {
    expect(normalizeLink('http://m.tiktok.com/@Muse.Studio/video/7431234567890123456?is_from_webapp=1&sender_device=pc'))
      .toEqual({ platform: 'tiktok', url: 'https://www.tiktok.com/@muse.studio/video/7431234567890123456' });
    expect(normalizeLink('https://vm.tiktok.com/ZMabc123/').url).toBe('https://vm.tiktok.com/ZMabc123/');
    expect(normalizeLink('https://www.instagram.com/reels/C9xYz12AbC/?igsh=abc').url).toBe('https://www.instagram.com/reel/C9xYz12AbC/');
    expect(normalizeLink('https://youtube.com/shorts/AbCdEfGhIjK?feature=share').url).toBe('https://www.youtube.com/shorts/AbCdEfGhIjK');
    expect(normalizeLink('https://youtu.be/dQw4w9WgXcQ?t=3').url).toBe('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    for (const bad of ['https://example.com/video.mp4', 'ftp://tiktok.com/x', 'not a link', 'https://www.tiktok.com/@a', 'https://www.instagram.com/someone/'])
      expect(() => normalizeLink(bad)).toThrow(expect.objectContaining({ code: 'link_unsupported' }));
  });

  it('the metadata alone refuses lists, live, private, age-gated, too long and too big', () => {
    const o = { maxSec: 60, maxBytes: 80 * 1048576 };
    expect(() => checkInfo(JSON.parse(fx('tiktok-public.info.json')), o)).not.toThrow();
    const code = (f: string) => { try { checkInfo(JSON.parse(fx(f)), o); return 'ok'; } catch (e) { return (e as { code: string }).code; } };
    expect([code('youtube-playlist.info.json'), code('youtube-age.info.json'), code('youtube-long.info.json'), code('youtube-huge.info.json')])
      .toEqual(['link_unsupported', 'link_private', 'too_long', 'link_too_big']);
    expect(() => checkInfo({ is_live: true }, o)).toThrow(expect.objectContaining({ code: 'link_unsupported' }));
    expect(() => checkInfo({ availability: 'subscriber_only' }, o)).toThrow(expect.objectContaining({ code: 'link_private' }));
    expect(() => checkInfo({ availability: 'unlisted', age_limit: 0, duration: 20 }, o)).not.toThrow();
  });

  it('TikTok\'s downloads setting from the public page; yt-dlp errors to plain codes', () => {
    expect(tiktokDownloadsOff(fx('tiktok-page-downloads-on.html'))).toBe(false);
    expect(tiktokDownloadsOff(fx('tiktok-page-downloads-off.html'))).toBe(true);
    expect(tiktokDownloadsOff('<html>no data</html>')).toBeNull();
    const c = (s: string) => errorFor(s).code;
    expect(c('ERROR: [Instagram] C9x: Requested content is not available, rate-limit reached or login required. Use --cookies')).toBe('link_blocked');
    expect(c('ERROR: [youtube] abc: Private video. Sign in if you\'ve been granted access to this video')).toBe('link_private');
    expect(c('ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.')).toBe('link_private');
    expect(c('ERROR: [TikTok] 743: HTTP Error 403: Forbidden')).toBe('link_blocked');
    expect(c('ERROR: Unsupported URL: https://example.com')).toBe('link_unsupported');
    expect(errorFor('timed out')).toMatchObject({ code: 'link_blocked', status: 502, message: FALLBACK });
    // No sign-ins: never cookies, never the user's config.
    expect(BASE_ARGS).toEqual(expect.arrayContaining(['--ignore-config', '--no-cookies', '--no-cookies-from-browser', '--no-playlist']));
  });
});

/** A fake yt-dlp: metadata from the fixtures by link, the test video for downloads, every call logged. */
function fakeYtDlp(dir: string, video: string) {
  const log = path.join(dir, 'calls.jsonl'), bin = path.join(dir, 'yt-dlp');
  const byUrl: Record<string, { info?: string; stderr?: string }> = {
    'https://www.tiktok.com/@muse.studio/video/7431234567890123456': { info: path.join(FIX, 'tiktok-public.info.json') },
    'https://vm.tiktok.com/ZMshort1/': { info: path.join(FIX, 'tiktok-public.info.json') },
    'https://www.tiktok.com/@muse.studio/video/7431234567890000003': { info: path.join(FIX, 'tiktok-second.info.json') },
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ': { info: path.join(FIX, 'youtube-long.info.json') },
    'https://www.youtube.com/shorts/AgeGated123': { info: path.join(FIX, 'youtube-age.info.json') },
    'https://www.youtube.com/shorts/HugeShort01': { info: path.join(FIX, 'youtube-huge.info.json') },
    'https://www.instagram.com/reel/C9xPrivate1/': { stderr: 'ERROR: [Instagram] C9xPrivate1: This account is private' },
    'https://www.instagram.com/reel/C9xBlocked1/': { stderr: 'ERROR: [Instagram] C9xBlocked1: Requested content is not available, rate-limit reached or login required' },
  };
  fs.writeFileSync(bin, `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ args, env: Object.keys(process.env) }) + '\\n');
const byUrl = ${JSON.stringify(byUrl)};
if (args.includes('--dump-single-json')) {
  const f = byUrl[args[args.length - 1]];
  if (!f) { process.stderr.write('ERROR: Unsupported URL: ' + args[args.length - 1] + '\\n'); process.exit(1); }
  if (f.stderr) { process.stderr.write(f.stderr + '\\n'); process.exit(1); }
  process.stdout.write(fs.readFileSync(f.info, 'utf8'));
} else if (args.includes('--load-info-json')) {
  const info = JSON.parse(fs.readFileSync(args[args.indexOf('--load-info-json') + 1], 'utf8'));
  if (info.id === '7431234567890000003') { process.stderr.write('ERROR: [TikTok] 743: HTTP Error 403: Forbidden\\n'); process.exit(1); }
  fs.copyFileSync(${JSON.stringify(video)}, args[args.indexOf('-o') + 1].replace('%(ext)s', 'mp4'));
}
`, { mode: 0o755 });
  const calls = () => fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l) as { args: string[]; env: string[] }) : [];
  return { bin, calls };
}

describe.skipIf(!hasFfmpeg)('Recreate · references from links (fake yt-dlp, no platform calls)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, member: Client, other: Client, dir: string, fake: ReturnType<typeof fakeYtDlp>;
  const pages: string[] = [];
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-links-'));
    fake = fakeYtDlp(dir, makeReference(dir));
    a = await makeApp({ YTDLP_PATH: fake.bin, RECREATE_POSE: 'false' });
    ({ members: [member, other] } = await people(a, 2) as any);
    recreateOf(a.ctx).fetchPage = async url => { pages.push(url); return fx(url.endsWith('7431234567890123456') || url.endsWith('7431234567890000003') ? 'tiktok-page-downloads-on.html' : 'tiktok-page-downloads-off.html'); };
  });
  afterAll(async () => { await a?.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const ready = (c: Client, id: string) => until(async () => { const r = (await c.req('GET', `/v1/recreate/references/${id}`)).body; return r.state === 'ready' || r.state === 'failed' ? r : null; }, 60_000);

  it('a public TikTok link becomes a private reference: metadata once, then the download from it; no cookies or config', async () => {
    const r = await member.req('POST', '/v1/recreate/references', { url: 'https://www.tiktok.com/@Muse.Studio/video/7431234567890123456?is_from_webapp=1' });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ state: 'analyzing', source: 'link', sourceUrl: 'https://www.tiktok.com/@muse.studio/video/7431234567890123456', name: 'outfit check but make it a transition' });
    const done = await ready(member, r.body.id);
    expect(done.state).toBe('ready');
    expect(done.recipe.slots).toHaveLength(3);
    const [row] = await a.ctx.db.select().from(recreateReferences).where(eq(recreateReferences.id, r.body.id));
    expect(row!.storageKey).toBe(`rx/${row!.studioId}/${row!.id}/source.mp4`); // private (not under /uploads)
    expect(await a.ctx.storage.head(`rx/${row!.studioId}/${row!.id}/info.json`)).toBeNull(); // the metadata is gone once stored
    expect(row!.uploadId).toBeNull();
    const calls = fake.calls();
    expect(calls).toHaveLength(2); // one metadata read, one download from that metadata (the page isn't read again)
    expect(calls[1]!.args).toContain('--load-info-json');
    expect(calls[1]!.args.some(x => x.startsWith('https://'))).toBe(false);
    for (const c of calls) {
      expect(c.args).toEqual(expect.arrayContaining(['--ignore-config', '--no-cookies', '--no-cookies-from-browser', '--no-playlist']));
      expect(c.env.filter(k => !['PATH', 'HOME', 'LANG', 'PWD', 'SHLVL', '_'].includes(k))).toEqual([]); // nothing of the server's leaks in
    }
    expect(pages).toEqual(['https://www.tiktok.com/@muse.studio/video/7431234567890123456']);
    // The video for the side-by-side player, like a file reference.
    expect((await member.req('GET', `/v1/recreate/references/${r.body.id}/video`)).status).toBe(200);
  }, 90_000);

  it('the same link again is the same reference (no new fetch); another member fetches their own', async () => {
    const before = fake.calls().length;
    const again = await member.req('POST', '/v1/recreate/references', { url: 'https://m.tiktok.com/@muse.studio/video/7431234567890123456?lang=en' });
    expect(again.body).toMatchObject({ cached: true, state: 'ready' });
    // A short link is read once, then found by the video's own link.
    const short = await member.req('POST', '/v1/recreate/references', { url: 'https://vm.tiktok.com/ZMshort1/' });
    expect(short.body).toMatchObject({ cached: true, id: again.body.id });
    expect(fake.calls().length).toBe(before + 1);
    const theirs = await other.req('POST', '/v1/recreate/references', { url: 'https://www.tiktok.com/@muse.studio/video/7431234567890123456' });
    expect(theirs.body.id).not.toBe(again.body.id);
    expect(theirs.body.cached).toBeUndefined();
    await ready(other, theirs.body.id);
  }, 90_000);

  it('refusals with plain codes, before anything is downloaded', async () => {
    const before = fake.calls().filter(c => c.args.includes('--load-info-json')).length;
    const post = (url: string) => member.req('POST', '/v1/recreate/references', { url });
    const off = await post('https://www.tiktok.com/@muse.studio/video/7431234567890999999');
    expect(off.status).toBe(422); // not in the fake's list: an unsupported URL to yt-dlp
    expect(off.body.error).toMatch(/can’t fetch from that link/);
    const cases: [string, number, string][] = [
      ['https://www.youtube.com/watch?v=dQw4w9WgXcQ', 400, 'too_long'],
      ['https://youtube.com/shorts/AgeGated123', 422, 'link_private'],
      ['https://youtube.com/shorts/HugeShort01', 422, 'link_too_big'],
      ['https://www.instagram.com/reel/C9xPrivate1/', 422, 'link_private'],
      ['https://www.instagram.com/reel/C9xBlocked1/', 502, 'link_blocked'],
      ['https://example.com/v.mp4', 422, 'link_unsupported'],
    ];
    for (const [url, status, code] of cases) {
      const r = await post(url);
      expect([url, r.status, r.body.code]).toEqual([url, status, code]);
    }
    expect((await post('https://www.instagram.com/reel/C9xBlocked1/')).body.error).toBe(FALLBACK);
    expect(fake.calls().filter(c => c.args.includes('--load-info-json')).length).toBe(before);
  });

  it('the creator turned TikTok downloads off: refused, nothing stored', async () => {
    recreateOf(a.ctx).fetchPage = async () => fx('tiktok-page-downloads-off.html');
    const count = (await a.ctx.db.select().from(recreateReferences)).length;
    const r = await member.req('POST', '/v1/recreate/references', { url: 'https://www.tiktok.com/@muse.studio/video/7431234567890000003' });
    expect(r).toMatchObject({ status: 422, body: { code: 'link_downloads_off' } });
    expect((await a.ctx.db.select().from(recreateReferences)).length).toBe(count);
    // A page MUSE can't read is a blocked fetch, not a yes.
    recreateOf(a.ctx).fetchPage = async () => { throw new Error('403'); };
    expect((await member.req('POST', '/v1/recreate/references', { url: 'https://www.tiktok.com/@muse.studio/video/7431234567890000003' })).body.code).toBe('link_blocked');
  });

  it('a download the platform blocks fails the reference with link_blocked (the apps offer the file drop)', async () => {
    recreateOf(a.ctx).fetchPage = async () => fx('tiktok-page-downloads-on.html');
    const r = await member.req('POST', '/v1/recreate/references', { url: 'https://www.tiktok.com/@muse.studio/video/7431234567890000003' });
    expect(r.status).toBe(200);
    const done = await ready(member, r.body.id);
    expect(done).toMatchObject({ state: 'failed', errorCode: 'link_blocked', error: FALLBACK });
    // A failed one isn't cached: trying again fetches again.
    const before = fake.calls().length;
    await member.req('POST', '/v1/recreate/references', { url: 'https://www.tiktok.com/@muse.studio/video/7431234567890000003' });
    expect(fake.calls().length).toBeGreaterThan(before);
    await recreateOf(a.ctx).idle();
  }, 60_000);

  it('a missing resolver is a blocked fetch, not a crash', async () => {
    const svc = recreateOf(a.ctx);
    svc.resolver = ytDlp('/nonexistent/yt-dlp');
    const r = await member.req('POST', '/v1/recreate/references', { url: 'https://youtube.com/shorts/AbCdEfGhIjK' });
    expect(r).toMatchObject({ status: 502, body: { code: 'link_blocked' } });
    svc.resolver = null;
  });
});
