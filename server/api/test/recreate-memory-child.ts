// Child process for test/recreate-memory.test.ts: runs the full Recreate analysis on argv[2] and prints the analyzer
// facts as JSON. Run with `node --import tsx` so the parent can measure this process tree's memory on its own.
import { analyzeReference } from '../src/recreate/analyze.js';
import { hasTesseract } from '../src/recreate/ocr.js';

const input = process.argv[2]!;
const tesseract = (await hasTesseract('tesseract')) ? 'tesseract' : undefined;
const out = await analyzeReference({ ffmpeg: 'ffmpeg', ffprobe: 'ffprobe', ...(tesseract ? { tesseract } : {}), pose: { minFreeMb: 0 } }, input, { maxSec: 61, minFreeMb: 0 });
process.stdout.write(JSON.stringify({ slots: out.recipe.slots.length, text: out.recipe.text.length, analyzer: out.recipe.analyzer, tesseract: !!tesseract }));
