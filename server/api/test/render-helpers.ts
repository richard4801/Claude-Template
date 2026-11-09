// Helpers for the server render tests.
import { execFileSync } from 'node:child_process';

/** Loudness (RMS, 0–1) of a file between t0 and t1, mono. */
export function rms(file: string, t0: number, t1: number): number {
  const buf = execFileSync('ffmpeg', ['-v', 'error', '-ss', String(t0), '-t', String(t1 - t0), '-i', file, '-ac', '1', '-ar', '16000', '-f', 'f32le', 'pipe:1'], { maxBuffer: 64 * 1024 * 1024 });
  const x = new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 4));
  let s = 0; for (const v of x) s += v * v;
  return x.length ? Math.sqrt(s / x.length) : 0;
}
