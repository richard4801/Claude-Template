// Builds the Edit suite's content library (plans/edit-content-licences.md) into assets/content/: Twemoji stickers
// (CC BY 4.0) as 160 px PNG, CC0 sound effects (uisfx, Kenney via Net Forge) as AAC .m4a, nine OFL font families as
// .ttf, plus catalog.json. Sources are pinned; downloads are cached in $TMPDIR/muse-content-cache. Run:
//   npx tsx scripts/editor-content.ts
// The server copies assets/content into storage on start and serves the catalog (src/editor/content.ts).
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { CONTENT_DIR, type Catalog, type Pack } from '../src/editor/content.js';
import { IN_HOUSE, validateInHouse } from '../src/editor/contentPacks.js';

const SOURCES = {
  twemoji: 'https://cdn.jsdelivr.net/gh/jdecked/twemoji@17.0.2',
  emojibase: 'https://cdn.jsdelivr.net/npm/emojibase-data@18.0.0/en/compact.json',
  uisfx: 'https://registry.npmjs.org/uisfx/-/uisfx-0.4.0.tgz',
  netforge: 'https://registry.npmjs.org/@netforge/asset-library-files/-/asset-library-files-0.2.0.tgz',
  font: (pkg: string, v: string) => `https://registry.npmjs.org/@expo-google-fonts/${pkg}/-/${pkg}-${v}.tgz`,
} as const;

const here = path.dirname(fileURLToPath(import.meta.url));
const CACHE = path.join(os.tmpdir(), 'muse-content-cache');
fs.mkdirSync(CACHE, { recursive: true });

async function fetchCached(url: string): Promise<Buffer | null> {
  const f = path.join(CACHE, crypto.createHash('sha1').update(url).digest('hex'));
  if (fs.existsSync(f)) { const b = fs.readFileSync(f); return b.length ? b : null; }
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const r = await fetch(url);
      if (r.status === 404) { fs.writeFileSync(f, ''); return null; }
      if (!r.ok) throw new Error(`${r.status}`);
      const b = Buffer.from(await r.arrayBuffer());
      fs.writeFileSync(f, b);
      return b;
    } catch (e) { if (attempt === 3) throw new Error(`${url}: ${(e as Error).message}`); await new Promise(r => setTimeout(r, 1000 * 2 ** attempt)); }
  }
  return null;
}
/** A package tarball unpacked into the cache (once). */
async function unpacked(url: string): Promise<string> {
  const dir = path.join(CACHE, 'pkg-' + crypto.createHash('sha1').update(url).digest('hex'));
  if (!fs.existsSync(path.join(dir, 'package'))) {
    const tgz = await fetchCached(url);
    if (!tgz) throw new Error(`missing ${url}`);
    fs.mkdirSync(dir, { recursive: true });
    const t = path.join(dir, 'p.tgz'); fs.writeFileSync(t, tgz);
    execFileSync('tar', ['-xzf', t, '-C', dir]);
  }
  return path.join(dir, 'package');
}
async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (i < items.length) await fn(items[i++]!); }));
}
const out = (rel: string) => { const f = path.join(CONTENT_DIR, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); return f; };

// ------------------------------------------------------------------ stickers
/** Sticker size: sharp enough at the default 30 % on a 1080 px canvas, small enough to keep the library light. */
const STICKER_PX = 160;
const GROUPS: [number, string, string][] = [[0, 'smileys', 'Smileys'], [1, 'people', 'People'], [3, 'animals', 'Animals & nature'], [4, 'food', 'Food & drink'],
  [5, 'travel', 'Travel & places'], [6, 'activities', 'Activities'], [7, 'objects', 'Objects'], [8, 'symbols', 'Symbols'], [9, 'flags', 'Flags']];

/** Twemoji's file name for an emoji: lower-case code points; FE0F dropped unless the sequence has a ZWJ (twemoji toCodePoint). */
const twemojiName = (hex: string) => { const cps = hex.toLowerCase().split('-'); return (cps.includes('200d') ? cps : cps.filter(c => c !== 'fe0f')).join('-'); };

async function stickers(): Promise<Pack> {
  const data = JSON.parse((await fetchCached(SOURCES.emojibase))!.toString('utf8')) as { hexcode: string; label: string; group?: number; order?: number; tags?: string[] }[];
  const keep = data.filter(e => e.group !== undefined && GROUPS.some(g => g[0] === e.group)).sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
  const items: Pack['items'] = [];
  let missing = 0;
  await pool(keep, 16, async e => {
    const name = twemojiName(e.hexcode);
    const svg = (await fetchCached(`${SOURCES.twemoji}/assets/svg/${name}.svg`)) ?? (await fetchCached(`${SOURCES.twemoji}/assets/svg/${e.hexcode.toLowerCase()}.svg`));
    if (!svg) { missing++; return; }
    const file = `stickers/twemoji/${name}.png`;
    const png = await sharp(svg, { density: 320 }).resize(STICKER_PX, STICKER_PX, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } }).png({ palette: true, quality: 90, compressionLevel: 9 }).toBuffer();
    fs.writeFileSync(out(file), png);
    items.push({ id: name, name: e.label, category: GROUPS.find(g => g[0] === e.group)![1], tags: (e.tags ?? []).slice(0, 12), file, width: STICKER_PX, height: STICKER_PX, bytes: png.length, order: e.order ?? 0 });
  });
  items.sort((a, b) => (a.order as number) - (b.order as number));
  for (const it of items) delete it.order;
  console.log(`stickers: ${items.length} (${missing} without a Twemoji file)`);
  return { id: 'twemoji', kind: 'stickers', title: 'Emoji', licence: 'CC-BY-4.0',
    attribution: 'Twemoji graphics by Twitter, Inc. and other contributors, licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Rasterized to PNG.',
    categories: GROUPS.map(([, id, label]) => ({ id, label })), items };
}

// ------------------------------------------------------------------ sound effects
const UISFX_PACKS = ['cinematic', 'arcade', 'glass', 'dreamy', 'organic'];
const UISFX_SKIP = new Set(['input', 'system', 'loops', 'commerce']);
const m4a = (src: string, dst: string) => execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', src, '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-ar', '48000', dst]);
const durationOf = (f: string) => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString().trim());

async function sfx(): Promise<Pack[]> {
  const ui = await unpacked(SOURCES.uisfx);
  const m = JSON.parse(fs.readFileSync(path.join(ui, 'manifest.json'), 'utf8')) as {
    cues: { name: string; label: string; category: string; description: string; loop: boolean }[];
    assets: { pack: string; cue: string; category: string; files: { ogg: { path: string } } }[];
  };
  const cues = new Map(m.cues.map(c => [c.name, c]));
  const uiItems: Pack['items'] = [];
  for (const a of m.assets) {
    const c = cues.get(a.cue)!;
    if (!UISFX_PACKS.includes(a.pack) || UISFX_SKIP.has(a.category) || c.loop) continue;
    const file = `sfx/uisfx/${a.pack}-${a.cue}.m4a`;
    m4a(path.join(ui, a.files.ogg.path), out(file));
    uiItems.push({ id: `${a.pack}-${a.cue}`, name: c.label, category: a.pack, tags: [c.category, a.cue, ...c.description.toLowerCase().replace(/[^a-z ]/g, '').split(' ').filter(w => w.length > 3)].slice(0, 10),
      file, durationSec: Math.round(durationOf(out(file)) * 1000) / 1000, bytes: fs.statSync(out(file)).size });
  }
  const nf = await unpacked(SOURCES.netforge);
  const dir = path.join(nf, 'library/audio/sfx');
  const kItems: Pack['items'] = [];
  for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.ogg')).sort()) {
    const id = f.replace(/\.ogg$/, ''), file = `sfx/kenney/${id}.m4a`;
    m4a(path.join(dir, f), out(file));
    kItems.push({ id, name: id.replace(/_/g, ' ').replace(/^./, c => c.toUpperCase()), category: 'game', tags: id.split('_'), file, durationSec: Math.round(durationOf(out(file)) * 1000) / 1000, bytes: fs.statSync(out(file)).size });
  }
  console.log(`sfx: uisfx ${uiItems.length}, kenney ${kItems.length}`);
  return [
    { id: 'uisfx', kind: 'sfx', title: 'Sound effects', licence: 'CC0-1.0', attribution: 'UI SFX by Romain Simon (uisfx), CC0 1.0.',
      categories: UISFX_PACKS.map(id => ({ id, label: id[0]!.toUpperCase() + id.slice(1) })), items: uiItems },
    { id: 'kenney', kind: 'sfx', title: 'Game sounds', licence: 'CC0-1.0', attribution: 'Sounds by Kenney (kenney.nl), CC0 1.0.',
      categories: [{ id: 'game', label: 'Game' }], items: kItems },
  ];
}

// ------------------------------------------------------------------ fonts
/** Contract family → npm package, the package's file stem, and the weight file used for 400/700/900. */
export const FONT_SOURCES: { id: string; name: string; pkg: string; v?: string; stem: string; weights: Record<'400' | '700' | '900', string> }[] = [
  { id: 'inter', name: 'Inter', pkg: 'inter', stem: 'Inter', weights: { 400: '400Regular', 700: '700Bold', 900: '900Black' } },
  { id: 'montserrat', name: 'Montserrat', pkg: 'montserrat', stem: 'Montserrat', weights: { 400: '400Regular', 700: '700Bold', 900: '900Black' } },
  { id: 'robotoCondensed', name: 'Roboto Condensed', pkg: 'roboto-condensed', stem: 'RobotoCondensed', weights: { 400: '400Regular', 700: '700Bold', 900: '900Black' } },
  { id: 'playfair', name: 'Playfair Display', pkg: 'playfair-display', stem: 'PlayfairDisplay', weights: { 400: '400Regular', 700: '700Bold', 900: '900Black' } },
  { id: 'unbounded', name: 'Unbounded', pkg: 'unbounded', v: '0.4.1', stem: 'Unbounded', weights: { 400: '400Regular', 700: '700Bold', 900: '900Black' } },
  { id: 'rubik', name: 'Rubik', pkg: 'rubik', stem: 'Rubik', weights: { 400: '400Regular', 700: '700Bold', 900: '900Black' } },
  { id: 'jetbrainsMono', name: 'JetBrains Mono', pkg: 'jetbrains-mono', v: '0.4.1', stem: 'JetBrainsMono', weights: { 400: '400Regular', 700: '700Bold', 900: '800ExtraBold' } },
  { id: 'caveat', name: 'Caveat', pkg: 'caveat', stem: 'Caveat', weights: { 400: '400Regular', 700: '700Bold', 900: '700Bold' } },
  { id: 'oswald', name: 'Oswald', pkg: 'oswald', stem: 'Oswald', weights: { 400: '400Regular', 700: '700Bold', 900: '700Bold' } },
];

async function fonts(): Promise<Pack> {
  const items: Pack['items'] = [];
  for (const f of FONT_SOURCES) {
    const pkg = await unpacked(SOURCES.font(f.pkg, f.v ?? '0.4.2'));
    const files: Record<string, string> = {};
    for (const [w, suffix] of Object.entries(f.weights)) {
      const src = path.join(pkg, suffix, `${f.stem}_${suffix}.ttf`);
      if (!fs.existsSync(src)) throw new Error(`font file missing: ${src}`);
      const file = `fonts/${f.id}_${w}.ttf`;
      fs.copyFileSync(src, out(file));
      files[w] = file;
    }
    fs.copyFileSync(path.join(pkg, 'LICENSE_FONT'), out(`licences/OFL-${f.id}.txt`));
    items.push({ id: f.id, name: f.name, files, scripts: ['latin', 'latin-ext', 'cyrillic'] });
  }
  console.log(`fonts: ${items.length}`);
  return { id: 'fonts', kind: 'fonts', title: 'Fonts', licence: 'OFL-1.1', attribution: 'Fonts from Google Fonts under the SIL Open Font License 1.1 (licences/OFL-<family>.txt).', items };
}

// ------------------------------------------------------------------ licences + catalog
async function licences() {
  fs.writeFileSync(out('licences/CC-BY-4.0-twemoji.txt'), (await fetchCached(`${SOURCES.twemoji}/LICENSE-GRAPHICS`))!);
  fs.copyFileSync(path.join(await unpacked(SOURCES.uisfx), 'LICENSE-AUDIO'), out('licences/CC0-uisfx.txt'));
  const nf = await unpacked(SOURCES.netforge);
  fs.copyFileSync(path.join(nf, 'CC0-1.0.txt'), out('licences/CC0-1.0.txt'));
  fs.copyFileSync(path.join(nf, 'NOTICE'), out('licences/NOTICE-kenney-via-netforge.txt'));
}

async function main() {
  await validateInHouse();
  fs.rmSync(CONTENT_DIR, { recursive: true, force: true });
  const packs = [await stickers(), ...(await sfx()), await fonts(), ...IN_HOUSE];
  await licences();
  // The version changes whenever any file or entry does, so the apps' caches follow it.
  const h = crypto.createHash('sha256');
  h.update(JSON.stringify(packs));
  for (const p of packs) for (const it of p.items) for (const f of [it.file, ...Object.values((it.files as Record<string, string>) ?? {})]) if (typeof f === 'string') h.update(fs.readFileSync(path.join(CONTENT_DIR, f)));
  const catalog: Catalog = { version: h.digest('hex').slice(0, 12), packs };
  fs.writeFileSync(out('catalog.json'), JSON.stringify(catalog));
  let bytes = 0; const walk = (d: string) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) e.isDirectory() ? walk(path.join(d, e.name)) : (bytes += fs.statSync(path.join(d, e.name)).size); };
  walk(CONTENT_DIR);
  console.log(`catalog ${catalog.version}: ${packs.length} packs, ${(bytes / 1e6).toFixed(1)} MB in ${path.relative(path.join(here, '..'), CONTENT_DIR)}`);
}

await main();
