#!/usr/bin/env node
// The edit render's extra script faces (plans/edit-xl-options.md §4): Google's Noto Sans SC / JP / KR (step 2) and
// Arabic / Hebrew / Devanagari / Thai (step 3, drawn shaped through harfbuzz), Regular and Bold, single-face TTFs
// (opentype.js can't read the .ttc collections Debian ships). Taken from pinned npm packages @expo-google-fonts/noto-sans-*
// (npm checks each package's integrity), only these files kept and each checked against its SHA-256 below.
// SIL Open Font License 1.1 (LICENSE_FONT, copied alongside).
//
//   node scripts/cjk-fonts.mjs [dir]     default dir: assets/cjk (gitignored; the Docker build puts them there too)
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/** npm package (pinned version) per face family. */
const PACKAGES = { 'noto-sans-sc': '0.4.4', 'noto-sans-jp': '0.4.4', 'noto-sans-kr': '0.4.4', 'noto-sans-arabic': '0.4.3', 'noto-sans-hebrew': '0.4.1', 'noto-sans-devanagari': '0.4.2', 'noto-sans-thai': '0.4.2' };
export const CJK_FILES = {
  'NotoSansSC-Regular.ttf': ['noto-sans-sc', '400Regular/NotoSansSC_400Regular.ttf', 'd45f67f0a7c0ca3f256950777ce6a61cc7ce5f9696d02900cbbaac25f8aa7d16'],
  'NotoSansSC-Bold.ttf': ['noto-sans-sc', '700Bold/NotoSansSC_700Bold.ttf', '9a38ae0ab28cd5a256f9ea8e00dedc688aac17f7915fcb000572990afa956b96'],
  'NotoSansJP-Regular.ttf': ['noto-sans-jp', '400Regular/NotoSansJP_400Regular.ttf', '6255ea4692e97ef27330304fb96fd650f9111f868cd585fcf2802d42823930e5'],
  'NotoSansJP-Bold.ttf': ['noto-sans-jp', '700Bold/NotoSansJP_700Bold.ttf', '7c03e14d8a03e8f5181dbd130712d51e4ae01ac648cbd59442ae8b16c0951835'],
  'NotoSansKR-Regular.ttf': ['noto-sans-kr', '400Regular/NotoSansKR_400Regular.ttf', 'b4a747e78805bc25b610dcfc3003cb5fb2e2ec034763774b24216ed15889eef4'],
  'NotoSansKR-Bold.ttf': ['noto-sans-kr', '700Bold/NotoSansKR_700Bold.ttf', 'c76f806dc46b8e7981410cb083801f7f124b7f8bc0d181cdae80e78f16d0e9cc'],
  'NotoSansArabic-Regular.ttf': ['noto-sans-arabic', '400Regular/NotoSansArabic_400Regular.ttf', '252629ca0e87b6233851249b8cbf7b43445211a8caf199f1b306a19202251508'],
  'NotoSansArabic-Bold.ttf': ['noto-sans-arabic', '700Bold/NotoSansArabic_700Bold.ttf', 'a86a704ff8b315082f4859b04c2f8f746f4cefb14553ef10505f143e0d4829d3'],
  'NotoSansHebrew-Regular.ttf': ['noto-sans-hebrew', '400Regular/NotoSansHebrew_400Regular.ttf', 'e0ee753f09733337b9236221018d4bf71fd6d06c87dd76bbc83120514bc55911'],
  'NotoSansHebrew-Bold.ttf': ['noto-sans-hebrew', '700Bold/NotoSansHebrew_700Bold.ttf', '8010b087f33f152e25aef020e68cb5568d6f8deebb6dde8f60d655196e59ebde'],
  'NotoSansDevanagari-Regular.ttf': ['noto-sans-devanagari', '400Regular/NotoSansDevanagari_400Regular.ttf', '30f20b135b2b7b8c370ea30dd8c88f5174c1209f0373534ad4c814717f375b9e'],
  'NotoSansDevanagari-Bold.ttf': ['noto-sans-devanagari', '700Bold/NotoSansDevanagari_700Bold.ttf', '614d1bf087d082e88f0802a6259d96ec846351c0a6fb736294af01fadd09ebac'],
  'NotoSansThai-Regular.ttf': ['noto-sans-thai', '400Regular/NotoSansThai_400Regular.ttf', '9acb585d8662ca4ed1b1cf5889dfa1393f8555103b3986e1ea1e3af4faef70bd'],
  'NotoSansThai-Bold.ttf': ['noto-sans-thai', '700Bold/NotoSansThai_700Bold.ttf', '0be544f347b3ab6382bdc2b555a783727a4858a3dc140670406924670967d916'],
};
const sha = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const ok = (dir, name) => { const f = path.join(dir, name); return fs.existsSync(f) && sha(f) === CJK_FILES[name][2]; };

/** Puts the faces (and the font licence) in [dir], downloading only what's missing or wrong. */
export function fetchCjkFonts(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const need = Object.keys(CJK_FILES).filter(n => !ok(dir, n));
  const pkgs = [...new Set(need.map(n => CJK_FILES[n][0]))];
  if (!pkgs.length && fs.existsSync(path.join(dir, 'LICENSE_FONT'))) return;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-cjk-'));
  try {
    for (const pkg of pkgs.length ? pkgs : ['noto-sans-jp']) {
      const out = execFileSync('npm', ['pack', `@expo-google-fonts/${pkg}@${PACKAGES[pkg]}`, '--pack-destination', tmp, '--silent'], { encoding: 'utf8' }).trim().split('\n').pop();
      const tgz = path.join(tmp, out);
      const files = Object.entries(CJK_FILES).filter(([, v]) => v[0] === pkg).map(([, v]) => `package/${v[1]}`);
      execFileSync('tar', ['-xzf', tgz, '-C', tmp, ...files, 'package/LICENSE_FONT']);
      for (const [name, [p, rel]] of Object.entries(CJK_FILES)) if (p === pkg) fs.copyFileSync(path.join(tmp, 'package', rel), path.join(dir, name));
      fs.copyFileSync(path.join(tmp, 'package', 'LICENSE_FONT'), path.join(dir, 'LICENSE_FONT'));
      fs.rmSync(path.join(tmp, 'package'), { recursive: true, force: true }); fs.rmSync(tgz, { force: true });
    }
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  const bad = Object.keys(CJK_FILES).filter(n => !ok(dir, n));
  if (bad.length) throw new Error(`CJK fonts: checksum mismatch for ${bad.join(', ')}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const dir = path.resolve(process.argv[2] ?? path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'assets', 'cjk'));
  fetchCjkFonts(dir);
  console.log(`CJK fonts ready in ${dir}`);
}
