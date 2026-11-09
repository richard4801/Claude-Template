// In-house content packs (© MUSE): looks, caption templates and transition presets built from the existing engine.
// Plain Look / CaptionStyle / Transition values; scripts/editor-content.ts validates them into the catalog
// (test/editor-content.test.ts too).
import type { Pack } from './content.js';
import type { Look } from './look.js';
import type { CaptionStyle, Transition } from './model.js';
import { CAPTION_STYLES } from './presets.js';

const look = (id: string, name: string, category: string, l: Look) => ({ id, name, category, look: l });

/** Effects stacked on the pack's graded LUTs: grain, halation, light leaks, vignettes, HSL and curves. */
const LOOKS = [
  look('super8', 'Super 8', 'film', { lut: 'pack:film-gold', strength: 0.85, grain: { amount: 0.55, size: 2 }, vignette: { amount: 0.45, size: 0.35, softness: 0.6 }, leak: { kind: 'amber', amount: 0.25, angle: 40 }, lift: 0.25 }),
  look('portra-glow', 'Portra glow', 'film', { lut: 'pack:film-pastel', strength: 0.8, halation: { amount: 0.35, radius: 0.5, threshold: 0.7 }, grain: { amount: 0.2, size: 1 }, hsl: { orange: { sat: -0.1, light: 0.15 } } }),
  look('cine-dream', 'Dream', 'cinematic', { lut: 'pack:cine-golden', strength: 0.7, halation: { amount: 0.45, radius: 0.7, threshold: 0.65 }, lift: 0.2, vignette: { amount: 0.25 } }),
  look('cine-matrix', 'Code green', 'cinematic', { lut: 'pack:cine-bleach', strength: 0.6, hsl: { green: { sat: 0.6, light: 0.1 }, aqua: { hue: -0.5, sat: 0.4 }, red: { sat: -0.6 }, orange: { sat: -0.3 } }, vignette: { amount: 0.35 } }),
  look('neon-night', 'Neon night', 'moody', { lut: 'pack:moody-night', strength: 0.8, hsl: { magenta: { sat: 0.6, light: 0.2 }, purple: { sat: 0.5 }, blue: { sat: 0.4 } }, halation: { amount: 0.3, threshold: 0.6 }, chromatic: 0.25 }),
  look('rainy-day', 'Rainy day', 'moody', { lut: 'pack:cool-blue-hour', strength: 0.75, curves: { rgb: [[0, 0.06], [0.5, 0.48], [1, 0.92]] }, hsl: { orange: { sat: -0.35 }, yellow: { sat: -0.4 } }, grain: { amount: 0.25, size: 1.5 } }),
  look('red-pop', 'Red only', 'bw', { hsl: { orange: { sat: -1 }, yellow: { sat: -1 }, green: { sat: -1 }, aqua: { sat: -1 }, blue: { sat: -1 }, purple: { sat: -1 }, magenta: { sat: -0.6 }, red: { sat: 0.3 } }, curves: { rgb: [[0, 0.02], [0.3, 0.24], [0.7, 0.78], [1, 1]] } }),
  look('skin-glow', 'Skin glow', 'natural', { lut: 'pack:natural-glow', strength: 0.6, hsl: { orange: { sat: -0.15, light: 0.25 }, red: { light: 0.1 } }, sharpen: 0.15 }),
  look('lush', 'Lush', 'natural', { lut: 'pack:natural-pop', strength: 0.6, hsl: { green: { sat: 0.35, hue: -0.2 }, blue: { sat: 0.3, light: -0.15 }, aqua: { sat: 0.25 } } }),
  look('vhs', 'VHS', 'vintage', { lut: 'pack:vintage-faded', strength: 0.8, chromatic: 0.7, grain: { amount: 0.6, size: 2.5 }, sharpen: 0, lift: 0.3, vignette: { amount: 0.3 } }),
  look('polaroid', 'Instant warm', 'vintage', { lut: 'pack:vintage-instant', strength: 0.85, leak: { kind: 'warm', amount: 0.35, angle: 300 }, vignette: { amount: 0.3, softness: 0.8 }, grain: { amount: 0.2 } }),
  look('ink', 'Ink', 'bw', { lut: 'pack:bw-contrast', strength: 1, curves: { rgb: [[0, 0], [0.35, 0.22], [0.65, 0.8], [1, 1]] }, grain: { amount: 0.35, size: 1 }, vignette: { amount: 0.5, size: 0.3 } }),
];

const cap = (id: string, name: string, s: CaptionStyle) => ({ id, name, style: s });
const C = CAPTION_STYLES;
/** Caption templates: the eight caption presets dressed in the content fonts, colours and sizes. */
const CAPTIONS = [
  cap('bold-yellow', 'Bold yellow', { ...C.pop, font: 'montserrat', weight: 900, highlightColor: '#FFD400' }),
  cap('clean-white', 'Clean white', { ...C.plain, font: 'inter', weight: 700, sizePct: 0.038 }),
  cap('tall-news', 'Headline', { ...C.box, font: 'oswald', weight: 700, uppercase: true, highlightColor: '#E11D48', sizePct: 0.046 }),
  cap('handwritten', 'Handwritten', { ...C.karaoke, font: 'caveat', weight: 700, sizePct: 0.06, highlightColor: '#F97316', stroke: { color: '#000000', widthPct: 0.06 } }),
  cap('retro-mono', 'Terminal', { ...C.highlighter, font: 'jetbrainsMono', weight: 700, uppercase: false, sizePct: 0.036, highlightColor: '#22C55E', color: '#E5FFE9' }),
  cap('elegant', 'Elegant', { ...C.plain, font: 'playfair', weight: 700, sizePct: 0.042, uppercase: false, shadow: { color: '#000000', opacity: 0.5, blurPct: 0.25, dyPct: 0.03 } }),
  cap('chunky', 'Chunky', { ...C.single, font: 'unbounded', weight: 900, sizePct: 0.06, highlightColor: '#FFFFFF' }),
  cap('soft-round', 'Soft round', { ...C.box, font: 'rubik', weight: 700, highlightColor: '#0EA5E9', sizePct: 0.042 }),
  cap('neon-pink', 'Neon pink', { ...C.neon, font: 'montserrat', weight: 900 }),
  cap('neon-cyan', 'Neon cyan', { ...C.neon, font: 'robotoCondensed', weight: 900, color: '#D6FBFF', highlightColor: '#22D3EE', shadow: { color: '#22D3EE', opacity: 0.9, blurPct: 0.5, dyPct: 0 } }),
];

const tr = (id: string, name: string, t: Transition) => ({ id, name, transition: t });
/** Transition presets: each kind at the length that suits it, plus fast and slow variants of the common ones. */
const TRANSITIONS = [
  tr('quick-fade', 'Quick fade', { kind: 'fade', durationSec: 0.25 }),
  tr('slow-fade', 'Slow fade', { kind: 'fade', durationSec: 1.2 }),
  tr('dip-black', 'Dip to black', { kind: 'black', durationSec: 0.8 }),
  tr('flash', 'Flash', { kind: 'white', durationSec: 0.3 }),
  tr('zoom-out', 'Zoom out', { kind: 'zoomOut', durationSec: 0.5 }),
  tr('whip-right', 'Whip right', { kind: 'whipRight', durationSec: 0.35 }),
  tr('cover-left', 'Cover left', { kind: 'coverLeft', durationSec: 0.45 }),
  tr('cover-right', 'Cover right', { kind: 'coverRight', durationSec: 0.45 }),
  tr('cover-up', 'Cover up', { kind: 'coverUp', durationSec: 0.45 }),
  tr('cover-down', 'Cover down', { kind: 'coverDown', durationSec: 0.45 }),
  tr('split-fade', 'Split fade', { kind: 'splitFade', durationSec: 0.4 }),
  tr('fast-spin', 'Fast spin', { kind: 'spin', durationSec: 0.35 }),
];

export const IN_HOUSE: Pack[] = [
  { id: 'muse-looks', kind: 'looks', title: 'More looks', licence: 'MUSE', categories: ['film', 'cinematic', 'moody', 'natural', 'vintage', 'bw'].map(id => ({ id, label: id === 'bw' ? 'B&W' : id[0]!.toUpperCase() + id.slice(1) })), items: LOOKS },
  { id: 'muse-captions', kind: 'captions', title: 'Caption templates', licence: 'MUSE', items: CAPTIONS },
  { id: 'muse-transitions', kind: 'transitions', title: 'Transition presets', licence: 'MUSE', items: TRANSITIONS },
];

/** Every in-house item checked by the contract's own rules (a probe project per item); throws on the first problem. */
export async function validateInHouse(packs: Pack[] = IN_HOUSE) {
  const M = await import('./model.js');
  const { lookProblem } = await import('./look.js');
  const { LOOK_IDS } = await import('./lookpack.js');
  const { FILTERS } = await import('./presets.js');
  const probe = (): import('./model.js').EditProject => ({
    version: 2, sourceTakeId: 't', canvas: { width: 1080, height: 1920, fps: 30, background: '#000000' },
    assets: [{ id: 'src', kind: 'video', take: 't', durationSec: 10 }],
    tracks: [{ id: 'main', kind: 'main', items: [{ id: 'c1', asset: 'src', inSec: 0, outSec: 5, speed: 1 }, { id: 'c2', asset: 'src', inSec: 5, outSec: 10, speed: 1 }] }],
  });
  for (const p of packs) for (const it of p.items) {
    const where = `${p.id}/${it.id}`;
    if (p.kind === 'looks') { const e = lookProblem(it.look as Look, new Map(), LOOK_IDS, new Set()); if (e) throw new Error(`${where}: look.${e.field} ${e.message}`); }
    const q = probe();
    if (p.kind === 'captions') q.tracks.push({ id: 'cap', kind: 'caption', items: [], caption: { asset: 'src', words: [{ text: 'Hi', startSec: 0, endSec: 1 }], style: it.style as CaptionStyle } });
    if (p.kind === 'transitions') (q.tracks[0]!.items[1] as import('./model.js').VideoClip).transitionIn = it.transition as Transition;
    if (p.kind === 'looks') (q.tracks[0]!.items[0] as import('./model.js').VideoClip).look = it.look as Look;
    try { M.validate(q, FILTERS, LOOK_IDS); } catch (e) { throw new Error(`${where}: ${(e as Error).message}`); }
  }
}
