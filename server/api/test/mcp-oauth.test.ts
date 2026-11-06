// OAuth 2.1 on /mcp: metadata, dynamic registration, Client ID Metadata Documents, PKCE, audience binding, scopes,
// refresh rotation with reuse detection, owner-only consent, grants and the Mac app's session token.
import crypto from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { cimd } from '../src/mcp/oauth.js';
import { oauthTokens } from '../src/camera/schema.js';
import { makeApp, people, type Client } from './helpers.js';

type App = Awaited<ReturnType<typeof makeApp>>;
let a: App, owner: Client, member: Client;
const CB = 'https://claude.ai/api/mcp/auth_callback';
const RES = 'http://localhost:80/mcp';

beforeAll(async () => {
  process.env.OAUTH_CIMD_ALLOW_PRIVATE = '1';
  a = await makeApp({ PUBLIC_URL: 'http://localhost:80' });
  ({ owner, members: [member] } = await people(a, 1, { topUp: 0 }) as { owner: Client; members: Client[] });
});
afterAll(async () => { await a.close(); delete process.env.OAUTH_CIMD_ALLOW_PRIVATE; });

const form = (o: Record<string, string>) => new URLSearchParams(o).toString();
const post = (url: string, body: Record<string, string>) =>
  a.app.inject({ method: 'POST', url, headers: { 'content-type': 'application/x-www-form-urlencoded' }, payload: form(body) });
const pkce = () => { const verifier = crypto.randomBytes(32).toString('base64url'); return { verifier, challenge: crypto.createHash('sha256').update(verifier).digest('base64url') }; };
const register = async (redirect = CB) => JSON.parse((await a.app.inject({ method: 'POST', url: '/oauth/register', headers: { 'content-type': 'application/json' },
  payload: JSON.stringify({ redirect_uris: [redirect], client_name: 'Claude' }) })).body);
async function authorize(clientId: string, p: { challenge: string }, o: { email?: string; password?: string; scope?: string; redirect?: string; resource?: string } = {}) {
  return post('/oauth/authorize', { response_type: 'code', client_id: clientId, redirect_uri: o.redirect ?? CB, code_challenge: p.challenge, code_challenge_method: 'S256',
    state: 'st8', resource: o.resource ?? RES, ...(o.scope ? { scope: o.scope } : {}), email: o.email ?? 'owner@test.dev', password: o.password ?? 'correct horse', decision: 'allow' });
}
const codeOf = (location: string) => new URL(location).searchParams.get('code')!;
const mcp = (token: string, method: string, params?: unknown) => a.app.inject({ method: 'POST', url: '/mcp', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
  payload: JSON.stringify({ jsonrpc: '2.0', id: 1, method, ...(params ? { params } : {}) }) }).then(r => ({ status: r.statusCode, body: r.body ? JSON.parse(r.body) : null }));
async function fullFlow(scope?: string) {
  const c = await register(), p = pkce();
  const r = await authorize(c.client_id, p, { scope });
  const t = await post('/oauth/token', { grant_type: 'authorization_code', code: codeOf(r.headers.location as string), redirect_uri: CB, client_id: c.client_id, code_verifier: p.verifier, resource: RES });
  return { client: c, tokens: JSON.parse(t.body) };
}

describe('OAuth metadata and registration', () => {
  it('advertises the authorization server, PKCE S256, CIMD and the scopes (no generate:run)', async () => {
    const m = JSON.parse((await a.app.inject({ method: 'GET', url: '/.well-known/oauth-authorization-server' })).body);
    expect(m).toMatchObject({ issuer: 'http://localhost:80', authorization_endpoint: 'http://localhost:80/oauth/authorize', token_endpoint: 'http://localhost:80/oauth/token',
      code_challenge_methods_supported: ['S256'], token_endpoint_auth_methods_supported: ['none'], client_id_metadata_document_supported: true });
    expect(m.scopes_supported).toContain('edit:write');
    expect(m.scopes_supported).not.toContain('generate:run');
    const prm = JSON.parse((await a.app.inject({ method: 'GET', url: '/.well-known/oauth-protected-resource' })).body);
    expect(prm).toMatchObject({ resource: RES, authorization_servers: ['http://localhost:80'] });
  });

  it('registers public clients with allowed redirects only', async () => {
    const c = await register();
    expect(c).toMatchObject({ client_id: expect.stringMatching(/^cli_/), token_endpoint_auth_method: 'none', redirect_uris: [CB] });
    expect((await register('http://127.0.0.1:53682/callback')).client_id).toBeTruthy();
    const bad = await a.app.inject({ method: 'POST', url: '/oauth/register', headers: { 'content-type': 'application/json' }, payload: JSON.stringify({ redirect_uris: ['https://evil.example/cb'] }) });
    expect(bad.statusCode).toBe(400);
    expect(JSON.parse(bad.body).error).toBe('invalid_redirect_uri');
  });
});

describe('authorization code + PKCE', () => {
  it('shows the owner sign-in page, refuses wrong passwords and members, and redirects with code, state and iss', async () => {
    const c = await register(), p = pkce();
    const q = new URLSearchParams({ response_type: 'code', client_id: c.client_id, redirect_uri: CB, code_challenge: p.challenge, code_challenge_method: 'S256', state: 'st8', resource: RES });
    const pageRes = await a.app.inject({ method: 'GET', url: `/oauth/authorize?${q}` });
    expect(pageRes.statusCode).toBe(200);
    expect(pageRes.body).toContain('Connect to MUSE');
    expect(pageRes.body).toContain('never spend money');
    expect(pageRes.headers['x-frame-options']).toBe('DENY');
    expect((await authorize(c.client_id, p, { password: 'nope' })).statusCode).toBe(401);
    const m = await authorize(c.client_id, p, { email: 'member1@test.dev' });
    expect(m.statusCode).toBe(403);
    expect(m.body).toContain('Only the studio owner');
    const ok = await authorize(c.client_id, p);
    expect(ok.statusCode).toBe(302);
    const loc = new URL(ok.headers.location as string);
    expect(loc.origin + loc.pathname).toBe(CB);
    expect(loc.searchParams.get('state')).toBe('st8');
    expect(loc.searchParams.get('iss')).toBe('http://localhost:80');
    // Cancel goes back with access_denied.
    const deny = await post('/oauth/authorize', { response_type: 'code', client_id: c.client_id, redirect_uri: CB, code_challenge: p.challenge, code_challenge_method: 'S256', state: 's', resource: RES, decision: 'deny' });
    expect(new URL(deny.headers.location as string).searchParams.get('error')).toBe('access_denied');
  });

  it('rejects plain PKCE, a foreign redirect, and a resource that is not this /mcp', async () => {
    const c = await register(), p = pkce();
    const plain = await a.app.inject({ method: 'GET', url: `/oauth/authorize?${new URLSearchParams({ response_type: 'code', client_id: c.client_id, redirect_uri: CB, code_challenge: p.verifier, code_challenge_method: 'plain', resource: RES })}` });
    expect(plain.statusCode).toBe(400);
    expect((await authorize(c.client_id, p, { redirect: 'https://claude.com/api/mcp/auth_callback' })).statusCode).toBe(400); // not registered for this client
    expect((await authorize(c.client_id, p, { resource: 'https://other.example/mcp' })).statusCode).toBe(400);
  });

  it('exchanges the code once with the right verifier; a reused code revokes what it issued', async () => {
    const c = await register(), p = pkce();
    const code = codeOf((await authorize(c.client_id, p)).headers.location as string);
    const base = { grant_type: 'authorization_code', code, redirect_uri: CB, client_id: c.client_id, resource: RES };
    const wrong = await post('/oauth/token', { ...base, code_verifier: pkce().verifier });
    expect(JSON.parse(wrong.body)).toMatchObject({ error: 'invalid_grant' });
    const t = await post('/oauth/token', { ...base, code_verifier: p.verifier });
    expect(t.statusCode).toBe(200);
    expect(t.headers['cache-control']).toBe('no-store');
    const tok = JSON.parse(t.body);
    expect(tok).toMatchObject({ token_type: 'Bearer', expires_in: 3600, access_token: expect.stringMatching(/^muse_oat_/), refresh_token: expect.stringMatching(/^muse_ort_/) });
    expect((await mcp(tok.access_token, 'ping')).status).toBe(200);
    const again = await post('/oauth/token', { ...base, code_verifier: p.verifier });
    expect(JSON.parse(again.body).error).toBe('invalid_grant');
    expect((await mcp(tok.access_token, 'ping')).status).toBe(401);
  });

  it('a token for another audience is refused at /mcp', async () => {
    const { tokens } = await fullFlow();
    await a.ctx.db.update(oauthTokens).set({ audience: 'https://elsewhere.example/mcp' });
    expect((await mcp(tokens.access_token, 'ping')).status).toBe(401);
  });
});

describe('scopes, refresh, grants', () => {
  it('a camera:read token sees only read tools and gets insufficient_scope for the rest', async () => {
    const { tokens } = await fullFlow('camera:read');
    expect(tokens.scope).toBe('camera:read');
    const names = (await mcp(tokens.access_token, 'tools/list')).body.result.tools.map((t: any) => t.name);
    expect(names).toContain('get_camera_session');
    expect(names).not.toContain('create_shot_draft');
    expect(names).not.toContain('list_characters');
    const r = (await mcp(tokens.access_token, 'tools/call', { name: 'create_camera_session', arguments: {} })).body.result;
    expect(r).toMatchObject({ isError: true, content: [{ text: expect.stringMatching(/^insufficient_scope/) }] });
    expect((await post('/oauth/authorize', { response_type: 'code', client_id: 'x', redirect_uri: CB, code_challenge: pkce().challenge, code_challenge_method: 'S256', scope: 'generate:run', resource: RES, decision: 'allow' })).statusCode).toBe(400);
  });

  it('refresh tokens rotate; reusing an old one revokes the whole grant', async () => {
    const { client, tokens } = await fullFlow();
    const r1 = JSON.parse((await post('/oauth/token', { grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: client.client_id })).body);
    expect(r1.access_token).toMatch(/^muse_oat_/);
    expect(r1.refresh_token).not.toBe(tokens.refresh_token);
    expect((await mcp(r1.access_token, 'ping')).status).toBe(200);
    const reuse = JSON.parse((await post('/oauth/token', { grant_type: 'refresh_token', refresh_token: tokens.refresh_token, client_id: client.client_id })).body);
    expect(reuse.error).toBe('invalid_grant');
    expect((await mcp(r1.access_token, 'ping')).status).toBe(401);
    expect(JSON.parse((await post('/oauth/token', { grant_type: 'refresh_token', refresh_token: r1.refresh_token, client_id: client.client_id })).body).error).toBe('invalid_grant');
  });

  it('the owner lists and revokes connections; members cannot', async () => {
    const { tokens } = await fullFlow();
    const grants = (await owner.req('GET', '/v1/mcp/grants')).body;
    expect(grants[0]).toMatchObject({ clientName: 'Claude', scopes: expect.arrayContaining(['camera:write']) });
    expect((await member.req('GET', '/v1/mcp/grants')).status).toBe(403);
    const g = grants.find((x: any) => x.id) ;
    for (const x of grants) await owner.req('DELETE', `/v1/mcp/grants/${x.id}`);
    expect(g).toBeTruthy();
    expect((await mcp(tokens.access_token, 'ping')).status).toBe(401);
  });

  it('the Mac app gets a short-lived every-scope token for its local Claude Code', async () => {
    const t = (await owner.req('POST', '/v1/mcp/session-token', { ttlMinutes: 30 })).body;
    expect(t).toMatchObject({ token: expect.stringMatching(/^muse_oat_/), mcpUrl: RES });
    expect(t.expiresAt - Date.now()).toBeLessThanOrEqual(30 * 60_000 + 1000);
    expect((await mcp(t.token, 'tools/list')).body.result.tools.map((x: any) => x.name)).toContain('create_shot_draft');
    expect((await member.req('POST', '/v1/mcp/session-token', {})).status).toBe(403);
    expect((await owner.req('GET', '/v1/mcp/grants')).body.some((g: any) => g.clientId === 'muse-app')).toBe(false);
  });
});

describe('Client ID Metadata Documents', () => {
  it('fetches the client document, checks client_id and redirect_uris', async () => {
    const id = 'https://claude.ai/oauth/mcp-client.json';
    const real = cimd.fetch;
    cimd.fetch = async (url: string) => new Response(JSON.stringify(url === id ? { client_id: id, client_name: 'Claude', redirect_uris: [CB] } : {}), { status: 200 });
    try {
      const p = pkce();
      const r = await authorize(id, p);
      expect(r.statusCode).toBe(302);
      const t = JSON.parse((await post('/oauth/token', { grant_type: 'authorization_code', code: codeOf(r.headers.location as string), redirect_uri: CB, client_id: id, code_verifier: p.verifier })).body);
      expect(t.access_token).toMatch(/^muse_oat_/);
      const bad = 'https://claude.ai/oauth/other.json';
      expect((await authorize(bad, pkce())).statusCode).toBe(400); // its document's client_id doesn't match
      expect((await authorize('http://claude.ai/x.json', pkce())).statusCode).toBe(400); // not https → unknown client
    } finally { cimd.fetch = real; }
  });
});
