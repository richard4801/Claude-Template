// Claude in the AI Suite (workstream 1, owner-approved 2026-11-08; plans/api.md "Claude in the AI Suite"): the owner
// describes a shot, Claude sets up the composer (the @model, the prompt, the rig with only the options members see,
// tool, quality, length), explains its choices, and generates only after the owner's yes (the price shown and
// approved in the app, like Recreate's fill_slot). The draft is the composer's own Reuse-settings draft, shared live:
// Claude's changes reach the app as `suiteAssist` events and the owner's own edits come back with PATCH.
import { and, desc, eq } from 'drizzle-orm';
import { type DraftDirected, directedOf } from './directed.js';
import { z } from 'zod';
import { sentOfBody, type SentInput } from '../images/sent.js';
import type { AuthUser, Ctx } from '../ctx.js';
import { clips, jobs, models } from '../db/schema.js';
import { RemixSchema, SHOT_PROMPT_CEILING } from './plan.js';
import { modelById } from './registry.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { uid } from '../lib/util.js';
import { APERTURES, BODIES, ERAS, FOCAL_STEPS, GENRES, HEIGHTS, LENSES, LIGHTING, LOOKS, MOVES, PALETTES, SHOT_SIZES, TEMPOS, UGC_FORMATS, type CameraSpecInput, type Option } from './camera.js';
import { DraftSchema, RigSchema, type Draft, type Rig } from './drafts.js';
import { rigCheck } from './rigcheck.js';
import { suiteAssists } from './schema.js';
import { normaliseImage, uploadImage } from '../camera/claudeAttachments.js';
import { putObject } from '../storage/objects.js';
import { onScreen, screenOf, withScreen } from './screen.js';
import { ImageInSchema, sentImagesOf } from '../images/sent.js';

type Row = typeof suiteAssists.$inferSelect;
export type AssistPending = { id: string; kind: 'suite_request_shot'; label: string; estimateUsd: number; maxUsd: number; breakdown?: { lines: { label: string; usd: number }[]; totalUsd: number }; status: 'waiting' | 'declined' | 'done' | 'failed'; jobId?: string; error?: string; createdAt: number };
type Token = { t: 'text'; text: string } | { t: 'move'; id: string; label: string; category: string; intensity: number; key: number } | { t: 'mention'; kind: string; id: string; label: string; key: number };

const QUALITIES = ['draft', 'standard', 'hd', 'cinema'] as const;
/** workstream 1: what an image attached in the chat is for, as a reference of the shot (its role in the request). */
export const REFERENCE_USES = ['pose', 'style', 'location', 'outfit'] as const;
export const MAX_DRAFT_REFERENCES = 3;
export type DraftReference = { uploadId: string; url: string; use: typeof REFERENCE_USES[number]; label?: string };
const DraftReferenceSchema = z.object({ uploadId: z.string().max(80), url: z.string().max(2000).regex(/\/uploads\/[a-z]+\/[A-Za-z0-9._-]+$/, 'a studio image (/uploads/…)'),
  use: z.enum(REFERENCE_USES), label: z.string().max(80).optional() }).strict();
export const AddReferenceBody = z.object({ uploadId: z.string().min(1).max(80).optional(),
  /** Any image of this studio instead of an upload: a take id (a Library still, or a video's frame with at), {takeId, at}, {url} as MUSE gives it, an outfit/character picture. */
  image: ImageInSchema.optional(), takeId: z.string().regex(/^[A-Za-z0-9_-]{1,80}$/).optional(), at: z.number().min(0).max(3600).optional(),
  use: z.enum(REFERENCE_USES), label: z.string().trim().max(80).optional(), remove: z.boolean().optional() }).strict()
  .refine(b => !!(b.uploadId || b.image || b.takeId), { message: 'uploadId, takeId or image: the picture to use' });
const ASPECTS = ['9:16', '16:9', '1:1', '4:3', '3:4', '21:9'] as const;
const PHOTO_ASPECTS = new Set(['9:16', '4:5', '3:4', '2:3', '1:1', '3:2', '4:3', '16:9']);
/** Photo's prompt limit (suite/photo.ts PhotoRequestSchema). */
export const PHOTO_PROMPT_MAX = 2000;

/**
 * The prompt limit for this draft (ci_9a79f3707f79): Photo's own; a pinned video model's registry promptMax ("Seedance
 * 2.0 takes at most 4000 characters"); else MUSE's ceiling (under Auto a model that takes less gets it shortened, and
 * the estimate's warnings name it).
 */
export function promptLimit(tool: string | undefined, engineModel?: string): { max: number; why: string } {
  if (tool === 'photo') return { max: PHOTO_PROMPT_MAX, why: `a Photo prompt takes at most ${PHOTO_PROMPT_MAX} characters` };
  const m = engineModel ? modelById(engineModel) : undefined;
  if (m?.promptMax && m.promptMax < SHOT_PROMPT_CEILING) return { max: m.promptMax, why: `${m.name} takes at most ${m.promptMax} characters` };
  return { max: SHOT_PROMPT_CEILING, why: `MUSE takes at most ${SHOT_PROMPT_CEILING} characters` };
}

// ------------------------------------------------------------------ start / end frames (ci_91473102d2b0)
/** A frame Claude put in the Shot's start or end slot: the studio picture, what it is, and the slot's own picture
 *  (on screen) when Claude set it, so a picture the person puts in that slot afterwards wins. */
export type DraftFrame = { url: string; label: string; over: string | null };
const ID_RE = /^[A-Za-z0-9_-]{1,80}$/;
export const FrameInSchema = z.object({
  takeId: z.string().regex(ID_RE).optional(),
  /** Seconds into a video take, or its first / last frame (chaining clips: the next starts on the last frame). */
  at: z.union([z.number().min(0).max(3600), z.enum(['first', 'last'])]).optional(),
  uploadId: z.string().regex(ID_RE).optional(),
  image: ImageInSchema.optional(),
  label: z.string().trim().max(80).optional(),
}).strict().refine(f => [f.takeId, f.uploadId, f.image].filter(Boolean).length === 1, { message: 'one of takeId (with at), uploadId or image' });
const DraftFrameSchema = z.object({ url: z.string().max(2000).regex(/\/uploads\/[a-z]+\/[A-Za-z0-9._-]+$/), label: z.string().max(120), over: z.string().max(2000).nullable() }).strict();
/** The draft's frames Claude set, only well-formed ones. */
export function framesOf(d: Draft): { start?: DraftFrame; end?: DraftFrame } {
  const raw = (d as { frames?: { start?: unknown; end?: unknown } }).frames;
  if (!raw || typeof raw !== 'object') return {};
  const out: { start?: DraftFrame; end?: DraftFrame } = {};
  for (const k of ['start', 'end'] as const) { const p = DraftFrameSchema.safeParse(raw[k]); if (p.success) out[k] = p.data; }
  return out;
}
/** A slot's picture as a comparable string (its link or asset), or null. */
export const frameKey = (x: unknown) => { const o = x as { url?: unknown; asset?: unknown } | null | undefined; return typeof o?.url === 'string' ? o.url.replace(/^.*(\/uploads\/)/, '$1') : typeof o?.asset === 'string' ? `asset:${o.asset}` : null; };

// ------------------------------------------------------------------ what members see (Claude picks only these)
/** The rig's option lists by draft field, and the composer's visible subset (merged duplicates and hidden ones left out). */
const LISTS: Record<string, Option[]> = { body: BODIES, lens: LENSES, aperture: APERTURES, height: HEIGHTS, shotSize: SHOT_SIZES, lighting: LIGHTING,
  palette: PALETTES, stock: LOOKS, genre: GENRES, era: ERAS, tempo: TEMPOS, format: UGC_FORMATS };
const visible = (l: Option[]) => l.filter(o => o.visible !== false && !o.mergedInto);
/** suite_options: every visible choice with its label and what it does, so Claude never picks a hidden one (f/4 …). */
export function suiteOptions() {
  const pick = (l: Option[]) => visible(l).map(o => ({ id: o.id, label: o.label, description: o.description }));
  return {
    camera: { body: pick(BODIES), lens: pick(LENSES), focalMm: FOCAL_STEPS.map(f => ({ mm: f.mm, label: f.label, description: f.description })), aperture: pick(APERTURES),
      height: pick(HEIGHTS), shotSize: pick(SHOT_SIZES) },
    look: { palette: pick(PALETTES), stock: pick(LOOKS), gradeLook: 'true (default): the take is graded with the Look; false: only described' },
    lighting: pick(LIGHTING),
    style: { genre: pick(GENRES), era: pick(ERAS), tempo: pick(TEMPOS), format: pick(UGC_FORMATS) },
    moves: MOVES.map(m => ({ id: m.id, label: m.label, description: m.description, category: m.category })),
    moveRules: 'At most 2 moves; a second must be a different kind (never with static, time or aerial moves). Intensity 0–1 (default 0.5).',
    bar: { tool: 'the composer\'s own (the draft keeps it; suite_request_shot only for shot)', count: 'Photo: 1–4 stills', quality: [...QUALITIES], aspect: [...ASPECTS], duration: '2–30 s (whole seconds)', takes: '1–4', sound: 'true = native sound where the model makes it' },
    notes: 'Leave a row out for Auto. Only these ids are accepted.',
  };
}
/** A rig with only visible choices, or a 400 naming the visible ones. */
export function checkVisibleRig(rig: Rig): Rig {
  for (const [k, list] of Object.entries(LISTS)) {
    const v = (rig as Record<string, unknown>)[k];
    if (v === undefined) continue;
    if (!visible(list).some(o => o.id === v)) throw badRequest(`rig.${k}: "${v}" isn't offered · one of ${visible(list).map(o => o.id).join(', ')}`);
  }
  if (rig.focalMm !== undefined && !FOCAL_STEPS.some(f => f.mm === rig.focalMm)) throw badRequest(`rig.focalMm: ${rig.focalMm} isn't offered · one of ${FOCAL_STEPS.map(f => f.mm).join(', ')}`);
  return rig;
}

// ------------------------------------------------------------------ draft ↔ shot request (as the composers do)
const tokensOf = (d: Draft) => ((d as { tokens?: unknown }).tokens as Token[] | undefined) ?? [];
/** The prompt the server gets: mentions as their names, #moves left out (they go in camera.move / mix). */
export function promptText(tokens: Token[]) {
  const raw = tokens.map(p => (p.t === 'text' ? p.text : p.t === 'mention' ? ` ${p.label} ` : ' ')).join('');
  return raw.replace(/\s+/g, ' ').replace(/ ([,.!?;:])/g, '$1').trim();
}
/** The request's camera: only non-Auto rows plus the prompt's #moves (first = move, second = mix); undefined when all Auto. */
export function cameraOf(rig: Rig, moves: { id: string; intensity: number }[]): CameraSpecInput | undefined {
  const r = { ...(rig.body ? { body: rig.body } : {}), ...(rig.lens ? { lens: rig.lens } : {}), ...(rig.focalMm ? { focalMm: rig.focalMm } : {}),
    ...(rig.aperture ? { aperture: rig.aperture } : {}), ...(rig.stock ? { look: rig.stock } : {}) };
  const angle = { ...(rig.height ? { height: rig.height } : {}), ...(rig.shotSize ? { shotSize: rig.shotSize } : {}) };
  const style = { ...(rig.genre ? { genre: rig.genre } : {}), ...(rig.era ? { era: rig.era } : {}), ...(rig.tempo ? { tempo: rig.tempo } : {}), ...(rig.format ? { format: rig.format } : {}) };
  const spec: Record<string, unknown> = { mode: 'preset',
    ...(Object.keys(r).length ? { rig: r } : {}), ...(rig.lighting ? { lighting: { preset: rig.lighting } } : {}), ...(rig.palette ? { palette: { preset: rig.palette } } : {}),
    ...(moves[0] ? { move: moves[0] } : {}), ...(moves[1] ? { mix: moves[1] } : {}),
    ...(Object.keys(angle).length ? { angle } : {}), ...(Object.keys(style).length ? { style } : {}) };
  return Object.keys(spec).length > 1 ? spec as CameraSpecInput : undefined;
}
/** What Generate sends for this draft (POST /v1/suite/shots), the draft included for Reuse settings. */
export function requestOf(d: Draft): ShotRequestOf & { mode?: string; clipId?: string; keepAudio?: boolean } {
  return d.tool === 'remix' ? remixRequestOf(d) as unknown as ShotRequestOf : shotRequestOf(d);
}
type ShotRequestOf = ReturnType<typeof shotRequestOf>;
function shotRequestOf(d: Draft) {
  const toks = tokensOf(d), rig = (d.rig ?? {}) as Rig;
  const mention = (k: string) => toks.find((x): x is Extract<Token, { t: 'mention' }> => x.t === 'mention' && x.kind === k)?.id;
  const moves = toks.filter((x): x is Extract<Token, { t: 'move' }> => x.t === 'move').map(m => ({ id: m.id, intensity: Math.round(m.intensity) / 100 }));
  const extra = d as Record<string, unknown>;
  // Directed (a camera session's camera and guides) replaces the chips' camera, as in the composer.
  const directed = (extra.directed as DraftDirected | undefined)?.camera;
  const camera = directed ?? cameraOf(rig, moves);
  return withFrames(withScreen({
    ...(mention('character') ? { modelId: mention('character') } : {}),
    ...((mention('outfit') ?? extra.outfitId) ? { outfitId: (mention('outfit') ?? extra.outfitId) as string } : {}),
    prompt: promptText(toks), duration: Math.round(d.duration ?? 5), aspectRatio: d.aspect ?? '9:16', quality: d.quality ?? 'draft', takes: d.takes ?? 1,
    ...(d.sound !== undefined ? { audio: !!d.sound } : {}), ...(typeof extra.speaking === 'boolean' ? { speaking: extra.speaking } : {}),
    ...(camera ? { camera } : {}),
    ...(typeof extra.engineModel === 'string' ? { engineModel: extra.engineModel, ...(typeof extra.resolution === 'string' ? { resolution: extra.resolution } : {}) } : {}),
    ...(rig.gradeLook === false && (rig.palette || rig.stock) ? { gradeLook: false } : {}),
    // Claude's background (keep included, so its Keep wins over the screen's); none set: the screen's (screen.ts FALLBACK).
    ...(extra.background === 'keep' || extra.background === 'photo' || extra.background === 'describe' ? { background: extra.background as 'keep' | 'photo' | 'describe' } : {}),
    ...(referencesOf(d).length ? { references: { images: referencesOf(d).map(r => ({ image: { url: r.url }, role: r.use, label: r.label ?? r.use })) } } : {}),
    // Images sent (images/sent.ts): Claude's or the person's choice, kept in the draft (set_sent_images).
    ...sentOfDraft(d),
    draft: d,
  }, d), d);
}
/**
 * Claude's start / end frames in the request's frame slots (the ones the apps fill). A slot the person changed on screen
 * after Claude set it keeps the person's picture.
 */
function withFrames<T extends Record<string, unknown>>(req: T, d: Draft): T {
  const mine = framesOf(d);
  if (!mine.start && !mine.end) return req;
  const on = (screenOf(d)?.request?.frames ?? {}) as Record<string, unknown>;
  const frames = { ...((req.frames ?? {}) as Record<string, unknown>) };
  for (const k of ['start', 'end'] as const) { const f = mine[k]; if (f && frameKey(on[k]) === f.over) frames[k] = { url: f.url }; }
  return { ...req, frames };
}

/** Photo (ci_40e89e2a9fd6): what the Photo composer's Generate sends (POST /v1/suite/photos), priced by Photo's rules. */
export function photoRequestOf(d: Draft): Record<string, unknown> {
  const toks = tokensOf(d), rig = (d.rig ?? {}) as Rig, extra = d as Record<string, unknown>;
  const mention = (k: string) => toks.find((x): x is Extract<Token, { t: 'mention' }> => x.t === 'mention' && x.kind === k)?.id;
  const screen = screenOf(d)?.request ?? {};
  // The screen's photo request (references, preset, product …) under Claude's values.
  const base: Record<string, unknown> = {};
  for (const k of ['modelId', 'outfitId', 'presetId', 'productImage', 'references', 'imageModel', 'engineModel', 'aspect', 'count', 'seed', 'lockSeed', 'shuffleSeed', 'gradeLook'] as const)
    if (screen[k] !== undefined && screen[k] !== null) base[k] = screen[k];
  const engine = typeof extra.engineModel === 'string' ? extra.engineModel : undefined;
  const modelId = mention('character') ?? (base.modelId as string | undefined), outfitId = (mention('outfit') ?? extra.outfitId ?? base.outfitId) as string | undefined;
  const camera = cameraOf(rig, []);
  const aspect = d.aspect && PHOTO_ASPECTS.has(d.aspect) ? d.aspect : base.aspect;
  const out: Record<string, unknown> = { ...base, prompt: promptText(toks), count: d.count ?? base.count ?? 1, draft: d,
    ...(modelId ? { modelId } : {}), ...(outfitId ? { outfitId } : {}), ...(camera ? { camera } : {}), ...(aspect ? { aspect } : {}),
    ...(rig.gradeLook === false ? { gradeLook: false } : {}), ...sentOfDraft(d) };
  // The pinned image model: a custom one ("c_…") is engineModel; a Replicate "owner/name" is imageModel.
  if (engine) { delete out.imageModel; delete out.engineModel; if (engine.startsWith('c_')) out.engineModel = engine; else out.imageModel = engine; }
  return out;
}

/**
 * New Swap (remix, plans/new-swap.md): the source clip, the toggles, the trimmed part and the model. Claude's own values
 * (set with suite_set_draft) win; otherwise what the app shows (its screen request).
 */
export function remixRequestOf(d: Draft) {
  const x = d as Record<string, unknown>;
  const req = withScreen({
    mode: 'remix' as const, prompt: '',
    ...(x.remix && typeof x.remix === 'object' ? { remix: x.remix } : {}),
    ...(Array.isArray(x.range) ? { range: x.range } : {}),
    ...(typeof x.engineModel === 'string' ? { engineModel: x.engineModel, ...(typeof x.resolution === 'string' ? { resolution: x.resolution } : {}) } : {}),
    quality: d.quality ?? 'standard', takes: d.takes ?? 1, aspectRatio: d.aspect ?? '9:16',
    draft: d,
  } as Record<string, unknown>, d);
  if (typeof x.clipId === 'string') req.clipId = x.clipId;
  if (typeof d.sound === 'boolean') req.keepAudio = d.sound;
  return req;
}

/** The draft's images-sent choice as request fields (images/sent.ts), or nothing. */
export function sentOfDraft(d: Draft): Partial<SentInput> {
  try { return sentOfBody((d as { sent?: unknown }).sent ?? null) ?? {}; } catch { return {}; }
}
/** The draft's chat references (workstream 1), only well-formed ones. */
export function referencesOf(d: Draft): DraftReference[] {
  const raw = (d as { references?: unknown }).references;
  if (!Array.isArray(raw)) return [];
  return raw.map(x => DraftReferenceSchema.safeParse(x)).filter(p => p.success).map(p => p.data!).slice(0, MAX_DRAFT_REFERENCES);
}

/** Claude's changes to the draft: each given field replaces the draft's; the prompt keeps the @model first and the #moves last. */
export const SetBody = z.object({
  modelId: z.string().max(80).nullable().optional(), outfitId: z.string().max(80).nullable().optional(),
  prompt: z.string().max(SHOT_PROMPT_CEILING, `at most ${SHOT_PROMPT_CEILING} characters (MUSE's limit): shorten it, keep the skeleton and cut repeats`).optional(), rig: RigSchema.omit({ moves: true }).optional(),
  moves: z.array(z.object({ id: z.string().max(40), intensity: z.number().min(0).max(1).optional() }).strict()).max(2).optional(),
  quality: z.enum(QUALITIES).optional(), aspect: z.enum(ASPECTS).optional(), duration: z.number().int().min(2).max(30).optional(), takes: z.number().int().min(1).max(4).optional(),
  sound: z.boolean().optional(), speaking: z.boolean().nullable().optional(),
  /** WS18: Photo's number of stills. */
  count: z.number().int().min(1).max(4).optional(),
  /** Movement → Directed: the camera (and blocking guides) from a camera session; null goes back to the chips. */
  directed: z.object({ cameraSessionId: z.string().max(80) }).strict().nullable().optional(),
  /** The model this shot runs on (a tier's model id, as the composer's model picker), null = Auto; and its resolution. */
  engineModel: z.string().max(40).nullable().optional(), resolution: z.string().max(20).nullable().optional(),
  /** Swap / Recast background: keep the clip's place, a new photo, or describe it in the prompt; null = Keep. */
  background: z.enum(['keep', 'photo', 'describe']).nullable().optional(),
  /** Swap's header switch: the current Swap ("classic") or New Swap (beta, "new"); only while Swap is open. */
  swapVariant: z.enum(['classic', 'new']).optional(),
  /** New Swap: the source clip (a clip of this studio). */
  clipId: z.string().max(80).nullable().optional(),
  /** New Swap: each toggle's setting; a toggle set to null is switched off (kept from the clip); remix: null clears all. */
  remix: z.object({
    background: RemixSchema.shape.background.unwrap().nullable().optional(), outfit: RemixSchema.shape.outfit.unwrap().nullable().optional(),
    character: RemixSchema.shape.character.unwrap().nullable().optional(), look: RemixSchema.shape.look.unwrap().nullable().optional(),
  }).strict().nullable().optional(),
  /** New Swap: the part of the clip to use [from, to] seconds (the trimmer); null = the whole clip. */
  range: z.tuple([z.number().min(0), z.number().positive()]).nullable().optional(),
  /** Shot's start / end frame slots (ci_91473102d2b0): a take's frame (at seconds | "first" | "last"), an upload or a
   *  Library / studio picture; null empties Claude's frame (the slot goes back to what is on screen). */
  startFrame: FrameInSchema.nullable().optional(), endFrame: FrameInSchema.nullable().optional(),
}).strict();
export type SetInput = z.infer<typeof SetBody>;

export class SuiteAssist {
  constructor(private ctx: Ctx) {}
  /** POST /v1/suite/photos/estimate's own pricing (set by routes/index.ts, where the Photo pipeline lives). */
  photoEstimate?: (u: AuthUser, body: Record<string, unknown>) => Promise<Record<string, unknown>>;

  view(r: Row) {
    const d = r.draft as Draft, req = (d.tool === 'photo' ? photoRequestOf(d) : requestOf(d)) as ReturnType<typeof requestOf>;
    return { id: r.id, userId: r.userId, draft: d, revision: r.revision, request: req, onScreen: onScreen(d),
      warnings: rigCheck({ prompt: req.prompt, camera: req.camera as never, speaking: (req as { speaking?: boolean }).speaking ?? false }),
      pending: (r.pending as AssistPending[]).filter(p => p.status === 'waiting').concat((r.pending as AssistPending[]).filter(p => p.status !== 'waiting').slice(-3)),
      createdAt: r.createdAt, updatedAt: r.updatedAt };
  }
  private emit(r: Row) {
    const v = this.view(r);
    this.ctx.hub.emit(r.studioId, x => (x.userId === r.userId || x.role === 'owner' ? { type: 'suiteAssist', assist: v } : null));
  }
  /** The assist this user may use: their own (the owner, any in the studio). */
  async row(u: AuthUser, id: string): Promise<Row> {
    const [r] = await this.ctx.db.select().from(suiteAssists).where(and(eq(suiteAssists.id, id), eq(suiteAssists.studioId, u.studioId)));
    if (!r || (r.userId !== u.id && u.role !== 'owner')) throw notFound('Assist');
    return r;
  }
  private async save(r: Row, set: Partial<Row>) {
    const [n] = await this.ctx.db.update(suiteAssists).set({ ...set, updatedAt: Date.now() }).where(eq(suiteAssists.id, r.id)).returning();
    this.emit(n!);
    return n!;
  }

  /** POST /v1/suite/assist {draft?, fromJobId?}: a new shared draft (empty, the composer's current one, or a shot's). */
  async create(u: AuthUser, body: unknown) {
    const b = z.object({ draft: z.unknown().optional(), fromJobId: z.string().max(80).optional() }).strict().safeParse(body ?? {});
    if (!b.success) throw badRequest(b.error.issues[0]?.message ?? 'Invalid body');
    let draft: Draft = { v: 1, tool: 'shot', quality: 'draft', aspect: '9:16', duration: 5, takes: 1, sound: true } as Draft;
    if (b.data.fromJobId) {
      const [j] = await this.ctx.db.select({ draft: jobs.draft }).from(jobs).where(and(eq(jobs.id, b.data.fromJobId), eq(jobs.studioId, u.studioId)));
      if (!j) throw notFound('Job');
      if (j.draft) draft = j.draft as Draft;
    } else if (b.data.draft !== undefined) draft = parseDraft(b.data.draft);
    const now = Date.now();
    const [r] = await this.ctx.db.insert(suiteAssists).values({ id: uid('sa'), studioId: u.studioId, userId: u.id, draft, revision: 1, pending: [], createdAt: now, updatedAt: now }).returning();
    return this.view(r!);
  }
  async get(u: AuthUser, id: string) { return this.view(await this.row(u, id)); }
  /** PATCH /v1/suite/assist/{id} {draft, baseRevision?}: the owner's own composer edits, so Claude sees them. */
  async patch(u: AuthUser, id: string, body: unknown) {
    const b = z.object({ draft: z.unknown(), baseRevision: z.number().int().min(0).optional() }).strict().safeParse(body ?? {});
    if (!b.success) throw badRequest(b.error.issues[0]?.message ?? 'Invalid body');
    const r = await this.row(u, id);
    if (b.data.baseRevision !== undefined && b.data.baseRevision !== r.revision) throw new ApiError(409, 'stale', 'Claude changed the shot meanwhile · reload it');
    const incoming = { ...((b.data.draft ?? {}) as Record<string, unknown>) };
    const prev = r.draft as Record<string, unknown>;
    const tool = typeof incoming.tool === 'string' ? incoming.tool : (prev.tool as string | undefined) ?? 'shot';
    // The app's first sync after Claude's change can echo the composer from before it (ci_40e89e2a9fd6: engineModel,
    // outfitId and count went back once after opening; ci_62c3c2fdcdbf: a reset images-sent list came back). A field
    // that comes back exactly as it was before Claude changed it keeps Claude's value, on that one sync only.
    const echo = prev.claudeSet as ClaudeSet | undefined;
    if (echo && echo.tool === tool) {
      for (const [k, v] of Object.entries(echo.fields)) {
        // An explicit null is the person's own Reset / Auto, never an echo.
        if (incoming[k] === null || !same(incoming[k], v.before) || same(v.before, v.after)) continue;
        if (v.after === undefined) delete incoming[k]; else incoming[k] = v.after;
      }
    }
    delete incoming.claudeSet;
    // Images sent (images/sent.ts), per tool (ci_62c3c2fdcdbf: a new Shot carried Photo's list): an app that doesn't know
    // `sent` keeps this tool's choice; another tool's list arriving with a tool switch is left with that tool; null clears.
    const byTool = { ...((prev.sentByTool ?? {}) as Record<string, unknown>) };
    if (prev.sent && prev.tool && !byTool[prev.tool as string]) byTool[prev.tool as string] = prev.sent;
    if (!('sent' in incoming)) { if (byTool[tool]) incoming.sent = byTool[tool]; }
    else if (incoming.sent === null) { delete incoming.sent; delete byTool[tool]; }
    else if (tool !== prev.tool && !byTool[tool] && Object.entries(byTool).some(([t, v]) => t !== tool && same(v, incoming.sent))) delete incoming.sent;
    else byTool[tool] = incoming.sent;
    if (Object.keys(byTool).length) incoming.sentByTool = byTool; else delete incoming.sentByTool;
    // Claude's start / end frames: the apps don't send them back (the request's frames win once the person changes that slot).
    if (!('frames' in incoming) && prev.frames) incoming.frames = prev.frames;
    return this.view(await this.save(r, { draft: parseDraft(incoming), revision: r.revision + 1 }));
  }

  /** Undo of one "What I changed" row (claude/cards.ts): fn turns the draft as it is now into the draft to keep. */
  async rewrite(u: AuthUser, id: string, fn: (d: Record<string, unknown>) => Record<string, unknown>) {
    const r = await this.row(u, id);
    // The person undid Claude's change: the app's next sync showing the old value is theirs, not an echo (see patch).
    const { claudeSet: _echo, ...d } = fn({ ...(r.draft as Record<string, unknown>) });
    return this.view(await this.save(r, { draft: parseDraft(d), revision: r.revision + 1 }));
  }
  /** suite_set_draft: Claude's changes, checked against the composer's visible options. */
  async set(u: AuthUser, id: string, input: unknown) {
    const p = SetBody.safeParse(input ?? {});
    if (!p.success) throw badRequest(p.error.issues.map(i => (i.path.length ? `${i.path.join('.')}: ` : '') + i.message).join('; '));
    const b = p.data;
    const r = await this.row(u, id);
    const d = { ...(r.draft as Draft) } as Draft & Record<string, unknown>;
    const before = { ...(r.draft as Record<string, unknown>) };
    let toks = [...tokensOf(d)];
    let key = toks.reduce((m, x) => Math.max(m, 'key' in x ? x.key : 0), 0);
    if (b.modelId !== undefined) {
      toks = toks.filter(x => !(x.t === 'mention' && (x.kind === 'character' || x.kind === 'outfit')));
      if (b.modelId) {
        const [m] = await this.ctx.db.select({ id: models.id, name: models.name, archivedAt: models.archivedAt }).from(models).where(and(eq(models.id, b.modelId), eq(models.studioId, u.studioId)));
        if (!m) throw badRequest(`modelId: no model ${b.modelId} in the studio`);
        if (m.archivedAt) throw new ApiError(409, 'model_archived', `${m.name} is archived`);
        toks.unshift({ t: 'mention', kind: 'character', id: m.id, label: m.name, key: ++key });
      }
    }
    if (b.outfitId !== undefined) { if (b.outfitId) d.outfitId = b.outfitId; else delete d.outfitId; }
    if (b.prompt !== undefined) {
      const head = toks.filter(x => x.t === 'mention'), tail = toks.filter(x => x.t === 'move');
      toks = [...head, ...(b.prompt.trim() ? [{ t: 'text' as const, text: `${head.length ? ' ' : ''}${b.prompt.trim()}${tail.length ? ' ' : ''}` }] : []), ...tail];
    }
    if (b.moves !== undefined) {
      const ms = b.moves.map(m => { const o = MOVES.find(x => x.id === m.id); if (!o) throw badRequest(`moves: unknown move "${m.id}" (suite_options lists them)`); return { o, intensity: m.intensity ?? 0.5 }; });
      toks = [...toks.filter(x => x.t !== 'move'), ...ms.map(({ o, intensity }) => ({ t: 'move' as const, id: o.id, label: o.label, category: o.category, intensity: Math.round(intensity * 100), key: ++key }))];
    }
    if (b.rig !== undefined) d.rig = { ...checkVisibleRig(RigSchema.parse(b.rig)) };
    for (const k of ['quality', 'aspect', 'duration', 'takes', 'sound', 'count'] as const) if (b[k] !== undefined) (d as Record<string, unknown>)[k] = b[k];
    if (b.speaking !== undefined) { if (b.speaking === null) delete d.speaking; else d.speaking = b.speaking; }
    if (b.directed !== undefined) {
      if (b.directed === null) {
        delete d.directed;
        // Back to the chips: a Directed camera picked on screen goes too (the app shows the chips again).
        const sc = screenOf(d);
        if ((sc?.request?.camera as { mode?: string } | undefined)?.mode === 'directed') { const { camera: _c, ...req } = sc!.request!; d.screen = { ...(d.screen as object), request: req }; }
      } else d.directed = await directedOf(this.ctx, u, b.directed.cameraSessionId);
    }
    if (b.engineModel !== undefined) { if (b.engineModel === null) { delete d.engineModel; delete d.resolution; } else d.engineModel = b.engineModel; }
    if (b.resolution !== undefined) { if (b.resolution === null) delete d.resolution; else d.resolution = b.resolution; }
    // The app takes it (Swap / Recast panel) and shows "Claude set Background"; null = back to what is on screen.
    if (b.background !== undefined) { if (b.background === null) delete (d as Record<string, unknown>).background; else (d as Record<string, unknown>).background = b.background; }
    // WS18: the draft keeps the composer's tool (Photo, Talking, UGC ad, …). Forcing 'shot' here made the app refuse every
    // change Claude made outside Shot, because it only lays a draft over the composer of the same tool.
    if (!d.tool) d.tool = 'shot';
    // New Swap: the header switch, the clip, the toggles (each replaced or switched off) and the trimmer's range.
    if (b.swapVariant !== undefined) {
      if (d.tool !== 'swap' && d.tool !== 'remix') throw new ApiError(409, 'not_swap', 'swapVariant: open Swap first (it switches between Swap and New Swap)');
      d.tool = b.swapVariant === 'new' ? 'remix' : 'swap';
    }
    if (b.clipId !== undefined || b.remix !== undefined || b.range !== undefined) {
      if (d.tool !== 'remix') throw new ApiError(409, 'not_new_swap', 'clipId, remix and range are New Swap’s: switch to it first (swapVariant: "new")');
      if (b.clipId !== undefined) {
        if (b.clipId === null) delete d.clipId;
        else {
          const [c] = await this.ctx.db.select({ id: clips.id }).from(clips).where(and(eq(clips.id, b.clipId), eq(clips.studioId, u.studioId)));
          if (!c) throw badRequest(`clipId: no clip ${b.clipId} in the studio`);
          d.clipId = b.clipId;
        }
      }
      if (b.remix === null) delete d.remix;
      else if (b.remix) {
        const cur = { ...((d.remix ?? {}) as Record<string, unknown>) };
        for (const [k, v] of Object.entries(b.remix)) { if (v === null) delete cur[k]; else if (v !== undefined) cur[k] = v; }
        if (Object.keys(cur).length) d.remix = RemixSchema.parse(cur); else delete d.remix;
      }
      if (b.range !== undefined) { if (b.range === null) delete d.range; else d.range = b.range; }
    }
    // Start / end frames (ci_91473102d2b0): the same request slots the apps fill (frames.start / frames.end).
    for (const [slot, f] of [['start', b.startFrame], ['end', b.endFrame]] as const) {
      if (f === undefined) continue;
      if (d.tool !== 'shot' && f !== null) throw new ApiError(409, 'not_a_shot', `${slot}Frame: start and end frames are the Shot composer's (this draft is ${d.tool})`);
      const cur = { ...framesOf(d) };
      if (f === null) delete cur[slot];
      else {
        const on = (screenOf(d)?.request?.frames as Record<string, unknown> | undefined)?.[slot];
        cur[slot] = { url: await this.frameUrl(u, f), label: f.label ?? frameLabel(f), over: frameKey(on) };
      }
      if (cur.start || cur.end) d.frames = cur; else delete d.frames;
    }
    (d as Record<string, unknown>).tokens = toks;
    // The prompt against the limit of the model it will run on (ci_9a79f3707f79).
    if (b.prompt !== undefined || b.engineModel !== undefined) {
      const words = toks.filter(x => x.t === 'text').map(x => (x as { text: string }).text).join('').trim();
      const lim = promptLimit(d.tool, typeof d.engineModel === 'string' ? d.engineModel : undefined);
      if (words.length > lim.max) throw badRequest(`prompt: ${words.length} characters, but ${lim.why}: shorten it, keep the skeleton and cut repeats${typeof d.engineModel === 'string' && d.tool !== 'photo' ? ', or pick a model that takes more (suite_models)' : ''}`);
    }
    // What Claude changed, so the app's first sync echoing the old composer doesn't undo it (see patch).
    const fields: ClaudeSet['fields'] = {};
    for (const k of ECHO_FIELDS) if (!same(before[k], (d as Record<string, unknown>)[k])) fields[k] = { before: before[k], after: (d as Record<string, unknown>)[k] };
    if (Object.keys(fields).length) d.claudeSet = { tool: d.tool, fields } satisfies ClaudeSet; else delete d.claudeSet;
    return this.view(await this.save(r, { draft: parseDraft(d), revision: r.revision + 1 }));
  }

  /** A frame's studio picture: a take's frame (first, last or at seconds), an upload, or a Library / studio picture. */
  private async frameUrl(u: AuthUser, f: z.infer<typeof FrameInSchema>): Promise<string> {
    if (f.takeId) {
      const ref = await sentImagesOf(this.ctx).takeFrame(u.studioId, f.takeId, f.at === 'first' ? 0 : f.at);
      const m = ref.url ? /\/uploads\/[a-z]+\/[A-Za-z0-9._-]+$/.exec(ref.url) : null;
      if (!m) throw badRequest('That take has no stored picture to use as a frame');
      return m[0];
    }
    return this.referenceUrl(u, f.uploadId, f.image);
  }

  /**
   * suite_add_reference (workstream 1): an image the owner attached becomes a reference of the shot (pose, style,
   * location or outfit), at most 3. A studio image under u/ (HEIC made JPEG) so the engine can be sent it; the same
   * upload again replaces its use; remove takes it out. Her identity always comes from her own references.
   */
  async addReference(u: AuthUser, id: string, input: unknown) {
    const p = AddReferenceBody.safeParse(input ?? {});
    if (!p.success) throw badRequest(p.error.issues.map(i => (i.path.length ? `${i.path.join('.')}: ` : '') + i.message).join('; '));
    const b = p.data;
    const r = await this.row(u, id);
    const d = { ...(r.draft as Draft) } as Draft & Record<string, unknown>;
    let list = referencesOf(d);
    // The reference's id: the upload, the take (and moment), or the image's own link.
    const imageIn = b.image ?? (b.takeId ? { takeId: b.takeId, ...(b.at !== undefined ? { at: b.at } : {}) } : undefined);
    const refId = (b.uploadId ?? (b.takeId ? `${b.takeId}${b.at ? `@${b.at}` : ''}` : typeof b.image === 'string' ? b.image
      : b.image && 'takeId' in b.image ? `${b.image.takeId}${b.image.at ? `@${b.image.at}` : ''}` : (b.image as { url?: string; asset?: string }).url ?? (b.image as { asset?: string }).asset ?? '')).slice(0, 80);
    const existing = list.find(x => x.uploadId === refId);
    if (b.remove) {
      if (!existing) throw notFound('Reference');
      list = list.filter(x => x !== existing);
    } else {
      let url = existing?.url;
      if (!url) {
        if (list.length >= MAX_DRAFT_REFERENCES) throw new ApiError(409, 'too_many_references', `A shot takes at most ${MAX_DRAFT_REFERENCES} chat references · remove one first`);
        url = await this.referenceUrl(u, b.uploadId, imageIn);
      }
      const item: DraftReference = { uploadId: refId, url, use: b.use, ...(b.label ? { label: b.label } : existing?.label && existing.use === b.use ? { label: existing.label } : {}) };
      list = existing ? list.map(x => (x === existing ? item : x)) : [...list, item];
    }
    if (list.length) d.references = list; else delete d.references;
    return this.view(await this.save(r, { draft: parseDraft(d), revision: r.revision + 1 }));
  }

  /** A studio image's /uploads/ link for a reference: an upload (HEIC made JPEG), else a take, Library still or link. */
  private async referenceUrl(u: AuthUser, uploadId: string | undefined, image: z.infer<typeof ImageInSchema> | undefined): Promise<string> {
    if (uploadId) {
      try {
        const { up, buf, kind } = await uploadImage(this.ctx, u, uploadId);
        if (kind !== 'heic' && up.storageKey.startsWith('u/')) return `/uploads/${up.storageKey}`;
        const img = await normaliseImage(buf, kind, uploadId);
        const key = `u/${uid('img')}.${img.mimeType === 'image/png' ? 'png' : img.mimeType === 'image/webp' ? 'webp' : 'jpg'}`;
        await putObject(this.ctx, { key, body: img.buf, studioId: u.studioId, kind: 'image', userId: u.id, contentType: img.mimeType });
        return `/uploads/${key}`;
      } catch (e) {
        // Not an upload: a take or Library still given as uploadId (Claude's issue 2026-11-11) is taken as one.
        if (!(e instanceof ApiError) || e.status !== 404 || image) throw e;
        image = uploadId;
      }
    }
    const ref = await sentImagesOf(this.ctx).image(u.studioId, image!);
    const m = ref.url ? /\/uploads\/[a-z]+\/[A-Za-z0-9._-]+$/.exec(ref.url) : null;
    if (!m) throw badRequest('That picture can\'t be a reference (only this studio\'s stored images)');
    return m[0];
  }

  /** set_sent_images on the Suite: the images Generate sends, kept in the draft (null: back to MUSE's pick). */
  async setSent(u: AuthUser, id: string, sent: SentInput | null) {
    const r = await this.row(u, id);
    const d = { ...(r.draft as Draft) } as Draft & Record<string, unknown>;
    const before = d.sent;
    if (sent) d.sent = sent; else delete d.sent;
    const tool = d.tool ?? 'shot';
    const byTool = { ...((d.sentByTool ?? {}) as Record<string, unknown>) };
    if (sent) byTool[tool] = sent; else delete byTool[tool];
    if (Object.keys(byTool).length) d.sentByTool = byTool; else delete d.sentByTool;
    // A reset that the app's next sync would undo (ci_62c3c2fdcdbf) is kept, as Claude's other changes are.
    if (!same(before, d.sent)) d.claudeSet = { tool, fields: { sent: { before, after: d.sent } } } satisfies ClaudeSet;
    return this.view(await this.save(r, { draft: parseDraft(d), revision: r.revision + 1 }));
  }
  /** suite_estimate: the price, caps and warnings of what Generate would send (nothing held). */
  async estimate(u: AuthUser, id: string) {
    const v = this.view(await this.row(u, id));
    // Photo (ci_40e89e2a9fd6): priced as the Photo composer's Generate (POST /v1/suite/photos/estimate), on its image model.
    if (v.draft.tool === 'photo') {
      if (!this.photoEstimate) throw new ApiError(503, 'not_ready', 'Photo pricing is starting up · try again');
      return { assistId: id, tool: 'photo', estimate: await this.photoEstimate(u, v.request as Record<string, unknown>), warnings: v.warnings };
    }
    if (v.request.mode === 'remix' && !v.request.clipId) throw badRequest('New Swap: add the video first (suite_set_draft clipId, or the person adds it)');
    // ci_5bb0ab964dd8: no character (modelId) is a shot without her, priced as Generate would send it (the app's own
    // estimate does the same), never "Pick the model first". Auto (no engineModel) is priced on the model Auto picks now.
    const estimate = await this.ctx.suite.estimate(u, v.request) as { engine?: { label?: string } };
    const lone = !v.request.modelId && v.request.mode !== 'remix' && !['swap', 'recast', 'extend'].includes(String(v.draft.tool ?? 'shot'));
    const auto = typeof (v.request as { engineModel?: unknown }).engineModel !== 'string';
    return { assistId: id, estimate, warnings: v.warnings, ...(lone ? { note: 'No character picked: priced as a shot without her (suite_set_draft modelId adds her).' } : {}),
      ...(auto ? { engineChoice: 'auto', ...(estimate.engine?.label ? { autoPicks: estimate.engine.label } : {}) } : {}) };
  }
  /** suite_request_shot with confirm: the owner is asked in the app; their yes runs the shot at this price at most. */
  async ask(u: AuthUser, id: string) {
    const tool = ((await this.row(u, id)).draft as { tool?: string }).tool ?? 'shot';
    if (tool !== 'shot' && tool !== 'remix') throw new ApiError(409, 'not_a_shot', 'Claude can ask to generate a Shot or a New Swap only · in this composer the owner presses Generate');
    const e = await this.estimate(u, id) as { estimate: { estimate?: number; ok?: boolean; message?: string; buttonLabel?: string; breakdown?: AssistPending['breakdown']; remix?: { trim?: { needed?: boolean; maxSeconds?: number } } } };
    if (e.estimate.remix?.trim?.needed) throw new ApiError(400, 'remix_trim_needed', `Trim the clip first: this model takes up to ${e.estimate.remix.trim.maxSeconds} s (suite_set_draft range, or the person uses the trimmer)`);
    if (e.estimate.ok === false) throw new ApiError(402, 'caps', e.estimate.message ?? 'A spending cap stops this shot');
    const usd = Number(e.estimate.estimate) || 0;
    const r = await this.row(u, id);
    const item: AssistPending = { id: uid('sp'), kind: 'suite_request_shot', label: e.estimate.buttonLabel ?? `Generate · $${usd.toFixed(2)}`, estimateUsd: usd, maxUsd: usd, ...(e.estimate.breakdown ? { breakdown: e.estimate.breakdown } : {}), status: 'waiting', createdAt: Date.now() };
    const list = [...(r.pending as AssistPending[]).filter(p => p.status !== 'waiting').slice(-5), ...(r.pending as AssistPending[]).filter(p => p.status === 'waiting'), item];
    await this.save(r, { pending: list });
    return item;
  }
  /** POST /v1/suite/assist/{id}/pending/{pid} {approve}: yes runs the shot (the price checked again against the one asked). */
  async answer(u: AuthUser, id: string, pid: string, body: unknown) {
    const r = await this.row(u, id);
    const list = r.pending as AssistPending[];
    const p = list.find(x => x.id === pid);
    if (!p || p.status !== 'waiting') throw notFound('Waiting request');
    if ((body as { approve?: unknown } | null)?.approve !== true) p.status = 'declined';
    else {
      const req = this.view(r).request;
      const now = await this.ctx.suite.estimate(u, req) as { estimate?: number };
      const total = Number(now.estimate) || 0;
      if (total > p.maxUsd + 0.005) {
        const e = new ApiError(409, 'price_changed', `This shot now costs about $${total.toFixed(2)} · ask Claude to price it again`);
        (e as ApiError & { extra?: unknown }).extra = { totalUsd: total };
        throw e;
      }
      try {
        const job = await this.ctx.suite.create(u, req) as { id: string };
        p.status = 'done'; p.jobId = job.id;
      } catch (e) {
        p.status = 'failed'; p.error = e instanceof ApiError ? e.message : 'Couldn’t start the shot';
        await this.save(r, { pending: list });
        throw e;
      }
    }
    await this.save(r, { pending: list });
    return p;
  }
}

/** Fields the app's first sync could echo back from before Claude's change. */
const ECHO_FIELDS = ['engineModel', 'resolution', 'outfitId', 'count', 'sent'] as const;
type ClaudeSet = { tool?: string; fields: Record<string, { before: unknown; after: unknown }> };
/** Deep equality for JSON values (undefined and absent alike). */
function same(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a == null || b == null) return a == null && b == null;
  if (typeof a !== 'object' || typeof b !== 'object') return false;
  const ka = Object.keys(a as object).filter(k => (a as Record<string, unknown>)[k] !== undefined).sort(), kb = Object.keys(b as object).filter(k => (b as Record<string, unknown>)[k] !== undefined).sort();
  return ka.length === kb.length && ka.every((k, i) => k === kb[i] && same((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]));
}
const frameLabel = (f: z.infer<typeof FrameInSchema>) => (f.takeId ? `${f.at === 'last' ? 'last frame' : f.at === 'first' || f.at === undefined ? 'first frame' : `frame at ${f.at} s`} of ${f.takeId}` : f.uploadId ? `upload ${f.uploadId}` : 'studio picture');

function parseDraft(v: unknown): Draft {
  const p = DraftSchema.safeParse(v);
  if (!p.success) throw badRequest(`draft: ${p.error.issues[0]?.path.join('.')} ${p.error.issues[0]?.message}`);
  return p.data;
}

const services = new WeakMap<Ctx, SuiteAssist>();
export const assistOf = (ctx: Ctx) => { let s = services.get(ctx); if (!s) { s = new SuiteAssist(ctx); services.set(ctx, s); } return s; };
/** The member's most recent assists (for the threads list). */
export async function recentAssists(ctx: Ctx, u: AuthUser, limit = 10) {
  return (await ctx.db.select().from(suiteAssists).where(and(eq(suiteAssists.studioId, u.studioId), eq(suiteAssists.userId, u.id))).orderBy(desc(suiteAssists.updatedAt)).limit(limit)).map(r => assistOf(ctx).view(r));
}
