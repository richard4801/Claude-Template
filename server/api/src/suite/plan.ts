// AI suite · planning a shot: request schema, model selection on the quality ladder, the character's reference subset,
// the prompt, provider inputs and the cost. Pure functions (no database), so the estimate, the job and the tests agree.
import { z } from 'zod';
import type { ImageRef } from '../db/schema.js';
import { DEFAULT_TEXTS, listOf, type PromptTexts } from '../prompt/library.js';
import { sanitizeDirection } from '../prompt/engine.js';
import { run } from '../prompt/scripts/builders.js';
import { CameraSpecSchema, VideoRefSchema, type VideoRef } from './camera.js';
import { compileCamera, type CompiledCamera } from './compile.js';
import { DEFAULT_LADDER, modelById, refFor, TIER_INFO, TIERS, type LadderStep, type ModelSpec, type ProviderId, type Resolution, type ShotMode, type Tier } from './registry.js';

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
  mode: z.enum(['text', 'image', 'reference', 'swap', 'recast']).optional(),
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
    images: z.array(z.object({ image: ImageRefSchema, role: z.enum(['product', 'location', 'style', 'prop', 'person']).default('product'), label: z.string().max(80).optional() })).max(6).optional(),
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
}).strict();
export type ShotRequest = z.infer<typeof ShotRequestSchema>;

export type ModelPrefs = Record<string, { enabled?: boolean; acknowledgedAt?: number | null; priceScale?: number }>;
export type SuitePrefs = { models?: ModelPrefs; ladder?: Partial<Record<Tier, LadderStep[]>>; capPerJob?: number | null; capPerDay?: number | null };

export type Character = { name: string; look: string; neverAdd: string[]; images: { label: string; image: ImageRef }[]; outfit?: { name: string; description?: string; images: { label: string; image: ImageRef }[] } | null };

export type Need = {
  mode: Exclude<ShotMode, 'swap'>; start: boolean; end: boolean; middle: number; characterImages: number; extraImages: number; videos: number; guide: boolean;
  directed: boolean; duration: number; aspect: string; withAudio: boolean; audioRef: boolean;
};

/** The shot's needs, from the request. */
export function needOf(r: ShotRequest, character: Character | null): Need {
  const f = r.frames ?? {};
  const keyframes = r.camera?.guide?.keyframes;
  const start = !!(f.start || keyframes?.start), end = !!(f.end || keyframes?.end), middle = (f.middle?.length ?? 0) || (keyframes?.middle?.length ?? 0);
  const mode = (r.mode as Need['mode'] | undefined) ?? (start || end ? 'image' : character?.images.length ? 'reference' : 'text');
  return { mode, start, end, middle, characterImages: mode === 'text' ? 0 : character?.images.length ?? 0, extraImages: r.references?.images?.length ?? 0,
    videos: r.references?.videos?.length ?? 0, guide: !!r.camera?.guide, directed: r.camera?.mode === 'directed', duration: r.duration, aspect: r.aspectRatio, withAudio: r.audio, audioRef: !!r.references?.audio };
}

/** Why `m` at `resolution` can't make this shot, or null. Also the duration it would render. */
export function fit(m: ModelSpec, resolution: string, n: Need): { why: string | null; seconds: number } {
  let seconds = Math.max(m.duration.min, Math.min(n.duration, m.duration.max));
  if (m.duration.allowed) seconds = m.duration.allowed.reduce((p, c) => (Math.abs(c - n.duration) < Math.abs(p - n.duration) || (Math.abs(c - n.duration) === Math.abs(p - n.duration) && c > p) ? c : p));
  const no = (why: string) => ({ why, seconds });
  if (m.status === 'removed') return no('removed');
  if (m.licence.blockNewFeatures) return no('licence');
  if (!m.resolutions.some(x => x.id === resolution)) return no(`no ${resolution}`);
  if (n.duration > m.duration.max || n.duration < m.duration.min - 1) return no(`length ${m.duration.min}–${m.duration.max} s`);
  if (!m.aspectRatios.includes(n.aspect)) return no(`no ${n.aspect}`);
  if (n.directed && !(m.modes.guide || m.camera.referenceVideo)) return no('no guide clip');
  if (n.mode === 'text' && !m.modes.text) return no('no text-to-video');
  if (n.mode === 'image') {
    if (!m.modes.image || (n.start && !m.frames.start) || (n.end && !m.frames.end)) return no('no keyframes');
    if (n.middle > m.frames.middle) return no(`at most ${m.frames.middle} middle frames`);
  }
  if (n.mode === 'reference' && (!m.modes.reference || m.refs.images < 1)) return no('no reference images');
  if (n.videos > m.refs.videos) return no('no reference videos');
  if (n.audioRef && m.refs.audios < 1) return no('no reference audio');
  // Reference audio rides with an image or video reference (Seedance and H3 Lite require it; safest everywhere).
  if (n.audioRef && n.mode === 'text' && !n.extraImages && !n.videos && !n.guide) return no('audio needs an image or video reference');
  if (n.audioRef && n.mode === 'image' && !m.frames.withRefs) return no('no audio with keyframes');
  if (n.extraImages > 0 && m.refs.images < n.extraImages + (n.mode === 'reference' ? 1 : 0) && !(n.mode === 'image' && !m.frames.withRefs)) return no('too many reference images');
  if (m.id === 'veo-3.1-lite' && resolution === '1080p' && seconds !== 8) return no('1080p only at 8 s');
  return { why: null, seconds };
}

export type Pick = { model: ModelSpec; resolution: Resolution; seconds: number; tried: { model: string; resolution: string; why: string }[] };

/** The model for a tier: the first ladder step that is allowed, set up and fits. */
export function pickModel(tier: Tier, n: Need, o: { prefs?: SuitePrefs; providers: Set<ProviderId>; engineModel?: string; resolution?: string }): Pick | { error: string; tried: Pick['tried'] } {
  const ladder: LadderStep[] = o.engineModel
    ? [{ model: o.engineModel, resolution: o.resolution ?? modelById(o.engineModel)?.resolutions.at(-1)?.id ?? '' }]
    : o.prefs?.ladder?.[tier]?.length ? o.prefs.ladder[tier]! : DEFAULT_LADDER[tier];
  const tried: Pick['tried'] = [];
  for (const step of ladder) {
    const m = modelById(step.model);
    if (!m) { tried.push({ ...step, why: 'unknown model' }); continue; }
    const pref = o.prefs?.models?.[m.id];
    if (pref?.enabled === false) { tried.push({ ...step, why: 'switched off' }); continue; }
    if (m.licence.requiresAck && !pref?.acknowledgedAt) { tried.push({ ...step, why: 'licence not acknowledged' }); continue; }
    if (!o.providers.has(m.provider)) { tried.push({ ...step, why: `${m.provider} not set up` }); continue; }
    const f = fit(m, step.resolution, n);
    if (f.why) { tried.push({ ...step, why: f.why }); continue; }
    return { model: m, resolution: m.resolutions.find(x => x.id === step.resolution)!, seconds: f.seconds, tried };
  }
  return { error: 'nothing_fits', tried };
}

/** Which endpoint kind a plan calls. */
export const kindOf = (m: ModelSpec, n: Need): 't2v' | 'i2v' | 'ref2v' | 'guide' =>
  m.adapter === 'fal-h3-3d' ? 'guide' : n.mode === 'image' ? 'i2v' : n.mode === 'reference' || n.videos > 0 ? 'ref2v' : 't2v';

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
export const extraPerTake = (m: ModelSpec) => (m.adapter === 'fal-h3-3d' ? 0.5 : 0);

export type ImagePlan = { start?: ImageRef; middle: ImageRef[]; end?: ImageRef; refs: { label: string; role: string; image: ImageRef }[] };
export type ShotPlan = {
  tier: Tier; mode: Need['mode'] | 'recast'; modelId: string; provider: ProviderId; ref: string; kind: 't2v' | 'i2v' | 'ref2v' | 'guide'; resolution: string;
  seconds: number; aspect: string; audio: boolean; takes: number; seed?: number; prompt: string; negative?: string; params: Record<string, unknown>;
  images: ImagePlan; videos: { video: VideoRef; use: string }[];
  /** The audio reference and whether only its instrumental is sent (performer not speaking). */
  audioRef?: { ref: VideoRef; beatOnly: boolean }; promptNoAudio?: string; speaking: boolean; separationUsd: number; perSec: number; billedPerTake: number; extraPerTake: number; estimate: number;
  camera: Pick_<CompiledCamera, 'moves' | 'notes' | 'usesGuide'>; notes: string[];
  /** Recast only: keep the source sound (put back by stream copy when the model doesn't), and who became whom. */
  recast?: { keepAudio: boolean; restoreAudio: boolean; people: { characterId: string; outfitId?: string; who: string; speaking: 'yes' | 'no' | 'unknown' }[] };
};
type Pick_<T, K extends keyof T> = { [P in K]: T[P] };

export const token = (style: ModelSpec['camera']['refStyle'], kind: 'image' | 'video', i: number) =>
  style === 'photo' ? (kind === 'image' ? `reference photo ${i}` : `the source video`) : style === 'at' ? `@${kind}_${i}` : style === 'triple' ? `<<<${kind}_${i}>>>` : style === 'bracket' ? `[${kind === 'image' ? 'Image' : 'Video'}${i}]` : `<${kind === 'image' ? 'Image' : 'Video'} ${i}>`;
export const joinTokens = (t: string[]) => (t.length <= 1 ? t.join('') : `${t.slice(0, -1).join(', ')} and ${t.at(-1)}`);
const ROLE_WORDS: Record<string, [string, string]> = {
  product: ['the product', 'shape, colours, packaging and label'], location: ['the location', 'place, layout and light'], style: ['a style reference', 'colour, mood and texture'],
  prop: ['a prop', 'shape and colour'], person: ['another person in the scene', 'appearance and clothing'],
};

/** Builds the whole plan for a picked model. */
export function buildPlan(r: ShotRequest, n: Need, p: Pick, character: Character | null, o: { texts?: PromptTexts; priceScale?: number; speaking?: boolean; separationUsd?: number }): ShotPlan {
  const t = o.texts ?? DEFAULT_TEXTS;
  const m = p.model, notes: string[] = [];
  const kind = kindOf(m, n);
  const cam = compileCamera(r.camera, m, { texts: t, durationS: p.seconds, talking: o.speaking ?? r.speaking ?? false });
  if (p.seconds !== r.duration) notes.push(`length set to ${p.seconds} s (this quality makes ${m.duration.allowed?.join(', ') ?? `${m.duration.min}–${m.duration.max}`} s)`);

  // ---- images: keyframes, then the character subset, then extra references, within the model's limits
  const f = r.frames ?? {};
  const kf = r.camera?.guide?.keyframes;
  const images: ImagePlan = { middle: [], refs: [] };
  if (n.mode === 'image' || n.mode === 'reference') {
    if (m.frames.start) images.start = f.start ?? (kf?.start ? { url: kf.start } : undefined);
    if (m.frames.end) images.end = f.end ?? (kf?.end ? { url: kf.end } : undefined);
    if (m.frames.middle) images.middle = (f.middle ?? kf?.middle?.map(url => ({ url })) ?? []).slice(0, m.frames.middle);
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
  const refItems = images.refs.map((x, i) => ({ x, i })).filter(({ x }) => x.role !== 'character').map(({ x, i }) => {
    const [role, use] = ROLE_WORDS[x.role] ?? ROLE_WORDS.product!;
    return { kind: x.role, ref: named ? token(style, 'image', i + 1) : x.label, role: x.label && !x.label.startsWith(x.role) ? `${role} (${x.label})` : role, use };
  });
  const VIDEO_USE: Record<string, string> = { camera: 'camera movement and framing', blocking: 'camera movement, framing, blocking and positions', style: 'style and pacing', motion: 'motion and timing' };
  const videoItems = videos.map((v, i) => ({ kind: v.use, video: named ? token(style, 'video', i + 1) : 'the reference video', use: VIDEO_USE[v.use] ?? VIDEO_USE.motion! }));
  const avoid = !m.negativePrompt && cam.avoid.length ? cam.avoid.map(a => a.charAt(0).toUpperCase() + a.slice(1)).join('. ') + '.' : '';
  const ident = character ? { name: character.name, look: character.look, neverAdd: character.neverAdd } : null;
  const userWords = [r.prompt, r.direction].map(x => (x ?? '').trim()).filter(Boolean).join(' ');
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
  let prompt = shotPrompt(audioSent);
  // Beat-only shots also carry the prompt for "no audio sent": used when the vocals can't be removed (the separator is
  // off or returned nothing), because sending the original track would let the model sing or lip-sync to it.
  let promptNoAudio = audioPlan?.beatOnly ? shotPrompt('none') : undefined;
  if (promptNoAudio && m.promptMax && promptNoAudio.length > m.promptMax) promptNoAudio = promptNoAudio.slice(0, m.promptMax);
  const negList = [...listOf(t['suite.shot.negative'] ?? ''), ...cam.avoid.map(a => a.replace(/^no\s+/i, ''))];
  if (m.promptMax && prompt.length > m.promptMax) { prompt = prompt.slice(0, m.promptMax); notes.push('prompt shortened to fit'); }

  // ---- price
  const videoInput = videos.length > 0;
  const perSec = perSecond(m, p.resolution, { videoInput, audio: r.audio, kind }) * (o.priceScale ?? 1);
  const guideSeconds = videos[0]?.video.seconds;
  const billed = billedSeconds(m, p.seconds, { videoInput, guideSeconds });
  const extraCost = extraPerTake(m);
  const separation = audioPlan?.beatOnly ? o.separationUsd ?? 0 : 0;
  const estimate = Math.round(((perSec * billed + extraCost) * r.takes + separation) * 10000) / 10000;

  return {
    tier: r.quality, mode: n.mode, modelId: m.id, provider: m.provider, ref: refFor(m, kind), kind, resolution: p.resolution.id, seconds: p.seconds, aspect: r.aspectRatio,
    audio: r.audio && m.audio !== 'none', takes: r.takes, seed: m.seed ? r.seed : undefined, prompt, negative: m.negativePrompt ? negList.join(', ') : undefined, params: cam.params,
    images, videos, audioRef: audioPlan, promptNoAudio, speaking, separationUsd: separation, perSec, billedPerTake: billed, extraPerTake: extraCost, estimate,
    camera: { moves: cam.moves, notes: cam.notes, usesGuide: cam.usesGuide }, notes,
  };
}

/** "Video · Shot · HD 1080p · 5 s" (ledger) / "Shot · HD · 1080p" (job label). Never names a model. */
export const shotLabel = (tier: Tier, resolution: string, kind: 'Shot' | 'Recast' = 'Shot') => `${kind} · ${TIER_INFO[tier].label} · ${/^\d+$/.test(resolution) ? `${resolution}p` : resolution.replace(/P$/, 'p')}`;
export const shotNote = (tier: Tier, resolution: string, seconds: number[], kind: 'Shot' | 'Recast' = 'Shot') => {
  const fmt = (v: number) => String(Math.round(v * 10) / 10);
  const s = seconds.length > 1 ? (seconds.every(v => v === seconds[0]) ? `${seconds.length} × ${fmt(seconds[0]!)} s` : `${fmt(seconds.reduce((a, b) => a + b, 0))} s`) : `${fmt(seconds[0] ?? 0)} s`;
  return `Video · ${kind} ${TIER_INFO[tier].label} ${/^\d+$/.test(resolution) ? `${resolution}p` : resolution.replace(/P$/, 'p')} · ${s}`;
};
