// One Claude, full control · batch B2 (plans/claude-control-audit.md): actions that spend, delete or post, behind ONE
// go-ahead. Without confirm a gated tool says what it would do (and the price, from the screen's own estimate). With
// confirm: true it stores the exact call as a waiting action and puts an Approve card in the person's chat; nothing
// happens until THEY press Approve (POST /v1/claude/actions/:id {approve: true}), and then the stored call runs as them
// (their permissions, their wallet). Claude can never approve: the approve route is not a tool. Waiting actions expire.
import { and, desc, eq, lt } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { compact, uid } from '../lib/util.js';
import { parse } from '../camera/validate.js';
import type { EditTool } from '../editor/mcpTools.js';
import { appCall, slim } from './appCall.js';
import { ownChat, uiLine } from './chatTools.js';
import { claudeActions } from './schema.js';
import type { Gate } from './registry.js';

const EXPIRES_MS = 30 * 60_000;
type Method = 'POST' | 'DELETE' | 'PATCH' | 'PUT';
type Plan = { summary: string; method: Method; url: string; body?: unknown; priceUsd?: number | null };
type Env = Parameters<EditTool['run']>[0];
export type GatedTool = EditTool & { gate: Exclude<Gate, 'none'> };

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const CONFIRM = { type: 'boolean', description: 'Ask the person to approve (an Approve card in their app). Leave out to see what it would do and the price.' };
const CHAT_ID = str('This chat (filled in for you in the app)');
const enc = encodeURIComponent;
const id = (v: unknown, what: string) => { if (typeof v !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(v)) throw badRequest(`${what}: an id`); return v; };
/** The price in an estimate answer, whatever the screen calls it. */
export function priceOf(e: unknown): number | null {
  if (!e || typeof e !== 'object') return null;
  const o = e as Record<string, unknown>;
  for (const k of ['estimateUsd', 'usd', 'totalUsd', 'priceUsd', 'cost', 'price', 'total']) if (typeof o[k] === 'number') return o[k] as number;
  for (const k of ['estimate', 'quote', 'price']) if (o[k] && typeof o[k] === 'object') { const p = priceOf(o[k]); if (p !== null) return p; }
  return null;
}
const money = (p: number | null | undefined) => (typeof p === 'number' ? ` · $${p.toFixed(2)}` : '');

/** One gated tool: plan() works out the exact call (and the price) without changing anything. */
function gated(def: Omit<EditTool, 'run' | 'inputSchema'> & { gate: GatedTool['gate']; props: Record<string, unknown>; required: string[]; plan: (env: Env, a: Record<string, unknown>) => Promise<Plan> }): GatedTool {
  const { props, required, plan, ...rest } = def;
  return {
    ...rest,
    inputSchema: { type: 'object', additionalProperties: false, required, properties: { chatId: CHAT_ID, ...props, confirm: CONFIRM } },
    run: async (env, a) => {
      const p = await plan(env, a);
      if (a.confirm !== true) {
        return compact({ needsConfirmation: true, would: p.summary, estimateUsd: p.priceUsd ?? undefined,
          message: `${p.summary}${money(p.priceUsd)}. Call again with confirm: true to ask the person; it happens only after they press Approve.` });
      }
      return requestApproval(env, def.name, def.gate, p, typeof a.chatId === 'string' ? a.chatId : undefined);
    },
  };
}

async function requestApproval(env: Env, tool: string, gate: string, p: Plan, chatId?: string) {
  const u = env.user, now = Date.now();
  const chat = chatId ? await ownChat(env.ctx, u, chatId).catch(() => null) : null;
  const [row] = await env.ctx.db.insert(claudeActions).values({ id: uid('ca'), studioId: u.studioId, userId: u.id, chatId: chat?.id ?? null, tool, gate,
    summary: p.summary, priceUsd: p.priceUsd ?? null, call: { method: p.method, url: p.url, body: p.body ?? null }, status: 'waiting', createdAt: now, updatedAt: now, expiresAt: now + EXPIRES_MS }).returning();
  const ui = compact({ approve: row!.id, gate, summary: p.summary, priceUsd: p.priceUsd ?? undefined, label: `${gate === 'delete' ? 'Delete' : gate === 'post' ? 'Post' : gate === 'spend' ? 'Approve' : 'Change'}${money(p.priceUsd)}` });
  if (chat) await uiLine(env.ctx, u, chat.id, 'approve', `Waiting for your go-ahead: ${p.summary}${money(p.priceUsd)}`, ui);
  else void env.ctx.hub.emitTo(u.id, { type: 'claude', op: 'ui', name: 'approve', ui });
  return { waitingForApproval: true, actionId: row!.id, would: p.summary, estimateUsd: p.priceUsd ?? undefined,
    message: 'The person sees an Approve card in the MUSE app (Claude panel). Nothing happens until they press it; don\'t say it is done. If their app shows no button, tell them to do it on its screen instead (open the page for them).' };
}

export const actionView = (r: typeof claudeActions.$inferSelect) => compact({ id: r.id, tool: r.tool, gate: r.gate, summary: r.summary, priceUsd: r.priceUsd ?? undefined,
  status: r.status, result: r.result ?? undefined, error: r.error ?? undefined, chatId: r.chatId ?? undefined, createdAt: r.createdAt, expiresAt: r.expiresAt });

/** The person answers an Approve card. Only the person it was made for, once, before it expires. */
export async function answerAction(ctx: Ctx, u: AuthUser, actionId: string, body: unknown) {
  const b = parse(z.object({ approve: z.boolean() }).strict(), body ?? {});
  const [r] = await ctx.db.select().from(claudeActions).where(and(eq(claudeActions.id, actionId), eq(claudeActions.userId, u.id), eq(claudeActions.studioId, u.studioId)));
  if (!r) throw notFound('Action');
  if (r.status !== 'waiting') throw new ApiError(409, 'already_answered', `This was already ${r.status}`);
  const now = Date.now();
  if (r.expiresAt < now) { await ctx.db.update(claudeActions).set({ status: 'expired', updatedAt: now }).where(eq(claudeActions.id, r.id)); throw new ApiError(410, 'expired', 'This request expired · ask Claude again'); }
  // Claim it first so a double press runs it once.
  const [claimed] = await ctx.db.update(claudeActions).set({ status: b.approve ? 'running' : 'declined', updatedAt: now })
    .where(and(eq(claudeActions.id, r.id), eq(claudeActions.status, 'waiting'))).returning();
  if (!claimed) throw new ApiError(409, 'already_answered', 'This was already answered');
  const line = async (text: string, ui: Record<string, unknown>) => { if (r.chatId) await uiLine(ctx, u, r.chatId, 'approve_result', text, ui).catch(() => undefined); };
  if (!b.approve) { await line(`Declined: ${r.summary}`, { action: r.id, status: 'declined' }); return actionView(claimed); }
  const c = r.call as { method: Method; url: string; body: unknown };
  try {
    const res = await appCall(ctx, u, c.method, c.url, c.body ?? undefined);
    const [done] = await ctx.db.update(claudeActions).set({ status: 'done', result: (slim(res, 10) ?? null) as never, updatedAt: Date.now() }).where(eq(claudeActions.id, r.id)).returning();
    await line(`Done: ${r.summary}`, { action: r.id, status: 'done' });
    return actionView(done!);
  } catch (e) {
    const msg = e instanceof ApiError ? `${e.code}: ${e.message}` : 'server_error';
    const [failed] = await ctx.db.update(claudeActions).set({ status: 'failed', error: msg.slice(0, 500), updatedAt: Date.now() }).where(eq(claudeActions.id, r.id)).returning();
    await line(`Didn't work: ${r.summary} (${msg.slice(0, 200)})`, { action: r.id, status: 'failed' });
    return actionView(failed!);
  }
}

export async function registerActionRoutes(app: FastifyInstance, ctx: Ctx) {
  // The person's own waiting (or recent) actions: the app shows the cards from here after a restart.
  app.get('/v1/claude/actions', async req => {
    const q = parse(z.object({ status: z.enum(['waiting', 'running', 'done', 'failed', 'declined', 'expired']).optional() }).strict(), req.query ?? {});
    await ctx.db.update(claudeActions).set({ status: 'expired', updatedAt: Date.now() }).where(and(eq(claudeActions.userId, req.user.id), eq(claudeActions.status, 'waiting'), lt(claudeActions.expiresAt, Date.now())));
    const rows = await ctx.db.select().from(claudeActions).where(and(eq(claudeActions.userId, req.user.id), q.status ? eq(claudeActions.status, q.status) : undefined)).orderBy(desc(claudeActions.createdAt)).limit(50);
    return { actions: rows.map(actionView) };
  });
  app.post<{ Params: { id: string } }>('/v1/claude/actions/:id', async req => answerAction(ctx, req.user, req.params.id, req.body));
}

/** What Claude can ask to do (each mirrors a screen's button). */
export const ACTION_TOOLS: GatedTool[] = [
  gated({ name: 'take_discard', title: 'Discard a take', scope: 'edit:write', gate: 'delete',
    description: 'Deletes a take or edited version from the Library for good (as Discard on its screen). Needs the person\'s go-ahead.',
    props: { takeId: str('The take', 80) }, required: ['takeId'],
    plan: async (env, a) => {
      const t = await appCall(env.ctx, env.user, 'GET', '/v1/takes').then((rows: { id: string; title?: string; name?: string }[]) => rows.find(x => x.id === a.takeId));
      if (!t) throw notFound('Take');
      return { summary: `Delete “${t.name ?? t.title ?? t.id}” from the Library`, method: 'DELETE', url: `/v1/takes/${enc(id(a.takeId, 'takeId'))}` };
    } }),
  gated({ name: 'collection_delete', title: 'Delete a Library collection', scope: 'edit:write', gate: 'delete',
    description: 'Deletes a Library collection (its takes stay in the Library). Needs the person\'s go-ahead.',
    props: { collectionId: str('The collection', 80) }, required: ['collectionId'],
    plan: async (env, a) => {
      const c = await appCall(env.ctx, env.user, 'GET', `/v1/library/collections/${enc(id(a.collectionId, 'collectionId'))}`);
      return { summary: `Delete the collection “${c?.name ?? a.collectionId}” (its takes stay)`, method: 'DELETE', url: `/v1/library/collections/${enc(a.collectionId as string)}` };
    } }),
  gated({ name: 'outfit_delete', title: 'Delete an outfit', scope: 'edit:write', gate: 'delete',
    description: 'Deletes an outfit and its pictures (as Delete on the outfit page). Needs the person\'s go-ahead.',
    props: { outfitId: str('The outfit', 80) }, required: ['outfitId'],
    plan: async (env, a) => {
      const o = (await appCall(env.ctx, env.user, 'GET', '/v1/outfits') as { id: string; name?: string }[]).find(x => x.id === a.outfitId);
      if (!o) throw notFound('Outfit');
      return { summary: `Delete the outfit “${o.name ?? o.id}”`, method: 'DELETE', url: `/v1/outfits/${enc(id(a.outfitId, 'outfitId'))}` };
    } }),
  gated({ name: 'queue_cancel', title: 'Cancel a job', scope: 'edit:write', gate: 'delete',
    description: 'Cancels a running or waiting generation job (or removes a finished one from the Queue), as on the Queue screen. Use queue_list for ids. Needs the person\'s go-ahead.',
    props: { jobId: str('The job', 80) }, required: ['jobId'],
    plan: async (env, a) => {
      const jobs = await appCall(env.ctx, env.user, 'GET', '/v1/jobs');
      const j = ((Array.isArray(jobs) ? jobs : jobs?.jobs ?? []) as { id: string; title?: string; status?: string }[]).find(x => x.id === a.jobId);
      if (!j) throw notFound('Job');
      return { summary: `Cancel the job “${j.title ?? j.id}” (${j.status ?? 'unknown'})`, method: 'DELETE', url: `/v1/jobs/${enc(id(a.jobId, 'jobId'))}` };
    } }),
  gated({ name: 'suite_queue_remove', title: 'Remove a queued shot', scope: 'edit:write', gate: 'delete',
    description: 'Removes an AI Suite shot from the run-later queue (queue_list shows them). Needs the person\'s go-ahead.',
    props: { queuedId: str('The queued shot', 80) }, required: ['queuedId'],
    plan: async (_env, a) => ({ summary: 'Remove a queued AI Suite shot', method: 'DELETE', url: `/v1/suite/queue/${enc(id(a.queuedId, 'queuedId'))}` }) }),
  gated({ name: 'suite_queue_run', title: 'Run a queued shot', scope: 'edit:write', gate: 'spend',
    description: 'Runs an AI Suite shot from the run-later queue. Paid: without confirm it gives the price; with confirm: true the person approves it in the app.',
    props: { queuedId: str('The queued shot', 80) }, required: ['queuedId'],
    plan: async (env, a) => {
      const q = enc(id(a.queuedId, 'queuedId'));
      const e = await appCall(env.ctx, env.user, 'POST', `/v1/suite/queue/${q}/estimate`, {});
      return { summary: 'Run a queued AI Suite shot', method: 'POST', url: `/v1/suite/queue/${q}/run`, body: {}, priceUsd: priceOf(e) };
    } }),
  gated({ name: 'post_cancel', title: 'Cancel a scheduled post', scope: 'edit:write', gate: 'delete',
    description: 'Cancels a scheduled social post (posts_list for ids). Needs the person\'s go-ahead.',
    props: { postId: str('The post', 80) }, required: ['postId'],
    plan: async (_env, a) => ({ summary: 'Cancel a scheduled post', method: 'DELETE', url: `/v1/posts/${enc(id(a.postId, 'postId'))}` }) }),
  gated({ name: 'post_schedule', title: 'Post or schedule a take', scope: 'edit:write', gate: 'post',
    description: 'Posts a take to the character\'s connected accounts, now or at a time (ISO date-time in when), with a caption and hashtags, as on the Posts screen. Write the caption yourself when asked. Needs the person\'s go-ahead.',
    props: { modelId: str('The character whose accounts post it', 80), takeId: str('The take to post', 80),
      platforms: { type: 'array', items: { type: 'string', maxLength: 20 }, maxItems: 6, description: 'Which connected accounts (e.g. tiktok, instagram)' },
      caption: str('Caption with hashtags', 2200), when: str('ISO date-time; leave out to post now', 40), aiLabel: { type: 'boolean', description: 'Mark it as AI-generated on the platform' } },
    required: ['modelId', 'takeId', 'platforms'],
    plan: async (_env, a) => {
      const platforms = Array.isArray(a.platforms) ? a.platforms.filter((p): p is string => typeof p === 'string') : [];
      if (!platforms.length) throw badRequest('platforms: at least one connected account');
      const body = compact({ modelId: id(a.modelId, 'modelId'), takeId: id(a.takeId, 'takeId'), platforms, caption: typeof a.caption === 'string' ? a.caption : undefined,
        when: typeof a.when === 'string' ? a.when : undefined, aiLabel: typeof a.aiLabel === 'boolean' ? a.aiLabel : undefined });
      return { summary: `${body.when ? `Schedule for ${body.when}` : 'Post now'} on ${platforms.join(', ')}${body.caption ? `: “${String(body.caption).slice(0, 80)}”` : ''}`, method: 'POST', url: '/v1/posts', body };
    } }),
  gated({ name: 'character_dress_up', title: 'Dress up a character', scope: 'edit:write', gate: 'spend',
    description: 'Dress up (as on the character page): new pictures of the character in a look. options are the Dress up screen\'s choices (the estimate tells you what is missing). Paid: without confirm it gives the price.',
    props: { modelId: str('The character', 80), options: { type: 'object', description: 'The Dress up choices, as the screen sends them' } }, required: ['modelId'],
    plan: async (env, a) => {
      const m = enc(id(a.modelId, 'modelId')), body = (a.options && typeof a.options === 'object' ? a.options : {}) as object;
      const e = await appCall(env.ctx, env.user, 'POST', `/v1/models/${m}/dress-up/estimate`, body);
      return { summary: 'Dress up the character', method: 'POST', url: `/v1/models/${m}/dress-up`, body, priceUsd: priceOf(e) };
    } }),
  gated({ name: 'character_enhance', title: 'Enhance a character\'s pictures', scope: 'edit:write', gate: 'spend',
    description: 'Enhance (as on the character page): sharper, cleaner sheet pictures. options are the Enhance screen\'s choices. Paid: without confirm it gives the price.',
    props: { modelId: str('The character', 80), options: { type: 'object', description: 'The Enhance choices, as the screen sends them' } }, required: ['modelId'],
    plan: async (env, a) => {
      const m = enc(id(a.modelId, 'modelId')), body = (a.options && typeof a.options === 'object' ? a.options : {}) as object;
      const e = await appCall(env.ctx, env.user, 'POST', `/v1/models/${m}/enhance/estimate`, body);
      return { summary: 'Enhance the character\'s pictures', method: 'POST', url: `/v1/models/${m}/enhance`, body, priceUsd: priceOf(e) };
    } }),
  // B3: paid makes, priced by the screen's own route with dryRun: true (nothing held or made).
  gated({ name: 'character_fill_angles', title: 'Fill a character\'s missing angles', scope: 'edit:write', gate: 'spend',
    description: 'Makes the character sheet\'s missing angles from her identity pictures (as Fill missing angles on her page). Paid: without confirm it gives the price and the angles.',
    props: { modelId: str('The character', 80) }, required: ['modelId'],
    plan: async (env, a) => {
      const m = enc(id(a.modelId, 'modelId'));
      const e = await appCall(env.ctx, env.user, 'POST', `/v1/models/${m}/fill-angles`, { dryRun: true });
      const angles = Array.isArray(e?.angles) ? e.angles as string[] : [];
      if (!angles.length) throw new ApiError(409, 'nothing_missing', 'Her sheet has no missing angles');
      return { summary: `Fill ${angles.length} missing angle${angles.length === 1 ? '' : 's'} (${angles.join(', ')})`, method: 'POST', url: `/v1/models/${m}/fill-angles`, body: {}, priceUsd: priceOf(e) };
    } }),
  gated({ name: 'outfit_fill', title: 'Fill an outfit\'s missing angles', scope: 'edit:write', gate: 'spend',
    description: 'Makes an outfit\'s missing ¾, side and back pictures from its front (as on the outfit page). Paid: without confirm it gives the price.',
    props: { outfitId: str('The outfit', 80) }, required: ['outfitId'],
    plan: async (env, a) => {
      const o = enc(id(a.outfitId, 'outfitId'));
      const e = await appCall(env.ctx, env.user, 'POST', `/v1/outfits/${o}/fill`, { dryRun: true });
      if (!e?.dryRun) throw new ApiError(409, 'nothing_missing', 'This outfit has all its angles');
      return { summary: `Make ${e.angles} missing outfit angle${e.angles === 1 ? '' : 's'}`, method: 'POST', url: `/v1/outfits/${o}/fill`, body: {}, priceUsd: priceOf(e) };
    } }),
  gated({ name: 'outfit_make', title: 'Make a new outfit', scope: 'edit:write', gate: 'spend',
    description: 'Makes a new outfit for a character (4 pictures: front, ¾, side, back), as the Outfits sheet does: mode describe (from the description), photo (from product photos in images) or own. Name it. Paid: without confirm it gives the price.',
    props: { modelId: str('The character', 80), name: str('The outfit\'s name', 80), mode: { type: 'string', enum: ['describe', 'photo', 'own'] },
      description: str('What she wears', 1000), images: { type: 'array', maxItems: 4, description: 'Product photos (image refs from the Library or uploads)' } },
    required: ['modelId', 'name'],
    plan: async (env, a) => {
      const body = compact({ modelId: id(a.modelId, 'modelId'), name: typeof a.name === 'string' ? a.name : undefined, mode: typeof a.mode === 'string' ? a.mode : undefined,
        description: typeof a.description === 'string' ? a.description : undefined, images: Array.isArray(a.images) ? a.images : undefined });
      const e = await appCall(env.ctx, env.user, 'POST', '/v1/outfits', { ...body, dryRun: true });
      return { summary: `Make the outfit “${body.name}”`, method: 'POST', url: '/v1/outfits', body, priceUsd: priceOf(e) };
    } }),
  gated({ name: 'take_upscale', title: 'Upscale a take', scope: 'edit:write', gate: 'spend',
    description: 'Upscales a finished video take to 1080p, 2k or 4k (as Upscale in the AI Suite); the result arrives as a new take. Paid: without confirm it gives the price.',
    props: { takeId: str('The take', 80), size: { type: 'string', enum: ['1080p', '2k', '4k'] } }, required: ['takeId', 'size'],
    plan: async (env, a) => {
      const t = enc(id(a.takeId, 'takeId'));
      const e = await appCall(env.ctx, env.user, 'POST', `/v1/takes/${t}/upscale`, { size: a.size, dryRun: true });
      return { summary: `Upscale the take to ${String(a.size)}`, method: 'POST', url: `/v1/takes/${t}/upscale`, body: { size: a.size }, priceUsd: priceOf(e) };
    } }),
  gated({ name: 'queue_run', title: 'Run the queue', scope: 'edit:write', gate: 'spend',
    description: 'Starts every queued generation job, as Run queue on Home/Queue. Paid: without confirm it lists them with the total.',
    props: {}, required: [],
    plan: async env => {
      const jobs = await appCall(env.ctx, env.user, 'GET', '/v1/jobs');
      const q = ((Array.isArray(jobs) ? jobs : jobs?.jobs ?? []) as { state?: string; status?: string; kind?: string; cost?: number; estimate?: number }[])
        .filter(j => (j.state ?? j.status) === 'queued' && (j.kind ?? 'render') === 'render');
      if (!q.length) throw new ApiError(409, 'queue_empty', 'Nothing is queued');
      const total = q.reduce((s, j) => s + (typeof j.cost === 'number' ? j.cost : typeof j.estimate === 'number' ? j.estimate : 0), 0);
      return { summary: `Run ${q.length} queued job${q.length === 1 ? '' : 's'}`, method: 'POST', url: '/v1/queue/run', body: {}, priceUsd: total || null };
    } }),
];

/** Studio settings Claude may read and (with the owner's go-ahead) change. Never keys, providers or prices. */
const SETTINGS: Record<string, { name: string; path: string; method: 'PATCH' }> = {
  studio: { name: 'Studio limits', path: '/v1/settings/studio', method: 'PATCH' },
  image_engine: { name: 'Image engine', path: '/v1/settings/image-engine', method: 'PATCH' },
  editor: { name: 'Editor paid helpers', path: '/v1/editor/settings', method: 'PATCH' },
  recreate: { name: 'Recreate', path: '/v1/recreate/settings', method: 'PATCH' },
  suite_models: { name: 'AI Suite models on/off', path: '/v1/suite/settings', method: 'PATCH' },
  engine_defaults: { name: 'Default models', path: '/v1/engines/defaults', method: 'PATCH' },
  members_models: { name: 'Models members see', path: '/v1/engines/members', method: 'PATCH' },
};
const AREA = { type: 'string', enum: Object.keys(SETTINGS) };
const area = (v: unknown) => { if (typeof v !== 'string' || !SETTINGS[v]) throw badRequest(`area: one of ${Object.keys(SETTINGS).join(', ')}`); return SETTINGS[v]!; };

/** Owner only (the registry hides them from members). */
export const SETTINGS_TOOLS: EditTool[] = [
  { name: 'settings_read', title: 'Read studio settings (owner)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: `The studio's settings in one area: ${Object.entries(SETTINGS).map(([k, v]) => `${k} (${v.name})`).join(', ')}. Keys, providers and prices are never shown or changed through Claude: the owner does those in Settings.`,
    inputSchema: { type: 'object', additionalProperties: false, required: ['area'], properties: { area: AREA } },
    run: async (env, a) => slim(await appCall(env.ctx, env.user, 'GET', area(a.area).path), 60) },
  gated({ name: 'settings_change', title: 'Change studio settings (owner)', scope: 'edit:write', gate: 'settings',
    description: 'Changes studio settings in one area (read them first with settings_read and send only the fields to change, as the Settings screen does). Needs the owner\'s go-ahead; never keys, providers or prices.',
    props: { area: AREA, changes: { type: 'object', description: 'The fields to change, as the Settings screen sends them' } }, required: ['area', 'changes'],
    plan: async (env, a) => {
      const s = area(a.area);
      if (!a.changes || typeof a.changes !== 'object' || Array.isArray(a.changes) || !Object.keys(a.changes).length) throw badRequest('changes: the fields to change');
      if (/key|secret|token|price|markup|provider/i.test(Object.keys(a.changes).join(' '))) throw new ApiError(403, 'not_through_claude', 'Keys, providers and prices are changed by the owner in Settings, never through Claude');
      const now = await appCall(env.ctx, env.user, 'GET', s.path).catch(() => ({}));
      const diff = Object.entries(a.changes as Record<string, unknown>).map(([k, v]) => `${k}: ${JSON.stringify((now as Record<string, unknown>)?.[k] ?? null)} → ${JSON.stringify(v)}`).join('; ');
      return { summary: `Change ${s.name}: ${diff.slice(0, 300)}`, method: s.method, url: s.path, body: a.changes };
    } }),
];
