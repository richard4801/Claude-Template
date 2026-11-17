// Upload picture (owner 2026-11-17: "upload image manually to already generated outfits. I shouldn't need to generate if I
// already have it"). POST /v1/outfits/:id/slot puts an upload of the studio into any of the 7 slots, free: checked to be a
// photo, saved upright as a JPEG (long edge ≤ 2048), marked source 'upload'; a replaced picture is kept and can be put
// back. Claude's outfit_set_slot previews without confirm and needs Approve.
import sharp from 'sharp';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { ledger, outfits, uploads, users } from '../src/db/schema.js';
import { registryByName } from '../src/claude/registry.js';
import { outfitPicture } from '../src/images/outfitUpload.js';
import { putObject } from '../src/storage/objects.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, maker: Client, other: Client, m: { id: string }, studioId: string, ownerU: AuthUser;
const R = (asset: string) => ({ asset });
const row = async (id: string, v: Partial<typeof outfits.$inferInsert> = {}) => {
  await a.ctx.db.insert(outfits).values({ id, studioId, modelId: m.id, name: 'Linen', mode: 'describe', description: '', state: 'ready', createdBy: maker.id, createdAt: Date.now(),
    angles: [R('g_front'), R('g_tq'), R('g_side'), R('g_back')], faces: [R('face'), null, null], ...v });
};
const get = async (id: string) => (await a.ctx.db.select().from(outfits).where(eq(outfits.id, id)))[0]!;
/** A stored upload of a studio: { url } like POST /v1/uploads/images gives, and its upload id. */
const upload = async (body: Buffer, ext = 'jpg', sid = studioId) => {
  const key = `u/test_${Math.random().toString(16).slice(2)}.${ext}`;
  await putObject(a.ctx, { key, body, studioId: sid, kind: 'image', keepMetadata: true });
  const [u] = await a.ctx.db.select().from(uploads).where(eq(uploads.storageKey, key));
  return { image: { url: `/uploads/${key}` }, uploadId: u!.id };
};
const photo = (w: number, h: number, o: { orientation?: number; png?: boolean } = {}) => {
  const img = sharp({ create: { width: w, height: h, channels: 3, background: { r: 30, g: 120, b: 200 } } });
  return o.png ? img.png().toBuffer() : img.jpeg().withMetadata(o.orientation ? { orientation: o.orientation } : {}).toBuffer();
};
const stored = async (ref: { url?: string }) => sharp(Buffer.from(await (await a.app.inject({ method: 'GET', url: ref.url! })).rawPayload)).metadata();

beforeAll(async () => {
  a = await makeApp({ BALANCE_MODE: 'simulated' });
  ({ owner, members: [maker, other] } = await people(a, 2) as any);
  m = await demoModel(owner);
  studioId = (await a.ctx.db.select().from(users).where(eq(users.id, owner.id)))[0]!.studioId;
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test', sessionId: null };
});
afterAll(async () => { await a?.close(); });

describe('outfit: upload a picture into a slot', () => {
  it('an empty face slot takes an upload: free, normalized JPEG (upright, ≤ 2048), marked upload; nothing charged', async () => {
    await row('o_u1');
    const before = (await a.ctx.db.select().from(ledger)).length;
    const up = await upload(await photo(3000, 2000, { orientation: 6 })); // stored sideways: shown 2000 × 3000
    const dry = (await owner.req('POST', '/v1/outfits/o_u1/slot', { slot: 'faceTq', image: up.image, dryRun: true })).body;
    expect(dry).toEqual({ dryRun: true, slot: 'faceTq', replaces: null, restores: false, cost: 0 });
    expect((await get('o_u1')).faces![1]).toBeNull();
    const r = await owner.req('POST', '/v1/outfits/o_u1/slot', { slot: 'faceTq', image: up.image });
    expect(r.status).toBe(200);
    expect(r.body.replaced).toBeNull();
    const ref = r.body.outfit.faces[1];
    expect(ref.url).toMatch(/^\/uploads\/u\/outfit_[0-9a-f]+\.jpg$/);
    expect(r.body.outfit.sources).toEqual({ faceTq: 'upload' });
    expect(r.body.outfit.replaced).toBeUndefined();
    const meta = await stored(ref);
    expect(meta).toMatchObject({ format: 'jpeg', width: 1365, height: 2048 });
    expect(meta.orientation).toBeUndefined();
    expect((await a.ctx.db.select().from(ledger)).length).toBe(before);
  });

  it('a filled slot by uploadId (a PNG): the old picture is kept in replaced, and sending it back restores it', async () => {
    await row('o_u2');
    const up = await upload(await photo(600, 800, { png: true }), 'png');
    expect((await maker.req('POST', '/v1/outfits/o_u2/slot', { slot: 'side', uploadId: up.uploadId, dryRun: true })).body).toMatchObject({ replaces: R('g_side'), restores: false });
    const r = (await other.req('POST', '/v1/outfits/o_u2/slot', { slot: 'side', uploadId: up.uploadId })).body; // any member of the studio
    expect(r.replaced).toEqual(R('g_side'));
    expect(r.outfit.sources).toEqual({ side: 'upload' });
    expect(r.outfit.replaced).toMatchObject([{ slot: 'side', image: R('g_side'), source: 'generated', by: other.id }]);
    expect((await stored(r.outfit.angles[2])).format).toBe('jpeg');
    const mine = r.outfit.angles[2];
    // Put the generated one back: no new file, the mark goes, the upload is the one kept now.
    const dry = (await owner.req('POST', '/v1/outfits/o_u2/slot', { slot: 'side', image: R('g_side'), dryRun: true })).body;
    expect(dry).toMatchObject({ restores: true, replaces: mine });
    const back = (await owner.req('POST', '/v1/outfits/o_u2/slot', { slot: 'side', image: R('g_side') })).body;
    expect(back.outfit.angles[2]).toEqual(R('g_side'));
    expect(back.outfit.sources).toBeUndefined();
    expect(back.outfit.replaced).toMatchObject([{ slot: 'side', image: mine, source: 'upload' }]);
  });

  it('reorder carries the upload mark; a Redo of that slot makes it generated again', async () => {
    await row('o_u3');
    const up = await upload(await photo(400, 500));
    await owner.req('POST', '/v1/outfits/o_u3/slot', { slot: 'side', image: up.image });
    const moved = (await owner.req('POST', '/v1/outfits/o_u3/reorder', { moves: [{ from: 'side', to: 'back' }] })).body;
    expect(moved.outfit.sources).toEqual({ back: 'upload' });
    expect((await owner.req('POST', '/v1/outfits/o_u3/redo', { angle: 'back' })).status).toBe(200);
    const { until } = await import('./helpers.js');
    const o = await until(async () => { const x = await get('o_u3'); return x.angles[3] && (x.angles[3] as any).url !== moved.outfit.angles[3].url && !x.sources?.back ? x : null; }, 15_000);
    expect(o.sources).toEqual({});
  });

  it('an older outfit without face close-ups gets its faces list; a body upload leaves faces as they were', async () => {
    await row('o_u4', { faces: null });
    const up = await upload(await photo(400, 500));
    expect((await owner.req('POST', '/v1/outfits/o_u4/slot', { slot: 'front', image: up.image })).body.outfit.faces).toBeUndefined();
    const f = (await owner.req('POST', '/v1/outfits/o_u4/slot', { slot: 'profile', image: up.image })).body.outfit;
    expect(f.faces.map(Boolean)).toEqual([false, false, true]);
  });

  it('refused: not a photo 400; another studio\'s upload or outfit 404; no picture / two pictures / bad slot 400; busy 409; unconfirmed 409', async () => {
    await row('o_u5');
    const txt = await upload(Buffer.from('just some words, not a picture'), 'jpg');
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front', image: txt.image })).status).toBe(400);
    const far = await upload(await photo(100, 100), 'jpg', 'st_other');
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front', image: far.image })).status).toBe(404);
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front', uploadId: far.uploadId })).status).toBe(404);
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front', image: { url: 'https://example.com/a.jpg' } })).status).toBe(400);
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front' })).status).toBe(400);
    const ok = await upload(await photo(100, 100));
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front', image: ok.image, uploadId: ok.uploadId })).status).toBe(400);
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'left', image: ok.image })).status).toBe(400);
    await a.ctx.db.insert(outfits).values({ id: 'o_ufar', studioId: 'st_other', modelId: m.id, name: 'Far', mode: 'own', description: '', state: 'ready', createdAt: Date.now(), angles: [null, null, null, null] });
    expect((await owner.req('POST', '/v1/outfits/o_ufar/slot', { slot: 'front', image: ok.image })).status).toBe(404);
    await row('o_u6', { state: 'generating' });
    expect((await owner.req('POST', '/v1/outfits/o_u6/slot', { slot: 'front', image: ok.image })).status).toBe(409);
    await a.ctx.db.update(uploads).set({ state: 'pending' }).where(eq(uploads.id, ok.uploadId));
    expect((await owner.req('POST', '/v1/outfits/o_u5/slot', { slot: 'front', uploadId: ok.uploadId })).status).toBe(409);
    expect((await get('o_u5')).angles[0]).toEqual(R('g_front'));
  });

  it('outfitPicture: webp and png with transparency become JPEG; garbage is null', async () => {
    const webp = await sharp({ create: { width: 50, height: 60, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).webp().toBuffer();
    expect(await sharp((await outfitPicture(webp))!).metadata()).toMatchObject({ format: 'jpeg', width: 50, height: 60, hasAlpha: false });
    expect(await outfitPicture(Buffer.from('nope'))).toBeNull();
    const gif = await sharp({ create: { width: 5, height: 5, channels: 3, background: '#fff' } }).gif().toBuffer();
    expect(await outfitPicture(gif)).toBeNull();
  });

  it('Claude: outfit_set_slot says what it replaces without confirm, waits for Approve, then puts the picture in', async () => {
    await row('o_u7');
    const t = registryByName.get('outfit_set_slot')!;
    expect(t.gate).toBe('settings');
    expect(t.scope).toBe(registryByName.get('outfit_reorder')!.scope);
    const env = { ctx: a.ctx, user: ownerU, source: 'chat' } as any;
    const up = await upload(await photo(300, 400));
    const look = await t.run(env, { outfitId: 'o_u7', slot: 'back', image: up.image }) as any;
    expect(look.needsConfirmation).toBe(true);
    expect(look.would).toBe('Replace the outfit\'s Back picture with this one (the current one is kept to put back)');
    expect(look.estimateUsd).toBeUndefined();
    expect((await t.run(env, { outfitId: 'o_u7', slot: 'faceTq', image: up.image }) as any).would).toBe('Put this picture in the outfit\'s empty Face ¾ slot');
    const ask = await t.run(env, { outfitId: 'o_u7', slot: 'back', image: up.image, confirm: true }) as any;
    expect(ask.waitingForApproval).toBe(true);
    expect((await get('o_u7')).angles[3]).toEqual(R('g_back'));
    expect((await owner.req('POST', `/v1/claude/actions/${ask.actionId}`, { approve: true })).body.status).toBe('done');
    const o = await get('o_u7');
    expect((o.angles[3] as any).url).toMatch(/\/uploads\/u\/outfit_/);
    expect(o.sources).toEqual({ back: 'upload' });
  });
});
