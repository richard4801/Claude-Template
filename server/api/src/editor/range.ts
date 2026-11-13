// Item-scoped paid helpers on part of their source (owner report ci_238dd2979f5a, 2026-11-13): Remove background on a
// 1.8 s clip used to send (and bill) the whole 102 s source. A job's `source.range` is the window the provider sees;
// the estimate and the run both price its length. The input is trimmed here with ffmpeg, and the result is padded back
// to the source's own length (black / silence outside the window), so `alphaMatte`, layer mattes and `audioAsset` stay
// "aligned with the clip's own asset" exactly as before (no contract change). Outside the window a matte is black (cut
// out): a trim later widened past it needs the helper run again.
import { spawn } from 'node:child_process';
import type { EditorJobKind, EditorSource } from './schema.js';
import { badRequest } from '../errors.js';

/** Kinds that work on a window of their source (the rest always take the whole source). */
export const RANGED_KINDS: readonly EditorJobKind[] = ['matte', 'layers', 'denoise'];
/** Seconds added on each side of a clip's own range (frame rounding, a later nudge of the trim); a window is at least minSec. */
export const RANGE = { padSec: 0.25, minSec: 1 } as const;

export type SourceRange = { startSec: number; endSec: number };
const ms = (x: number) => Math.round(x * 1000) / 1000;

/** The seconds a job processes (and is priced on): its window, or the whole source. */
export function sourceSec(s: EditorSource): number { return s.range ? ms(s.range.endSec - s.range.startSec) : s.durationSec; }

/** A clip's [inSec, outSec] (or several clips' union) → the window to send, padded and clamped to the source. Null = the whole source. */
export function clipWindow(spans: { inSec: number; outSec: number }[], durationSec: number | undefined): SourceRange | null {
  if (!spans.length) return null;
  if (!(durationSec && durationSec > 0)) durationSec = Infinity; // unknown here: the server clamps it to the source (parseRange)
  let a = Math.min(...spans.map(s => s.inSec)) - RANGE.padSec, b = Math.max(...spans.map(s => s.outSec)) + RANGE.padSec;
  if (b - a < RANGE.minSec) { const mid = (a + b) / 2; a = mid - RANGE.minSec / 2; b = mid + RANGE.minSec / 2; }
  if (a < 0) { b -= a; a = 0; }
  if (b > durationSec) { a = Math.max(0, a - (b - durationSec)); b = durationSec; }
  if (a <= 0.01 && b >= durationSec - 0.01) return null;
  return { startSec: ms(a), endSec: ms(b) };
}

/** `source.range` as sent: {startSec, endSec} inside the source (end clamped to it). Undefined when absent or the whole source. */
export function parseRange(raw: unknown, durationSec: number): SourceRange | undefined {
  if (raw === undefined || raw === null) return undefined;
  const r = raw as { startSec?: unknown; endSec?: unknown };
  if (typeof r !== 'object' || typeof r.startSec !== 'number' || typeof r.endSec !== 'number' || !Number.isFinite(r.startSec) || !Number.isFinite(r.endSec))
    throw badRequest('source.range: {startSec, endSec} in seconds of the source');
  if (r.startSec < 0 || r.endSec <= r.startSec + 0.05 || r.startSec >= durationSec - 0.05) throw badRequest(`source.range: inside the source (0–${durationSec} s), endSec after startSec`);
  // endSec past the end (a padded window, or a length the caller didn't know) is clamped to the source.
  const out = { startSec: ms(r.startSec), endSec: ms(Math.min(r.endSec, durationSec)) };
  return out.startSec <= 0.01 && out.endSec >= durationSec - 0.01 ? undefined : out;
}

function ff(ffmpeg: string, args: string[], timeoutMs = 5 * 60_000): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, ['-y', '-v', 'error', ...args], { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    const t = setTimeout(() => p.kill('SIGKILL'), timeoutMs);
    p.stderr.on('data', d => { err = (err + d).slice(-400); });
    p.on('error', e => { clearTimeout(t); reject(e); });
    p.on('close', code => { clearTimeout(t); code === 0 ? resolve() : reject(new Error(`ffmpeg: ${err || `exit ${code}`}`)); });
  });
}

/**
 * The window of the source for the provider: re-encoded so it starts exactly at startSec (frame-accurate; a stream copy
 * would start at the previous keyframe and shift the result). Video keeps its size and frame rate; `audio` keeps sound only.
 */
export async function trimRange(ffmpeg: string, input: string, out: string, r: SourceRange, kind: 'video' | 'audio') {
  const cut = ['-ss', r.startSec.toFixed(3), '-i', input, '-t', (r.endSec - r.startSec).toFixed(3)];
  if (kind === 'audio') await ff(ffmpeg, ['-threads', '2', ...cut, '-vn', '-c:a', 'pcm_s16le', out]);
  else await ff(ffmpeg, ['-threads', '2', ...cut, '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '14', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out]);
}

/**
 * A result made on the window, put back at its place in the source: black frames (a matte: cut out) or silence before
 * and after, so it runs the source's full length and lines up with the clip's own asset times.
 */
export async function padToSource(ffmpeg: string, file: string, out: string, r: SourceRange, fullSec: number, kind: 'video' | 'audio') {
  const lenSec = r.endSec - r.startSec, after = Math.max(0, fullSec - r.endSec);
  if (kind === 'audio') {
    const delayMs = Math.round(r.startSec * 1000);
    await ff(ffmpeg, ['-i', file, '-vn', '-af', `atrim=0:${lenSec.toFixed(3)},asetpts=PTS-STARTPTS,adelay=${delayMs}:all=1,apad=whole_dur=${fullSec.toFixed(3)}`, '-t', fullSec.toFixed(3), '-c:a', 'pcm_s16le', out]);
    return;
  }
  await ff(ffmpeg, ['-i', file, '-an', '-vf',
    `trim=duration=${lenSec.toFixed(3)},setpts=PTS-STARTPTS,format=gray,tpad=start_duration=${r.startSec.toFixed(3)}:start_mode=add:color=black:stop_duration=${after.toFixed(3)}:stop_mode=add,format=yuv420p`,
    '-t', fullSec.toFixed(3), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-threads', '2', '-movflags', '+faststart', out]);
}
