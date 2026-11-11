// WS13 · model choice everywhere (plans/model-choice.md): the purposes an owner can pick a model for, and which built-in
// models serve which purpose. Pure data and functions (no database), shared by the catalog (engines/service.ts), the
// Suite's owner picker (/v1/suite/catalog engines[].purposes) and the tests.
import type { ModelSpec } from '../suite/registry.js';

export const PURPOSES = ['shot', 'talking', 'ugc', 'storyboard', 'guide', 'recast', 'extend', 'swap', 'fill', 'photo', 'outfit', 'character', 'plate',
  'upscale', 'matte', 'track', 'captions', 'denoise'] as const;
export type Purpose = (typeof PURPOSES)[number];
export type EngineKind = 'video' | 'image' | 'tool';

export const PURPOSE_INFO: Record<Purpose, { label: string; kind: EngineKind }> = {
  shot: { label: 'Shot', kind: 'video' },
  talking: { label: 'Talking', kind: 'video' },
  ugc: { label: 'UGC ad', kind: 'video' },
  storyboard: { label: 'Storyboard', kind: 'video' },
  guide: { label: 'Camera guide (3D)', kind: 'video' },
  recast: { label: 'Recast', kind: 'video' },
  extend: { label: 'Extend', kind: 'video' },
  swap: { label: 'Character swap', kind: 'video' },
  fill: { label: 'Recreate fills', kind: 'video' },
  photo: { label: 'Photo', kind: 'image' },
  outfit: { label: 'Outfits', kind: 'image' },
  character: { label: 'Character photos', kind: 'image' },
  plate: { label: 'Background plates', kind: 'image' },
  upscale: { label: 'Upscale', kind: 'tool' },
  matte: { label: 'Remove background', kind: 'tool' },
  track: { label: 'Tap to keep', kind: 'tool' },
  captions: { label: 'Captions', kind: 'tool' },
  denoise: { label: 'Voice clean-up', kind: 'tool' },
};

export const isPurpose = (v: unknown): v is Purpose => typeof v === 'string' && (PURPOSES as readonly string[]).includes(v);

/** Purposes a Suite shot request serves (the composer's tool, its mode, a guide clip, an audio reference). */
export function purposeOfShot(r: { mode?: string; cast?: unknown[]; extend?: unknown; camera?: { guide?: unknown; mode?: string } | null; references?: { audio?: unknown; images?: unknown[] } | null;
  draft?: unknown }): Purpose {
  if (r.mode === 'swap') return 'swap';
  if (r.mode === 'recast' || r.cast?.length) return 'recast';
  if (r.mode === 'extend' || r.extend) return 'extend';
  const tool = (r.draft as { tool?: unknown } | undefined)?.tool;
  if (r.camera?.guide || r.camera?.mode === 'directed') return 'guide';
  if (tool === 'talking' || r.references?.audio) return 'talking';
  if (tool === 'ugc_ad' || tool === 'ugc') return 'ugc';
  if (tool === 'storyboard') return 'storyboard';
  return 'shot';
}

const makesShots = (m: ModelSpec) => m.modes.text || m.modes.image || m.modes.reference;
/** The video purposes a model can serve, from its registry entry (custom models: plain shots and, with images, UGC). */
export function videoPurposes(m: ModelSpec): Purpose[] {
  const out: Purpose[] = [];
  if (makesShots(m)) out.push('shot', 'storyboard', 'fill');
  if (makesShots(m) && m.refs.audios > 0) out.push('talking');
  if (makesShots(m) && m.refs.images > 0) out.push('ugc');
  if (!m.byo && (m.modes.guide || (makesShots(m) && m.camera.referenceVideo))) out.push('guide');
  if (m.modes.recast && m.recast) out.push('recast');
  if (m.extend) out.push('extend');
  return PURPOSES.filter(p => out.includes(p));
}

/**
 * Character swap engines (the existing swap: the source clip as the reference video, her sheet as references). Hosted:
 * the MiniMax H3 family on Replicate (same input schema; services/replicateVideo.ts). Our GPU: Edit (H3 open weights,
 * the existing path the owner kept) and Fast · beta (Viggle), when the pods offer them.
 */
export type SwapEngine = { id: string; name: string; runs: 'replicate' | 'higgsfield' | 'gpu'; ref?: string; gpuEngine?: 'h3' | 'viggle'; capability?: string; noResolution?: boolean; notice?: string;
  /** Higgsfield Genjutsu motion transfer: its own input (video_url, image_urls ≤ maxImages, prompt, resolution), source range and resolutions. */
  genjutsu?: { minSec: number; maxSec: number; maxImages: number } };
export const SWAP_ENGINES: SwapEngine[] = [
  { id: 'h3', name: 'MiniMax H3', runs: 'replicate', ref: 'minimax/h3' },
  { id: 'h3-lite', name: 'MiniMax H3 Lite', runs: 'replicate', ref: 'minimax/h3-lite' },
  { id: 'h3-highspeed', name: 'MiniMax H3 Highspeed', runs: 'replicate', ref: 'minimax/h3-highspeed', noResolution: true },
  // The owner's Higgsfield plan (half Replicate's 2K price): H3 reference-to-video with the clip as the reference video
  // (Higgsfield has no H3 edit endpoint); 2K only, 5–15 s. Out of credit or down at the start → Replicate H3.
  { id: 'h3-hf', name: 'MiniMax H3', runs: 'higgsfield', ref: 'minimax/h3/reference-to-video' },
  // Higgsfield Genjutsu motion transfer (owner 2026-11-11): her images (1–8) take over the person in the clip, keeping its
  // motion. Source 4–30 s (shorter is padded to 4 s, longer cut to 30 s); 480p/720p/1080p by quality. No fallback to
  // another model (a different look and price): a refusal is said plainly. Light keeps the first 15 s.
  { id: 'genjutsu', name: 'Genjutsu', runs: 'higgsfield', ref: 'higgsfield/genjutsu/motion-transfer/v1.0', genjutsu: { minSec: 4, maxSec: 30, maxImages: 8 } },
  { id: 'genjutsu-light', name: 'Genjutsu Light', runs: 'higgsfield', ref: 'higgsfield/genjutsu-light/motion-transfer/v1.0', genjutsu: { minSec: 4, maxSec: 15, maxImages: 8 } },
  { id: 'h3-open', name: 'Edit · MiniMax H3 open weights', runs: 'gpu', gpuEngine: 'h3', capability: 'h3',
    notice: 'Powered by MiniMax H3 · open-weights licence excludes the US, EU, UK and South Korea' },
  { id: 'viggle', name: 'Fast · beta · Viggle', runs: 'gpu', gpuEngine: 'viggle', capability: 'viggle' },
];
/** Higgsfield's H3 takes 5–15 s (a shorter clip is padded to 5 s and the take is cut back). */
export const HF_SWAP_MIN_SEC = 5;
export const swapEngineById = (id: string) => SWAP_ENGINES.find(e => e.id === id);
/**
 * What Genjutsu keeps from the source clip, from Higgsfield's docs (read 2026-11-11), for the pickers to explain. Docs say:
 * the motion and timing follow the source (output length = the prepared source); Light keeps the source audio and the
 * first 15 s; full Genjutsu takes up to 30 s. They say nothing about cuts, camera moves or the background: shown as
 * "not stated" (the new scene comes from the prompt and pictures). MUSE puts the clip's sound back on either way.
 */
export const GENJUTSU_KEEPS = {
  keeps: ['the moves and timing of the clip', 'the clip’s sound (MUSE puts it back)'],
  changes: ['the person, outfit, products and scene, from your pictures (up to 8) and the prompt'],
  notStated: ['cuts', 'camera moves', 'the background (describe it in the prompt to change or keep it)'],
  limits: 'Genjutsu: first 30 s (shorter than 4 s is padded). Light: first 15 s; billed on output + input seconds.',
} as const;

/**
 * Owner 2026-11-11: Auto picks between the two jobs a one-person Recast can be. "Same moves, new look or scene" (a new
 * outfit, background or scene, added characters or products) → Genjutsu Light; "same scene, new person" → the Recast
 * models. Reads the request's words; null reason = nothing points to a new look.
 */
const LOOK_RE = /\b(outfit|wear(?:s|ing)?|dress(?:ed)?|clothes|clothing|costume|background|backdrop|scene|setting|location|set in|beach|street|studio|room|product|holding|holds|bottle|bag|add(?:s|ing)?\s+(?:a|an|another|her|his|two|three)?\s*(?:character|person|people|friend|girl|guy|woman|man|product)|new look|restyle|style it)\b/i;
export function recastIntent(text: string | null | undefined): { kind: 'look' | 'person'; reason: string } {
  const m = LOOK_RE.exec(text ?? '');
  return m ? { kind: 'look', reason: `you asked for a new look or scene (“${m[0]}”) with the same moves` }
    : { kind: 'person', reason: 'same scene, new person' };
}

/** Said when the server's Higgsfield key has no access to Genjutsu (a 403/404 that isn't about credit). */
export const GENJUTSU_NO_ACCESS = "Your Higgsfield plan doesn't include Genjutsu · you weren't charged. Pick another model, or add Genjutsu to the Higgsfield plan.";
/** Genjutsu's resolution per MUSE quality (Draft 480p, Standard 720p, HD 1080p). */
export const GENJUTSU_RES: Record<string, string> = { draft: '480p', standard: '720p', hd: '1080p' };

/** Curated Replicate image models for the image purposes (any other "owner/name" is accepted too, checked when it runs). */
export const IMAGE_CANDIDATES = ['black-forest-labs/flux-2-pro', 'black-forest-labs/flux-2-max', 'black-forest-labs/flux-2-flex', 'black-forest-labs/flux-2-dev'];

/** Editor helper → the provider model kind behind it (editor/providers.ts). */
export const TOOL_MODEL_KIND = { matte: 'matte', track: 'track', captions: 'transcribe', denoise: 'separate' } as const;

/** The ids WS7 (Android) proposed, accepted as aliases of the canonical purposes. */
export const PURPOSE_ALIASES: Record<string, Purpose> = { recreate: 'fill', model_photos: 'character', background: 'plate', camera: 'guide' };
/** A purpose id or one of its aliases → the purpose (null if neither). */
export const toPurpose = (v: unknown): Purpose | null => isPurpose(v) ? v : typeof v === 'string' && PURPOSE_ALIASES[v] ? PURPOSE_ALIASES[v]! : null;
