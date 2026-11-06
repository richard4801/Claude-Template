// AI suite (workstream 1): bakes the generated Look LUTs (src/suite/looks.ts: palettes and film stocks without a twin in
// the look pack, graded from their swatches) into 17³ .cube files + palettes.json in assets/lookpack/palettes/. The apps
// ship the lookpack folder; a suite take's `look.lut` "palette:<id>" names one of these files.
// Run: npx tsx scripts/suite-looks.ts   (a server test fails if the committed files differ from what this writes)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeCube } from '../src/editor/look.js';
import { CUBE_SIZE } from '../src/editor/lookpack.js';
import { generatedFn, generatedLooks, swatchesOf } from '../src/suite/looks.js';

export const PALETTE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../assets/lookpack/palettes');

export function bakePalettes(): Record<string, string> {
  const files: Record<string, string> = {};
  const looks = generatedLooks();
  for (const l of looks) files[`${l.id}.cube`] = writeCube(CUBE_SIZE, `MUSE ${l.name}`, generatedFn(l.grade));
  files['palettes.json'] = JSON.stringify({ version: 1, cubeSize: CUBE_SIZE,
    looks: looks.map(l => ({ id: l.id, name: l.name, kind: l.group === 'looks' ? 'stock' : 'palette', file: `${l.id}.cube`, lut: `palette:${l.id}`,
      swatches: swatchesOf(l.group, l.group === 'looks' ? l.id.replace(/^stock-/, '') : l.id) })) }, null, 1) + '\n';
  return files;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  fs.mkdirSync(PALETTE_DIR, { recursive: true });
  for (const f of fs.readdirSync(PALETTE_DIR)) if (f.endsWith('.cube') || f === 'palettes.json') fs.rmSync(path.join(PALETTE_DIR, f));
  const files = bakePalettes();
  for (const [n, body] of Object.entries(files)) fs.writeFileSync(path.join(PALETTE_DIR, n), body);
  console.log(`wrote ${Object.keys(files).length} files to ${PALETTE_DIR}`);
}
