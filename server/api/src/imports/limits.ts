// Import limits (owner 2026-11-16: "import up to 1 hr long, about 2 GB max … edit file videos needed to make an edit").
// Imports (a file or a link) are source footage for edits: up to IMPORT_MAX_SEC_EDIT (60 min) and IMPORT_MAX_MB (2 GB).
// The Suite's swap and recast engines take far shorter sources (SUITE_SOURCE_MAX_SEC, 30 s today): that rule is applied
// when a long Library clip is picked there, with a plain reason and the existing trim (New Swap's range pick), never
// at import.
import fs from 'node:fs';
import os from 'node:os';
import { ApiError } from '../errors.js';
import { MODELS } from '../suite/registry.js';

/**
 * The longest source the Suite's swap and recast engines take (registry `recast.sourceSeconds`, and reference videos'
 * `videoSecondsMax`): 30 s today. Was the import cap until 2026-11-16; now checked at use.
 */
export const SUITE_SOURCE_MAX_SEC = Math.max(30, ...MODELS.map(m => Math.max((m as { recast?: { sourceSeconds?: [number, number] } }).recast?.sourceSeconds?.[1] ?? 0, m.refs?.videoSecondsMax ?? 0)));

/** "45 s", "12 min", "1 h 5 min": a length the way the apps say it. */
export function lengthText(sec: number): string {
  const s = Math.round(sec);
  if (s < 120) return `${s} s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  return m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`;
}
/** "150 MB", "2 GB", "2.3 GB". */
export function sizeText(bytes: number): string {
  const mb = bytes / 1048576;
  if (mb < 1024) return `${Math.max(1, Math.round(mb))} MB`;
  const gb = Math.round(mb / 1024 * 10) / 10;
  return `${gb % 1 ? gb.toFixed(1) : gb.toFixed(0)} GB`;
}
/** The limit line the apps show: "Up to 60 minutes and 2 GB". */
export function limitText(maxSec: number, maxMb: number): string {
  return `Up to ${limitLength(maxSec)} and ${sizeText(maxMb * 1048576)}`;
}
/** A length limit in words: "60 minutes", "30 seconds". */
export const limitLength = (maxSec: number) => (maxSec % 60 === 0 && maxSec >= 120 ? `${maxSec / 60} minutes` : `${maxSec} seconds`);

/** The import errors, each naming the limit it hit (and the whole rule, as the apps show it). */
export const tooLongError = (sec: number, maxSec: number, maxMb: number) =>
  new ApiError(400, 'too_long', `This video is ${lengthText(sec)} long · the limit is ${limitLength(maxSec)} (imports: ${limitText(maxSec, maxMb).replace(/^Up/, 'up')})`);
export const tooBigError = (bytes: number, maxMb: number, maxSec: number) =>
  new ApiError(422, 'link_too_big', `This video is ${sizeText(bytes)} · the limit is ${sizeText(maxMb * 1048576)} (imports: ${limitText(maxSec, maxMb).replace(/^Up/, 'up')})`);

/**
 * A Library clip picked for a Suite tool that takes at most `maxSec` of source: a plain reason, with the numbers the
 * apps need to offer the trim. Null when it fits.
 */
export function suiteSourceTooLong(seconds: number | null | undefined, tool: 'Swap' | 'Recast', maxSec = SUITE_SOURCE_MAX_SEC): ApiError | null {
  if (!(typeof seconds === 'number' && seconds > maxSec + 0.05)) return null;
  const how = tool === 'Swap' ? 'pick the part to use in New Swap, or trim it in Edit first' : 'trim it in Edit first, or pick the part in New Swap';
  return Object.assign(new ApiError(400, 'clip_too_long', `This clip is ${lengthText(seconds)} · ${tool} takes up to ${maxSec} s: ${how}`),
    { extra: { tool: tool.toLowerCase(), maxSeconds: maxSec, clipSeconds: Math.round(seconds * 1000) / 1000 } });
}

/** Free space (bytes) on the file system holding `dir` (the temp dir); null when it can't be read. */
export function freeBytes(dir = os.tmpdir()): number | null {
  try { const s = fs.statfsSync(dir); return Number(s.bavail) * Number(s.bsize); } catch { return null; }
}
/** Refuses before a large temp write when the disk is short: needs `bytes` plus the reserve. */
export function requireTempSpace(bytes: number, reserveMb: number, free: (dir?: string) => number | null = freeBytes) {
  const have = free();
  if (have == null) return;
  const need = bytes + reserveMb * 1048576;
  if (have < need) throw new ApiError(507, 'server_disk_full', `The server is short of temporary space for this video (${sizeText(bytes)} needs ${sizeText(need)} free, ${sizeText(have)} left) · try again in a few minutes, or import a shorter video`);
}
