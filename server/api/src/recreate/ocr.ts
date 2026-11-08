// Recreate this edit · reading on-screen words (workstream 1, plans/recreate-edit.md "Text and captions"): one frame
// per text item (its middle), the box cropped, cleaned up and read by tesseract (eng). Free: CPU on the server, one
// item at a time. Without tesseract the words stay null and Claude reads them off the contact sheet.
import { execFile, spawn } from 'node:child_process';
import path from 'node:path';
import sharp from 'sharp';
import { FONT_DIR } from '../editor/render.js';
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
  // The border goes on in a second pass: sharp applies negate after extend, which would turn a white border black.
  const clean = await img.png().toBuffer();
  return sharp(clean).extend({ top: 20, bottom: 20, left: 20, right: 20, background: '#ffffff' }).png().toBuffer();
}

/** One face per editor font, for matching (the bundled files the server render uses too). `font` is a Pango description:
 * the family list ends at the comma, so "Condensed" or "Medium" in a family name isn't read as a style. */
const FACES: { id: TextItem['fontId']; file: string; font: string }[] = [
  { id: 'sans', file: 'figtree_700', font: 'Figtree, Bold' },
  { id: 'serif', file: 'instrument_serif_400', font: 'Instrument Serif,' },
  { id: 'rounded', file: 'outfit_700', font: 'Outfit, Bold' },
  { id: 'condensed', file: 'barlow_condensed_700', font: 'Barlow Condensed, Bold' },
  { id: 'mono', file: 'dm_mono_500', font: 'DM Mono Medium,' },
  { id: 'marker', file: 'permanent_marker_400', font: 'Permanent Marker,' },
];
/** Ink (dark on light), trimmed to its box, scaled to w × h and softened, as 0–1 per pixel (thin strokes still overlap). */
async function inkMask(png: Buffer, w: number, h: number, darkInk: boolean): Promise<{ mask: Float32Array; aspect: number } | null> {
  let img = sharp(png).greyscale();
  if (!darkInk) img = img.negate({ alpha: false });
  const trimmed = await img.threshold(128).trim({ background: '#ffffff', threshold: 10 }).png().toBuffer().catch(() => null);
  if (!trimmed) return null;
  const meta = await sharp(trimmed).metadata();
  if (!meta.width || !meta.height) return null;
  const raw = await sharp(trimmed).resize(w, h, { fit: 'fill' }).blur(1).greyscale().raw().toBuffer();
  return { mask: Float32Array.from(raw, v => (255 - v) / 255), aspect: meta.width / meta.height };
}
/** A font match below this score, or within this ratio of the runner-up, is left unknown (calibrated on the six fonts). */
export const MIN_FONT_SCORE = 0.2, FONT_MARGIN = 1.03;
/**
 * The editor font whose shape is nearest a crop of known words (black text on white, as read): the words rendered in
 * each font, compared by soft ink overlap after scaling to the crop, and by width for their height. Null when unsure.
 */
export async function fontOf(cropPng: Buffer, words: string): Promise<{ fontId: TextItem['fontId']; score: number } | null> {
  const W = 160, H = 32;
  const crop = await inkMask(cropPng, W, H, true);
  if (!crop || !words.trim()) return null;
  const scores: { fontId: TextItem['fontId']; score: number }[] = [];
  for (const f of FACES) {
    const r = await sharp({ text: { text: escapeMarkup(words.trim().slice(0, 60)), fontfile: path.join(FONT_DIR, `${f.file}.ttf`), font: `${f.font} 64`, rgba: false } }).png().toBuffer().catch(() => null);
    if (!r) continue;
    const t = await inkMask(r, W, H, false);
    if (!t) continue;
    let inter = 0, uni = 0;
    for (let i = 0; i < W * H; i++) { const a = crop.mask[i]!, b = t.mask[i]!; inter += Math.min(a, b); uni += Math.max(a, b); }
    const score = (uni ? inter / uni : 0) * Math.exp(-2 * Math.abs(Math.log(crop.aspect / t.aspect)));
    scores.push({ fontId: f.id, score: Math.round(score * 1000) / 1000 });
  }
  // Unsure: a weak match, or a near tie (Figtree and Outfit capitals are nearly the same shape).
  const [best, next] = scores.sort((a, b) => b.score - a.score);
  return best && best.score >= MIN_FONT_SCORE && (!next || best.score >= next.score * FONT_MARGIN) ? best : null;
}
const escapeMarkup = (s: string) => s.replace(/[<>&]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]!));

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
      let r: ReturnType<typeof parseTsv> = null, crop: Buffer | null = null;
      for (const v of variantsFor(it.color)) {
        const png = await ocrImage(f.rgb, fw, fh, it.box, v);
        const got = parseTsv(await tesseract(cfg.tesseract, png, it.box.h > 0.12 ? 6 : 7));
        if (got && (!r || got.conf > r.conf)) { r = got; crop = png; }
        if (r && r.conf >= 85) break;
      }
      // The nearest editor font, from the read words' shape (G4).
      const font = r && r.conf >= MIN_OCR_CONF && crop && it.box.h <= 0.12 ? await fontOf(crop, r.words).catch(() => null) : null;
      out.push(r && r.conf >= MIN_OCR_CONF ? { ...it, words: r.words.slice(0, 200), ...(font ? { fontId: font.fontId } : {}), confidence: Math.round(Math.min(0.9, it.confidence + (r.conf / 100) * 0.45) * 100) / 100 } : it);
    } catch { out.push(it); }
  }
  return out;
}
