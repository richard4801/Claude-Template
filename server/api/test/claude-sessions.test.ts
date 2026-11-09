// WS18: Claude chat sessions and the Suite draft Claude changes. Each place keeps a list of chats (the AI Suite one per
// composer tool, Recreate/Edit/Camera one per reference, session or camera), stored on the server so any device picks
// up where the owner left off; a message the Mac sends is stored once; Claude's suite_set_draft and
// suite_add_reference keep the composer's tool, so the app can lay them over the open composer. No Claude calls, no money.
import sharp from 'sharp';
import { eq, sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { AuthUser } from '../src/ctx.js';
import { users } from '../src/db/schema.js';
import { autoTitle, suiteKey } from '../src/camera/claude.js';
import { SUITE_TOOLS } from '../src/suite/mcpTools.js';
import { suiteOptions } from '../src/suite/assist.js';
import { demoModel, makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, ownerUser: AuthUser, model: { id: string; name: string };
const tool = (n: string) => SUITE_TOOLS.find(t => t.name === n)!;
const env = () => ({ ctx: a.ctx, user: ownerUser, source: 'mcp' as const });
const DRAFT = (tool: string) => ({ v: 1, tool, quality: 'draft', aspect: '9:16', duration: 5, takes: 1, sound: true });
const assist = async (t: string) => (await owner.req('POST', '/v1/suite/assist', { draft: DRAFT(t) })).body as { id: string; revision: number };
const open = async (body: Record<string, unknown>) => owner.req('POST', '/v1/claude/threads', body);
const list = async (key: string) => (await owner.req('GET', `/v1/claude/threads?key=${encodeURIComponent(key)}`)).body;
/** What the Mac mirrors for a message typed there: the context line, then the words. */
const typed = async (threadId: string, assistId: string, words: string) =>
  owner.req('POST', `/v1/claude/threads/${threadId}/events`, { events: [{ type: 'user', text: `[Suite · draft ${assistId} rev 1 · Photo · Draft, 9:16, 5 s, 1 take · prompt: empty]\n${words}` }] });

beforeAll(async () => {
  a = await makeApp({ SUITE_MODE: 'mock', SUITE_POLL_MS: '10' });
  ({ owner, members: [member] } = await people(a, 1, { topUp: 10 }) as any);
  const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  const [u] = await a.ctx.db.select().from(users).where(eq(users.id, owner.id));
  ownerUser = { id: u!.id, studioId, email: u!.email, role: 'owner', studioName: 'Test Studio', sessionId: null };
  model = await demoModel(owner) as any;
});
afterAll(async () => { await a?.close(); });

describe('titles and keys (unit)', () => {
  it('a title is the first words without the context line, ids or paths; long ones are cut at a word', () => {
    expect(autoTitle('[Suite · draft sa_1234abcd rev 3 · Shot]\nGreat place it, and also add the image as reference.')).toBe('Great place it, and also add the image as reference.');
    expect(autoTitle('[Recreate ref_1]\nMatch shot 4 to /Users/me/Library/Caches/MUSE/x.png please')).toBe('Match shot 4 to please');
    expect(autoTitle('[Suite …]\n   ')).toBeNull();
    const long = autoTitle('She walks out of the café into golden light, turns to the camera and smiles while the wind lifts her hair')!;
    expect(long.length).toBeLessThanOrEqual(61);
    expect(long.endsWith('…')).toBe(true);
    expect(suiteKey('photo')).toBe('suite:photo');
    expect(suiteKey(undefined)).toBe('suite:shot');
    expect(suiteKey('../x')).toBe('suite:shot');
  });
});

describe('chat sessions per place', () => {
  it('each Suite mode has its own list: new chat, list (newest first, title, last time), rename, delete', async () => {
    const shot = await assist('shot'), photo1 = await assist('photo'), photo2 = await assist('photo');
    const ts = (await open({ contextKind: 'suite', contextId: shot.id })).body;
    const p1 = (await open({ contextKind: 'suite', contextId: photo1.id })).body;
    expect(ts.contextKey).toBe('suite:shot');
    expect(p1.contextKey).toBe('suite:photo');
    // Opening the same draft again is the same chat (an older app's call keeps working).
    expect((await open({ contextKind: 'suite', contextId: photo1.id })).body.id).toBe(p1.id);
    expect((await typed(p1.id, photo1.id, 'Great place it, and also add the image as reference.')).status).toBe(200);
    const p2 = (await open({ contextKind: 'suite', contextId: photo2.id, new: true })).body;
    expect(p2.id).not.toBe(p1.id);
    await typed(p2.id, photo2.id, 'A second photo idea');

    const l = list('suite:photo');
    const got = await l;
    expect(got.threads.map((t: any) => t.id)).toEqual([p2.id, p1.id]);
    expect(got.threads[1]).toMatchObject({ title: 'Great place it, and also add the image as reference.', contextId: photo1.id, messageCount: 1, updatedAt: expect.any(Number) });
    expect((await list('suite:shot')).threads.map((t: any) => t.id)).toEqual([ts.id]);

    // Rename; an empty name goes back to the first words. A rename doesn't move the chat up.
    expect((await owner.req('PATCH', `/v1/claude/threads/${p1.id}`, { title: '  Café look ' })).body.title).toBe('Café look');
    expect((await list('suite:photo')).threads.map((t: any) => t.id)).toEqual([p2.id, p1.id]);
    expect((await owner.req('PATCH', `/v1/claude/threads/${p1.id}`, { title: '' })).body.title).toBe('Great place it, and also add the image as reference.');
    expect((await owner.req('PATCH', `/v1/claude/threads/${p1.id}`, {})).status).toBe(400);

    // Delete: gone from the list and from GET; the other chat stays.
    expect((await owner.req('DELETE', `/v1/claude/threads/${p2.id}`)).body).toEqual({ ok: true, id: p2.id });
    expect((await owner.req('GET', `/v1/claude/threads/${p2.id}`)).status).toBe(404);
    expect((await list('suite:photo')).threads.map((t: any) => t.id)).toEqual([p1.id]);
    expect((await owner.req('GET', '/v1/claude/threads?key=nope')).status).toBe(400);

    // Owner only, as every Claude thread.
    expect((await member.req('GET', '/v1/claude/threads?key=suite:photo')).status).toBe(403);
    expect((await member.req('DELETE', `/v1/claude/threads/${p1.id}`)).status).toBe(403);
  });

  it('messages are kept: closing and coming back (any device) reads the same chat with its messages, each stored once', async () => {
    const d = await assist('talking');
    const t = (await open({ contextKind: 'suite', contextId: d.id })).body;
    await typed(t.id, d.id, 'Say hello to the camera');
    await owner.req('POST', `/v1/claude/threads/${t.id}/events`, { events: [{ type: 'text', delta: 'Done' }, { type: 'assistant', text: 'Done. I set the light.' }, { type: 'done', ok: true }] });
    // "Reopen": the list's newest chat for the mode, then its messages.
    const again = (await list('suite:talking')).threads[0];
    expect(again.id).toBe(t.id);
    const g = (await owner.req('GET', `/v1/claude/threads/${again.id}`)).body;
    expect(g.messages.map((m: any) => m.role)).toEqual(['user', 'assistant']);
    expect(g.messages.filter((m: any) => m.role === 'user')).toHaveLength(1);
    expect(g.messages[0].text).toMatch(/\nSay hello to the camera$/);
  });

  it('Recreate, Edit and Camera keep several chats about the same thing; the plain open is the newest', async () => {
    const e1 = (await open({ contextKind: 'edit', contextId: 'es_sessions1' })).body;
    expect(e1.contextKey).toBe('edit:es_sessions1');
    await owner.req('POST', `/v1/claude/threads/${e1.id}/events`, { events: [{ type: 'user', text: 'First edit chat' }] });
    const e2 = (await open({ contextKind: 'edit', contextId: 'es_sessions1', new: true, title: 'Colour pass' })).body;
    expect(e2).toMatchObject({ title: 'Colour pass', contextKey: 'edit:es_sessions1' });
    expect((await open({ contextKind: 'edit', contextId: 'es_sessions1' })).body.id).toBe(e2.id);
    expect((await list('edit:es_sessions1')).threads.map((t: any) => [t.id, t.title])).toEqual([[e2.id, 'Colour pass'], [e1.id, 'First edit chat']]);
    // Another session has its own list.
    expect((await list('edit:es_other')).threads).toEqual([]);
  });
});

describe('Claude\'s draft changes in every mode', () => {
  it('suite_set_draft keeps the composer\'s tool (Photo), so the app can lay the rig, the prompt and the model over it', async () => {
    const d = await assist('photo');
    const o = suiteOptions();
    const rig = { lens: o.camera.lens[0]!.id, lighting: o.lighting[0]!.id };
    const v = await tool('suite_set_draft').run(env(), { assistId: d.id, modelId: model.id, prompt: 'At the café window, soft morning light', rig, aspect: '3:4' }) as any;
    expect(v.draft.tool).toBe('photo');
    expect(v.revision).toBe(d.revision + 1);
    expect(v.draft.rig).toMatchObject(rig);
    expect(v.draft.aspect).toBe('3:4');
    expect(v.draft.tokens[0]).toMatchObject({ t: 'mention', kind: 'character', id: model.id });
    expect(v.request.prompt).toBe(`${model.name} At the café window, soft morning light`);
    // A reference image goes into the same draft, another revision, the tool still Photo.
    const png = await sharp({ create: { width: 64, height: 64, channels: 3, background: '#c08040' } }).png().toBuffer();
    const p = (await owner.req('POST', '/v1/uploads/presign', { kind: 'image', contentType: 'image/png', bytes: png.length })).body;
    const u = new URL(p.url);
    expect((await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': 'image/png' }, payload: png })).statusCode).toBe(200);
    expect((await owner.req('POST', `/v1/uploads/${p.uploadId}/confirm`, {})).status).toBeLessThan(300);
    const r = await tool('suite_add_reference').run(env(), { assistId: d.id, uploadId: p.uploadId, use: 'location' }) as any;
    expect(r.revision).toBe(v.revision + 1);
    expect(r.draft.tool).toBe('photo');
    expect(r.draft.references).toEqual([expect.objectContaining({ uploadId: p.uploadId, use: 'location' })]);
    expect(r.draft.rig).toMatchObject(rig);
    // What the app reads back (GET, as after each tool step) is the same revision.
    const g = (await owner.req('GET', `/v1/suite/assist/${d.id}`)).body;
    expect([g.revision, g.draft.tool, g.draft.references.length]).toEqual([r.revision, 'photo', 1]);
    // Generating from Claude is a Shot thing; in Photo the owner presses Generate.
    await expect(tool('suite_request_shot').run(env(), { assistId: d.id, confirm: true })).rejects.toThrow(/Shot only/);
  });

  it('a Shot draft stays a Shot', async () => {
    const d = await assist('shot');
    const v = await tool('suite_set_draft').run(env(), { assistId: d.id, prompt: 'A slow walk' }) as any;
    expect(v.draft.tool).toBe('shot');
  });
});
