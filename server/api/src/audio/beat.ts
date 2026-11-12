// Beat-only audio (plans/prompt-scripts.md §6): for a shot with no motion source where the user's music should drive
// the rhythm but nobody sings or speaks, the vocals are separated out and only the instrumental is sent to the video
// model as reference audio (with "move to the beat; do not sing or mouth lyrics"). Runs only when the user generates,
// billed with the job. The separation is the editor's (workstream 3) `EditorProvider.separate(…, 'no_vocals')`: one
// Replicate adapter for both, switched by EDITOR_AI_PROVIDER (mock by default: no provider call, the source is used).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import type { Ctx } from '../ctx.js';
import { makeProvider, rmQuiet, type EditorProvider } from '../editor/providers.js';
import { putFile } from '../storage/objects.js';

export type BeatOnly = {
  /** The instrumental in storage (audio only, AAC). The source itself when the provider is the mock (`separated: false`). */
  instrumentalKey: string; separated: boolean;
  costUsd: number; predictionId: string | null; seconds: number | null;
  /** The provider separated (and charged) but saving the instrumental failed: the shot goes on without audio, the cost is billed. */
  lost?: boolean;
};

function ffmpeg(bin: string, args: string[]) {
  return new Promise<void>((resolve, reject) => execFile(bin, args, { timeout: 5 * 60_000 }, (e, _o, err) => (e ? reject(new Error(`ffmpeg failed: ${String(err).slice(-300)}`)) : resolve())));
}

/**
 * Separates the vocals from `audioKey` (any audio or video file in storage) and stores the instrumental as
 * `r/<jobId>/instrumental.m4a`. Throws the provider's ReplicateError (the caller fails the job with its usual
 * member-safe message). `durationSec` sizes the provider's timeout; `provider` is for tests.
 */
export async function beatOnlyAudio(ctx: Ctx, o: {
  studioId: string; userId?: string | null; jobId: string; audioKey: string; durationSec?: number; cancelled?: () => boolean; provider?: EditorProvider;
  /** The separation's prediction, saved by the caller so a restart polls it instead of paying for a second one. */
  resumeId?: string | null; onPrediction?: (id: string) => Promise<void> | void;
}): Promise<BeatOnly> {
  const provider = o.provider ?? makeProvider(ctx);
  const url = await ctx.storage.presignGet(o.audioKey, ctx.config.REPLICATE_INPUT_URL_TTL_SEC);
  let predictionId: string | null = null;
  const r = await provider.separate(url, o.durationSec ?? 30, { cancelled: o.cancelled ?? (() => false), resumeId: o.resumeId, onPrediction: async id => { predictionId = id; await o.onPrediction?.(id); } }, 'no_vocals');
  const costUsd = (r.gpuSec ?? 0) * provider.rates.separate;
  if (!r.file) return { instrumentalKey: o.audioKey, separated: false, costUsd, predictionId, seconds: r.gpuSec };
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'muse-beat-'));
  try {
    // Audio only (never video): the stem converted to AAC.
    const out = path.join(tmp, 'instrumental.m4a');
    await ffmpeg(ctx.config.FFMPEG_PATH, ['-y', '-v', 'error', '-i', r.file, '-vn', '-c:a', 'aac', '-b:a', '192k', out]);
    const key = `r/${o.jobId}/instrumental.m4a`;
    await putFile(ctx, { key, file: out, studioId: o.studioId, kind: 'output', userId: o.userId ?? null, contentType: 'audio/mp4' });
    return { instrumentalKey: key, separated: true, costUsd, predictionId, seconds: r.gpuSec };
  } catch (e) {
    // Paid at the provider already: never fail the shot (and say "not charged") over our own conversion or storage.
    ctx.log.warn({ job: o.jobId, err: (e as Error).message }, 'beat-only audio: separated but not saved, the shot goes on without audio');
    return { instrumentalKey: o.audioKey, separated: false, costUsd, predictionId, seconds: r.gpuSec, lost: true };
  } finally {
    rmQuiet(r.file);
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
