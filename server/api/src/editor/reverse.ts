// Reverse (Edit suite): a video played backwards, sound too, as a new file the clip switches to (model.ts
// reverseClip). Local ffmpeg. The reverse filters hold every decoded frame of their input, so the source is reversed
// in short pieces, one at a time on disk, then joined last piece first: memory stays at one piece whatever the length.
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/** Pieces of 0.5 s, decoded and encoded on one thread with no x264 lookahead: about 210 MB peak at 1080p (measured). */
export const REVERSE_LIMITS = { maxSec: 60, pieceSec: 0.5 } as const;

function ff(ffmpeg: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => execFile(ffmpeg, ['-y', '-v', 'error', ...args], { timeout: 10 * 60_000, maxBuffer: 4 * 1024 * 1024 },
    (err, _o, e) => (err ? reject(new Error(`reverse failed: ${String(e ?? err.message).trim().split('\n').slice(-2).join(' ').slice(0, 300)}`)) : resolve())));
}

/**
 * Writes [input] ([durationSec] long) reversed — picture and, with [hasAudio], sound — to [out] as H.264/AAC MP4.
 * Each piece is reversed on its own (H.264 + PCM in Matroska, so no AAC priming gaps at the joins), then the pieces
 * are joined in reverse order with the picture copied and the sound encoded once.
 */
export async function reverseVideo(ffmpeg: string, input: string, out: string, hasAudio: boolean, durationSec: number, pieceSec: number = REVERSE_LIMITS.pieceSec): Promise<void> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-rev-'));
  try {
    const pieces: string[] = [];
    const n = Math.max(1, Math.ceil(durationSec / pieceSec - 1e-6));
    for (let i = 0; i < n; i++) {
      const start = i * pieceSec, len = Math.min(pieceSec, durationSec - start);
      if (len < 0.02) continue;
      const f = path.join(dir, `p${String(i).padStart(4, '0')}.mkv`);
      await ff(ffmpeg, ['-threads', '1', '-ss', start.toFixed(4), '-t', len.toFixed(4), '-i', input, '-vf', 'reverse', ...(hasAudio ? ['-af', 'areverse', '-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2'] : ['-an']),
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-threads', '1', '-x264-params', 'rc-lookahead=0:sync-lookahead=0', f]);
      pieces.push(f);
    }
    const list = path.join(dir, 'list.txt');
    fs.writeFileSync(list, pieces.reverse().map(f => `file '${f.replace(/'/g, "'\\''")}'`).join('\n') + '\n');
    await ff(ffmpeg, ['-f', 'concat', '-safe', '0', '-i', list, '-c:v', 'copy', ...(hasAudio ? ['-c:a', 'aac', '-b:a', '160k'] : ['-an']), '-movflags', '+faststart', out]);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
