// Bakes MUSE's look pack (src/editor/lookpack.ts) into 17³ .cube files + looks.json in assets/lookpack/looks/.
// The Android app (assets) and the Mac app (bundle resources) ship that folder as is; the server reads it for photos.
// Run: npx tsx scripts/editor-looks.ts   (a server test fails if the committed files differ from what this writes)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeCube } from '../src/editor/look.js';
import { CUBE_SIZE, LOOKS, grade, packLook } from '../src/editor/lookpack.js';

export const LOOK_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../assets/lookpack/looks');

export function bakeAll(): Record<string, string> {
  const files: Record<string, string> = {};
  for (const l of LOOKS) files[`${l.id}.cube`] = writeCube(CUBE_SIZE, `MUSE ${l.name}`, grade(l.grade));
  files['looks.json'] = JSON.stringify({ version: 1, cubeSize: CUBE_SIZE,
    looks: LOOKS.map(l => ({ id: l.id, name: l.name, category: l.category, file: `${l.id}.cube`, look: packLook(l.id) })) }, null, 1) + '\n';
  return files;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  fs.mkdirSync(LOOK_DIR, { recursive: true });
  for (const f of fs.readdirSync(LOOK_DIR)) if (f.endsWith('.cube') || f === 'looks.json') fs.rmSync(path.join(LOOK_DIR, f));
  const files = bakeAll();
  for (const [n, body] of Object.entries(files)) fs.writeFileSync(path.join(LOOK_DIR, n), body);
  console.log(`wrote ${Object.keys(files).length} files to ${LOOK_DIR}`);
}
