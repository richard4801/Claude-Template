// AI suite · finishing a model's take (ffmpeg): the planned length and even loudness.
// - Length: some providers round a clip up (an 8 s request came back 10 s on H3), so a take longer than planned is cut
//   to the planned length (re-encoded so the cut lands exactly; otherwise the picture is stream-copied).
// - Loudness: model sound comes back at very different levels (H3 peaked near −50 dB), so the sound is levelled to
//   about −16 LUFS (two-pass loudnorm, linear when it can be; true peak ≤ −1.5 dBTP). True silence is left alone.
import { execFile } from 'node:child_process';
import type { MediaInfo } from '../replicate/media.js';

export const TARGET_LUFS = -16;
const TRUE_PEAK = -1.5;
const LRA = 11;
/** Longer than planned by more than this → cut. */
const TRIM_SLACK_SEC = 0.5;
/** A peak below this counts as silence: not levelled. */
const SILENCE_DB = -90;
/** Very faint sound is first raised so its peak sits here, else loudnorm's −70 LUFS gate reads it as silence. */
const PRE_PEAK_DB = -20;

function run(bin: string, args: string[], timeoutMs = 10 * 60_000): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) reject(new Error(`${bin.split('/').pop()} failed: ${String(stderr ?? '').trim().split('\n').slice(-3).join(' | ').slice(0, 400) || err.message}`));
      else resolve({ stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

export type Loudness = { i: number; tp: number; lra: number; thresh: number; offset: number };

/** The peak level of `file`'s sound in dBFS (volumedetect), or null without sound. */
export async function peakDb(ffmpeg: string, file: string, seconds?: number): Promise<number | null> {
  const { stderr } = await run(ffmpeg, ['-hide_banner', '-nostats', '-i', file, ...(seconds ? ['-t', seconds.toFixed(3)] : []), '-vn', '-af', 'volumedetect', '-f', 'null', '-']);
  const m = stderr.match(/max_volume:\s*(-?[\d.]+|-inf) dB/);
  return m ? (m[1] === '-inf' ? -Infinity : Number(m[1])) : null;
}

/** The integrated loudness of `file`'s sound (loudnorm's first pass) after `preDb` of gain, or null without sound. */
export async function measureLoudness(ffmpeg: string, file: string, seconds?: number, preDb = 0): Promise<Loudness | null> {
  const { stderr } = await run(ffmpeg, ['-hide_banner', '-nostats', '-i', file, ...(seconds ? ['-t', seconds.toFixed(3)] : []), '-vn',
    '-af', `${preDb ? `volume=${preDb.toFixed(2)}dB,` : ''}loudnorm=I=${TARGET_LUFS}:TP=${TRUE_PEAK}:LRA=${LRA}:print_format=json`, '-f', 'null', '-']);
  const m = stderr.match(/\{[^{}]*"input_i"[^{}]*\}/);
  if (!m) return null;
  const j = JSON.parse(m[0]) as Record<string, string>;
  const n = (k: string) => (j[k] === '-inf' ? -Infinity : j[k] === 'inf' ? Infinity : Number(j[k]));
  return { i: n('input_i'), tp: n('input_tp'), lra: n('input_lra'), thresh: n('input_thresh'), offset: n('target_offset') };
}

export type FinishPlan = { trimTo: number | null; level: boolean };

/** What finishing does to a take of `info` planned at `seconds` (null: no length rule, e.g. Extend or Recast). */
export function finishPlan(info: MediaInfo, seconds: number | null, o: { level: boolean }): FinishPlan {
  const trimTo = seconds != null && info.duration > seconds + TRIM_SLACK_SEC ? seconds : null;
  return { trimTo, level: o.level && !!info.audioCodec };
}

/**
 * `src` → `out` at the planned length with levelled sound. Returns what was done (for the job's notes), or null when
 * nothing needed doing (then `out` is not written).
 */
export async function finishTake(ffmpeg: string, src: string, out: string, info: MediaInfo, plan: FinishPlan): Promise<{ trimmedFrom?: number; levelledFrom?: number } | null> {
  let loud: Loudness | null = null, pre = 0, from = 0;
  if (plan.level) {
    const peak = await peakDb(ffmpeg, src, plan.trimTo ?? undefined);
    if (peak != null && peak > SILENCE_DB) {
      pre = peak < PRE_PEAK_DB ? PRE_PEAK_DB - peak : 0;
      loud = await measureLoudness(ffmpeg, src, plan.trimTo ?? undefined, pre);
      if (!loud || !Number.isFinite(loud.i)) loud = null;
      else { from = loud.i - pre; if (Math.abs(loud.i - TARGET_LUFS) < 1 && !pre) loud = null; }
    }
  }
  if (!loud && plan.trimTo == null) return null;
  const video = plan.trimTo != null
    ? ['-c:v', 'libx264', '-preset', 'medium', '-crf', '16', '-pix_fmt', 'yuv420p', '-threads', '2']
    : ['-c:v', 'copy'];
  const audio = !info.audioCodec ? ['-an']
    : loud ? ['-af', `${pre ? `volume=${pre.toFixed(2)}dB,` : ''}loudnorm=I=${TARGET_LUFS}:TP=${TRUE_PEAK}:LRA=${LRA}:measured_I=${loud.i}:measured_TP=${loud.tp}:measured_LRA=${loud.lra}:measured_thresh=${loud.thresh}:offset=${loud.offset}:linear=true`,
      '-c:a', 'aac', '-b:a', '192k', '-ar', '48000']
    : ['-c:a', 'copy'];
  await run(ffmpeg, ['-y', '-v', 'error', '-i', src, '-t', (plan.trimTo ?? info.duration).toFixed(3), '-map', '0:v:0', '-map', '0:a:0?',
    ...video, ...audio, '-movflags', '+faststart', out]);
  return { ...(plan.trimTo != null ? { trimmedFrom: Math.round(info.duration * 100) / 100 } : {}), ...(loud ? { levelledFrom: Math.round(from * 10) / 10 } : {}) };
}
