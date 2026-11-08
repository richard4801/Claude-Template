// AI suite · the takes feed (workstream 1, plans/ai-suite-design.md build step 2; plans/api.md "Takes feed"): the new
// Suite's rail. Newest first: jobs still queued or running (and failed ones, saying why) as one card each, and every
// finished take or photo as its own card. Two queries per page (jobs; takes with their job and model joined), keyset
// paged on (createdAt, id) and merged, so a page never costs more than two round trips.
import { and, desc, eq, inArray, isNull, lt, or, sql, type SQL } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { jobs, models, takes } from '../db/schema.js';
import { badRequest } from '../errors.js';
import { aspectOf, draftSummary, TOOLS, type Draft, type Tool } from './drafts.js';
import { listQueue } from './queue.js';
import { libraryCollectionItems, libraryCollections } from './schema.js';

export const FEED_PAGE = 30;
export const FEED_PAGE_MAX = 60;
const PENDING = ['queued', 'running', 'failed'] as const;
export const FEED_STATUSES = [...PENDING, 'done'] as const;
type Status = (typeof FEED_STATUSES)[number];

const list = <T extends string>(all: readonly T[]) => z.string().max(200).optional().transform((v, c) => {
  if (!v) return undefined;
  const xs = v.split(',').map(x => x.trim()).filter(Boolean);
  const bad = xs.find(x => !all.includes(x as T));
  if (bad) { c.addIssue({ code: 'custom', message: `unknown value "${bad}" (one of ${all.join(', ')})` }); return z.NEVER; }
  return xs as T[];
});
const Query = z.object({
  tool: list(TOOLS), status: list(FEED_STATUSES), model: z.string().max(80).optional(),
  /** Library collections (workstream 1): only that collection's takes and photos. */
  collection: z.string().max(80).optional(),
  cursor: z.string().max(200).optional(), limit: z.coerce.number().int().min(1).max(FEED_PAGE_MAX).optional(),
});

/** A cursor is the last item's (createdAt, id): the next page starts strictly after it. */
export const encodeCursor = (createdAt: number, id: string) => Buffer.from(JSON.stringify([createdAt, id])).toString('base64url');
function decodeCursor(c: string): [number, string] {
  try {
    const v = JSON.parse(Buffer.from(c, 'base64url').toString('utf8'));
    if (Array.isArray(v) && typeof v[0] === 'number' && typeof v[1] === 'string') return [v[0], v[1]];
  } catch { /* fall through */ }
  throw badRequest('Invalid cursor');
}
const after = (col: { createdAt: any; id: any }, c: [number, string] | null): SQL | undefined =>
  c ? or(lt(col.createdAt, c[0]), and(eq(col.createdAt, c[0]), lt(col.id, c[1]))) : undefined;

/** The tool a job was made with: the draft's, else from its request (suite mode, upscale, or the video studio's swap). */
const jobTool = sql`coalesce(${jobs.draft}->>'tool', case
  when ${jobs.request}->>'engine' = 'upscale' then 'upscale'
  when ${jobs.request}->>'engine' = 'suite' then (case ${jobs.request}->>'mode' when 'extend' then 'extend' when 'recast' then 'recast' else 'shot' end)
  else 'swap' end)`;
/** A take's tool: its own draft's (photos), a still is a photo, else its job's. */
const takeTool = sql`coalesce(${takes.draft}->>'tool', case when ${takes.kind} = 'shot' then 'photo' else ${jobTool} end)`;

export type FeedItem = Record<string, unknown> & { id: string; createdAt: number };

export async function feed(ctx: Ctx, u: AuthUser, query: unknown) {
  const q = Query.safeParse(query ?? {});
  if (!q.success) throw badRequest(`Invalid feed query: ${q.error.issues[0]?.path.join('.')} ${q.error.issues[0]?.message}`);
  const { tool, status, model, collection } = q.data;
  const limit = q.data.limit ?? FEED_PAGE;
  const cursor = q.data.cursor ? decodeCursor(q.data.cursor) : null;
  if (collection) {
    const [c] = await ctx.db.select({ id: libraryCollections.id }).from(libraryCollections).where(and(eq(libraryCollections.id, collection), eq(libraryCollections.studioId, u.studioId)));
    if (!c) throw badRequest('collection: no such collection');
  }
  // A collection holds finished takes and photos only.
  const wantPending = collection ? [] : PENDING.filter(s => !status || status.includes(s));
  const wantDone = !status || status.includes('done');
  const pub = ctx.config.PUBLIC_URL ?? '';

  const [pending, done] = await Promise.all([
    wantPending.length ? ctx.db.select().from(jobs).where(and(
      eq(jobs.studioId, u.studioId), eq(jobs.kind, 'render'), isNull(jobs.hiddenAt), inArray(jobs.state, wantPending as Status[] as any),
      model ? eq(jobs.modelId, model) : undefined, tool ? inArray(jobTool, tool) : undefined, after(jobs, cursor),
    )).orderBy(desc(jobs.createdAt), desc(jobs.id)).limit(limit + 1) : Promise.resolve([]),
    wantDone ? ctx.db.select({ t: takes, request: jobs.request, jobDraft: jobs.draft, modelName: models.name, tool: sql<string>`${takeTool}` })
      .from(takes).leftJoin(jobs, eq(takes.jobId, jobs.id)).leftJoin(models, eq(takes.modelId, models.id)).where(and(
        eq(takes.studioId, u.studioId), inArray(takes.kind, ['take', 'shot']), or(isNull(takes.jobId), isNull(jobs.hiddenAt)),
        model ? eq(takes.modelId, model) : undefined, tool ? inArray(takeTool, tool) : undefined, after(takes, cursor),
        collection ? inArray(takes.id, ctx.db.select({ id: libraryCollectionItems.takeId }).from(libraryCollectionItems).where(eq(libraryCollectionItems.collectionId, collection))) : undefined,
      )).orderBy(desc(takes.createdAt), desc(takes.id)).limit(limit + 1) : Promise.resolve([]),
  ]);

  const items: FeedItem[] = [
    ...pending.map(j => jobItem(j)),
    ...done.map(r => takeItem(r.t, r, pub)),
  ].sort((a, b) => b.createdAt - a.createdAt || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
  const page = items.slice(0, limit);
  const more = items.length > limit;
  const last = page.at(-1);
  // The Suite queue (shots saved to run later) sits above the first page.
  const queued = !cursor && !collection && (!status || status.includes('queued')) ? (await listQueue(ctx, u))
    .filter(x => (!tool || tool.includes(x.tool as Tool)) && (!model || x.modelId === model)) : undefined;
  return { ...(queued ? { queued } : {}), items: page, nextCursor: more && last ? encodeCursor(last.createdAt, last.id) : null };
}

const toolOfJob = (j: typeof jobs.$inferSelect): Tool => (j.draft?.tool ?? (j.request.engine === 'upscale' ? 'upscale'
  : j.request.engine === 'suite' ? (j.request.mode === 'extend' ? 'extend' : j.request.mode === 'recast' ? 'recast' : 'shot') : 'swap')) as Tool;

function jobItem(j: typeof jobs.$inferSelect): FeedItem {
  const r = j.request ?? {};
  const seconds = Number(r.seconds ?? r.clipSeconds) || undefined;
  const aspect = j.draft?.aspect ?? r.aspectRatio ?? undefined;
  return strip({
    id: j.id, kind: 'job', status: j.state, tool: toolOfJob(j), jobId: j.id, title: j.title, modelId: j.modelId || undefined, modelName: j.modelName || undefined,
    createdAt: j.createdAt, poster: j.thumb ?? undefined, aspect, durationSec: seconds, takes: Number(r.takes) || 1, price: j.cost,
    progress: j.progress, phase: j.phase || undefined, secondsLeft: j.state === 'running' ? j.secondsLeft : undefined, blocked: j.blocked ?? undefined,
    error: j.state === 'failed' ? j.error ?? 'It didn’t finish' : undefined, errorCode: j.state === 'failed' ? (j.stats as any)?.errorCode : undefined,
    refunded: j.refunded || undefined, label: r.engineLabel ?? undefined,
    summary: draftSummary(j.draft, { aspect, seconds, takes: Number(r.takes) || 1, sound: r.audio ?? undefined }),
  });
}

function takeItem(t: typeof takes.$inferSelect, r: { request: Record<string, any> | null; jobDraft: Draft | null; modelName: string | null; tool: string }, pub: string): FeedItem {
  const draft = t.draft ?? r.jobDraft ?? null;
  const m = t.media ?? {};
  const photo = t.kind === 'shot';
  const aspect = aspectOf(m.width, m.height) ?? draft?.aspect ?? r.request?.aspectRatio ?? (photo ? '9:16' : undefined);
  const seconds = photo ? undefined : Number(m.durationSec ?? r.request?.seconds) || undefined;
  return strip({
    id: t.id, kind: photo ? 'photo' : 'take', status: 'done', tool: r.tool, jobId: t.jobId ?? undefined, takeId: t.id, title: t.title, label: t.label,
    modelId: t.modelId ?? undefined, modelName: r.modelName ?? undefined, createdAt: t.createdAt, poster: t.thumb ?? undefined,
    videoUrl: !photo && t.mediaKey ? `${pub}/uploads/${t.mediaKey}` : undefined, aspect, durationSec: seconds, index: t.index, of: t.of,
    price: t.cost, final: t.status === 'final',
    summary: draftSummary(draft, photo ? { aspect, count: t.of } : { aspect, seconds: Number(r.request?.seconds) || seconds, takes: Number(r.request?.takes) || t.of, sound: r.request?.audio ?? undefined }),
  });
}

const strip = (o: Record<string, unknown>) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as FeedItem;
