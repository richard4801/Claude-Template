// save_to_mac (ci_741e03646382, ci_c62906bcd1c1): Claude saves a take's video or photo, an upload or an outfit's full-size
// picture to the person's Mac (original quality, default ~/Downloads/MUSE, never over another file), after a card unless
// the folder is always allowed; the Mac answers with the local path. Free.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { outfits, takes, uploads } from '../src/db/schema.js';
import { NEEDS_NEW_APP_SAVE, permissionsOf } from '../src/claude/permissions.js';
import { DEFAULT_SAVE_FOLDER, fileNameFor, saveFolder, shortId, slug } from '../src/claude/saveToMac.js';
import { makeApp, people, demoModel, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, studioId: string, modelId: string;

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as { owner: Client; members: Client[] });
  modelId = (await demoModel(owner)).id;
  studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
  const take = (id: string, kind: 'take' | 'shot', mediaKey: string | null, index = 1, thumb: unknown = null) => ({ id, studioId, userId: owner.id, kind, jobId: null, modelId, index, of: 2,
    title: kind === 'shot' ? 'Photo · Pier at dusk' : 'Mia · Living-room dance', label: 'Draft', engineLabel: '', cost: 0, seed: 0, status: 'test' as const, thumb: thumb as any,
    prompt: 'she dances in the living room', mediaKey, createdAt: Date.now() });
  await a.ctx.db.insert(takes).values([take('take_v1', 'take', 's/v1.mp4', 1), take('take_v2', 'take', 's/v2.mp4', 2), take('s_9381c89cde04', 'shot', 'g/still.png'),
    take('take_rendering', 'take', null), take('s_thumbonly', 'shot', null, 1, { url: 'https://muse.test/uploads/g/thumb.jpg' })]);
  await a.ctx.db.insert(uploads).values([
    { id: 'up_v1', studioId, kind: 'output', storageKey: 's/v1.mp4', contentType: 'video/mp4', bytes: 48 * 1024 * 1024, state: 'ready', createdAt: Date.now() },
    { id: 'up_still', studioId, kind: 'generated', storageKey: 'g/still.png', contentType: 'image/png', bytes: 2_000_000, state: 'ready', createdAt: Date.now() },
    { id: 'up_song', studioId, kind: 'asset', storageKey: 'c/up_song.m4a', contentType: 'audio/mp4', bytes: 100, state: 'ready', createdAt: Date.now() },
    { id: 'up_front', studioId, kind: 'generated', storageKey: 'g/front.jpg', contentType: 'image/jpeg', bytes: 900_000, state: 'ready', createdAt: Date.now() },
  ]);
  await a.ctx.db.insert(outfits).values({ id: 'o_red', studioId, modelId, name: 'Red slip dress', mode: 'describe', angles: [{ url: 'https://muse.test/uploads/g/front.jpg' }, null, null, { asset: 'g_back' }],
    state: 'ready', createdAt: Date.now() });
});
afterAll(async () => { await a.close(); });

let nextId = 1;
async function mcp(c: Client, name: string, args: Record<string, unknown>) {
  const tok = (await c.req('POST', '/v1/mcp/session-token', {})).body.token;
  const r = await a.app.inject({ method: 'POST', url: '/mcp', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', authorization: `Bearer ${tok}` },
    payload: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name, arguments: args } }) });
  const res = JSON.parse(r.body).result;
  return res.isError ? { isError: true, text: res.content[0].text } : JSON.parse(res.content[0].text);
}
const checkIn = (c: Client, caps: string) => a.app.inject({ method: 'GET', url: '/v1/claude/permissions', headers: { authorization: `Bearer ${c.token}`, 'x-muse-caps': caps } });
const nextAsk = async (c: Client) => { let x: any; for (let i = 0; i < 50 && !x; i++) { x = (await c.req('GET', '/v1/claude/permissions')).body.asks[0]; if (!x) await new Promise(r => setTimeout(r, 20)); } return x; };

describe('file names (the Mac\'s SaveFileName scheme)', () => {
  it('readable, one per take: title (or prompt), short id, number', () => {
    expect(slug('Mia · Living-room dance!')).toBe('mia-living-room-dance');
    expect(slug('a'.repeat(50))).toBe('a'.repeat(40));
    expect(shortId('s_9381c89cde04')).toBe('s9381c89c');
    expect(fileNameFor({ title: 'Mia · Living-room dance', id: 'take_v1', index: 1, ext: 'mp4' })).toBe('mia-living-room-dance-takev1-1.mp4');
    expect(fileNameFor({ title: '', prompt: 'Waves on a pier', id: 's_1', ext: 'png' })).toBe('waves-on-a-pier-s1.png');
    expect(fileNameFor({ id: 'x', ext: 'jpg' })).toBe('muse-x.jpg');
  });
  it('folders: default ~/Downloads/MUSE; absolute or ~/ only; never key folders', () => {
    expect(saveFolder(undefined)).toBe(DEFAULT_SAVE_FOLDER);
    expect(saveFolder('~/Desktop/edits/')).toBe('~/Desktop/edits');
    expect(() => saveFolder('Desktop')).toThrow(/absolute/);
    expect(() => saveFolder('~/Movies/../.ssh')).toThrow(/\.\./);
    expect(() => saveFolder('~/.ssh')).toThrow(/keys, passwords or tokens/);
    expect(() => saveFolder('/Users/me/.aws/x')).toThrow(/keys/);
  });
});

describe('save_to_mac', () => {
  it('an older Mac app (no save capability) is told to update; nothing is asked', async () => {
    const hub = permissionsOf(a.ctx);
    hub.appWaitMs = 40;
    await checkIn(owner, 'files,results,ui,acks');
    expect(await mcp(owner, 'save_to_mac', { takeId: 'take_v1' })).toEqual({ status: 'failed', error: NEEDS_NEW_APP_SAVE });
    expect((await owner.req('GET', '/v1/claude/permissions')).body.asks).toEqual([]);
  });

  it('a take\'s video: a Save card for ~/Downloads/MUSE with a unique name, download progress, then the local path', async () => {
    const hub = permissionsOf(a.ctx);
    hub.uploadAnswerMs = 60;
    try {
      await checkIn(owner, 'files,results,ui,acks,save');
      const first = await mcp(owner, 'save_to_mac', { takeId: 'take_v1' });
      expect(first).toMatchObject({ status: 'waiting_for_approval', saveTicket: expect.stringMatching(/^perm/) });
      const ask = await nextAsk(owner);
      expect(ask).toMatchObject({ id: first.saveTicket, toolName: 'Save', input: { file_path: '~/Downloads/MUSE/mia-living-room-dance-takev1-1.mp4', folder: '~/Downloads/MUSE',
        fileName: 'mia-living-room-dance-takev1-1.mp4', url: '/uploads/s/v1.mp4', contentType: 'video/mp4', bytes: 48 * 1024 * 1024 } });
      expect(ask.input.what).toMatch(/the video take_v1/);
      await owner.req('POST', `/v1/claude/permissions/${ask.id}/progress`, { phase: 'asking' });
      expect(await mcp(owner, 'save_to_mac', { saveTicket: ask.id })).toMatchObject({ status: 'waiting_for_approval', message: expect.stringMatching(/Save mia-living-room-dance-takev1-1\.mp4 to ~\/Downloads\/MUSE/) });
      // Asked again while on its way: the same save, no second card.
      expect(await mcp(owner, 'save_to_mac', { takeId: 'take_v1' })).toMatchObject({ saveTicket: ask.id });
      expect((await owner.req('GET', '/v1/claude/permissions')).body.asks).toHaveLength(1);
      expect((await owner.req('POST', `/v1/claude/permissions/${ask.id}/progress`, { phase: 'downloading', sentBytes: 24 * 1024 * 1024, totalBytes: 48 * 1024 * 1024 })).status).toBe(204);
      expect(await mcp(owner, 'upload_status', { uploadTicket: ask.id })).toMatchObject({ status: 'downloading', percent: 50, savedMB: 24, totalMB: 48 });
      // Allowing without saying where it went is refused; keys never.
      expect((await owner.req('POST', `/v1/claude/permissions/${ask.id}`, { allow: true })).status).toBe(400);
      expect((await owner.req('POST', `/v1/claude/permissions/${ask.id}`, { allow: true, saved: { path: '/Users/me/.ssh/x.mp4' } })).status).toBe(400);
      expect((await member.req('POST', `/v1/claude/permissions/${ask.id}`, { allow: true, saved: { path: '/Users/me/Downloads/MUSE/a.mp4' } })).status).toBe(410);
      const path = '/Users/me/Downloads/MUSE/mia-living-room-dance-takev1-1 (2).mp4';
      expect((await owner.req('POST', `/v1/claude/permissions/${ask.id}`, { allow: true, saved: { path, bytes: 48 * 1024 * 1024 } })).status).toBe(204);
      expect(await mcp(owner, 'save_to_mac', { saveTicket: ask.id })).toMatchObject({ status: 'done', path, bytes: 48 * 1024 * 1024, sizeMB: 48, message: expect.stringMatching(/Use that path/) });
    } finally { hub.uploadAnswerMs = 40_000; }
  });

  it('two takes of the same shot get two names; a photo, an upload and an outfit picture; a folder of the person\'s choosing; a no', async () => {
    const hub = permissionsOf(a.ctx);
    hub.uploadAnswerMs = 30;
    try {
      await checkIn(owner, 'files,results,ui,acks,save');
      const one = async (args: Record<string, unknown>) => {
        await mcp(owner, 'save_to_mac', args);
        const x = await nextAsk(owner);
        await owner.req('POST', `/v1/claude/permissions/${x.id}`, { allow: false });
        return x;
      };
      expect((await one({ takeId: 'take_v2' })).input.fileName).toBe('mia-living-room-dance-takev2-2.mp4');
      expect((await one({ takeId: 's_9381c89cde04' })).input).toMatchObject({ fileName: 'photo-pier-at-dusk-s9381c89c-1.png', url: '/uploads/g/still.png' });
      expect((await one({ takeId: 's_thumbonly' })).input).toMatchObject({ url: '/uploads/g/thumb.jpg', fileName: 'photo-pier-at-dusk-sthumbonl-1.jpg' });
      expect((await one({ uploadId: 'up_song', folder: '~/Music/stems' })).input).toMatchObject({ folder: '~/Music/stems', file_path: '~/Music/stems/upload-audio-upsong.m4a', contentType: 'audio/mp4' });
      expect((await one({ outfitId: 'o_red' })).input).toMatchObject({ fileName: 'red-slip-dress-front-ored.jpg', url: '/uploads/g/front.jpg', bytes: 900_000 });
      expect((await one({ outfitId: 'o_red', picture: 'back' })).input).toMatchObject({ fileName: 'red-slip-dress-back-ored.jpg', url: '/assets/ref/g_back.jpg' });
      // The person says no: failed with why.
      const st = await mcp(owner, 'save_to_mac', { takeId: 'take_v2', folder: '~/Desktop' });
      const x = await nextAsk(owner);
      await owner.req('POST', `/v1/claude/permissions/${x.id}`, { allow: false, message: 'Not now' });
      expect(await mcp(owner, 'save_to_mac', { saveTicket: st.saveTicket })).toEqual({ status: 'failed', error: 'Not now' });
    } finally { hub.uploadAnswerMs = 40_000; }
  });

  it('says plainly what is wrong: missing, not ready, no such picture, more than one file, key folders', async () => {
    await checkIn(owner, 'files,results,ui,acks,save');
    expect((await mcp(owner, 'save_to_mac', { takeId: 's_gone' })).text).toMatch(/not a take of this studio now \(deleted/);
    expect((await mcp(owner, 'save_to_mac', { takeId: 'take_rendering' })).text).toMatch(/no video yet/);
    expect((await mcp(owner, 'save_to_mac', { outfitId: 'o_red', picture: 'side' })).text).toMatch(/Red slip dress has no side picture · it has: front, back/);
    expect((await mcp(owner, 'save_to_mac', { takeId: 'take_v1', uploadId: 'up_v1' })).text).toMatch(/Name one file/);
    expect((await mcp(owner, 'save_to_mac', { takeId: 'take_v1', folder: '~/.ssh' })).text).toMatch(/keys, passwords or tokens/);
    expect((await mcp(owner, 'save_to_mac', { uploadId: 'up_v1', folder: 'relative' })).text).toMatch(/absolute/);
    expect((await owner.req('GET', '/v1/claude/permissions')).body.asks).toEqual([]);
  });

  it('members have it too (their studio\'s files), on the MCP list', async () => {
    const tok = (await member.req('POST', '/v1/mcp/session-token', {})).body.token;
    const r = await a.app.inject({ method: 'POST', url: '/mcp', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', authorization: `Bearer ${tok}` },
      payload: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'tools/list' }) });
    expect(JSON.parse(r.body).result.tools.map((t: any) => t.name)).toContain('save_to_mac');
    const hub = permissionsOf(a.ctx);
    hub.uploadAnswerMs = 30;
    try {
      await checkIn(member, 'files,results,ui,acks,save');
      expect(await mcp(member, 'save_to_mac', { takeId: 'take_v1' })).toMatchObject({ status: 'waiting_for_approval' });
      const x = await nextAsk(member);
      expect(x.toolName).toBe('Save');
      await member.req('POST', `/v1/claude/permissions/${x.id}`, { allow: false });
    } finally { hub.uploadAnswerMs = 40_000; }
  });
});
