// AI suite · a paid provider job must survive a deploy or restart (owner report 2026-11-11: a 13 s H3 shot on
// Higgsfield was charged there and lost here). Against a FAKE Higgsfield (no money): the server is stopped mid-render
// and a new instance resumes the saved request id; two instances overlapping (a deploy) don't both run it; a result we
// can't download fails honestly and job_recover brings it back without a new generation; finishing that fails keeps the
// video as made; our timeout never throws away a render the provider finished anyway.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { jobs, ledger } from '../src/db/schema.js';
import { openDb } from '../src/db/client.js';
import { PAID_UNCONFIRMED, PAID_UNSAVED } from '../src/suite/runner.js';
import { client, demoModel, makeApp, people, until } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();

describe.skipIf(!hasFfmpeg)('AI suite · Higgsfield job across a restart (FAKE Higgsfield, no money)', () => {
  let server: http.Server, dir: string, base = '';
  type Req = { id: string; state: 'in_progress' | 'completed' | 'canceled'; cancels: number };
  const reqs: Req[] = [];
  const fake = { downloads: 0, failDownloads: 0, startState: 'in_progress' as Req['state'], honourCancel: true };
  const reset = () => { reqs.length = 0; Object.assign(fake, { downloads: 0, failDownloads: 0, startState: 'in_progress', honourCancel: true }); };
  beforeAll(async () => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-hf-restart-'));
    const file = path.join(dir, 'out.mp4');
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=288x512:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', file]);
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
        if (!url.startsWith('/hf/') || q.headers.authorization !== 'Key hfid:hfsecret') return json(401, {});
        const sub = url.slice(3);
        if (q.method === 'POST' && sub.startsWith('/minimax/h3/')) {
          const id = `00000000-0000-0000-0000-${String(reqs.length + 1).padStart(12, '0')}`;
          reqs.push({ id, state: fake.startState, cancels: 0 });
          return json(200, { status: 'queued', request_id: id, status_url: `${base}/hf/requests/${id}/status`, cancel_url: `${base}/hf/requests/${id}/cancel` });
        }
        const m = /^\/requests\/([0-9a-f-]+)\/(status|cancel)$/.exec(sub);
        const r = m ? reqs.find(x => x.id === m[1]) : undefined;
        if (!r) return json(404, { detail: 'Not found' });
        if (m![2] === 'cancel') { r.cancels++; if (fake.honourCancel) r.state = 'canceled'; return json(fake.honourCancel ? 202 : 400, {}); }
        return json(200, { status: r.state, request_id: r.id, ...(r.state === 'completed' ? { video: { url: `${base}/out.mp4` } } : {}) });
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); fs.rmSync(dir, { recursive: true, force: true }); });

  const env = (uploads: string, extra: Record<string, string> = {}) => ({ SUITE_MODE: 'live', SUITE_POLL_MS: '10', IMAGE_PROVIDER: 'simulated',
    REPLICATE_API_TOKEN: 'r8_unused', REPLICATE_API_URL: `${base}/nope`, HIGGSFIELD_API_URL: `${base}/hf`, HF_CREDENTIALS: 'hfid:hfsecret', UPLOAD_DIR: uploads, ...extra });
  const start = async (owner: any) => {
    const m = await demoModel(owner);
    const r = (await owner.req('POST', '/v1/suite/shots', { modelId: m.id, prompt: 'She turns to the camera.', duration: 6, quality: 'hd', camera: { preset: 'talking_head' } })).body;
    expect(r.id, JSON.stringify(r)).toBeTruthy();
    return r.id as string;
  };
  const ended = (c: any, id: string, ms = 20_000) => until(async () => {
    const x = (await c.req('GET', `/v1/suite/shots/${id}`)).body.job; return x?.state === 'done' || x?.state === 'failed' ? x : null;
  }, ms);
  const row = async (a: any, id: string) => (await a.ctx.db.select().from(jobs).where(eq(jobs.id, id)))[0]!;

  it('a deploy mid-render: the server steps back, the next instance polls the SAME request and saves the take', async () => {
    reset();
    const db = await openDb('pglite://memory'), uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads), { db });
    let b: Awaited<ReturnType<typeof makeApp>> | undefined;
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(owner);
      await until(async () => ((await row(a, id)).stats as any)?.suite?.takes?.[0]?.id ? true : null, 10_000);
      await a.close(); // SIGTERM: what a Railway deploy does
      const j = await row(a, id);
      expect(j.state).toBe('running'); // not failed, not cancelled
      expect(reqs).toHaveLength(1);
      expect(reqs[0]!.cancels).toBe(0);
      reqs[0]!.state = 'completed'; // Higgsfield finishes while we were down
      b = await makeApp(env(uploads), { db });
      const done = await ended({ req: client(b, owner.token) }, id);
      expect(done.state, done.error).toBe('done');
      expect(reqs).toHaveLength(1); // never started (or paid) twice
      const settle = (await b.ctx.db.select().from(ledger).where(eq(ledger.jobId, id))).find(x => x.kind === 'settle');
      expect(settle!.amountUsd).toBeGreaterThan(0);
    } finally { await b?.close(); await db.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('two instances at once (a deploy overlap): the new one leaves a job the old one still runs', async () => {
    reset();
    const db = await openDb('pglite://memory'), uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads), { db });
    let b: Awaited<ReturnType<typeof makeApp>> | undefined;
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(owner);
      await until(async () => ((await row(a, id)).stats as any)?.suite?.lease?.at ? true : null, 10_000);
      b = await makeApp(env(uploads), { db });
      for (let k = 0; k < 5; k++) { await b.ctx.jobs.tick?.(); await new Promise(r => setTimeout(r, 60)); }
      expect(b.ctx.suite.runner.busy()).toBe(false);
      expect(a.ctx.suite.runner.busy()).toBe(true);
      reqs[0]!.state = 'completed';
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      expect(fake.downloads).toBe(1);
      expect(reqs).toHaveLength(1);
    } finally { await a.close(); await b?.close(); await db.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('finished at Higgsfield but not downloadable: an honest failure, an issue for the owner, and job_recover saves it for free', async () => {
    reset();
    fake.startState = 'completed'; fake.failDownloads = 1000;
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads));
    try {
      const { owner, members } = await people(a, 1, { topUp: 100 });
      const id = await start(owner);
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
      expect(reqs).toHaveLength(1); // no new generation
      const take = (await owner.req('GET', '/v1/takes')).body;
      expect(JSON.stringify(take)).toContain(id);
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('recover refuses when the provider says the render failed or nothing was saved', async () => {
    reset();
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads, { SUITE_PREDICTION_TIMEOUT_SEC: '0.05' }));
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(owner); // in progress past the time: cancel asked, Higgsfield cancels
      const failed = await ended(owner, id);
      expect(failed.state).toBe('failed');
      expect(failed.errorCode).toBe('provider_timeout'); // cancelled at the provider: really not charged
      const r = await owner.req('POST', `/v1/jobs/${id}/recover`);
      expect(r.status).toBe(400);
      expect(r.body.error).toMatch(/failed or was cancelled/);
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('our timeout: a render Higgsfield finishes anyway is saved; one it never answers fails honestly', async () => {
    reset();
    fake.honourCancel = false;
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads, { SUITE_PREDICTION_TIMEOUT_SEC: '0.3' }));
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(owner);
      await until(async () => reqs[0]?.cancels ? true : null, 10_000);
      reqs[0]!.state = 'completed';
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      const id2 = await start(owner); // never answers: after the grace it fails as "may still charge"
      const failed = await ended(owner, id2);
      expect(failed.state).toBe('failed');
      expect(failed.error).toBe(PAID_UNCONFIRMED);
      expect(failed.errorCode).toBe('provider_unconfirmed');
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('finishing that fails (e.g. ffmpeg killed) keeps the video as Higgsfield made it instead of failing the job', async () => {
    reset();
    fake.startState = 'completed';
    const uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const wrap = path.join(dir, 'ffmpeg-flaky.sh');
    fs.writeFileSync(wrap, '#!/bin/sh\ncase "$*" in *loudnorm*) exit 137;; esac\nexec ffmpeg "$@"\n', { mode: 0o755 });
    const a = await makeApp(env(uploads, { FFMPEG_PATH: wrap }));
    try {
      const { owner } = await people(a, 0, { topUp: 100 });
      const id = await start(owner);
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      const notes = ((await row(a, id)).stats as any)?.suite?.finished as string[];
      expect(notes.some(x => /skipped \(kept as the provider made it\)/.test(x))).toBe(true);
    } finally { await a.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });
});
