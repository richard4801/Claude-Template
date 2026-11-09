// The server render's text and captions (render parity): drawn as the apps draw them (android EditOverlay /
// RenderPlan.textFrame / captionFrame, mac EditV2Compositor), as SVG from the fonts' own outlines (opentype.js), so no
// font has to be installed and the member's own font file draws exactly. Pure but for reading font files.
//
// A text block: words laid out greedily into lines no wider than maxWidthPct (default 0.85) of the canvas, each line
// aligned inside the block, the block centred on the item's position; line advance = the font's ascent + descent ×
// lineHeight / 1.15. Painted back to front: background box, caption word box / marker stripe, shadow, stroke, fill.
// The item's scale (static × keyframes × animation × loop), rotation, mirror and opacity apply to the whole block.
import fs from 'node:fs';
import opentype from 'opentype.js';
import sharp from 'sharp';
import * as M from './model.js';

/** Faces for letters the editor's fonts lack (Cyrillic, Greek, …): Debian's fonts-dejavu-core (Dockerfile). */
export const FALLBACK_FONTS = { regular: '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', bold: '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf' };

/** Put in `missing` when an emoji is drawn: the fonts here have it in one colour (outline), the apps in full colour. */
export const EMOJI = 'colour emoji';

const faces = new Map<string, opentype.Font | null>();
/** A font file, parsed once (null when it can't be read). */
export function face(file: string): opentype.Font | null {
  if (faces.has(file)) return faces.get(file)!;
  let f: opentype.Font | null = null;
  try { const b = fs.readFileSync(file); f = opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.length)); } catch { f = null; }
  if (faces.size > 24) faces.clear();
  faces.set(file, f);
  return f;
}

const n2 = (x: number) => String(Math.round(x * 100) / 100);
const xmlAttr = (s: string) => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

/** A word (or run of words) and how it is drawn. */
export type Run = { text: string; color: string; scale?: number; box?: string; marker?: string };
type Word = { d: string; width: number; run: Run; scale: number };
type Shaped = { d: string; width: number };

/** One word as an outline at baseline 0: glyphs from the font, or the fallback where it lacks one; kerned, tracked. */
function shape(text: string, font: opentype.Font, fallback: opentype.Font | null, px: number, tracking: number, missing: Set<string>): Shaped {
  let x = 0, d = '';
  let prev: { g: opentype.Glyph; f: opentype.Font } | null = null;
  for (const ch of text) {
    let f: opentype.Font | null = font.charToGlyphIndex(ch) ? font : fallback?.charToGlyphIndex(ch) ? fallback : null;
    if (!f) { if (!/\s/.test(ch)) missing.add(ch); prev = null; continue; }
    if (/\p{Extended_Pictographic}/u.test(ch)) missing.add(EMOJI);
    const g = f.glyphs.get(f.charToGlyphIndex(ch));
    if (prev && prev.f === f) x += (f.getKerningValue(prev.g, g) / f.unitsPerEm) * px;
    d += g.getPath(x, 0, px).toPathData(2);
    x += ((g.advanceWidth ?? 0) / f.unitsPerEm) * px + tracking;
    prev = { g, f };
  }
  return { d, width: x };
}

/**
 * under: boxes behind the text; shadow: the shadow's outlines, to be blurred by `sigma` px (0: sharp, drawn as is);
 * over: stroke and letters. margin: how far paint reaches outside the block, for cropping.
 */
export type Block = { width: number; height: number; under: string; shadow: { svg: string; sigma: number } | null; over: string; margin: number };
/**
 * Lays out and paints runs (each split into words) in a block whose top-left is (0, 0). `missing` collects letters no
 * font has. `id` keeps filter ids unique in a frame.
 */
export function drawBlock(runs: Run[], s: M.TextStyle, px: number, maxW: number, fontFile: string, o: { maxLines?: number; missing: Set<string>; id: string }): Block | null {
  const font = face(fontFile) ?? face(FALLBACK_FONTS.regular);
  if (!font) return null;
  const fallback = face(s.weight >= 700 ? FALLBACK_FONTS.bold : FALLBACK_FONTS.regular);
  const tracking = (s.letterSpacing ?? 0) * px;
  const space = ((font.charToGlyph(' ').advanceWidth ?? font.unitsPerEm * 0.25) / font.unitsPerEm) * px + tracking;
  // Words, with forced breaks between paragraphs.
  const paras: Word[][] = [[]];
  for (const r of runs) {
    r.text.split('\n').forEach((part, i) => {
      if (i > 0) paras.push([]);
      for (const w of part.split(/[ \t]+/).filter(Boolean)) {
        const k = r.scale ?? 1, sh = shape(w, font, fallback, px * k, tracking * k, o.missing);
        paras.at(-1)!.push({ d: sh.d, width: sh.width, run: r, scale: k });
      }
    });
  }
  const lines: Word[][] = [];
  for (const para of paras) {
    let line: Word[] = [], w = 0;
    for (const word of para) {
      const add = (line.length ? space : 0) + word.width;
      if (line.length && w + add > maxW) { lines.push(line); line = [word]; w = word.width; } else { line.push(word); w += add; }
    }
    lines.push(line);
  }
  const shown = lines.slice(0, o.maxLines ?? lines.length);
  const asc = (font.ascender / font.unitsPerEm) * px, natural = ((font.ascender - font.descender) / font.unitsPerEm) * px;
  const mult = (s.lineHeight ?? 1.15) / 1.15;
  const widths = shown.map(l => l.reduce((a, w, i) => a + w.width + (i ? space : 0), 0));
  const lw = Math.max(0, ...widths);
  type Placed = { x: number; base: number; top: number; bottom: number; w: Word };
  const placed: Placed[] = [];
  let top = 0;
  shown.forEach((l, i) => {
    const ms = Math.max(1, ...l.map(w => w.scale)), h = natural * ms * mult;
    let x = s.align === 'left' ? 0 : s.align === 'right' ? lw - widths[i]! : (lw - widths[i]!) / 2;
    const base = top + asc * ms;
    for (const w of l) { placed.push({ x, base, top, bottom: top + natural * ms, w }); x += w.width + space; }
    top += h;
  });
  const lh = top;
  if (!placed.length) return null;
  const out: string[] = [];
  let shadow: Block['shadow'] = null;
  if (s.background) {
    const pad = s.background.paddingPct * px, r = s.background.radiusPct * px;
    out.push(`<rect x="${n2(-pad)}" y="${n2(-pad)}" width="${n2(lw + 2 * pad)}" height="${n2(lh + 2 * pad)}" rx="${n2(r)}" fill="${s.background.color}" fill-opacity="${n2(s.background.opacity)}"/>`);
  }
  for (const p of placed) {
    if (p.w.run.box) { // caption "box": a rounded box behind the active word
      const pad = 0.2 * px;
      out.push(`<rect x="${n2(p.x - pad)}" y="${n2(p.top - pad / 2)}" width="${n2(p.w.width + 2 * pad)}" height="${n2(p.bottom - p.top + pad)}" rx="${n2(pad)}" fill="${p.w.run.box}"/>`);
    }
    if (p.w.run.marker) { // caption "highlighter": a stripe over the lower 45 % of the line
      const pad = 0.08 * px, h = 0.45 * (p.bottom - p.top);
      out.push(`<rect x="${n2(p.x - pad)}" y="${n2(p.bottom - h)}" width="${n2(p.w.width + 2 * pad)}" height="${n2(h)}" fill="${p.w.run.marker}"/>`);
    }
  }
  const paths = (attrs: (p: Placed) => string) => placed.filter(p => p.w.d).map(p => `<path transform="translate(${n2(p.x)} ${n2(p.base)})" d="${p.w.d}" ${attrs(p)}/>`).join('');
  if (s.shadow && s.shadow.opacity > 0) {
    // Android BlurMaskFilter(radius = blurPct × size): σ ≈ 0.57735 × radius + 0.5.
    const sigma = s.shadow.blurPct > 0 ? s.shadow.blurPct * px * 0.57735 + 0.5 : 0;
    shadow = { svg: `<g transform="translate(0 ${n2(s.shadow.dyPct * px)})" fill="${s.shadow.color}" fill-opacity="${n2(s.shadow.opacity)}">${paths(() => '')}</g>`, sigma };
  }
  const under = out.splice(0).join('');
  if (s.stroke && s.stroke.widthPct > 0) {
    out.push(`<g fill="none" stroke="${s.stroke.color}" stroke-width="${n2(Math.ceil(s.stroke.widthPct * px * 2))}" stroke-linejoin="round">${paths(() => '')}</g>`);
  }
  out.push(paths(p => `fill="${xmlAttr(p.w.run.color)}"`));
  const margin = Math.max(s.background ? s.background.paddingPct * px : 0, 0.25 * px, s.stroke ? Math.ceil(s.stroke.widthPct * px * 2) : 0,
    s.shadow ? 3 * (s.shadow.blurPct * px * 0.57735 + 0.5) + Math.abs(s.shadow.dyPct * px) : 0) + 2;
  void o.id;
  return { width: lw, height: lh, under, shadow, over: out.join(''), margin };
}

// ------------------------------------------------------------------ what shows at a moment (RenderPlan.textFrame / captionFrame)
/** One text block on the canvas at a moment. */
export type Piece = { runs: Run[]; style: M.TextStyle; font: string; maxLines?: number; x: number; y: number; scale: number; rotation: number; flipX: boolean; flipY: boolean; alpha: number };

/** A text item at timeline t, or null when it isn't on screen (android RenderPlan.textFrame). */
export function textPiece(it: M.TextItem, t: number, font: string): Piece | null {
  if (t < it.startSec || t >= it.startSec + it.durationSec) return null;
  const local = t - it.startSec, tr = it.transform ?? {};
  const a = M.animState(it, local), lp = M.loopState(it.animLoop, local);
  let text = it.style.uppercase ? it.text.toUpperCase() : it.text;
  if (a.chars !== null) text = [...text].slice(0, a.chars).join('');
  const alpha = M.propAt(it, 'opacity', it.opacity ?? 1, local) * a.opacity * lp.opacity;
  if (alpha <= 0 || !text.trim()) return null;
  return {
    runs: [{ text, color: it.style.color }], style: it.style, font, alpha,
    x: M.propAt(it, 'x', tr.x ?? 0.5, local), y: M.propAt(it, 'y', tr.y ?? 0.5, local) + a.dy + lp.dy,
    scale: M.propAt(it, 'scale', tr.scale ?? 1, local) * a.scale * lp.scale, rotation: M.propAt(it, 'rotation', tr.rotation ?? 0, local) + lp.rotation,
    flipX: !!tr.flipX, flipY: !!tr.flipY,
  };
}

/**
 * The caption page at timeline t, or null (android RenderPlan.captionFrame): highlight / pop / neon colour the active
 * word, karaoke every word up to it; pop draws it 1.15×; box puts a highlight-coloured box behind it, highlighter a
 * stripe; single shows one word popping in (0.6 → 1 over 0.15 s). Neon's glow is the style's shadow.
 */
export function captionPiece(ct: M.CaptionTrack, pages: M.CaptionPage[], t: number, font: string): Piece | null {
  let pi = -1;
  for (let i = 0; i < pages.length; i++) if (t >= pages[i]!.startSec && t < pages[i]!.endSec) { pi = i; break; }
  if (pi < 0) return null;
  const page = pages[pi]!, s = ct.style;
  let active = 0;
  page.words.forEach((w, k) => { if (w.startSec <= t) active = k; });
  const single = s.preset === 'single' ? 0.6 + 0.4 * M.ease('easeOut', (t - page.startSec) / 0.15) : 1;
  const runs: Run[] = page.words.map((w, k) => {
    const lit = s.preset === 'karaoke' ? k <= active : (s.preset === 'highlight' || s.preset === 'pop' || s.preset === 'neon') && k === active;
    const run: Run = { text: s.uppercase ? w.text.toUpperCase() : w.text, color: lit ? s.highlightColor : s.color };
    if (k === active) {
      if (s.preset === 'pop') run.scale = 1.15;
      if (s.preset === 'single') run.scale = single;
      if (s.preset === 'box') run.box = s.highlightColor;
      if (s.preset === 'highlighter') run.marker = s.highlightColor;
    }
    return run;
  });
  return { runs, style: s, font, maxLines: s.maxLines ?? 2, x: 0.5, y: s.y ?? 0.72, scale: 1, rotation: 0, flipX: false, flipY: false, alpha: 1 };
}

/** A frame of text and captions: the groups to draw (canvas coordinates) and the canvas box they can paint (x0, y0, x1, y1). */
/**
 * A blurred shadow, drawn once and placed in every frame that shows it as an image (an SVG blur cost ~40 ms a frame):
 * `svg` in block coordinates over the box x, y, w, h, blurred by sigma px.
 */
export type Sprite = { id: string; svg: string; sigma: number; x: number; y: number; w: number; h: number };
/** A frame of text and captions: SVG in canvas coordinates (shadows as `sprite:<id>` images); the area it can paint (x0, y0, x1, y1). */
export type Frame = { svg: string; box: [number, number, number, number] };
/** A whole frame of text and captions (null when nothing shows). New shadows go into `sprites` (keyed by their drawing). */
export function frameBody(pieces: Piece[], W: number, H: number, missing: Set<string>, sprites: Map<string, Sprite>): Frame | null {
  const groups: string[] = [];
  const box: [number, number, number, number] = [Infinity, Infinity, -Infinity, -Infinity];
  pieces.forEach((pc, i) => {
    const px = Math.max(1, pc.style.sizePct * H), maxW = Math.max(1, (pc.style.maxWidthPct ?? 0.85) * W);
    const b = drawBlock(pc.runs, pc.style, px, maxW, pc.font, { maxLines: pc.maxLines, missing, id: String(i) });
    if (!b || pc.alpha <= 0.001 || pc.scale <= 0) return;
    let shadow = b.shadow?.svg ?? '';
    if (b.shadow && b.shadow.sigma > 0) {
      const key = `${b.shadow.sigma}|${b.shadow.svg}`;
      let sp = sprites.get(key);
      if (!sp) {
        const dy = (pc.style.shadow?.dyPct ?? 0) * px, m = Math.ceil(3 * b.shadow.sigma + 2);
        sp = { id: `sp${sprites.size}`, svg: b.shadow.svg, sigma: b.shadow.sigma, x: -m, y: Math.floor(-m + Math.min(0, dy)), w: Math.ceil(b.width + 2 * m), h: Math.ceil(b.height + 2 * m + Math.abs(dy)) };
        sprites.set(key, sp);
      }
      shadow = `<image x="${sp.x}" y="${sp.y}" width="${sp.w}" height="${sp.h}" preserveAspectRatio="none" href="sprite:${sp.id}"/>`;
    }
    const sx = pc.scale * (pc.flipX ? -1 : 1), sy = pc.scale * (pc.flipY ? -1 : 1);
    const cx = pc.x * W, cy = pc.y * H, a = (pc.rotation * Math.PI) / 180, alpha = Math.min(1, pc.alpha);
    groups.push(`<g${alpha < 1 ? ` opacity="${n2(alpha)}"` : ''} transform="translate(${n2(cx)} ${n2(cy)}) rotate(${n2(pc.rotation)}) scale(${n2(sx)} ${n2(sy)}) translate(${n2(-b.width / 2)} ${n2(-b.height / 2)})">${b.under}${shadow}${b.over}</g>`);
    const hw = b.width / 2 + b.margin, hh = b.height / 2 + b.margin;
    for (const [u, v] of [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]] as const) {
      const x = cx + (u * sx) * Math.cos(a) - (v * sy) * Math.sin(a), y = cy + (u * sx) * Math.sin(a) + (v * sy) * Math.cos(a);
      box[0] = Math.min(box[0], x); box[1] = Math.min(box[1], y); box[2] = Math.max(box[2], x); box[3] = Math.max(box[3], y);
    }
  });
  return groups.length ? { svg: groups.join(''), box } : null;
}
export type Crop = [number, number, number, number];
const svgDoc = (body: string, crop: Crop) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${crop[2]}" height="${crop[3]}" viewBox="${crop.join(' ')}">${body}</svg>`;

/** Draws the shadows (blurred once each) as PNG data URIs, by sprite id. */
export async function drawSprites(sprites: Sprite[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const sp of sprites) {
    const png = await sharp(Buffer.from(svgDoc(sp.svg, [sp.x, sp.y, sp.w, sp.h]))).ensureAlpha().blur(Math.max(0.3, sp.sigma)).png({ compressionLevel: 1 }).toBuffer();
    out.set(sp.id, `data:image/png;base64,${png.toString('base64')}`);
  }
  return out;
}
/** Draws a frame, cropped to `crop` (x, y, w, h in canvas pixels), into a PNG file. */
export async function rasterize(svg: string, crop: Crop, file: string, sprites: Map<string, string>): Promise<void> {
  const body = svg.replace(/href="sprite:(\w+)"/g, (_, id: string) => `href="${sprites.get(id) ?? ''}"`);
  await sharp(Buffer.from(svgDoc(body, crop))).png({ compressionLevel: 1, adaptiveFiltering: false }).toFile(file);
}
