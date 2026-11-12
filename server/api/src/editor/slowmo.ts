// Smooth slow motion (Edit XL options §3, the Android path): a range of a clip played 2× or 4× slower with new frames
// made in between by fal's RIFE frame interpolation, as a new file the clip switches to (like reverse and stabilise).
// The range is cut here (re-encoded, no sound, at most 1080p on its short side so the price stays predictable), sent
// to fal, and fal's answer (fps × factor) is retimed to play at the source's frame rate: factor × longer, every frame
// kept. Priced from fal's published rate ($ per compute second, checked 2026-11-09 for fal-ai/rife/video and
// fal-ai/film/video: $0.0013), estimated before running and settled on the compute seconds fal reports.
import { execFile } from 'node:child_process';
import type { FalProvider } from '../suite/providers.js';
import { ReplicateError } from '../replicate/client.js';
import { pollPaid, type PollHooks } from './paidPoll.js';

export type SlowmoFactor = 2 | 4;
export const SLOWMO_LIMITS = { maxRangeSec: 10, minRangeSec: 0.3, maxFps: 60, maxShortSide: 1080, maxWaitMs: 15 * 60_000 } as const;
/** The model and fal's price per compute second (env FAL_SLOWMO_MODEL / FAL_SLOWMO_PER_SEC override). */
export const SLOWMO_MODEL = { ref: process.env.FAL_SLOWMO_MODEL?.trim() || 'fal-ai/rife/video', perSec: Number(process.env.FAL_SLOWMO_PER_SEC) > 0 ? Number(process.env.FAL_SLOWMO_PER_SEC) : 0.0013 };

/**
 * Compute seconds a job is expected to take: start-up, then the frames made, scaled by picture size against 1080p
 * (assumes ~15 output frames a second at 1080p, on the slow side so the hold covers it; the job settles on fal's figure).
 */
export function slowmoComputeSec(rangeSec: number, fps: number, factor: SlowmoFactor, width: number, height: number): number {
  const frames = rangeSec * Math.min(fps || 30, SLOWMO_LIMITS.maxFps) * factor;
  const px = Math.max(0.15, Math.min(1, (Math.min(width, height) || SLOWMO_LIMITS.maxShortSide) / SLOWMO_LIMITS.maxShortSide) ** 2);
  return 10 + (frames / 15) * px;
}
/** What compute seconds cost × the markup, at least a cent. */
export function slowmoUsd(computeSec: number, markup: number, perSec: number = SLOWMO_MODEL.perSec) {
  return Math.max(0.01, Math.round(computeSec * perSec * markup * 10000) / 10000);
}

function ff(ffmpeg: string, args: string[], timeoutMs = 5 * 60_000): Promise<void> {
  return new Promise((resolve, reject) => execFile(ffmpeg, ['-y', '-v', 'error', ...args], { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
    (err, _o, e) => (err ? reject(new ReplicateError(`slow motion failed: ${String(e || err.message).trim().split('\n').slice(-2).join(' ').slice(0, 300)}`, 'failed')) : resolve())));
}
const X264 = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16', '-pix_fmt', 'yuv420p', '-x264-params', 'sliced-threads=1:rc-lookahead=5:sync-lookahead=0', '-threads', '2', '-movflags', '+faststart'];

/** The range [start, end) of [input] as its own clip: no sound, at most 1080p on its short side and 60 fps. */
export async function cutRange(ffmpeg: string, input: string, out: string, startSec: number, endSec: number, fps: number) {
  const r = Math.min(fps || 30, SLOWMO_LIMITS.maxFps), s = SLOWMO_LIMITS.maxShortSide;
  await ff(ffmpeg, ['-threads', '2', '-ss', startSec.toFixed(3), '-i', input, '-t', (endSec - startSec).toFixed(3), '-an',
    '-vf', `scale='if(lt(iw,ih),min(${s},iw),-2)':'if(lt(iw,ih),-2,min(${s},ih))',fps=${r}`, ...X264, out]);
}

/** fal's interpolated clip played at [fps] for [seconds] (its frames spread evenly, none dropped or doubled). */
export async function retime(ffmpeg: string, input: string, out: string, inputSec: number, seconds: number, fps: number) {
  const k = seconds / inputSec;
  await ff(ffmpeg, ['-threads', '2', '-i', input, '-an', '-vf', `setpts=${k.toFixed(6)}*PTS`, '-r', String(Math.min(fps || 30, SLOWMO_LIMITS.maxFps) * 1), '-t', seconds.toFixed(3), ...X264, out]);
}

/**
 * Runs fal on the cut range (`url()`, only made when a request must start) or resumes a saved request: → the
 * interpolated clip downloaded to [file] and the compute seconds fal reports (null when it reports none). The
 * editor/paidPoll.ts rules apply (a timeout asks fal to cancel and keeps polling; a finished result is paid).
 */
export async function falInterpolate(fal: FalProvider, url: () => Promise<string>, factor: SlowmoFactor, file: string,
  h: { cancelled: () => boolean; leaving?: () => boolean; onProgress?: (f: number) => Promise<void> | void; pollMs?: number; resumeId?: string | null; onStart?: (id: string) => Promise<void>; onMade?: PollHooks['onMade'] }) {
  let id = h.resumeId ?? null;
  if (!id) {
    id = await fal.start(SLOWMO_MODEL.ref, { video_url: await url(), num_frames: factor - 1, use_calculated_fps: true, use_scene_detection: false, loop: false }, { cancelled: h.cancelled });
    await h.onStart?.(id);
  }
  return pollPaid(fal, id, file, 'Slow motion', { cancelled: h.cancelled, leaving: h.leaving, pollMs: h.pollMs ?? 2000, timeoutMs: SLOWMO_LIMITS.maxWaitMs, onProgress: h.onProgress, onMade: h.onMade });
}
