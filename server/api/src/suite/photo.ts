// AI suite · the Photo tool (plans/video-composer.md "Photo tool", workstream 3). Photoshoot folded into the composer:
// the same shoot pipeline (references, prompt library, PhotoBill, image engines; routes/index.ts runs it), with the
// composer's rig compiled for a still. Movement, tempo, frame rate and shutter don't exist in a photo, so they are dropped
// with a note. A Photo preset is a photo template: it carries its own camera and light, so the rig isn't added on top.
import { z } from 'zod';
import { SENT_FIELDS } from '../images/sent.js';
import { ImageRefSchema } from './plan.js';
import { APERTURES, BODIES, CameraSpecSchema, ERAS, GENRES, HEIGHTS, LENSES, LIGHTING, LOOKS, MOVES, PALETTES, SHOT_SIZES, canonicalSpec, resolvePreset, type CameraSpec, type Option } from './camera.js';
import { rigCheck, type RigWarning } from './rigcheck.js';
import { shotLook } from './looks.js';
import { houseStyle } from '../prompt/engine.js';
import type { PromptTexts } from '../prompt/library.js';

/** A shoot reference (as `/v1/shoots`): an image and what to take from it. */
const PhotoRefSchema = z.object({ image: ImageRefSchema, guides: z.array(z.enum(['pose', 'look', 'scene'])).min(1).max(3) })
  .refine(r => new Set(r.guides).size === r.guides.length, { message: 'guides must not repeat' });

export const PhotoRequestSchema = z.object({
  /** The character (a MUSE model) and her outfit. Optional (owner 2026-11-11): without one, an image is needed and is the photo to work from. */
  modelId: z.string().min(1).max(80).optional(),
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
  /** WS5: an owner-added image model ("c_…") instead of the studio's image engine (members: those not hidden from them). */
  engineModel: z.string().max(40).optional(),
  /** WS5: the image model for this run, a Replicate image model ("owner/name") or a custom one ("c_…"); 4c: members, a shown one. */
  imageModel: z.string().max(170).optional(),
  /** Images sent (images/sent.ts): replace, add to or drop from what MUSE picks. */
  ...SENT_FIELDS,
}).strict();
export type PhotoRequest = z.infer<typeof PhotoRequestSchema>;

/** The rig as the shoot prompt takes it. Every field is optional: unset means the library's default (Auto). */
export type StillRig = {
  scene?: string; camera?: { shot: string; lensMm: number; aperture: string }; light?: string; grade?: string;
  /** Body, lens character, angle, style, era and expression: one sentence after the scene. */
  direction?: string;
  /** What was left out ("Movement doesn't apply to photos"). */
  notes: string[];
  /** The rig (or its camera preset) sets a camera body, lens character, look or grade: the house style's Camera feel and
   *  the default grade are left out and the rig's own words stand (owner 2026-11-11). */
  ownCamera?: boolean;
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
  const ownCamera = !!(rig.body || rig.lens || rig.look || pal?.preset || pal?.colors?.length);
  return { scene, camera, light, grade, direction, notes, ...(ownCamera ? { ownCamera } : {}) };
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

// ------------------------------------------------------------------ Photo without a character (owner 2026-11-11)
// "I should be able to generate even with just an image." No @character: the uploaded image is the photo to work from.
// With words: an edit of image 1 (everything else kept). Without: a new still of the same people, clothes and place.
// No identity, outfit, figure-lock or her never-add lines; only the rig rows the person set (no default scene or light).
const GUIDE_WORDS: Record<'pose' | 'look' | 'scene', string> = { pose: 'the pose and framing', look: 'the light, colour grade and camera feel', scene: 'the place and background' };
const andWords = (xs: string[]) => (xs.length <= 1 ? xs.join('') : `${xs.slice(0, -1).join(', ')} and ${xs.at(-1)}`);
export function freePhotoPrompt(o: { prompt: string; still: StillRig; refs: { index: number; guides: ('pose' | 'look' | 'scene')[] }[]; texts: Record<string, string | undefined> }) {
  const t = o.texts, words = photoPrompt(o.prompt).replace(/[.\s]+$/, '');
  const [base, ...rest] = [...o.refs].sort((a, b) => a.index - b.index);
  const lines: string[] = [];
  if (base) lines.push(words
    ? `Edit image ${base.index}: ${words}. Keep everything else in image ${base.index} as it is (the same people, faces, bodies, hair and clothes, place and light) unless a line below changes it.`
    : `A new photograph made from image ${base.index}: the same people, faces, bodies, hair and clothes, in the same place and light, at a fresh natural moment.`);
  else if (words) lines.push(`A photograph: ${words}.`); // words only: plain text-to-image (owner 2026-11-11)
  for (const r of rest) lines.push(`Copy ${andWords(r.guides.map(g => GUIDE_WORDS[g]))} from image ${r.index}. Do not take the people or clothes from image ${r.index}.`);
  const s = o.still; // its scene is the prompt itself (stillRig), used above
  if (s.camera) {
    const note = s.camera.lensMm <= 24 ? t['shoot.camera.wide'] ?? '' : s.camera.lensMm >= 85 ? t['shoot.camera.tele'] ?? '' : '';
    lines.push(`Camera: ${s.camera.shot.toLowerCase()} shot, ${s.camera.lensMm}mm lens, ${s.camera.aperture}${note}.`);
  }
  if (s.light || s.grade) lines.push([s.light && `Light: ${s.light.toLowerCase()}`, s.grade && `${s.light ? 'grade' : 'Grade'}: ${s.grade.toLowerCase()}`].filter(Boolean).join('; ') + '.');
  if (s.direction) lines.push(s.direction);
  const style = houseStyle(t as PromptTexts, !!s.ownCamera);
  if (style) lines.push(`Style: ${style}.`);
  const never = (t['never.base'] ?? '').split(',').map(x => x.trim()).filter(Boolean);
  if (never.length) lines.push(`Never add: ${never.join(', ')}.`);
  return lines.join('\n');
}
