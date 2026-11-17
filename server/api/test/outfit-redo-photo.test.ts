// Redo of an outfit made "From a photo" (owner 2026-11-17): the outfit keeps its reference photo; Redo sends that original
// (never the old front for a front redo), its description, the hair and head-to-toe lines, and the person's one-off note.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { outfits, users } from '../src/db/schema.js';
import type { ImageRequest } from '../src/images/engines.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
const engines = (a: App) => (a.ctx.images as unknown as { engines: Record<string, any> }).engines;

describe('Redo of an outfit made from a photo', () => {
  let a: App, owner: Client, m: { id: string }, studioId: string;
  const seen: ImageRequest[] = [];
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'simulated' });
    ({ owner } = await people(a, 0, { topUp: 100 }) as any);
    m = await demoModel(owner);
    studioId = (await a.ctx.db.select().from(users).where(eq(users.id, owner.id)))[0]!.studioId;
    const real = engines(a).simulated;
    engines(a).simulated = { provider: 'simulated', generate: async (req: ImageRequest, sel: any) => { seen.push(req); return real.generate(req, sel); } };
  });
  afterAll(async () => { await a?.close(); });

  it('a new outfit from a photo stores the photo', async () => {
    const o = (await owner.req('POST', '/v1/outfits', { modelId: m.id, mode: 'photo', name: 'Space set', description: 'Keep the hair from the photo, and the headset.', images: [{ asset: 'c_tq' }] })).body;
    const done = await until(async () => (await owner.req('GET', '/v1/outfits')).body.find((x: any) => x.id === o.id && x.state === 'preview'), 15_000);
    expect(done.photos).toEqual([{ asset: 'c_tq' }]);
    const [row] = await a.ctx.db.select().from(outfits).where(eq(outfits.id, o.id));
    expect(row!.photos).toEqual([{ asset: 'c_tq' }]);
    expect(row!.prompt).toMatch(/Wearing: the outfit in (image|panel) \d+ \(space set\)/);
    expect(row!.prompt).toContain('The complete outfit head to toe as in');
    expect(row!.prompt).toContain('Hair for this look: the hairstyle of the person in');
  });

  const seed = async (id: string) => a.ctx.db.insert(outfits).values({ id, studioId, modelId: m.id, name: 'Space set', mode: 'photo', description: 'Keep the hair from the photo, and the headset.',
    state: 'preview', createdBy: owner.id, createdAt: Date.now(), photos: [{ asset: 'c_tq' }],
    angles: [{ asset: 'c_front' }, { asset: 'g_tq' }, { asset: 'g_side' }, { asset: 'g_back' }], faces: [{ asset: 'face' }, { asset: 'face' }, { asset: 'face' }] });
  const redo = async (id: string, angle: string, note?: string) => {
    seen.length = 0;
    expect((await owner.req('POST', `/v1/outfits/${id}/redo`, { angle, ...(note ? { note } : {}) })).status).toBe(200);
    return until(() => seen[0], 15_000);
  };

  it('a front redo sends the original reference photo and its description, never the old front, with the note', async () => {
    await seed('o_rp1');
    const req = await redo('o_rp1', 'front', 'sneakers on');
    const refs = req.referenceImages.join(' ');
    expect(refs).toContain('c_tq');
    expect(refs).not.toContain('c_front');
    expect(req.prompt).toContain('For this look also: Keep the hair from the photo, and the headset.');
    expect(req.prompt).toMatch(/Wearing: the outfit in (image|panel) \d+ \(space set\)/);
    expect(req.prompt).toContain('Hair for this look: the hairstyle of the person in');
    expect(req.prompt).toContain('including the footwear, on every angle');
    expect(req.prompt.trim().endsWith('sneakers on')).toBe(true);
  });

  it('a side redo edits the current front, with the original photo and the head-to-toe line, and the note', async () => {
    await seed('o_rp2');
    const req = await redo('o_rp2', 'side', 'use the reference’s hair');
    expect(req.referenceImages[0]).toContain('c_front'); // image 1: the current front it edits
    expect(req.referenceImages[2]).toContain('c_tq'); // image 3: the original photo (after her face)
    expect(req.prompt).toContain('The complete outfit head to toe as in image 3, including the footwear');
    expect(req.prompt).toContain('use the reference’s hair');
  });

  it('a face redo carries the note', async () => {
    await seed('o_rp3');
    const req = await redo('o_rp3', 'faceTq', 'keep the headset');
    expect(req.prompt).toContain('keep the headset');
  });
});
