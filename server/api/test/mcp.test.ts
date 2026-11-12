// The MUSE MCP server: Streamable HTTP JSON-RPC round-trips, personal access tokens, owner-only, presigned uploads.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { repairHistory } from '../src/camera/director.js';
import { uploads } from '../src/db/schema.js';
import { sql } from 'drizzle-orm';
import { makeApp, people, demoModel, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client, token: string, tokenId: string, modelId: string;

beforeAll(async () => {
  a = await makeApp();
  ({ owner, members: [member] } = await people(a, 1) as { owner: Client; members: Client[] });
  modelId = (await demoModel(owner)).id;
  const t = await owner.req('POST', '/v1/mcp/tokens', { name: 'Claude Code' });
  token = t.body.token; tokenId = t.body.id;
});
afterAll(async () => { await a.close(); });

let nextId = 1;
async function rpc(method: string, params?: unknown, opts: { token?: string | null; headers?: Record<string, string>; raw?: unknown } = {}) {
  const tok = opts.token === undefined ? token : opts.token;
  const r = await a.app.inject({ method: 'POST', url: '/mcp', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream',
    ...(tok ? { authorization: `Bearer ${tok}` } : {}), ...(opts.headers ?? {}) },
    payload: JSON.stringify(opts.raw ?? { jsonrpc: '2.0', id: nextId++, method, ...(params !== undefined ? { params } : {}) }) });
  return { status: r.statusCode, headers: r.headers, body: r.body ? JSON.parse(r.body) : null };
}
const call = async (name: string, args: Record<string, unknown> = {}) => (await rpc('tools/call', { name, arguments: args })).body.result;

describe('MCP tokens (owner endpoints)', () => {
  it('created once, listed without the secret, owner-only', async () => {
    expect(token).toMatch(/^muse_pat_/);
    const list = (await owner.req('GET', '/v1/mcp/tokens')).body;
    expect(list).toEqual([expect.objectContaining({ id: tokenId, name: 'Claude Code', prefix: token.slice(0, 13) })]);
    expect(JSON.stringify(list)).not.toContain(token);
    expect((await member.req('POST', '/v1/mcp/tokens', { name: 'x' })).body.code).toBe('owner_only');
    expect((await owner.req('POST', '/v1/mcp/tokens', { name: '' })).status).toBe(400);
  });
});

describe('MCP transport and auth', () => {
  it('needs a token: 401 with the protected-resource metadata pointer', async () => {
    const r = await rpc('initialize', {}, { token: null });
    expect(r.status).toBe(401);
    expect(r.headers['www-authenticate']).toMatch(/^Bearer resource_metadata=".*\/\.well-known\/oauth-protected-resource", scope="camera:read .*generate:estimate"$/);
    expect((await rpc('tools/list', {}, { token: 'muse_pat_wrong' })).status).toBe(401);
    // A normal app session token is not an MCP token.
    expect((await rpc('tools/list', {}, { token: owner.token })).status).toBe(401);
    const meta = await a.app.inject({ method: 'GET', url: '/.well-known/oauth-protected-resource' });
    expect(JSON.parse(meta.body)).toMatchObject({ resource: expect.stringMatching(/\/mcp$/), bearer_methods_supported: ['header'], authorization_servers: [expect.any(String)] });
  });

  it('initialize, notifications, ping, unknown method, GET/DELETE 405, bad Origin, bad protocol header, batches', async () => {
    const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'claude-code', version: '9' } });
    expect(init.status).toBe(200);
    expect(init.body.result).toMatchObject({ protocolVersion: '2025-06-18', serverInfo: { name: 'muse' }, capabilities: { tools: {} } });
    expect(init.body.result.instructions).toMatch(/never start a paid generation/);
    expect((await rpc('initialize', { protocolVersion: '1999-01-01' })).body.result.protocolVersion).toBe('2026-07-28');
    expect((await rpc('', undefined, { raw: { jsonrpc: '2.0', method: 'notifications/initialized' } })).status).toBe(202);
    expect((await rpc('ping')).body).toMatchObject({ jsonrpc: '2.0', result: {} });
    expect((await rpc('nope/nope')).body.error.code).toBe(-32601);
    expect((await rpc('', undefined, { raw: [{ jsonrpc: '2.0', id: 1, method: 'ping' }] })).body.error.code).toBe(-32600);
    expect((await a.app.inject({ method: 'GET', url: '/mcp', headers: { authorization: `Bearer ${token}` } })).statusCode).toBe(405);
    expect((await a.app.inject({ method: 'DELETE', url: '/mcp' })).statusCode).toBe(405);
    expect((await rpc('ping', undefined, { headers: { origin: 'https://evil.example' } })).status).toBe(403);
    expect((await rpc('ping', undefined, { headers: { 'mcp-protocol-version': '2020-01-01' } })).status).toBe(400);
    expect((await rpc('ping', undefined, { headers: { 'mcp-protocol-version': '2025-06-18' } })).status).toBe(200);
  });

  it('tools/list: the MUSE tools with schemas and annotations, nothing that spends', async () => {
    const tools = (await rpc('tools/list')).body.result.tools;
    const names = tools.map((t: any) => t.name);
    expect(names).toEqual(expect.arrayContaining(['list_characters', 'get_camera_session', 'update_camera_session', 'attach_guide_media', 'set_camera_path', 'create_shot_draft', 'list_presets']));
    expect(names.some((n: string) => /generate|submit|run_job/.test(n))).toBe(false);
    const get = tools.find((t: any) => t.name === 'get_camera_session');
    expect(get).toMatchObject({ inputSchema: { type: 'object', required: ['sessionId'] }, annotations: { readOnlyHint: true, destructiveHint: false } });
  });
});

describe('MCP tools round-trip', () => {
  it('drives a camera session end to end; the app sees the same session', async () => {
    const chars = (await call('list_characters')).structuredContent.characters;
    expect(chars[0]).toMatchObject({ id: modelId, name: 'Demo model', heightM: 1.68 });
    expect(chars[0].images.length).toBeGreaterThan(0);

    const s = (await call('create_camera_session', { title: 'From Claude Code', characters: [{ modelId }], durationSec: 6 })).structuredContent;
    expect(s.id).toMatch(/^cs_/);
    const got = await call('get_camera_session', { sessionId: s.id });
    expect(got.isError).toBeUndefined();
    expect(JSON.parse(got.content[0].text).title).toBe('From Claude Code');

    const path = await call('set_camera_path', { sessionId: s.id, camera: { keyframes: [{ t: 0, position: [0, -3, 1.6], target: [0, 0, 1.5] }] },
      characters: [{ modelId, keyframes: [{ t: 0, position: [0, 0, 0] }] }] });
    expect(path.structuredContent).toMatchObject({ status: 'blocking', revision: 2 });

    const upd = await call('update_camera_session', { sessionId: s.id, brief: 'She smiles', revision: 1 });
    expect(upd.isError).toBe(true);
    expect(upd.content[0].text).toMatch(/^stale_revision/);
    expect((await call('update_camera_session', { sessionId: s.id, brief: 'She smiles', revision: 2 })).structuredContent.brief).toBe('She smiles');

    const att = (await call('attach_guide_media', { sessionId: s.id, kind: 'greybox', contentType: 'video/mp4' })).structuredContent;
    expect(att.upload.url).toBeTruthy();
    const u = new URL(att.upload.url);
    expect((await a.app.inject({ method: 'PUT', url: u.pathname + u.search, headers: { 'content-type': 'video/mp4' }, payload: Buffer.from('mp4') })).statusCode).toBe(200);
    expect((await call('confirm_guide_media', { sessionId: s.id, assetId: att.asset.id })).structuredContent).toMatchObject({ state: 'ready', source: 'mcp' });

    expect((await call('post_camera_message', { sessionId: s.id, text: 'Blocked a slow push-in.' })).structuredContent).toMatchObject({ source: 'mcp', role: 'assistant' });
    const draft = (await call('create_shot_draft', { sessionId: s.id, prompt: 'bright kitchen' })).structuredContent;
    expect(draft).toMatchObject({ state: 'draft', estimate: { usd: expect.any(Number) } });

    const app = (await owner.req('GET', `/v1/camera-sessions/${s.id}`)).body;
    expect(app).toMatchObject({ status: 'ready', brief: 'She smiles', shotDraft: { id: draft.id } });
    expect(app.camera.directed.guideAssets.greybox).toBe(att.asset.id);
    expect(app.messages.at(-1)).toMatchObject({ source: 'mcp', text: 'Blocked a slow push-in.' });

    // Resources mirror the sessions.
    const res = (await rpc('resources/list')).body.result.resources;
    expect(res.map((r: any) => r.uri)).toContain(`muse://camera-session/${s.id}`);
    const read = (await rpc('resources/read', { uri: `muse://camera-session/${s.id}` })).body.result.contents[0];
    expect(JSON.parse(read.text).id).toBe(s.id);
    expect((await rpc('resources/read', { uri: 'muse://camera-session/cs_nope' })).body.error.code).toBe(-32002);
    expect((await call('list_presets', { kind: 'move' })).structuredContent.presets.every((p: any) => p.kind === 'move')).toBe(true);
  });

  it('bad arguments and unknown sessions are tool errors; unknown tools are protocol errors', async () => {
    const bad = await call('set_camera_path', { sessionId: 'cs_000000000000000000000000', camera: { keyframes: [] } });
    expect(bad.isError).toBe(true);
    const missing = await call('get_camera_session', { sessionId: 'cs_000000000000000000000000' });
    expect(missing).toMatchObject({ isError: true, content: [{ type: 'text', text: expect.stringMatching(/^not_found/) }] });
    expect((await rpc('tools/call', { name: 'generate_video', arguments: {} })).body.error.code).toBe(-32602);
  });

  it('a revoked token stops working at once; a token whose user is no longer the owner too', async () => {
    const t2 = (await owner.req('POST', '/v1/mcp/tokens', { name: 'temp', expiresDays: 1 })).body;
    expect((await rpc('ping', undefined, { token: t2.token })).status).toBe(200);
    expect((await owner.req('DELETE', `/v1/mcp/tokens/${t2.id}`)).status).toBe(204);
    expect((await rpc('ping', undefined, { token: t2.token })).status).toBe(401);
    expect((await owner.req('DELETE', `/v1/mcp/tokens/${t2.id}`)).status).toBe(404);
    const t3 = (await owner.req('POST', '/v1/mcp/tokens', { name: 'demoted' })).body;
    await a.ctx.db.execute((await import('drizzle-orm')).sql`update users set role = 'member' where id = ${owner.id}`);
    expect((await rpc('ping', undefined, { token: t3.token })).status).toBe(401);
    await a.ctx.db.execute((await import('drizzle-orm')).sql`update users set role = 'owner' where id = ${owner.id}`);
  });
});

describe('Settings → Connections', () => {
  it('shows relay, Claude app use and the MCP URL to the owner only', async () => {
    await rpc('ping');
    const c = (await owner.req('GET', '/v1/connections')).body;
    expect(c).toMatchObject({ relay: { online: false, blender: false }, claudeApp: { tokens: expect.any(Number), lastSeenAt: expect.any(Number) }, inAppChat: false });
    expect(c.mcpUrl).toMatch(/\/mcp$/);
    expect((await member.req('GET', '/v1/connections')).status).toBe(403);
    const s = (await call('create_camera_session', {})).structuredContent;
    expect(s.claude).toMatchObject({ chatBusy: false, appLastSeenAt: expect.any(Number) });
  });
});

describe('director history repair', () => {
  it('appends interrupted results for unanswered tool calls (never edits)', () => {
    const h: any[] = [{ role: 'user', content: 'x' }, { role: 'assistant', content: [{ type: 'text', text: 'a' }, { type: 'tool_use', id: 't1', name: 'n', input: {} }] }];
    const before = JSON.stringify(h);
    const r = repairHistory(h);
    expect(JSON.stringify(r.slice(0, 2))).toBe(before);
    expect(r[2]).toEqual({ role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: expect.stringMatching(/interrupted/), is_error: true }] });
    expect(repairHistory([{ role: 'user', content: 'x' }] as any)).toHaveLength(1);
  });
});

describe('registerMcpTools', () => {
  it('adds tools and is idempotent by name', async () => {
    const { registerMcpTools, MUSE_TOOLS } = await import('../src/mcp/tools.js');
    const t = { name: 'zz_test_tool', title: 'T', description: 'd', inputSchema: { type: 'object' }, scope: 'edit:read', run: async () => ({ mcpContent: [{ type: 'text', text: 'hi' }] }) };
    registerMcpTools([t]); registerMcpTools([{ ...t }]);
    expect(MUSE_TOOLS.filter(x => x.name === 'zz_test_tool')).toHaveLength(1);
    const r = (await rpc('tools/call', { name: 'zz_test_tool', arguments: {} })).body.result;
    expect(r).toEqual({ content: [{ type: 'text', text: 'hi' }] });
    registerMcpTools([{ ...t, run: async () => ({ mcpContent: [{ type: 'image', data: 'AA==', mimeType: 'image/png' }], structuredContent: { label: 'Looked at 0:01.5' } }) }]);
    const img = (await rpc('tools/call', { name: 'zz_test_tool', arguments: {} })).body.result;
    expect(img.content.at(-1)).toEqual({ type: 'text', text: JSON.stringify({ label: 'Looked at 0:01.5' }) });
    expect(img.structuredContent.label).toBe('Looked at 0:01.5');
  });
});

describe('render_camera_guides (Claude Code renders guides through the Mac relay)', () => {
  it('needs the relay and Blender, sends the same relay render the Camera page uses, one at a time', async () => {
    const s = (await call('create_camera_session', { title: 'Clip 8', characters: [{ modelId }], durationSec: 6 })).structuredContent;
    expect((await call('render_camera_guides', { sessionId: s.id })).structuredContent).toMatchObject({ ok: false, error: expect.stringMatching(/not connected/) });
    await owner.req('POST', '/v1/blender/relay', { online: true, blender: { connected: false } });
    expect((await call('render_camera_guides', { sessionId: s.id })).structuredContent.error).toMatch(/Blender is not connected/);
    await owner.req('POST', '/v1/blender/relay', { online: true, blender: { connected: true } });
    const started = (await call('render_camera_guides', { sessionId: s.id, wait: false })).structuredContent;
    expect(started).toMatchObject({ ok: true, started: true, passes: ['greybox', 'keyframes', 'camera_json', 'characters_json'] });
    const [c] = (await owner.req('GET', '/v1/blender/calls')).body;
    expect(c).toMatchObject({ sessionId: s.id, tool: 'blender_render_guides', args: { passes: ['greybox', 'keyframes', 'camera_json', 'characters_json'] } });
    expect((await call('render_camera_guides', { sessionId: s.id })).structuredContent).toMatchObject({ ok: false, busy: true });
    await owner.req('POST', `/v1/blender/calls/${c.id}/claim`);
    await owner.req('POST', `/v1/blender/calls/${c.id}/result`, { ok: true, result: { frames: 144 } });
    // wait (default): returns when the Mac posts the result.
    const done = call('render_camera_guides', { sessionId: s.id, passes: ['greybox'] });
    let c2: any;
    for (let i = 0; i < 50 && !c2; i++) { c2 = (await owner.req('GET', '/v1/blender/calls')).body[0]; if (!c2) await new Promise(r => setTimeout(r, 20)); }
    expect(c2.args).toEqual({ passes: ['greybox'] });
    await owner.req('POST', `/v1/blender/calls/${c2.id}/claim`);
    await owner.req('POST', `/v1/blender/calls/${c2.id}/result`, { ok: true, result: { frames: 144 } });
    expect((await done).structuredContent).toMatchObject({ ok: true, revision: expect.any(Number) });
    await owner.req('POST', '/v1/blender/relay', { online: false });
  });
});

describe('permission_prompt (files on the person\'s Mac ask first)', () => {
  it('waits for the person: allow, deny; credentials are refused outright; members have it too', async () => {
    const ask = (tool_name: string, input: Record<string, unknown>) => rpc('tools/call', { name: 'permission_prompt', arguments: { tool_name, input, tool_use_id: 'toolu_1' } });
    // An older Mac app (no X-Muse-Caps: files): answered at once, never left waiting.
    expect(JSON.parse((await ask('Read', { file_path: '/Users/me/a.txt' })).body.result.content[0].text)).toEqual({ behavior: 'deny', message: expect.stringMatching(/newer MUSE app/) });
    expect(JSON.parse((await rpc('tools/call', { name: 'upload_local_file', arguments: { path: '/Users/me/a.png' } })).body.result.content[0].text).error).toMatch(/newer MUSE app/);
    await a.app.inject({ method: 'GET', url: '/v1/claude/permissions', headers: { authorization: `Bearer ${owner.token}`, 'x-muse-caps': 'files,results' } });
    const pending = ask('Read', { file_path: '/Users/me/Movies/clip.mov' });
    let asks: any[] = [];
    for (let i = 0; i < 50 && !asks.length; i++) { asks = (await owner.req('GET', '/v1/claude/permissions')).body.asks; if (!asks.length) await new Promise(r => setTimeout(r, 20)); }
    expect(asks[0]).toMatchObject({ toolName: 'Read', input: { file_path: '/Users/me/Movies/clip.mov' }, toolUseId: 'toolu_1' });
    expect((await member.req('POST', `/v1/claude/permissions/${asks[0].id}`, { allow: true })).status).toBe(410); // not theirs
    expect((await owner.req('POST', `/v1/claude/permissions/${asks[0].id}`, { allow: true })).status).toBe(204);
    const r = (await pending).body.result;
    expect(r.content).toEqual([{ type: 'text', text: '{"behavior":"allow"}' }]);
    expect(r.structuredContent).toBeUndefined();

    const p2 = ask('Bash', { command: 'ls ~/Movies' });
    let a2: any;
    for (let i = 0; i < 50 && !a2; i++) { a2 = (await owner.req('GET', '/v1/claude/permissions')).body.asks[0]; if (!a2) await new Promise(r => setTimeout(r, 20)); }
    await owner.req('POST', `/v1/claude/permissions/${a2.id}`, { allow: false });
    expect(JSON.parse((await p2).body.result.content[0].text)).toEqual({ behavior: 'deny', message: 'The person said no.' });

    for (const [t, i] of [['Read', { file_path: '/Users/me/project/.env' }], ['Read', { file_path: '/Users/me/.ssh/id_ed25519' }], ['Bash', { command: 'cat ~/.aws/credentials' }],
      ['Read', { file_path: '/Users/me/MUSE/Claude/ct_1/.mcp-abc.json' }], ['Grep', { pattern: 'x', path: '/Users/me/Library/Keychains' }]] as const) {
      expect(JSON.parse((await ask(t, i)).body.result.content[0].text)).toMatchObject({ behavior: 'deny', message: expect.stringMatching(/never lets Claude read/) });
    }
    expect((await owner.req('GET', '/v1/claude/permissions')).body.asks).toEqual([]);

    // A member's own Mac (session token from the app) has the tool too.
    const mt = (await member.req('POST', '/v1/mcp/session-token')).body;
    const names = (await rpc('tools/list', {}, { token: mt.token })).body.result.tools.map((x: any) => x.name);
    expect(names).toContain('permission_prompt');
    expect(names).not.toContain('render_camera_guides');
  });
});

describe('upload_local_file (a Mac file into MUSE, after the person says yes)', () => {
  it('asks with an Upload card, returns the upload the Mac made, refuses keys and other people\'s uploads', async () => {
    const up = (path: string, purpose = 'reference') => rpc('tools/call', { name: 'upload_local_file', arguments: { path, purpose } });
    const next = async () => { let x: any; for (let i = 0; i < 50 && !x; i++) { x = (await owner.req('GET', '/v1/claude/permissions')).body.asks[0]; if (!x) await new Promise(r => setTimeout(r, 20)); } return x; };
    expect(JSON.parse((await up('~/.ssh/id_rsa')).body.result.content[0].text).error).toMatch(/never lets Claude/);
    expect((await up('relative/a.png')).body.result.isError).toBe(true);

    const p1 = up('/Users/me/Shoot/layout_A_house.png');
    const a1 = await next();
    expect(a1).toMatchObject({ toolName: 'Upload', input: { file_path: '/Users/me/Shoot/layout_A_house.png', purpose: 'reference' } });
    expect((await owner.req('POST', `/v1/claude/permissions/${a1.id}`, { allow: true })).status).toBe(400); // needs the upload
    expect((await owner.req('POST', `/v1/claude/permissions/${a1.id}`, { allow: true, result: { uploadId: 'up_nope', kind: 'image' } })).status).toBe(400);
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    await a.ctx.db.insert(uploads).values({ id: 'up_layout', studioId, kind: 'image', storageKey: 'u/layout.png', contentType: 'image/png', bytes: 10, state: 'ready', createdAt: Date.now() });
    expect((await owner.req('POST', `/v1/claude/permissions/${a1.id}`, { allow: true, result: { uploadId: 'up_layout', kind: 'image', url: '/uploads/u/layout.png' } })).status).toBe(204);
    expect(JSON.parse((await p1).body.result.content[0].text)).toEqual({ uploadId: 'up_layout', kind: 'image', url: '/uploads/u/layout.png' });

    const p2 = up('/Users/me/Shoot/b.mov', 'clip');
    const a2 = await next();
    await owner.req('POST', `/v1/claude/permissions/${a2.id}`, { allow: false });
    expect(JSON.parse((await p2).body.result.content[0].text).error).toMatch(/said no/);
  });

  it('takes a sound as an editor audio upload (ci_de89873ab1de): checks the file arrived, marks it ready, fills its link', async () => {
    const up = (path: string) => rpc('tools/call', { name: 'upload_local_file', arguments: { path, purpose: 'audio' } });
    const next = async () => { let x: any; for (let i = 0; i < 50 && !x; i++) { x = (await owner.req('GET', '/v1/claude/permissions')).body.asks[0]; if (!x) await new Promise(r => setTimeout(r, 20)); } return x; };
    const studioId = ((await a.ctx.db.execute(sql`select studio_id from users where id = ${owner.id}`)) as any).rows[0].studio_id;
    // A presigned editor upload whose PUT hasn't landed: refused until the file is there.
    await a.ctx.db.insert(uploads).values({ id: 'up_song', studioId, kind: 'asset', storageKey: 'c/up_song.aac', contentType: 'audio/aac', bytes: null, state: 'pending', createdBy: owner.id, createdAt: Date.now() });
    await a.ctx.db.insert(uploads).values({ id: 'up_pic', studioId, kind: 'image', storageKey: 'u/pic.png', contentType: 'image/png', bytes: 10, state: 'ready', createdBy: owner.id, createdAt: Date.now() });
    const p1 = up('/Users/me/Music/song.mp4');
    const a1 = await next();
    expect(a1).toMatchObject({ toolName: 'Upload', input: { file_path: '/Users/me/Music/song.mp4', purpose: 'audio' } });
    expect((await owner.req('POST', `/v1/claude/permissions/${a1.id}`, { allow: true, result: { uploadId: 'up_pic', kind: 'audio' } })).status).toBe(400); // not a sound
    expect((await owner.req('POST', `/v1/claude/permissions/${a1.id}`, { allow: true, result: { uploadId: 'up_song', kind: 'audio', durationSec: 184.2 } })).status).toBe(409);
    await a.ctx.storage.put('c/up_song.aac', Buffer.from([0xff, 0xf1, 0x50, 0x80, 0, 0, 0, 0]), 'audio/aac');
    expect((await owner.req('POST', `/v1/claude/permissions/${a1.id}`, { allow: true, result: { uploadId: 'up_song', kind: 'audio', name: 'song.mp4', durationSec: 184.2 } })).status).toBe(204);
    const out = JSON.parse((await p1).body.result.content[0].text);
    expect(out).toMatchObject({ uploadId: 'up_song', kind: 'audio', name: 'song.mp4', durationSec: 184.2 });
    expect(out.url).toMatch(/\/uploads\/c\/up_song\.aac$/);
    const [row] = ((await a.ctx.db.execute(sql`select state, bytes from uploads where id = 'up_song'`)) as any).rows;
    expect(row).toMatchObject({ state: 'ready', bytes: 8 });
    const tools = (await rpc('tools/list', {})).body.result.tools;
    expect(tools.find((t: any) => t.name === 'upload_local_file').description).toMatch(/sound \(MP3, M4A, AAC, WAV, or an MP4 with sound only, up to 200 MB/);
  });
});
