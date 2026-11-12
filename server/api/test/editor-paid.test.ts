// Edit helpers on a paid provider (Genjutsu on a FAKE Higgsfield, no money): a deploy mid-render resumes the SAME
// request on the next instance (never a new paid start); a result made but not downloadable fails honestly
// (provider_paid_unsaved, not "try again") and the owner recovers it for free; a cancel that arrives after the
// result was made keeps it.
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { takes, users } from '../src/db/schema.js';
import { openDb } from '../src/db/client.js';
import { editorAi } from '../src/editor/service.js';
import { editorJobs } from '../src/editor/schema.js';
import { PAID_UNSAVED } from '../src/services/paidLost.js';
import { client, makeApp, people, until } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;

describe('Edit helpers on Higgsfield across a restart (FAKE Higgsfield, no money)', () => {
  let server: http.Server, base = '';
  type Req = { id: string; state: 'in_progress' | 'completed' | 'canceled' };
  const reqs: Req[] = [];
  const fake = { failDownloads: 0, downloads: 0, startState: 'in_progress' as Req['state'], holdDownload: false };
  const reset = () => { reqs.length = 0; Object.assign(fake, { failDownloads: 0, downloads: 0, startState: 'in_progress', holdDownload: false }); };
  let release: (() => void) | null = null;
  beforeAll(async () => {
    server = http.createServer((q, res) => {
      q.resume();
      q.on('end', () => {
        const url = q.url ?? '';
        const json = (s: number, o: unknown) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
        if (url === '/out.mp4') {
          fake.downloads++;
          if (fake.failDownloads > 0) { fake.failDownloads--; return json(500, {}); }
          const send = () => { res.writeHead(200, { 'content-type': 'video/mp4' }); res.end(Buffer.alloc(2048, 7)); };
          if (fake.holdDownload) { release = send; return; }
          return send();
        }
        if (!url.startsWith('/hf/')) return json(404, {});
        const sub = url.slice(3);
        if (q.method === 'POST' && sub.startsWith('/higgsfield/genjutsu/')) {
          const id = `00000000-0000-0000-0000-${String(reqs.length + 1).padStart(12, '0')}`;
          reqs.push({ id, state: fake.startState });
          return json(200, { status: 'queued', request_id: id, status_url: `${base}/hf/requests/${id}/status`, cancel_url: `${base}/hf/requests/${id}/cancel` });
        }
        const m = /^\/requests\/([0-9a-f-]+)\/(status|cancel)$/.exec(sub);
        const r = m ? reqs.find(x => x.id === m[1]) : undefined;
        if (!r) return json(404, {});
        if (m![2] === 'cancel') return json(400, {}); // Higgsfield can't stop a running request
        return json(200, { status: r.state, request_id: r.id, ...(r.state === 'completed' ? { video: { url: `${base}/out.mp4` } } : {}) });
      });
    });
    await new Promise<void>(r => server.listen(0, '127.0.0.1', r));
    base = `http://127.0.0.1:${(server.address() as any).port}`;
  });
  afterAll(() => { server?.close(); });

  const env = (uploads: string) => ({ SUITE_MODE: 'live', IMAGE_PROVIDER: 'simulated', HIGGSFIELD_API_URL: `${base}/hf`, HF_CREDENTIALS: 'hfid:hfsecret', UPLOAD_DIR: uploads });
  const setup = async (a: App) => {
    const { owner, members } = await people(a, 1, { topUp: 100 });
    const [me] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    await a.ctx.db.insert(takes).values({ id: `take_${Math.random().toString(36).slice(2, 8)}`, studioId: me!.studioId, userId: null, kind: 'take', jobId: null, modelId: null, index: 1, of: 1, title: 'v', label: '',
      engineLabel: '', cost: 0, seed: 0, status: 'final', thumb: null, prompt: '', mediaKey: 'c/gj.mp4', media: { durationSec: 6.2, width: 1080, height: 1920, contentType: 'video/mp4' }, createdAt: Date.now() }).returning()
      .then(([t]) => { (owner as any).takeId = t!.id; });
    expect((await owner.req('PATCH', '/v1/editor/settings', { capPerDayUsd: 50 })).status).toBe(200);
    return { owner, member: members[0]! };
  };
  const start = async (owner: any) => {
    const j = (await owner.req('POST', '/v1/editor/jobs', { kind: 'objectswap', source: { takeId: owner.takeId }, options: { images: [{ url: 'https://example.com/bag.jpg' }] } })).body;
    expect(j.id, JSON.stringify(j)).toBeTruthy();
    return j.id as string;
  };
  const ended = (c: any, id: string) => until(async () => { const x = (await c.req('GET', `/v1/editor/jobs/${id}`)).body; return x.state !== 'running' ? x : null; }, 30_000);
  const fast = (a: App) => { editorAi(a.ctx).genjutsuPollMs = 10; };

  it('a deploy mid-render: the next instance polls the SAME request and saves the result', async () => {
    reset();
    const db = await openDb('pglite://memory'), uploads = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'));
    const a = await makeApp(env(uploads), { db });
    fast(a);
    let b: App | undefined;
    try {
      const { owner } = await setup(a);
      const id = await start(owner);
      await until(async () => (await db.db.select().from(editorJobs).where(eq(editorJobs.id, id)))[0]?.predictionId ? true : null, 10_000);
      await a.close();
      b = await makeApp(env(uploads), { db }); // its startup resumes the saved request
      fast(b);
      await until(async () => ((await db.db.select().from(editorJobs).where(eq(editorJobs.id, id)))[0]?.options as any)?.runner ? true : null, 10_000);
      reqs[0]!.state = 'completed';
      const done = await ended({ req: client(b, owner.token) }, id);
      expect(done.state, done.error).toBe('done');
      expect(reqs).toHaveLength(1); // never started (or paid) twice
      expect(done.costUsd).toBeGreaterThan(0);
    } finally { await b?.close(); await db.close(); fs.rmSync(uploads, { recursive: true, force: true }); }
  });

  it('made but not downloadable: an honest failure, and the owner (only) recovers it for free', async () => {
    reset();
    fake.startState = 'completed'; fake.failDownloads = 1000;
    const a = await makeApp(env(fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'))));
    fast(a);
    try {
      const { owner, member } = await setup(a);
      const id = await start(owner);
      const failed = await ended(owner, id);
      expect(failed.state).toBe('failed');
      expect(failed.error).toBe(PAID_UNSAVED);
      expect(failed).toMatchObject({ errorCode: 'provider_paid_unsaved', recoverable: true });
      expect(failed.options.runner).toBeUndefined();
      expect(fake.downloads).toBe(3);
      expect((await member.req('POST', `/v1/jobs/${id}/recover`)).status).toBe(403);
      fake.failDownloads = 0;
      const r = await owner.req('POST', `/v1/jobs/${id}/recover`);
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body).toMatchObject({ state: 'recovering' });
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
      expect(reqs).toHaveLength(1); // no new generation
    } finally { await a.close(); }
  });

  it('a cancel that arrives after Higgsfield made the result keeps it', async () => {
    reset();
    fake.startState = 'completed'; fake.holdDownload = true;
    const a = await makeApp(env(fs.mkdtempSync(path.join(os.tmpdir(), 'muse-up-'))));
    fast(a);
    try {
      const { owner } = await setup(a);
      const id = await start(owner);
      await until(async () => (release ? true : null), 10_000); // downloading: made and billed
      expect((await owner.req('DELETE', `/v1/editor/jobs/${id}`)).body.state).toBe('cancelling');
      release!(); release = null;
      const done = await ended(owner, id);
      expect(done.state, done.error).toBe('done');
    } finally { await a.close(); }
  });
});
