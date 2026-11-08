// The Suite queue (workstream 1; plans/ai-suite-design.md "Refinements" 1; plans/api.md "Suite queue"): a shot saved
// to run later. Queuing checks the shot and prices it, but holds nothing. "Run · $cost" prices it again (prices and
// caps may have moved), the app confirms, and the run goes through the normal path (POST /v1/suite/shots: caps, hold,
// job). Each member sees their own queue; the owner sees the studio's. The feed shows it at the top of its first page.
import { and, desc, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { draftOf } from './drafts.js';
import { suiteQueue } from './schema.js';

export const QUEUE_MAX = 50;
type Row = typeof suiteQueue.$inferSelect;
const money = (v: number) => `$${v.toFixed(2)}`;

/** The shot request as it will run: without the queue and dry-run switches. */
function shotBody(body: unknown): Record<string, unknown> {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw badRequest('Send the shot as POST /v1/suite/shots takes it');
  const { queue: _q, dryRun: _d, ...rest } = body as Record<string, unknown>;
  return rest;
}
const toolOf = (body: Record<string, unknown>) => (draftOf(body)?.tool ?? (body.mode === 'swap' ? 'swap' : body.mode === 'recast' ? 'recast' : body.mode === 'extend' ? 'extend' : 'shot'));
export function queueView(r: Row, u: AuthUser) {
  const b = r.body, d = draftOf(b);
  return {
    id: r.id, kind: 'queued' as const, title: r.title, tool: toolOf(b), modelId: typeof b.modelId === 'string' ? b.modelId : undefined, userId: r.userId, mine: r.userId === u.id,
    estimate: r.estimate, buttonLabel: `Run · ${money(r.estimate)}`, prompt: typeof b.prompt === 'string' ? b.prompt : undefined,
    ...(d ? { draft: d } : {}), createdAt: r.createdAt,
  };
}
/** Only the one who queued it and the owner hear about a queued shot. */
const emitQueue = (ctx: Ctx, r: Row, e: Record<string, unknown>) =>
  ctx.hub.emit(r.studioId, v => (v.role === 'owner' || v.userId === r.userId ? { type: 'queue', ...e } : null));
const scope = (u: AuthUser) => u.role === 'owner' ? eq(suiteQueue.studioId, u.studioId) : and(eq(suiteQueue.studioId, u.studioId), eq(suiteQueue.userId, u.id));

export async function listQueue(ctx: Ctx, u: AuthUser) {
  return (await ctx.db.select().from(suiteQueue).where(scope(u)).orderBy(desc(suiteQueue.createdAt))).map(r => queueView(r, u));
}
async function row(ctx: Ctx, u: AuthUser, id: string) {
  const [r] = await ctx.db.select().from(suiteQueue).where(and(eq(suiteQueue.id, id), scope(u)));
  if (!r) throw notFound('Queued shot');
  return r;
}

/** POST /v1/suite/queue: checks and prices the shot (nothing held, nothing runs) and saves it. */
export async function queueShot(ctx: Ctx, u: AuthUser, body: unknown) {
  const b = shotBody(body);
  const n = (await ctx.db.select({ id: suiteQueue.id }).from(suiteQueue).where(and(eq(suiteQueue.studioId, u.studioId), eq(suiteQueue.userId, u.id)))).length;
  if (n >= QUEUE_MAX) throw new ApiError(409, 'queue_full', `Up to ${QUEUE_MAX} shots can wait in your queue · run or discard some first`);
  const est = await ctx.suite.estimate(u, b) as { estimate?: number };
  const d = draftOf(b);
  const title = (typeof b.title === 'string' && b.title.trim()) || (typeof b.prompt === 'string' && b.prompt.trim().slice(0, 60)) || (d?.tool ? `Queued ${d.tool}` : 'Queued shot');
  const [r] = await ctx.db.insert(suiteQueue).values({ id: uid('sq'), studioId: u.studioId, userId: u.id, title, body: b, estimate: Number(est.estimate) || 0, createdAt: Date.now() }).returning();
  emitQueue(ctx, r!, { item: queueView(r!, u) });
  return queueView(r!, u);
}

/** POST /v1/suite/queue/:id/estimate: today's price (the queued one may be stale), for the confirm. */
export async function queueEstimate(ctx: Ctx, u: AuthUser, id: string) {
  const r = await row(ctx, u, id);
  const est = await ctx.suite.estimate(u, r.body) as Record<string, unknown> & { estimate?: number };
  const now = Number(est.estimate) || 0;
  if (Math.abs(now - r.estimate) > 1e-9) await ctx.db.update(suiteQueue).set({ estimate: now }).where(eq(suiteQueue.id, r.id));
  return { ...queueView({ ...r, estimate: now }, u), estimateView: est, changed: Math.abs(now - r.estimate) > 0.005 };
}

/** POST /v1/suite/queue/:id/run {confirm: true}: the normal shot path (caps, hold, job); the queue entry goes. */
export async function runQueued(ctx: Ctx, u: AuthUser, id: string, body: unknown) {
  if ((body as { confirm?: unknown } | null)?.confirm !== true) throw badRequest('confirm: true, after showing the price (POST …/estimate)');
  const r = await row(ctx, u, id);
  const job = await ctx.suite.create(u, r.body);
  await ctx.db.delete(suiteQueue).where(eq(suiteQueue.id, r.id));
  emitQueue(ctx, r, { removed: r.id, jobId: (job as { id?: string }).id });
  return { queuedId: r.id, job };
}

/** DELETE /v1/suite/queue/:id: discard (nothing was held). */
export async function discardQueued(ctx: Ctx, u: AuthUser, id: string) {
  const r = await row(ctx, u, id);
  await ctx.db.delete(suiteQueue).where(eq(suiteQueue.id, r.id));
  emitQueue(ctx, r, { removed: r.id });
}
