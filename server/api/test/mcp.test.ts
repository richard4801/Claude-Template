// The MUSE MCP server: Streamable HTTP JSON-RPC round-trips, personal access tokens, owner-only, presigned uploads.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { repairHistory } from '../src/camera/director.js';
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
  });
});
