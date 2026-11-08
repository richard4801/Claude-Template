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
export type SwapEngine = { id: string; name: string; runs: 'replicate' | 'gpu'; ref?: string; gpuEngine?: 'h3' | 'viggle'; capability?: string; noResolution?: boolean; notice?: string };
export const SWAP_ENGINES: SwapEngine[] = [
  { id: 'h3', name: 'MiniMax H3', runs: 'replicate', ref: 'minimax/h3' },
  { id: 'h3-lite', name: 'MiniMax H3 Lite', runs: 'replicate', ref: 'minimax/h3-lite' },
  { id: 'h3-highspeed', name: 'MiniMax H3 Highspeed', runs: 'replicate', ref: 'minimax/h3-highspeed', noResolution: true },
  { id: 'h3-open', name: 'Edit · MiniMax H3 open weights (own GPU)', runs: 'gpu', gpuEngine: 'h3', capability: 'h3',
    notice: 'Powered by MiniMax H3 · open-weights licence excludes the US, EU, UK and South Korea' },
  { id: 'viggle', name: 'Fast · beta · Viggle (own GPU)', runs: 'gpu', gpuEngine: 'viggle', capability: 'viggle' },
];
export const swapEngineById = (id: string) => SWAP_ENGINES.find(e => e.id === id);

/** Curated Replicate image models for the image purposes (any other "owner/name" is accepted too, checked when it runs). */
export const IMAGE_CANDIDATES = ['black-forest-labs/flux-2-pro', 'black-forest-labs/flux-2-max', 'black-forest-labs/flux-2-flex', 'black-forest-labs/flux-2-dev'];

/** Editor helper → the provider model kind behind it (editor/providers.ts). */
export const TOOL_MODEL_KIND = { matte: 'matte', track: 'track', captions: 'transcribe', denoise: 'separate' } as const;
