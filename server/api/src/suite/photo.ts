// AI suite · the Photo tool (plans/video-composer.md "Photo tool", workstream 3). Photoshoot folded into the composer:
// the same shoot pipeline (references, prompt library, PhotoBill, image engines; routes/index.ts runs it), with the
// composer's rig compiled for a still. Movement, tempo, frame rate and shutter don't exist in a photo, so they are dropped
// with a note. A Photo preset is a photo template: it carries its own camera and light, so the rig isn't added on top.
import { z } from 'zod';
import { ImageRefSchema } from './plan.js';
import { APERTURES, BODIES, CameraSpecSchema, ERAS, GENRES, HEIGHTS, LENSES, LIGHTING, LOOKS, MOVES, PALETTES, SHOT_SIZES, canonicalSpec, resolvePreset, type CameraSpec, type Option } from './camera.js';
import { rigCheck, type RigWarning } from './rigcheck.js';
import { shotLook } from './looks.js';

/** A shoot reference (as `/v1/shoots`): an image and what to take from it. */
const PhotoRefSchema = z.object({ image: ImageRefSchema, guides: z.array(z.enum(['pose', 'look', 'scene'])).min(1).max(3) })
  .refine(r => new Set(r.guides).size === r.guides.length, { message: 'guides must not repeat' });

export const PhotoRequestSchema = z.object({
  /** The character (a MUSE model) and her outfit. */
  modelId: z.string().min(1).max(80),
  outfitId: z.string().max(80).optional(),
  /** The scene and what she does, in the member's words. */
  prompt: z.string().max(2000).default(''),
  /** The composer's rig. Movement, tempo, frame rate and shutter are ignored for stills. */
  camera: CameraSpecSchema.optional(),
  /** "Grade with this look" (on by default, as for shots): the Look's LUT is applied to each photo as an editable look. */
  gradeLook: z.boolean().default(true),
  /** Photos in this run (as the old Photoshoot: 1–4). */
  count: z.number().int().min(1).max(4).default(4),
  /** A Photo preset (a photo template id). */
  presetId: z.string().max(80).optional(),
  /** A product photo, for presets with a product layer. */
  productImage: ImageRefSchema.optional(),
  /** Up to 3 references, each saying what to take from it (pose, look, scene). */
  references: z.array(PhotoRefSchema).max(3).optional(),
  seed: z.number().int().min(0).max(2147483647).nullable().optional(),
  lockSeed: z.boolean().optional(),
  shuffleSeed: z.number().int().min(0).optional(),
  title: z.string().max(200).optional(),
  /** AI suite (workstream 1): the composer's draft, checked by suite/drafts.ts and stored with every still. */
  draft: z.unknown().optional(),
  /** WS5: an owner-added image model ("c_…") instead of the studio's image engine (members: only ones made available). */
  engineModel: z.string().max(40).optional(),
  /** WS5 · owner only: the image model for this run, a Replicate image model ("owner/name") or a custom one ("c_…"). */
  imageModel: z.string().max(170).optional(),
}).strict();
export type PhotoRequest = z.infer<typeof PhotoRequestSchema>;

/** The rig as the shoot prompt takes it. Every field is optional: unset means the library's default (Auto). */
export type StillRig = {
  scene?: string; camera?: { shot: string; lensMm: number; aperture: string }; light?: string; grade?: string;
  /** Body, lens character, angle, style, era and expression: one sentence after the scene. */
  direction?: string;
  /** What was left out ("Movement doesn't apply to photos"). */
  notes: string[];
};

const SHOT_WORDS: Record<string, string> = {
  els: 'extreme wide', ls: 'wide', full: 'full-body', cowboy: 'cowboy', ms: 'medium', mcu: 'medium close-up', cu: 'close-up',
  ecu: 'extreme close-up', insert: 'insert', ots: 'over-the-shoulder', pov: 'point-of-view', two_shot: 'two-person',
};
const wording = (list: Option[], id?: string) => (id ? list.find(x => x.id === id)?.wording ?? '' : '');
const optLabel = (list: Option[], id?: string) => (id ? list.find(x => x.id === id)?.label ?? id : '');
const sentence = (parts: string[]) => { const s = parts.filter(Boolean).join('; '); return s ? `${s[0]!.toUpperCase()}${s.slice(1)}.` : ''; };

/** The composer's #move tokens are not words for a still. */
export function photoPrompt(prompt: string) {
  let p = prompt;
  for (const m of [...MOVES].sort((a, b) => b.label.length - a.label.length)) p = p.split(`#${m.label}`).join(' ');
  return p.replace(/\s{2,}/g, ' ').trim();
}

/** Compiles the composer's rig (preset underneath, merged ids resolved) into the shoot prompt's pieces. */
export function stillRig(r: Pick<PhotoRequest, 'prompt' | 'camera'>): StillRig {
  const notes: string[] = [];
  const scene = photoPrompt(r.prompt) || undefined;
  if (!r.camera) return { scene, notes };
  const c: CameraSpec = canonicalSpec(resolvePreset(r.camera));
  if (r.camera.move || r.camera.mix) notes.push('Movement doesn’t apply to photos');
  if (c.style?.tempo) notes.push('Tempo doesn’t apply to photos');
  const rig = c.rig ?? {};
  const camera = rig.focalMm != null || rig.aperture || c.angle?.shotSize
    ? { shot: SHOT_WORDS[c.angle?.shotSize ?? 'ms'] ?? 'medium', lensMm: rig.focalMm ?? 35, aperture: optLabel(APERTURES, rig.aperture ?? 'f2.8') }
    : undefined;
  const l = c.lighting;
  const light = l?.preset || l?.direction || l?.temperatureK
    ? [wording(LIGHTING, l.preset), l.direction ? `from the ${l.direction === 'top' ? 'top' : l.direction === 'below' ? 'below' : l.direction}` : '',
      l.temperatureK ? `${l.temperatureK}K` : '', l.intensity && l.intensity !== 'normal' ? `${l.intensity} intensity` : ''].filter(Boolean).join(', ')
    : undefined;
  const pal = c.palette;
  const grade = [wording(LOOKS, rig.look), wording(PALETTES, pal?.preset), pal?.colors?.length ? `palette ${pal.colors.join(' ')}` : ''].filter(Boolean).join(', ') || undefined;
  const a = c.angle, s = c.style, p = c.performance;
  const direction = sentence([
    wording(BODIES, rig.body) && `shot on ${wording(BODIES, rig.body)}`,
    wording(LENSES, rig.lens),
    wording(HEIGHTS, a?.height),
    a?.dutchDeg ? `canted ${Math.round(a.dutchDeg)}° Dutch angle` : '',
    wording(GENRES, s?.genre) && `${wording(GENRES, s?.genre)} photograph`,
    wording(ERAS, s?.era),
    p ? `expression: ${p.emotion}${p.to ? ` turning to ${p.to}` : ''}` : '',
  ]) || undefined;
  return { scene, camera, light, grade, direction, notes };
}

/** The rig-check rules that make sense for a still (no movement, no reveal, no lip sync). */
const STILL_RULES = new Set<RigWarning['id']>(['deep_focus', 'wide_close', 'worm_close', 'look_clash', 'prompt_angle', 'prompt_size']);
export function photoRigCheck(r: Pick<PhotoRequest, 'prompt' | 'camera'>): RigWarning[] {
  const camera = r.camera ? { ...r.camera, move: undefined, mix: undefined } : undefined;
  return rigCheck({ prompt: r.prompt, camera, speaking: false }).filter(w => STILL_RULES.has(w.id));
}

/** The editable look graded onto each photo (the Look chip), as the shoot pipeline's `filter`. */
export function photoFilter(r: Pick<PhotoRequest, 'camera' | 'gradeLook'>) {
  const l = shotLook(r.camera ? resolvePreset(r.camera) : undefined, r.gradeLook);
  return l ? { look: l, filter: { lut: l.lut, strength: 1 } } : null;
}

/** "Generate · 4 photos · $0.24". */
export const photoButton = (count: number, money: string) => `Generate · ${count} photo${count === 1 ? '' : 's'} · ${money}`;
