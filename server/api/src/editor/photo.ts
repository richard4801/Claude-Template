// Looks on photos (plans/api.md "Editor v2" → Looks on photos): the same filter stack as the video editor, rendered on
// the server with the reference CPU renderer over sharp's raw pixels, so a photo and a video with the same look match.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { badRequest } from '../errors.js';
import { lookProblem, parseCube, renderLook, type Look, type Lut } from './look.js';
import { LOOK_IDS } from './lookpack.js';

export const LOOK_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/lookpack/looks');
/** Suite looks generated from palettes and film stocks (workstream 1, scripts/suite-looks.ts); absent folder = none. */
export const PALETTE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/lookpack/palettes');
/** Tests point this elsewhere (and reset the cache) with `usePaletteDir`. */
let paletteDir = PALETTE_DIR;
export function usePaletteDir(dir: string) { paletteDir = dir; palettes = null; for (const k of [...cubes.keys()]) if (k.startsWith('palette:')) cubes.delete(k); }
let palettes: Map<string, string> | null = null;
const cubes = new Map<string, Lut>();
/** Palette look id → .cube file name, from palettes.json (read once). */
export function paletteFiles(): Map<string, string> {
  if (palettes) return palettes;
  palettes = new Map();
  try {
    const j = JSON.parse(fs.readFileSync(path.join(paletteDir, 'palettes.json'), 'utf8')) as { looks?: { id?: unknown; file?: unknown }[] };
    for (const l of j.looks ?? []) if (typeof l.id === 'string' && typeof l.file === 'string' && /^[A-Za-z0-9._-]+\.cube$/.test(l.file)) palettes.set(l.id, l.file);
  } catch { /* no palettes shipped */ }
  return palettes;
}
export const paletteIds = () => new Set(paletteFiles().keys());
/** A bundled look's LUT ("pack:<id>" or "palette:<id>"), read once. */
export function packLut(ref: string): Lut | null {
  let file: string | undefined;
  if (ref.startsWith('pack:')) { const id = ref.slice(5); if (LOOK_IDS.has(id)) file = path.join(LOOK_DIR, `${id}.cube`); }
  else if (ref.startsWith('palette:')) { const f = paletteFiles().get(ref.slice(8)); if (f) file = path.join(paletteDir, f); }
  if (!file) return null;
  let l = cubes.get(ref);
  if (!l) { l = parseCube(fs.readFileSync(file, 'utf8')); cubes.set(ref, l); }
  return l;
}

/** A look for a photo (bundled LUTs only), checked; `field` names it in the error. Null/undefined = none. */
export function photoLook(raw: unknown, field = 'filter'): Look | undefined {
  if (raw === undefined || raw === null) return undefined;
  const p = lookProblem(raw, new Map(), LOOK_IDS, paletteIds());
  if (p) throw badRequest(`${field}${p.field ? `.${p.field}` : ''}: ${p.message}`);
  const l = raw as Look;
  if (l.lut && !l.lut.startsWith('pack:') && !l.lut.startsWith('palette:')) throw badRequest(`${field}.lut: photos use a bundled look ("pack:<id>" or "palette:<id>")`);
  return l;
}
export const hasLook = (l?: Look | null) => !!l && Object.keys(l).some(k => k !== 'strength');

/** Applies a look to an image (any format sharp reads); returns PNG bytes (the caller encodes the final file). */
export async function applyLookToImage(input: Buffer, look: Look): Promise<Buffer> {
  const { data, info } = await sharp(input, { failOn: 'none' }).removeAlpha().toColourspace('srgb').raw().toBuffer({ resolveWithObject: true });
  const f = new Float32Array(info.width * info.height * 3);
  for (let i = 0; i < f.length; i++) f[i] = data[i]! / 255;
  const out = renderLook({ width: info.width, height: info.height, data: f }, look, { lut: look.lut ? packLut(look.lut) : null, frame: 0 });
  const b = Buffer.alloc(out.data.length);
  for (let i = 0; i < b.length; i++) b[i] = Math.round(out.data[i]! * 255);
  return sharp(b, { raw: { width: info.width, height: info.height, channels: 3 } }).png().toBuffer();
}
