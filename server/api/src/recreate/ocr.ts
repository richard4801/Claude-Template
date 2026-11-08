// Recreate this edit · reading on-screen words (workstream 1, plans/recreate-edit.md "Text and captions"): one frame
// per text item (its middle), the box cropped, cleaned up and read by tesseract (eng). Free: CPU on the server, one
// item at a time. Without tesseract the words stay null and Claude reads them off the contact sheet.
import { execFile, spawn } from 'node:child_process';
import sharp from 'sharp';
import { grabFrame } from './frames.js';
import type { TextItem } from './text.js';

/** At most this many items are read (each is one frame and up to three tesseract runs, about 0.1 s each). */
export const MAX_OCR_ITEMS = 20;
/** Words read with less average confidence (0–100) stay null. */
export const MIN_OCR_CONF = 55;

const available = new Map<string, Promise<boolean>>();
/** Whether `bin` runs (checked once per path). */
export function hasTesseract(bin = 'tesseract') {
  let p = available.get(bin);
  if (!p) { p = new Promise(res => execFile(bin, ['--version'], { timeout: 10_000 }, err => res(!err))); available.set(bin, p); }
  return p;
}

/** The words in tesseract's TSV output (level 5 rows) with their mean confidence; lines kept, joined by a space. */
export function parseTsv(tsv: string): { words: string; conf: number } | null {
  const rows = tsv.split('\n').slice(1).map(l => l.split('\t')).filter(c => c.length >= 12 && c[0] === '5');
  const ws = rows.map(c => ({ text: c[11]!.trim(), conf: Number(c[10]) })).filter(w => w.text && w.conf >= 0);
  // Stray marks: single symbols that are not letters or digits.
  const kept = ws.filter(w => /[\p{L}\p{N}]/u.test(w.text));
  if (!kept.length) return null;
  const words = kept.map(w => w.text).join(' ').replace(/\s+/g, ' ').trim();
  return { words, conf: kept.reduce((a, w) => a + w.conf, 0) / kept.length };
}

function tesseract(bin: string, png: Buffer, psm: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const p = spawn(bin, ['stdin', 'stdout', '-l', 'eng', '--psm', String(psm), 'tsv'], { env: { ...process.env, OMP_THREAD_LIMIT: '1' } });
    let out = '', err = '';
    const timer = setTimeout(() => p.kill('SIGKILL'), 20_000);
    p.stdout.on('data', d => { out += String(d); });
    p.stderr.on('data', d => { err += String(d); });
    p.on('error', e => { clearTimeout(timer); reject(e); });
    p.on('close', code => { clearTimeout(timer); code === 0 ? resolve(out) : reject(new Error(`tesseract failed: ${err.trim().split('\n').slice(-1)[0]?.slice(0, 200)}`)); });
    p.stdin.on('error', () => undefined);
    p.stdin.end(png);
  });
}

/** How a crop is cleaned up: keep the caption's fill (near-white or near-black) as black text on white, or plain grey. */
export type OcrVariant = { fill: 'light' | 'dark'; cut: number } | { fill: 'grey' };
/** Tried in order until one reads with confidence ≥ 85 (light captions: only the brightest pixels are the letters). */
export const variantsFor = (color: string): OcrVariant[] => color === '#000000'
  ? [{ fill: 'dark', cut: 25 }, { fill: 'dark', cut: 50 }, { fill: 'grey' }]
  : [{ fill: 'light', cut: 235 }, { fill: 'light', cut: 200 }, { fill: 'grey' }];

/** The box of one frame made easy to read: cropped with a margin, scaled so the text is about 90 px tall, cleaned up per `v`, a white border. */
export async function ocrImage(rgb: Uint8Array, width: number, height: number, box: TextItem['box'], v: OcrVariant): Promise<Buffer> {
  const padX = 0.04, padY = box.h * 0.35;
  const left = Math.max(0, Math.floor((box.x - padX) * width)), top = Math.max(0, Math.floor((box.y - padY) * height));
  const w = Math.max(8, Math.min(width - left, Math.ceil((box.w + 2 * padX) * width))), h = Math.max(8, Math.min(height - top, Math.ceil((box.h + 2 * padY) * height)));
  const scale = Math.min(6, Math.max(1, 90 / h));
  let img = sharp(Buffer.from(rgb), { raw: { width, height, channels: 3 } }).extract({ left, top, width: w, height: h })
    .resize(Math.round(w * scale), Math.round(h * scale), { kernel: 'cubic' }).greyscale();
  if (v.fill === 'light') img = img.threshold(v.cut).negate({ alpha: false });
  else if (v.fill === 'dark') img = img.threshold(v.cut);
  return img.extend({ top: 20, bottom: 20, left: 20, right: 20, background: '#ffffff' }).png().toBuffer();
}

/**
 * Fills `words` for the text items it can read (in place order; returns new items). Each item is read at its middle
 * from a frame up to 720 px wide. Items over MAX_OCR_ITEMS, or read with low confidence, keep `words: null`.
 */
export async function readWords(cfg: { ffmpeg: string; tesseract: string }, input: string, items: TextItem[], src: { width: number; height: number }): Promise<TextItem[]> {
  if (!items.length || !(await hasTesseract(cfg.tesseract))) return items;
  const fw = Math.min(720, src.width - (src.width % 2)), fh = Math.max(2, Math.round(fw * src.height / src.width / 2) * 2);
  const out: TextItem[] = [];
  for (const [i, it] of items.entries()) {
    if (i >= MAX_OCR_ITEMS) { out.push(it); continue; }
    try {
      const f = await grabFrame(cfg.ffmpeg, input, (it.startSec + it.endSec) / 2, fw, fh);
      // A single line for captions; a block when the box is tall.
      let r: ReturnType<typeof parseTsv> = null;
      for (const v of variantsFor(it.color)) {
        const got = parseTsv(await tesseract(cfg.tesseract, await ocrImage(f.rgb, fw, fh, it.box, v), it.box.h > 0.12 ? 6 : 7));
        if (got && (!r || got.conf > r.conf)) r = got;
        if (r && r.conf >= 85) break;
      }
      out.push(r && r.conf >= MIN_OCR_CONF ? { ...it, words: r.words.slice(0, 200), confidence: Math.round(Math.min(0.9, it.confidence + (r.conf / 100) * 0.45) * 100) / 100 } : it);
    } catch { out.push(it); }
  }
  return out;
}
