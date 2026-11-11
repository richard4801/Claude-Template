// Model tools (plans/api.md "Model tools") against a FAKE Replicate on localhost (no real predictions, no money):
// schema mapping on real model schemas (trimmed copies in fixtures/replicate, fetched 2026-11-04), prices from real
// model pages, the catalog and step-model endpoints, Enhance, outfit face close-ups, exact settle, review/apply, archive.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { ledger, outfits as outfitsT } from '../src/db/schema.js';
import * as Live from '../src/prompt/engine.js';
import { buildInput, mapModel, type RawModel } from '../src/replicate/mapping.js';
import { estimateOne, exactOne, parseModelPage, priceLine } from '../src/replicate/prices.js';
import { replicateReferencesFor, referencesFor } from '../src/services/jobs.js';
import { makeApp, people, demoModel, until, type Client } from './helpers.js';
import { fakeReplicate } from './fakeReplicate.js';

const FIX = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures/replicate');
const MODELS = JSON.parse(fs.readFileSync(path.join(FIX, 'models.json'), 'utf8')) as Record<string, RawModel>;
const page = (id: string) => fs.readFileSync(path.join(FIX, `page_${id.replace('/', '_')}.html`), 'utf8');
const EST = { timeEstSec: 20, unknownUsd: 0.05 };
const TOKEN = 'r8_tools_test';

describe('schema mapping (real model schemas)', () => {
  it('FLUX.1 Krea [dev]: img2img for realism', () => {
    const r = mapModel(MODELS['black-forest-labs/flux-krea-dev']!, 'realism');
    expect(r.compatible).toBe(true);
    expect(r.mapping).toMatchObject({ prompt: 'prompt', image: { field: 'image', array: false }, strength: { field: 'prompt_strength', min: 0, max: 1 },
      aspectRatio: 'aspect_ratio', resolution: 'megapixels', seed: 'seed', outputFormat: 'output_format', count: 'num_outputs' });
    const input = buildInput(r.mapping, { prompt: 'p', images: ['https://x/a.jpg'], width: 768, height: 1024, outMp: 1, seed: 5, strength: 0.35 }, { disable_safety_checker: true, go_fast: false });
    expect(input).toEqual({ prompt: 'p', image: 'https://x/a.jpg', aspect_ratio: '3:4', megapixels: '1', seed: 5, prompt_strength: 0.35, output_format: 'jpg', output_quality: 95, num_outputs: 1, go_fast: false });
    expect(Object.keys(input)).not.toContain('disable_safety_checker');
    // An upscale needs no prompt but Krea has no scale: compatible with a warning.
    expect(mapModel(MODELS['black-forest-labs/flux-krea-dev']!, 'upscale').warnings).toContain('no scale control · 2× / 4× do nothing');
    // One image only: not for Dress up.
    expect(mapModel(MODELS['black-forest-labs/flux-krea-dev']!, 'dressA')).toMatchObject({ compatible: false, reasons: ['takes one photo · Dress up needs the sheet photo and the outfit'] });
  });

  it('Qwen edit 2511 and FLUX.2 [pro]: image arrays for edits and Dress up', () => {
    const q = mapModel(MODELS['qwen/qwen-image-edit-2511']!, 'dressA');
    expect(q.compatible).toBe(true);
    expect(q.mapping.image).toEqual({ field: 'image', array: true, max: null });
    expect(buildInput(q.mapping, { prompt: 'p', images: ['a', 'b', 'c'], width: 768, height: 1024, matchInput: true, seed: 1 }))
      .toEqual({ prompt: 'p', image: ['a', 'b', 'c'], aspect_ratio: 'match_input_image', seed: 1, output_format: 'jpg', output_quality: 95 });
    const f = mapModel(MODELS['black-forest-labs/flux-2-pro']!, 'shot');
    expect(f.compatible).toBe(true);
    expect(buildInput(f.mapping, { prompt: 'p', images: ['a', 'b'], width: 1080, height: 1920, outMp: 2, seed: 3 }))
      .toEqual({ prompt: 'p', input_images: ['a', 'b'], aspect_ratio: '9:16', resolution: '2 MP', seed: 3, output_format: 'jpg', output_quality: 95 });
    expect(mapModel(MODELS['google/nano-banana']!, 'dressB').mapping.image).toEqual({ field: 'image_input', array: true, max: null });
    expect(mapModel(MODELS['bytedance/seedream-4']!, 'edit')).toMatchObject({ compatible: true, mapping: { image: { field: 'image_input', array: true }, count: 'max_images' } });
  });

  it('upscalers: Clarity (community, number scale + creativity), Topaz (enum scale), Real-ESRGAN', () => {
    const c = mapModel(MODELS['philz1337x/clarity-upscaler']!, 'upscale');
    expect(c).toMatchObject({ compatible: true, mapping: { image: { field: 'image', array: false }, scale: { field: 'scale_factor', kind: 'number' }, strength: { field: 'creativity' } } });
    expect(buildInput(c.mapping, { images: ['a'], scale: 4, strength: 0.2 })).toMatchObject({ image: 'a', scale_factor: 4, creativity: 0.2 });
    const t = mapModel(MODELS['topazlabs/image-upscale']!, 'upscale');
    expect(t.compatible).toBe(true);
    expect(buildInput(t.mapping, { images: ['a'], scale: 2 }).upscale_factor).toBe('2x');
    expect(buildInput(t.mapping, { images: ['a'], scale: 4 }).upscale_factor).toBe('4x');
    // No prompt: Topaz can't do realism, edits or new shots.
    expect(mapModel(MODELS['topazlabs/image-upscale']!, 'realism')).toMatchObject({ compatible: false, reasons: ['has no prompt'] });
    expect(mapModel(MODELS['nightmareai/real-esrgan']!, 'upscale').mapping.scale).toMatchObject({ field: 'scale', kind: 'number', max: 10 });
    expect(mapModel(MODELS['nightmareai/real-esrgan']!, 'edit').compatible).toBe(false);
  });

  it('SDXL (community): new shots and realism, not Dress up; the inputs list for the advanced view', () => {
    const s = mapModel(MODELS['stability-ai/sdxl']!, 'shot');
    expect(s.compatible).toBe(true);
    expect(s.mapping.size).toMatchObject({ width: 'width', height: 'height' });
    expect(buildInput(s.mapping, { prompt: 'p', images: ['a'], width: 1080, height: 1920 })).toMatchObject({ width: 1088, height: 1920, image: 'a', num_outputs: 1 });
    expect(s.inputs.find(i => i.name === 'disable_safety_checker')).toMatchObject({ type: 'boolean', default: false });
    expect(s.inputs.find(i => i.name === 'prompt')!.mappedAs).toBe('prompt');
    expect(mapModel(MODELS['stability-ai/sdxl']!, 'dressB').compatible).toBe(false);
    expect(mapModel({ owner: 'x', name: 'y', latest_version: null }, 'shot')).toMatchObject({ compatible: false, reasons: ["its inputs can't be read"] });
  });
});

describe('prices from model pages (real pages, trimmed)', () => {
  it('per unit (official) and by time (community)', () => {
    const krea = parseModelPage(page('black-forest-labs/flux-krea-dev'))!;
    expect(krea).toEqual({ kind: 'per-unit', source: 'model page', units: [{ metric: 'image_output_count', usd: 0.025, label: 'per output image' }] });
    expect(priceLine(krea)).toBe('$0.025 per output image');
    const flux = parseModelPage(page('black-forest-labs/flux-2-pro'))!;
    expect(priceLine(flux)).toBe('$0.015 per run + $0.015 per input MP + $0.015 per output MP');
    expect(estimateOne(flux, { outMp: 2, inMp: 0.79 * 6 }, EST)).toBeCloseTo(0.015 + 0.015 * 4.74 + 0.015 * 2, 9);
    const clarity = parseModelPage(page('philz1337x/clarity-upscaler'))!;
    expect(clarity).toEqual({ kind: 'per-second', source: 'model page', usdPerSecond: 0.00115, hardware: 'A100 (40GB)', typicalUsd: 0.018 });
    expect(priceLine(clarity)).toBe('by time · about $0.018 a run ($0.00115/s on A100 (40GB))');
    expect(estimateOne(clarity, { outMp: 4, inMp: 1, scale: 4 }, EST)).toBeCloseTo(0.072, 9);
    expect(exactOne(clarity, { predict_time: 12.5 }, { outMp: 4, inMp: 1 }, EST)).toEqual({ usd: 12.5 * 0.00115, estimated: false });
    expect(exactOne(clarity, {}, { outMp: 4, inMp: 1 }, EST)).toEqual({ usd: 0.018, estimated: true });
    expect(parseModelPage(page('topazlabs/image-upscale'))).toMatchObject({ kind: 'per-unit', units: [{ metric: 'unspecified_billing_metric', usd: 0.08 }] });
    expect(parseModelPage(page('qwen/qwen-image-edit-2511'))).toMatchObject({ kind: 'per-unit', units: [{ metric: 'image_output_count', usd: 0.03 }] });
    // Billing counts win; Replicate's own dollar figure wins over everything.
    expect(exactOne(flux, { image_input_megapixel_count: 2, image_output_megapixel_count: 1 }, { outMp: 9, inMp: 9 }, EST).usd).toBeCloseTo(0.015 + 0.03 + 0.015, 9);
    expect(exactOne(flux, { cost_usd: 0.07 }, { outMp: 9, inMp: 9 }, EST).usd).toBe(0.07);
    expect(estimateOne({ kind: 'unknown' }, { outMp: 1, inMp: 1 }, EST)).toBe(0.05);
    expect(parseModelPage('<html>nothing</html>')).toBeNull();
  });
});

describe('model tools on a fake Replicate', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, fake: Awaited<ReturnType<typeof fakeReplicate>>;
  let owner: Client, tess: Client, modelId: string;
  beforeAll(async () => {
    fake = await fakeReplicate();
    a = await makeApp({ REPLICATE_API_TOKEN: TOKEN, REPLICATE_API_URL: fake.base, REPLICATE_WEB_URL: fake.web, REPLICATE_POLL_MS: '10', BALANCE_MODE: 'simulated',
      CAP_PER_DAY_USD: '1000', CAP_PER_USER_DAY_USD: '1000' });
    const p = await people(a, 1); owner = p.owner; tess = p.members[0]!;
    await owner.req('POST', '/v1/wallets/transfer', { toUserId: tess.id, tokens: 2000 });
    modelId = (await demoModel(owner)).id;
  }, 60_000);
  afterAll(async () => { await a?.close(); await fake?.close(); });
  const run = (c: Client, id: string) => until(async () => { const r = (await c.req('GET', `/v1/tool-runs/${id}`)).body; return r.state !== 'running' && r.items.every((i: any) => i.state !== 'running') ? r : null; }, 30_000);

  it('image models: owner-only steps, catalog per step with compatibility and prices, change with checks, reset', async () => {
    expect((await tess.req('GET', '/v1/image-models')).body.code).toBe('owner_only');
    expect((await tess.req('GET', '/v1/image-models/catalog?step=upscale')).status).toBe(403);
    const v = (await owner.req('GET', '/v1/image-models')).body;
    expect(v.steps.map((s: any) => [s.step, s.model, s.isDefault])).toEqual([
      ['shot', 'black-forest-labs/flux-2-pro', true], ['edit', 'qwen/qwen-image-edit-2511', true], ['realism', 'black-forest-labs/flux-krea-dev', true],
      ['upscale', 'philz1337x/clarity-upscaler', true]]); // Dress up's steps are hidden (removed 2026-11-11)
    expect(v.steps.find((s: any) => s.step === 'upscale')).toMatchObject({ official: false, priceLine: 'by time · about $0.018 a run ($0.00115/s on A100 (40GB))', compatible: true });
    expect(v.steps.find((s: any) => s.step === 'realism').priceLine).toBe('$0.025 per output image');
    const cat = (await owner.req('GET', '/v1/image-models/catalog?step=upscale')).body;
    expect(cat.models.map((m: any) => m.id)).toEqual(['nightmareai/real-esrgan', 'philz1337x/clarity-upscaler', 'topazlabs/image-upscale']);
    expect(cat.models.every((m: any) => m.compatible === true && m.priceLine)).toBe(true);
    expect(cat.collections.map((c: any) => c.slug)).toEqual(['super-resolution', 'ai-image-restoration']);
    const realism = (await owner.req('GET', '/v1/image-models/catalog?step=realism')).body;
    expect(realism.models.find((m: any) => m.id === 'stability-ai/sdxl')).toMatchObject({ compatible: true, official: false });
    const dress = (await owner.req('GET', '/v1/image-models/catalog?step=dressA')).body;
    expect(dress.models.find((m: any) => m.id === 'google/nano-banana').compatible).toBe(true);
    // Search results come without a schema: each is read, so compatibility is filled.
    const found = (await owner.req('GET', '/v1/image-models/catalog?step=realism&q=upscale')).body;
    expect(found.models.find((m: any) => m.id === 'topazlabs/image-upscale')).toMatchObject({ compatible: false, reasons: ['has no prompt'] });
    // Paste any owner/model.
    const d = (await owner.req('GET', '/v1/image-models/model?id=stability-ai/sdxl&step=shot')).body;
    expect(d).toMatchObject({ id: 'stability-ai/sdxl', compatible: true, version: MODELS['stability-ai/sdxl']!.latest_version!.id });
    expect(d.inputs.length).toBeGreaterThan(10);
    expect((await owner.req('GET', '/v1/image-models/model?id=nobody/nothing&step=shot')).status).toBe(404);
    // Change: incompatible refused, safety switch refused, unknown extra refused, then a good one.
    const bad = await owner.req('PUT', '/v1/image-models/realism', { model: 'topazlabs/image-upscale' });
    expect(bad.status).toBe(400); expect(bad.body).toMatchObject({ code: 'model_incompatible' });
    expect((await owner.req('PUT', '/v1/image-models/realism', { model: 'stability-ai/sdxl', extra: { disable_safety_checker: true } })).status).toBe(400);
    expect((await owner.req('PUT', '/v1/image-models/realism', { model: 'stability-ai/sdxl', extra: { nope: 1 } })).status).toBe(400);
    expect((await tess.req('PUT', '/v1/image-models/realism', { model: 'stability-ai/sdxl' })).status).toBe(403);
    const ok = (await owner.req('PUT', '/v1/image-models/upscale', { model: 'topazlabs/image-upscale', extra: { enhance_model: 'High Fidelity V2' } })).body;
    expect(ok).toMatchObject({ step: 'upscale', model: 'topazlabs/image-upscale', isDefault: false, extra: { enhance_model: 'High Fidelity V2' } });
    expect((await owner.req('DELETE', '/v1/image-models/upscale')).body).toMatchObject({ model: 'philz1337x/clarity-upscaler', isDefault: true });
    // Members' settings carry the tools without model names; the owner's carry the defaults.
    const ms = (await tess.req('GET', '/v1/settings/studio')).body.features.tools;
    expect(ms.dressUp).toBeUndefined(); // Dress up was removed (owner 2026-11-11)
    expect(JSON.stringify(ms)).not.toMatch(/qwen|flux|clarity|replicate/i);
    expect((await owner.req('GET', '/v1/settings/studio')).body.features.tools.enhance.models.realism.model).toBe('black-forest-labs/flux-krea-dev');
  });

  it('Enhance: estimate, one seed and prompt for all 7, realism then upscale, exact settle, review, apply with a previous version, restore', async () => {
    const est = (await tess.req('POST', `/v1/models/${modelId}/enhance/estimate`, {})).body;
    expect(est).toMatchObject({ images: 7, label: '7 images · about $0.30' });
    expect(est.estimate).toBeCloseTo(7 * (0.025 + 0.018), 9);
    expect((await tess.req('POST', `/v1/models/${modelId}/enhance`, { models: { realism: 'stability-ai/sdxl' } })).body.code).toBe('owner_only');
    expect((await tess.req('POST', `/v1/models/${modelId}/enhance`, { realism: 'off', upscale: 'off' })).status).toBe(400);
    const before = fake.state.creates.length;
    const start = (await tess.req('POST', `/v1/models/${modelId}/enhance`, { realism: 'strong', upscale: '4x' })).body;
    expect(start).toMatchObject({ kind: 'enhance', state: 'running', engines: ['a'] });
    expect(start.models).toBeUndefined(); // members never see model names
    expect(start.items.map((i: any) => i.slot)).toEqual(['face', 'faceTq', 'profile', 'front', 'tq', 'side', 'back']);
    const r = await run(tess, start.id);
    expect(r.state).toBe('review');
    const made = fake.state.creates.slice(before);
    expect(made.length).toBe(14);
    const krea = made.filter(p => p.model === 'black-forest-labs/flux-krea-dev'), clarity = made.filter(p => p.model === 'philz1337x/clarity-upscaler');
    expect(krea.length).toBe(7); expect(clarity.length).toBe(7);
    expect(new Set(krea.map(p => p.input.seed)).size).toBe(1);
    expect(new Set(krea.map(p => p.input.prompt)).size).toBe(1);
    expect(krea[0]!.input).toMatchObject({ prompt_strength: 0.5, num_outputs: 1, output_format: 'jpg' });
    expect(krea[0]!.input.prompt).toMatch(/^candid smartphone photo, natural skin texture/);
    expect(krea[0]!.version).toBeUndefined(); // official: by name
    expect(clarity[0]!.version).toBe(MODELS['philz1337x/clarity-upscaler']!.latest_version!.id); // community: by version
    expect(clarity[0]!.input).toMatchObject({ scale_factor: 4, creativity: 0.2, resemblance: 1 });
    expect(clarity[0]!.input.prompt).toBeUndefined();
    for (const p of made) expect(Object.keys(p.input)).not.toContain('disable_safety_checker');
    // Exact: Krea $0.025 per image, Clarity 10 s × $0.00115.
    const exact = 7 * (0.025 + 10 * 0.00115);
    expect(r.cost).toBeCloseTo(exact, 9);
    const rows = await a.ctx.db.select().from(ledger).where(eq(ledger.jobId, start.id));
    expect(rows.find(x => x.kind === 'settle')!.amountUsd).toBeCloseTo(exact, 9);
    // Review: keep 6, reject one, retry one (holds and settles on its own).
    expect((await tess.req('POST', `/v1/tool-runs/${start.id}/apply`, {})).status).toBe(400); // nothing kept yet
    for (const i of r.items) await tess.req('PATCH', `/v1/tool-runs/${start.id}/items/${i.slot}`, { decision: i.slot === 'back' ? 'reject' : 'keep' });
    const retried = (await tess.req('POST', `/v1/tool-runs/${start.id}/items/side/retry`, {})).body;
    expect(retried.items.find((i: any) => i.slot === 'side')).toMatchObject({ state: 'running', decision: 'pending' });
    const after = await run(tess, start.id);
    expect(after.items.find((i: any) => i.slot === 'side')).toMatchObject({ state: 'done', decision: 'pending' });
    await tess.req('PATCH', `/v1/tool-runs/${start.id}/items/side`, { decision: 'keep' });
    const applied = (await tess.req('POST', `/v1/tool-runs/${start.id}/apply`, {})).body;
    expect(applied.run.state).toBe('applied');
    const slots = Object.fromEntries(applied.model.slots.map((s: any) => [s.key, s]));
    expect(slots.face.image.url).toMatch(/\/uploads\/g\//);
    expect(slots.face.source).toBe('generated');
    expect(slots.back.image).toEqual({ asset: 'g_back' }); // rejected: unchanged
    const versions = (await tess.req('GET', `/v1/models/${modelId}/sheet-versions`)).body;
    expect(versions.length).toBe(1);
    expect(versions[0].slots.find((s: any) => s.key === 'face').image).toEqual({ asset: 'face' });
    const restored = (await tess.req('POST', `/v1/models/${modelId}/sheet-versions/${versions[0].id}/restore`)).body;
    expect(restored.slots.find((s: any) => s.key === 'face').image).toEqual({ asset: 'face' });
    expect((await tess.req('GET', `/v1/models/${modelId}/sheet-versions`)).body[0].reason).toBe('restore');
  }, 60_000);

  it('every outfit comes with its own face close-ups: priced in, edits of her base faces with the outfit front, 7 pictures, sent alone', async () => {
    // Dress up is gone: older builds hear why.
    const gone = await owner.req('POST', `/v1/models/${modelId}/dress-up`, { outfitImage: { asset: 'c_front' } });
    expect(gone.status).toBe(410); expect(gone.body.code).toBe('dress_up_removed');
    const est = (await owner.req('POST', '/v1/outfits', { modelId, name: 'Linen', mode: 'describe', description: 'a linen shirt', dryRun: true })).body;
    expect(est).toMatchObject({ dryRun: true, images: 7, faces: 3 });
    expect(est.faceCost).toBeGreaterThan(0);
    expect(est.cost).toBeCloseTo(est.bodyCost + est.faceCost, 9);
    const before = fake.state.creates.length;
    const o = (await owner.req('POST', '/v1/outfits', { modelId, name: 'Linen', mode: 'describe', description: 'a linen shirt' })).body;
    const done = await until(async () => { const x = (await owner.req('GET', '/v1/outfits')).body.find((y: any) => y.id === o.id); return x?.state === 'preview' ? x : null; }, 30_000);
    const made = fake.state.creates.slice(before);
    expect(made.length).toBe(7);
    const faces = made.slice(4);
    expect(faces.map(p => p.input.prompt)).toEqual([0, 1, 2].map(i => Live.outfitFacePrompt(i)));
    // Each face edits her base face photo of that angle; the outfit's new front goes with it.
    const urls = (p: any) => JSON.stringify(p.input);
    // Each face edits her base face photo of that angle (first), with the outfit's new front (last, the same for all three).
    expect(faces.every(p => p.input.image.length === 2)).toBe(true);
    expect(new Set(faces.map(p => p.input.image[1].split('?')[0])).size).toBe(1);
    expect(new Set(faces.map(p => p.input.image[0].split('?')[0])).size).toBe(3);
    expect(done.faces.every((x: any) => x?.url)).toBe(true);
    expect(done.angles.every((x: any) => x?.url)).toBe(true);
    // Shots with it send ONLY the outfit's images: its faces, then its angles (never her base face or body).
    const [m] = await a.ctx.db.query.models.findMany({ where: (t, { eq: e }) => e(t.id, modelId) });
    const [row] = await a.ctx.db.query.outfits.findMany({ where: (t, { eq: e }) => e(t.id, o.id) });
    const rep = replicateReferencesFor(m!, row!);
    expect(rep.map(x => x.label)).toEqual(['face, front', 'outfit, front', 'face, ¾', 'face, profile', 'outfit, ¾', 'outfit, side', 'outfit, back']);
    expect(rep[0]!.image).toEqual(done.faces[0]);
    const base = m!.slots.filter(s => s.image).map(s => JSON.stringify(s.image));
    expect(rep.some(x => base.includes(JSON.stringify(x.image)))).toBe(false);
    expect(referencesFor(m!, row!).length).toBe(6);
    // An older outfit without faces: her base face front only, plus the angles, and it says so.
    const old = replicateReferencesFor(m!, { ...row!, faces: null });
    expect(old.map(x => x.label)).toEqual(['face, front', 'outfit, front', 'outfit, ¾', 'outfit, side', 'outfit, back']);
    expect(old[0]!.why).toMatch(/no face close-ups yet/);
    // Add face close-ups (paid, priced first) and Redo one face.
    await a.ctx.db.update(outfitsT).set({ faces: null }).where(eq(outfitsT.id, o.id));
    const add = (await owner.req('POST', `/v1/outfits/${o.id}/faces`, { dryRun: true })).body;
    expect(add).toMatchObject({ dryRun: true, faces: 3, images: 3 });
    expect(add.cost).toBeCloseTo(est.faceCost, 9);
    const n2 = fake.state.creates.length;
    await owner.req('POST', `/v1/outfits/${o.id}/faces`, {});
    const filled = await until(async () => { const x = (await owner.req('GET', '/v1/outfits')).body.find((y: any) => y.id === o.id); return x?.faces?.every(Boolean) ? x : null; }, 30_000);
    expect(fake.state.creates.length - n2).toBe(3);
    const redo = (await owner.req('POST', `/v1/outfits/${o.id}/redo`, { angle: 'faceTq', dryRun: true })).body;
    expect(redo).toMatchObject({ dryRun: true, faces: 1, images: 1 });
    const n3 = fake.state.creates.length;
    await owner.req('POST', `/v1/outfits/${o.id}/redo`, { angle: 'faceTq' });
    await until(async () => { const x = (await owner.req('GET', '/v1/outfits')).body.find((y: any) => y.id === o.id); return x?.faces?.[1]?.url !== filled.faces[1].url ? x : null; }, 30_000);
    expect(fake.state.creates.slice(n3).map(p => p.input.prompt)).toEqual([Live.outfitFacePrompt(1)]);
    expect((await owner.req('POST', `/v1/outfits/${o.id}/redo`, { angle: 'nose' })).status).toBe(400);
  }, 60_000);

  it('a per-run model for one photoshoot (owner): any model via the mapping, priced from its page', async () => {
    const before = fake.state.creates.length;
    const shots = (await owner.req('POST', '/v1/shoots', { modelId, scene: 'Café', count: 1, models: { shot: 'google/nano-banana' } })).body;
    expect(shots.length).toBe(1);
    const p = fake.state.creates[before]!;
    expect(p.model).toBe('google/nano-banana');
    expect(p.input.image_input.length).toBeGreaterThan(1);
    expect((await tess.req('POST', '/v1/shoots', { modelId, scene: 'Café', count: 1, models: { shot: 'google/nano-banana' } })).body.code).toBe('owner_only');
  }, 60_000);

  it('archive: hidden everywhere, no new work, owner-only list, restore', async () => {
    const m2 = (await owner.req('POST', '/v1/models', { name: 'Old model', age: 30, niche: 'x' })).body;
    expect((await tess.req('POST', `/v1/models/${m2.id}/archive`)).status).toBe(403);
    expect((await owner.req('POST', `/v1/models/${m2.id}/archive`)).body).toMatchObject({ archived: true });
    expect((await tess.req('GET', '/v1/models')).body.some((m: any) => m.id === m2.id)).toBe(false);
    expect((await tess.req('GET', '/v1/models?archived=true')).body.code).toBe('owner_only');
    expect((await owner.req('GET', '/v1/models?archived=true')).body.map((m: any) => m.id)).toEqual([m2.id]);
    for (const [method, url, body] of [['POST', '/v1/shoots', { modelId: m2.id, count: 1 }], ['POST', `/v1/models/${m2.id}/fill-angles`, undefined],
      ['POST', `/v1/models/${m2.id}/enhance`, {}], ['POST', '/v1/jobs', { title: 'x', modelId: m2.id }], ['POST', `/v1/models/${m2.id}/lora/candidates`, undefined]] as const) {
      const r = await owner.req(method, url, body);
      expect(r.status, url).toBe(409); expect(r.body.code).toBe('model_archived');
    }
    expect((await owner.req('POST', `/v1/models/${m2.id}/unarchive`)).body).toMatchObject({ archived: false });
    expect((await tess.req('GET', '/v1/models')).body.some((m: any) => m.id === m2.id)).toBe(true);
  });
});

describe('model tools without Replicate (simulated)', () => {
  it('runs at the estimate with the known prices', async () => {
    const a = await makeApp({ BALANCE_MODE: 'simulated' });
    try {
      const { owner } = await people(a, 0);
      const m = await demoModel(owner);
      const est = (await owner.req('POST', `/v1/models/${m.id}/enhance/estimate`, { upscale: 'off' })).body;
      expect(est).toMatchObject({ images: 7, label: '7 images · about $0.18' });
      const s = (await owner.req('POST', `/v1/models/${m.id}/enhance`, { upscale: 'off' })).body;
      const r = await until(async () => { const x = (await owner.req('GET', `/v1/tool-runs/${s.id}`)).body; return x.state === 'review' ? x : null; });
      expect(r.cost).toBeCloseTo(7 * 0.025, 9);
      expect((await owner.req('GET', '/v1/image-models')).body.steps[0].priceLine).toBe('$0.015 per run + $0.015 per input MP + $0.015 per output MP');
    } finally { await a.close(); }
  });
});
