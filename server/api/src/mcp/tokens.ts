// Personal access tokens for the MUSE MCP server: the owner makes them in the app and pastes one into Claude Code /
// Claude Desktop. Only a sha256 is stored; the token is shown once. OAuth 2.1 is the documented follow-up
// (plans/mcp-bridge.md "Auth").
import { and, desc, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { studios, users } from '../db/schema.js';
import { ApiError, notFound } from '../errors.js';
import { compact, randomToken, sha256, uid } from '../lib/util.js';
import { mcpTokens } from '../camera/schema.js';
import { parse } from '../camera/validate.js';

export const PAT_PREFIX = 'muse_pat_';
const view = (t: typeof mcpTokens.$inferSelect) =>
  compact({ id: t.id, name: t.name, prefix: t.prefix, createdAt: t.createdAt, lastUsedAt: t.lastUsedAt ?? undefined, expiresAt: t.expiresAt ?? undefined });

export async function listTokens(ctx: Ctx, u: AuthUser) {
  const rows = await ctx.db.select().from(mcpTokens).where(and(eq(mcpTokens.userId, u.id), isNull(mcpTokens.revokedAt))).orderBy(desc(mcpTokens.createdAt));
  return rows.filter(r => !r.expiresAt || r.expiresAt > Date.now()).map(view);
}

export async function createToken(ctx: Ctx, u: AuthUser, body: unknown) {
  const b = parse(z.object({ name: z.string().trim().min(1).max(60), expiresDays: z.number().int().min(1).max(365).optional() }).strict(), body);
  const live = await listTokens(ctx, u);
  if (live.length >= 20) throw new ApiError(409, 'too_many_tokens', 'You have 20 tokens · revoke one first');
  const token = `${PAT_PREFIX}${randomToken(32)}`;
  const now = Date.now();
  const [row] = await ctx.db.insert(mcpTokens).values({ id: uid('pat'), studioId: u.studioId, userId: u.id, name: b.name, tokenHash: sha256(token),
    prefix: token.slice(0, PAT_PREFIX.length + 4), createdAt: now, expiresAt: b.expiresDays ? now + b.expiresDays * 86_400_000 : null }).returning();
  return { ...view(row!), token };
}

export async function revokeToken(ctx: Ctx, u: AuthUser, id: string) {
  const [row] = await ctx.db.update(mcpTokens).set({ revokedAt: Date.now() }).where(and(eq(mcpTokens.id, id), eq(mcpTokens.userId, u.id), isNull(mcpTokens.revokedAt))).returning();
  if (!row) throw notFound('Token');
}

/** The owner behind a token, or null (unknown, revoked, expired, disabled, or no longer the owner). */
export async function authenticatePat(ctx: Ctx, token: string | null): Promise<AuthUser | null> {
  if (!token?.startsWith(PAT_PREFIX)) return null;
  const now = Date.now();
  const [row] = await ctx.db.select({ t: mcpTokens, u: users, s: studios }).from(mcpTokens).innerJoin(users, eq(users.id, mcpTokens.userId))
    .innerJoin(studios, eq(studios.id, users.studioId)).where(and(eq(mcpTokens.tokenHash, sha256(token)), isNull(mcpTokens.revokedAt)));
  if (!row || (row.t.expiresAt && row.t.expiresAt <= now) || row.u.disabledAt || row.u.role !== 'owner') return null;
  if (!row.t.lastUsedAt || now - row.t.lastUsedAt > 60_000) await ctx.db.update(mcpTokens).set({ lastUsedAt: now }).where(eq(mcpTokens.id, row.t.id));
  return { id: row.u.id, studioId: row.u.studioId, email: row.u.email, role: row.u.role, studioName: row.s.name, sessionId: null };
}
