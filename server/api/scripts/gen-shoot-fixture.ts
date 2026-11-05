// Writes android/core/src/test/resources/shoot_prompt_fixture.json: photoshoot prompts as the SERVER builds them with the
// default prompt library (Presets on/off, reference images). The apps' offline/demo prompt engines are checked against it.
// Also writes android/app/src/main/resources/prompt_library.json: the library's entries with their defaults, for the app's demo mode.
// Run: npx tsx scripts/gen-shoot-fixture.ts
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { photoshoot, type SentRef } from '../src/prompt/engine.js';
import { libraryDefaults } from '../src/prompt/service.js';

const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../android/core/src/test/resources/shoot_prompt_fixture.json');
const identity = { name: 'Demo model', look: 'young woman, shoulder-length dark brown hair, brown eyes, light olive skin', neverAdd: ['tattoos', 'rings'], referenceCount: 7 };
type In = { outfit: string; scene?: string; shot: string; lens: number; aperture: string; light?: string; grade?: string; direction?: string; lockSeed?: boolean; presets?: boolean; refs?: SentRef[] };
const inputs: In[] = [
  { outfit: 'Green set', shot: 'Medium', lens: 35, aperture: 'f/2.8' },
  { outfit: 'Green set', scene: 'Café window', shot: 'Close', lens: 85, aperture: 'f/1.4', light: 'Window light', grade: 'Warm film', lockSeed: true },
  { outfit: 'Crystal dress', scene: 'sunlit rooftop bar, string lights', shot: 'Wide', lens: 16, aperture: 'f/11', light: 'Neon night', direction: 'laughing mid-step, hair blowing' },
  { outfit: 'Green set', shot: 'Medium', lens: 35, aperture: 'f/2.8', direction: 'holding an iced coffee, with rings', presets: false },
  { outfit: 'Green set', shot: 'Full', lens: 50, aperture: 'f/5.6', refs: [{ index: 6, guides: ['pose'] }, { index: 7, guides: ['look', 'scene'] }, { index: 8, guides: ['scene', 'pose', 'look'] }] },
  { outfit: 'Crystal dress', shot: 'Medium', lens: 24, aperture: 'f/2.8', presets: false, lockSeed: true, direction: 'sitting on the steps', refs: [{ index: 8, guides: ['look'] }] },
];
const rows = inputs.map(i => {
  const p = photoshoot({ identity, outfit: { name: i.outfit }, scene: i.scene, camera: { shot: i.shot, lensMm: i.lens, aperture: i.aperture }, light: i.light, grade: i.grade,
    direction: i.direction, lockSeed: i.lockSeed, presets: i.presets, refs: i.refs });
  return { input: i, slots: p.slots, seed: p.seed, removed: p.removed, text: p.text };
});
fs.writeFileSync(out, JSON.stringify({ identity, rows }, null, 1) + '\n');
console.log(`wrote ${rows.length} rows to ${out}`);

const lib = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../android/app/src/main/resources/prompt_library.json');
fs.mkdirSync(path.dirname(lib), { recursive: true });
fs.writeFileSync(lib, JSON.stringify(libraryDefaults(), null, 1) + '\n');
console.log(`wrote the prompt library defaults to ${lib}`);
