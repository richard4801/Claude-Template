// One Claude, full control (plans/claude-control-audit.md): Claude's tools call MUSE's own routes in-process, AS the
// person (their permissions, member filtering and wallet exactly as in the app), so every screen action can become a
// tool without copying its logic. A call carries a one-time random grant (never leaves the process, valid 30 s, used
// once); the /v1 auth hook swaps it for the person. No network hop and no token.
import { randomBytes } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError } from '../errors.js';

const apps = new WeakMap<Ctx, FastifyInstance>();
const grants = new Map<string, { user: AuthUser; until: number }>();
const HEADER = 'x-muse-claude-grant';

export const bindAppCaller = (ctx: Ctx, app: FastifyInstance) => { apps.set(ctx, app); };

/** The auth hook: the person behind an in-process grant, or undefined (then the normal bearer check runs). */
export function grantUser(req: FastifyRequest): AuthUser | undefined {
  const g = req.headers[HEADER];
  if (typeof g !== 'string') return undefined;
  const hit = grants.get(g);
  grants.delete(g);
  if (!hit || hit.until < Date.now()) throw new ApiError(401, 'unauthorized', 'Sign in to continue');
  return hit.user;
}

/** Calls a MUSE route as the person; returns its JSON or throws its error as an ApiError (Claude sees code: message). */
export async function appCall(ctx: Ctx, user: AuthUser, method: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE', url: string, body?: unknown): Promise<any> {
  const app = apps.get(ctx);
  if (!app) throw new ApiError(503, 'not_ready', 'MUSE is starting; try again');
  const g = randomBytes(32).toString('hex');
  grants.set(g, { user, until: Date.now() + 30_000 });
  try {
    const res = await app.inject({ method, url, headers: { [HEADER]: g, ...(body !== undefined ? { 'content-type': 'application/json' } : {}) }, ...(body !== undefined ? { payload: JSON.stringify(body) } : {}) });
    const data = res.body ? (() => { try { return JSON.parse(res.body); } catch { return res.body; } })() : null;
    if (res.statusCode >= 400) throw new ApiError(res.statusCode, (data as { code?: string })?.code ?? 'error', (data as { error?: string })?.error ?? `HTTP ${res.statusCode}`);
    return data;
  } finally { grants.delete(g); }
}

/** Keeps a result small for Claude: long strings (signed URLs, data) are cut, arrays capped. */
export function slim(v: unknown, max = 30, depth = 0): unknown {
  if (typeof v === 'string') return v.length > 240 ? (/^https?:\/\//.test(v) ? '[link]' : `${v.slice(0, 240)}…`) : v;
  if (Array.isArray(v)) { const a = v.slice(0, max).map(x => slim(x, max, depth + 1)); return v.length > max ? [...a, `…${v.length - max} more`] : a; }
  if (v && typeof v === 'object') {
    if (depth > 5) return '[…]';
    return Object.fromEntries(Object.entries(v).filter(([, x]) => x !== null && x !== undefined).map(([k, x]) => [k, slim(x, max, depth + 1)]));
  }
  return v;
}
