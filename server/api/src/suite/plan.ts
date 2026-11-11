// AI suite · planning a shot: request schema, model selection on the quality ladder, the character's reference subset,
// the prompt, provider inputs and the cost. Pure functions (no database), so the estimate, the job and the tests agree.
import { z } from 'zod';
import type { ImageRef } from '../db/schema.js';
import { DEFAULT_TEXTS, listOf, type PromptTexts } from '../prompt/library.js';
import { applySent, roleOfLabel, sameImage, SENT_FIELDS, whyOf, type Resolved, type SentImage, type SentRole, type SentView } from '../images/sent.js';
import { sanitizeDirection } from '../prompt/engine.js';
import { run } from '../prompt/scripts/builders.js';
import { CameraSpecSchema, stripMoveTokens, VideoRefSchema, type VideoRef } from './camera.js';
import { compileCamera, type CompiledCamera } from './compile.js';
import { DEFAULT_LADDER, modelById, refFor, TIER_INFO, TIERS, type LadderStep, type ModelSpec, type ProviderId, type Resolution, type ShotMode, type Tier } from './registry.js';
import { modelLabel } from '../engines/labels.js';

export const ImageRefSchema = z.object({ asset: z.string().max(80).optional(), url: z.string().max(2000).optional() }).refine(v => !!v.asset || !!v.url, 'an image needs asset or url');

/** One person to recast: which person in the clip (index, position hint, or a face crop) → which character. */
export const CastSchema = z.object({
  /** 1-based, in order of appearance (or left to right when they appear together). */
  personIndex: z.number().int().min(1).max(4).optional(),
  personHint: z.enum(['left', 'center', 'right', 'foreground', 'background', 'first', 'second', 'third', 'fourth']).optional(),
  /** Free words: "the woman in the red coat". */
  personNote: z.string().max(80).optional(),
  /** A crop of the person's face from the clip (sent where the model takes one). */
  faceCrop: ImageRefSchema.optional(),
  characterId: z.string().max(80),
  outfitId: z.string().max(80).optional(),
  /** This person speaks or sings in the clip. Unset: the clip's talking flag/detection when one person is recast, else unknown. */
  speaking: z.boolean().optional(),
}).strict();

export const ShotRequestSchema = z.object({
  mode: z.enum(['text', 'image', 'reference', 'swap', 'recast', 'extend']).optional(),
  /** Extend: the finished clip to continue (a take, clip or upload in this studio) and which way. suite/extend.ts. */
  extend: z.object({ video: VideoRefSchema, direction: z.enum(['after', 'before']).default('after'),
    /** Deliver source + extension as one clip (default) or the new part alone. */
    join: z.boolean().default(true) }).optional(),
  /** Recast: who in the source clip (`clipId`) becomes which studio character; 1–4 people (suite/recast.ts). */
  cast: z.array(CastSchema).min(1).max(4).optional(),
  title: z.string().max(200).optional(),
  /** The character (a MUSE model) and her outfit. */
  modelId: z.string().max(80).optional(),
  outfitId: z.string().max(80).optional(),
  /** Scene, action and dialogue in the user's words. */
  prompt: z.string().max(2000).default(''),
  frames: z.object({ start: ImageRefSchema.optional(), middle: z.array(ImageRefSchema).max(8).optional(), end: ImageRefSchema.optional() }).optional(),
  references: z.object({
    images: z.array(z.object({ image: ImageRefSchema, role: z.enum(['product', 'location', 'style', 'prop', 'person', 'pose', 'outfit' /* workstream 1: attached in the Claude chat */, 'frame' /* a start/middle/end frame sent as a reference (adaptRequest) */]).default('product'), label: z.string().max(80).optional() })).max(6).optional(),
    videos: z.array(z.object({ video: VideoRefSchema, use: z.enum(['camera', 'motion', 'style']).default('motion') })).max(3).optional(),
    /** One audio track (an upload in this studio). Speaking: sent as is (lip sync); not speaking: only its instrumental is sent. */
    audio: z.object({ audio: VideoRefSchema }).optional(),
  }).optional(),
  duration: z.number().int().min(2).max(30).default(5),
  aspectRatio: z.enum(['9:16', '16:9', '1:1', '4:3', '3:4', '21:9']).default('9:16'),
  quality: z.enum(TIERS as [Tier, ...Tier[]]).default('draft'),
  takes: z.number().int().min(1).max(4).default(1),
  /** Native sound where the model makes it. */
  audio: z.boolean().default(true),
  /**
   * The character speaks or sings on camera (the switch). Unset: the uploaded audio's talking flag, else detection on
   * the audio reference, else no (plans/prompt-scripts.md). Off: the prompt says she does not speak, sing or mouth words.
   */
  speaking: z.boolean().optional(),
  camera: CameraSpecSchema.optional(),
  /** "Grade the take with this look" (composer, on by default): the Look's LUT is applied after the render as an editable Look. */
  gradeLook: z.boolean().default(true),
  seed: z.number().int().min(0).max(2147483647).optional(),
  /** Owner only: a registry model id (and resolution) instead of the ladder. */
  engineModel: z.string().max(40).optional(),
  resolution: z.string().max(20).optional(),
  /** Swap mode (the existing character swap): the source clip and whether to keep its sound. */
  clipId: z.string().max(80).optional(),
  keepAudio: z.boolean().optional(),
  direction: z.string().max(500).optional(),
  /** Plan and price only: nothing is held or run (agents, previews). */
  dryRun: z.boolean().optional(),
  /** AI suite (workstream 1): the composer's draft, checked by suite/drafts.ts and stored with the job. */
  draft: z.unknown().optional(),
  /** Images sent (images/sent.ts): replace, add to or drop from what MUSE picks. */
  ...SENT_FIELDS,
}).strict();
export type ShotRequest = z.infer<typeof ShotRequestSchema>;

export type ModelPrefs = Record<string, { enabled?: boolean; acknowledgedAt?: number | null; priceScale?: number }>;
export type SuitePrefs = { models?: ModelPrefs; ladder?: Partial<Record<Tier, LadderStep[]>>; capPerJob?: number | null; capPerDay?: number | null };

export type Character = { name: string; look: string; neverAdd: string[]; images: { label: string; image: ImageRef }[]; outfit?: { name: string; description?: string; images: { label: string; image: ImageRef }[] } | null };

export type Need = {
  mode: Exclude<ShotMode, 'swap'>; start: boolean; end: boolean; middle: number; characterImages: number; extraImages: number; videos: number; guide: boolean;
  directed: boolean; duration: number; aspect: string; withAudio: boolean; audioRef: boolean;
};

/**
 * The shot's needs, from the request. Only the person's own frames (`frames`) are hard: the Camera stage's guide
 * keyframes (camera.guide.keyframes) are hints that buildPlan sends where the model can take them, so they never switch
 * the shot to keyframe mode or rule a model out.
 */
export function needOf(r: ShotRequest, character: Character | null): Need {
  const f = r.frames ?? {};
  const start = !!f.start, end = !!f.end, middle = f.middle?.length ?? 0;
  const mode = (r.mode as Need['mode'] | undefined) ?? (start || end ? 'image' : character?.images.length ? 'reference' : 'text');
  return { mode, start, end, middle, characterImages: mode === 'text' ? 0 : character?.images.length ?? 0, extraImages: r.references?.images?.length ?? 0,
    videos: r.references?.videos?.length ?? 0, guide: !!r.camera?.guide, directed: r.camera?.mode === 'directed', duration: r.duration, aspect: r.aspectRatio, withAudio: r.audio, audioRef: !!r.references?.audio };
}

/** Why `m` at `resolution` can't make this shot, or null. Also the duration it would render. */
export function fit(m: ModelSpec, resolution: string, n: Need): { why: string | null; seconds: number } {
  const r = misfits(m, resolution, n);
  return { why: r.why[0] ?? null, seconds: r.seconds };
}

/** Every reason `m` at `resolution` can't make this shot (codes, in check order), and the duration it would render. */
export function misfits(m: ModelSpec, resolution: string, n: Need): { why: string[]; seconds: number } {
  let seconds = Math.max(m.duration.min, Math.min(n.duration, m.duration.max));
  if (m.duration.allowed) seconds = m.duration.allowed.reduce((p, c) => (Math.abs(c - n.duration) < Math.abs(p - n.duration) || (Math.abs(c - n.duration) === Math.abs(p - n.duration) && c > p) ? c : p));
  const why: string[] = [];
  if (m.status === 'removed') return { why: ['removed'], seconds };
  if (m.licence.blockNewFeatures) return { why: ['licence'], seconds };
  if (!m.resolutions.some(x => x.id === resolution)) why.push(`no ${resolution}`);
  if (n.duration > m.duration.max || n.duration < m.duration.min - 1) why.push(`length ${m.duration.min}–${m.duration.max} s`);
  if (!m.aspectRatios.includes(n.aspect)) why.push(`no ${n.aspect}`);
  if (n.directed && !(m.modes.guide || m.camera.referenceVideo)) why.push('no guide clip');
  if (n.mode === 'text' && !m.modes.text) why.push('no text-to-video');
  if (n.mode === 'image') {
    if (!m.modes.image || (n.start && !m.frames.start) || (n.end && !m.frames.end)) why.push('no keyframes');
    else if (n.middle > m.frames.middle) why.push(`at most ${m.frames.middle} middle frames`);
  }
  if (n.mode === 'reference' && (!m.modes.reference || m.refs.images < 1)) why.push('no reference images');
  if (n.videos > m.refs.videos) why.push('no reference videos');
  if (n.audioRef && m.refs.audios < 1) why.push('no reference audio');
  // Reference audio rides with an image or video reference (Seedance and H3 Lite require it; safest everywhere).
  if (n.audioRef && n.mode === 'text' && !n.extraImages && !n.videos && !n.guide) why.push('audio needs an image or video reference');
  if (n.audioRef && n.mode === 'image' && !m.frames.withRefs) why.push('no audio with keyframes');
  if (n.extraImages > 0 && m.refs.images < n.extraImages + (n.mode === 'reference' ? 1 : 0) && !(n.mode === 'image' && !m.frames.withRefs)) why.push('too many reference images');
  if (m.id === 'veo-3.1-lite' && resolution === '1080p' && seconds !== 8) why.push('1080p only at 8 s');
  return { why, seconds };
}

/** A misfit code in plain, member-safe words ("can't use a start frame"). */
export function whyWords(code: string, m: ModelSpec, n?: Need): string {
  const lim = m.duration.allowed ? m.duration.allowed.join(', ') : `${m.duration.min}–${m.duration.max}`;
  if (code === 'removed') return 'is no longer available';
  if (code === 'licence') return 'is not offered for new shots';
  if (code === 'unknown model') return 'is not available in this studio';
  if (code === 'switched off') return 'is switched off in this studio';
  if (code === 'licence not acknowledged') return 'needs the studio owner to accept its licence first';
  if (/ not set up$/.test(code)) return 'is not set up in this studio yet';
  if (code.startsWith('length ')) return `length must be ${lim} s`;
  if (/^no \d+:\d+$/.test(code)) return `can't make ${code.slice(3)} (makes ${m.aspectRatios.join(', ')})`;
  if (/^no \S+$/.test(code) && code !== 'no keyframes') return `makes ${m.resolutions.map(r => r.label).join(', ')} only`;
  if (code === 'no guide clip') return "can't follow a guide clip";
  if (code === 'no text-to-video') return 'needs a picture to start from';
  if (code === 'no keyframes') return n?.start && !n.end ? "can't use a start frame" : n?.end && !n.start ? "can't use an end frame" : "can't use start or end frames";
  if (code.startsWith('at most ')) return `takes ${code.slice(8)}`;
  if (code === 'no reference images') return "can't use reference images";
  if (code === 'no reference videos') return m.refs.videos ? `takes at most ${m.refs.videos} reference video${m.refs.videos > 1 ? 's' : ''}` : "can't use reference videos";
  if (code === 'no reference audio') return "can't use an audio reference";
  if (code === 'audio needs an image or video reference') return 'needs an image or video with the audio reference';
  if (code === 'no audio with keyframes') return "can't use an audio reference with start or end frames";
  if (code === 'too many reference images') return `takes at most ${m.refs.images} reference images`;
  if (code === '1080p only at 8 s') return 'makes 1080p at 8 s only';
  return code;
}

/** A model's label, "<Model> · <Provider>" (engines/labels.ts; owner-added models by their own name and provider). */
export const modelName = (m: ModelSpec) => modelLabel(m.byo?.displayName ?? m.name, m.byo ? m.byo.providerKind : m.provider);

const ASPECT_VALUE = (a: string) => { const [w, h] = a.split(':').map(Number); return (w ?? 1) / (h ?? 1); };
/** The supported aspect closest to `a`. */
export const nearestAspect = (a: string, list: string[]) => list.reduce((p, c) => (Math.abs(Math.log(ASPECT_VALUE(c) / ASPECT_VALUE(a))) < Math.abs(Math.log(ASPECT_VALUE(p) / ASPECT_VALUE(a))) ? c : p));

/** The short side a resolution id stands for ("1080p" 1080, "2K" 1440, "768x1344" 768); unknown: the largest. */
const sideOf = (id: string) => { const x = /^(\d+)x(\d+)$/.exec(id); if (x) return Math.min(+x[1]!, +x[2]!); if (/^2k$/i.test(id)) return 1440; if (/^4k$/i.test(id)) return 2160; const p = /^(\d+)p$/i.exec(id); return p ? +p[1]! : Infinity; };

/** Misfits MUSE can work around by changing the request (adaptRequest); everything else refuses. */
const ADAPTABLE = (code: string) => /^(no \S+|length .*|too many reference images|no keyframes|no audio with keyframes|at most \d+ middle frames|no reference videos|audio needs an image or video reference)$/.test(code)
  && !['no guide clip', 'no text-to-video', 'no reference images', 'no reference audio'].includes(code);

export type Adapted = { request: ShotRequest; resolution: string; need: Need; notes: string[]; adapted: string[] };

/**
 * "Adapt, don't block": change the request so `m` can make it, saying each change in member-safe words. Frames on a model
 * without keyframes go as reference images ("opening frame" first; the prompt says "Open on image n"); a length outside
 * the range is clamped; an unsupported aspect or resolution moves to the nearest; extra references and videos are cut to
 * the model's limits (frames and the first given kept). Null `request` with `why`: what can't be worked around.
 */
export function adaptRequest(m: ModelSpec, resolution: string, r0: ShotRequest, character: Character | null): Adapted & { why: string[] } {
  let r: ShotRequest = structuredClone(r0);
  let res = resolution;
  const notes: string[] = [], adapted: string[] = [], name = modelName(m);
  for (let i = 0; i < 8; i++) {
    const n = needOf(r, character);
    const { why, seconds } = misfits(m, res, n);
    const code = why.find(ADAPTABLE);
    if (!why.length || !code) return { request: r, resolution: res, need: n, notes, adapted, why };
    if (/^no \d+:\d+$/.test(code)) {
      const a = nearestAspect(n.aspect, m.aspectRatios);
      r.aspectRatio = a as ShotRequest['aspectRatio'];
      notes.push(`made ${a} (${name} doesn't make ${n.aspect})`); adapted.push(`aspect:${a}`);
    } else if (/^no \S+$/.test(code) && !/^no (keyframes|reference videos)$/.test(code)) {
      const want = sideOf(res);
      const near = [...m.resolutions].sort((a, b) => Math.abs(a.shortSide - want) - Math.abs(b.shortSide - want) || b.shortSide - a.shortSide)[0]!;
      notes.push(`made at ${near.label} (${name} makes ${m.resolutions.map(x => x.label).join(', ')})`); adapted.push(`resolution:${near.id}`);
      res = near.id;
    } else if (code.startsWith('length ')) {
      notes.push(`made ${seconds} s, ${name} ${n.duration > m.duration.max ? 'max' : 'min'}`); adapted.push(`length:${seconds}`);
      r.duration = seconds;
    } else if (code.startsWith('at most ') && m.modes.image) {
      const keep = m.frames.middle;
      if (r.frames?.middle) r.frames = { ...r.frames, middle: r.frames.middle.slice(0, keep) };
      if (r.camera?.guide?.keyframes?.middle) r.camera = { ...r.camera, guide: { ...r.camera.guide, keyframes: { ...r.camera.guide.keyframes, middle: r.camera.guide.keyframes.middle.slice(0, keep) } } };
      notes.push(keep ? `kept the first ${keep} middle frame${keep > 1 ? 's' : ''} (${name} takes ${keep})` : `middle frames left out (${name} takes none)`); adapted.push('middle_trimmed');
    } else if (code === 'no keyframes' || code === 'no audio with keyframes' || code.startsWith('at most ')) {
      if (!m.modes.reference || m.refs.images < 1) return { request: r, resolution: res, need: n, notes, adapted, why };
      r = framesAsRefs(r);
      notes.push(`${name} can't start from a frame: your frames are sent as reference images and the prompt opens on them`); adapted.push('frames_as_refs');
    } else if (code === 'too many reference images') {
      const room = Math.max(0, m.refs.images - (n.mode === 'reference' && character?.images.length ? 1 : 0));
      if (room < 1) return { request: r, resolution: res, need: n, notes, adapted, why };
      const list = r.references?.images ?? [];
      const out = list.slice(room);
      r.references = { ...r.references, images: list.slice(0, room) };
      notes.push(`${out.length} reference image${out.length > 1 ? 's' : ''} left out (${name} takes ${m.refs.images}): ${out.map(x => x.label ?? x.role).join(', ')}`); adapted.push('refs_trimmed');
    } else if (code === 'no reference videos') {
      if (m.refs.videos < 1) return { request: r, resolution: res, need: n, notes, adapted, why };
      const list = r.references?.videos ?? [];
      r.references = { ...r.references, videos: list.slice(0, m.refs.videos) };
      notes.push(`${list.length - m.refs.videos} reference video${list.length - m.refs.videos > 1 ? 's' : ''} left out (${name} takes ${m.refs.videos})`); adapted.push('videos_trimmed');
    } else if (code === 'audio needs an image or video reference') {
      // Her own images count; else there is nothing to send with the audio.
      if (!character?.images.length || !m.modes.reference || m.refs.images < 1) return { request: r, resolution: res, need: n, notes, adapted, why };
      r.mode = 'reference'; adapted.push('reference_mode');
    } else return { request: r, resolution: res, need: n, notes, adapted, why };
  }
  const n = needOf(r, character);
  return { request: r, resolution: res, need: n, notes, adapted, why: misfits(m, res, n).why };
}

/** Start/middle/end frames (the request's or the Camera stage's keyframes) as reference images, opening frame first. */
export function framesAsRefs(r0: ShotRequest): ShotRequest {
  const r: ShotRequest = structuredClone(r0);
  const f = r.frames ?? {}, kf = r.camera?.guide?.keyframes;
  const start = f.start ?? (kf?.start ? { url: kf.start } : undefined), end = f.end ?? (kf?.end ? { url: kf.end } : undefined);
  const middle = f.middle?.length ? f.middle : (kf?.middle ?? []).map(url => ({ url }));
  type Ref = NonNullable<NonNullable<ShotRequest['references']>['images']>[number];
  const frames: Ref[] = [
    ...(start ? [{ image: start, role: 'frame' as const, label: 'opening frame' }] : []),
    ...(end ? [{ image: end, role: 'frame' as const, label: 'end frame' }] : []),
    ...middle.map((image, i) => ({ image, role: 'frame' as const, label: `middle frame ${i + 1}` })),
  ];
  r.references = { ...r.references, images: [...frames, ...(r.references?.images ?? [])] };
  delete r.frames;
  if (r.camera?.guide?.keyframes) { const { keyframes: _k, ...g } = r.camera.guide; r.camera = { ...r.camera, guide: g as typeof r.camera.guide }; }
  r.mode = 'reference';
  return r;
}

export type Pick = { model: ModelSpec; resolution: Resolution; seconds: number; tried: { model: string; resolution: string; why: string }[] };

type PickOpts = { prefs?: SuitePrefs; providers: Set<ProviderId>; engineModel?: string; resolution?: string; studioId?: string };
const ladderOf = (tier: Tier, o: PickOpts): LadderStep[] => o.engineModel
  ? [{ model: o.engineModel, resolution: o.resolution ?? modelById(o.engineModel)?.resolutions.at(-1)?.id ?? '' }]
  : o.prefs?.ladder?.[tier]?.length ? o.prefs.ladder[tier]! : DEFAULT_LADDER[tier];
/** Why a ladder step can't be used in this studio at all (before looking at the shot), or null. */
function unusable(step: LadderStep, o: PickOpts): { m?: ModelSpec; why: string | null } {
  const m = modelById(step.model);
  if (!m || (m.byo && m.byo.studioId !== o.studioId)) return { why: 'unknown model' };
  const pref = o.prefs?.models?.[m.id];
  if (pref?.enabled === false) return { m, why: 'switched off' };
  if (m.licence.requiresAck && !pref?.acknowledgedAt) return { m, why: 'licence not acknowledged' };
  if (!o.providers.has(m.provider)) return { m, why: `${m.provider} not set up` };
  return { m, why: null };
}

/** The model for a tier: the first ladder step that is allowed, set up and fits. */
export function pickModel(tier: Tier, n: Need, o: PickOpts): Pick | { error: string; tried: Pick['tried'] } {
  const tried: Pick['tried'] = [];
  for (const step of ladderOf(tier, o)) {
    const u = unusable(step, o);
    if (u.why) { tried.push({ ...step, why: u.why }); continue; }
    const m = u.m!;
    const f = fit(m, step.resolution, n);
    if (f.why) { tried.push({ ...step, why: f.why }); continue; }
    return { model: m, resolution: m.resolutions.find(x => x.id === step.resolution)!, seconds: f.seconds, tried };
  }
  return { error: 'nothing_fits', tried };
}

/** Why one model refused, in member-safe words. */
export type Refusal = { model: string; name: string; reasons: string[] };
/**
 * "Adapt, don't block": like pickModel, but each step may change the request (adaptRequest) so the model can make it.
 * Used after a strict pick fails. On failure, every step's reasons in plain words.
 */
export function pickAdapted(tier: Tier, r: ShotRequest, character: Character | null, o: PickOpts): { pick: Pick; adapted: Adapted } | { error: 'nothing_fits'; tried: Pick['tried']; refusals: Refusal[] } {
  const tried: Pick['tried'] = [], refusals: Refusal[] = [];
  for (const step of ladderOf(tier, o)) {
    const u = unusable(step, o);
    if (u.why) {
      tried.push({ ...step, why: u.why });
      if (u.m) refusals.push({ model: u.m.id, name: modelName(u.m), reasons: [whyWords(u.why, u.m)] });
      continue;
    }
    const m = u.m!;
    const a = adaptRequest(m, step.resolution, r, character);
    if (a.why.length) {
      tried.push({ ...step, why: a.why[0]! });
      refusals.push({ model: m.id, name: modelName(m), reasons: [...new Set(a.why.map(w => whyWords(w, m, a.need)))] });
      continue;
    }
    return { pick: { model: m, resolution: m.resolutions.find(x => x.id === a.resolution)!, seconds: fit(m, a.resolution, a.need).seconds, tried }, adapted: a };
  }
  return { error: 'nothing_fits', tried, refusals };
}

/** "MiniMax H3 · Higgsfield: can't use a start frame; length must be 5–15 s" */
export const refusalLine = (x: Refusal) => `${x.name}: ${x.reasons.join('; ')}`;

/** Which endpoint kind a plan calls. */
export const kindOf = (m: ModelSpec, n: Need): 't2v' | 'i2v' | 'ref2v' | 'guide' =>
  m.adapter === 'fal-h3-3d' ? 'guide' : n.mode === 'image' ? 'i2v' : n.mode === 'reference' || n.videos > 0 || n.extraImages > 0 || (n.guide && m.camera.referenceVideo) ? 'ref2v' : 't2v';

/** Dollars per output second on this model and resolution for this shot. */
export function perSecond(m: ModelSpec, res: Resolution, o: { videoInput: boolean; audio: boolean; kind: string }) {
  if (m.id === 'wan-2.7' && o.kind === 'i2v' && res.id === '1080p') return 0.15;
  if (o.videoInput && res.perSecWithVideo != null) return res.perSecWithVideo;
  if (o.audio && m.audio === 'flag' && res.audioPerSec != null) return res.audioPerSec;
  return res.perSec;
}
/** Seconds the provider bills for one take. */
export function billedSeconds(m: ModelSpec, seconds: number, o: { videoInput: boolean; guideSeconds?: number }) {
  let s = Math.max(seconds, m.duration.minBilled ?? 0);
  // Kling 4.0 with a video input bills the output plus the longer of the inputs or the output.
  if (m.id === 'kling-v4' && o.videoInput) s = seconds + Math.max(o.guideSeconds ?? seconds, seconds);
  return s;
}
/** Fixed extra per take (fal H3 Max reference tokens, an estimate). */
/** Higgsfield H3: the first 5 reference images are included, each further one costs $0.08 per take. */
/** An owner-added model priced per run (WS5): its per-run cost. */
export const extraPerTake = (m: ModelSpec, refImages = 0) => (m.adapter === 'fal-h3-3d' ? 0.5 : m.adapter === 'hf-h3' ? 0.08 * Math.max(0, refImages - 5) : m.byo ? m.byo.perRunUsd : 0);

export type ImagePlan = { start?: ImageRef; middle: ImageRef[]; end?: ImageRef; refs: { label: string; role: string; image: ImageRef }[] };
export type ShotPlan = {
  tier: Tier; mode: Need['mode'] | 'recast' | 'extend'; modelId: string; provider: ProviderId; ref: string; kind: 't2v' | 'i2v' | 'ref2v' | 'guide'; resolution: string;
  seconds: number; aspect: string; audio: boolean; takes: number; seed?: number; prompt: string; negative?: string; params: Record<string, unknown>;
  images: ImagePlan; videos: { video: VideoRef; use: string }[];
  /** The audio reference and whether only its instrumental is sent (performer not speaking). */
  audioRef?: { ref: VideoRef; beatOnly: boolean }; promptNoAudio?: string; speaking: boolean; separationUsd: number; perSec: number; billedPerTake: number; extraPerTake: number; estimate: number;
  camera: Pick_<CompiledCamera, 'moves' | 'notes' | 'usesGuide'>; notes: string[];
  /** Recast only: keep the source sound (put back by stream copy when the model doesn't), and who became whom. */
  /** Extend only: how the source is used and how the take is assembled (the runner prepares the media). */
  extend?: { direction: 'after' | 'before'; method: 'clip' | 'reference' | 'frame'; source: { key: string; seconds: number }; join: boolean;
    /** Send only this many seconds from the source's end (after) or start (before). */ useSeconds: number };
  recast?: { keepAudio: boolean; restoreAudio: boolean; people: { characterId: string; outfitId?: string; who: string; speaking: 'yes' | 'no' | 'unknown' }[] };
  /** The reference images sent (images/sent.ts), automatic or chosen, for the estimate. */
  sentImages?: SentView;
  /** What MUSE changed so the model could make it (adaptRequest codes: frames_as_refs, length:15, aspect:16:9, …). */
  adapted?: string[];
};
type Pick_<T, K extends keyof T> = { [P in K]: T[P] };

export const token = (style: ModelSpec['camera']['refStyle'], kind: 'image' | 'video', i: number) =>
  style === 'photo' ? (kind === 'image' ? `reference photo ${i}` : `the source video`) : style === 'at' ? `@${kind}_${i}` : style === 'triple' ? `<<<${kind}_${i}>>>` : style === 'bracket' ? `[${kind === 'image' ? 'Image' : 'Video'}${i}]` : `<${kind === 'image' ? 'Image' : 'Video'} ${i}>`;
export const joinTokens = (t: string[]) => (t.length <= 1 ? t.join('') : `${t.slice(0, -1).join(', ')} and ${t.at(-1)}`);
const ROLE_WORDS: Record<string, [string, string]> = {
  product: ['the product', 'shape, colours, packaging and label'], location: ['the location', 'place, layout and light'], style: ['a style reference', 'colour, mood and texture'],
  prop: ['a prop', 'shape and colour'], person: ['another person in the scene', 'appearance and clothing'],
  // workstream 1: references the owner attaches in the Claude chat. Her identity comes only from her own images.
  pose: ['a pose reference', 'body pose, gesture and framing, never the face, body or clothing of anyone in it'],
  frame: ['a frame of this shot', 'composition, framing, setting and light'],
  outfit: ['an outfit reference', 'the clothes (cut, fabric, colour), never the face or body of anyone wearing them'],
};

/** Builds the whole plan for a picked model. */
export function buildPlan(r: ShotRequest, n: Need, p: Pick, character: Character | null, o: { texts?: PromptTexts; priceScale?: number; speaking?: boolean; separationUsd?: number; sent?: Resolved | null }): ShotPlan {
  const t = o.texts ?? DEFAULT_TEXTS;
  const m = p.model, notes: string[] = [];
  let kind = kindOf(m, n);
  const cam = compileCamera(r.camera, m, { texts: t, durationS: p.seconds, talking: o.speaking ?? r.speaking ?? false });
  if (p.seconds !== r.duration) notes.push(`length set to ${p.seconds} s (this quality makes ${m.duration.allowed?.join(', ') ?? `${m.duration.min}–${m.duration.max}`} s)`);

  // ---- images: keyframes, then the character subset, then extra references, within the model's limits
  const f = r.frames ?? {};
  // The Camera stage's guide keyframes are hints (needOf): real start/end/middle frames only on a model that takes them
  // together with references on one endpoint; otherwise they go as reference images in the room left (below).
  const kf = f.start || f.end || f.middle?.length ? undefined : r.camera?.guide?.keyframes;
  const kfAsFrames = !!kf && m.modes.image && m.frames.withRefs && typeof m.ref === 'string';
  const images: ImagePlan = { middle: [], refs: [] };
  if (n.mode === 'image' || n.mode === 'reference') {
    if (m.frames.start) images.start = f.start;
    if (m.frames.end) images.end = f.end;
    if (m.frames.middle) images.middle = (f.middle ?? []).slice(0, m.frames.middle);
  }
  const kfLeft: { label: string; role: string; image: ImageRef }[] = [];
  if (kf) {
    if (kf.start) { if (kfAsFrames && m.frames.start) images.start = { url: kf.start }; else kfLeft.push({ label: 'opening frame', role: 'frame', image: { url: kf.start } }); }
    if (kf.end) { if (kfAsFrames && m.frames.end) images.end = { url: kf.end }; else kfLeft.push({ label: 'end frame', role: 'frame', image: { url: kf.end } }); }
    (kf.middle ?? []).forEach((url, i) => { if (kfAsFrames && i < m.frames.middle) images.middle.push({ url }); else kfLeft.push({ label: `middle frame ${i + 1}`, role: 'frame', image: { url } }); });
  }
  const framesUsed = (images.start ? 1 : 0) + (images.end ? 1 : 0) + images.middle.length;
  const hasFrames = framesUsed > 0;
  let room = m.refs.images;
  if (m.refs.totalImages) room = Math.min(room, m.refs.totalImages - framesUsed);
  // Kling 3.0 Omni: at most 4 images with a reference video.
  const videoCount = (n.videos) + (cam.usesGuide ? 1 : 0);
  if (m.id === 'kling-v3-omni' && videoCount > 0) room = Math.min(room, 4);
  if (hasFrames && !m.frames.withRefs) { room = 0; if (character?.images.length || n.extraImages) notes.push('keyframes carry the look on this quality: character and extra references are not sent'); }
  const extra = (r.references?.images ?? []).map((x, i) => ({ label: x.label ?? `${x.role} ${i + 1}`, role: x.role, image: x.image as ImageRef }));
  const extraFit = extra.slice(0, Math.max(0, room - (n.mode === 'reference' && character?.images.length ? 1 : 0)));
  if (extraFit.length < extra.length && room > 0) notes.push(`${extra.length - extraFit.length} extra reference image(s) left out (limit ${m.refs.images})`);
  const charRoom = Math.max(0, room - extraFit.length);
  const charImgs = n.mode !== 'text' && character ? [...character.images, ...(character.outfit?.images ?? [])] : [];
  // Priority: face, profile, outfit front (or body front), then the rest in sheet order.
  const prio = (l: string) => ['face, front', 'outfit, front', 'face, profile', 'body, front', 'outfit, ¾', 'body, ¾', 'face, ¾', 'outfit, back', 'body, back', 'outfit, side', 'body, side'].indexOf(l);
  const chosen = [...charImgs].sort((a, b) => (prio(a.label) < 0 ? 99 : prio(a.label)) - (prio(b.label) < 0 ? 99 : prio(b.label))).slice(0, charRoom);
  // Keep the sheet's order in what is sent (face first).
  const charSent = charImgs.filter(x => chosen.includes(x));
  images.refs = [...charSent.map(x => ({ label: x.label, role: 'character', image: x.image })), ...extraFit];
  if (charImgs.length > charSent.length && charRoom > 0) notes.push(`${charImgs.length - charSent.length} character image(s) left out (limit ${m.refs.images})`);
  // Guide keyframes the model can't take as frames: reference images in the room left (her images and yours come first).
  if (kfLeft.length) {
    const fits = kfLeft.slice(0, Math.max(0, room - images.refs.length));
    images.refs.push(...fits);
    if (fits.length < kfLeft.length) notes.push(fits.length ? `${kfLeft.length - fits.length} guide still${kfLeft.length - fits.length > 1 ? 's' : ''} left out (no room for more images); the guide clip carries the blocking`
      : `the guide stills aren't sent on this model; ${cam.usesGuide ? 'the guide clip carries the blocking' : 'the camera is described in words'}`);
  }
  // Images sent (images/sent.ts): the choice replaces or adjusts MUSE's pick, within the model's room; "Image n" follows it.
  const sentImages = applySent(images.refs.map(planRefSent), o.sent, room);
  if (sentImages.changed) images.refs = sentImages.images.map(x => sentPlanRef(x, charImgs));

  // Guide stills sent as references or frames: the matching endpoint.
  if (kind === 't2v' && images.refs.length) kind = 'ref2v';
  else if (kind === 't2v' && (images.start || images.end)) kind = 'i2v';

  // ---- videos: the guide clip first, then extra reference videos
  const videos: ShotPlan['videos'] = [];
  if (cam.usesGuide && r.camera?.guide) videos.push({ video: r.camera.guide.video, use: r.camera.guide.use });
  for (const v of r.references?.videos ?? []) if (videos.length < m.refs.videos) videos.push({ video: v.video, use: v.use });

  // ---- audio: speech goes as is; music without speaking goes as its instrumental (separated when the job runs)
  const speaking = o.speaking ?? r.speaking ?? false;
  const audioRef = r.references?.audio?.audio;
  const audioPlan = audioRef && m.refs.audios > 0 ? { ref: audioRef, beatOnly: !speaking } : undefined;
  if (audioRef && !audioPlan) notes.push('this quality takes no reference audio: the audio is not sent');

  // ---- prompt: the suite.shot script (owner-editable rules and blocks); the user's words only in its scene section
  const style = m.camera.refStyle;
  const named = style !== 'none';
  const charTokens = images.refs.map((x, i) => (x.role === 'character' && !x.label.startsWith('outfit') ? token(style, 'image', i + 1) : '')).filter(Boolean);
  const outfitTokens = images.refs.map((x, i) => (x.role === 'character' && x.label.startsWith('outfit') ? token(style, 'image', i + 1) : '')).filter(Boolean);
  const refItems = images.refs.map((x, i) => ({ x, i })).filter(({ x }) => x.role !== 'character' && x.role !== 'frame').map(({ x, i }) => {
    const [role, use] = ROLE_WORDS[x.role] ?? ROLE_WORDS.product!;
    return { kind: x.role, ref: named ? token(style, 'image', i + 1) : x.label, role: x.label && !x.label.startsWith(x.role) ? `${role} (${x.label})` : role, use };
  });
  const VIDEO_USE: Record<string, string> = { camera: 'camera movement and framing', blocking: 'camera movement, framing, blocking and positions', style: 'style and pacing', motion: 'motion and timing' };
  const videoItems = videos.map((v, i) => ({ kind: v.use, video: named ? token(style, 'video', i + 1) : 'the reference video', use: VIDEO_USE[v.use] ?? VIDEO_USE.motion! }));
  const avoid = !m.negativePrompt && cam.avoid.length ? cam.avoid.map(a => a.charAt(0).toUpperCase() + a.slice(1)).join('. ') + '.' : '';
  const ident = character ? { name: character.name, look: character.look, neverAdd: character.neverAdd } : null;
  // AI suite (workstream 1): `#Move` text is a chip, not prose (stripMoveTokens).
  const userWords = stripMoveTokens([r.prompt, r.direction].map(x => (x ?? '').trim()).filter(Boolean).join(' '), cam.moves);
  const { clean, removed } = ident ? sanitizeDirection(userWords, ident, t) : { clean: userWords, removed: [] as string[] };
  if (removed.length) notes.push(`left out of the scene (it would change her look): ${removed.join('; ')}`);
  const audioSent: 'speech' | 'music' | 'none' = audioPlan ? (speaking ? 'speech' : 'music') : 'none';
  const shotPrompt = (audioSent: 'speech' | 'music' | 'none') => run('suite.shot', t, {
    inputs: {
      hasCharacter: !!character, characterImages: !!character && charTokens.length > 0 && named, hasOutfit: !!character?.outfit,
      refs: refItems, mixedRoles: new Set(images.refs.map(x => x.role)).size > 1 || images.refs.some(x => x.role === 'person'), hasFrames,
      videos: videoItems, hasCamera: !!cam.text, audio: audioSent, speaking, hasAvoid: !!avoid,
    },
    vars: {
      name: character?.name ?? '', look: character?.look ?? '', refs: joinTokens(charTokens), never: character?.neverAdd.length ? ` She never has: ${character.neverAdd.join(', ')}.` : '',
      outfit: character?.outfit ? character.outfit.description || character.outfit.name : '', outfitRefs: outfitTokens.length && named ? ` as shown in ${joinTokens(outfitTokens)}` : '',
      start: images.start ? 'the start frame' : 'its first frame',
      middle: images.middle.length ? `, passes through the ${images.middle.length} middle keyframe${images.middle.length > 1 ? 's' : ''} in order` : '',
      end: images.end ? ' and ends exactly on the end frame' : '',
      camera: cam.text ? (cam.text.endsWith('.') ? cam.text : `${cam.text}.`) : '',
      subject: character?.name ?? 'The person', audio: style === 'bracket' ? '[Audio1]' : '<Audio 1>', avoid,
    },
    direction: clean,
  }).text;
  // Frames sent as references (adaptRequest): "Open on image n" / "End like image n".
  const frameLines = images.refs.map((x, i) => (x.role !== 'frame' ? '' : x.label === 'opening frame' ? `Open on ${named ? token(style, 'image', i + 1) : `image ${i + 1}`}.`
    : x.label === 'end frame' ? `End like ${named ? token(style, 'image', i + 1) : `image ${i + 1}`}.` : `Pass through ${named ? token(style, 'image', i + 1) : `image ${i + 1}`} on the way.`)).filter(Boolean).join(' ');
  const withFrames = (text: string) => (frameLines ? `${text.trimEnd()}\n${frameLines}` : text);
  let prompt = withFrames(shotPrompt(audioSent));
  // Beat-only shots also carry the prompt for "no audio sent": used when the vocals can't be removed (the separator is
  // off or returned nothing), because sending the original track would let the model sing or lip-sync to it.
  let promptNoAudio = audioPlan?.beatOnly ? withFrames(shotPrompt('none')) : undefined;
  if (promptNoAudio && m.promptMax && promptNoAudio.length > m.promptMax) promptNoAudio = promptNoAudio.slice(0, m.promptMax);
  const negList = [...listOf(t['suite.shot.negative'] ?? ''), ...cam.avoid.map(a => a.replace(/^no\s+/i, ''))];
  if (m.promptMax && prompt.length > m.promptMax) { prompt = prompt.slice(0, m.promptMax); notes.push('prompt shortened to fit'); }

  // ---- price
  const videoInput = videos.length > 0;
  const perSec = perSecond(m, p.resolution, { videoInput, audio: r.audio, kind }) * (o.priceScale ?? 1);
  const guideSeconds = videos[0]?.video.seconds;
  const billed = billedSeconds(m, p.seconds, { videoInput, guideSeconds });
  const extraCost = extraPerTake(m, images.refs.length) * (m.byo ? o.priceScale ?? 1 : 1); // WS5: a custom model's per-run price takes its markup too
  const separation = audioPlan?.beatOnly ? o.separationUsd ?? 0 : 0;
  const estimate = Math.round(((perSec * billed + extraCost) * r.takes + separation) * 10000) / 10000;

  return {
    tier: r.quality, mode: n.mode, modelId: m.id, provider: m.provider, ref: refFor(m, kind), kind, resolution: p.resolution.id, seconds: p.seconds, aspect: r.aspectRatio,
    audio: r.audio && m.audio !== 'none', takes: r.takes, seed: m.seed ? r.seed : undefined, prompt, negative: m.negativePrompt ? negList.join(', ') : undefined, params: cam.params,
    images, videos, audioRef: audioPlan, promptNoAudio, speaking, separationUsd: separation, perSec, billedPerTake: billed, extraPerTake: extraCost, estimate,
    camera: { moves: cam.moves, notes: cam.notes, usesGuide: cam.usesGuide }, notes, sentImages,
  };
}

const PLAN_ROLES: Record<string, SentRole> = { frame: 'other', product: 'product', location: 'location', style: 'style', pose: 'pose', outfit: 'outfit', person: 'other', prop: 'other', crop: 'other' };
/** A plan's reference as the estimate shows it. */
export function planRefSent(x: { label: string; role: string; image: ImageRef }): SentImage {
  if (x.role === 'character') { const role = roleOfLabel(x.label, 'person'); return { image: x.image, role, label: x.label.replace(/^person \d+ · /, ''), why: whyOf(x.label.replace(/^person \d+ · /, ''), role) }; }
  return { image: x.image, role: PLAN_ROLES[x.role] ?? 'other', label: x.label, why: x.role === 'crop' ? 'the face to recast in the clip' : x.role === 'frame' ? `your ${x.label} (sent as a reference)` : `your ${x.role} reference${x.label && !x.label.startsWith(x.role) ? ` (${x.label})` : ''}` };
}
/** A chosen image as a plan reference: one of her own images keeps its sheet label (the prompt names her images and the
 * outfit's apart); a person or outfit image of hers otherwise is labelled by its role; the rest are extra references. */
export function sentPlanRef(x: SentImage, own: { label: string; image: ImageRef }[]): { label: string; role: string; image: ImageRef } {
  const mine = own.find(c => sameImage(c.image, x.image));
  if (mine) return { label: mine.label, role: 'character', image: x.image };
  if (x.role === 'person') return { label: /^(face|body)/.test(x.label) ? x.label : `body, ${x.label}`, role: 'character', image: x.image };
  if (x.role === 'outfit') return { label: x.label.startsWith('outfit') ? x.label : `outfit, ${x.label}`, role: own.length ? 'character' : 'outfit', image: x.image };
  if (x.role === 'other' && /^(opening|end|middle) frame/.test(x.label)) return { label: x.label, role: 'frame', image: x.image };
  return { label: x.label, role: x.role === 'other' ? 'prop' : x.role, image: x.image };
}

/** "Video · Shot · HD 1080p · 5 s" (ledger) / "Shot · HD · 1080p" (job label). Never names a model. */
export const shotLabel = (tier: Tier, resolution: string, kind: 'Shot' | 'Recast' | 'Extend' = 'Shot') => `${kind} · ${TIER_INFO[tier].label} · ${/^\d+$/.test(resolution) ? `${resolution}p` : resolution.replace(/P$/, 'p')}`;
export const shotNote = (tier: Tier, resolution: string, seconds: number[], kind: 'Shot' | 'Recast' | 'Extend' = 'Shot') => {
  const fmt = (v: number) => String(Math.round(v * 10) / 10);
  const s = seconds.length > 1 ? (seconds.every(v => v === seconds[0]) ? `${seconds.length} × ${fmt(seconds[0]!)} s` : `${fmt(seconds.reduce((a, b) => a + b, 0))} s`) : `${fmt(seconds[0] ?? 0)} s`;
  return `Video · ${kind} ${TIER_INFO[tier].label} ${/^\d+$/.test(resolution) ? `${resolution}p` : resolution.replace(/P$/, 'p')} · ${s}`;
};
