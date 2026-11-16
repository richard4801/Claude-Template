// Retake with AI on one sheet photo (owner 2026-11-16: a retaken "Body · side" lost her figure, because the old photo was
// cleared first and the model never saw it). The retake keeps the current photo and sends it as image 1.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { and, eq, like } from 'drizzle-orm';
import * as E from '../src/prompt/engine.js';
import { DEFAULT_TEXTS } from '../src/prompt/library.js';
import { scriptDef } from '../src/prompt/scripts/defs.js';
import { retakeRefs } from '../src/images/identity.js';
import { ledger, models, type SheetSlot } from '../src/db/schema.js';
import { modelChoice } from '../src/engines/service.js';
import { demoModel, makeApp, people, until, type Client } from './helpers.js';

const demo: E.Identity = { name: 'Demo model', look: 'young woman, dark hair', neverAdd: ['tattoos'], referenceCount: 3 };
const FIGURE = (body: string) => DEFAULT_TEXTS['outfit.figure']!.replace('{body}', body);
const REALISM = DEFAULT_TEXTS['sheet.realism']!;
const FULL = { face: 'face', profile: 'profile', front: 'g_front', tq: 'g_tq', side: 'g_side', back: 'g_back', faceTq: 'c_face' };
const slotsOf = (o: Record<string, string>): SheetSlot[] => Object.entries(o).map(([key, a]) => ({ key, image: { asset: a }, source: 'upload', busy: false }) as SheetSlot);

describe('retake prompts (unit)', () => {
  it('the images: the current photo first, then her face close-ups, then her nearest body angles', () => {
    expect(retakeRefs({ slots: slotsOf(FULL) }, 'side').map(r => `${(r.image as any).asset}:${r.label}`))
      .toEqual(['g_side:body', 'face:face', 'c_face:face ¾', 'profile:face profile', 'g_tq:body', 'g_back:body', 'g_front:body']);
    expect(retakeRefs({ slots: slotsOf(FULL) }, 'faceTq').map(r => (r.image as any).asset)).toEqual(['c_face', 'face', 'profile', 'g_tq', 'g_front']);
    expect(retakeRefs({ slots: slotsOf({ face: 'face' }) }, 'side')).toEqual([]);
  });
  it('an edit of image 1 with her figure and the realism line; the faces and other angles named', () => {
    const p = E.sheetRetake(demo, E.sheetAngle('side')!, { faces: 'image 2 (face, front), image 3 (face ¾)', bodies: 'Images 4–5' }).text;
    expect(p).toContain('Task: edit image 1, her body · side photo, into a real photograph of a real human');
    expect(p).toContain('the same framing (full body, side view) and the same pose');
    expect(p).toContain('Her face exactly as in image 2 (face, front), image 3 (face ¾).');
    expect(p).toContain('Images 4–5 show her body from other angles: match her proportions from them, never their pose or framing.');
    expect(p).toContain(FIGURE('image 1'));
    expect(p).toContain(REALISM);
    expect(p).toMatch(/\nStyle: realistic smartphone photo, natural skin texture/);
    expect(REALISM).toMatch(/visible pores/);
    // A face close-up has no figure line; no other body photos, no line for them.
    const f = E.sheetRetake(demo, E.sheetAngle('face')!, { faces: '', bodies: '' }).text;
    expect(f).not.toMatch(/Figure:|other angles/);
    expect(f).toContain('Her face exactly as in image 1.');
    expect(f).toContain(REALISM);
  });
  it('fill-angles: a body angle carries her figure and the realism line; a face angle the realism line', () => {
    const body = E.characterSheetShot(demo, E.sheetAngle('side')!, DEFAULT_TEXTS, 'her body photo (image 3)');
    expect(body.slots.map(s => s.layer)).toEqual(['identity', 'task', 'style', 'figure', 'realism', 'negative']);
    expect(body.text).toContain(FIGURE('her body photo (image 3)'));
    expect(body.text).toContain(REALISM);
    expect(E.characterSheetShot(demo, E.sheetAngle('face')!).text).not.toMatch(/Figure:/);
    for (const id of ['sheet', 'sheet.retake']) for (const r of ['figure', 'realism']) expect(scriptDef(id)!.rules.find(x => x.id === r), `${id} ${r}`).toMatchObject({ locked: true });
  });
});

describe('POST /v1/models/:id/slots/:slot/retake', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, m: { id: string };
  const calls: any[] = [];
  let fail = false;
  beforeAll(async () => {
    a = await makeApp({ BALANCE_MODE: 'simulated' });
    ({ owner } = await people(a, 0) as any);
    m = await demoModel(owner);
    vi.spyOn(modelChoice(a.ctx), 'imageOverrides').mockResolvedValue({ shot: 'c_seedream' } as any);
    vi.spyOn(a.ctx.suite.byo, 'photoCapacity').mockResolvedValue(6);
    vi.spyOn(a.ctx.suite.byo, 'photoPerShot').mockResolvedValue(0.05);
    vi.spyOn(a.ctx.images, 'generate').mockImplementation(async (o: any) => {
      calls.push(o);
      if (fail) throw new Error('engine down');
      o.bill?.add(0.07); // the engine charged more than the estimate
      return { images: [{ asset: 'g_new_side' }], costUsd: 0.07, costs: [0.07], selection: { provider: 'byo', model: 'c_seedream' } } as any;
    });
  });
  afterAll(async () => { vi.restoreAllMocks(); await a?.close(); });

  const row = async () => (await a.ctx.db.select().from(models).where(eq(models.id, m.id)))[0]!;
  const side = async () => (await row()).slots.find(s => s.key === 'side')!;
  const idle = () => until(async () => !(await side()).busy, 15_000);

  it('dryRun: the price and the images, nothing made', async () => {
    const d = (await owner.req('POST', `/v1/models/${m.id}/slots/side/retake`, { dryRun: true })).body;
    expect(d).toMatchObject({ dryRun: true, slot: 'side', cost: 0.05 });
    expect(d.sentImages.images.map((x: any) => x.image.asset)).toEqual(['g_side', 'face', 'c_face', 'profile', 'g_tq', 'g_back']);
    expect(calls).toHaveLength(0);
    expect((await side()).image).toEqual({ asset: 'g_side' });
  });

  it('sends the current photo as image 1, her faces and nearest angles within the limit; saves a version, then replaces; settles the price shown', async () => {
    const price = (await owner.req('POST', `/v1/models/${m.id}/slots/side/retake`, { dryRun: true })).body.cost;
    const r = await owner.req('POST', `/v1/models/${m.id}/slots/side/retake`, {});
    expect(r.status).toBe(200);
    expect(r.body.cost).toBe(price);
    await until(async () => (await side()).image?.asset === 'g_new_side', 15_000);
    const c = calls.at(-1)!;
    expect(c.editOf).toBeUndefined();
    expect(c.refs.map((x: any) => x.asset)).toEqual(['g_side', 'face', 'c_face', 'profile', 'g_tq', 'g_back']);   // front: beyond the limit of 6
    expect(c.req.prompt).toContain('Task: edit image 1, her body · side photo');
    expect(c.req.prompt).toContain('Her face exactly as in image 2 (face, front), image 3 (face ¾), image 4 (face in profile).');
    expect(c.req.prompt).toContain('Images 5–6 show her body from other angles');
    expect(c.req.prompt).toContain(FIGURE('image 1'));
    expect(c.req.prompt).toContain(REALISM);
    console.log(`sample retake prompt:\n${c.req.prompt}`);
    const now = await row();
    expect(now.slots.find(s => s.key === 'side')).toMatchObject({ source: 'generated', busy: false });
    expect(now.sheetVersions[0]).toMatchObject({ reason: 'retake' });
    expect(now.sheetVersions[0]!.slots.find(s => s.key === 'side')!.image).toEqual({ asset: 'g_side' });
    // Settled at the price shown, never above it.
    const settled = await until(async () => (await a.ctx.db.select().from(ledger).where(and(eq(ledger.kind, 'settle'), like(ledger.jobId, 'sheet_r%'))))[0]);
    expect(settled.amountUsd).toBeCloseTo(price, 9);
    // The old photo comes back with Restore.
    const back = (await owner.req('POST', `/v1/models/${m.id}/sheet-versions/${now.sheetVersions[0]!.id}/restore`)).body;
    expect(back.slots.find((s: any) => s.key === 'side').image).toEqual({ asset: 'g_side' });
  });

  it('a failed retake leaves the photo as it was and charges nothing', async () => {
    fail = true;
    const versions = (await row()).sheetVersions.length;
    expect((await owner.req('POST', `/v1/models/${m.id}/slots/side/retake`, {})).status).toBe(200);
    await idle();
    fail = false;
    const now = await row();
    expect(now.slots.find(s => s.key === 'side')).toMatchObject({ image: { asset: 'g_side' }, busy: false });
    expect(now.sheetVersions).toHaveLength(versions);
  });

  it('refuses an empty slot and an unknown one', async () => {
    const e = (await owner.req('POST', '/v1/models', { name: 'Empty', age: 25 })).body;
    expect((await owner.req('POST', `/v1/models/${e.id}/slots/side/retake`, { dryRun: true })).status).toBe(409);
    expect((await owner.req('POST', `/v1/models/${m.id}/slots/nope/retake`, { dryRun: true })).status).toBe(404);
  });
});
