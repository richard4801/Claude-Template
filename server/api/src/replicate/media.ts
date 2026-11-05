// ffmpeg steps around a Replicate render (plans/backend.md "Replicate"): pad the source to whole seconds, cut the
// render back to the exact source length with the source's own audio, and grab a thumbnail. ffmpeg runs as a child
// process with a small thread count so a 2K encode fits next to the API.
import { execFile } from 'node:child_process';

export type MediaInfo = { duration: number; width: number; height: number; fps: number; audioCodec: string | null };

function run(bin: string, args: string[], timeoutMs = 10 * 60_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const tail = String(stderr ?? '').trim().split('\n').slice(-3).join(' | ').slice(0, 400);
        const e = err as Error & { signal?: string | null; killed?: boolean; code?: number | string };
        // A kill with no stderr is almost always the instance running out of memory (or our timeout).
        const how = e.signal ? ` (killed by ${e.signal}${e.killed ? ', timeout' : ', likely out of memory'})` : e.code != null ? ` (exit ${e.code})` : '';
        reject(new Error(`${bin.split('/').pop()} failed${how}: ${tail || e.message}`));
      } else resolve(String(stdout));
    });
  });
}

const cache = new Map<string, Promise<boolean>>();
/** Whether ffmpeg and ffprobe run here (checked once). */
export function mediaToolsAvailable(ffmpeg: string, ffprobe: string) {
  const k = `${ffmpeg}|${ffprobe}`;
  if (!cache.has(k)) cache.set(k, Promise.all([run(ffmpeg, ['-version'], 10_000), run(ffprobe, ['-version'], 10_000)]).then(() => true, () => false));
  return cache.get(k)!;
}

const fpsOf = (r?: string) => {
  const [a, b] = String(r ?? '0/1').split('/').map(Number);
  return a && b ? Math.round((a / b) * 100) / 100 : 0;
};

export async function probe(ffprobe: string, file: string): Promise<MediaInfo> {
  const out = JSON.parse(await run(ffprobe, ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', file], 60_000)) as {
    format?: { duration?: string }; streams?: { codec_type?: string; codec_name?: string; width?: number; height?: number; avg_frame_rate?: string; r_frame_rate?: string; duration?: string }[];
  };
  const v = out.streams?.find(s => s.codec_type === 'video');
  const a = out.streams?.find(s => s.codec_type === 'audio');
  if (!v) throw new Error('The clip has no video stream');
  const duration = Number(out.format?.duration ?? v.duration ?? NaN);
  return { duration, width: v.width ?? 0, height: v.height ?? 0, fps: fpsOf(v.avg_frame_rate) || fpsOf(v.r_frame_rate), audioCodec: a?.codec_name ?? null };
}

const sec = (v: number) => v.toFixed(3);

/**
 * Pads `src` to exactly `seconds` by holding the last frame (and adding silence when it has audio), so Replicate's
 * whole-second output covers the full clip. Very large sources are scaled down to 1440 wide (2K's width).
 */
export async function padTo(ffmpeg: string, src: string, out: string, seconds: number, info: MediaInfo, o: { mute?: boolean } = {}) {
  const extra = Math.max(0, seconds - info.duration) + 0.1;
  const args = ['-y', '-v', 'error', '-i', src,
    '-vf', `scale='min(1440,iw)':-2,tpad=stop_mode=clone:stop_duration=${sec(extra)}`];
  // mute: the model gets no sound, so it can't lip-sync to music or speech the performer isn't making.
  if (info.audioCodec && !o.mute) args.push('-af', `apad=pad_dur=${sec(extra)}`, '-c:a', 'aac', '-b:a', '192k');
  else args.push('-an');
  args.push('-t', String(seconds), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16', '-pix_fmt', 'yuv420p', '-threads', '2', '-movflags', '+faststart', out);
  await run(ffmpeg, args);
}

/**
 * The finished take: Replicate's render cut to the exact source length with a re-encode (a stream copy would cut at a
 * keyframe), plus the source's original audio (copied when it's AAC) or no audio.
 */
export async function finishTake(ffmpeg: string, rendered: string, src: string, out: string, o: { duration: number; keepAudio: boolean; audioCodec: string | null }) {
  const withAudio = o.keepAudio && !!o.audioCodec;
  const args = ['-y', '-v', 'error', '-i', rendered];
  if (withAudio) args.push('-i', src);
  args.push('-map', '0:v:0');
  if (withAudio) args.push('-map', '1:a:0', ...(o.audioCodec === 'aac' ? ['-c:a', 'copy'] : ['-c:a', 'aac', '-b:a', '192k']));
  else args.push('-an');
  // Light on memory: a 2K (1440x2560) 'medium' encode with full lookahead was killed on the small API instance.
  args.push('-t', sec(o.duration), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '15', '-x264-params', 'rc-lookahead=8:ref=2',
    '-pix_fmt', 'yuv420p', '-threads', '2', '-max_muxing_queue_size', '1024', '-movflags', '+faststart', out);
  try {
    await run(ffmpeg, args);
  } catch (first) {
    // Fallback that needs almost no memory: copy the video stream (the cut lands on the nearest keyframe, at most a
    // fraction of a second long) and put the audio on. Better a take a hair long than a finished render marked failed.
    const fb = ['-y', '-v', 'error', '-i', rendered];
    if (withAudio) fb.push('-i', src);
    fb.push('-map', '0:v:0');
    if (withAudio) fb.push('-map', '1:a:0', '-c:a', 'aac', '-b:a', '192k'); else fb.push('-an');
    fb.push('-t', sec(o.duration), '-c:v', 'copy', '-movflags', '+faststart', out);
    try { await run(ffmpeg, fb); } catch { throw first; }
  }
}

/**
 * Puts the source clip's own sound on a delivered take: the video is stream-copied (no re-encode); the audio is copied
 * when it's AAC, else encoded to AAC (audio only, light). Used when the model was sent a silent clip.
 */
export async function restoreAudio(ffmpeg: string, take: string, src: string, out: string, audioCodec: string | null) {
  await run(ffmpeg, ['-y', '-v', 'error', '-i', take, '-i', src, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy',
    ...(audioCodec === 'aac' ? ['-c:a', 'copy'] : ['-c:a', 'aac', '-b:a', '192k']), '-movflags', '+faststart', out]);
}

/** The same video without its audio track (stream copy, no re-encode). */
export async function stripAudio(ffmpeg: string, src: string, out: string) {
  await run(ffmpeg, ['-y', '-v', 'error', '-i', src, '-map', '0:v:0', '-c:v', 'copy', '-an', '-movflags', '+faststart', out]);
}

/** A JPEG frame from the finished take, for its thumbnail. */
export async function thumbnail(ffmpeg: string, video: string, out: string, at: number) {
  await run(ffmpeg, ['-y', '-v', 'error', '-ss', sec(Math.max(0, at)), '-i', video, '-frames:v', '1', '-vf', "scale='min(720,iw)':-2", '-q:v', '3', out], 60_000);
}
