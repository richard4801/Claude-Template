// Reorder an outfit's pictures (owner 2026-11-12: "the picture in Side is actually the back"; Claude issue ci_cf8c3c8ee924).
// POST /v1/outfits/:id/reorder swaps pictures between the 7 slots (dryRun previews before/after); Claude's outfit_reorder
// previews without confirm and needs the person's Approve; suite_see labels every picture with its slot.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { outfits, users } from '../src/db/schema.js';
import { registryByName } from '../src/claude/registry.js';
import { lookOf } from '../src/suite/vision.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, maker: Client, other: Client, m: { id: string }, studioId: string, ownerU: AuthUser;
const R = (asset: string) => ({ asset });
const row = async (id: string, v: Partial<typeof outfits.$inferInsert> = {}) => {
  await a.ctx.db.insert(outfits).values({ id, studioId, modelId: m.id, name: 'Linen', mode: 'describe', description: '', state: 'ready', createdBy: maker.id, createdAt: Date.now(),
    angles: [R('g_front'), R('g_tq'), R('g_back'), R('g_side')], faces: [R('face'), R('c_face'), null], ...v });
};
const pics = async (id: string) => { const [o] = await a.ctx.db.select().from(outfits).where(eq(outfits.id, id)); return { angles: o!.angles, faces: o!.faces }; };

beforeAll(async () => {
  a = await makeApp({ BALANCE_MODE: 'simulated' });
  ({ owner, members: [maker, other] } = await people(a, 2) as any);
  m = await demoModel(owner);
  studioId = (await a.ctx.db.select().from(users).where(eq(users.id, owner.id)))[0]!.studioId;
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test', sessionId: null };
});
afterAll(async () => { await a?.close(); });

describe('outfit reorder', () => {
  it('swaps side and back; dryRun only previews; across body and face slots; nothing is lost', async () => {
    await row('o_r1');
    const dry = (await owner.req('POST', '/v1/outfits/o_r1/reorder', { moves: [{ from: 'side', to: 'back' }], dryRun: true })).body;
    expect(dry).toMatchObject({ dryRun: true, changed: ['side', 'back'], before: { side: R('g_back'), back: R('g_side') }, after: { side: R('g_side'), back: R('g_back') } });
    expect((await pics('o_r1')).angles[2]).toEqual(R('g_back')); // unchanged
    const done = (await maker.req('POST', '/v1/outfits/o_r1/reorder', { moves: [{ from: 'side', to: 'back' }] })).body;
    expect(done.outfit.angles).toEqual([R('g_front'), R('g_tq'), R('g_side'), R('g_back')]);
    // A face picture in a body slot, and an empty face slot taking a picture.
    await maker.req('POST', '/v1/outfits/o_r1/reorder', { moves: [{ from: 'faceTq', to: 'profile' }] });
    expect((await pics('o_r1')).faces).toEqual([R('face'), null, R('c_face')]);
    const all = Object.values((await owner.req('POST', '/v1/outfits/o_r1/reorder', { moves: [{ from: 'front', to: 'face' }, { from: 'tq', to: 'back' }], dryRun: true })).body.after);
    expect(all.filter(Boolean)).toHaveLength(6); // the same 6 pictures, moved
  });

  it('who may: the owner or the maker; another member 403; another studio 404; bad slots and no-op moves 400; busy 409', async () => {
    await row('o_r2');
    expect((await other.req('POST', '/v1/outfits/o_r2/reorder', { moves: [{ from: 'side', to: 'back' }] })).status).toBe(403);
    await a.ctx.db.insert(outfits).values({ id: 'o_far', studioId: 'st_other', modelId: m.id, name: 'Far', mode: 'own', description: '', state: 'ready', createdAt: Date.now(), angles: [R('g_front'), null, null, null] });
    expect((await owner.req('POST', '/v1/outfits/o_far/reorder', { moves: [{ from: 'side', to: 'back' }] })).status).toBe(404);
    expect((await owner.req('POST', '/v1/outfits/o_r2/reorder', { moves: [{ from: 'left', to: 'back' }] })).status).toBe(400);
    expect((await owner.req('POST', '/v1/outfits/o_r2/reorder', { moves: [{ from: 'side', to: 'side' }] })).status).toBe(400);
    expect((await owner.req('POST', '/v1/outfits/o_r2/reorder', { moves: [] })).status).toBe(400);
    await row('o_r3', { state: 'generating' });
    expect((await owner.req('POST', '/v1/outfits/o_r3/reorder', { moves: [{ from: 'side', to: 'back' }] })).status).toBe(409);
  });

  it('Claude: outfit_reorder previews before and after without confirm, waits for Approve, then runs; suite_see labels the slots', async () => {
    await row('o_r4');
    const t = registryByName.get('outfit_reorder')!;
    expect(t.gate).toBe('settings');
    const env = { ctx: a.ctx, user: ownerU, source: 'chat' } as any;
    const look = await t.run(env, { outfitId: 'o_r4', moves: [{ from: 'side', to: 'back' }] }) as any;
    expect(look.needsConfirmation).toBe(true);
    expect(look.would).toBe('Reorder the outfit\'s pictures: Side ← the picture now in Back; Back ← the picture now in Side');
    expect((await pics('o_r4')).angles[2]).toEqual(R('g_back'));
    const ask = await t.run(env, { outfitId: 'o_r4', moves: [{ from: 'side', to: 'back' }], confirm: true }) as any;
    expect(ask.waitingForApproval).toBe(true);
    expect((await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true })).body.status).toBe('done');
    expect((await pics('o_r4')).angles).toEqual([R('g_front'), R('g_tq'), R('g_side'), R('g_back')]);
    await expect(t.run(env, { outfitId: 'o_r4', moves: [{ from: 'profile', to: 'profile' }] })).rejects.toThrow();
    // suite_see's pictures: each with its slot; the empty face side is listed.
    const seen = await lookOf(a.ctx, ownerU, { outfitId: 'o_r4', outfitFull: true });
    const labels = seen.blocks.filter((b: any) => b.type === 'text').map((b: any) => b.text);
    expect(labels.some((l: string) => / · slot side \(side\)$/.test(l))).toBe(true);
    expect(labels.some((l: string) => / · slot faceTq \(face ¾\)$/.test(l))).toBe(true);
    expect((seen.meta.outfit as any).emptySlots).toEqual(['profile']);
  });
});
