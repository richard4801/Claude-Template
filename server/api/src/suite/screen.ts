// Claude sees what is on screen (owner, 2026-11-11: "Claude still can't see clips added to swap or anywhere"). The app
// mirrors its open composer into the shared draft (suite/assist.ts) on every page: Shot, Photo, Talking, UGC, Swap,
// Recast, Extend and camera-session Shot drafts. Besides the prompt chips and rig, the draft now carries `screen`:
//   request: what Generate would send right now, exactly as the app builds it (Swap's clipId, Recast's cast, Extend's
//            video, the frames and references in the slots, a Directed camera with its guides, the pinned model);
//   inputs:  every input on screen in words, each with the id Claude watches or sees it by (a clip attached by link,
//            an uploaded swap source, a guide clip, a reference picture, a Library still, a chat attachment).
// One source of truth: requestOf (assist.ts) takes the media from `screen.request` and everything Claude can set
// (the @model, prompt, rig, bar) from the draft, so Claude's view and the app's Generate send the same request.
// resolveAssist: every Suite tool reaches the draft on screen whatever id it is given (sa_ shared draft, sd_ camera
// Shot draft, cs_ camera session) or, with none, the chat's page (else the person's latest chat).
import { and, desc, eq, sql } from 'drizzle-orm';
import { z } from 'zod';
import type { AuthUser, Ctx } from '../ctx.js';
import { ApiError, notFound } from '../errors.js';
import { cameraSessions, claudeThreads } from '../camera/schema.js';
import { pageOfContext, type PageRef } from '../claude/page.js';
import { models } from '../db/schema.js';
import { suiteAssists } from './schema.js';
import { TOOLS, type Draft } from './drafts.js';

const ID = z.string().regex(/^[A-Za-z0-9_-]{1,80}$/);
export const SCREEN_KINDS = ['video', 'image', 'audio'] as const;

/** One input on screen. Any of the ids may be given; the first that names stored media is what Claude watches/sees. */
export const ScreenInputSchema = z.object({
  /** Where it sits: "swap.clip", "recast.clip", "extend.video", "start", "middle 1", "end", "reference 2", "video 1", "audio", "guide", "chat". */
  slot: z.string().trim().min(1).max(40),
  kind: z.enum(SCREEN_KINDS),
  label: z.string().trim().max(120).optional(),
  /** References: product | location | style | prop | person | pose | outfit. Videos: motion | camera | style | blocking. */
  role: z.string().max(20).optional(),
  clipId: ID.optional(), uploadId: ID.optional(), takeId: ID.optional(), cameraSessionId: ID.optional(),
  /** A stored object (as the request names it) or a studio link (/uploads/…). */
  key: z.string().max(300).optional(), url: z.string().max(2000).optional(),
  /** The page a clip was imported from (attached by link). */
  link: z.string().max(2000).optional(),
  seconds: z.number().min(0).max(3600).optional(),
  /** Not ready yet: still uploading or importing, or failed. */
  state: z.enum(['ready', 'uploading', 'importing', 'failed']).optional(),
}).strict();
export type ScreenInput = z.infer<typeof ScreenInputSchema>;

export const ScreenSchema = z.object({
  tool: z.enum(TOOLS).optional(),
  /** What Generate would send now (the app's own ShotRequest, Photo request …). Checked when it runs, not here. */
  request: z.record(z.string(), z.unknown()).optional(),
  inputs: z.array(z.unknown()).max(24).optional(),
  /** When the app read the screen (ms). */
  at: z.number().optional(),
}).passthrough();
export type Screen = { tool?: (typeof TOOLS)[number]; request?: Record<string, unknown>; inputs?: ScreenInput[]; at?: number; dropped?: number };

/** The draft's screen, checked leniently: a bad input is left out (and counted) rather than refusing the whole sync. */
export function screenOf(d: Draft | Record<string, unknown> | null | undefined): Screen | null {
  const raw = (d as { screen?: unknown } | null | undefined)?.screen;
  if (raw == null) return null;
  const p = ScreenSchema.safeParse(raw);
  if (!p.success) return null;
  const inputs: ScreenInput[] = [];
  let dropped = 0;
  for (const x of p.data.inputs ?? []) { const i = ScreenInputSchema.safeParse(x); if (i.success) inputs.push(i.data); else dropped++; }
  return { ...(p.data.tool ? { tool: p.data.tool } : {}), ...(p.data.request ? { request: p.data.request } : {}), inputs,
    ...(typeof p.data.at === 'number' ? { at: p.data.at } : {}), ...(dropped ? { dropped } : {}) };
}

/** Request fields that are media on screen: the app's are the truth (Claude can't set them except references/sent). */
const MEDIA = ['mode', 'clipId', 'keepAudio', 'cast', 'extend', 'frames', 'direction'] as const;
/** Fields Claude sets in the draft; the screen's are used only when the draft has none (Swap's character lives there). */
const FALLBACK = ['modelId', 'outfitId', 'engineModel', 'resolution'] as const;

type Req = Record<string, unknown> & { references?: { images?: unknown[]; videos?: unknown[]; audio?: unknown } };

/**
 * The request with what is on screen: the media fields from the app's request, its slot references merged before the
 * chat references, a Directed camera (with guides) when the draft hasn't set one, and Swap/Recast's own character.
 */
export function withScreen<T extends Record<string, unknown>>(req: T, d: Draft): T {
  const s = screenOf(d)?.request;
  if (!s) return req;
  const out = { ...req } as Req;
  for (const k of MEDIA) if (s[k] !== undefined) out[k] = s[k];
  for (const k of FALLBACK) if (out[k] === undefined && s[k] !== undefined) out[k] = s[k];
  // Swap / Recast / Extend: the bar's values live in their own panel on the app.
  const tool = (d as { tool?: string }).tool;
  if (tool === 'swap' || tool === 'recast' || tool === 'extend') for (const k of ['quality', 'takes', 'audio'] as const) if (s[k] !== undefined) out[k] = s[k];
  // A Directed camera picked on screen (the Rig's Movement → Directed, guides from Blender) unless Claude set its own.
  const cam = s.camera as { mode?: string } | undefined;
  if (cam?.mode === 'directed' && !(d as { directed?: unknown }).directed) out.camera = cam;
  else if (cam && !out.camera && (tool === 'swap' || tool === 'recast')) out.camera = cam; // Swap's Look chip
  const sr = s.references as Req['references'] | undefined;
  if (sr) {
    const chat = out.references?.images ?? [];
    const images = [...(sr.images ?? []), ...chat].slice(0, 6);
    out.references = { ...(images.length ? { images } : {}), ...(sr.videos?.length ? { videos: sr.videos } : {}), ...(sr.audio ? { audio: sr.audio } : {}) };
  }
  return out as T;
}

/** The id Claude passes to watch for a video on screen, or undefined (not stored yet). */
const watchId = (i: ScreenInput) => i.clipId ?? i.takeId ?? i.uploadId ?? i.cameraSessionId ?? (i.key ? `/uploads/${i.key.replace(/^\/?uploads\//, '')}` : i.url && /\/uploads\//.test(i.url) ? i.url : undefined);

/** Claude's view of the screen: each input in words with how to look at it. */
export function onScreen(d: Draft) {
  const s = screenOf(d);
  if (!s) return { synced: false, note: 'The app has not sent its screen for this draft (an older MUSE app): inputs on screen (clips, guides, slot images) are not visible here. Ask the person to update MUSE; ui_snapshot shows the window.' };
  const inputs = (s.inputs ?? []).map((i, n) => {
    const ready = !i.state || i.state === 'ready';
    const how = !ready ? { notReady: i.state }
      : i.kind === 'video' ? (watchId(i) ? { watch: watchId(i) } : { notStored: true })
      : i.kind === 'image' ? { see: `suite_see {input: ${n}}` }
      : {};
    return { input: n, slot: i.slot, kind: i.kind, ...(i.label ? { label: i.label } : {}), ...(i.role ? { role: i.role } : {}), ...(i.link ? { link: i.link } : {}),
      ...(i.seconds ? { seconds: i.seconds } : {}), ...how };
  });
  return { synced: true, tool: s.tool ?? (d as { tool?: string }).tool, ...(s.at ? { at: s.at } : {}), inputs, ...(s.dropped ? { unreadable: s.dropped } : {}),
    note: 'What the composer on screen holds. Watch each video (watch {id}) and see each image (suite_see {input}) before you write about it.' };
}

// ------------------------------------------------------------------------------------------------ which draft

/** `page`: the page the app shows now (the in-app chat passes it); it wins over the chat's stored page. */
type Env = { ctx: Ctx; user: AuthUser; page?: PageRef };

/** A camera session of this owner (camera sessions are the owner's own). */
async function ownSession(ctx: Ctx, u: AuthUser, where: ReturnType<typeof eq>) {
  const [s] = await ctx.db.select().from(cameraSessions).where(and(where, eq(cameraSessions.studioId, u.studioId)));
  if (!s || s.ownerId !== u.id) return null;
  return s;
}

/** The shared draft for a camera session's Shot draft (sd_) or the session itself (cs_): made once, then the same. */
async function assistOfCamera(ctx: Ctx, u: AuthUser, s: typeof cameraSessions.$inferSelect): Promise<string> {
  const sd = s.shotDraft;
  const id = `sa_${sd?.id ?? s.id}`;
  const [have] = await ctx.db.select({ id: suiteAssists.id }).from(suiteAssists).where(and(eq(suiteAssists.id, id), eq(suiteAssists.studioId, u.studioId)));
  if (have) return id;
  const req = (sd?.request ?? {}) as Record<string, unknown>;
  const prompt = typeof req.prompt === 'string' ? req.prompt : sd?.prompt ?? s.brief ?? '';
  const modelId = typeof req.modelId === 'string' ? req.modelId : s.characters[0]?.modelId;
  const tokens: unknown[] = [];
  if (modelId) {
    const [m] = await ctx.db.select({ id: models.id, name: models.name }).from(models).where(and(eq(models.id, modelId), eq(models.studioId, u.studioId)));
    if (m) tokens.push({ t: 'mention', kind: 'character', id: m.id, label: m.name, key: 1 });
  }
  if (prompt.trim()) tokens.push({ t: 'text', text: `${tokens.length ? ' ' : ''}${prompt.trim().slice(0, 2000)}` });
  const camera = req.camera as { mode?: string; guide?: unknown } | undefined;
  const draft: Record<string, unknown> = {
    v: 1, tool: 'shot', quality: typeof req.quality === 'string' ? req.quality : 'cinema', aspect: typeof req.aspectRatio === 'string' ? req.aspectRatio : s.aspect,
    duration: typeof req.duration === 'number' ? req.duration : Math.max(2, Math.min(30, Math.round(s.durationSec))), takes: 1, sound: true, tokens,
    ...(typeof req.engineModel === 'string' ? { engineModel: req.engineModel, ...(typeof req.resolution === 'string' ? { resolution: req.resolution } : {}) } : {}),
    ...(camera?.mode === 'directed' && camera.guide ? { directed: { cameraSessionId: s.id, title: s.title, camera } } : {}),
    fromCamera: { cameraSessionId: s.id, ...(sd ? { shotDraftId: sd.id } : {}), title: s.title },
  };
  const now = Date.now();
  await ctx.db.insert(suiteAssists).values({ id, studioId: u.studioId, userId: u.id, draft, revision: 1, pending: [], createdAt: now, updatedAt: now }).onConflictDoNothing();
  return id;
}

/** A page's ids → the draft on screen (the Suite's shared draft, else a camera session's Shot draft). */
async function fromIds(ctx: Ctx, u: AuthUser, ids: Record<string, string | undefined> | undefined) {
  if (ids?.assistId) return ids.assistId;
  if (ids?.cameraSessionId) { const s = await ownSession(ctx, u, eq(cameraSessions.id, ids.cameraSessionId)); if (s) return assistOfCamera(ctx, u, s); }
  return undefined;
}

/**
 * The shared draft a Suite tool acts on: an sa_ id as given; an sd_ camera Shot draft or a cs_ camera session through
 * its own shared draft (made from the session's Shot draft: prompt, @model, Directed camera with guides, model); none:
 * the chat's page (chatId), else the person's latest chat's page.
 */
export async function resolveAssist(env: Env, a: Record<string, unknown>): Promise<string> {
  const { ctx, user: u } = env;
  const id = typeof a.assistId === 'string' ? a.assistId.trim() : '';
  if (id) {
    if (id.startsWith('sd_')) {
      const s = await ownSession(ctx, u, sql`${cameraSessions.shotDraft}->>'id' = ${id}` as never);
      if (!s) throw notFound(`Shot draft ${id}`);
      return assistOfCamera(ctx, u, s);
    }
    if (id.startsWith('cs_')) {
      const s = await ownSession(ctx, u, eq(cameraSessions.id, id));
      if (!s) throw notFound('Camera session');
      return assistOfCamera(ctx, u, s);
    }
    return id;
  }
  if (typeof a.cameraSessionId === 'string' && a.cameraSessionId) return resolveAssist(env, { assistId: a.cameraSessionId });
  if (env.page) {
    const now = await fromIds(ctx, u, env.page.ids);
    if (now) return now;
    throw new ApiError(400, 'nothing_open', 'No composer is open on this page: open the AI Suite (open_page {page:"suite"}) or pass the draft id (sa_…, a camera Shot draft sd_… or a camera session cs_…)');
  }
  const [t] = typeof a.chatId === 'string' && a.chatId
    ? await ctx.db.select().from(claudeThreads).where(and(eq(claudeThreads.id, a.chatId), eq(claudeThreads.ownerId, u.id), eq(claudeThreads.studioId, u.studioId)))
    : await ctx.db.select().from(claudeThreads).where(and(eq(claudeThreads.ownerId, u.id), eq(claudeThreads.studioId, u.studioId))).orderBy(desc(claudeThreads.updatedAt)).limit(1);
  const page: PageRef | undefined = t ? (t.page ?? pageOfContext(t.contextKind, t.contextId, t.contextKey)) : undefined;
  const got = await fromIds(ctx, u, page?.ids);
  if (got) return got;
  throw new ApiError(400, 'bad_request', 'assistId: no composer is open on the person\'s page. Open the AI Suite (open_page {page:"suite"}) or pass the draft id (sa_…, a camera Shot draft sd_… or a camera session cs_…)');
}

export const DRAFT_ID_HELP = 'The draft on screen (filled in for you). Also takes a camera session\'s Shot draft (sd_…) or a camera session (cs_…): its own shared draft, with its Directed camera, guides, prompt and model';
