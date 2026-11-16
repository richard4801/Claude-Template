// Claude's Suite reports (2026-11-15): suite_estimate prices a Photo draft as Photo (ci_40e89e2a9fd6 / ci_6e22b530e992),
// the app's first sync can't echo Claude's change away, prompts up to the pinned model's own limit (ci_9a79f3707f79),
// start / end frames from a take's last frame, an upload or a still (ci_91473102d2b0), images sent per tool with the
// warning in suite_get_draft (ci_62c3c2fdcdbf). Mock providers: nothing is spent.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { takes, uploads, users } from '../src/db/schema.js';
import { registryByName } from '../src/claude/registry.js';
import { promptLimit } from '../src/suite/assist.js';
import { lastFrame } from '../src/images/sent.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, ownerU: AuthUser, model: { id: string };
const run = (name: string, args: Record<string, unknown>) => registryByName.get(name)!.run({ ctx: a.ctx, user: ownerU, source: 'chat' } as any, args) as Promise<any>;
const words = (n: number) => 'She walks slowly along the wet pier at dusk, '.repeat(Math.ceil(n / 45)).slice(0, n).trim();
async function upload(body: Buffer, contentType: string, kind: 'image' | 'clip' = 'image') {
  const p = (await owner.req('POST', '/v1/uploads/presign', { kind, contentType, bytes: body.length })).body;
  const u = new URL(p.url);
  const r = await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': contentType }, payload: body });
  expect(r.statusCode).toBe(200);
  const c = await owner.req('POST', `/v1/uploads/${p.uploadId}/confirm`, kind === 'clip' ? { meta: { title: 'x', durationSec: 2, width: 64, height: 64, fps: 24 } } : {});
  expect(c.status, JSON.stringify(c.body)).toBeLessThan(300);
  return p.uploadId as string;
}
const newDraft = async (draft?: Record<string, unknown>) => (await owner.req('POST', '/v1/suite/assist', draft ? { draft } : {})).body.id as string;
const get = async (id: string) => (await owner.req('GET', `/v1/suite/assist/${id}`)).body;
const patch = async (id: string, draft: Record<string, unknown>) => {
  const cur = await get(id);
  const r = await owner.req('PATCH', `/v1/suite/assist/${id}`, { draft, baseRevision: cur.revision });
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  return r.body;
};

beforeAll(async () => {
  a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
  ({ owner } = await people(a, 0, { topUp: 100 }) as any);
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
  model = await demoModel(owner) as any;
});
afterAll(async () => { await a?.close(); });

describe('suite_estimate on a Photo draft (ci_40e89e2a9fd6, ci_6e22b530e992)', () => {
  it('is priced as Photo on the pinned image model, never as a Shot', async () => {
    const id = await newDraft({ v: 1, tool: 'photo', count: 4 });
    await run('suite_set_draft', { assistId: id, modelId: model.id, prompt: 'A still of her on the pier', engineModel: 'google/nano-banana-pro', count: 1 });
    const v = await get(id);
    expect(v.request).toMatchObject({ imageModel: 'google/nano-banana-pro', count: 1, modelId: model.id });
    expect(v.request.engineModel).toBeUndefined();
    const e = await run('suite_estimate', { assistId: id });
    expect(e.tool).toBe('photo');
    expect(e.estimate).toMatchObject({ tool: 'photo', count: 1, ok: true });
    // The same price the Photo composer's own estimate gives.
    const direct = await owner.req('POST', '/v1/suite/photos/estimate', v.request);
    expect(direct.status, JSON.stringify(direct.body)).toBe(200);
    expect(e.estimate.estimate).toBe(direct.body.estimate);
  });

  it('the app\'s first sync after Claude\'s change can\'t echo it away; later edits by the person stand', async () => {
    const id = await newDraft({ v: 1, tool: 'photo', count: 4 });
    const old = { v: 1, tool: 'photo', count: 4, tokens: [] };
    await run('suite_set_draft', { assistId: id, engineModel: 'google/nano-banana-pro', count: 1, outfitId: 'of_claude' });
    // The app opens and pushes its composer from before Claude's change.
    const n = await patch(id, old);
    expect(n.draft).toMatchObject({ engineModel: 'google/nano-banana-pro', count: 1, outfitId: 'of_claude' });
    // The person then picks 2 stills and Auto: that stands.
    const m = await patch(id, { ...old, count: 2 });
    expect(m.draft.count).toBe(2);
    expect(m.draft.engineModel).toBeUndefined();
    // Undo on "What I changed" (the card): the app's sync showing the old value then stands.
    await run('suite_set_draft', { assistId: id, count: 4 });
    await a.ctx.db.execute(sql`select 1`);
    await (await import('../src/suite/assist.js')).assistOf(a.ctx).rewrite(ownerU, id, d => ({ ...d, count: 2 }));
    expect((await patch(id, { ...old, count: 2 })).draft.count).toBe(2);
    // A sync that already carries Claude's values isn't touched.
    await run('suite_set_draft', { assistId: id, count: 3 });
    expect((await patch(id, { ...old, count: 3 })).draft.count).toBe(3);
  });
});

describe('prompt length by the chosen model (ci_9a79f3707f79)', () => {
  it('the limit is the pinned model\'s promptMax, MUSE\'s ceiling under Auto, Photo\'s own', () => {
    expect(promptLimit('shot', 'seedance-2.0')).toMatchObject({ max: 4000, why: 'Seedance 2.0 takes at most 4000 characters' });
    expect(promptLimit('shot', 'kling-v3')).toMatchObject({ max: 2500 });
    expect(promptLimit('shot').max).toBe(8000);
    expect(promptLimit('photo', 'google/nano-banana-pro').max).toBe(2000);
  });
  it('suite_set_draft takes 3500 characters for Seedance 2.0 and names the model when it is too long', async () => {
    const id = await newDraft();
    const ok = await run('suite_set_draft', { assistId: id, modelId: model.id, engineModel: 'seedance-2.0', prompt: words(3500) });
    expect(ok.request.prompt.length).toBeGreaterThan(3400);
    await expect(run('suite_set_draft', { assistId: id, prompt: words(4300) })).rejects.toThrow(/4300 characters, but Seedance 2\.0 takes at most 4000 characters/);
    // Pinning a model that takes less checks the prompt already there.
    await expect(run('suite_set_draft', { assistId: id, engineModel: 'kling-v3' })).rejects.toThrow(/Kling 3\.0 takes at most 2500/);
    // Auto: up to 8000; the request still validates (no flat 2000 left).
    await run('suite_set_draft', { assistId: id, engineModel: null, prompt: words(5000) });
    const e = await run('suite_estimate', { assistId: id });
    expect(e.estimate).toBeTruthy();
    await expect(run('suite_set_draft', { assistId: id, prompt: words(8100) })).rejects.toThrow(/8000/);
  });
  it('Photo says it is Photo\'s limit', async () => {
    const id = await newDraft({ v: 1, tool: 'photo', count: 1 });
    await expect(run('suite_set_draft', { assistId: id, prompt: words(2400) })).rejects.toThrow(/a Photo prompt takes at most 2000/);
  });
});

describe('start / end frames (ci_91473102d2b0)', () => {
  it('"last" is the video\'s very last picture (red, then blue: blue)', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-last-'));
    const mp4 = path.join(dir, 'rb.mp4');
    execFileSync('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=red:s=32x32:r=24:d=1.5', '-f', 'lavfi', '-i', 'color=c=blue:s=32x32:r=24:d=0.08',
      '-filter_complex', '[0][1]concat=n=2:v=1', '-pix_fmt', 'yuv420p', mp4]);
    const jpg = await lastFrame('ffmpeg', mp4, { encoding: 'buffer', maxBuffer: 1 << 24, timeout: 30_000 });
    const { data } = await sharp(jpg).raw().toBuffer({ resolveWithObject: true });
    expect(data[2]!).toBeGreaterThan(150); // blue
    expect(data[0]!).toBeLessThan(80);
    fs.rmSync(dir, { recursive: true, force: true });
  });
  it('a take\'s last frame, an upload and a still go in the slots Generate sends; the person\'s later pick wins', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-frames-'));
    const mp4 = path.join(dir, 'clip.mp4');
    execFileSync('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=24:duration=2', '-pix_fmt', 'yuv420p', mp4]);
    const clipUp = await upload(fs.readFileSync(mp4), 'video/mp4', 'clip');
    // No HTTP server in tests: ffmpeg reads the stored clip straight from disk.
    const get0 = a.ctx.storage.presignGet.bind(a.ctx.storage);
    a.ctx.storage.presignGet = (async () => mp4) as any;
    const [up] = await a.ctx.db.select().from(uploads).where(eq(uploads.id, clipUp));
    const takeId = 'tk_chain1';
    await a.ctx.db.insert(takes).values({ id: takeId, studioId: ownerU.studioId, userId: ownerU.id, kind: 'take', index: 1, of: 1, title: 'Clip 1', label: 'Clip 1',
      cost: 0, seed: 0, status: 'test', mediaKey: up!.storageKey, createdAt: Date.now() } as any);
    const still = await upload(await sharp({ create: { width: 48, height: 64, channels: 3, background: '#406080' } }).jpeg().toBuffer(), 'image/jpeg');

    const id = await newDraft();
    const v = await run('suite_set_draft', { assistId: id, modelId: model.id, prompt: 'She turns to the sea', startFrame: { takeId, at: 'last' }, endFrame: { uploadId: still, label: 'the pier at dusk' } });
    expect(v.request.frames.start.url).toMatch(/\/uploads\/g\/frame_tk_chain1_last\.jpg$/);
    expect(v.request.frames.end.url).toMatch(/^\/uploads\/u\//);
    expect(v.draft.frames.start.label).toBe('last frame of tk_chain1');
    a.ctx.storage.presignGet = get0;
    fs.rmSync(dir, { recursive: true, force: true });
    // The app's next sync (it doesn't know Claude's frames) keeps them.
    const after = await patch(id, { ...v.draft, frames: undefined, screen: { tool: 'shot', request: { frames: {} } } });
    expect(after.request.frames.start.url).toMatch(/frame_tk_chain1_last/);
    // The person puts their own picture in the start slot: theirs wins; Claude's end frame stays.
    const theirs = await patch(id, { ...after.draft, screen: { tool: 'shot', request: { frames: { start: { asset: 'face' } } } } });
    expect(theirs.request.frames.start).toEqual({ asset: 'face' });
    expect(theirs.request.frames.end.url).toMatch(/^\/uploads\/u\//);
    // null empties Claude's frame; a still works as {takeId}; frames are Shot's only.
    const cleared = await run('suite_set_draft', { assistId: id, endFrame: null });
    expect(cleared.draft.frames?.end).toBeUndefined();
    const est = await run('suite_estimate', { assistId: id });
    expect(est.estimate).toBeTruthy();
    const photo = await newDraft({ v: 1, tool: 'photo', count: 1 });
    await expect(run('suite_set_draft', { assistId: photo, startFrame: { uploadId: still } })).rejects.toMatchObject({ code: 'not_a_shot' });
    await expect(run('suite_set_draft', { assistId: id, startFrame: { takeId, uploadId: still } })).rejects.toMatchObject({ code: 'bad_request' });
  });
});

describe('images sent per tool (ci_62c3c2fdcdbf)', () => {
  it('a Shot doesn\'t inherit Photo\'s list; a reset sticks through the app\'s next sync; suite_get_draft warns', async () => {
    const id = await newDraft({ v: 1, tool: 'photo', count: 1 });
    await run('suite_set_draft', { assistId: id, modelId: model.id });
    const list = [{ image: { asset: 'face' }, role: 'person' }];
    const photoSent = { sentImages: list, sentImagesBy: 'claude' };
    await a.ctx.db.execute(sql`select 1`);
    await (await import('../src/suite/assist.js')).assistOf(a.ctx).setSent(ownerU, id, photoSent as any);
    const cur = await get(id);
    expect(cur.draft.sent).toEqual(photoSent);
    // The app switches to Shot carrying the composer's (Photo's) list: the Shot gets none.
    const shot = await patch(id, { ...cur.draft, tool: 'shot', claudeSet: undefined });
    expect(shot.draft.sent).toBeUndefined();
    expect(shot.draft.sentByTool.photo).toEqual(photoSent);
    // Back on Photo, its own list returns.
    const back = await patch(id, { ...shot.draft, tool: 'photo', sent: undefined });
    expect(back.draft.sent).toEqual(photoSent);
    // A reset, then the app's sync with the old list: the reset sticks.
    await run('set_sent_images', { assistId: id, reset: true });
    const synced = await patch(id, { ...back.draft, sent: photoSent });
    expect(synced.draft.sent).toBeUndefined();

    // A list the model can't take shows in suite_get_draft, as on screen.
    const s2 = await newDraft();
    await run('suite_set_draft', { assistId: s2, modelId: model.id, prompt: 'She waves' });
    const many = Array.from({ length: 14 }, () => ({ image: { asset: 'face' }, role: 'person' }));
    await (await import('../src/suite/assist.js')).assistOf(a.ctx).setSent(ownerU, s2, { sentImages: many, sentImagesBy: 'claude' } as any);
    const g = await run('suite_get_draft', { assistId: s2 });
    expect(g.sentImagesWarning).toMatch(/This model takes (no images here|up to \d+ image)/);
    expect(g.sentImagesWarning).toMatch(/set_sent_images reset/);
    const fine = await run('suite_get_draft', { assistId: id });
    expect(fine.sentImagesWarning).toBeUndefined();
  });
});

describe('suite_estimate on Auto and with no character (ci_5bb0ab964dd8)', () => {
  it('prices a shot with no character as Generate would (no "Pick the model first"), and says what Auto picks', async () => {
    const id = await newDraft();
    await run('suite_set_draft', { assistId: id, prompt: 'Waves roll onto an empty pier at dusk' });
    const e = await run('suite_estimate', { assistId: id });
    const v = await get(id);
    const direct = await owner.req('POST', '/v1/suite/shots/estimate', v.request);
    expect(direct.status, JSON.stringify(direct.body)).toBe(200);
    expect(e.estimate.estimate).toBe(direct.body.estimate);
    expect(e.note).toBe('No character picked: priced as a shot without her (suite_set_draft modelId adds her).');
    expect(e).toMatchObject({ engineChoice: 'auto', autoPicks: e.estimate.engine.label });
    // With her, on Auto: no warning about the character; still Auto.
    await run('suite_set_draft', { assistId: id, modelId: model.id });
    const her = await run('suite_estimate', { assistId: id });
    expect(her.note).toBeUndefined();
    expect(her.engineChoice).toBe('auto');
    // A pinned model: priced on it, no Auto fields.
    await run('suite_set_draft', { assistId: id, engineModel: 'seedance-2.0' });
    const pinned = await run('suite_estimate', { assistId: id });
    expect(pinned.engineChoice).toBeUndefined();
    expect(pinned.estimate.engine.model).toMatch(/seedance-2\.0/);
  });
});
