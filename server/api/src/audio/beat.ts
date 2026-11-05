// Beat-only audio (plans/prompt-scripts.md §6): for a shot with no motion source where the user's music should drive
// the rhythm but nobody sings or speaks, the vocals are separated out and only the instrumental is sent to the video
// model as reference audio (with "move to the beat; do not sing or mouth lyrics"). Runs only when the user generates,
// on Replicate (a Demucs build, MIT-licensed code), billed with the job. The AI suite (workstream 1) calls this.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import type { Ctx } from '../ctx.js';
import { ReplicateError, type Prediction } from '../replicate/client.js';
import { putFile } from '../storage/objects.js';
import { predictionError } from '../services/replicateVideo.js';

export type BeatOnly = { instrumentalKey: string; costUsd: number; predictionId: string; seconds: number | null };
type Deps = Pick<Ctx, 'replicate' | 'storage' | 'db' | 'config' | 'log'>;

/** The instrumental in a finished separation: a no-vocals stem, or null (then the other stems are mixed). */
export function instrumentalOf(output: unknown): { url: string | null; stems: string[] } {
  if (!output || typeof output !== 'object' || Array.isArray(output)) return { url: null, stems: [] };
  const o = output as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === 'string' && v ? v : null);
  for (const k of ['no_vocals', 'accompaniment', 'instrumental', 'other_than_vocals']) if (str(o[k])) return { url: str(o[k]), stems: [] };
  return { url: null, stems: Object.entries(o).filter(([k, v]) => k !== 'vocals' && str(v)).map(([, v]) => v as string) };
}

function ffmpeg(bin: string, args: string[]) {
  return new Promise<void>((resolve, reject) => execFile(bin, args, { timeout: 5 * 60_000 }, (e, _o, err) => (e ? reject(new Error(`ffmpeg failed: ${String(err).slice(-300)}`)) : resolve())));
}

/**
 * Separates the vocals from `audioKey` (any audio or video file in storage) and stores the instrumental as an AAC
 * file next to it. Throws a ReplicateError (the caller fails the job with its usual member-safe message).
 */
export async function beatOnlyAudio(ctx: Deps, o: { studioId: string; userId?: string | null; jobId: string; audioKey: string; cancelled?: () => boolean }): Promise<BeatOnly> {
  const c = ctx.config;
  const version = c.AUDIO_SEPARATION_VERSION || (await ctx.replicate.latestVersion(c.AUDIO_SEPARATION_MODEL));
  if (!version) throw new ReplicateError(`The vocal separation model ${c.AUDIO_SEPARATION_MODEL} isn't available`, 'unavailable');
  const extra = (() => { try { return JSON.parse(c.AUDIO_SEPARATION_INPUT) as Record<string, unknown>; } catch { return {}; } })();
  const url = await ctx.storage.presignGet(o.audioKey, c.REPLICATE_INPUT_URL_TTL_SEC);
  const input = { ...extra, [c.AUDIO_SEPARATION_AUDIO_FIELD]: url };
  const p = await ctx.replicate.create(c.AUDIO_SEPARATION_MODEL, input, { version, maxWaitMs: c.REPLICATE_MAX_RATE_WAIT_SEC * 1000, cancelled: o.cancelled });
  const done: Prediction = p.status === 'succeeded' || p.status === 'failed' || p.status === 'canceled' ? p
    : await ctx.replicate.wait(p.id, { pollMs: Math.min(c.REPLICATE_POLL_MS, 2000), timeoutMs: 10 * 60_000, cancelled: o.cancelled });
  if (done.status === 'failed') throw predictionError(done);
  if (done.status === 'canceled') throw new ReplicateError('The vocal separation was cancelled', 'cancelled');
  const found = instrumentalOf(done.output);
  if (!found.url && !found.stems.length) throw new ReplicateError('The vocal separation returned no instrumental', 'failed');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-beat-'));
  try {
    const files: string[] = [];
    for (const [i, u] of (found.url ? [found.url] : found.stems).entries()) {
      const f = path.join(tmp, `stem_${i}`);
      await ctx.replicate.download(u, f);
      files.push(f);
    }
    // Audio only (never video): one stem is converted to AAC, several are mixed into one.
    const out = path.join(tmp, 'instrumental.m4a');
    const args = ['-y', '-v', 'error', ...files.flatMap(f => ['-i', f])];
    if (files.length > 1) args.push('-filter_complex', `amix=inputs=${files.length}:normalize=0`);
    args.push('-vn', '-c:a', 'aac', '-b:a', '192k', out);
    await ffmpeg(c.FFMPEG_PATH, args);
    const key = `r/${o.jobId}/instrumental.m4a`;
    await putFile(ctx, { key, file: out, studioId: o.studioId, kind: 'output', userId: o.userId ?? null, contentType: 'audio/mp4' });
    const secs = Number(done.metrics?.predict_time);
    const costUsd = Number.isFinite(secs) && secs > 0 ? secs * c.AUDIO_SEPARATION_PRICE_PER_SEC : c.AUDIO_SEPARATION_ESTIMATE;
    return { instrumentalKey: key, costUsd, predictionId: done.id, seconds: Number.isFinite(secs) ? secs : null };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
