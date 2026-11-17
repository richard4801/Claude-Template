// AI suite · Extend's media steps (ffmpeg): the part of the source a model continues from, the bridge frame, and the
// join of source + extension into one take. Re-encodes (H.264 / AAC) so cuts land on exact times and both parts match.
import { execFile } from 'node:child_process';
import type { MediaInfo } from '../replicate/media.js';
import { encThreads } from '../lib/resources.js';

function run(bin: string, args: string[], timeoutMs = 10 * 60_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) reject(new Error(`${bin.split('/').pop()} failed: ${String(stderr ?? '').trim().split('\n').slice(-3).join(' | ').slice(0, 400) || err.message}`));
      else resolve(String(stdout));
    });
  });
}

const ENC = () => ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-threads', encThreads(2)];
const AENC = ['-c:a', 'aac', '-b:a', '160k', '-ar', '48000', '-ac', '2'];

/** `seconds` from the end (`from: "end"`) or the start of `src`. */
export async function segment(ffmpeg: string, src: string, out: string, seconds: number, from: 'start' | 'end', info: MediaInfo) {
  const s = Math.max(0.1, Math.min(seconds, info.duration));
  const seek = from === 'end' ? ['-ss', Math.max(0, info.duration - s).toFixed(3)] : [];
  await run(ffmpeg, ['-y', ...seek, '-i', src, '-t', s.toFixed(3), ...ENC(), ...(info.audioCodec ? AENC : ['-an']), '-movflags', '+faststart', out]);
}

/** New Swap's trimmer: `from`–`to` seconds of `src` (re-encoded so the cut lands on the exact time). */
export async function cutRange(ffmpeg: string, src: string, out: string, from: number, to: number, info: MediaInfo) {
  const a = Math.max(0, Math.min(from, info.duration)), d = Math.max(0.1, Math.min(to, info.duration) - a);
  await run(ffmpeg, ['-y', '-ss', a.toFixed(3), '-i', src, '-t', d.toFixed(3), ...ENC(), ...(info.audioCodec ? AENC : ['-an']), '-movflags', '+faststart', out]);
}

/**
 * The size a source must be scaled up to so its short side is at least `minPx` (aspect kept, even sizes, never
 * smaller than it is), or null when it is already big enough. 540×960 with 720 → 720×1280.
 */
export function upscaleSize(width: number, height: number, minPx: number): { width: number; height: number } | null {
  if (!(width > 0 && height > 0 && minPx > 0) || Math.min(width, height) >= minPx) return null;
  const k = minPx / Math.min(width, height);
  const even = (v: number) => Math.ceil(v / 2) * 2;
  const short = even(minPx), long = Math.max(short, even(Math.max(width, height) * k - 1e-6));
  return height >= width ? { width: short, height: long } : { width: long, height: short };
}

/**
 * `src` scaled up (lanczos) so its short side is at least `minPx`, for an edit model's floor (Kling O1: 720). Frame
 * rate, length and sound are kept (sound copied); the picture is re-encoded at high quality (CRF 18), never resampled
 * in time. Returns false (and writes nothing) when the source is already big enough.
 */
export async function upscaleTo(ffmpeg: string, src: string, out: string, info: MediaInfo, minPx: number) {
  const size = upscaleSize(info.width, info.height, minPx);
  if (!size) return false;
  // Sized from the frame ffmpeg actually decodes (after a phone's rotation flag is applied), so a rotated clip isn't squashed.
  const s = Math.min(size.width, size.height);
  await run(ffmpeg, ['-y', '-i', src, '-vf', `scale='if(lt(iw,ih),${s},-2)':'if(lt(iw,ih),-2,${s})':flags=lanczos,setsar=1`, ...ENC(),
    ...(info.audioCodec ? ['-c:a', 'copy'] : ['-an']), '-movflags', '+faststart', out]);
  return true;
}

/** One frame of `src` at `at` seconds, as a JPEG (New Swap's frames for models that can't take a video). */
export async function frameAt(ffmpeg: string, src: string, out: string, at: number) {
  await run(ffmpeg, ['-y', '-ss', Math.max(0, at).toFixed(3), '-i', src, '-frames:v', '1', '-q:v', '2', out]);
}

/** The first or last frame of `src` as a JPEG (the frame bridge's start or end image). */
export async function frameOf(ffmpeg: string, src: string, out: string, which: 'first' | 'last', info: MediaInfo) {
  const at = which === 'first' ? 0 : Math.max(0, info.duration - Math.max(0.05, 1 / Math.max(1, info.fps || 24)) * 1.5);
  await run(ffmpeg, ['-y', '-ss', at.toFixed(3), '-i', src, '-frames:v', '1', '-q:v', '2', out]);
}

/**
 * `first` then `second` as one clip at `target`'s size and frame rate (letterboxed if the shapes differ). A part
 * without sound gets silence, so the joined clip always has one continuous audio track when either part has sound.
 */
export async function joinClips(ffmpeg: string, first: { file: string; info: MediaInfo }, second: { file: string; info: MediaInfo }, out: string, target: MediaInfo) {
  const w = target.width - (target.width % 2), h = target.height - (target.height % 2), fps = target.fps || 24;
  const v = (i: number) => `[${i}:v]scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${fps},format=yuv420p[v${i}]`;
  const audio = !!(first.info.audioCodec || second.info.audioCodec);
  const args = ['-y', '-i', first.file, '-i', second.file];
  const filters = [v(0), v(1)];
  if (audio) {
    // Silence for a part without sound, as long as that part.
    const parts = [first, second].map((p, i) => {
      if (p.info.audioCodec) { filters.push(`[${i}:a]aresample=48000,aformat=channel_layouts=stereo[a${i}]`); return; }
      args.push('-f', 'lavfi', '-t', p.info.duration.toFixed(3), '-i', 'anullsrc=r=48000:cl=stereo');
      return args.filter(a => a === '-i').length - 1;
    });
    parts.forEach((idx, i) => { if (idx != null) filters.push(`[${idx}:a]anull[a${i}]`); });
    filters.push('[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]');
  } else filters.push('[v0][v1]concat=n=2:v=1:a=0[v]');
  await run(ffmpeg, [...args, '-filter_complex', filters.join(';'), '-map', '[v]', ...(audio ? ['-map', '[a]', ...AENC] : []), ...ENC(), '-movflags', '+faststart', out]);
}
