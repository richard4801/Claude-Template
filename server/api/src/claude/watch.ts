// Claude watches videos (plans/claude-video-vision.md, Stage 1, free): a "flip book" of any take, Suite job, Library
// item, clip or uploaded video in the person's studio. Frames are picked by motion (every hard cut, the motion peaks,
// and more frames where the picture moves fast than where it is still), packed into small timestamped JPEG contact
// sheets, with the video's length, frame rate, size and whether it has sound in the voice range. Beside that overview,
// watch returns a full sweep: frames at an even rate (up to 8 fps) over the whole video up to 60 s, so every second is
// seen; longer videos get a list of consecutive watch_closer windows to sweep. watch_closer gives every frame (or an
// even run, up to 96 for a sweep window) of a short window at a larger size. ffmpeg on the server only: nothing is paid or stored.
// Railway has ~512 MB: one watch runs at a time, frames are decoded streamed (the motion pass keeps two tiny frames),
// stills are written to a temp dir and packed small, and results are cached in memory.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { and, desc, eq } from 'drizzle-orm';
import { cameraAssets } from '../camera/schema.js';
import sharp from 'sharp';
import type { AuthUser, Ctx } from '../ctx.js';
import { clips, jobs, takes, uploads } from '../db/schema.js';
import { ApiError, badRequest, notFound } from '../errors.js';
import { findCuts, findPeaks, measureMotion, type MotionFrames } from '../editor/motion.js';
import type { EditTool } from '../editor/mcpTools.js';
import { editorAi } from '../editor/service.js';
import { mediaToolsAvailable, probe, type MediaInfo } from '../replicate/media.js';

export const SHEET_COLS = 4, SHEET_TILES = 16, MAX_SHEETS = 3, TILE_EDGE = 256, CLOSER_EDGE = 400, CLOSER_MAX = 16, SINGLE_EDGE = 1024;
// The full sweep: every part of the video at an even rate, beside the motion-picked overview. 24 frames a sheet, 4
// across (a row is a fixed slice of time, so the eye reads motion down the sheet), tiles ≤ 224 px so a sheet stays
// under ~1.4 MP in portrait and landscape. At most 8 sweep sheets + 3 overview sheets = 11 images a call.
export const SWEEP_EDGE = 224, SWEEP_TILES = 24, SWEEP_SHEETS = 8, SWEEP_MAX = SWEEP_TILES * SWEEP_SHEETS, SWEEP_FPS = 8, SWEEP_MAX_SEC = 60;
export const IMAGE_CAP = MAX_SHEETS + SWEEP_SHEETS;
/** watch_closer's largest even run (a sweep window): 4 sheets of sweep-size tiles. */
export const CLOSER_SWEEP_MAX = SWEEP_TILES * 4, SWEEP_WINDOW_SEC = 30;
const MAX_WATCH_SEC = 30 * 60, CACHE_MAX = 16, LABEL_H = 18;

type Video = { id: string; kind: 'take' | 'upload' | 'clip'; key: string; title?: string };
type Block = { type: 'image'; data: string; mimeType: 'image/jpeg' } | { type: 'text'; text: string };
export type Picked = { t: number; why: 'start' | 'end' | 'cut' | 'motion peak' | 'motion' };

// ---- what the id is ----------------------------------------------------------------------------------------------

/** The stored video an id names, in the person's studio only: a take (Suite, Library, edited version), a Suite job with
 * one take, an uploaded video (chat attachment, Edit upload) or an imported clip. */
export async function videoOf(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, id: unknown): Promise<Video> {
  // A stored file as the composer names it (/uploads/<key>, or the key itself): a swap source, guide or reference video.
  if (typeof id === 'string' && (id.includes('/') || /\.(mp4|mov|m4v|webm)$/i.test(id))) return videoByKey(ctx, u, id);
  if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,80}$/.test(id)) throw badRequest('id: a take, job, Library item, clip, uploaded video, camera session or /uploads/… link');
  // A camera session: its newest Blender guide clip (the greybox blocking); a camera asset: that file.
  if (id.startsWith('cs_') || id.startsWith('ca_')) {
    const rows = id.startsWith('cs_')
      ? await ctx.db.select().from(cameraAssets).where(and(eq(cameraAssets.sessionId, id), eq(cameraAssets.studioId, u.studioId), eq(cameraAssets.state, 'ready'))).orderBy(desc(cameraAssets.createdAt))
      : await ctx.db.select().from(cameraAssets).where(and(eq(cameraAssets.id, id), eq(cameraAssets.studioId, u.studioId)));
    const v = rows.find(r => /^video\//i.test(r.contentType) && (id.startsWith('ca_') || r.kind === 'greybox')) ?? rows.find(r => /^video\//i.test(r.contentType));
    if (v) return { id, kind: 'upload', key: v.storageKey, title: v.label ?? (v.kind === 'greybox' ? 'Blender guide (greybox)' : v.kind) };
    if (id.startsWith('cs_')) throw new ApiError(409, 'not_ready', `${id} has no rendered guide clip yet (render_camera_guides)`);
  }
  const [t] = await ctx.db.select().from(takes).where(and(eq(takes.id, id), eq(takes.studioId, u.studioId)));
  if (t) {
    if (t.kind === 'shot') throw badRequest(`${id} is a photo, not a video: look at it in the app or with the photo tools`);
    if (!t.mediaKey) throw new ApiError(409, 'not_ready', `${id} has no video yet`);
    return { id, kind: 'take', key: t.mediaKey, title: t.title };
  }
  const [j] = await ctx.db.select().from(jobs).where(and(eq(jobs.id, id), eq(jobs.studioId, u.studioId)));
  if (j) {
    const made = (await ctx.db.select().from(takes).where(and(eq(takes.jobId, id), eq(takes.studioId, u.studioId)))).filter(x => x.mediaKey && x.kind !== 'shot');
    if (made.length === 1) return { id: made[0]!.id, kind: 'take', key: made[0]!.mediaKey!, title: made[0]!.title };
    if (!made.length) throw new ApiError(409, 'not_ready', `${id} (“${j.title}”) has no finished take yet (${j.state})`);
    throw new ApiError(400, 'choose_take', `${id} made ${made.length} takes; watch each by its id: ${made.map(x => `${x.id} (${x.label || `take ${x.index}`})`).join(', ')}`);
  }
  const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.id, id), eq(uploads.studioId, u.studioId)));
  if (up) {
    if (!/^video\//i.test(up.contentType)) throw badRequest(`${id} is not a video (${up.contentType})`);
    if (up.state !== 'ready') {
      // Editor uploads (Edit's Uploads / timeline) are PUT straight to storage and never told "done": the row stays
      // pending although the file is there and plays. If the file has arrived, it is ready: mark it and watch it.
      const h = await ctx.storage.head(up.storageKey).catch(() => null);
      if (!h || !(h.size > 0)) throw new ApiError(409, 'not_ready', `${id}: the upload hasn't finished`);
      await ctx.db.update(uploads).set({ state: 'ready', bytes: h.size }).where(eq(uploads.id, up.id));
    }
    return { id, kind: 'upload', key: up.storageKey };
  }
  const [c] = await ctx.db.select().from(clips).where(and(eq(clips.id, id), eq(clips.studioId, u.studioId)));
  if (c?.storageKey) return { id, kind: 'clip', key: c.storageKey, title: c.name };
  throw notFound('Video');
}

/** A video named by its stored key or /uploads/ link, in the person's studio (an upload, clip, take or camera asset). */
async function videoByKey(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, raw: string): Promise<Video> {
  const key = (/\/uploads\/([A-Za-z0-9][A-Za-z0-9._/-]*)/.exec(raw)?.[1] ?? raw).replace(/^\/+/, '');
  if (!/^[A-Za-z0-9][A-Za-z0-9._/-]{0,299}$/.test(key) || key.includes('..')) throw badRequest('id: a studio video link (/uploads/…)');
  const [up] = await ctx.db.select().from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, u.studioId)));
  if (up) { if (!/^video\//i.test(up.contentType)) throw badRequest(`${raw} is not a video (${up.contentType})`); return { id: up.id, kind: 'upload', key }; }
  const [c] = await ctx.db.select().from(clips).where(and(eq(clips.storageKey, key), eq(clips.studioId, u.studioId)));
  if (c) return { id: c.id, kind: 'clip', key, title: c.name };
  const [t] = await ctx.db.select().from(takes).where(and(eq(takes.mediaKey, key), eq(takes.studioId, u.studioId)));
  if (t && t.kind !== 'shot') return { id: t.id, kind: 'take', key, title: t.title };
  const [ca] = await ctx.db.select().from(cameraAssets).where(and(eq(cameraAssets.storageKey, key), eq(cameraAssets.studioId, u.studioId)));
  if (ca && /^video\//i.test(ca.contentType)) return { id: ca.id, kind: 'upload', key, title: ca.label ?? ca.kind };
  throw notFound('Video');
}

// ---- one at a time ---------------------------------------------------------------------------------------------

let busy: Promise<unknown> = Promise.resolve();
let running = 0, maxRunning = 0;
/** Runs `fn` after every earlier watch has finished (one ffmpeg pipeline at a time on the small box). */
export function oneAtATime<T>(fn: () => Promise<T>): Promise<T> {
  const next = busy.then(async () => { running++; maxRunning = Math.max(maxRunning, running); try { return await fn(); } finally { running--; } });
  busy = next.catch(() => {});
  return next;
}
/** For tests: the most watches that ever ran at once. */
export const watchConcurrency = () => maxRunning;

// ---- picking frames by motion --------------------------------------------------------------------------------------

/**
 * Up to `budget` moments: the first and last frame, every hard cut (the frame before and the frame after), the motion
 * peaks (strongest first), then more where the picture moves: equal steps of accumulated motion, so a still stretch
 * gets few frames and a fast one many (down to neighbouring frames). Times in seconds, sorted.
 */
export function pickFrames(m: MotionFrames, budget: number): Picked[] {
  const n = m.energy.length;
  if (!n) return [];
  const at = (i: number) => Math.round((i / m.fps) * 1000) / 1000;
  const cuts = findCuts(m);
  const cutIdx = new Set(cuts.map(c => Math.round(c.t * m.fps)));
  const peaks = findPeaks(m, { cuts, minGapSec: 0.15, max: 60 }).sort((a, b) => b.strength - a.strength);
  const want: { i: number; why: Picked['why'] }[] = [{ i: 0, why: 'start' }, { i: n - 1, why: 'end' }];
  for (const c of cutIdx) { want.push({ i: c, why: 'cut' }); if (c > 0) want.push({ i: c - 1, why: 'cut' }); }
  for (const p of peaks) want.push({ i: Math.round(p.t * m.fps), why: 'motion peak' });
  // Motion-weighted spacing: a cut's jump isn't motion. Each frame's motion counts half against the whole video and
  // half against its own shot, so one busy shot can't starve a quick move in a calmer one; a floor keeps still
  // stretches from going unseen.
  const e = Array.from(m.energy, (v, i) => (cutIdx.has(i) ? 0 : v));
  const meanOf = (a: number, b: number) => { let s = 0; for (let i = a; i < b; i++) s += e[i]!; return b > a ? s / (b - a) : 0; };
  const mean = Math.max(meanOf(0, n), 1e-4);
  const bounds = [0, ...[...cutIdx].filter(c => c > 0 && c < n).sort((x, y) => x - y), n];
  const w = new Array<number>(n);
  for (let k = 0; k + 1 < bounds.length; k++) {
    const a = bounds[k]!, b = bounds[k + 1]!, sm = Math.max(meanOf(a, b), mean * 0.05, 1e-4);
    for (let i = a; i < b; i++) w[i] = 0.5 * (e[i]! / mean) + 0.5 * (e[i]! / sm) + 0.35;
  }
  const total = w.reduce((s, v) => s + v, 0);
  const steps = Math.max(1, budget);
  let acc = 0, k = 0;
  for (let i = 0; i < n && k < steps; i++) { acc += w[i]!; while (k < steps && acc >= ((k + 0.5) / steps) * total) { want.push({ i, why: 'motion' }); k++; } }
  const seen = new Set<number>(), out: { i: number; why: Picked['why'] }[] = [];
  for (const x of want) {
    if (out.length >= budget) break;
    const i = Math.min(n - 1, Math.max(0, x.i));
    if (!seen.has(i)) { seen.add(i); out.push({ i, why: x.why }); }
  }
  return out.sort((a, b) => a.i - b.i).map(x => ({ t: at(x.i), why: x.why }));
}

/** How many frames the overview shows for a video this long. */
export const budgetFor = (sec: number) => (sec <= 6 ? 24 : sec <= 15 ? 32 : SHEET_TILES * MAX_SHEETS);

/**
 * The sweep's frame rate for a video this long: 8 fps while that fits the 192-frame budget (up to 24 s), then as dense
 * as fits (6.4 fps at 30 s, 3.2 fps at 60 s), never above the video's own rate. 0 above SWEEP_MAX_SEC: no sweep.
 */
export function sweepFps(sec: number, srcFps = 30): number {
  if (!(sec > 0) || sec > SWEEP_MAX_SEC) return 0;
  return Math.min(SWEEP_FPS, SWEEP_MAX / sec, srcFps > 0 ? srcFps : SWEEP_FPS);
}

/** The sweep's source frames: evenly spaced from the first frame to the last, the same for the same video. */
export function sweepFrames(sec: number, srcFps: number): number[] {
  const f = sweepFps(sec, srcFps);
  if (!f) return [];
  const last = Math.max(0, Math.floor(sec * srcFps) - 1);
  const n = Math.min(SWEEP_MAX, last + 1, Math.max(2, Math.round(sec * f)));
  return [...new Set(Array.from({ length: n }, (_, k) => (n === 1 ? 0 : Math.round((k * last) / (n - 1)))))];
}

/** Consecutive watch_closer windows that cover every second of a video too long for the sweep. */
export function sweepWindows(sec: number): { fromSec: number; toSec: number; frames: number }[] {
  const out: { fromSec: number; toSec: number; frames: number }[] = [];
  const end = Math.min(sec, MAX_WATCH_SEC);
  for (let a = 0; a < end; a += SWEEP_WINDOW_SEC) out.push({ fromSec: a, toSec: Math.round(Math.min(end, a + SWEEP_WINDOW_SEC) * 1000) / 1000, frames: CLOSER_SWEEP_MAX });
  return out;
}

// ---- ffmpeg -------------------------------------------------------------------------------------------------------

function run(bin: string, args: string[], timeoutMs: number): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => execFile(bin, args, { timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
    if (err) reject(new Error(`${path.basename(bin)} failed: ${String(stderr ?? '').trim().split('\n').slice(-2).join(' | ').slice(0, 300) || err.message}`));
    else resolve({ stdout: String(stdout), stderr: String(stderr) });
  }));
}

/**
 * The source frames `frames` (frame numbers counted from `fromSec`) as JPEGs fitted inside `edge`×`edge`, in one
 * decoding pass (2 threads). Frames past the end are left out.
 */
async function grab(ffmpeg: string, input: string, frames: number[], edge: number, fromSec = 0, lenSec?: number): Promise<Map<number, Buffer>> {
  const want = [...new Set(frames)].sort((a, b) => a - b);
  // The box is small (~512 MB shared with the API): one decode thread, one filter thread, and at most GRAB_CHUNK frames
  // per ffmpeg run, so a big source (4K, 10-bit HEVC, 60 fps) never holds many full-size frames at once. A run that
  // still fails for memory is retried once in smaller chunks.
  const runChunk = async (part: number[], out: Map<number, Buffer>) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-watch-'));
    try {
      const sel = part.map(f => `eq(n,${f})`).join('+');
      await run(ffmpeg, ['-v', 'error', '-threads', '1', '-filter_threads', '1', ...(fromSec > 0 ? ['-ss', fromSec.toFixed(3)] : []), '-i', input, ...(lenSec ? ['-t', lenSec.toFixed(3)] : []), '-an', '-sn', '-dn',
        '-vf', `select='${sel}',scale=${edge}:${edge}:force_original_aspect_ratio=decrease:flags=bilinear`, '-fps_mode', 'vfr', '-frames:v', String(part.length), '-q:v', '5', path.join(dir, 'f%04d.jpg')], 180_000);
      const files = fs.readdirSync(dir).filter(f => f.endsWith('.jpg')).sort();
      files.forEach((f, i) => { if (part[i] !== undefined) out.set(part[i]!, fs.readFileSync(path.join(dir, f))); });
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  };
  const out = new Map<number, Buffer>();
  const pass = async (size: number) => { for (let i = 0; i < want.length; i += size) { const part = want.slice(i, i + size).filter(f => !out.has(f)); if (part.length) await runChunk(part, out); } };
  try { await pass(GRAB_CHUNK); } catch (e) {
    if (!/alloc|memory|killed|SIGKILL/i.test(String((e as Error)?.message ?? e))) throw e;
    await pass(Math.max(8, GRAB_CHUNK >> 2));
  }
  return out;
}
const GRAB_CHUNK = 64;

/** Sound: present or not, its level, and how long it is active in the voice range (200–3500 Hz). Not words. */
async function soundOf(ffmpeg: string, input: string, info: MediaInfo) {
  if (!info.audioCodec) return { present: false };
  try {
    const { stderr } = await run(ffmpeg, ['-hide_banner', '-nostats', '-v', 'info', '-i', input, '-t', String(MAX_WATCH_SEC), '-vn', '-sn',
      '-af', 'volumedetect,highpass=f=200,lowpass=f=3500,silencedetect=n=-38dB:d=0.35', '-f', 'null', '-'], 120_000);
    const num = (re: RegExp) => { const m = stderr.match(re); return m ? (m[1] === '-inf' ? null : Number(m[1])) : null; };
    const d = Math.min(info.duration || 0, MAX_WATCH_SEC);
    let quiet = 0, open: number | null = null;
    for (const m of stderr.matchAll(/silence_(start|end): (-?[\d.]+)/g)) {
      if (m[1] === 'start') open = Number(m[2]);
      else if (open !== null) { quiet += Number(m[2]) - open; open = null; }
    }
    if (open !== null) quiet += Math.max(0, d - open);
    const active = Math.max(0, d - quiet);
    return { present: true, meanDb: num(/mean_volume:\s*(-?[\d.]+|-inf) dB/), peakDb: num(/max_volume:\s*(-?[\d.]+|-inf) dB/),
      voiceRangeActiveSec: Math.round(active * 10) / 10, voiceRangeActivePct: d ? Math.round((active / d) * 100) : 0,
      note: 'Sound level in the voice range only, not words: voice, singing and music all count. Silent or near-silent below about 5%.' };
  } catch { return { present: true, note: 'has a sound track (its level could not be measured)' }; }
}

const mmss = (t: number) => `${Math.floor(t / 60)}:${(t % 60).toFixed(2).padStart(5, '0')}`;

/** Timestamped contact sheets, `SHEET_COLS` across, tiles fitted inside `edge` px, read left→right, top→bottom. */
async function sheets(tiles: { t: number; tag?: string; jpg: Buffer }[], edge: number, perSheet = SHEET_TILES, quality = 72): Promise<{ from: number; to: number; jpg: Buffer }[]> {
  const out: { from: number; to: number; jpg: Buffer }[] = [];
  for (let s = 0; s < tiles.length; s += perSheet) {
    const part = tiles.slice(s, s + perSheet);
    const metas = await Promise.all(part.map(p => sharp(p.jpg).metadata()));
    const tw = Math.max(...metas.map(m => m.width ?? edge)), th = Math.max(...metas.map(m => m.height ?? edge));
    const cols = Math.min(SHEET_COLS, part.length), rows = Math.ceil(part.length / SHEET_COLS);
    const comps = part.flatMap((p, i) => {
      const left = (i % SHEET_COLS) * tw, top = Math.floor(i / SHEET_COLS) * (th + LABEL_H);
      const label = `${mmss(p.t)}${p.tag ? ` ${p.tag}` : ''}`;
      const svg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${tw}" height="${LABEL_H}"><rect width="100%" height="100%" fill="#111"/><text x="4" y="13" font-size="12" fill="#fff" font-family="DejaVu Sans Mono, monospace">${label}</text></svg>`);
      return [{ input: p.jpg, left, top }, { input: svg, left, top: top + th }];
    });
    const jpg = await sharp({ create: { width: cols * tw, height: rows * (th + LABEL_H), channels: 3, background: '#111111' } }).composite(comps).jpeg({ quality }).toBuffer();
    out.push({ from: part[0]!.t, to: part.at(-1)!.t, jpg });
  }
  return out;
}

// ---- watch and look closer -----------------------------------------------------------------------------------------

type Overview = { meta: Record<string, unknown>; blocks: Block[] };
const cache = new Map<string, Overview>();
const remember = (k: string, v: Overview) => { cache.set(k, v); while (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value!); return v; };

async function ready(ctx: Ctx) {
  if (!(await mediaToolsAvailable(ctx.config.FFMPEG_PATH, ctx.config.FFPROBE_PATH))) throw new ApiError(503, 'unavailable', 'Watching videos needs ffmpeg on the server, which is missing here');
}

/** The flip book of a whole video: facts, the picked moments, the sound, and the contact sheets. Cached per video. */
export async function watchVideo(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, id: unknown): Promise<Overview> {
  const v = await videoOf(ctx, u, id);
  const ck = `${u.studioId}|${v.key}`;
  const hit = cache.get(ck);
  if (hit) { cache.delete(ck); cache.set(ck, hit); return hit; }
  await ready(ctx);
  const c = ctx.config;
  return oneAtATime(() => editorAi(ctx).withLocalInput(v.key, async input => {
    const info = await probe(c.FFPROBE_PATH, input);
    const dur = Number.isFinite(info.duration) ? info.duration : 0;
    // Short videos: every frame up to 30 fps; long ones a lighter pass (the overview, then watch_closer on parts).
    const mfps = dur > 600 ? 1 : dur > 120 ? 4 : undefined;
    const m = await measureMotion(c.FFMPEG_PATH, c.FFPROBE_PATH, input, { width: 64, maxSec: MAX_WATCH_SEC, inputArgs: ['-threads', '1'], ...(mfps ? { fps: mfps } : {}) });
    const picks = pickFrames(m, budgetFor(dur));
    const fps = info.fps || m.fps, last = Math.max(0, Math.floor(dur * fps) - 1);
    const frameOf = (t: number) => Math.min(last, Math.max(0, Math.round(t * fps)));
    // One decoding pass for both: the motion-picked overview and the even sweep (shrunk to sweep size after).
    const sweep = sweepFrames(dur, fps);
    const got = await grab(c.FFMPEG_PATH, input, [...picks.map(p => frameOf(p.t)), ...sweep], TILE_EDGE);
    const tiles = picks.flatMap(p => { const jpg = got.get(frameOf(p.t)); return jpg ? [{ t: frameOf(p.t) / fps, tag: p.why === 'cut' ? 'CUT' : p.why === 'motion peak' ? '★' : undefined, jpg }] : []; });
    const sh = await sheets(tiles, TILE_EDGE);
    const cuts = findCuts(m).map(x => x.t);
    const cutAt = new Set(cuts.map(t => Math.round(t * fps)));
    const sweepTiles = (await Promise.all(sweep.map(async f => {
      const jpg = got.get(f);
      if (!jpg) return [];
      const small = await sharp(jpg).resize(SWEEP_EDGE, SWEEP_EDGE, { fit: 'inside' }).jpeg({ quality: 80 }).toBuffer();
      return [{ t: f / fps, tag: cutAt.has(f) ? 'CUT' : undefined, jpg: small }];
    }))).flat();
    const ssh = await sheets(sweepTiles, SWEEP_EDGE, SWEEP_TILES, 68);
    const sweepRate = sweepTiles.length > 1 ? Math.round(((sweepTiles.length - 1) / (sweepTiles.at(-1)!.t - sweepTiles[0]!.t || 1)) * 10) / 10 : 0;
    const windows = sweep.length ? [] : sweepWindows(dur);
    const sound = await soundOf(c.FFMPEG_PATH, input, info);
    const meta = {
      id: v.id, kind: v.kind, ...(v.title ? { title: v.title } : {}), durationSec: Math.round(dur * 1000) / 1000, fps, width: info.width, height: info.height,
      sound, cuts, frames: tiles.map(x => Math.round(x.t * 1000) / 1000), sheets: sh.length,
      sweep: ssh.length
        ? { frames: sweepTiles.length, fps: sweepRate, everySec: Math.round((1 / (sweepRate || 1)) * 1000) / 1000, sheets: ssh.length, fromSec: Math.round(sweepTiles[0]!.t * 1000) / 1000, toSec: Math.round(sweepTiles.at(-1)!.t * 1000) / 1000 }
        : { frames: 0, sheets: 0, windows, note: `This video is longer than ${SWEEP_MAX_SEC} s, so it has no full sweep here: only the overview. Before you describe, judge or edit it, sweep ALL of it with watch_closer, one call per window, in order: ${windows.length} consecutive windows of ${SWEEP_WINDOW_SEC} s (fromSec/toSec as listed, frames: ${CLOSER_SWEEP_MAX}), so every second is seen. Then watch_closer again on any fast moment.` },
      ...(dur > MAX_WATCH_SEC ? { analysedSec: MAX_WATCH_SEC } : {}),
      howToRead: `Two parts. (1) The overview: ${sh.length} sheet(s) of frames picked by motion: CUT marks a hard cut (the frames either side), ★ a motion peak; fast stretches get more frames than still ones. ${ssh.length ? `(2) The full sweep: ${ssh.length} sheet(s), ${sweepTiles.length} frames evenly every ${(1 / (sweepRate || 1)).toFixed(2)} s from the first frame to the last, so every second of the video is on them.` : '(2) No full sweep: the video is too long; see sweep.windows.'} All sheets are ${SHEET_COLS} frames across, read left→right then top→bottom like a flip book, each frame labelled m:ss.ss. Go through EVERY sheet, in order, before you describe or judge anything; never summarise from a few frames. For any fast moment (hands, a face, text, a quick move, a glitch), call watch_closer on that time range to see every frame larger.`,
    };
    const blocks: Block[] = [{ type: 'text', text: JSON.stringify(meta) }];
    sh.forEach((s, i) => blocks.push({ type: 'text', text: `Sheet ${i + 1}/${sh.length}: ${mmss(s.from)}–${mmss(s.to)}` }, { type: 'image', data: s.jpg.toString('base64'), mimeType: 'image/jpeg' }));
    ssh.forEach((s, i) => blocks.push({ type: 'text', text: `Sweep ${i + 1}/${ssh.length}: ${mmss(s.from)}–${mmss(s.to)}` }, { type: 'image', data: s.jpg.toString('base64'), mimeType: 'image/jpeg' }));
    return remember(ck, { meta, blocks });
  }));
}

/** Every frame of a short window (or an even run of at most `count`), larger; one frame at `fromSec` when to = from. */
export async function watchCloser(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, id: unknown, fromSec: unknown, toSec: unknown, count?: unknown): Promise<Overview> {
  const v = await videoOf(ctx, u, id);
  const from = Number(fromSec), to = toSec === undefined ? from : Number(toSec);
  if (!Number.isFinite(from) || from < 0 || !Number.isFinite(to) || to < from) throw badRequest('fromSec/toSec: seconds from the start, toSec ≥ fromSec');
  if (to - from > 30) throw badRequest('watch_closer is for windows up to 30 s: use watch for the whole video, then look closer at parts');
  const max = Math.min(CLOSER_SWEEP_MAX, Math.max(1, Math.round(Number(count) || CLOSER_MAX)));
  const ck = `${u.studioId}|${v.key}|${from}|${to}|${max}`;
  const hit = cache.get(ck);
  if (hit) return hit;
  await ready(ctx);
  const c = ctx.config;
  return oneAtATime(() => editorAi(ctx).withLocalInput(v.key, async input => {
    const info = await probe(c.FFPROBE_PATH, input);
    if (from >= info.duration) throw badRequest(`fromSec: the video is ${info.duration.toFixed(2)} s long`);
    const fps = info.fps || 30, end = Math.min(to, info.duration);
    const all = Math.max(1, Math.floor((end - from) * fps) + 1), n = Math.min(all, max);
    const rel = [...new Set(Array.from({ length: n }, (_, i) => (n === 1 ? 0 : Math.round((i * (all - 1)) / (n - 1)))))];
    // Up to 16 frames large (12 a sheet); a longer run (a sweep window) at sweep size, 24 a sheet.
    const single = rel.length === 1, wide = rel.length > CLOSER_MAX, edge = single ? SINGLE_EDGE : wide ? SWEEP_EDGE : CLOSER_EDGE;
    const got = await grab(c.FFMPEG_PATH, input, rel, edge, from, end - from + 2 / fps);
    const tiles = rel.flatMap(f => { const jpg = got.get(f); return jpg ? [{ t: from + f / fps, jpg }] : []; });
    const step = rel.length > 1 ? (rel[1]! - rel[0]!) : 1;
    const meta = { id: v.id, fromSec: from, toSec: end, fps, frames: tiles.map(x => Math.round(x.t * 1000) / 1000),
      everyFrame: step === 1, ...(step > 1 ? { everyNthFrame: step, note: `More frames than ${max} in this window: every ${step}th frame. Narrow the window to see every frame.` } : {}) };
    const blocks: Block[] = [{ type: 'text', text: JSON.stringify(meta) }];
    if (single && tiles[0]) blocks.push({ type: 'text', text: `Frame at ${mmss(tiles[0].t)}` }, { type: 'image', data: tiles[0].jpg.toString('base64'), mimeType: 'image/jpeg' });
    else for (const s of await sheets(tiles, edge, wide ? SWEEP_TILES : 12, wide ? 68 : 72)) blocks.push({ type: 'text', text: `${mmss(s.from)}–${mmss(s.to)}, left→right then down` }, { type: 'image', data: s.jpg.toString('base64'), mimeType: 'image/jpeg' });
    return remember(ck, { meta, blocks });
  }));
}

// ---- the tools ----------------------------------------------------------------------------------------------------

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
const num = (d: string, min?: number, max?: number) => ({ type: 'number', description: d, ...(min !== undefined ? { minimum: min } : {}), ...(max !== undefined ? { maximum: max } : {}) });
const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const ID = str('A take id (Suite feed, Library, list_takes, an edited version), a Suite job id with one take, an imported clip id (a Swap/Recast source, uploaded or attached by link), the uploadId of a video attached to the chat, a camera session (cs_…: its Blender guide clip), or a video on screen by its /uploads/… link (suite_get_draft onScreen gives each one\'s id)', 300);
const result = (o: Overview) => ({ ...o.meta, mcpContent: o.blocks, structuredContent: o.meta });

const PHOTOS_MAX = 6;
export const WATCH_TOOLS: EditTool[] = [
  {
    name: 'watch', title: 'Watch a video (free)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: `Watch a video yourself: a take, a Library item, a clip or a video attached to the chat. Returns its length, frame rate, size and sound (present, level, how much is in the voice range; not the words), the hard cuts, and two flip books, each frame labelled with its time: an overview of frames picked by motion (every cut, the motion peaks, more frames where it moves fast) and a FULL SWEEP of the whole video at an even rate (about ${SWEEP_FPS} frames a second up to ${SWEEP_MAX / SWEEP_FPS} s, ${SWEEP_MAX} frames up to ${SWEEP_MAX_SEC} s). ALWAYS watch a video before you judge, compare, describe or edit it: never work from the person\'s description, the title or the prompt alone. Cover every second: go through every sheet of the sweep, then watch_closer on every fast moment (hands, a face, text, a quick move); never summarise from a few frames. Over ${SWEEP_MAX_SEC} s there is no sweep: sweep it yourself with watch_closer in the consecutive windows the result lists. Free; can take a few seconds.`,
    inputSchema: obj({ id: ID, takeId: str('The take open on the page (filled in for you)', 80) }),
    run: async (env, a) => result(await watchVideo(env.ctx, env.user, a.id ?? a.takeId)),
  },
  {
    name: 'watch_closer', title: 'Look closer at part of a video (free)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: `Every frame of a short window of a video (${CLOSER_MAX} frames by default, larger than watch's; an even run when the window has more), each labelled with its time: for a fast move, a hand, a face, text, a glitch. Use it on every fast moment of a video you are studying. frames up to ${CLOSER_SWEEP_MAX} (smaller tiles) sweeps a window of up to ${SWEEP_WINDOW_SEC} s: for a video too long for watch's sweep, call it on consecutive windows that cover every second. One frame at full detail when toSec is left out. Seconds from the video's start, as watch labels them. Free.`,
    inputSchema: obj({ id: ID, takeId: str('The take open on the page (filled in for you)', 80), fromSec: num('Start of the window (s)', 0), toSec: num('End of the window (s); leave out for one frame', 0),
      frames: num(`At most this many frames (default ${CLOSER_MAX}; up to ${CLOSER_SWEEP_MAX} to sweep a window)`, 1, CLOSER_SWEEP_MAX) }, ['fromSec']),
    run: async (env, a) => result(await watchCloser(env.ctx, env.user, a.id ?? a.takeId, a.fromSec, a.toSec, a.frames)),
  },
  {
    name: 'see_photos', title: 'See photos (free)', scope: 'edit:read', readOnly: true, idempotent: true,
    description: `Look at photos yourself: the stills a Photo run made and Library photos (their take ids), images attached to the chat or uploaded (upload ids) and any studio picture link (/uploads/…), up to ${PHOTOS_MAX} at once, each sized to about 1024 px with its id and title. Free. Videos: use watch.`,
    inputSchema: obj({ ids: { type: 'array', minItems: 1, maxItems: PHOTOS_MAX, items: { type: 'string', maxLength: 300 }, description: 'Photo take ids, image upload ids or /uploads/ links' } }, ['ids']),
    run: async (env, a) => seePhotos(env.ctx, env.user, a.ids),
  },
];

/** An uploaded image or a /uploads/ link of the studio, as a JPEG ≤ 1024 px. */
async function otherPhoto(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, id: string): Promise<Buffer> {
  const key = /\/uploads\/([A-Za-z0-9][A-Za-z0-9._/-]*)/.exec(id)?.[1];
  const [up] = key
    ? await ctx.db.select().from(uploads).where(and(eq(uploads.storageKey, key), eq(uploads.studioId, u.studioId)))
    : await ctx.db.select().from(uploads).where(and(eq(uploads.id, id), eq(uploads.studioId, u.studioId)));
  if (!up) throw new ApiError(404, 'not_found', `Photo ${id} not found in this studio (deleted, or not a take or upload id) · suite_feed or library lists the ids`);
  if (!/^image\//i.test(up.contentType)) throw badRequest(`${id} is not a picture (${up.contentType})${/^video\//i.test(up.contentType) ? ': watch it instead' : ''}`);
  const obj = await ctx.storage.get(up.storageKey);
  if (!obj) throw new ApiError(409, 'not_ready', `${id}: the image hasn't arrived yet`);
  const parts: Buffer[] = [];
  for await (const ch of obj.body) parts.push(ch as Buffer);
  return sharp(Buffer.concat(parts)).rotate().resize(1024, 1024, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 80 }).toBuffer();
}

/** Photo takes (kind "shot") of the person's studio as image blocks, small enough for Claude to read. */
export async function seePhotos(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, ids: unknown) {
  if (!Array.isArray(ids) || !ids.length || ids.length > PHOTOS_MAX || !ids.every(x => typeof x === 'string' && (/^[A-Za-z0-9_-]{1,80}$/.test(x) || /\/uploads\/[A-Za-z0-9][A-Za-z0-9._/-]{0,299}$/.test(x)))) {
    throw badRequest(`ids: 1 to ${PHOTOS_MAX} photo take ids, image upload ids or /uploads/ links`);
  }
  const blocks: Block[] = [];
  const seen: { id: string; title?: string }[] = [];
  for (const id of ids as string[]) {
    const [t] = await ctx.db.select().from(takes).where(and(eq(takes.id, id), eq(takes.studioId, u.studioId)));
    if (!t) {
      // Not a take: an uploaded image (a chat attachment, a reference) or a studio picture link.
      const up = await otherPhoto(ctx, u, id);
      blocks.push({ type: 'text', text: id }, { type: 'image', data: up.toString('base64'), mimeType: 'image/jpeg' });
      seen.push({ id });
      continue;
    }
    if (t.kind !== 'shot') throw badRequest(`${id} is a video: watch it instead`);
    if (!t.mediaKey) throw new ApiError(409, 'not_ready', `${id} has no image yet`);
    const obj = await ctx.storage.get(t.mediaKey);
    if (!obj) throw new ApiError(409, 'not_ready', `${id}: the image hasn't arrived yet`);
    const parts: Buffer[] = [];
    for await (const ch of obj.body) parts.push(ch as Buffer);
    const jpg = await sharp(Buffer.concat(parts)).rotate().resize(1024, 1024, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 80 }).toBuffer();
    blocks.push({ type: 'text', text: `${id}${t.title ? ` · ${t.title}` : ''}${t.label ? ` · ${t.label}` : ''}` }, { type: 'image', data: jpg.toString('base64'), mimeType: 'image/jpeg' });
    seen.push({ id, title: t.title ?? undefined });
  }
  return { mcpContent: blocks, structuredContent: { photos: seen } };
}
