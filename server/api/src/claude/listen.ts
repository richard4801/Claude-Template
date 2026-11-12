// Claude listens (free, ffmpeg only): the loudness of a video's or audio file's sound, or of an edit's mixed sound as
// it plays, over time in four bands (all, bass 20–150 Hz, mid 150–2000 Hz, highs above 2 kHz) every 0.1 s, plus the
// moments that matter for editing to music: bass hits, drops (a big jump in bass after a quieter stretch), the loudest
// moment and the silent stretches, and EBU R128 loudness (LUFS, range, peak). Numbers, with an optional small graph.
// One ffmpeg pass at a time (lib/mediaLane.ts).
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { and, eq } from 'drizzle-orm';
import sharp from 'sharp';
import type { AuthUser, Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import { BEAT_SR, decodeMono } from '../editor/audio.js';
import type { EditTool, ToolEnv } from '../editor/mcpTools.js';
import type * as M from '../editor/model.js';
import { renderSound } from '../editor/render.js';
import { editorAi } from '../editor/service.js';
import { LEAN_DECODE, oneAtATime } from '../lib/mediaLane.js';
import { mediaToolsAvailable } from '../replicate/media.js';
import { readyIfStored } from '../storage/objects.js';
import { IN_EDIT, videoOf, watchTarget } from './watch.js';

const MAX_SEC = 600;

/** RBJ biquad (low- or high-pass, Q 0.707), run in place over a copy. */
function biquad(x: Float32Array, sr: number, f0: number, kind: 'low' | 'high'): Float32Array {
  const w = (2 * Math.PI * f0) / sr, cw = Math.cos(w), al = Math.sin(w) / (2 * Math.SQRT1_2);
  const b0 = kind === 'low' ? (1 - cw) / 2 : (1 + cw) / 2, b1 = kind === 'low' ? 1 - cw : -(1 + cw), b2 = b0;
  const a0 = 1 + al, a1 = -2 * cw, a2 = 1 - al;
  const y = new Float32Array(x.length);
  let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (let i = 0; i < x.length; i++) {
    const v = (b0 * x[i]! + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
    x2 = x1; x1 = x[i]!; y2 = y1; y1 = v; y[i] = v;
  }
  return y;
}

const db = (e: number) => Math.max(-90, Math.round(10 * Math.log10(1e-12 + e) * 10) / 10);

/** Per-window RMS in dBFS. */
function curve(x: Float32Array, sr: number, hopSec: number): number[] {
  const h = Math.max(1, Math.round(hopSec * sr)), out: number[] = [];
  for (let i = 0; i + 1 <= x.length; i += h) { let e = 0; const end = Math.min(x.length, i + h); for (let k = i; k < end; k++) e += x[k]! * x[k]!; out.push(db(e / (end - i))); }
  return out;
}

export type Listening = {
  durationSec: number; stepSec: number; meanDb: number; loudest: { t: number; db: number };
  curves: { all: number[]; bass: number[]; mid: number[]; highs: number[] };
  bassHits: { t: number; rise: number }[]; drops: { t: number; rise: number }[];
  silent: { fromSec: number; toSec: number }[]; howToRead: string;
};

/** The analysis on mono samples (exported for tests). */
export function analyse(x: Float32Array, sr = BEAT_SR): Listening {
  const dur = x.length / sr, step = dur <= 120 ? 0.1 : dur <= 300 ? 0.25 : 0.5;
  const all = curve(x, sr, step), bass = curve(biquad(biquad(x, sr, 150, 'low'), sr, 20, 'high'), sr, step), highs = curve(biquad(x, sr, 2000, 'high'), sr, step);
  const mid = curve(biquad(biquad(x, sr, 2000, 'low'), sr, 150, 'high'), sr, step);
  const t = (i: number) => Math.round(i * step * 100) / 100;
  let li = 0; all.forEach((v, i) => { if (v > all[li]!) li = i; });
  const loud = all[li] ?? -90, floor = Math.max(-60, loud - 45);
  const mean = (() => { const v = all.filter(d => d > floor); return v.length ? Math.round(10 * 10 * Math.log10(v.reduce((s, d) => s + 10 ** (d / 10), 0) / v.length)) / 10 : -90; })();
  // Bass hits: a rise of the bass level of at least 4 dB over the last 0.2 s that is a local peak (±0.15 s), above the floor.
  const back = Math.max(1, Math.round(0.2 / step)), near = Math.max(1, Math.round(0.15 / step)), gap = Math.max(1, Math.round(0.12 / step));
  const hits: { t: number; rise: number }[] = [];
  for (let i = 1; i < bass.length; i++) {
    const b = bass[i]!; if (b < floor) continue;
    const prev = Math.min(...bass.slice(Math.max(0, i - back), i)), rise = b - prev;
    if (rise < 4) continue;
    let peak = true; for (let k = Math.max(0, i - near); k <= Math.min(bass.length - 1, i + near); k++) if (bass[k]! > b) { peak = false; break; }
    if (!peak) continue;
    if (hits.length && i - Math.round(hits.at(-1)!.t / step) < gap) { if (rise > hits.at(-1)!.rise) hits[hits.length - 1] = { t: t(i), rise: Math.round(rise * 10) / 10 }; continue; }
    hits.push({ t: t(i), rise: Math.round(rise * 10) / 10 });
  }
  // Drops: the bass level of the next 1 s is at least 6 dB above the 2 s before (a section that hits much harder).
  const win1 = Math.max(1, Math.round(1 / step)), win2 = Math.max(1, Math.round(2 / step));
  const avg = (a: number, b: number) => { let s = 0, c = 0; for (let k = Math.max(0, a); k < Math.min(bass.length, b); k++) { s += 10 ** (bass[k]! / 10); c++; } return c ? 10 * Math.log10(s / c) : -90; };
  const drops: { t: number; rise: number }[] = [];
  // A run of windows that all qualify is one drop: it lands where the rise is biggest, then on the strongest bass
  // within the next 0.3 s (the hit itself).
  let best = -1, bestRise = 0;
  const flush = () => {
    if (best < 0) return;
    // the first bass peak in the louder second that is clearly above the stretch before it
    const before = avg(best - win2, best), top = Math.max(...bass.slice(best, best + win1 + 1));
    let j = best;
    for (let k = best; k < Math.min(bass.length, best + win1 + 1); k++) {
      if (bass[k]! < before + 6 || bass[k]! < top - 6) continue;
      let pk = true; for (let q = Math.max(0, k - near); q <= Math.min(bass.length - 1, k + near); q++) if (bass[q]! > bass[k]!) { pk = false; break; }
      if (pk) { j = k; break; }
    }
    if (!drops.length || j - Math.round(drops.at(-1)!.t / step) > win2) drops.push({ t: t(j), rise: Math.round(bestRise * 10) / 10 });
    best = -1; bestRise = 0;
  };
  for (let i = win2; i + 1 < bass.length; i++) {
    const rise = avg(i, i + win1) - avg(i - win2, i);
    if (rise >= 6 && bass[i]! >= floor) { if (rise > bestRise) { bestRise = rise; best = i; } }
    else flush();
  }
  flush();
  const silent: { fromSec: number; toSec: number }[] = [];
  let s0 = -1; const minSil = Math.max(1, Math.round(0.4 / step));
  all.forEach((v, i) => { const q = v < floor; if (q && s0 < 0) s0 = i; if ((!q || i === all.length - 1) && s0 >= 0) { const e = q ? i + 1 : i; if (e - s0 >= minSil) silent.push({ fromSec: t(s0), toSec: Math.min(Math.round(dur * 100) / 100, t(e)) }); s0 = -1; } });
  return {
    durationSec: Math.round(dur * 1000) / 1000, stepSec: step, meanDb: mean, loudest: { t: t(li), db: loud },
    curves: { all, bass, mid, highs }, bassHits: hits, drops, silent,
    howToRead: `curves.* are levels in dBFS, one value every ${step} s from 0 (index × ${step} = seconds): all = the whole sound, bass = 20–150 Hz (kicks, 808s, drops), mid = 150–2000 Hz (voice, melody), highs = above 2 kHz (hats, claps, sibilance). bassHits = sharp bass rises (a kick or bass hit), rise in dB. drops = where the bass gets much heavier than the 2 s before (the drop), rise in dB. silent = stretches ${Math.round(loud - floor)} dB below the loudest moment. Use these for cuts on hits, the drop moment, and where the sound ends; detect_beats gives the tempo grid.`,
  };
}

/** EBU R128 loudness of the sound (one audio-only pass): integrated LUFS, loudness range and sample peak. Null when unreadable. */
function r128(ffmpeg: string, input: string, fromSec: number, lenSec: number): Promise<Loudness> {
  const none = { integratedLufs: null, rangeLu: null, peakDb: null };
  return new Promise(resolve => execFile(ffmpeg, ['-hide_banner', '-nostats', '-v', 'info', ...LEAN_DECODE, ...(fromSec > 0 ? ['-ss', fromSec.toFixed(3)] : []), '-vn', '-sn', '-dn', '-i', input,
    '-t', lenSec.toFixed(3), '-af', 'ebur128=peak=sample:framelog=quiet', '-f', 'null', '-'], { timeout: 180_000, maxBuffer: 8 * 1024 * 1024 }, (err, _o, stderr) => {
    if (err) return resolve(none);
    const tail = String(stderr).slice(String(stderr).lastIndexOf('Summary:'));
    const num = (re: RegExp) => { const m = tail.match(re); return m && Number.isFinite(Number(m[1])) ? Number(m[1]) : null; };
    resolve({ integratedLufs: num(/I:\s*(-?[\d.]+) LUFS/), rangeLu: num(/LRA:\s*(-?[\d.]+) LU/), peakDb: num(/Peak:\s*(-?[\d.]+) dBFS/) });
  }));
}
export type Loudness = { integratedLufs: number | null; rangeLu: number | null; peakDb: number | null };

/** Whether the file has a sound track at all (true when ffprobe can't tell). */
function hasSound(ffprobe: string, input: string): Promise<boolean> {
  return new Promise(resolve => execFile(ffprobe, ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=index', '-of', 'csv=p=0', input], { timeout: 60_000 },
    (err, out) => resolve(err ? true : String(out).trim().length > 0)));
}

/** The analysis of a file's sound from fromSec (times in the file's seconds), with its R128 loudness. */
async function hear(ctx: Ctx, input: string, rid: string, fromSec: number, toSec?: number): Promise<Listening & { loudness: Loudness; fromSec: number }> {
  const len = Math.min(MAX_SEC, toSec !== undefined ? toSec - fromSec : MAX_SEC);
  const x = await decodeMono(ctx.config.FFMPEG_PATH, input, len, fromSec).catch(async e => {
    if (!(await hasSound(ctx.config.FFPROBE_PATH, input))) return new Float32Array(0); // a video with no sound track
    throw e;
  });
  if (x.length < BEAT_SR * 0.2) throw badRequest(`${rid} has no sound to listen to${fromSec > 0 ? ` from ${fromSec} s` : ''}`);
  const r = analyse(x);
  const loudness = await r128(ctx.config.FFMPEG_PATH, input, fromSec, len);
  if (!(fromSec > 0)) return { ...r, loudness, fromSec: 0 };
  const sh = (t: number) => Math.round((t + fromSec) * 100) / 100;
  return { ...r, fromSec, loudness, loudest: { ...r.loudest, t: sh(r.loudest.t) }, bassHits: r.bassHits.map(h => ({ ...h, t: sh(h.t) })), drops: r.drops.map(d => ({ ...d, t: sh(d.t) })),
    silent: r.silent.map(q => ({ fromSec: sh(q.fromSec), toSec: sh(q.toSec) })), howToRead: `${r.howToRead} Index 0 of the curves is ${fromSec} s; every time listed is in the file's own seconds.` };
}

type Heard = Record<string, unknown> & { curves?: Listening['curves']; bassHits?: Listening['bassHits']; drops?: Listening['drops']; stepSec?: number; fromSec?: number };
const cache = new Map<string, Heard>();
const remember = (k: string, v: Heard) => { cache.set(k, v); while (cache.size > 16) cache.delete(cache.keys().next().value!); return v; };

/** Listen to a video's or audio file's sound (an id, as watch takes it), or in Edit with no id the edit's mixed sound. */
export async function listenTo(ctx: Ctx, u: AuthUser, a: Record<string, unknown> | unknown): Promise<Heard> {
  if (!(await mediaToolsAvailable(ctx.config.FFMPEG_PATH, ctx.config.FFPROBE_PATH))) throw new ApiError(503, 'unavailable', 'Listening needs ffmpeg on the server, which is missing here');
  const args: Record<string, unknown> = a && typeof a === 'object' ? a as Record<string, unknown> : { id: a };
  const fromSec = args.fromSec === undefined ? 0 : Number(args.fromSec), toSec = args.toSec === undefined ? undefined : Number(args.toSec);
  if (!(fromSec >= 0) || (toSec !== undefined && !(toSec > fromSec))) throw badRequest('fromSec/toSec: seconds from the start, toSec > fromSec');
  const sid = typeof args.sessionId === 'string' && args.sessionId ? args.sessionId : undefined;
  if (sid && args.id === undefined && args.itemId === undefined && args.takeId === undefined) {
    // The edit as it plays: every clip's sound, music and voice-over mixed like the export, in timeline seconds.
    const { editSessionsOf } = await import('../editor/sessions.js');
    const { rendersOf } = await import('../editor/renders.js');
    const s = await editSessionsOf(ctx).row(u, sid);
    const p = s.project as unknown as M.EditProject;
    const ck = `${u.studioId}|edit|${s.id}|${s.revision}|${fromSec}|${toSec}`;
    const hit = cache.get(ck);
    if (hit) return hit;
    const r = await oneAtATime(async (): Promise<Heard> => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-listen-'));
      try {
        const files = await rendersOf(ctx).files(s.studioId, { ...p, assets: p.assets.filter(x => x.kind === 'video' || x.kind === 'audio') }, dir);
        const out = path.join(dir, 'sound.flac');
        const mixed = await renderSound({ ffmpeg: ctx.config.FFMPEG_PATH, ffprobe: ctx.config.FFPROBE_PATH }, p, files, out);
        if (!mixed.hasAudio) return { durationSec: mixed.durationSec, note: 'The edit is silent: no clip with sound, or all of them muted.' };
        return { ...(await hear(ctx, out, s.id, fromSec, toSec)), durationSec: Math.round(mixed.durationSec * 1000) / 1000 };
      } finally { fs.rmSync(dir, { recursive: true, force: true }); }
    });
    return remember(ck, { source: { sessionId: s.id, revision: s.revision, timeline: true }, ...r });
  }
  const target = await watchTarget({ ctx, user: u }, args);
  let key: string, rid: string;
  const [au] = typeof target === 'string' ? await ctx.db.select().from(uploads).where(and(eq(uploads.id, target), eq(uploads.studioId, u.studioId))) : [];
  if (au && /^audio\//i.test(au.contentType)) {
    if (!(await readyIfStored(ctx, au))) throw new ApiError(409, 'not_ready', `${au.id}: the upload hasn't arrived on the server yet`);
    key = au.storageKey; rid = au.id;
  } else { const v = await videoOf(ctx, u, target); key = v.key; rid = v.id; }
  const ck = `${u.studioId}|${key}|${fromSec}|${toSec}`;
  const hit = cache.get(ck);
  if (hit) return hit;
  const r = await oneAtATime(() => editorAi(ctx).withLocalInput(key, input => hear(ctx, input, rid, fromSec, toSec)));
  return remember(ck, { id: rid, ...r });
}

/** A small graph (PNG, 640×180): all grey, mid blue, bass orange; drops as red lines, bass hits as ticks. */
export async function listenGraph(r: Heard): Promise<Buffer | null> {
  const c = r.curves;
  if (!c?.bass.length) return null;
  const W = 640, H = 180, n = c.bass.length, step = r.stepSec ?? 0.1, from = r.fromSec ?? 0;
  const x = (i: number) => (i / Math.max(1, n - 1)) * W, y = (v: number) => H - 14 - ((Math.max(-70, v) + 70) / 70) * (H - 24);
  const line = (v: number[], col: string) => `<polyline fill="none" stroke="${col}" stroke-width="1.4" points="${v.map((d, i) => `${x(i).toFixed(1)},${y(d).toFixed(1)}`).join(' ')}"/>`;
  const tx = (t: number) => ((t - from) / Math.max(step, (n - 1) * step)) * W;
  const marks = [...(r.bassHits ?? []).map(h => `<line x1="${tx(h.t).toFixed(1)}" x2="${tx(h.t).toFixed(1)}" y1="${H - 12}" y2="${H}" stroke="#f90"/>`),
    ...(r.drops ?? []).map(d => `<line x1="${tx(d.t).toFixed(1)}" x2="${tx(d.t).toFixed(1)}" y1="0" y2="${H}" stroke="#e33" stroke-width="2"/><text x="${(tx(d.t) + 3).toFixed(1)}" y="11" font-size="10" fill="#e33" font-family="DejaVu Sans Mono, monospace">${d.t.toFixed(1)}s</text>`)];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><rect width="100%" height="100%" fill="#111"/>${line(c.all, '#888')}${line(c.mid, '#4a8fe7')}${line(c.bass, '#f90')}${marks.join('')}</svg>`;
  return sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toBuffer();
}

const str = (d: string, max?: number) => ({ type: 'string', description: d, ...(max ? { maxLength: max } : {}) });
export const LISTEN_TOOLS: EditTool[] = [{
  name: 'listen', title: 'Listen to the sound (free)', scope: 'edit:read', readOnly: true, idempotent: true,
  description: 'Measure the sound of a video or audio file over time, or in Edit (no id) the edit\'s own mixed sound as it plays, in timeline seconds: loudness (EBU R128 LUFS, range, peak), levels every 0.1 s in four bands (all, bass 20–150 Hz, mid 150–2000 Hz, highs above 2 kHz), the bass hits, the drop(s), the loudest moment and the silent stretches, all with timestamps. Use it before you cut to music, find "the drop", sync an action to a hit or say where the sound ends; never guess those from the picture; detect_beats gives the tempo grid. Takes the same ids as watch (a take, Library item, clip, upload, attached video, or in Edit a timeline item) or an audio upload id (music, voice-over). fromSec/toSec listen to part of it; graph: true adds a small picture of the curves. Free; numbers only unless graph.',
  inputSchema: { type: 'object', additionalProperties: false, properties: {
    id: str('A take, job, Library item, clip, uploaded video or audio (get_edit\'s watchId), or /uploads/… link. Leave out in Edit for the edit\'s own sound', 300),
    takeId: str('The take open on the page (filled in for you)', 80), ...IN_EDIT,
    fromSec: { type: 'number', minimum: 0, description: 'Only from this second (default 0)' }, toSec: { type: 'number', minimum: 0, description: 'Only up to this second (default the end; at most 600 s are read)' },
    graph: { type: 'boolean', description: 'Also a small PNG graph of the curves (default false)' } } },
  run: async (env: ToolEnv, a) => {
    const r = await listenTo(env.ctx, env.user, a);
    const png = a.graph === true ? await listenGraph(r) : null;
    return png ? { ...r, mcpContent: [{ type: 'text', text: JSON.stringify(r) }, { type: 'image', data: png.toString('base64'), mimeType: 'image/png' }], structuredContent: r } : r;
  },
}];
