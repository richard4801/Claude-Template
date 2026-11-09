#!/usr/bin/env node
// The edit render's CJK faces (plans/edit-xl-options.md §4, step 2): Google's Noto Sans SC / JP / KR, Regular and Bold,
// single-face TTFs (opentype.js can't read the .ttc collections Debian ships). Taken from the pinned npm packages
// @expo-google-fonts/noto-sans-{sc,jp,kr} (npm checks each package's integrity), only these six files kept and each
// checked against its SHA-256 below. SIL Open Font License 1.1 (LICENSE_FONT, copied alongside).
//
//   node scripts/cjk-fonts.mjs [dir]     default dir: assets/cjk (gitignored; the Docker build puts them there too)
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const VERSION = '0.4.4';
export const CJK_FILES = {
  'NotoSansSC-Regular.ttf': ['noto-sans-sc', '400Regular/NotoSansSC_400Regular.ttf', 'd45f67f0a7c0ca3f256950777ce6a61cc7ce5f9696d02900cbbaac25f8aa7d16'],
  'NotoSansSC-Bold.ttf': ['noto-sans-sc', '700Bold/NotoSansSC_700Bold.ttf', '9a38ae0ab28cd5a256f9ea8e00dedc688aac17f7915fcb000572990afa956b96'],
  'NotoSansJP-Regular.ttf': ['noto-sans-jp', '400Regular/NotoSansJP_400Regular.ttf', '6255ea4692e97ef27330304fb96fd650f9111f868cd585fcf2802d42823930e5'],
  'NotoSansJP-Bold.ttf': ['noto-sans-jp', '700Bold/NotoSansJP_700Bold.ttf', '7c03e14d8a03e8f5181dbd130712d51e4ae01ac648cbd59442ae8b16c0951835'],
  'NotoSansKR-Regular.ttf': ['noto-sans-kr', '400Regular/NotoSansKR_400Regular.ttf', 'b4a747e78805bc25b610dcfc3003cb5fb2e2ec034763774b24216ed15889eef4'],
  'NotoSansKR-Bold.ttf': ['noto-sans-kr', '700Bold/NotoSansKR_700Bold.ttf', 'c76f806dc46b8e7981410cb083801f7f124b7f8bc0d181cdae80e78f16d0e9cc'],
};
const sha = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
const ok = (dir, name) => { const f = path.join(dir, name); return fs.existsSync(f) && sha(f) === CJK_FILES[name][2]; };

/** Puts the six faces (and the font licence) in [dir], downloading only what's missing or wrong. */
export function fetchCjkFonts(dir) {
  fs.mkdirSync(dir, { recursive: true });
  const need = Object.keys(CJK_FILES).filter(n => !ok(dir, n));
  const pkgs = [...new Set(need.map(n => CJK_FILES[n][0]))];
  if (!pkgs.length && fs.existsSync(path.join(dir, 'LICENSE_FONT'))) return;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-cjk-'));
  try {
    for (const pkg of pkgs.length ? pkgs : ['noto-sans-jp']) {
      const out = execFileSync('npm', ['pack', `@expo-google-fonts/${pkg}@${VERSION}`, '--pack-destination', tmp, '--silent'], { encoding: 'utf8' }).trim().split('\n').pop();
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
