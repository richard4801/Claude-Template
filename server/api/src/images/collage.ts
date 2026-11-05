// A reference sheet for models that take a single input image (plans/api.md "Identity images" §3): every image a step
// would send, in one JPEG — her face front largest, then the other panels in a grid, each with a small numbered label
// ("1 face", "2 face ¾", "3 body", "4 ref: look & colour") on a neutral background, ≤ 2048 px on the long side.
// Labels are drawn with a built-in 5×7 pixel font, so they look the same on any server (no system fonts needed).

export const COLLAGE_MAX_PX = 2048;
const BG = { r: 235, g: 233, b: 230 };
/** A panel's size is 3:4 (portrait), like the sheet. */
const CELL_RATIO = 4 / 3;

export type CollageCell = { x: number; y: number; w: number; h: number };
/**
 * The layout for `n` panels: panel 1 takes a 2×2 block at the top left, the rest fill a 3-column (n ≤ 3) or 4-column grid
 * around it, row by row. Depends on `n` only, so the estimate's megapixels are the real ones.
 */
export function collageLayout(n: number): { width: number; height: number; cells: CollageCell[] } {
  const count = Math.max(1, n);
  const cols = count <= 3 ? 3 : 4;
  const besideFace = (cols - 2) * 2;
  const rows = 2 + Math.ceil(Math.max(0, count - 1 - besideFace) / cols);
  const u = Math.floor(Math.min(COLLAGE_MAX_PX / cols, COLLAGE_MAX_PX / (rows * CELL_RATIO)));
  const uh = Math.floor(u * CELL_RATIO);
  const cells: CollageCell[] = [{ x: 0, y: 0, w: 2 * u, h: 2 * uh }];
  for (let r = 0; cells.length < count; r++) {
    for (let c = 0; c < cols && cells.length < count; c++) {
      if (r < 2 && c < 2) continue;
      cells.push({ x: c * u, y: r * uh, w: u, h: uh });
    }
  }
  return { width: cols * u, height: rows * uh, cells };
}
export const collageMp = (n: number) => { const l = collageLayout(n); return l.width * l.height / 1e6; };

// 5×7 glyphs, rows top to bottom.
const FONT: Record<string, string> = {
  A: '01110100011000111111100011000110001', B: '11110100011000111110100011000111110', C: '01110100011000010000100001000101110',
  D: '11110100011000110001100011000111110', E: '11111100001000011110100001000011111', F: '11111100001000011110100001000010000',
  G: '01110100011000010111100011000101111', H: '10001100011000111111100011000110001', I: '01110001000010000100001000010001110',
  J: '00111000100001000010000101001001100', K: '10001100101010011000101001001010001', L: '10000100001000010000100001000011111',
  M: '10001110111010110101100011000110001', N: '10001100011100110101100111000110001', O: '01110100011000110001100011000101110',
  P: '11110100011000111110100001000010000', Q: '01110100011000110001101011001001101', R: '11110100011000111110101001001010001',
  S: '01111100001000001110000010000111110', T: '11111001000010000100001000010000100', U: '10001100011000110001100011000101110',
  V: '10001100011000110001100010101000100', W: '10001100011000110101101011010101010', X: '10001100010101000100010101000110001',
  Y: '10001100011000101010001000010000100', Z: '11111000010001000100010001000011111',
  0: '01110100011001110101110011000101110', 1: '00100011000010000100001000010001110', 2: '01110100010000100010001000100011111',
  3: '11111000100010000010000011000101110', 4: '00010001100101010010111110001000010', 5: '11111100001111000001000011000101110',
  6: '00110010001000011110100011000101110', 7: '11111000010001000100010000100001000', 8: '01110100011000101110100011000101110',
  9: '01110100011000101111000010001001100',
  ':': '00000011000110000000011000110000000', '&': '01100100101010001000101011001001101', '/': '00000000010001000100010001000000000',
  '-': '00000000000000011111000000000000000', '·': '00000000000000000100000000000000000', ',': '00000000000000000000011000010001000',
  '.': '00000000000000000000000000110001100', '(': '00010001000100001000010000010000010', ')': '01000001000001000010000100010001000',
};

/**
 * A label as an SVG: white pixel text on a dark strip, `px` screen pixels per font pixel, wrapped at spaces onto as many
 * lines as it needs to fit `maxWidth` (a word longer than a line is cut).
 */
export function labelSvg(text: string, px: number, maxWidth: number) {
  const t = text.replace(/¾/g, '3/4').replace(/½/g, '1/2').toUpperCase();
  const pad = 2 * px, adv = 6 * px, lineH = 9 * px;
  const fit = Math.max(1, Math.floor((maxWidth - 2 * pad + px) / adv));
  const lines: string[] = [];
  for (const word of t.split(/\s+/).filter(Boolean)) {
    const cur = lines[lines.length - 1];
    if (cur != null && cur.length + 1 + word.length <= fit) lines[lines.length - 1] = `${cur} ${word}`;
    else lines.push([...word].slice(0, fit).join(''));
  }
  if (!lines.length) lines.push('');
  const w = Math.max(...lines.map(l => [...l].length)) * adv - px + 2 * pad, h = lines.length * lineH - 2 * px + 2 * pad;
  const rects: string[] = [];
  lines.forEach((line, row) => [...line].forEach((ch, i) => {
    const g = FONT[ch];
    if (!g) return;
    for (let k = 0; k < 35; k++) if (g[k] === '1') rects.push(`<rect x="${pad + i * adv + (k % 5) * px}" y="${pad + row * lineH + Math.floor(k / 5) * px}" width="${px}" height="${px}"/>`);
  }));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="${w}" height="${h}" fill="#000" fill-opacity="0.62"/><g fill="#fff">${rects.join('')}</g></svg>`;
  return { svg: Buffer.from(svg), width: w, height: h, lines };
}

/** Builds the reference sheet: `images[i]` (any format sharp reads) in panel i with "i+1 label". JPEG, quality 90. */
export async function buildCollage(images: Buffer[], labels: string[]): Promise<{ data: Buffer; width: number; height: number }> {
  const sharp = (await import('sharp')).default;
  const L = collageLayout(images.length);
  const gap = Math.max(4, Math.round(L.cells[L.cells.length > 1 ? 1 : 0]!.w * 0.025));
  const comps: { input: Buffer; left: number; top: number }[] = [];
  for (let i = 0; i < images.length; i++) {
    const c = L.cells[i]!;
    const bw = c.w - 2 * gap, bh = c.h - 2 * gap;
    const { data, info } = await sharp(images[i]!).rotate().resize(bw, bh, { fit: 'inside' }).jpeg({ quality: 92 }).toBuffer({ resolveWithObject: true });
    const left = c.x + gap + Math.floor((bw - info.width) / 2), top = c.y + gap + Math.floor((bh - info.height) / 2);
    comps.push({ input: data, left, top });
    const small = L.cells[1]?.w ?? c.w;
    // The label sits on the image's bottom-left corner.
    const lab = labelSvg(`${i + 1} ${labels[i] ?? ''}`.trim(), Math.max(2, Math.round(small / 170)), info.width);
    comps.push({ input: lab.svg, left, top: Math.max(c.y, top + info.height - lab.height) });
  }
  const data = await sharp({ create: { width: L.width, height: L.height, channels: 3, background: BG } }).composite(comps).jpeg({ quality: 90 }).toBuffer();
  return { data, width: L.width, height: L.height };
}
