// OAuth 2.1 authorization server for MUSE's MCP endpoint (plans/api.md "Claude on the owner's plan", MCP authorization
// spec 2026-07-28): PKCE (S256 only), resource indicators with audience-bound tokens, Client ID Metadata Documents plus
// dynamic registration, refresh-token rotation with reuse detection. Owner only: members can't connect Claude.
import crypto from 'node:crypto';
import dns from 'node:dns/promises';
import net from 'node:net';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AuthUser, Ctx } from '../ctx.js';
import { studios, users } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { randomToken, sha256, uid } from '../lib/util.js';
import { verifyPassword } from '../auth/auth.js';
import { oauthClients, oauthCodes, oauthTokens } from '../camera/schema.js';

export const SCOPES = ['camera:read', 'camera:write', 'edit:read', 'edit:write', 'cast:read', 'assets:write', 'generate:estimate'] as const;
export type Scope = (typeof SCOPES)[number];
const SCOPE_WORDS: Record<Scope, string> = {
  'camera:read': 'See your camera sessions', 'camera:write': 'Change camera sessions (blocking, camera paths, notes)',
  'edit:read': 'See your edit sessions and takes', 'edit:write': 'Edit videos in the Edit suite (every change can be undone)',
  'cast:read': 'See your characters and their sheets', 'assets:write': 'Upload guide renders and frames',
  'generate:estimate': 'Make Shot drafts with a price (it can never start a paid generation)',
};
export const ACCESS_TTL_SEC = 3600, REFRESH_TTL_SEC = 30 * 86_400, CODE_TTL_SEC = 600;
export const OAT = 'muse_oat_', ORT = 'muse_ort_';
const CLAUDE_REDIRECTS = ['https://claude.ai/api/mcp/auth_callback', 'https://claude.com/api/mcp/auth_callback'];

export const resourceOf = (ctx: Ctx) => `${ctx.publicBase()}/mcp`;
export const parseScopes = (s: unknown): Scope[] => {
  if (typeof s !== 'string' || !s.trim()) return [...SCOPES];
  const asked = s.trim().split(/\s+/).flatMap(x => (x === 'camera:*' ? ['camera:read', 'camera:write'] : x === 'edit:*' ? ['edit:read', 'edit:write'] : [x]));
  const bad = asked.find(x => !(SCOPES as readonly string[]).includes(x));
  if (bad) throw new OAuthError('invalid_scope', `Unknown scope ${bad.slice(0, 40)}`);
  return [...new Set(asked)] as Scope[];
};

export class OAuthError extends Error { constructor(public error: string, message: string, public status = 400) { super(message); } }

/** Loopback (Claude Code), claude.ai's callback, or one the owner added (OAUTH_EXTRA_REDIRECTS, comma separated). */
export function redirectAllowed(ctx: Ctx, uri: string) {
  let u: URL;
  try { u = new URL(uri); } catch { return false; }
  if (u.hash) return false;
  if (u.protocol === 'http:' && (u.hostname === 'localhost' || u.hostname === '127.0.0.1')) return true;
  const extra = (process.env.OAUTH_EXTRA_REDIRECTS ?? '').split(',').map(s => s.trim()).filter(Boolean);
  return [...CLAUDE_REDIRECTS, ...extra].includes(uri);
}

// ---------------------------------------------------------------- clients
export type Client = { id: string; name: string; redirectUris: string[] };
/** Client ID Metadata Documents are fetched with this (tests replace it). */
export const cimd = { fetch: (url: string, signal: AbortSignal) => fetch(url, { signal, redirect: 'error', headers: { accept: 'application/json' } }) };
const cimdCache = new Map<string, { client: Client; at: number }>();

async function publicHost(host: string) {
  if (host === 'localhost' || host.endsWith('.local') || host.endsWith('.internal')) return false;
  const addrs = net.isIP(host) ? [host] : (await dns.lookup(host, { all: true }).catch(() => [])).map(a => a.address);
  if (!addrs.length) return false;
  return addrs.every(a => !/^(10\.|127\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|::1$|f[cd]|fe80)/i.test(a));
}

async function fetchClientDocument(clientId: string): Promise<Client> {
  const hit = cimdCache.get(clientId);
  if (hit && Date.now() - hit.at < 600_000) return hit.client;
  const u = new URL(clientId);
  if (u.protocol !== 'https:' || u.username || u.password || u.hash) throw new OAuthError('invalid_client', 'client_id must be an https URL');
  if (process.env.OAUTH_CIMD_ALLOW_PRIVATE !== '1' && !(await publicHost(u.hostname))) throw new OAuthError('invalid_client', 'client_id host is not public');
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 5000);
  try {
    const r = await cimd.fetch(clientId, ctl.signal);
    if (!r.ok) throw new OAuthError('invalid_client', `client metadata answered ${r.status}`);
    const body = await r.text();
    if (body.length > 64 * 1024) throw new OAuthError('invalid_client', 'client metadata is too large');
    const doc = JSON.parse(body) as { client_id?: unknown; client_name?: unknown; redirect_uris?: unknown };
    if (doc.client_id !== clientId) throw new OAuthError('invalid_client', 'client metadata client_id does not match');
    if (!Array.isArray(doc.redirect_uris) || !doc.redirect_uris.every(x => typeof x === 'string')) throw new OAuthError('invalid_client', 'client metadata has no redirect_uris');
    const client = { id: clientId, name: typeof doc.client_name === 'string' ? doc.client_name.slice(0, 80) : u.hostname, redirectUris: doc.redirect_uris as string[] };
    cimdCache.set(clientId, { client, at: Date.now() });
    return client;
  } catch (e) {
    if (e instanceof OAuthError) throw e;
    throw new OAuthError('invalid_client', 'client metadata could not be read');
  } finally { clearTimeout(t); }
}

export async function resolveClient(ctx: Ctx, clientId: unknown): Promise<Client> {
  if (typeof clientId !== 'string' || !clientId || clientId.length > 500) throw new OAuthError('invalid_client', 'client_id is required');
  if (clientId.startsWith('https://')) return fetchClientDocument(clientId);
  const [c] = await ctx.db.select().from(oauthClients).where(eq(oauthClients.id, clientId));
  if (!c) throw new OAuthError('invalid_client', 'Unknown client');
  return { id: c.id, name: c.name, redirectUris: c.redirectUris };
}

// ---------------------------------------------------------------- tokens
type Grant = { grantId: string; clientId: string; clientName: string; userId: string; studioId: string; scopes: string[]; audience: string };
export async function issueTokens(ctx: Ctx, g: Grant, opts: { refresh?: boolean; accessTtlSec?: number } = {}) {
  const now = Date.now(), access = `${OAT}${randomToken(32)}`;
  const accessTtl = opts.accessTtlSec ?? ACCESS_TTL_SEC;
  const rows: (typeof oauthTokens.$inferInsert)[] = [{ id: uid('tok'), ...g, kind: 'access', tokenHash: sha256(access), createdAt: now, expiresAt: now + accessTtl * 1000 }];
  let refresh: string | undefined;
  if (opts.refresh !== false) {
    refresh = `${ORT}${randomToken(32)}`;
    rows.push({ id: uid('tok'), ...g, kind: 'refresh', tokenHash: sha256(refresh), createdAt: now, expiresAt: now + REFRESH_TTL_SEC * 1000 });
  }
  await ctx.db.insert(oauthTokens).values(rows);
  return { access_token: access, token_type: 'Bearer', expires_in: accessTtl, ...(refresh ? { refresh_token: refresh } : {}), scope: g.scopes.join(' '), expiresAt: now + accessTtl * 1000 };
}

const revokeGrant = (ctx: Ctx, grantId: string) =>
  ctx.db.update(oauthTokens).set({ revokedAt: Date.now() }).where(and(eq(oauthTokens.grantId, grantId), isNull(oauthTokens.revokedAt)));

/** An owner behind an OAuth access token for this audience, with its scopes; null otherwise. */
export async function authenticateAccessToken(ctx: Ctx, token: string, audience: string): Promise<{ user: AuthUser; scopes: string[] } | null> {
  if (!token.startsWith(OAT)) return null;
  const now = Date.now();
  const [row] = await ctx.db.select({ t: oauthTokens, u: users, s: studios }).from(oauthTokens).innerJoin(users, eq(users.id, oauthTokens.userId))
    .innerJoin(studios, eq(studios.id, users.studioId)).where(and(eq(oauthTokens.tokenHash, sha256(token)), eq(oauthTokens.kind, 'access'), isNull(oauthTokens.revokedAt)));
  if (!row || row.t.expiresAt <= now || row.t.audience !== audience || row.u.disabledAt || row.u.role !== 'owner') return null;
  if (!row.t.lastUsedAt || now - row.t.lastUsedAt > 60_000) await ctx.db.update(oauthTokens).set({ lastUsedAt: now }).where(eq(oauthTokens.id, row.t.id));
  return { user: { id: row.u.id, studioId: row.u.studioId, email: row.u.email, role: row.u.role, studioName: row.s.name, sessionId: null }, scopes: row.t.scopes };
}

/** The owner's connected clients (one row per grant, the newest token's times). */
export async function listGrants(ctx: Ctx, u: AuthUser) {
  const rows = await ctx.db.select().from(oauthTokens).where(and(eq(oauthTokens.userId, u.id), isNull(oauthTokens.revokedAt), sql`${oauthTokens.expiresAt} > ${Date.now()}`));
  const by = new Map<string, { id: string; clientName: string; clientId: string; scopes: string[]; createdAt: number; lastUsedAt?: number }>();
  for (const r of rows) {
    if (r.clientId === 'muse-app') continue; // the Mac app's own short-lived tokens
    const g = by.get(r.grantId) ?? { id: r.grantId, clientName: r.clientName, clientId: r.clientId, scopes: r.scopes, createdAt: r.createdAt };
    g.createdAt = Math.min(g.createdAt, r.createdAt);
    if (r.lastUsedAt) g.lastUsedAt = Math.max(g.lastUsedAt ?? 0, r.lastUsedAt);
    by.set(r.grantId, g);
  }
  return [...by.values()].sort((a, b) => b.createdAt - a.createdAt);
}
export async function revokeGrantOf(ctx: Ctx, u: AuthUser, grantId: string) {
  const r = await ctx.db.update(oauthTokens).set({ revokedAt: Date.now() }).where(and(eq(oauthTokens.grantId, grantId), eq(oauthTokens.userId, u.id), isNull(oauthTokens.revokedAt))).returning();
  if (!r.length) throw new ApiError(404, 'not_found', 'Connection not found');
}

/** The Mac app's own token for its local Claude Code (--mcp-config): every scope, no refresh. */
export function sessionToken(ctx: Ctx, u: AuthUser, ttlMinutes: number) {
  return issueTokens(ctx, { grantId: uid('grant'), clientId: 'muse-app', clientName: 'MUSE Mac app', userId: u.id, studioId: u.studioId, scopes: [...SCOPES], audience: resourceOf(ctx) },
    { refresh: false, accessTtlSec: ttlMinutes * 60 });
}

// ---------------------------------------------------------------- the pages and endpoints
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
function page(title: string, body: string) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)}</title>
<style>body{margin:0;background:#F3EFE8;color:#141210;font:15px/1.45 -apple-system,system-ui,sans-serif;display:flex;justify-content:center;padding:48px 16px}
main{max-width:420px;width:100%}h1{font:400 34px/1.1 Georgia,serif;margin:0 0 8px}p{color:#5b554d}ul{padding-left:18px;color:#3a352f}
label{display:block;margin:14px 0 4px;font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:#5b554d}input{width:100%;box-sizing:border-box;padding:11px 12px;border:1px solid #c9c1b4;background:#fffdf9;font:inherit}
.row{display:flex;gap:10px;margin-top:22px}button{flex:1;padding:12px;border:1px solid #141210;font:600 13px/1 system-ui;letter-spacing:.08em;text-transform:uppercase;cursor:pointer}
.go{background:#141210;color:#F3EFE8}.no{background:transparent}.err{color:#B5121B;margin-top:12px}</style></head><body><main>${body}</main></body></html>`;
}

type AuthzParams = { client_id: string; redirect_uri: string; code_challenge: string; code_challenge_method: string; state: string; scope: string; resource: string; response_type: string };
const PARAM_KEYS: (keyof AuthzParams)[] = ['client_id', 'redirect_uri', 'code_challenge', 'code_challenge_method', 'state', 'scope', 'resource', 'response_type'];

async function checkAuthz(ctx: Ctx, p: Partial<AuthzParams>) {
  // Errors before the redirect URI is trusted are shown on our page, never redirected.
  const client = await resolveClient(ctx, p.client_id);
  if (!p.redirect_uri || !client.redirectUris.includes(p.redirect_uri) || !redirectAllowed(ctx, p.redirect_uri)) throw new OAuthError('invalid_request', 'This redirect address is not allowed for this app');
  if (p.response_type !== 'code') throw new OAuthError('unsupported_response_type', 'response_type must be code');
  if (p.code_challenge_method !== 'S256' || !/^[A-Za-z0-9_-]{43,128}$/.test(p.code_challenge ?? '')) throw new OAuthError('invalid_request', 'PKCE with S256 is required');
  if ((p.resource ?? resourceOf(ctx)) !== resourceOf(ctx)) throw new OAuthError('invalid_target', 'resource must be this MUSE server\'s /mcp');
  return { client, scopes: parseScopes(p.scope) };
}

function loginPage(ctx: Ctx, client: Client, p: Partial<AuthzParams>, scopes: Scope[], error?: string) {
  const hidden = PARAM_KEYS.map(k => `<input type="hidden" name="${k}" value="${esc(p[k] ?? '')}">`).join('');
  return page('Connect Claude to MUSE', `<h1>Connect to MUSE</h1>
<p><b>${esc(client.name)}</b> wants to use your studio as the studio owner. It will be able to:</p>
<ul>${scopes.map(s => `<li>${esc(SCOPE_WORDS[s])}</li>`).join('')}</ul>
<p>It can never spend money: generating always waits for you in the MUSE app.</p>
<form method="post" action="/oauth/authorize">${hidden}
<label for="email">Owner email</label><input id="email" name="email" type="email" autocomplete="username" required>
<label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" required>
${error ? `<p class="err">${esc(error)}</p>` : ''}
<div class="row"><button class="no" name="decision" value="deny">Cancel</button><button class="go" name="decision" value="allow">Allow</button></div></form>
<p style="font-size:12px;margin-top:18px">Returns to ${esc(new URL(p.redirect_uri!).host)}.</p>`);
}

const redirectWith = (reply: FastifyReply, uri: string, q: Record<string, string | undefined>) => {
  const u = new URL(uri);
  for (const [k, v] of Object.entries(q)) if (v !== undefined && v !== '') u.searchParams.set(k, v);
  return reply.redirect(u.toString(), 302);
};

export function verifierMatches(verifier: string, challenge: string) {
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier)) return false;
  const want = Buffer.from(crypto.createHash('sha256').update(verifier).digest('base64url')), got = Buffer.from(challenge);
  return want.length === got.length && crypto.timingSafeEqual(want, got);
}

export async function registerOAuthRoutes(app: FastifyInstance, ctx: Ctx) {
  const base = () => ctx.publicBase();
  // Token, register and authorize-form bodies are form-encoded.
  app.addContentTypeParser('application/x-www-form-urlencoded', { parseAs: 'string', bodyLimit: 64 * 1024 }, (_req, body, done) => {
    done(null, Object.fromEntries(new URLSearchParams(body as string)));
  });
  const pub = { config: { public: true } };
  const limited = { config: { public: true, rateLimit: { max: Math.max(10, ctx.config.AUTH_RATE_PER_MIN), timeWindow: '1 minute' } } };
  const oauthFail = (reply: FastifyReply, e: unknown) => {
    if (e instanceof OAuthError) return reply.status(e.status).header('cache-control', 'no-store').send({ error: e.error, error_description: e.message });
    throw e;
  };

  app.get('/.well-known/oauth-authorization-server', pub, async () => ({
    issuer: base(), authorization_endpoint: `${base()}/oauth/authorize`, token_endpoint: `${base()}/oauth/token`,
    registration_endpoint: `${base()}/oauth/register`, revocation_endpoint: `${base()}/oauth/revoke`,
    response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'], code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'], scopes_supported: [...SCOPES], client_id_metadata_document_supported: true,
    service_documentation: 'https://github.com/richard4801/claude-template/blob/main/plans/mcp-bridge.md',
  }));

  app.post('/oauth/register', limited, async (req, reply) => {
    try {
      const b = (req.body ?? {}) as { redirect_uris?: unknown; client_name?: unknown; token_endpoint_auth_method?: unknown };
      if (!Array.isArray(b.redirect_uris) || !b.redirect_uris.length || b.redirect_uris.length > 10 || !b.redirect_uris.every(u => typeof u === 'string' && redirectAllowed(ctx, u))) {
        throw new OAuthError('invalid_redirect_uri', 'redirect_uris must be claude.ai\'s callback or a loopback address');
      }
      if (b.token_endpoint_auth_method && b.token_endpoint_auth_method !== 'none') throw new OAuthError('invalid_client_metadata', 'Only public clients (token_endpoint_auth_method none)');
      const now = Date.now(), name = typeof b.client_name === 'string' && b.client_name.trim() ? b.client_name.trim().slice(0, 80) : 'Claude';
      const [c] = await ctx.db.insert(oauthClients).values({ id: uid('cli'), name, redirectUris: b.redirect_uris as string[], createdAt: now }).returning();
      return reply.status(201).send({ client_id: c!.id, client_id_issued_at: Math.floor(now / 1000), client_name: name, redirect_uris: c!.redirectUris,
        token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] });
    } catch (e) { return oauthFail(reply, e); }
  });

  app.get('/oauth/authorize', pub, async (req, reply) => {
    const p = (req.query ?? {}) as Partial<AuthzParams>;
    try {
      const { client, scopes } = await checkAuthz(ctx, p);
      return reply.header('content-type', 'text/html; charset=utf-8').header('cache-control', 'no-store').header('x-frame-options', 'DENY')
        .header('content-security-policy', "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
        .send(loginPage(ctx, client, p, scopes));
    } catch (e) {
      if (!(e instanceof OAuthError)) throw e;
      return reply.status(400).header('content-type', 'text/html; charset=utf-8').send(page('MUSE', `<h1>Can't connect</h1><p>${esc(e.message)}</p>`));
    }
  });

  app.post('/oauth/authorize', limited, async (req, reply) => {
    const b = (req.body ?? {}) as Partial<AuthzParams> & { email?: string; password?: string; decision?: string };
    let checked: Awaited<ReturnType<typeof checkAuthz>>;
    try { checked = await checkAuthz(ctx, b); } catch (e) {
      if (!(e instanceof OAuthError)) throw e;
      return reply.status(400).header('content-type', 'text/html; charset=utf-8').send(page('MUSE', `<h1>Can't connect</h1><p>${esc(e.message)}</p>`));
    }
    const html = (msg: string, status = 200) => reply.status(status).header('content-type', 'text/html; charset=utf-8').header('cache-control', 'no-store')
      .header('x-frame-options', 'DENY').send(loginPage(ctx, checked.client, b, checked.scopes, msg));
    if (b.decision !== 'allow') return redirectWith(reply, b.redirect_uri!, { error: 'access_denied', state: b.state, iss: base() });
    const email = (b.email ?? '').trim().toLowerCase();
    const [u] = email ? await ctx.db.select().from(users).where(sql`lower(${users.email}) = ${email}`) : [];
    const ok = u ? await verifyPassword(u.passwordHash, b.password ?? '') : false;
    if (!u || !ok) return html('Wrong email or password', 401);
    if (u.disabledAt) return html('This account is switched off', 403);
    if (u.role !== 'owner') return html('Only the studio owner can connect Claude to MUSE', 403);
    const code = randomToken(32);
    await ctx.db.insert(oauthCodes).values({ codeHash: sha256(code), clientId: checked.client.id, clientName: checked.client.name, userId: u.id, studioId: u.studioId,
      redirectUri: b.redirect_uri!, codeChallenge: b.code_challenge!, resource: resourceOf(ctx), scopes: checked.scopes, expiresAt: Date.now() + CODE_TTL_SEC * 1000 });
    return redirectWith(reply, b.redirect_uri!, { code, state: b.state, iss: base() });
  });

  app.post('/oauth/token', limited, async (req, reply) => {
    const b = (req.body ?? {}) as Record<string, string | undefined>;
    try {
      reply.header('cache-control', 'no-store').header('pragma', 'no-cache');
      if (b.resource && b.resource !== resourceOf(ctx)) throw new OAuthError('invalid_target', 'resource must be this MUSE server\'s /mcp');
      if (b.grant_type === 'authorization_code') {
        const [c] = b.code ? await ctx.db.select().from(oauthCodes).where(eq(oauthCodes.codeHash, sha256(b.code))) : [];
        if (!c || c.expiresAt <= Date.now()) throw new OAuthError('invalid_grant', 'The code is unknown or expired');
        if (c.usedAt) {
          // A code used twice: revoke what it produced (RFC 6749 §4.1.2).
          await ctx.db.update(oauthTokens).set({ revokedAt: Date.now() }).where(and(eq(oauthTokens.grantId, `grant_${c.codeHash.slice(0, 24)}`), isNull(oauthTokens.revokedAt)));
          throw new OAuthError('invalid_grant', 'The code was already used');
        }
        if (c.clientId !== b.client_id || c.redirectUri !== b.redirect_uri) throw new OAuthError('invalid_grant', 'client_id or redirect_uri does not match');
        if (!verifierMatches(b.code_verifier ?? '', c.codeChallenge)) throw new OAuthError('invalid_grant', 'PKCE verification failed');
        const [claimed] = await ctx.db.update(oauthCodes).set({ usedAt: Date.now() }).where(and(eq(oauthCodes.codeHash, c.codeHash), isNull(oauthCodes.usedAt))).returning();
        if (!claimed) throw new OAuthError('invalid_grant', 'The code was already used');
        const [u] = await ctx.db.select().from(users).where(eq(users.id, c.userId));
        if (!u || u.role !== 'owner' || u.disabledAt) throw new OAuthError('invalid_grant', 'Only the studio owner can connect Claude');
        const t = await issueTokens(ctx, { grantId: `grant_${c.codeHash.slice(0, 24)}`, clientId: c.clientId, clientName: c.clientName, userId: c.userId, studioId: c.studioId,
          scopes: c.scopes, audience: c.resource });
        const { expiresAt: _e, ...body } = t;
        return body;
      }
      if (b.grant_type === 'refresh_token') {
        const [r] = b.refresh_token?.startsWith(ORT) ? await ctx.db.select().from(oauthTokens).where(and(eq(oauthTokens.tokenHash, sha256(b.refresh_token)), eq(oauthTokens.kind, 'refresh'))) : [];
        if (!r || r.revokedAt || r.expiresAt <= Date.now()) throw new OAuthError('invalid_grant', 'The refresh token is not valid');
        if (r.clientId !== b.client_id) throw new OAuthError('invalid_grant', 'client_id does not match');
        if (r.usedAt) { await revokeGrant(ctx, r.grantId); throw new OAuthError('invalid_grant', 'The refresh token was already used; the connection was revoked'); }
        const [claimed] = await ctx.db.update(oauthTokens).set({ usedAt: Date.now() }).where(and(eq(oauthTokens.id, r.id), isNull(oauthTokens.usedAt))).returning();
        if (!claimed) { await revokeGrant(ctx, r.grantId); throw new OAuthError('invalid_grant', 'The refresh token was already used'); }
        const [u] = await ctx.db.select().from(users).where(eq(users.id, r.userId));
        if (!u || u.role !== 'owner' || u.disabledAt) { await revokeGrant(ctx, r.grantId); throw new OAuthError('invalid_grant', 'Only the studio owner can connect Claude'); }
        const scopes = b.scope ? parseScopes(b.scope) : r.scopes;
        if (scopes.some(s => !r.scopes.includes(s))) throw new OAuthError('invalid_scope', 'A refresh can\'t widen the scopes');
        const t = await issueTokens(ctx, { grantId: r.grantId, clientId: r.clientId, clientName: r.clientName, userId: r.userId, studioId: r.studioId, scopes, audience: r.audience });
        const { expiresAt: _e, ...body } = t;
        return body;
      }
      throw new OAuthError('unsupported_grant_type', 'grant_type must be authorization_code or refresh_token');
    } catch (e) { return oauthFail(reply, e); }
  });

  app.post('/oauth/revoke', limited, async (req, reply) => {
    const token = String(((req.body ?? {}) as { token?: string }).token ?? '');
    if (token) {
      const [r] = await ctx.db.select().from(oauthTokens).where(eq(oauthTokens.tokenHash, sha256(token)));
      if (r) await revokeGrant(ctx, r.grantId);
    }
    return reply.status(200).send({});
  });
}

export type { FastifyRequest };
