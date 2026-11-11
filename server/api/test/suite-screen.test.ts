// Claude sees and sets everything on screen (owner complaint 2026-11-11, "Claude can't see clips added to swap or
// anywhere"): the app mirrors its composer into the shared draft with `screen` (the request Generate would send and
// every input in words); Claude's draft view, request and tools read it; every Suite tool reaches the draft on screen
// whatever its id (sa_, a camera Shot draft sd_, a camera session cs_, or none: the chat's page); references and photos
// by take or link; watch takes a link, a clip attached by link and a camera session's guide clip.
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { clips, takes, uploads, users } from '../src/db/schema.js';
import { cameraAssets, cameraSessions } from '../src/camera/schema.js';
import { SUITE_TOOLS } from '../src/suite/mcpTools.js';
import { CHAT_TOOLS } from '../src/claude/chatTools.js';
import { SENT_TOOLS } from '../src/claude/sentTools.js';
import { videoOf } from '../src/claude/watch.js';
import { withScreen } from '../src/suite/screen.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, ownerU: AuthUser, studioId: string;
const tool = (n: string) => [...SUITE_TOOLS, ...CHAT_TOOLS, ...SENT_TOOLS].find(t => t.name === n)!;
const env = () => ({ ctx: a.ctx, user: ownerU, source: 'chat' }) as any;

beforeAll(async () => {
  a = await makeApp({ SUITE_MODE: 'mock' });
  ({ owner } = await people(a, 0) as any);
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  ownerU = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
});
afterAll(async () => { await a?.close(); });

const clip = (id: string, key: string) => a.ctx.db.insert(clips).values({ id, studioId, name: 'Dance from a link', durationSec: 6, width: 720, height: 1280, fps: 30, meta: { url: 'https://example.com/v/1' }, checks: [], storageKey: key, createdAt: Date.now() });

describe('the composer on screen reaches Claude', () => {
  it('Swap: the clip attached by link, the character and outfit are in the request and onScreen, with the id to watch', async () => {
    const id = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    await clip('cl_link', 'c/link.mp4');
    const screen = { tool: 'swap', at: Date.now(),
      request: { mode: 'swap', modelId: 'm_x', outfitId: 'o_x', clipId: 'cl_link', keepAudio: true, quality: 'hd', prompt: '' },
      inputs: [{ slot: 'swap.clip', kind: 'video', label: 'Dance from a link', clipId: 'cl_link', link: 'https://example.com/v/1', seconds: 6 }, { slot: 'bad', kind: 'nope' }] };
    const p = await owner.req('PATCH', `/v1/suite/assist/${id}`, { draft: { v: 1, tool: 'swap', tokens: [], screen } });
    expect(p.status).toBe(200);
    const v = await tool('suite_get_draft').run(env(), { assistId: id }) as any;
    expect(v.request).toMatchObject({ mode: 'swap', clipId: 'cl_link', keepAudio: true, modelId: 'm_x', outfitId: 'o_x', quality: 'hd' });
    expect(v.onScreen).toMatchObject({ synced: true, tool: 'swap', unreadable: 1, inputs: [{ input: 0, slot: 'swap.clip', kind: 'video', watch: 'cl_link', link: 'https://example.com/v/1' }] });
    expect((await videoOf(a.ctx, ownerU, v.onScreen.inputs[0].watch)).key).toBe('c/link.mp4');
  });

  it('a Directed camera picked on screen (Rig → Directed, Blender guides) is in the request; directed: null takes it out', async () => {
    const id = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    const camera = { mode: 'directed', guide: { video: { key: 'c/grey.mp4', seconds: 6 }, use: 'blocking', cameraSessionId: 'cs_x', keyframes: { start: '/uploads/c/s.png' } } };
    await owner.req('PATCH', `/v1/suite/assist/${id}`, { draft: { v: 1, tool: 'shot', tokens: [{ t: 'text', text: 'She turns.' }],
      screen: { request: { prompt: 'She turns.', camera, frames: { start: { url: '/uploads/u/a.jpg' } }, references: { images: [{ image: { url: '/uploads/u/r.jpg' }, role: 'location' }] } },
        inputs: [{ slot: 'guide', kind: 'video', role: 'blocking', key: 'c/grey.mp4', cameraSessionId: 'cs_x' }, { slot: 'start', kind: 'image', url: '/uploads/u/a.jpg' }] } } });
    const v = await tool('suite_get_draft').run(env(), { assistId: id }) as any;
    expect(v.request.camera).toMatchObject({ mode: 'directed', guide: { use: 'blocking' } });
    expect(v.request.frames).toEqual({ start: { url: '/uploads/u/a.jpg' } });
    expect(v.request.references.images).toHaveLength(1);
    expect(v.onScreen.inputs).toMatchObject([{ slot: 'guide', watch: 'cs_x' }, { slot: 'start', see: 'suite_see {input: 1}' }]);
    const back = await tool('suite_set_draft').run(env(), { assistId: id, directed: null }) as any;
    expect(back.request.camera?.mode).not.toBe('directed');
  });

  it('withScreen: references on screen come before Claude\'s chat references (6 at most); no screen leaves the request alone', () => {
    const req = { prompt: 'x', references: { images: [{ image: { url: '/uploads/u/chat.jpg' }, role: 'pose' }] } };
    expect(withScreen(req, { v: 1, tool: 'shot' } as any)).toBe(req);
    const out = withScreen(req, { v: 1, tool: 'shot', screen: { request: { references: { images: [1, 2, 3, 4, 5, 6].map(n => ({ image: { url: `/uploads/u/${n}.jpg` }, role: 'product' })) } } } } as any) as any;
    expect(out.references.images).toHaveLength(6);
    expect(out.references.images[0].image.url).toBe('/uploads/u/1.jpg');
  });

  it('an older app (no screen) says so instead of an empty view', async () => {
    const id = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    expect((await tool('suite_get_draft').run(env(), { assistId: id }) as any).onScreen).toMatchObject({ synced: false });
  });
});

describe('every Suite tool reaches the draft on screen', () => {
  it('no id: the chat\'s page (or the latest chat) gives it', async () => {
    const assistId = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    const chat = (await owner.req('POST', '/v1/claude/chats', { page: { name: 'suite', tool: 'swap', ids: { assistId } } })).body;
    expect((await tool('suite_get_draft').run(env(), { chatId: chat.id }) as any).id).toBe(assistId);
    expect((await tool('suite_get_draft').run(env(), {}) as any).id).toBe(assistId);
  });

  it('a camera session\'s Shot draft (sd_) and the session (cs_) are one shared draft with its Directed camera; Claude sets its quality and references; open_page opens it', async () => {
    const cs = (await owner.req('POST', '/v1/camera-sessions', { title: 'Snap reveal', durationSec: 6 })).body;
    const camera = { mode: 'directed', guide: { video: { key: 'c/g2.mp4', seconds: 6 }, use: 'blocking', cameraSessionId: cs.id } };
    await a.ctx.db.update(cameraSessions).set({ shotDraft: { id: 'sd_test1', state: 'draft', source: 'suite', prompt: 'She spins.', targetModel: 'kling-v4.0', durationSec: 6, aspect: '9:16',
      estimate: { usd: 1, tokens: 10 }, camera: {}, createdAt: Date.now(), request: { prompt: 'She spins.', quality: 'cinema', duration: 6, aspectRatio: '9:16', engineModel: 'kling', resolution: '1080p', camera } } as any })
      .where(eq(cameraSessions.id, cs.id));
    const v = await tool('suite_get_draft').run(env(), { assistId: 'sd_test1' }) as any;
    expect(v.id).toBe('sa_sd_test1');
    expect(v.request).toMatchObject({ prompt: 'She spins.', quality: 'cinema', engineModel: 'kling', camera: { mode: 'directed', guide: { use: 'blocking' } } });
    expect((await tool('suite_get_draft').run(env(), { assistId: cs.id }) as any).id).toBe('sa_sd_test1');
    // The Camera page binds its session: the suite tools act on its Shot draft.
    expect((await tool('suite_get_draft').run(env(), { cameraSessionId: cs.id }) as any).id).toBe('sa_sd_test1');
    const set = await tool('suite_set_draft').run(env(), { assistId: 'sd_test1', quality: 'draft' }) as any;
    expect(set.request).toMatchObject({ quality: 'draft', camera: { mode: 'directed' } });
    // A Library still as a location reference, by take id.
    await a.ctx.db.insert(takes).values({ id: 's_still1', studioId, userId: null, kind: 'shot', jobId: null, modelId: null, index: 1, of: 1, title: 'Beach', label: 'Beach', cost: 0, seed: 0,
      status: 'test', thumb: { url: '/uploads/g/beach.jpg' }, mediaKey: 'g/beach.jpg', createdAt: Date.now() } as any);
    const r = await tool('suite_add_reference').run(env(), { assistId: 'sd_test1', takeId: 's_still1', use: 'location' }) as any;
    expect(r.draft.references).toEqual([{ uploadId: 's_still1', url: '/uploads/g/beach.jpg', use: 'location' }]);
    // Given as an "uploadId" (what Claude tried first): taken as the take.
    const r2 = await tool('suite_add_reference').run(env(), { assistId: 'sd_test1', uploadId: 's_still1', use: 'outfit' }) as any;
    expect(r2.draft.references).toHaveLength(1);
    expect(r2.draft.references[0].use).toBe('outfit');
    // Images sent reach it too.
    expect((await tool('get_sent_images').run(env(), { assistId: 'sd_test1' }) as any).page).toBe('suite');
    // open_page opens that shot in the composer.
    const chat = (await owner.req('POST', '/v1/claude/chats', { page: { name: 'camera', ids: { cameraSessionId: cs.id } } })).body;
    const o = await tool('open_page').run(env(), { chatId: chat.id, page: 'suite', tool: 'shot', id: 'sd_test1' }) as any;
    expect(o.assistId).toBe('sa_sd_test1');
  });

  it('suite_see needs no draft for a model or outfit (the Character page), and shows pictures on screen by number', async () => {
    const r = await tool('suite_see').run(env(), { modelId: 'm_none' }) as any;
    expect(r.model).toMatchObject({ id: 'm_none', missing: true });
    const id = (await owner.req('POST', '/v1/suite/assist', {})).body.id;
    await owner.req('PATCH', `/v1/suite/assist/${id}`, { draft: { v: 1, tool: 'shot', screen: { inputs: [{ slot: 'audio', kind: 'audio' }] } } });
    await expect(tool('suite_see').run(env(), { assistId: id, input: 0 })).rejects.toMatchObject({ status: 400 });
  });
});

describe('watch and see_photos take what is on screen', () => {
  it('a /uploads/ link, a camera session (its guide clip) and an uploaded image', async () => {
    await a.ctx.db.insert(uploads).values({ id: 'up_src', studioId, kind: 'clip', storageKey: 'u/src.mp4', contentType: 'video/mp4', bytes: 1, state: 'ready', createdAt: Date.now() });
    expect(await videoOf(a.ctx, ownerU, '/uploads/u/src.mp4')).toMatchObject({ id: 'up_src', key: 'u/src.mp4' });
    expect(await videoOf(a.ctx, ownerU, 'https://host.example/uploads/u/src.mp4')).toMatchObject({ key: 'u/src.mp4' });
    await expect(videoOf(a.ctx, ownerU, '/uploads/u/../x.mp4')).rejects.toMatchObject({ status: 400 });
    const cs = (await owner.req('POST', '/v1/camera-sessions', { title: 'Guide', durationSec: 4 })).body;
    await expect(videoOf(a.ctx, ownerU, cs.id)).rejects.toMatchObject({ code: 'not_ready' });
    await a.ctx.db.insert(cameraAssets).values({ id: 'ca_grey', sessionId: cs.id, studioId, kind: 'greybox', storageKey: 'c/guide.mp4', contentType: 'video/mp4', state: 'ready', source: 'relay', createdAt: Date.now() });
    expect(await videoOf(a.ctx, ownerU, cs.id)).toMatchObject({ key: 'c/guide.mp4' });
    expect(await videoOf(a.ctx, ownerU, '/uploads/c/guide.mp4')).toMatchObject({ key: 'c/guide.mp4' });
    // A take id that isn't there says what to do.
    await expect(tool('set_sent_images').run(env(), { assistId: (await owner.req('POST', '/v1/suite/assist', {})).body.id, add: [{ image: { takeId: 's_gone' }, role: 'location' }] }))
      .rejects.toThrow(/isn't in this studio/);
  });
});
