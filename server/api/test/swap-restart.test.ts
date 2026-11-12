// Character swap · a paid provider job must survive a deploy or restart, like the AI Suite line (suite-restart.test.ts).
// Against a FAKE Higgsfield and a FAKE Replicate (no money): the server is stopped mid-render and a new instance polls
// the SAME saved prediction on the provider it was made on (a take that moved to Replicate resumes there, never a new
// paid generation); two instances overlapping (a deploy) don't both run it; a result we can't download fails honestly
// and job_recover brings it back without a new generation; our timeout never throws away a render the provider finished
// anyway and never says "not charged" unless the provider confirmed the cancel; failing finishing keeps the video.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { jobs, ledger } from '../src/db/schema.js';
import { openDb } from '../src/db/client.js';
import { PAID_UNCONFIRMED, PAID_UNSAVED } from '../src/services/paidLost.js';
import { client, demoModel, makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
type App = Awaited<ReturnType<typeof makeApp>>;

describe.skipIf(!hasFfmpeg)('Character swap · Higgsfield / Replicate job across a restart (FAKE providers, no money)', () => {
  let server: http.Server, dir: string, base = '';
  type State = 'in_progress' | 'completed' | 'canceled';
  type Req = { id: string; on: 'hf' | 'rep'; state: State; cancels: number };
  const reqs: Req[] = [];
  const fake = { downloads: 0, failDownloads: 0, startState: 'in_progress' as State, honourCancel: true, hfNoCredit: false, hfPosts: 0 };
  const reset = () => { reqs.length = 0; Object.assign(fake, { downloads: 0, failDownloads: 0, startState: 'in_progress', honourCancel: true, hfNoCredit: false, hfPosts: 0 }); };
  const paidStarts = () => reqs.length; // every request a provider accepted (a refused start is not one)
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-swap-restart-'));
    const file = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '5', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
    server = http.createServer((q, res) => {
      let body = '';
      q.on('data', c => (body += c));
      q.on('end', () => {
        const url = q.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') {
          fake.downloads++;
          if (fake.failDownloads > 0) { fake.failDownloads--; return json(500, { detail: 'storage hiccup' }); }
          res.writeHead(200, { 'content-type': 'video/mp4' }); fs.createReadStream(file).pipe(res); return;
        }
        if (url.startsWith('/hf/')) {
          if (q.headers.authorization !== 'Key hfid:hfsecret') return json(401, {});
          const sub = url.slice(3);
          if (q.method === 'POST' && sub.startsWith('/minimax/h3/')) {
            fake.hfPosts++;
            if (fake.hfNoCredit) return json(403, { detail: 'Not enough credits' });
            const id = `00000000-0000-0000-0000-${String(reqs.length + 1).padStart(12, '0')}`;
            reqs.push({ id, on: 'hf', state: fake.startState, cancels: 0 });
            return json(200, { status: 'queued', request_id: id, status_url: `${base}/hf/requests/${id}/status`, cancel_url: `${base}/hf/requests/${id}/cancel` });
          }
          const m = /^\/requests\/([0-9a-f-]+)\/(status|cancel)$/.exec(sub);
          const r = m ? reqs.find(x => x.id === m[1] && x.on === 'hf') : undefined;
          if (!r) return json(404, { detail: 'Not found' });
          if (m![2] === 'cancel') { r.cancels++; if (fake.honourCancel) r.state = 'canceled'; return json(fake.honourCancel ? 202 : 400, {}); }
          return json(200, { status: r.state, request_id: r.id, ...(r.state === 'completed' ? { video: { url: `${base}/out.mp4` } } : {}) });
        }
        // Replicate
        if (q.headers.authorization !== 'Bearer r8_swap') return json(401, {});
        const create = /^\/v1\/models\/([^/]+\/[^/]+)\/predictions$/.exec(url);
        if (create && q.method === 'POST') {
          const id = `p${reqs.length + 1}`;
          reqs.push({ id, on: 'rep', state: fake.startState, cancels: 0 });
          return json(201, { id, status: 'starting' });
        }
        const g = /^\/v1\/predictions\/([^/]+?)(\/cancel)?$/.exec(url);
        const r = g ? reqs.find(x => x.id === g[1] && x.on === 'rep') : undefined;
        if (!r) return json(404, { detail: 'Not found' });
        if (g![2]) { r.cancels++; if (fake.honourCancel) r.state = 'canceled'; return json(200, {}); }
        const status = r.state === 'completed' ? 'succeeded' : r.state === 'canceled' ? 'canceled' : 'processing';
        return json(200, { id: r.id, status, ...(status === 'succeeded' ? { output: `${base}/out.mp4`, metrics: { video_output_duration_seconds: 5 } } : {}) });
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (uploads: string, extra: Record<string, string> = {}) => ({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', REPLICATE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated',
    REPLICATE_API_TOKEN: 'r8_swap', REPLICATE_API_URL: `${base}/v1`, HIGGSFIELD_API_URL: `${base}/hf`, HF_CREDENTIALS: 'hfid:hfsecret', UPLOAD_DIR: uploads, ...extra });
  /** A real 3.2 s clip with sound in storage (a Character swap source). */
  const clipOf = async (a: App, owner: any) => {
    const src = path.join(dir, 'swap-src.mp4');
    if (!fs.existsSync(src)) execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=360x640:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '3.2',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', src]);
    const b = '----museswap', meta = JSON.stringify({ name: 'dance', durationSec: 3.2, width: 1080, height: 1920, fps: 30 });
    const payload = Buffer.concat([Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="meta"\r\n\r\n${meta}\r\n`),
      Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="file"; filename="dance.mp4"\r\nContent-Type: video/mp4\r\n\r\n`), fs.readFileSync(src), Buffer.from(`\r\n--${b}--\r\n`)]);
    const r = await a.app.inject({ method: 'POST', url: '/v1/uploads/clips', headers: { authorization: `Bearer ${owner.token}`, 'content-type': `multipart/form-data; boundary=${b}` }, payload });
    expect(r.statusCode).toBe(200);
    return JSON.parse(r.body).id as string;
  };
  const start = async (a: App, owner: any) => {
    const m = await demoModel(owner), clipId = await clipOf(a, owner);
    const r = await owner.req('POST', '/v1/jobs', { modelId: m.id, clipId, engineModel: 'h3-hf', quality: 'hd' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return r.body.id as string;
  };
  const ended = (c: any, id: string, ms = 30_000) => until(async () => {
    const x = (await c.req('GET', '/v1/jobs')).body.find((y: any) => y.id === id); return x && ['done', 'failed'].includes(x.state) ? x : null;
  }, ms);
  const row = async (a: App, id: string) => (await a.ctx.db.select().from(jobs).where(eq(jobs.id, id)))[0]!;
  const saved = async (a: App, id: string) => ((await row(a, id)).stats as any)?.replicate?.takes?.[0];

  it('a deploy mid-render on Higgsfield: the server steps back, the next instance polls the SAME request and saves the take', async () => {
    reset();
    const db = await openDb('pglite://memory'), uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads), { db });
    let b: App | undefined;
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(a, owner);
      await until(async () => (await saved(a, id))?.id ? true : null, 15_000);
      expect((await saved(a, id)).provider).toBe('higgsfield');
      await a.close(); // SIGTERM: what a Railway deploy does (returns at once: no waiting for the render)
      const j = await row(a, id);
      expect(j.state).toBe('running'); // not failed, not cancelled
      expect(reqs).toHaveLength(1);
      expect(reqs[0]!.cancels).toBe(0);
      reqs[0]!.state = 'completed'; // Higgsfield finishes while we were down
      b = await makeApp(env(uploads), { db });
      const done = await ended({ req: client(b, owner.token) }, id);
      expect(done.state, done.error).toBe('done');
      expect(paidStarts()).toBe(1); // never started (or paid) twice
      const settle = (await b.ctx.db.select().from(ledger).where(eq(ledger.jobId, id))).find(x => x.kind === 'settle');
      expect(settle!.amountUsd).toBeGreaterThan(0);
    } finally { await b?.close(); await db.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('a take that moved to Replicate (Higgsfield out of credit) resumes on Replicate after a restart, with no new generation', async () => {
    reset();
    fake.hfNoCredit = true;
    const db = await openDb('pglite://memory'), uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads), { db });
    let b: App | undefined;
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(a, owner);
      await until(async () => (await saved(a, id))?.id ? true : null, 15_000);
      expect(await saved(a, id)).toMatchObject({ provider: 'replicate', id: 'p1' });
      await a.close();
      fake.hfNoCredit = false; // Higgsfield is back: the take must still resume on Replicate, not start again there
      reqs[0]!.state = 'completed';
      b = await makeApp(env(uploads), { db });
      const done = await ended({ req: client(b, owner.token) }, id);
      expect(done.state, done.error).toBe('done');
      expect(paidStarts()).toBe(1);
      expect(reqs[0]!.on).toBe('rep');
      expect(fake.hfPosts).toBe(1); // the refused start only
    } finally { await b?.close(); await db.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('two instances at once (a deploy overlap): the new one leaves a job the old one still runs', async () => {
    reset();
    const db = await openDb('pglite://memory'), uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads), { db });
    let b: App | undefined;
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(a, owner);
      await until(async () => (await saved(a, id))?.id && ((await row(a, id)).stats as any)?.replicateLease?.at ? true : null, 15_000);
      b = await makeApp(env(uploads), { db });
      for (let k = 0; k < 5; k++) { await b.ctx.jobs.tick?.(); await new Promise(r => setTimeout(r, 60)); }
      expect(b.ctx.replicateVideo.busy()).toBe(false);
      expect(a.ctx.replicateVideo.busy()).toBe(true);
      reqs[0]!.state = 'completed';
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      expect(fake.downloads).toBe(1);
      expect(paidStarts()).toBe(1);
    } finally { await a.close(); await b?.close(); await db.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('finished at Higgsfield but not downloadable: an honest failure, an issue for the owner, and recover saves it for free', async () => {
    reset();
    fake.startState = 'completed'; fake.failDownloads = 1000;
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads));
    try {
      const { owner, members } = await people(a, 1, { topUp: 100 });
      const id = await start(a, owner);
      const failed = await ended(owner, id);
      expect(failed.state).toBe('failed');
      expect(failed.error).toBe(PAID_UNSAVED);
      expect(failed.error).not.toMatch(/weren't charged/);
      expect(failed.errorCode).toBe('provider_paid_unsaved');
      expect(fake.downloads).toBe(3); // tried again before giving up
      const issues = (await owner.req('GET', '/v1/claude/issues')).body.issues as any[];
      expect(issues.some(i => i.severity === 'high' && i.summary.includes(id) && /job_recover/.test(i.summary))).toBe(true);
      expect((await members[0]!.req('POST', `/v1/jobs/${id}/recover`)).status).toBe(403);
      fake.failDownloads = 0;
      const r = await owner.req('POST', `/v1/jobs/${id}/recover`);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body).toMatchObject({ state: 'recovering', provider: ['succeeded'] });
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      expect(paidStarts()).toBe(1); // no new generation
      const settle = (await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, id))).filter(x => x.kind === 'settle').at(-1);
      expect(settle!.note).toMatch(/recovered/);
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('our timeout: a cancel Higgsfield confirms is "not charged" (and not recoverable); a render it finishes anyway is saved; one it never answers fails honestly', async () => {
    reset();
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads, { REPLICATE_PREDICTION_TIMEOUT_SEC: '0.3' }));
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(a, owner); // cancel asked past the time, Higgsfield cancels: really not charged
      const t = await ended(owner, id);
      expect(t.state).toBe('failed');
      expect(t.errorCode).toBe('provider_timeout');
      const rr = await owner.req('POST', `/v1/jobs/${id}/recover`);
      expect(rr.status).toBe(400);
      expect(rr.body.error).toMatch(/failed or was cancelled/);

      fake.honourCancel = false;
      const id2 = await start(a, owner);
      await until(async () => reqs[1]?.cancels ? true : null, 15_000);
      reqs[1]!.state = 'completed';
      const done = await ended(owner, id2);
      expect(done.state, done.error).toBe('done');

      const id3 = await start(a, owner); // never answers: after the grace it fails as "may still charge"
      const failed = await ended(owner, id3);
      expect(failed.state).toBe('failed');
      expect(failed.error).toBe(PAID_UNCONFIRMED);
      expect(failed.errorCode).toBe('provider_unconfirmed');
      expect(paidStarts()).toBe(3);
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it("putting the clip's sound back fails (e.g. ffmpeg killed): the take is kept as Higgsfield made it", async () => {
    reset();
    fake.startState = 'completed';
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const wrap = path.join(dir, 'ffmpeg-flaky.sh');
    fs.writeFileSync(wrap, '#!/bin/sh\ncase "$*" in *"1:a:0"*) exit 137;; esac\nexec ffmpeg "$@"\n', { mode: 0o755 });
    const a = await makeApp(env(uploads, { FFMPEG_PATH: wrap }));
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(a, owner);
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      const notes = ((await row(a, id)).stats as any)?.replicate?.finished as string[];
      expect(notes.some(x => /skipped \(kept as the provider made it\)/.test(x))).toBe(true);
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });
});
