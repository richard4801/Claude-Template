// AI suite · Look grading (plans/video-composer.md "Look is MUSE's edge"). A prompt can only nudge colour, so a shot's
// Look (a palette or a film stock) also names a real LUT, applied after the render as an editable, reversible Look in the
// Edit suite. Options with a close twin in MUSE's look pack use it (`pack:<id>`); the others get a LUT generated from
// their swatches (`palette:<id>`, baked into assets/lookpack/palettes by scripts/editor-looks.ts).
import { grade as packGrade, LOOK_IDS, type Grade } from '../editor/lookpack.js';
import { LOOKS, PALETTES, type CameraSpec } from './camera.js';

/** Five colours per palette and film stock, darkest → lightest: the tile's swatch strip and the source of generated LUTs. */
export const SWATCHES: Record<string, [string, string, string, string, string]> = {
  // palettes
  naturalistic: ['#2B2A28', '#5E5650', '#9C8C7E', '#C9B9A6', '#F1EAE0'],
  bleached_warm: ['#4A4038', '#8A7562', '#C4A788', '#E3CDB0', '#F7EBD8'],
  hyper_neon: ['#14061F', '#5A0F7A', '#E0218A', '#1FD6E8', '#F6F0FF'],
  teal_orange: ['#0C2A30', '#1E5A63', '#7A8C86', '#E39A5C', '#FFD7B0'],
  sodium_decay: ['#1A1405', '#4F3B10', '#A0721C', '#D9A23A', '#F2D486'],
  cold_steel: ['#0F151C', '#2E3B48', '#5E6E7E', '#9AA8B6', '#DCE3EA'],
  bleach_bypass: ['#141414', '#3E3E3B', '#77756F', '#B2AEA6', '#EAE7E1'],
  classic_bw: ['#0B0B0B', '#3A3A3A', '#7A7A7A', '#B8B8B8', '#F2F2F2'],
  pastel_dream: ['#6E6A86', '#A99BC2', '#E8B9C8', '#F6DCC7', '#FBF5EC'],
  muted_earth: ['#2A271C', '#56513A', '#857A5A', '#B4A27F', '#DED2B6'],
  golden_warmth: ['#2E1B08', '#7A4B14', '#C68A2E', '#EDBE6B', '#FCE7BC'],
  moody_blue: ['#060B18', '#14233F', '#2E4870', '#7B93B6', '#D3DDEA'],
  vintage_fade: ['#3A3034', '#6E5A52', '#A88C70', '#D7BE96', '#F2E4C8'],
  high_key: ['#8C8780', '#BDB7AE', '#DDD8D0', '#F0ECE6', '#FFFFFF'],
  low_key_noir: ['#030405', '#101418', '#2A3036', '#6B737B', '#C8CDD2'],
  cyber_magenta: ['#0D0516', '#3B0E52', '#B5179E', '#2BC4E0', '#F2E6FF'],
  forest_green: ['#0E1A10', '#24402A', '#4F7A46', '#94B07A', '#E1E8CF'],
  desert_sand: ['#3B2C1C', '#7A5E40', '#B8976E', '#DDC29C', '#F6E9D2'],
  commercial_clean: ['#1A1C20', '#4C5058', '#9298A2', '#D6D9DE', '#FCFCFD'],
  retro_80s: ['#1B0A2E', '#4E1F6B', '#C2407E', '#F58A6B', '#FFD9A8'],
  nineties_mall: ['#2A1A12', '#7A3A1E', '#D0662E', '#F2B24A', '#FFF0C4'],
  y2k_gloss: ['#0E1A2A', '#2F5C86', '#7FB7E0', '#C8E6F7', '#F7FBFF'],
  candy_pop: ['#2A0E3A', '#E0397E', '#FF9F1C', '#2EC4B6', '#FFF3B0'],
  autumn: ['#2A1306', '#6B2E0E', '#B5561C', '#D9962E', '#F2D9A6'],
  winter_frost: ['#1C2633', '#4A5E78', '#9DB3CC', '#D7E4F0', '#FAFCFF'],
  sepia: ['#21170E', '#5A4028', '#967352', '#C9AA85', '#F0E2CB'],
  kodachrome_like: ['#160C08', '#7A1A14', '#C9472B', '#2F5FA0', '#F2DFB8'],
  matte_film: ['#2E2C2A', '#5A5550', '#8C847C', '#BDB3A8', '#E6DED4'],
  // film stocks (LOOKS)
  digital_clean: ['#202020', '#545454', '#8E8E8E', '#C8C8C8', '#F6F6F6'],
  phone_hdr: ['#1C2230', '#4A5A78', '#8FA6C8', '#F2C9A0', '#FFFFFF'],
  portrait_negative: ['#2E2A2E', '#6A5E62', '#B49C92', '#E8CDBE', '#FBF1E8'],
  tungsten_stock: ['#08141C', '#1F4A5A', '#5E7E86', '#E0B488', '#FFE6C4'],
  slide_film: ['#0A0A14', '#1A3A7A', '#C0281E', '#F2B01E', '#FFF4DC'],
  bw_film: ['#080808', '#333333', '#777777', '#BBBBBB', '#F4F4F4'],
  bleach_bypass_stock: ['#141414', '#3E3E3B', '#77756F', '#B2AEA6', '#EAE7E1'],
  cross_process: ['#0E1A0A', '#2E5A1E', '#9AB82E', '#E8E04A', '#F6F8D8'],
  reversal_16: ['#100806', '#5A1E14', '#C8502E', '#3A7AB0', '#F6E6C0'],
  faded_print: ['#3A3432', '#6C625C', '#A0948A', '#CFC3B4', '#EFE6DA'],
};

/** Palettes and film stocks with a close twin in the look pack. The rest get a generated LUT. */
export const PACK_TWINS: Record<string, string> = {
  'palettes.naturalistic': 'natural-clean', 'palettes.teal_orange': 'cine-teal-orange', 'palettes.bleach_bypass': 'cine-bleach',
  'palettes.classic_bw': 'bw-classic', 'palettes.pastel_dream': 'film-pastel', 'palettes.golden_warmth': 'warm-honey',
  'palettes.moody_blue': 'cool-blue-hour', 'palettes.vintage_fade': 'vintage-70s', 'palettes.high_key': 'natural-bright',
  'palettes.low_key_noir': 'cine-noir', 'palettes.forest_green': 'moody-forest', 'palettes.sepia': 'bw-sepia',
  'palettes.matte_film': 'vintage-faded', 'palettes.winter_frost': 'cool-ice', 'palettes.commercial_clean': 'natural-pop',
  'looks.digital_clean': 'natural-clean', 'looks.phone_hdr': 'natural-pop', 'looks.portrait_negative': 'film-pastel',
  'looks.tungsten_stock': 'film-cine', 'looks.slide_film': 'film-chrome', 'looks.bw_film': 'bw-classic',
  'looks.bleach_bypass': 'cine-bleach', 'looks.faded_print': 'vintage-faded',
};

const swatchKey = (group: 'palettes' | 'looks', id: string) => (group === 'looks' && id === 'bleach_bypass' ? 'bleach_bypass_stock' : id);
export const swatchesOf = (group: 'palettes' | 'looks', id: string) => SWATCHES[swatchKey(group, id)];

const hexRgb = (h: string): [number, number, number] => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16) / 255) as [number, number, number];
const lumaOf = ([r, g, b]: number[]) => 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
const satOf = ([r, g, b]: number[]) => { const mx = Math.max(r!, g!, b!), mn = Math.min(r!, g!, b!); return mx > 0 ? (mx - mn) / mx : 0; };
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const r3 = (v: number) => Math.round(v * 1000) / 1000;

/**
 * A grade from five swatches (darkest → lightest): the darkest tints the shadows, the lightest the highlights, the
 * mid tones set warmth and saturation, and the spread sets contrast. Near-grey swatches give black and white.
 * Skin stays protected by the pack's grade().
 */
export function swatchGrade(sw: readonly string[]): Grade {
  const c = sw.map(hexRgb);
  const sats = c.map(satOf), mean = (f: (x: [number, number, number]) => number) => c.reduce((a, x) => a + f(x), 0) / c.length;
  const meanSat = sats.reduce((a, b) => a + b, 0) / sats.length;
  const spread = lumaOf(c[c.length - 1]!) - lumaOf(c[0]!);
  const contrast = r3(clamp((spread - 0.75) * 0.6, -0.2, 0.3));
  if (meanSat < 0.08) return { mono: [0.3, 0.59, 0.11], contrast, fade: r3(clamp(lumaOf(c[0]!) * 0.4, 0, 0.1)) };
  const mid = c.slice(1, -1);
  const warmth = mid.reduce((a, x) => a + (x[0] - x[2]), 0) / mid.length;
  // The most colourful swatch of each half tints shadows / highlights, pushed to a fixed chroma so a dark swatch still shows.
  const chroma = (x: [number, number, number]) => { const m = (x[0] + x[1] + x[2]) / 3; return Math.hypot(x[0] - m, x[1] - m, x[2] - m); };
  const pick = (xs: [number, number, number][]) => xs.reduce((a, b) => (chroma(b) > chroma(a) ? b : a));
  const tint = (x: [number, number, number]): [string, number] => {
    const m = (x[0] + x[1] + x[2]) / 3, k = chroma(x) > 1e-3 ? Math.min(4, 0.3 / chroma(x)) : 0;
    const hx = x.map(v => Math.round(clamp(0.5 + (v - m) * k, 0, 1) * 255).toString(16).padStart(2, '0')).join('');
    return [`#${hx.toUpperCase()}`, r3(clamp(chroma(x) * 1.6, 0.04, 0.3))];
  };
  return {
    temp: r3(clamp(warmth * 0.9, -0.5, 0.5)),
    sat: r3(clamp((meanSat - 0.4) * 0.6, -0.4, 0.25)),
    contrast,
    fade: r3(clamp(lumaOf(c[0]!) * 0.35, 0, 0.1)),
    shadows: tint(pick(c.slice(0, 3))),
    highlights: tint(pick(c.slice(2))),
    roll: 0.4,
    exposure: r3(clamp((mean(lumaOf) - 0.5) * 0.3, -0.12, 0.12)),
  };
}

/** Options whose LUT is generated (no pack twin), with their grades: what the bake script writes to assets/lookpack/palettes. */
export function generatedLooks(): { id: string; name: string; group: 'palettes' | 'looks'; grade: Grade }[] {
  const out: { id: string; name: string; group: 'palettes' | 'looks'; grade: Grade }[] = [];
  for (const [group, list] of [['palettes', PALETTES], ['looks', LOOKS]] as const) {
    for (const o of list) {
      if (PACK_TWINS[`${group}.${o.id}`]) continue;
      const sw = swatchesOf(group, o.id);
      if (sw) out.push({ id: `${group === 'looks' ? 'stock-' : ''}${o.id}`, name: o.label, group, grade: swatchGrade(sw) });
    }
  }
  return out;
}
/** The colour function of a generated look (for baking and for tests). */
export const generatedFn = (g: Grade) => packGrade(g);

export type ShotLook = { id: string; kind: 'palette' | 'stock'; label: string; lut: string };

/** The LUT for a palette or film stock: `pack:<id>` for a twin, else `palette:<id>` (generated). */
export function lutFor(group: 'palettes' | 'looks', id: string): string | null {
  const twin = PACK_TWINS[`${group}.${id}`];
  if (twin && LOOK_IDS.has(twin)) return `pack:${twin}`;
  if (!swatchesOf(group, id)) return null;
  return `palette:${group === 'looks' ? 'stock-' : ''}${id}`;
}

/**
 * The look a shot's take is graded with: the palette if one was chosen, else the film stock. Null when nothing was
 * chosen or the user switched "Grade the take with this look" off.
 */
export function shotLook(camera: CameraSpec | undefined, gradeLook: boolean): ShotLook | null {
  if (!gradeLook || !camera) return null;
  const pal = camera.palette?.preset, stock = camera.rig?.look;
  if (pal) { const o = PALETTES.find(x => x.id === pal); const lut = lutFor('palettes', pal); if (o && lut) return { id: pal, kind: 'palette', label: o.label, lut }; }
  if (stock) { const o = LOOKS.find(x => x.id === stock); const lut = lutFor('looks', stock); if (o && lut) return { id: stock, kind: 'stock', label: o.label, lut }; }
  return null;
}
