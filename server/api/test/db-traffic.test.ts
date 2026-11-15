// Database traffic (the "traffic diet", 2026-11-15): the background loops and hot routes read only what they use. Every
// SQL statement is recorded from an embedded Postgres, so each test can see what a pass or a route asked for.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { eq } from 'drizzle-orm';
import { MIGRATIONS_DIR, type Db, type DbHandle } from '../src/db/client.js';
import { jobs, pods, users } from '../src/db/schema.js';
import * as M from '../src/editor/model.js';
import { editSessionsOf } from '../src/editor/sessions.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type A = Awaited<ReturnType<typeof makeApp>>;

/** PGlite with every statement it runs kept in `log`. */
async function loggedDb(): Promise<DbHandle & { log: string[] }> {
  const { PGlite } = await import('@electric-sql/pglite');
  const { drizzle } = await import('drizzle-orm/pglite');
  const { migrate } = await import('drizzle-orm/pglite/migrator');
  const client = new PGlite();
  const log: string[] = [];
  const query = client.query.bind(client);
  (client as unknown as { query: typeof client.query }).query = ((q: string, ...rest: unknown[]) => { log.push(q); return (query as any)(q, ...rest); }) as typeof client.query;
  const db = drizzle(client);
  await migrate(db, { migrationsFolder: MIGRATIONS_DIR });
  return { db: db as unknown as Db, close: () => client.close(), kind: 'pglite', log };
}
const mentions = (log: string[], table: string) => log.filter(q => q.includes(`"${table}"`));

describe('dispatcher pass', () => {
  let a: A, h: Awaited<ReturnType<typeof loggedDb>>;
  // A long DISPATCH_MS: only the passes the test runs.
  beforeAll(async () => { h = await loggedDb(); a = await makeApp({ DISPATCH_MS: '600000', IDLE_POLL_SECONDS: '600' }, { db: h }); });
  afterAll(async () => { await a.close(); await h.close(); });

  it('with nothing running: the pods table is read once, no job column it never uses is read, and it goes quiet', async () => {
    await a.ctx.jobs.tick();
    h.log.length = 0;
    await a.ctx.jobs.tick();
    const podReads = mentions(h.log, 'pods').filter(q => /^select/i.test(q.trim()));
    expect(podReads).toHaveLength(1);
    const jobReads = mentions(h.log, 'jobs').filter(q => /^select/i.test(q.trim()));
    for (const q of jobReads) for (const col of ['draft', 'outputs', 'prompt', 'thumb']) expect(q, q).not.toContain(`"${col}"`);
    // The Suite and Replicate orphan checks read the id and the lease only.
    expect(jobReads.filter(q => q.includes('"stats"')).every(q => q.includes('#>'))).toBe(true);
    expect(a.ctx.jobs.pollMode()).toBe('quiet');
  });

  it('only hosted provider runs busy: the slower hosted pace; a pod up: the fast pace', async () => {
    const busy = vi.spyOn(a.ctx.replicateVideo, 'busy').mockReturnValue(true);
    try {
      await a.ctx.jobs.tick();
      expect(a.ctx.jobs.pollMode()).toBe('hosted');
      const now = Date.now();
      await a.ctx.db.insert(pods).values({ id: 'pod_t1', studioId: 'st', workerTokenHash: 'x', state: 'running', gpuType: 'NVIDIA H100 80GB HBM3', startedAt: now, readyAt: now, idleSince: now, warmupCharged: true, simulated: true });
      await a.ctx.jobs.tick();
      expect(a.ctx.jobs.pollMode()).toBe('busy');
    } finally {
      busy.mockRestore();
      await a.ctx.db.update(pods).set({ state: 'stopped' }).where(eq(pods.id, 'pod_t1'));
    }
    await a.ctx.jobs.tick();
    expect(a.ctx.jobs.pollMode()).toBe('quiet');
  });
});

describe('job progress', () => {
  let a: A, h: Awaited<ReturnType<typeof loggedDb>>, owner: Client;
  beforeAll(async () => { h = await loggedDb(); a = await makeApp({ DISPATCH_MS: '600000' }, { db: h }); ({ owner } = await people(a, 0)); });
  afterAll(async () => { await a.close(); await h.close(); });

  it('returns no outputs or run state, and the job event is exactly the full row\'s view', async () => {
    const now = Date.now();
    const big = { replicate: { takes: [{ id: 'pr_1', done: false, log: 'x'.repeat(5000) }] }, errorCode: 'kept', suite: { billedSeconds: 3 } };
    const [me] = await a.ctx.db.select({ studioId: users.studioId }).from(users).where(eq(users.id, owner.id));
    await a.ctx.db.insert(jobs).values({ id: 'j_prog', studioId: me!.studioId, userId: owner.id, kind: 'render', title: 'T', modelId: 'm', modelName: 'M',
      request: { engine: 'suite', engineLabel: 'Kling' }, state: 'running', gpuState: 'claimed', cost: 1, seed: 1, createdAt: now, podId: 'suite',
      outputs: [{ name: 'take_1.mp4', key: 'k'.repeat(4000) }], stats: big, draft: { v: 1, tool: 'shot' } as never });
    const emitted: unknown[] = [];
    const spy = vi.spyOn(a.ctx.hub, 'emit').mockImplementation(((_s: string, ev: unknown) => { emitted.push(ev); }) as never);
    h.log.length = 0;
    try { expect(await a.ctx.jobs.progress('j_prog', { progress: 42, phase: 'Rendering' })).toBe(true); } finally { spy.mockRestore(); }
    const upd = h.log.find(q => /^update "jobs"/i.test(q.trim()))!;
    const returning = upd.slice(upd.toLowerCase().indexOf('returning'));
    expect(returning).not.toContain('"outputs"');
    expect(returning).not.toMatch(/(returning |, )"stats"(,|$)/); // the stats column only as its projected keys
    expect(returning).toContain('as "stats"');
    const full = (await a.ctx.db.select().from(jobs).where(eq(jobs.id, 'j_prog')))[0]!;
    expect((emitted[0] as { job: unknown }).job).toEqual(a.ctx.jobs.view(full));
    expect((emitted[0] as { job: { errorCode?: string } }).job.errorCode).toBe('kept');
  });

  it('GET /v1/jobs: the same list, without reading outputs', async () => {
    h.log.length = 0;
    const r = await owner.req('GET', '/v1/jobs');
    expect(r.status).toBe(200);
    const full = await a.ctx.db.select().from(jobs).where(eq(jobs.kind, 'render'));
    expect(r.body).toEqual(JSON.parse(JSON.stringify(full.filter(j => !j.hiddenAt).sort((x, y) => y.createdAt - x.createdAt).map(j => a.ctx.jobs.view(j)))));
    const read = h.log.find(q => /^select/i.test(q.trim()) && q.includes('from "jobs"'))!;
    expect(read).not.toContain('"outputs"');
  });
});

describe('edit sessions', () => {
  let a: A, h: Awaited<ReturnType<typeof loggedDb>>, owner: Client;
  beforeAll(async () => { h = await loggedDb(); a = await makeApp({ DISPATCH_MS: '600000' }, { db: h }); ({ owner } = await people(a, 0)); });
  afterAll(async () => { await a.close(); await h.close(); });

  it('a change sends back no project, patch or inverse; history, presence and the light state route read only what they show', async () => {
    const s = (await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE })).body;
    expect(s.revision).toBe(0);
    h.log.length = 0;
    const r = await owner.req('POST', `/v1/edit-sessions/${s.id}/patch`, { baseRevision: 0, patch: [{ op: 'replace', path: '/canvas/background', value: '#222222' }], label: 'Bg', device: 'mac1' });
    expect(r.status).toBe(200);
    expect(r.body.revision).toBe(1);
    expect(r.body.entry).toMatchObject({ revision: 1, label: 'Bg', author: 'app:mac1', byClaude: false });
    const writes = h.log.filter(q => /^(update|insert)/i.test(q.trim()));
    for (const q of writes) {
      const ret = q.toLowerCase().includes('returning') ? q.slice(q.toLowerCase().indexOf('returning')) : '';
      for (const col of ['project', 'patch', 'inverse']) expect(ret, q).not.toContain(`"${col}"`);
    }

    h.log.length = 0;
    const view = (await owner.req('GET', `/v1/edit-sessions/${s.id}`)).body;
    expect(view.history[0]).toMatchObject({ revision: 1, label: 'Bg' });
    expect(view.project.canvas.background).toBe('#222222');
    expect(h.log.filter(q => q.includes('from "edit_ops"')).every(q => !q.includes('"patch"') && !q.includes('"inverse"'))).toBe(true);

    h.log.length = 0;
    expect((await owner.req('POST', `/v1/edit-sessions/${s.id}/presence`, { device: 'mac1', platform: 'mac' })).status).toBe(200);
    expect(h.log.filter(q => q.includes('"edit_sessions"')).every(q => !q.includes('"project"'))).toBe(true);

    const svc = editSessionsOf(a.ctx);
    const row = (await a.ctx.db.select().from((await import('../src/editor/schema.js')).editSessions))[0]!;
    await svc.askOwner(row, { kind: 'captions', label: 'Captions', estimateUsd: 0.1, args: {} });
    h.log.length = 0;
    const st = await owner.req('GET', `/v1/edit-sessions/${s.id}/state`);
    expect(st.status).toBe(200);
    expect(Object.keys(st.body).sort()).toEqual(['pending', 'revision']);
    expect(st.body.revision).toBe(1);
    expect(st.body.pending).toHaveLength(1);
    expect(st.body.pending[0]).toMatchObject({ kind: 'captions', status: 'waiting' });
    expect(h.log.every(q => !q.includes('"project"'))).toBe(true);
    expect((await owner.req('GET', '/v1/edit-sessions/es_nope/state')).status).toBe(404);
  });

  it('recent: the same sessions in the same order, with projects, reading in full only the ones returned', async () => {
    for (let i = 0; i < 3; i++) await owner.req('POST', '/v1/edit-sessions', { takeId: M.BLANK_SOURCE });
    h.log.length = 0;
    const r = await owner.req('GET', '/v1/edit-sessions?recent=1&limit=2');
    expect(r.status).toBe(200);
    expect(r.body).toHaveLength(2);
    for (const x of r.body) expect(x.project).toBeTruthy();
    expect(r.body[0].lastTouchedAt).toBeGreaterThanOrEqual(r.body[1].lastTouchedAt);
    const fullReads = h.log.filter(q => q.includes('from "edit_sessions"') && q.includes('"project"'));
    expect(fullReads).toHaveLength(1);
    expect(fullReads[0]).toMatch(/in \(\$\d+, \$\d+\)/);
  });
});

describe('post scheduler, simulated posting', () => {
  it('idles between due times instead of reading every tick, and still posts a handed-off post on time', async () => {
    const a = await makeApp({ SOCIAL_MODE: 'simulated', SCHEDULER_MS: '20', IDLE_POLL_SECONDS: '600', GEN_MS: '150' });
    try {
      const tick = vi.spyOn(a.ctx.posts, 'tick');
      await new Promise(r => setTimeout(r, 600)); // ~30 timer ticks
      expect(tick.mock.calls.length).toBeLessThanOrEqual(2);
      const { owner } = await people(a, 0);
      const m = await demoModel(owner);
      const now = Date.now();
      const { takes } = await import('../src/db/schema.js');
      const [me] = await a.ctx.db.select({ studioId: users.studioId }).from(users).where(eq(users.id, owner.id));
      await a.ctx.db.insert(takes).values({ id: 't_post', studioId: me!.studioId, userId: owner.id, kind: 'take', modelId: m.id, index: 1, of: 1, title: 'T', label: 'L', cost: 0, seed: 1, status: 'test', createdAt: now });
      expect((await owner.req('POST', `/v1/models/${m.id}/accounts/tiktok/connect`)).status).toBeLessThan(300);
      const p = await owner.req('POST', '/v1/posts', { modelId: m.id, takeId: 't_post', platforms: ['tiktok'], when: 'now' });
      expect(p.body.state).toBe('handoff');
      const deadline = Date.now() + 3000;
      let state = 'handoff';
      while (Date.now() < deadline && state !== 'posted') {
        await new Promise(r => setTimeout(r, 50));
        state = (await owner.req('GET', '/v1/posts')).body.find((x: { id: string }) => x.id === p.body.id)?.state;
      }
      expect(state).toBe('posted');
    } finally { await a.close(); }
  });
});

describe('Claude stream from the Mac', () => {
  let a: A, h: Awaited<ReturnType<typeof loggedDb>>, owner: Client;
  beforeAll(async () => { h = await loggedDb(); a = await makeApp({ DISPATCH_MS: '600000' }, { db: h }); ({ owner } = await people(a, 0)); });
  afterAll(async () => { await a.close(); await h.close(); });

  it('a running turn\'s event post is one small write; the error cases are unchanged', async () => {
    await owner.req('POST', '/v1/claude/mac/heartbeat', { claudeCode: { installed: true, signedIn: true, version: '2.1.300 (Claude Code)', model: 'm' } });
    const t = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'edit', contextId: 'es_1' })).body;
    const t2 = (await owner.req('POST', '/v1/claude/threads', { contextKind: 'edit', contextId: 'es_2' })).body;
    const sent = await owner.req('POST', `/v1/claude/threads/${t.id}/messages`, { text: 'hi' });
    const turnId = sent.body.turn.id;
    expect((await owner.req('POST', `/v1/claude/turns/${turnId}/claim`)).body.state).toBe('running');
    h.log.length = 0;
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId, events: [{ type: 'text', delta: 'Hel' }] })).body).toEqual({ ok: true });
    const touched = h.log.filter(q => q.includes('"claude_turns"') || q.includes('"claude_threads"'));
    expect(touched).toHaveLength(1);
    expect(touched[0]).toMatch(/^update "claude_turns"/);
    expect((await owner.req('POST', `/v1/claude/threads/${t2.id}/events`, { turnId, events: [{ type: 'text', delta: 'x' }] })).status).toBe(400);
    expect((await owner.req('POST', `/v1/claude/threads/ct_nope/events`, { turnId, events: [{ type: 'text', delta: 'x' }] })).status).toBe(404);
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId: 'tu_nope', events: [{ type: 'text', delta: 'x' }] })).status).toBe(410);
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId, events: [{ type: 'done', ok: true }] })).body).toEqual({ ok: true });
    expect((await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { turnId, events: [{ type: 'text', delta: 'x' }] })).body.code).toBe('turn_expired');
  });
});
