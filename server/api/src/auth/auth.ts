// Invite-only accounts: argon2id passwords, bearer-token sessions (only a sha256 of the token is stored, revocable),
// invite codes (only a hash stored; shown once). One shared studio for now.
import crypto from 'node:crypto';
import { hash, verify } from '@node-rs/argon2';
import { and, eq, gt, isNull, sql } from 'drizzle-orm';
import type { FastifyRequest } from 'fastify';
import type { AuthUser, Ctx } from '../ctx.js';
import { invites, sessions, studios, users } from '../db/schema.js';
import { ApiError } from '../errors.js';
import { randomToken, sha256, uid } from '../lib/util.js';

export const hashPassword = (pw: string) => hash(pw, { memoryCost: 19456, timeCost: 2, parallelism: 1 });
export const verifyPassword = (h: string, pw: string) => verify(h, pw).catch(() => false);

/** Invite codes look like "MUSE-7KQ2-XW9P-4HTD": easy to read out, 60 bits of randomness. */
export function newInviteCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let s = '';
  for (let i = 0; i < 12; i++) s += alphabet[crypto.randomInt(alphabet.length)];
  return `MUSE-${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
}
const normCode = (c: string) => c.trim().toUpperCase();

export async function ensureStudio(ctx: Pick<Ctx, 'db'>, name = 'MUSE Studio') {
  const [s] = await ctx.db.select().from(studios).limit(1);
  if (s) return s;
  const [n] = await ctx.db.insert(studios).values({ id: uid('st'), name, createdAt: Date.now() }).returning();
  return n!;
}

/** Creates an invite. The first one for a studio with no owner makes an owner; later ones make members (unless asked). */
export async function createInvite(ctx: Pick<Ctx, 'db'>, o: { studioId: string; email?: string | null; role?: 'owner' | 'member'; createdBy?: string | null; days?: number }) {
  const [owner] = await ctx.db.select({ id: users.id }).from(users).where(and(eq(users.studioId, o.studioId), eq(users.role, 'owner'))).limit(1);
  const role = o.role ?? (owner ? 'member' : 'owner');
  const code = newInviteCode();
  const now = Date.now();
  const [inv] = await ctx.db.insert(invites).values({
    id: uid('inv'), studioId: o.studioId, codeHash: sha256(normCode(code)), email: o.email?.trim().toLowerCase() || null, role,
    createdBy: o.createdBy ?? null, createdAt: now, expiresAt: now + (o.days ?? 14) * 86_400_000,
  }).returning();
  return { code, id: inv!.id, email: inv!.email, role, expiresAt: inv!.expiresAt };
}

export async function issueSession(ctx: Pick<Ctx, 'db' | 'config'>, user: { id: string; studioId: string }) {
  const token = `muse_${randomToken(32)}`;
  const now = Date.now();
  await ctx.db.insert(sessions).values({ id: uid('ses'), userId: user.id, studioId: user.studioId, tokenHash: sha256(token), createdAt: now,
    expiresAt: now + ctx.config.SESSION_DAYS * 86_400_000 });
  return token;
}

export async function userView(ctx: Pick<Ctx, 'db'>, u: typeof users.$inferSelect) {
  const [s] = await ctx.db.select().from(studios).where(eq(studios.id, u.studioId));
  return { id: u.id, studioName: s?.name ?? 'MUSE Studio', email: u.email, role: u.role };
}

export async function signup(ctx: Ctx, b: { studioName?: string; email?: string; password?: string; inviteCode?: string; attestAdultRightsOriginal?: unknown; attestLabelAi?: unknown }) {
  // Attestations first: the contract's attestation_required comes before anything else.
  if (b.attestAdultRightsOriginal !== true || b.attestLabelAi !== true) throw new ApiError(400, 'attestation_required', 'Tick both boxes to continue');
  const email = (b.email ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new ApiError(400, 'bad_request', 'Enter a valid email');
  const pw = b.password ?? '';
  const minPw = ctx.config.DEV_MODE ? 1 : ctx.config.MIN_PASSWORD;
  if (pw.length < minPw) throw new ApiError(400, 'bad_request', `Use a password of at least ${minPw} characters`);
  const [existing] = await ctx.db.select().from(users).where(sql`lower(${users.email}) = ${email}`);
  if (existing) throw new ApiError(409, 'email_taken', 'That email already has an account · sign in instead');

  let studioId: string, role: 'owner' | 'member', inviteId: string | null = null;
  if (b.inviteCode) {
    const [inv] = await ctx.db.select().from(invites).where(and(eq(invites.codeHash, sha256(normCode(b.inviteCode))), isNull(invites.usedAt), gt(invites.expiresAt, Date.now())));
    if (!inv) throw new ApiError(400, 'invite_invalid', 'That invite code is not valid or has expired');
    if (inv.email && inv.email !== email) throw new ApiError(400, 'invite_invalid', 'That invite is for a different email');
    studioId = inv.studioId; role = inv.role; inviteId = inv.id;
  } else if (ctx.config.DEV_MODE) {
    // Dev only: sign-up without an invite joins the dev studio as an owner (so the app contract tests can sign up).
    studioId = (await ensureStudio(ctx, b.studioName || 'Dev Studio')).id; role = 'owner';
  } else {
    throw new ApiError(400, 'invite_required', 'MUSE is invite-only for now · enter your invite code');
  }
  const now = Date.now();
  const [u] = await ctx.db.insert(users).values({
    id: uid('u'), studioId, email, passwordHash: await hashPassword(pw), role, attestAdultRightsOriginalAt: now, attestLabelAiAt: now,
    inviteId, createdAt: now, lastActiveAt: now,
  }).returning();
  if (inviteId) await ctx.db.update(invites).set({ usedAt: now, usedBy: u!.id }).where(eq(invites.id, inviteId));
  return { token: await issueSession(ctx, u!), user: await userView(ctx, u!) };
}

export async function signin(ctx: Ctx, b: { email?: string; password?: string }) {
  const email = (b.email ?? '').trim().toLowerCase();
  if (!email) throw new ApiError(400, 'bad_request', 'Enter your email');
  const [u] = await ctx.db.select().from(users).where(sql`lower(${users.email}) = ${email}`);
  // Same answer and similar time whether or not the account exists.
  const ok = u ? await verifyPassword(u.passwordHash, b.password ?? '') : (await hashPassword('timing-equaliser'), false);
  if (!u || !ok) throw new ApiError(401, 'bad_credentials', 'Wrong email or password');
  if (u.disabledAt) throw new ApiError(403, 'account_disabled', 'This account is switched off · ask the studio owner');
  await ctx.db.update(users).set({ lastActiveAt: Date.now() }).where(eq(users.id, u.id));
  return { token: await issueSession(ctx, u), user: await userView(ctx, u) };
}

/** Resolves the bearer token (header, or ?token= for clients whose event-stream API can't set headers). */
export async function authenticate(ctx: Ctx, req: FastifyRequest): Promise<AuthUser> {
  const h = req.headers.authorization;
  let token = h?.startsWith('Bearer ') ? h.slice(7).trim() : null;
  if (!token && req.method === 'GET') token = (req.query as Record<string, string> | undefined)?.token ?? null;
  if (!token) throw new ApiError(401, 'unauthorized', 'Sign in to continue');
  const now = Date.now();
  const [row] = await ctx.db.select({ s: sessions, u: users, st: studios }).from(sessions)
    .innerJoin(users, eq(users.id, sessions.userId)).innerJoin(studios, eq(studios.id, users.studioId))
    .where(and(eq(sessions.tokenHash, sha256(token)), isNull(sessions.revokedAt), gt(sessions.expiresAt, now)));
  if (!row) throw new ApiError(401, 'unauthorized', 'Your session has ended · sign in again');
  if (row.u.disabledAt) throw new ApiError(403, 'account_disabled', 'This account is switched off · ask the studio owner');
  if (!row.s.lastUsedAt || now - row.s.lastUsedAt > 60_000) {
    await ctx.db.update(sessions).set({ lastUsedAt: now }).where(eq(sessions.id, row.s.id));
    await ctx.db.update(users).set({ lastActiveAt: now }).where(eq(users.id, row.u.id));
  }
  return { id: row.u.id, studioId: row.u.studioId, email: row.u.email, role: row.u.role, studioName: row.st.name, sessionId: row.s.id };
}

export async function revokeSession(ctx: Ctx, sessionId: string) {
  await ctx.db.update(sessions).set({ revokedAt: Date.now() }).where(eq(sessions.id, sessionId));
}

/** OWNER_INVITE_CODE: makes an owner invite with the owner's own code while the studio has no owner. */
export async function bootstrapOwnerInvite(ctx: Pick<Ctx, 'db' | 'config' | 'log'>) {
  const code = ctx.config.OWNER_INVITE_CODE;
  if (!code) return;
  if (code.trim().length < 12) { ctx.log.warn('OWNER_INVITE_CODE is too short (12+ characters): ignored'); return; }
  const studio = await ensureStudio(ctx, ctx.config.STUDIO_NAME);
  const [owner] = await ctx.db.select({ id: users.id }).from(users).where(and(eq(users.studioId, studio.id), eq(users.role, 'owner'))).limit(1);
  if (owner) { ctx.log.info('OWNER_INVITE_CODE is set but the studio has an owner: you can delete the variable'); return; }
  const hash = sha256(normCode(code));
  const [exists] = await ctx.db.select({ id: invites.id }).from(invites).where(eq(invites.codeHash, hash));
  const now = Date.now();
  if (exists) await ctx.db.update(invites).set({ usedAt: null, expiresAt: now + 7 * 86_400_000 }).where(eq(invites.id, exists.id));
  else await ctx.db.insert(invites).values({ id: uid('inv'), studioId: studio.id, codeHash: hash, email: ctx.config.OWNER_EMAIL?.trim().toLowerCase() || null, role: 'owner', createdAt: now, expiresAt: now + 7 * 86_400_000 });
  ctx.log.info('owner invite from OWNER_INVITE_CODE is ready: sign up in the app with it');
}
