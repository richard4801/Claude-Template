// Stabilise (Edit XL options §2): a handheld video steadied, as a new file the clip switches to (like reverse). Local
// ffmpeg vid.stab, two passes: vidstabdetect measures the camera's shake into a transforms file, vidstabtransform
// smooths the camera path and moves each frame against the shake, zooming in just enough to hide the moving edges.
// vid.stab is GPL: it runs here on our server and is never shipped in the apps. Both passes stream (one frame at a
// time), with threads capped so the 512 MB box keeps room for Node.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const STABILIZE_LIMITS = { maxSec: 180, smoothing: 15 } as const;
/** The apps' strength (0–1, default 0.5) as vid.stab smoothing: frames each way, 5 (light) to 30 (locked off). */
export const smoothingOf = (strength = 0.5) => Math.round(5 + Math.min(1, Math.max(0, strength)) * 25);

function ff(ffmpeg: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => execFile(ffmpeg, ['-y', '-v', 'error', ...args], { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
    (err, _o, e) => (err ? reject(new Error(`stabilise failed: ${String(e ?? err.message).trim().split('\n').slice(-2).join(' ').slice(0, 300)}`)) : resolve(String(e ?? '')))));
}

/** Whether this server's ffmpeg has vid.stab (Debian's does: libavfilter depends on libvidstab). */
export async function vidstabAvailable(ffmpeg: string): Promise<boolean> {
  return new Promise(resolve => execFile(ffmpeg, ['-hide_banner', '-filters'], { timeout: 20_000, maxBuffer: 4 * 1024 * 1024 },
    (err, o) => resolve(!err && /\bvidstabdetect\b/.test(String(o)) && /\bvidstabtransform\b/.test(String(o)))));
}

/**
 * Writes [input] steadied to [out] (H.264, the sound copied). `smoothing`: frames each way the camera path is averaged
 * over (15 ≈ half a second at 30 fps). The picture is zoomed by the least that keeps the moved edges out of frame
 * (optzoom=1), or with zoom "none" not at all (the moved edges show black); a light unsharp undoes the resampling softness.
 */
export async function stabilizeVideo(ffmpeg: string, input: string, out: string, hasAudio: boolean, durationSec: number, smoothing: number = STABILIZE_LIMITS.smoothing, zoom: 'auto' | 'none' = 'auto'): Promise<void> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-stab-'));
  const timeout = Math.max(5 * 60_000, durationSec * 20_000);
  try {
    const trf = path.join(dir, 'motion.trf');
    await ff(ffmpeg, ['-threads', '2', '-i', input, '-an', '-vf', `vidstabdetect=shakiness=6:accuracy=9:stepsize=6:result=${trf}`, '-f', 'null', '-'], timeout);
    await ff(ffmpeg, ['-threads', '2', '-i', input, '-vf', `vidstabtransform=input=${trf}:smoothing=${Math.round(smoothing)}:${zoom === 'auto' ? 'optzoom=1:zoomspeed=0.25' : 'optzoom=0:crop=black'}:interpol=bilinear,unsharp=5:5:0.6:3:3:0.3,format=yuv420p`,
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-x264-params', 'sliced-threads=1:rc-lookahead=5:sync-lookahead=0', '-threads', '2',
      ...(hasAudio ? ['-c:a', 'copy'] : ['-an']), '-movflags', '+faststart', out], timeout);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
