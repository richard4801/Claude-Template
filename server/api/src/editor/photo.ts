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
const cubes = new Map<string, Lut>();
/** A bundled look's LUT ("pack:<id>"), read once. */
export function packLut(ref: string): Lut | null {
  if (!ref.startsWith('pack:')) return null;
  const id = ref.slice(5);
  if (!LOOK_IDS.has(id)) return null;
  let l = cubes.get(id);
  if (!l) { l = parseCube(fs.readFileSync(path.join(LOOK_DIR, `${id}.cube`), 'utf8')); cubes.set(id, l); }
  return l;
}

/** A look for a photo (bundled LUTs only), checked; `field` names it in the error. Null/undefined = none. */
export function photoLook(raw: unknown, field = 'filter'): Look | undefined {
  if (raw === undefined || raw === null) return undefined;
  const p = lookProblem(raw, new Map(), LOOK_IDS);
  if (p) throw badRequest(`${field}${p.field ? `.${p.field}` : ''}: ${p.message}`);
  const l = raw as Look;
  if (l.lut && !l.lut.startsWith('pack:')) throw badRequest(`${field}.lut: photos use a look from the pack ("pack:<id>")`);
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
