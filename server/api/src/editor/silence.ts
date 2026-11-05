// Free silence detection for the editor's cuts (plans/api.md "Editor v2" → cuts `silenceOnly`): ffmpeg's silencedetect
// filter reads the AUDIO only (no video is decoded into a new file and nothing is encoded); its log gives the quiet
// ranges, which become silence cuts with the same padding rules as transcript-based cuts.
import { execFile } from 'node:child_process';
import type { Cut } from './cuts.js';

export type Silence = { startSec: number; endSec: number };
const r3 = (v: number) => Math.round(v * 1000) / 1000;

/** Quiet ranges from ffmpeg's silencedetect log (an open silence at the end runs to durationSec). */
export function parseSilenceDetect(log: string, durationSec: number): Silence[] {
  const out: Silence[] = [];
  let open: number | null = null;
  for (const line of log.split('\n')) {
    const s = /silence_start:\s*(-?[\d.]+)/.exec(line);
    if (s) { open = Math.max(0, Number(s[1])); continue; }
    const e = /silence_end:\s*([\d.]+)/.exec(line);
    if (e && open !== null) { out.push({ startSec: r3(open), endSec: r3(Math.min(durationSec, Number(e[1]))) }); open = null; }
  }
  if (open !== null && open < durationSec) out.push({ startSec: r3(open), endSec: r3(durationSec) });
  return out.filter(x => x.endSec > x.startSec);
}

/** Silences → cuts: each keeps `keepPadSec` of quiet on both sides (none at the very start/end of the media). */
export function silenceCuts(sil: Silence[], durationSec: number, o: { minSilenceSec: number; keepPadSec: number }): { cuts: Cut[]; savedSec: number } {
  const cuts: Cut[] = [];
  for (const x of sil) {
    if (x.endSec - x.startSec < o.minSilenceSec - 1e-9) continue;
    const s = x.startSec <= 0.001 ? 0 : x.startSec + o.keepPadSec;
    const e = x.endSec >= durationSec - 0.001 ? durationSec : x.endSec - o.keepPadSec;
    if (e - s >= 0.1) cuts.push({ startSec: r3(s), endSec: r3(e), reason: 'silence' });
  }
  return { cuts, savedSec: r3(cuts.reduce((a, c) => a + c.endSec - c.startSec, 0)) };
}

/** Runs silencedetect on a file or URL. `noiseDb`: below this level counts as quiet. */
export function detectSilences(ffmpeg: string, input: string, durationSec: number, o: { minSilenceSec: number; noiseDb?: number; timeoutMs?: number }): Promise<Silence[]> {
  const d = Math.max(0.1, Math.min(o.minSilenceSec, 0.25)); // find short ones too; the caller filters by its own minimum
  return new Promise((resolve, reject) => {
    execFile(ffmpeg, ['-hide_banner', '-nostats', '-i', input, '-vn', '-sn', '-dn', '-af', `silencedetect=noise=${o.noiseDb ?? -35}dB:d=${d}`, '-f', 'null', '-'],
      { timeout: o.timeoutMs ?? 120_000, maxBuffer: 8 * 1024 * 1024 }, (err, _stdout, stderr) => {
        const log = String(stderr ?? '');
        if (err && /does not contain any stream|matches no streams|Output file #0 does not contain/i.test(log)) return resolve([{ startSec: 0, endSec: durationSec }]);
        if (err) return reject(new Error(`ffmpeg failed: ${log.trim().split('\n').slice(-2).join(' | ').slice(0, 300) || err.message}`));
        resolve(parseSilenceDetect(log, durationSec));
      });
  });
}
