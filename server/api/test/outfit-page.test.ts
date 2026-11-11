// Outfit page (plans/outfit-head-looks.md §4/§5): rename (PATCH), name on save, delete (DELETE) and making the missing
// angles (POST fill): who may, studio scope, name length, refused while the outfit is still being made.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { outfits, users } from '../src/db/schema.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

describe('outfit page · rename, delete, fill', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, maker: Client, other: Client, m: { id: string }, studioId: string;
  const row = async (id: string, v: Partial<typeof outfits.$inferInsert> = {}) => {
    await a.ctx.db.insert(outfits).values({ id, studioId, modelId: m.id, name: 'Set', mode: 'photo', description: '', state: 'ready', createdBy: maker.id, createdAt: Date.now(),
      angles: [{ asset: 'g_front' }, { asset: 'g_tq' }, { asset: 'g_side' }, { asset: 'g_back' }], ...v });
  };
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'simulated' });
    ({ owner, members: [maker, other] } = await people(a, 2) as any);
    m = await demoModel(owner);
    studioId = (await a.ctx.db.select().from(users).where(eq(users.id, owner.id)))[0]!.studioId;
  });
  afterAll(async () => { await a?.close(); });

  it('a new set is named before it is added; the name is trimmed and 1–80 characters', async () => {
    const o = (await owner.req('POST', '/v1/outfits', { modelId: m.id, mode: 'describe', description: 'Green halter mini skirt set' })).body;
    await until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id && x.state === 'preview'));
    expect((await owner.req('POST', `/v1/outfits/${o.id}/save`, { name: '' })).status).toBe(400);
    const saved = (await owner.req('POST', `/v1/outfits/${o.id}/save`, { name: '  Green halter set ' })).body;
    expect(saved).toMatchObject({ name: 'Green halter set', state: 'ready', createdBy: owner.id });
    expect(typeof saved.createdAt).toBe('number');
  });

  it('rename: the owner or the maker; another member is refused; empty or over 80 characters is refused', async () => {
    await row('o_ren');
    expect((await other.req('PATCH', '/v1/outfits/o_ren', { name: 'Mine' })).status).toBe(403);
    expect((await maker.req('PATCH', '/v1/outfits/o_ren', { name: '   ' })).status).toBe(400);
    expect((await maker.req('PATCH', '/v1/outfits/o_ren', { name: 'x'.repeat(81) })).status).toBe(400);
    expect((await maker.req('PATCH', '/v1/outfits/o_ren', { name: ' Beach day ' })).body.name).toBe('Beach day');
    expect((await owner.req('PATCH', '/v1/outfits/o_ren', { name: 'x'.repeat(80) })).status).toBe(200);
  });

  it("another studio's outfit is not found", async () => {
    await a.ctx.db.insert(outfits).values({ id: 'o_far', studioId: 'st_other', modelId: 'm_x', name: 'Far', mode: 'photo', description: '', state: 'ready', angles: [null, null, null, null], createdAt: Date.now() });
    expect((await owner.req('PATCH', '/v1/outfits/o_far', { name: 'Mine' })).status).toBe(404);
    expect((await owner.req('DELETE', '/v1/outfits/o_far')).status).toBe(404);
    expect((await owner.req('POST', '/v1/outfits/o_far/fill')).status).toBe(404);
  });

  it('delete: refused while being made; the owner or maker removes it from her list; takes are kept', async () => {
    await row('o_gen', { state: 'generating' });
    expect((await owner.req('DELETE', '/v1/outfits/o_gen')).status).toBe(409);
    await row('o_del');
    const mine = (await owner.req('GET', '/v1/models')).body.find((x: any) => x.id === m.id);
    await a.ctx.db.execute(`update models set outfit_ids = '${JSON.stringify([...mine.outfitIds, 'o_del'])}'::jsonb where id = '${m.id}'` as any);
    expect((await other.req('DELETE', '/v1/outfits/o_del')).status).toBe(403);
    expect((await maker.req('DELETE', '/v1/outfits/o_del')).status).toBe(204);
    expect((await owner.req('GET', '/v1/outfits')).body.some((x: any) => x.id === 'o_del')).toBe(false);
    expect((await owner.req('GET', '/v1/models')).body.find((x: any) => x.id === m.id).outfitIds).not.toContain('o_del');
  });

  it('fill: makes only the missing angles from the front; refused without a front', async () => {
    await row('o_gap', { angles: [{ asset: 'g_front' }, { asset: 'g_tq' }, null, null] });
    expect((await other.req('POST', '/v1/outfits/o_gap/fill')).status).toBe(403);
    const r = await owner.req('POST', '/v1/outfits/o_gap/fill'); // paid: the owner (members spend their own wallet)
    expect(r.status).toBe(200);
    expect(r.body.cost).toBeGreaterThan(0);
    expect((await maker.req('DELETE', '/v1/outfits/o_gap')).status).toBe(409);
    const done = await until(async () => (await maker.req('GET', '/v1/outfits')).body.find((x: any) => x.id === 'o_gap' && x.angles.every(Boolean)));
    expect(done.angles[1]).toEqual({ asset: 'g_tq' });
    await row('o_nofront', { angles: [null, { asset: 'g_tq' }, null, null] });
    expect((await maker.req('POST', '/v1/outfits/o_nofront/fill')).status).toBe(400);
  });
});

// §6: an outfit from her base photos keeping chosen pieces.
describe('outfit from her base photos, keeping pieces', () => {
  it('keep/replace lines', async () => {
    const E = await import('../src/prompt/engine.js');
    const k = { keep: { top: true }, note: 'the black lace bra.' };
    expect(E.outfitKeepParts(k)).toMatchObject({ keeping: true, keep: 'the top (the black lace bra)', replace: 'the bottom, the shoes and the accessories' });
    expect(E.outfitKeepFront(k, 'a pleated tennis skirt.')).toContain('Keep exactly: the top (the black lace bra) (colour, cut, fabric, straps). Replace only the bottom, the shoes and the accessories with a pleated tennis skirt.');
    expect(E.outfitKeepAngle(k)).toContain('keep the top (the black lace bra) exactly');
    expect(E.outfitKeepParts({ keep: {} }).keeping).toBe(false);
  });

  it('kept pieces: four edits (front from her base front photo), priced as edits', async () => {
    const a = await makeApp({ BALANCE_MODE: 'simulated' });
    try {
      const { owner } = await people(a, 0);
      const m = await demoModel(owner);
      const o = (await owner.req('POST', '/v1/outfits', { modelId: m.id, mode: 'describe', description: 'a pleated tennis skirt', base: { source: 'base', keep: { top: true }, note: 'the black lace bra' } })).body;
      expect(o.prompt).toContain('Keep exactly: the top (the black lace bra)');
      const done = await until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id && x.state === 'preview'));
      expect(done.angles.filter(Boolean)).toHaveLength(4);
      const imgs = (await a.ctx.db.query.generatedImages.findMany()).filter(i => i.purpose === 'outfit');
      expect(imgs).toHaveLength(4);
      expect(imgs.some(i => i.prompt.includes('Keep exactly: the top'))).toBe(true);
      expect(imgs.filter(i => i.prompt.includes('in her base clothes'))).toHaveLength(3);
      expect(done.cost).toBeCloseTo(4 * 0.03, 6);
    } finally { await a.close(); }
  });
});
