// Claude listens (free, ffmpeg only): the loudness of a video's or audio file's sound over time, in three bands (all,
// bass 20–150 Hz, highs above 2 kHz) every 0.1 s, plus the moments that matter for editing to music: bass hits, drops
// (a big jump in bass after a quieter stretch), the loudest moment and the silent stretches. Numbers only, no images.
import { and, eq } from 'drizzle-orm';
import type { AuthUser, Ctx } from '../ctx.js';
import { uploads } from '../db/schema.js';
import { ApiError, badRequest } from '../errors.js';
import { BEAT_SR, decodeMono } from '../editor/audio.js';
import type { EditTool } from '../editor/mcpTools.js';
import { editorAi } from '../editor/service.js';
import { mediaToolsAvailable } from '../replicate/media.js';
import { oneAtATime, videoOf } from './watch.js';

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
  curves: { all: number[]; bass: number[]; highs: number[] };
  bassHits: { t: number; rise: number }[]; drops: { t: number; rise: number }[];
  silent: { fromSec: number; toSec: number }[]; howToRead: string;
};

/** The analysis on mono samples (exported for tests). */
export function analyse(x: Float32Array, sr = BEAT_SR): Listening {
  const dur = x.length / sr, step = dur <= 120 ? 0.1 : dur <= 300 ? 0.25 : 0.5;
  const all = curve(x, sr, step), bass = curve(biquad(biquad(x, sr, 150, 'low'), sr, 20, 'high'), sr, step), highs = curve(biquad(x, sr, 2000, 'high'), sr, step);
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
    curves: { all, bass, highs }, bassHits: hits, drops, silent,
    howToRead: `curves.* are levels in dBFS, one value every ${step} s from 0 (index × ${step} = seconds): all = the whole sound, bass = 20–150 Hz (kicks, 808s, drops), highs = above 2 kHz (hats, claps, sibilance). bassHits = sharp bass rises (a kick or bass hit), rise in dB. drops = where the bass gets much heavier than the 2 s before (the drop), rise in dB. silent = stretches ${Math.round(loud - floor)} dB below the loudest moment. Use these for cuts on hits, the drop moment, and where the sound ends; detect_beats gives the tempo grid.`,
  };
}

/** Listen to a video's or audio file's sound. */
export async function listenTo(ctx: Ctx, u: Pick<AuthUser, 'studioId'>, id: unknown): Promise<Listening & { id: string }> {
  if (!(await mediaToolsAvailable(ctx.config.FFMPEG_PATH, ctx.config.FFPROBE_PATH))) throw new ApiError(503, 'unavailable', 'Listening needs ffmpeg on the server, which is missing here');
  let key: string, rid: string;
  const [au] = typeof id === 'string' ? await ctx.db.select().from(uploads).where(and(eq(uploads.id, id), eq(uploads.studioId, u.studioId))) : [];
  if (au && /^audio\//i.test(au.contentType)) { key = au.storageKey; rid = au.id; }
  else { const v = await videoOf(ctx, u, id); key = v.key; rid = v.id; }
  return oneAtATime(() => editorAi(ctx).withLocalInput(key, async input => {
    const x = await decodeMono(ctx.config.FFMPEG_PATH, input, MAX_SEC);
    if (x.length < BEAT_SR * 0.2) throw badRequest(`${rid} has no sound to listen to`);
    return { id: rid, ...analyse(x) };
  }));
}

export const LISTEN_TOOLS: EditTool[] = [{
  name: 'listen', title: 'Listen to the sound (free)', scope: 'edit:read', readOnly: true, idempotent: true,
  description: 'Measure the sound of a video or audio file over time: loudness every 0.1 s in three bands (all, bass 20–150 Hz, highs above 2 kHz), the bass hits, the drop(s), the loudest moment and the silent stretches, all with timestamps. Use it before you cut to music, find "the drop", sync an action to a hit or say where the sound ends; never guess those from the picture. Takes the same ids as watch (a take, Library item, clip, upload or attached video) or an audio upload id. Free; numbers only.',
  inputSchema: { type: 'object', properties: { id: { type: 'string', description: 'A take, job, Library item, clip, uploaded video or audio, or /uploads/… link' }, takeId: { type: 'string', description: 'The take open on the page (filled in for you)' } } },
  run: async (env, a) => listenTo(env.ctx, env.user, (a as Record<string, unknown>).id ?? (a as Record<string, unknown>).takeId),
}];
