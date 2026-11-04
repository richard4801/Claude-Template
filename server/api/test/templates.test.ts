// Photo templates (plans/templates.md): CRUD and owner-only rules, visibility, no hidden-layer leaks, variation draws,
// direction, Save as template (fromShotId), favourites, the starter seed and the after-effects.
import fs from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { makeApp, people, sienna, type Client } from './helpers.js';
import { templates } from '../src/db/schema.js';
import { applyAfterEffects, faceBox } from '../src/templates/effects.js';
import { drawVariation, suggestPool } from '../src/templates/prompt.js';
import { STARTERS } from '../src/templates/starters.js';
import { ASSET_DIR } from '../src/images/service.js';

const SECRET = 'zebra-striped velvet secret layer';
const LAYERS = {
  style: `phone photo, ${SECRET}`, scene: 'a laundrette at night', camera: 'phone main camera, low angle', light: 'flickering tube light',
  negative: 'neon signs', afterEffects: { grade: 'moody-blue', grain: 0.3 },
};
const POOL = {
  pose: ['pose-one', 'pose-two', 'pose-three', 'pose-four'], bodyAngle: ['angle-a', 'angle-b', 'angle-c'],
  framing: ['frame-x', 'frame-y', 'frame-z'], expression: ['expr-1', 'expr-2', 'expr-3'],
};

describe('photo templates', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, tess: Client, mo: Client, modelId: string;
  beforeAll(async () => {
    a = await makeApp({ DEV_MODE: 'true', BALANCE_MODE: 'simulated', SIM_START_BALANCE: '50', CAP_PER_USER_DAY_USD: '50', CAP_PER_DAY_USD: '100' });
    const p = await people(a, 2); owner = p.owner; tess = p.members[0]!; mo = p.members[1]!;
    for (const m of [tess, mo]) await owner.req('POST', '/v1/wallets/transfer', { toUserId: m.id, tokens: 1000 });
    modelId = (await sienna(tess)).id;
  });
  afterAll(async () => { await a.close(); });

  /** Every response body as text: a hidden layer must never appear in any of them. */
  const noLeak = (body: unknown) => {
    const s = JSON.stringify(body);
    expect(s).not.toContain(SECRET);
    expect(s).not.toContain('pose-one');
    expect(s).not.toContain('laundrette');
  };

  it('the starter pack is seeded for the studio, public, owned by the owner, with covers', async () => {
    const list = (await tess.req('GET', '/v1/templates?scope=public')).body;
    const starters = list.filter((t: any) => t.starter);
    expect(starters.map((t: any) => t.starter).sort()).toEqual(STARTERS.map(s => s.slug).sort());
    for (const t of starters) {
      expect(t).toMatchObject({ visibility: 'public', ownerId: owner.id, isOwner: false, ownerName: 'Owner' });
      expect(t.layers).toBeUndefined();
      expect(t.variationPool).toBeUndefined();
      expect(t.cover.url).toMatch(/\/uploads\/t\//);
    }
    const ownView = (await owner.req('GET', '/v1/templates?scope=mine')).body.find((t: any) => t.starter === 'mirror-selfie');
    expect(ownView.layers.afterEffects.grade).toBe('underexposed');
    expect(ownView.variationPool.pose.length).toBeGreaterThan(2);
    expect((await owner.req('GET', '/v1/templates?scope=mine')).body.find((t: any) => t.starter === 'product-moment').acceptsProduct).toBe(true);
    // The cover is a real, graded image in storage.
    const cover = await a.app.inject({ method: 'GET', url: starters[0].cover.url });
    expect(cover.statusCode).toBe(200);
    expect((await sharp(cover.rawPayload).metadata()).format).toBe('jpeg');
  });

  it('the starter seed is idempotent and puts back a missing starter', async () => {
    const count = async () => (await a.ctx.db.select().from(templates)).length;
    const before = await count();
    expect((await a.ctx.templates.seedAllStarters()).added).toBe(0);
    expect(await count()).toBe(before);
    const mirror = (await owner.req('GET', '/v1/templates?scope=mine&q=mirror')).body[0];
    expect((await owner.req('DELETE', `/v1/templates/${mirror.id}`)).status).toBe(204);
    expect(await count()).toBe(before - 1);
    expect((await a.ctx.templates.seedAllStarters()).added).toBe(1);
    expect((await a.ctx.templates.seedAllStarters()).added).toBe(0);
    expect(await count()).toBe(before);
  });

  let tpl: any;
  it('create, read, update and delete: owner only; private ones are invisible to others', async () => {
    const r = await tess.req('POST', '/v1/templates', { name: 'Laundrette', tags: ['Night', 'night', 'Moody'], layers: LAYERS, variationPool: POOL });
    expect(r.status).toBe(200);
    tpl = r.body;
    expect(tpl).toMatchObject({ name: 'Laundrette', visibility: 'private', isOwner: true, uses: 0, favourite: false, tags: ['night', 'Moody'] });
    expect(tpl.layers.style).toContain(SECRET);
    expect(tpl.variationPool.pose).toEqual(POOL.pose);

    // Private: Mo can't see, change, use or favourite it.
    expect((await mo.req('GET', `/v1/templates/${tpl.id}`)).status).toBe(404);
    expect((await mo.req('GET', '/v1/templates')).body.some((t: any) => t.id === tpl.id)).toBe(false);
    expect((await mo.req('PATCH', `/v1/templates/${tpl.id}`, { name: 'mine now' })).status).toBe(404);
    expect((await mo.req('POST', `/v1/templates/${tpl.id}/favourite`)).status).toBe(404);
    expect((await mo.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 1 })).status).toBe(404);
    expect((await owner.req('GET', `/v1/templates/${tpl.id}`)).status).toBe(404); // not even the studio owner

    const u = (await tess.req('PATCH', `/v1/templates/${tpl.id}`, { name: 'Laundrette night', tags: ['Night'] })).body;
    expect(u).toMatchObject({ name: 'Laundrette night', tags: ['Night'] });
    expect((await tess.req('PATCH', `/v1/templates/${tpl.id}`, { name: '' })).status).toBe(400);
    expect((await tess.req('PATCH', `/v1/templates/${tpl.id}`, { visibility: 'everyone' })).status).toBe(400);

    const tmp = (await tess.req('POST', '/v1/templates', { name: 'Throwaway' })).body;
    expect(tmp.variationPool.pose.length).toBeGreaterThan(0); // auto-suggested
    expect((await tess.req('DELETE', `/v1/templates/${tmp.id}`)).status).toBe(204);
    expect((await tess.req('GET', `/v1/templates/${tmp.id}`)).status).toBe(404);
  });

  it('visibility toggles both ways; a public template shows to the studio without its layers', async () => {
    let r = await tess.req('PATCH', `/v1/templates/${tpl.id}`, { visibility: 'public' });
    expect(r.body.visibility).toBe('public');
    const seen = (await mo.req('GET', `/v1/templates/${tpl.id}`)).body;
    expect(seen).toMatchObject({ id: tpl.id, name: 'Laundrette night', visibility: 'public', isOwner: false, ownerName: 'Member1', tags: ['Night'] });
    expect(seen.layers).toBeUndefined();
    expect(seen.variationPool).toBeUndefined();
    noLeak(seen);
    expect((await mo.req('GET', '/v1/templates?scope=public')).body.some((t: any) => t.id === tpl.id)).toBe(true);
    expect((await mo.req('GET', '/v1/templates?scope=mine')).body.some((t: any) => t.id === tpl.id)).toBe(false);
    // Owner-only actions on a public template are owner_only for others.
    for (const [m, u, b] of [['PATCH', `/v1/templates/${tpl.id}`, { name: 'x' }], ['DELETE', `/v1/templates/${tpl.id}`], ['POST', `/v1/templates/${tpl.id}/duplicate`]] as const) {
      const x = await mo.req(m, u, b);
      expect(x.status).toBe(403);
      expect(x.body.code).toBe('owner_only');
    }
    r = await tess.req('PATCH', `/v1/templates/${tpl.id}`, { visibility: 'private' });
    expect(r.body.visibility).toBe('private');
    expect((await mo.req('GET', `/v1/templates/${tpl.id}`)).status).toBe(404);
    await tess.req('PATCH', `/v1/templates/${tpl.id}`, { visibility: 'public' });
  });

  it('search by name or tag, tag chips, and scopes', async () => {
    const byName = (await mo.req('GET', '/v1/templates?q=laundr')).body.map((t: any) => t.name);
    expect(byName).toEqual(['Laundrette night']);
    const byTagText = (await mo.req('GET', '/v1/templates?q=faceless')).body.map((t: any) => t.starter);
    expect(byTagText.sort()).toEqual(['mirror-selfie', 'motion-blur-face']);
    const byTag = (await mo.req('GET', '/v1/templates?tag=night')).body.map((t: any) => t.name).sort();
    expect(byTag).toEqual(['Laundrette night', 'Moody low-light']);
    expect((await mo.req('GET', '/v1/templates?scope=nope')).status).toBe(400);
  });

  it('favourites are per user', async () => {
    let r = await mo.req('POST', `/v1/templates/${tpl.id}/favourite`);
    expect(r.body.favourite).toBe(true);
    noLeak(r.body);
    expect((await mo.req('GET', '/v1/templates?scope=favourites')).body.map((t: any) => t.id)).toEqual([tpl.id]);
    expect((await tess.req('GET', '/v1/templates?scope=favourites')).body).toEqual([]);
    expect((await tess.req('GET', `/v1/templates/${tpl.id}`)).body.favourite).toBe(false);
    await mo.req('POST', `/v1/templates/${tpl.id}/favourite`); // twice is fine
    r = await mo.req('DELETE', `/v1/templates/${tpl.id}/favourite`);
    expect(r.body.favourite).toBe(false);
    expect((await mo.req('GET', '/v1/templates?scope=favourites')).body).toEqual([]);
  });

  let moShots: any[] = [];
  it('a template shoot: the server builds each prompt, new seeds, different draws, after-effects applied', async () => {
    const before = (await mo.req('GET', '/v1/wallet')).body.usd;
    const r = await mo.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 4, scene: 'ignored', prompt: 'ignored' });
    expect(r.status).toBe(200);
    moShots = r.body;
    expect(moShots).toHaveLength(4);
    // Pass-through pricing: the simulated engine settles to the estimate, 4 × (0.015 + 0.015 × 2 + 0.015 × 0.79 × 6) = $0.4644 → 47 tokens.
    expect((await mo.req('GET', '/v1/wallet')).body.usd).toBeCloseTo(before - 0.47, 6);
    expect(moShots.reduce((t: number, x: any) => t + x.cost, 0)).toBeCloseTo(0.4644, 9);
    for (const s of moShots) {
      expect(s).toMatchObject({ kind: 'shot', templateId: tpl.id, templateName: 'Laundrette night' });
      expect(s.prompt.split('\n')).toContain('Template: Laundrette night');
      expect(s.prompt).toContain('Sienna Vale');
      expect(s.prompt).toMatch(/Never add: .*logos/);
      expect(s.variation).toBeUndefined(); // the draws are the owner's secret too
      expect(s.thumb.url).toMatch(/\/uploads\/g\/fx_/); // graded copy, not the raw still
      noLeak(s);
    }
    // Stored on the shot: the exact final prompt, the seed and the draws.
    const rows = await a.ctx.db.query.takes.findMany({ where: (t, { eq }) => eq(t.templateId, tpl.id) });
    expect(rows).toHaveLength(4);
    for (const row of rows) {
      expect(row.prompt).toContain(SECRET);
      expect(row.prompt).toContain('Scene: a laundrette at night');
      expect(row.prompt).toMatch(/Never add: .*neon signs/);
      expect(row.variation!.pose).toMatch(/^pose-/);
      expect(row.variation!.bodyAngle).toMatch(/^angle-/);
      expect(row.prompt).toContain(row.variation!.pose!);
      expect(row.publicPrompt).not.toContain(SECRET);
    }
    expect(new Set(rows.map(x => x.seed)).size).toBeGreaterThan(1);
    expect(new Set(rows.map(x => JSON.stringify(x.variation))).size).toBeGreaterThan(1);
    // The template owner sees the full prompt and the draws on the same shots.
    const asOwner = (await tess.req('GET', '/v1/takes')).body.filter((t: any) => t.templateId === tpl.id);
    expect(asOwner[0].prompt).toContain(SECRET);
    expect(asOwner[0].variation.pose).toMatch(/^pose-/);
    // Uses and recent results.
    const d = (await mo.req('GET', `/v1/templates/${tpl.id}`)).body;
    expect(d.uses).toBe(1);
    expect(d.recent).toHaveLength(4);
    noLeak(d);
    // A second shoot draws again: new seeds.
    const again = (await mo.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 1 })).body;
    expect(again[0].shuffleSeed).not.toBe(moShots[0].shuffleSeed);
  });

  it('direction replaces the pose and angle draws; shuffleSeed is repeatable', async () => {
    const r = (await mo.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 2, direction: 'sitting on the steps, looking back over her shoulder', shuffleSeed: 77 })).body;
    expect(r[0].prompt).toContain('Direction: sitting on the steps, looking back over her shoulder.');
    const rows = await a.ctx.db.query.takes.findMany({ where: (t, { inArray }) => inArray(t.id, r.map((x: any) => x.id)) });
    for (const row of rows) {
      expect(row.variation!.pose).toBeUndefined();
      expect(row.variation!.bodyAngle).toBeUndefined();
      expect(row.variation!.direction).toContain('sitting on the steps');
      expect(row.variation!.framing).toMatch(/^frame-/);
      expect(row.prompt).not.toMatch(/pose-|angle-/);
      expect(row.shuffleSeed).toBe(77);
    }
    // Same shuffleSeed → same draws (the prompt view matches the shoot); a different one differs somewhere.
    expect(drawVariation(POOL, 77, 0)).toEqual(drawVariation(POOL, 77, 0));
    const many = new Set(Array.from({ length: 12 }, (_, i) => JSON.stringify(drawVariation(POOL, i))));
    expect(many.size).toBeGreaterThan(6);
    // Lock look gives the same seed every time.
    const l1 = (await mo.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 1, lockSeed: true })).body[0];
    const l2 = (await mo.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 1, lockSeed: true })).body[0];
    expect(l1.seed).toBe(l2.seed);
  });

  it('the prompt view: one locked line for non-owners, every layer for the owner', async () => {
    const pub = (await mo.req('POST', `/v1/templates/${tpl.id}/prompt`, { modelId, direction: 'leaning on a dryer', shuffleSeed: 5 })).body;
    expect(pub.slots.find((s: any) => s.layer === 'template')).toEqual({ layer: 'template', text: 'Template: Laundrette night', locked: true });
    expect(pub.slots.map((s: any) => s.layer)).toEqual(['identity', 'template', 'direction', 'negative', 'seed']);
    expect(pub.variation).toBeUndefined();
    noLeak(pub);
    const own = (await tess.req('POST', `/v1/templates/${tpl.id}/prompt`, { modelId, shuffleSeed: 5 })).body;
    expect(own.text).toContain(SECRET);
    expect(own.variation).toEqual(drawVariation(POOL, 5, 0));
  });

  it('no endpoint leaks a public template’s layers to a non-owner', async () => {
    const urls = ['/v1/templates', '/v1/templates?scope=all', '/v1/templates?scope=public', '/v1/templates?scope=favourites', `/v1/templates/${tpl.id}`,
      '/v1/takes', '/v1/jobs', '/v1/models', '/v1/outfits', '/v1/posts', `/v1/templates?q=${encodeURIComponent('zebra')}`];
    await mo.req('POST', `/v1/templates/${tpl.id}/favourite`);
    for (const u of urls) {
      const r = await mo.req('GET', u);
      expect(r.status, u).toBeLessThan(400);
      noLeak(r.body);
    }
    // Searching for words inside the hidden layers finds nothing.
    expect((await mo.req('GET', '/v1/templates?q=zebra')).body).toEqual([]);
    noLeak((await mo.req('POST', `/v1/templates/${tpl.id}/favourite`)).body);
    noLeak((await mo.req('DELETE', `/v1/templates/${tpl.id}/favourite`)).body);
    noLeak((await mo.req('PATCH', `/v1/takes/${moShots[0].id}`, { status: 'final' })).body);
    // Saving someone else's template shot as your own template would copy the layers: refused.
    for (const u of ['/v1/templates/draft', '/v1/templates']) {
      const r = await mo.req('POST', u, { fromShotId: moShots[0].id, name: 'Stolen' });
      expect(r.status).toBe(403);
      expect(r.body.code).toBe('template_hidden');
      noLeak(r.body);
    }
    // The studio owner is a non-owner of Tess's template too.
    noLeak((await owner.req('GET', '/v1/takes')).body);
    noLeak((await owner.req('GET', `/v1/templates/${tpl.id}`)).body);
  });

  it('Save as template from a plain shot: its layers (no identity, outfit, never-add or seed), its image, a suggested pool', async () => {
    const shot = (await mo.req('POST', '/v1/shoots', { modelId, scene: 'Bathroom mirror · soft', direction: 'phone covering her face', count: 1 })).body[0];
    const draft = (await mo.req('POST', '/v1/templates/draft', { fromShotId: shot.id })).body;
    expect(draft.layers.scene).toBe('bathroom mirror');
    expect(draft.layers.camera).toContain('35mm');
    expect(JSON.stringify(draft.layers)).not.toMatch(/Sienna|Wearing|Never add|Seed/);
    expect(draft.variationPool.pose[0]).toBe('phone covering her face');
    expect(draft.variationPool.framing.length).toBeGreaterThan(0); // mirror → mirror-selfie suggestions
    const pool = { ...draft.variationPool, expression: ['edited-by-creator'] };
    const t = (await mo.req('POST', '/v1/templates', { fromShotId: shot.id, name: 'My mirror', tags: ['Selfie'], variationPool: pool })).body;
    expect(t).toMatchObject({ name: 'My mirror', visibility: 'private', isOwner: true, createdFromShotId: shot.id, tags: ['Selfie'] });
    expect(t.variationPool.expression).toEqual(['edited-by-creator']);
    expect(t.layers).toEqual(draft.layers);
    expect(t.cover.url).toMatch(/\/uploads\//);
    expect((await a.app.inject({ method: 'GET', url: t.cover.url })).statusCode).toBe(200);
    // Duplicate (owner) → a private copy.
    const dup = (await mo.req('POST', `/v1/templates/${t.id}/duplicate`)).body;
    expect(dup).toMatchObject({ name: 'My mirror copy', visibility: 'private', uses: 0 });
    // The template owner can save their own template shot as a new template: layers and pool come along.
    const own = (await tess.req('POST', '/v1/shoots', { modelId, templateId: tpl.id, count: 1 })).body[0];
    const t2 = (await tess.req('POST', '/v1/templates', { fromShotId: own.id, name: 'Laundrette v2' })).body;
    expect(t2.layers.style).toContain(SECRET);
    expect(t2.variationPool.pose).toEqual(POOL.pose);
  });

  it('product moment takes an optional product photo as a reference', async () => {
    const pm = (await mo.req('GET', '/v1/templates?q=product')).body[0];
    const r = await mo.req('POST', '/v1/shoots', { modelId, templateId: pm.id, count: 1, productImage: { asset: 'c_face' } });
    expect(r.status).toBe(200);
    const row = (await a.ctx.db.query.takes.findFirst({ where: (t, { eq }) => eq(t.id, r.body[0].id) }))!;
    expect(row.prompt).toContain('Product: the product from the product photo');
    expect(r.body[0].prompt).not.toContain('Product:');
  });

  it('a deleted template leaves its shots with the public prompt', async () => {
    const t = (await tess.req('POST', '/v1/templates', { name: 'Short-lived', layers: { style: SECRET }, visibility: 'public' })).body;
    const shot = (await mo.req('POST', '/v1/shoots', { modelId, templateId: t.id, count: 1 })).body[0];
    await tess.req('DELETE', `/v1/templates/${t.id}`);
    const after = (await mo.req('GET', '/v1/takes')).body.find((x: any) => x.id === shot.id);
    expect(after.templateName).toBe('Short-lived');
    expect(after.prompt).not.toContain(SECRET);
  });

  it('/health reports the build, the migrations and the starter seed', async () => {
    const h = (await a.app.inject({ method: 'GET', url: '/health' })).json();
    expect(h.migrations).toEqual({ applied: 4, latest: '0003_studio_balance' });
    expect(h.startedAt).toBeGreaterThan(0);
  });
});

describe('after-effects', () => {
  const src = fs.readFileSync(path.join(ASSET_DIR, 'face.jpg'));
  const stats = async (b: Buffer, region?: { left: number; top: number; width: number; height: number }) => {
    const img = region ? sharp(b).extract(region) : sharp(b);
    return img.stats();
  };

  it('grades change the colour, grain adds noise, motion blur softens only the face box', async () => {
    const base = await stats(src);
    const moody = await stats(await applyAfterEffects(src, { grade: 'moody-blue' }));
    expect(moody.channels[2]!.mean / moody.channels[0]!.mean).toBeGreaterThan(base.channels[2]!.mean / base.channels[0]!.mean);
    expect(moody.channels[0]!.mean).toBeLessThan(base.channels[0]!.mean);
    const mono = await stats(await applyAfterEffects(src, { grade: 'mono' }));
    expect(Math.abs(mono.channels[0]!.mean - mono.channels[2]!.mean)).toBeLessThan(2);

    const { width = 0, height = 0 } = await sharp(src).metadata();
    const box = faceBox(width, height);
    const inner = { left: box.left + box.width / 4 | 0, top: box.top + box.height / 4 | 0, width: box.width / 2 | 0, height: box.height / 2 | 0 };
    const corner = { left: 0, top: height - 60, width: 60, height: 60 };
    const blurred = await applyAfterEffects(src, { faceMotionBlur: 1 });
    // Horizontal motion blur: neighbouring pixels along a row get closer (less horizontal detail) inside the box.
    const rowDiff = async (b: Buffer, r: typeof inner) => {
      const { data, info } = await sharp(b).extract(r).greyscale().raw().toBuffer({ resolveWithObject: true });
      let s = 0; for (let y = 0; y < info.height; y++) for (let x = 1; x < info.width; x++) s += Math.abs(data[y * info.width + x]! - data[y * info.width + x - 1]!);
      return s / (info.height * (info.width - 1));
    };
    expect(await rowDiff(blurred, inner)).toBeLessThan((await rowDiff(src, inner)) * 0.6);
    expect(Math.abs((await rowDiff(blurred, corner)) - (await rowDiff(src, corner)))).toBeLessThan(1.5);

    const grain = await stats(await applyAfterEffects(src, { grain: 1 }), corner);
    const plain = await stats(await applyAfterEffects(src, {}), corner);
    expect(grain.channels[0]!.stdev).toBeGreaterThan(plain.channels[0]!.stdev);
  });

  it('suggested pools follow the style words', () => {
    expect(suggestPool({ style: 'mirror selfie in a bedroom' }).pose![0]).toContain('phone');
    expect(suggestPool({ style: 'anything' }).pose!.length).toBeGreaterThan(0);
  });
});
