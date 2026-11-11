// Deletes and dismisses stick across a restart (owner bugs 2026-11-11): every check here deletes or hides something,
// stops the server, starts a NEW server on the same database (as a Railway deploy does) and looks again.
// - Starter templates the owner deleted came back on every start (the boot seed re-added any missing slug).
// - Failed jobs dismissed on the Queue came back (the Mac only hid them in memory); Dismiss and "Clear all failed" now
//   store hiddenAt on the job, for every kind (video, photo, Suite shot).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { client, makeApp, people, type Client } from './helpers.js';
import { openDb, type DbHandle } from '../src/db/client.js';
import { jobs, studioSeeds, templates } from '../src/db/schema.js';
import { STARTERS } from '../src/templates/starters.js';

const ENV = { DEV_MODE: 'true', BALANCE_MODE: 'simulated', SIM_START_BALANCE: '50' };
type A = Awaited<ReturnType<typeof makeApp>>;

describe('deletes survive a restart', () => {
  let dbh: DbHandle, a: A, owner: Client, member: Client;
  /** Stop this server and start a fresh one on the same database; the clients keep their sessions. */
  const restart = async () => {
    await a.close();
    a = await makeApp(ENV, { db: dbh });
    owner = { ...owner, req: client(a, owner.token) };
    member = { ...member, req: client(a, member.token) };
  };
  beforeAll(async () => {
    dbh = await openDb('pglite://memory');
    a = await makeApp(ENV, { db: dbh });
    const p = await people(a, 1); owner = p.owner; member = p.members[0]!;
  });
  afterAll(async () => { await a.close(); await dbh.close(); });

  const slugs = async (c: Client) => ((await c.req('GET', '/v1/templates')).body as any[]).filter(t => t.starter).map(t => t.starter).sort();

  it('a deleted starter template is not re-added on the next start, nor by later lists', async () => {
    expect(await slugs(owner)).toEqual(STARTERS.map(s => s.slug).sort());
    const mine = (await owner.req('POST', '/v1/templates', { name: 'Bed Profile', tags: [], layers: { scene: 'bed', afterEffects: { grade: 'mono' } } })).body;
    expect(mine.id).toBeTruthy();
    const all = (await owner.req('GET', '/v1/templates?scope=mine')).body as any[];
    for (const slug of ['mirror-selfie', 'candid-pov']) {
      expect((await owner.req('DELETE', `/v1/templates/${all.find(t => t.starter === slug).id}`)).status).toBe(204);
    }
    const left = STARTERS.map(s => s.slug).filter(s => s !== 'mirror-selfie' && s !== 'candid-pov').sort();
    await restart();
    expect(a.ctx.boot.starters).toEqual({ studios: 1, added: 0 });
    expect(await slugs(owner)).toEqual(left);
    expect(await slugs(member)).toEqual(left);
    await restart();
    expect(await slugs(owner)).toEqual(left);
    expect(((await owner.req('GET', '/v1/templates?scope=mine')).body as any[]).some(t => t.id === mine.id)).toBe(true); // hers stays
  });

  it('a studio seeded before the record existed: its missing starters count as deleted, not as new', async () => {
    const sid = (await a.ctx.db.select().from(templates).limit(1))[0]!.studioId;
    await a.ctx.db.delete(studioSeeds).where(eq(studioSeeds.studioId, sid)); // as on prod before this fix
    await restart();
    expect(a.ctx.boot.starters).toEqual({ studios: 1, added: 0 });
    expect(await slugs(owner)).not.toContain('mirror-selfie');
    const rec = await a.ctx.db.select().from(studioSeeds).where(eq(studioSeeds.studioId, sid));
    expect(rec.map(r => r.slug).sort()).toEqual(STARTERS.map(s => s.slug).sort());
  });

  it('a brand-new studio still gets the whole starter pack once', async () => {
    const sid = (await a.ctx.db.select().from(templates).limit(1))[0]!.studioId;
    await a.ctx.db.delete(studioSeeds).where(eq(studioSeeds.studioId, sid));
    await a.ctx.db.delete(templates).where(eq(templates.studioId, sid));
    await restart();
    expect(a.ctx.boot.starters).toEqual({ studios: 1, added: STARTERS.length });
    await restart();
    expect(a.ctx.boot.starters).toEqual({ studios: 1, added: 0 });
  });

  // ------------------------------------------------------------------ failed jobs
  const failed = async (id: string, userId: string, request: Record<string, unknown>, state: 'failed' | 'running' = 'failed') => {
    const sid = (await a.ctx.db.select().from(templates).limit(1))[0]!.studioId;
    await a.ctx.db.insert(jobs).values({ id, studioId: sid, userId, kind: 'render', title: id, modelId: '', modelName: '', request, state, cost: 0.67,
      refunded: state === 'failed' ? 0.67 : 0, error: state === 'failed' ? 'This clip was refused by the content filter · you weren\'t charged' : null,
      prompt: '', seed: 0, createdAt: Date.now() } as never);
  };
  const listed = async () => ((await owner.req('GET', '/v1/jobs')).body as any[]).map(j => j.id).sort();

  it('Dismiss hides a failed job of every kind for good; a dismissed photo run cut off by the restart stays hidden', async () => {
    await failed('j_video', owner.id, { engine: 'replicate', title: 'ZELPHIRA SUBJECT', takes: 1 });
    await failed('j_shot', owner.id, { engine: 'suite', tool: 'shot', takes: 1 });
    await failed('j_photo', owner.id, { engine: 'photo', tool: 'photo', takes: 2, count: 2 }, 'running');
    expect(await listed()).toEqual(['j_photo', 'j_shot', 'j_video']);
    for (const id of ['j_video', 'j_shot', 'j_photo']) expect((await owner.req('DELETE', `/v1/jobs/${id}`)).status).toBe(204);
    expect(await listed()).toEqual([]);
    await restart(); // the boot marks the cut-off photo run failed ("Interrupted · try again"); it must not un-hide it
    expect(await listed()).toEqual([]);
    const [photo] = await a.ctx.db.select().from(jobs).where(eq(jobs.id, 'j_photo'));
    expect(photo!.state).toBe('failed');
    expect(photo!.hiddenAt).not.toBeNull();
  });

  it('Clear all failed: the owner clears the studio, a member only their own; both hold after a restart', async () => {
    await failed('j_m1', member.id, { engine: 'replicate', takes: 1 });
    await failed('j_o1', owner.id, { engine: 'photo', tool: 'photo', takes: 2 });
    await failed('j_o2', owner.id, { engine: 'suite', tool: 'shot', takes: 1 });
    const r = (await member.req('POST', '/v1/jobs/clear-failed')).body;
    expect(r).toEqual({ cleared: 1, ids: ['j_m1'] });
    expect(await listed()).toEqual(['j_o1', 'j_o2']);
    expect((await owner.req('POST', '/v1/jobs/clear-failed')).body.cleared).toBe(2);
    await restart();
    expect(await listed()).toEqual([]);
    expect((await owner.req('POST', '/v1/jobs/clear-failed')).body).toEqual({ cleared: 0, ids: [] });
  });
});
