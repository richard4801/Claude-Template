// Library collections and the Suite queue (workstream 1; plans/ai-suite-design.md "Refinements" 1 and 6). Mock video
// provider: no money.
import { execFileSync } from 'node:child_process';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const hasFfmpeg = (() => { try { execFileSync('ffmpeg', ['-version']); execFileSync('ffprobe', ['-version']); return true; } catch { return false; } })();
const DRAFT = { v: 1, tool: 'shot', quality: 'draft', aspect: '9:16', duration: 5, takes: 1, sound: true };

describe.skipIf(!hasFfmpeg)('Library collections and the Suite queue (mock provider)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, other: Client, model: { id: string };
  const takeIds: string[] = [];
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member, other] } = await people(a, 2, { topUp: 100 }) as any);
    model = await demoModel(owner);
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: member.id, tokens: 2000 });
    // Two photos and a video take to collect.
    const p = (await member.req('POST', '/v1/suite/photos', { modelId: model.id, prompt: 'A café window seat.', count: 2 })).body;
    takeIds.push(...p.takes.map((t: any) => t.id));
    const s = (await member.req('POST', '/v1/suite/shots', { modelId: model.id, prompt: 'She walks out to the street.', duration: 5, quality: 'draft', draft: DRAFT })).body;
    const j = await until(async () => { const x = (await member.req('GET', `/v1/suite/shots/${s.id}`)).body.job; return x?.state === 'done' ? x : null; }, 20_000);
    takeIds.push(...(await member.req('GET', '/v1/takes')).body.filter((t: any) => t.jobId === j.id).map((t: any) => t.id));
  });
  afterAll(async () => { await a?.close(); });

  it('collections: make, fill, rename, list in the feed; the studio sees them, only the maker or the owner changes them', async () => {
    expect(takeIds).toHaveLength(3);
    const c = await member.req('POST', '/v1/library/collections', { name: '  Summer drop  ', takeIds: [takeIds[0]] });
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body).toMatchObject({ name: 'Summer drop', mine: true, canEdit: true, count: 1, takeIds: [takeIds[0]] });
    expect(c.body.cover).toBeTruthy();
    const id = c.body.id;
    const add = (await member.req('POST', `/v1/library/collections/${id}/items`, { takeIds: [takeIds[1], takeIds[2], takeIds[1]] })).body;
    expect(add.count).toBe(3);
    expect((await member.req('POST', `/v1/library/collections/${id}/items`, { takeIds: [takeIds[0]] })).body.count).toBe(3); // once each
    // Everyone in the studio sees it; another member can't change it, the owner can.
    const seen = (await other.req('GET', '/v1/library/collections')).body;
    expect(seen.find((x: any) => x.id === id)).toMatchObject({ name: 'Summer drop', mine: false, canEdit: false, count: 3 });
    expect((await other.req('PATCH', `/v1/library/collections/${id}`, { name: 'Mine now' })).body.code).toBe('not_yours');
    expect((await other.req('POST', `/v1/library/collections/${id}/items/remove`, { takeIds: [takeIds[0]] })).status).toBe(403);
    expect((await owner.req('PATCH', `/v1/library/collections/${id}`, { name: 'Summer drop · final' })).body.name).toBe('Summer drop · final');
    // The feed lists only the collection's takes and photos, nothing pending.
    const f = (await other.req('GET', `/v1/suite/feed?collection=${id}`)).body;
    expect(f.items.map((x: any) => x.id).sort()).toEqual([...takeIds].sort());
    expect(f.queued).toBeUndefined();
    const left = (await member.req('POST', `/v1/library/collections/${id}/items/remove`, { takeIds: [takeIds[0]] })).body;
    expect(left.takeIds.sort()).toEqual([takeIds[1], takeIds[2]].sort());
    expect((await member.req('GET', `/v1/library/takes/${takeIds[1]}/collections`)).body.map((x: any) => x.id)).toEqual([id]);
    // Checks: names, unknown takes, unknown collections.
    expect((await member.req('POST', '/v1/library/collections', { name: '   ' })).status).toBe(400);
    expect((await member.req('POST', `/v1/library/collections/${id}/items`, { takeIds: ['nope'] })).body.error).toMatch(/takeIds: no take or photo nope/);
    expect((await member.req('GET', '/v1/library/collections/col_nope')).status).toBe(404);
    expect((await member.req('GET', '/v1/suite/feed?collection=col_nope')).status).toBe(400);
    // Deleting the collection leaves the takes in the library.
    expect((await member.req('DELETE', `/v1/library/collections/${id}`)).status).toBe(204);
    expect((await member.req('GET', '/v1/library/collections')).body.some((x: any) => x.id === id)).toBe(false);
    expect((await member.req('GET', '/v1/takes')).body.filter((t: any) => takeIds.includes(t.id))).toHaveLength(3);
  });

  it('the queue: saved with its price and nothing held; on top of the feed; run through the normal path, or discarded', async () => {
    const wallet = async () => (await member.req('GET', '/v1/wallet')).body;
    const before = await wallet();
    const body = { modelId: model.id, prompt: 'She turns to camera and smiles.', duration: 5, quality: 'draft', draft: DRAFT };
    const q = await member.req('POST', '/v1/suite/queue', { ...body, queue: true });
    expect(q.status, JSON.stringify(q.body)).toBe(200);
    expect(q.body).toMatchObject({ kind: 'queued', tool: 'shot', title: 'She turns to camera and smiles.', mine: true, draft: DRAFT });
    expect(q.body.estimate).toBeGreaterThan(0);
    expect(q.body.buttonLabel).toBe(`Run · $${q.body.estimate.toFixed(2)}`);
    expect((await wallet()).heldTokens).toBe(before.heldTokens); // nothing held
    const jobsBefore = (await member.req('GET', '/v1/jobs')).body.length;
    // A bad shot isn't queued.
    expect((await member.req('POST', '/v1/suite/queue', { ...body, draft: { tool: 'hologram' } })).status).toBe(400);
    // Top of the feed's first page; mine only for another member, everyone's for the owner.
    const f = (await member.req('GET', '/v1/suite/feed')).body;
    expect(f.queued.map((x: any) => x.id)).toEqual([q.body.id]);
    expect((await member.req('GET', `/v1/suite/feed?cursor=${encodeURIComponent(f.nextCursor ?? 'x')}`)).body.queued).toBeUndefined();
    expect((await other.req('GET', '/v1/suite/feed')).body.queued).toEqual([]);
    expect((await owner.req('GET', '/v1/suite/queue')).body.map((x: any) => x.id)).toEqual([q.body.id]);
    expect((await other.req('POST', `/v1/suite/queue/${q.body.id}/estimate`, {})).status).toBe(404);
    // Run: today's price first, then confirm; the queued entry becomes an ordinary job.
    const e = (await member.req('POST', `/v1/suite/queue/${q.body.id}/estimate`, {})).body;
    expect(e).toMatchObject({ id: q.body.id, changed: false, estimateView: { ok: true } });
    expect((await member.req('POST', `/v1/suite/queue/${q.body.id}/run`, {})).status).toBe(400); // confirm first
    const r = await member.req('POST', `/v1/suite/queue/${q.body.id}/run`, { confirm: true });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.job).toMatchObject({ state: 'running', draft: DRAFT });
    expect((await member.req('GET', '/v1/jobs')).body.length).toBe(jobsBefore + 1);
    expect((await member.req('GET', '/v1/suite/queue')).body).toEqual([]);
    await until(async () => { const x = (await member.req('GET', `/v1/suite/shots/${r.body.job.id}`)).body.job; return x?.state === 'done' ? x : null; }, 20_000);
    // Discard: gone, nothing charged.
    const d = (await member.req('POST', '/v1/suite/queue', body)).body;
    expect((await member.req('DELETE', `/v1/suite/queue/${d.id}`)).status).toBe(204);
    expect((await member.req('GET', '/v1/suite/queue')).body).toEqual([]);
    expect((await member.req('DELETE', `/v1/suite/queue/${d.id}`)).status).toBe(404);
  });
});
