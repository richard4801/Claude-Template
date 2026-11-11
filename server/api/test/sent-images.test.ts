// Images sent (owner, 2026-11-11): Claude and the person can choose the images a generation sends (images/sent.ts).
// The choice replaces MUSE's pick in its order, the model's limit is refused in plain words, "Image n" in the prompt
// follows the choice, every estimate returns sentImages, and only this studio's images are accepted. No money.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { uploads, users } from '../src/db/schema.js';
import { applySent, type SentImage } from '../src/images/sent.js';
import { registryByName } from '../src/claude/registry.js';
import { putObject } from '../src/storage/objects.js';
import type { AuthUser } from '../src/ctx.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

const S = (asset: string, role: SentImage['role'] = 'person', label = asset): SentImage => ({ image: { asset }, role, label, why: 'auto' });

describe('images sent (unit)', () => {
  const auto = [S('face', 'person', 'face'), S('c_face', 'person', 'face ¾'), S('g_front', 'person', 'body')];
  it('automatic, replace (order kept), add, exclude', () => {
    expect(applySent(auto, null, 8)).toMatchObject({ changed: false, max: 8 });
    const r = applySent(auto, { list: [S('g_back', 'person', 'back'), S('face')], add: [], exclude: [], by: 'claude' }, 8);
    expect(r.images.map(x => (x.image as any).asset)).toEqual(['g_back', 'face']);
    expect(r).toMatchObject({ changed: true, changedBy: 'claude' });
    expect(r.images[1]!.why).toBe('auto · auto'); // one of MUSE's own keeps its reason
    const adj = applySent(auto, { add: [S('g_side', 'person', 'side')], exclude: [{ asset: 'c_face' }], by: 'person' }, 8);
    expect(adj.images.map(x => (x.image as any).asset)).toEqual(['face', 'g_front', 'g_side']);
    expect(applySent(auto, { add: [], exclude: [], by: 'person', reset: true }, 8).changed).toBe(false);
  });
  it('refuses more than the model takes (never drops silently) and too few where needed', () => {
    expect(() => applySent(auto, { list: [S('a'), S('b'), S('c')], add: [], exclude: [], by: 'claude' }, 2)).toThrow('This model takes up to 2 images · 3 chosen');
    expect(() => applySent(auto, { list: [], add: [], exclude: [], by: 'claude' }, 6, { min: 1 })).toThrow('Send at least 1 image of her');
  });
});

describe('images sent (routes, fake engines)', () => {
  let a: Awaited<ReturnType<typeof makeApp>>, owner: Client, member: Client, model: { id: string }, uploadId: string, studioId: string, ownerUser: AuthUser;
  beforeAll(async () => {
    a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
    ({ owner, members: [member] } = await people(a, 1, { topUp: 100 }) as any);
    model = await demoModel(owner);
    const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
    studioId = u!.studioId!;
    ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null } as AuthUser;
    const jpg = await sharp({ create: { width: 64, height: 64, channels: 3, background: '#c08' } }).jpeg().toBuffer();
    await putObject(a.ctx, { key: 'u/sent-test.jpg', body: jpg, studioId, kind: 'image', contentType: 'image/jpeg' });
    await putObject(a.ctx, { key: 'u/other-studio.jpg', body: jpg, studioId: 'st_other', kind: 'image', contentType: 'image/jpeg' });
    uploadId = (await a.ctx.db.select().from(uploads).where(eq(uploads.storageKey, 'u/sent-test.jpg')))[0]!.id;
  });
  afterAll(async () => { await a?.close(); });

  it('Photo estimate: MUSE\'s pick with why; a choice replaces it, its price follows and "image n" follows its order', async () => {
    const auto = (await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, count: 1 })).body;
    expect(auto.sentImages).toMatchObject({ changed: false, max: 8 });
    expect(auto.sentImages.images.map((x: any) => [x.image.asset, x.role])).toEqual([['face', 'person'], ['c_face', 'person'], ['g_front', 'person']]);
    expect(auto.sentImages.images[0].why).toMatch(/face, front/);
    const chosen = (await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, count: 1,
      sentImages: [{ image: uploadId, role: 'pose', label: 'the lean' }, { image: { asset: 'face' }, role: 'person', label: 'face' }] })).body;
    expect(chosen.sentImages).toMatchObject({ changed: true, changedBy: 'person' });
    expect(chosen.sentImages.images.map((x: any) => x.role)).toEqual(['pose', 'person']);
    expect(chosen.sentImages.images[0].image.url).toMatch(/\/uploads\/u\/sent-test\.jpg$/);
    expect(chosen.prompt).toMatch(/from image 1\b/); // the pose reference is image 1 now
    expect(chosen.perPhoto).toBeLessThan(auto.perPhoto); // 2 images in, not 3
    const added = (await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, count: 1, addImages: [{ image: { asset: 'g_back' }, role: 'person', label: 'back' }], excludeImages: [{ asset: 'c_face' }] })).body;
    expect(added.sentImages.images.map((x: any) => x.image.asset)).toEqual(['face', 'g_front', 'g_back']);
  });

  it('refuses more images than the model takes, and images outside this studio', async () => {
    const nine = Array.from({ length: 9 }, () => ({ image: { asset: 'face' }, role: 'person' }));
    const r = await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, sentImages: nine });
    expect(r.status).toBe(400);
    expect(JSON.stringify(r.body)).toMatch(/This model takes up to 8 images/);
    const other = await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, sentImages: [{ image: { url: 'http://x/uploads/u/other-studio.jpg' }, role: 'style' }] });
    expect(other.status).toBe(400);
    expect(JSON.stringify(other.body)).toMatch(/isn’t in this studio/);
    const outside = await member.req('POST', '/v1/suite/photos/estimate', { modelId: model.id, sentImages: [{ image: { url: 'https://example.com/a.jpg' }, role: 'style' }] });
    expect(outside.status).toBe(400);
  });

  it('Suite shot, outfit sheet and Fill angles estimates return sentImages; a shot\'s choice follows into the plan', async () => {
    const body = { mode: 'reference', modelId: model.id, prompt: 'She walks along the pier.', duration: 5, quality: 'draft' };
    const e = (await owner.req('POST', '/v1/suite/shots/estimate', body)).body;
    expect(e.sentImages.changed).toBe(false);
    expect(e.sentImages.images[0]).toMatchObject({ role: 'person', label: 'face, front' });
    const c = (await owner.req('POST', '/v1/suite/shots/estimate', { ...body, sentImages: [{ image: { asset: 'g_back' }, role: 'person', label: 'body, back' }, { image: { asset: 'face' }, role: 'person' }] })).body;
    expect(c.sentImages.images.map((x: any) => x.image.asset)).toEqual(['g_back', 'face']);
    expect(c.input.images.refs.map((x: any) => x.image.asset)).toEqual(['g_back', 'face']);
    const o = (await owner.req('POST', '/v1/outfits', { modelId: model.id, name: 'Red set', description: 'a red slip dress', dryRun: true })).body;
    expect(o).toMatchObject({ dryRun: true, sentImages: { changed: false } });
    expect((await owner.req('GET', '/v1/outfits')).body.some((x: any) => x.name === 'Red set')).toBe(false); // nothing made
    const f = (await owner.req('POST', `/v1/models/${model.id}/fill-angles`, { dryRun: true })).body;
    expect(f).toMatchObject({ dryRun: true, sentImages: { changed: false } });
    const d = (await owner.req('POST', `/v1/models/${model.id}/dress-up/estimate`, { outfitImage: { asset: 'g_front' }, sentImages: [{ image: { asset: 'g_front' }, role: 'outfit' }, { image: { asset: 'g_tq' }, role: 'outfit', label: 'outfit ¾' }] })).body;
    expect(d.sentImages).toMatchObject({ changed: true, images: [{ role: 'outfit' }, { role: 'outfit', label: 'outfit ¾' }] });
  });

  it('Claude: get_sent_images / set_sent_images on the Suite draft and on the outfit sheet; reset; limit refused and undone', async () => {
    const env = { ctx: a.ctx, user: ownerUser, source: 'chat' as const };
    const tool = (n: string) => registryByName.get(n)!;
    expect(tool('set_sent_images').members).toBe(true);
    const assistId = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    await tool('suite_set_draft').run(env, { assistId, modelId: model.id, prompt: 'She turns and walks away.' });
    expect(((await tool('get_sent_images').run(env, { assistId })) as any).sentImages.changed).toBe(false);
    // Over MCP (no page filled in): the chat's page gives the draft; without a chatId, the person's latest chat.
    const chat = (await owner.req('POST', '/v1/claude/chats', { page: { name: 'suite', tool: 'shot', ids: { assistId } } })).body;
    expect(((await tool('get_sent_images').run(env, { chatId: chat.id })) as any).page).toBe('suite');
    expect(((await tool('get_sent_images').run(env, {})) as any).sentImages.changed).toBe(false);
    const set = await tool('set_sent_images').run(env, { assistId, list: [{ image: { asset: 'g_back' }, role: 'person', label: 'body, back' }, { image: { asset: 'face' }, role: 'person' }] }) as any;
    expect(set.sentImages).toMatchObject({ changed: true, changedBy: 'claude' });
    // Generate sends the draft's choice.
    expect((await owner.req('GET', `/v1/suite/assist/${assistId}`)).body.request.sentImages).toHaveLength(2);
    // An app that doesn't know `sent` keeps Claude's choice when it saves its own edits; `sent: null` (Reset) clears it.
    const { sent: _sent, ...noSent } = (await owner.req('GET', `/v1/suite/assist/${assistId}`)).body.draft;
    expect((await owner.req('PATCH', `/v1/suite/assist/${assistId}`, { draft: { ...noSent, duration: 6 } })).body.request.sentImages).toHaveLength(2);
    await expect(tool('set_sent_images').run(env, { assistId, list: Array.from({ length: 12 }, () => ({ image: { asset: 'face' }, role: 'person' })) })).rejects.toThrow(/takes up to/);
    expect(((await tool('get_sent_images').run(env, { assistId })) as any).sentImages.images).toHaveLength(2); // the refused change was undone
    expect(((await tool('set_sent_images').run(env, { assistId, reset: true })) as any).sentImages.changed).toBe(false);
    await tool('set_sent_images').run(env, { assistId, exclude: [{ asset: 'face' }] });
    const d2 = (await owner.req('GET', `/v1/suite/assist/${assistId}`)).body.draft;
    expect((await owner.req('PATCH', `/v1/suite/assist/${assistId}`, { draft: { ...d2, sent: null } })).body.request.excludeImages).toBeUndefined();
    // The outfit sheet: kept for this person and character; the route uses it; the body's own choice (null) wins.
    const s2 = await tool('set_sent_images').run(env, { page: 'outfit', modelId: model.id, request: { description: 'a red slip dress' }, exclude: [{ asset: 'c_face' }] }) as any;
    expect(s2.sentImages.images.map((x: any) => x.image.asset)).toEqual(['face', 'g_front']);
    expect((await owner.req('POST', '/v1/outfits', { modelId: model.id, description: 'x', dryRun: true })).body.sentImages).toMatchObject({ changed: true, changedBy: 'claude' });
    expect((await owner.req('POST', '/v1/outfits', { modelId: model.id, description: 'x', dryRun: true, sentImages: null })).body.sentImages.changed).toBe(false);
    await expect(tool('set_sent_images').run(env, { page: 'outfit', modelId: model.id, add: [{ image: { url: 'https://example.com/x.jpg' }, role: 'outfit' }] })).rejects.toThrow(/studio/);
    await tool('set_sent_images').run(env, { page: 'outfit', modelId: model.id, reset: true });
    expect((await owner.req('POST', '/v1/outfits', { modelId: model.id, description: 'x', dryRun: true })).body.sentImages.changed).toBe(false);
  });
});
